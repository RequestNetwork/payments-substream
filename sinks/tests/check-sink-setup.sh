#!/usr/bin/env bash
# Sink setup check against a real Postgres 17: `bash sinks/tests/check-sink-setup.sh <image-tag>`
# (CI: image.yml build-smoke, after the image is loaded). For each package baked into the image
# (/app/evm.spkg, /app/tron.spkg) it runs `substreams sink postgres setup` TWICE into its own
# schema and requires exit 0 both times (schema.sql must be idempotent), then checks that
# payments.inbox_seq (REQ-811) is a nullable BIGINT whose default draws from that schema's own
# payments_inbox_seq: set on insert, kept on an ON CONFLICT upsert, greater for a later row.
# Needs docker only; no SUBSTREAMS_API_TOKEN (setup never contacts an endpoint). Removes only the
# container and network it created.
set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: $0 <image-tag>" >&2
  exit 2
fi
IMAGE=$1

SUFFIX="$$-${RANDOM}"
NET="sink-setup-net-$SUFFIX"
PG="sink-setup-pg-$SUFFIX"
RUN="sink-setup-run-$SUFFIX"

cleanup() {
  # A setup container still running (script killed mid-setup) would keep the network in use.
  docker rm -f "$RUN" >/dev/null 2>&1 || true
  # -v also drops the anonymous volume the image declares for /var/lib/postgresql/data.
  docker rm -fv "$PG" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# psql inside the Postgres container (the base DSN: psql rejects the schemaName= URI option).
# Always over TCP (-h 127.0.0.1): the entrypoint's temporary init-only server listens on the Unix
# socket alone, so a socket connection can succeed before the real server is up. Host connections
# use password auth, hence PGPASSWORD.
psql_q() {
  docker exec -e PGPASSWORD=postgres "$PG" \
    psql -h 127.0.0.1 -p 5432 -v ON_ERROR_STOP=1 -qtA -U postgres -d payments -c "$1"
}

docker network create "$NET" >/dev/null
docker run -d --name "$PG" --network "$NET" \
  -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=payments \
  postgres:17-alpine >/dev/null

# The entrypoint restarts the server once after initdb; probe over TCP (the temporary init server
# has no TCP listener) and require a real query to succeed too.
ready=false
for _ in $(seq 1 60); do
  if docker exec "$PG" pg_isready -h 127.0.0.1 -p 5432 -U postgres -d payments >/dev/null 2>&1 \
    && psql_q 'SELECT 1' >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
[ "$ready" = true ] || { docker logs "$PG" >&2 || true; fail "postgres did not become ready"; }
echo "postgres: $(psql_q 'SHOW server_version')"

# package:schema pairs; setup applies schema.sql inside schemaName but does not create the schema.
PAIRS="evm:evm_a tron:tron_a"

for pair in $PAIRS; do
  pkg=${pair%%:*}
  schema=${pair#*:}
  psql_q "CREATE SCHEMA IF NOT EXISTS $schema"
  dsn="postgres://postgres:postgres@$PG:5432/payments?sslmode=disable&schemaName=$schema"
  for run in 1 2; do
    echo "=== setup /app/$pkg.spkg into $schema (run $run) ==="
    # DSN through the environment, never argv, as sinks/supervisor.sh does.
    if ! docker run --rm --name "$RUN" --network "$NET" -e SUBSTREAMS_SINK_DSN="$dsn" \
      --entrypoint substreams "$IMAGE" sink postgres setup "/app/$pkg.spkg"; then
      fail "setup /app/$pkg.spkg into $schema failed on run $run"
    fi
  done
done

# insert_probe <schema> <id> <amount>: insert omitting inbox_seq (upsert like the sink), print it.
insert_probe() {
  psql_q "INSERT INTO $1.payments (id, chain, tx_hash, block_number, timestamp, contract_address,
            token_address, from_address, to_address, amount, fee_amount, fee_address,
            payment_reference)
          VALUES ('$2', 'probe', '$2', 1, 1, '0xc', '0xt', '0xf', '0xr', $3, 0, '0xfa', '0xref')
          ON CONFLICT (id) DO UPDATE SET amount = EXCLUDED.amount
          RETURNING inbox_seq"
}

for pair in $PAIRS; do
  schema=${pair#*:}
  echo "=== inbox_seq in $schema ==="

  col=$(psql_q "SELECT data_type || '|' || is_nullable || '|' || coalesce(column_default, '')
                FROM information_schema.columns
                WHERE table_schema = '$schema' AND table_name = 'payments'
                  AND column_name = 'inbox_seq'")
  echo "column: $col"
  [ -n "$col" ] || fail "$schema.payments has no inbox_seq column"
  type=${col%%|*}
  rest=${col#*|}
  nullable=${rest%%|*}
  default=${rest#*|}
  [ "$type" = bigint ] || fail "$schema.payments.inbox_seq is $type, want bigint"
  [ "$nullable" = YES ] || fail "$schema.payments.inbox_seq is NOT NULL, want nullable"
  # psql runs with the default search_path, so a sequence outside it prints schema-qualified.
  case $default in
    *"'$schema.payments_inbox_seq'"*) ;;
    *) fail "$schema.payments.inbox_seq default [$default] does not name $schema.payments_inbox_seq" ;;
  esac
  echo "sequence: $schema.payments_inbox_seq"

  first=$(insert_probe "$schema" "probe-1" 1)
  [ -n "$first" ] || fail "$schema: inbox_seq is NULL on insert"
  again=$(insert_probe "$schema" "probe-1" 2)
  [ "$again" = "$first" ] || fail "$schema: upsert changed inbox_seq ($first -> $again)"
  amount=$(psql_q "SELECT amount FROM $schema.payments WHERE id = 'probe-1'")
  [ "$amount" = 2 ] || fail "$schema: upsert did not update amount (got $amount)"
  second=$(insert_probe "$schema" "probe-2" 1)
  [ -n "$second" ] && [ "$second" -gt "$first" ] \
    || fail "$schema: second row inbox_seq [$second] is not greater than [$first]"
  echo "probe: probe-1=$first (kept on upsert: $again), probe-2=$second"
done

echo "PASS: sink setup is idempotent and inbox_seq is bound per schema (${PAIRS})"
