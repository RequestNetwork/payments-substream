#!/usr/bin/env bash
# Multi-chain Substreams -> Postgres sink supervisor (D').
#
# Runs one `substreams sink postgres` child per chain in CHAINS, each in its own Postgres schema
# (DSN option schemaName=<schema>), restarts a child that exits, samples each chain's cursor
# block, and logs one JSON object per stdout line. The env contract, the per-chain resolution
# order and the event names are defined in docs/contract.md -- keep this file in step with it.
#
# Never prints the DSN, API tokens or the environment.
set -euo pipefail

# Paths are fixed relative to this script (the image installs it as /app/sinks/supervisor.sh),
# never read from the environment: whoever can set the pool's env must not choose which file is
# sourced or which package's schema is run against the database.
APP_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHAINS_ENV_FILE="$APP_DIR/sinks/chains.env"
SPKG_DIR="$APP_DIR"

# --- JSON logging -----------------------------------------------------------------------------

# json_str escapes backslash, quote, \n, \r and \t, and drops every other control character, so a
# value read from the environment can never break a line or forge a second log event.
json_str() {
  local s=${1//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  s=${s//[[:cntrl:]]/}
  printf '"%s"' "$s"
}

# log <severity> <event> [key value]... ; values matching ^-?[0-9]+$ are emitted as numbers,
# the literal "null" as null, everything else as a string.
log() {
  local severity=$1 event=$2 line
  shift 2
  line="{\"severity\":$(json_str "$severity"),\"event\":$(json_str "$event")"
  while [ "$#" -ge 2 ]; do
    if [[ $2 =~ ^-?[0-9]+$ ]] || [ "$2" = "null" ]; then
      line+=",$(json_str "$1"):$2"
    else
      line+=",$(json_str "$1"):$(json_str "$2")"
    fi
    shift 2
  done
  printf '%s}\n' "$line"
}

log INFO supervisor_started

# --- Global config ----------------------------------------------------------------------------

if [ ! -r "$CHAINS_ENV_FILE" ]; then
  log ERROR sink_config_invalid chain null field CHAINS_ENV_FILE \
    message "chain defaults file is missing"
  exit 1
fi
# shellcheck source-path=SCRIPTDIR source=chains.env
. "$CHAINS_ENV_FILE"

legacy_dsn_only=false
base_dsn=${SUBSTREAMS_SINK_DSN:-}
if [ -z "$base_dsn" ] && [ -n "${DSN:-}" ]; then
  # Legacy VM layout (docker-compose.prod.yml before the cutover): one TRON sink in `public`.
  base_dsn=$DSN
  legacy_dsn_only=true
fi

# An empty CHAINS is fatal (a worker pool would otherwise loop a successful empty process),
# except with the legacy DSN alone, where it defaults to the VM's single TRON sink.
chains_raw=${CHAINS:-}
if [ -z "${chains_raw//[[:space:],]/}" ] && [ "$legacy_dsn_only" = true ]; then
  chains_raw=tron
fi
if [ -z "${chains_raw//[[:space:],]/}" ]; then
  log ERROR sink_config_invalid chain null field CHAINS \
    message "CHAINS is empty; refusing to run a supervisor with no sinks"
  exit 1
fi
if [ -z "$base_dsn" ]; then
  log ERROR sink_config_invalid chain null field SUBSTREAMS_SINK_DSN \
    message "SUBSTREAMS_SINK_DSN is not set"
  exit 1
fi
# The sink accepts the postgres:// and psql:// schemes but rejects postgresql:// ("invalid
# scheme postgresql", verified with CLI v1.24.0); accept the common libpq spelling anyway.
if [[ $base_dsn == postgresql://* ]]; then
  base_dsn="postgres://${base_dsn#postgresql://}"
fi

ON_MODULE_HASH_MISMATCH=${ON_MODULE_HASH_MISMATCH:-warn}
SINK_MAX_RETRIES=${SINK_MAX_RETRIES:--1}
# Last-resort fallback only: each chain's confirmation depth comes from
# SINK_UNDO_BUFFER_SIZE_<CHAIN> -> <CHAIN>_UNDO_BUFFER_SIZE (chains.env) -> this value.
SINK_UNDO_BUFFER_SIZE=${SINK_UNDO_BUFFER_SIZE:-0}
SINK_PROGRESS_INTERVAL_SECONDS=${SINK_PROGRESS_INTERVAL_SECONDS:-60}
SINK_STALL_SECONDS=${SINK_STALL_SECONDS:-600}
SINK_CURSOR_READ_TIMEOUT_SECONDS=${SINK_CURSOR_READ_TIMEOUT_SECONDS:-20}

for name in SINK_MAX_RETRIES SINK_UNDO_BUFFER_SIZE SINK_PROGRESS_INTERVAL_SECONDS SINK_STALL_SECONDS \
  SINK_CURSOR_READ_TIMEOUT_SECONDS; do
  if ! [[ ${!name} =~ ^-?[0-9]+$ ]]; then
    log ERROR sink_config_invalid chain null field "$name" message "not an integer"
    exit 1
  fi
done
for name in SINK_PROGRESS_INTERVAL_SECONDS SINK_CURSOR_READ_TIMEOUT_SECONDS; do
  if [ "${!name}" -lt 1 ]; then
    log ERROR sink_config_invalid chain null field "$name" message "must be >= 1"
    exit 1
  fi
done

# --- Chain list -------------------------------------------------------------------------------

# Normalise CHAINS (trim, lowercase, drop empties) before any per-chain work so the whole-list
# rules below see the names the way the chains see them.
chains=()
IFS=',' read -r -a requested <<<"$chains_raw"
for raw in "${requested[@]}"; do
  chain=$(printf '%s' "$raw" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
  [ -n "$chain" ] || continue
  chains+=("$chain")
done

# Two writers on one schema corrupt its cursor: a duplicated chain name is fatal.
for i in "${!chains[@]}"; do
  for j in "${!chains[@]}"; do
    if [ "$j" -gt "$i" ] && [ "${chains[$j]}" = "${chains[$i]}" ]; then
      log ERROR sink_config_invalid chain "${chains[$i]}" field CHAINS reason "duplicate chain"
      exit 1
    fi
  done
done

# The legacy DSN forces every schema to `public`, so it can only ever carry the VM's one sink.
if [ "$legacy_dsn_only" = true ] && { [ "${#chains[@]}" -ne 1 ] || [ "${chains[0]}" != tron ]; }; then
  log ERROR sink_config_invalid chain null field CHAINS reason "legacy DSN supports tron only"
  exit 1
fi

# --- Per-chain resolution ---------------------------------------------------------------------

# resolve <CHAIN_KEY> <FIELD>: SINK_<FIELD>_<CHAIN> -> <CHAIN>_<FIELD> (chains.env) -> empty.
resolve() {
  local key=$1 field=$2 override default
  override="SINK_${field}_${key}"
  default="${key}_${field}"
  if [ -n "${!override:-}" ]; then
    printf '%s' "${!override}"
    return
  fi
  if [ "$field" = ENDPOINT ] && [ "$key" = TRON ] && [ -n "${SUBSTREAMS_ENDPOINTS_CONFIG_TRON:-}" ]; then
    printf '%s' "$SUBSTREAMS_ENDPOINTS_CONFIG_TRON"
    return
  fi
  if [ "$field" = SCHEMA ] && [ "$legacy_dsn_only" = true ]; then
    printf '%s' public
    return
  fi
  printf '%s' "${!default:-}"
}

# module_hash <spkg> <network>: hash of the package's db_out module for that network (the
# `Hash:` line after `Name: db_out` in `substreams info`), or empty. The hash differs per
# network because params/initialBlock do, so it must be computed with the chain's --network.
module_hash() {
  local out
  out=$(substreams info "$1" db_out --network "$2" 2>/dev/null) || return 0
  printf '%s\n' "$out" | awk '/^Name: db_out$/ { found = 1 } found && /^Hash: / { print $2; exit }'
}

chain_names=() chain_dsns=() chain_spkgs=() chain_endpoints=() chain_networks=()
chain_schemas=() chain_tokens=() chain_starts=() chain_stops=() chain_extras=()
chain_hashes=() chain_undo=()

for chain in "${chains[@]}"; do
  if ! [[ $chain =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    log ERROR sink_config_invalid chain "$chain" field CHAINS message "invalid chain name"
    continue
  fi
  key=$(printf '%s' "$chain" | tr '[:lower:]-' '[:upper:]_')

  ok=true
  for field in SPKG ENDPOINT NETWORK SCHEMA TOKEN_ENV; do
    if [ -z "$(resolve "$key" "$field")" ]; then
      log ERROR sink_config_invalid chain "$chain" field "$field"
      ok=false
    fi
  done
  [ "$ok" = true ] || continue

  spkg_name=$(resolve "$key" SPKG)
  # Only the two packages built into the image.
  if ! [[ $spkg_name =~ ^(tron|evm)$ ]]; then
    log ERROR sink_config_invalid chain "$chain" field SPKG message "package must be tron or evm"
    continue
  fi
  spkg="$SPKG_DIR/$spkg_name.spkg"
  endpoint=$(resolve "$key" ENDPOINT)
  network=$(resolve "$key" NETWORK)
  schema=$(resolve "$key" SCHEMA)
  token_env=$(resolve "$key" TOKEN_ENV)
  if [ ! -r "$spkg" ]; then
    log ERROR sink_config_invalid chain "$chain" field SPKG message "package not found"
    continue
  fi
  # The endpoint receives the API token as a bearer header, so it must be a known provider.
  if ! [[ $endpoint =~ ^[A-Za-z0-9.-]+\.(streamingfast\.io|pinax\.network):443$ ]]; then
    log ERROR sink_config_invalid chain "$chain" field ENDPOINT \
      message "endpoint must be <host>.streamingfast.io:443 or <host>.pinax.network:443"
    continue
  fi
  if ! [[ $network =~ ^[a-z0-9-]+$ ]]; then
    log ERROR sink_config_invalid chain "$chain" field NETWORK message "invalid network name"
    continue
  fi
  if ! [[ $schema =~ ^[a-z_][a-z0-9_]*$ ]]; then
    log ERROR sink_config_invalid chain "$chain" field SCHEMA message "invalid schema name"
    continue
  fi
  # A chain's schema is fixed by chains.env: an override may not point it at another chain's
  # schema (two writers on one schema corrupt its cursor). The legacy DSN-only layout is `public`.
  schema_override_var="SINK_SCHEMA_${key}" schema_default_var="${key}_SCHEMA"
  if [ "$legacy_dsn_only" = false ] && [ -n "${!schema_override_var:-}" ] &&
    [ "$schema" != "${!schema_default_var:-}" ]; then
    log ERROR sink_config_invalid chain "$chain" field SCHEMA \
      message "schema override does not match this chain's schema in chains.env"
    continue
  fi
  # The named variable is sent to the endpoint as a bearer token: only the two Substreams token
  # secrets may be named, never the DSN or any other variable.
  if ! [[ $token_env =~ ^SUBSTREAMS_API_TOKEN(_ALT)?$ ]]; then
    log ERROR sink_config_invalid chain "$chain" field TOKEN_ENV \
      message "token variable must be SUBSTREAMS_API_TOKEN or SUBSTREAMS_API_TOKEN_ALT"
    continue
  fi
  # A chain's network is intrinsic: an override may not point it at another network (e.g.
  # sepolia data written into the mainnet schema and labelled mainnet).
  default_network_var="${key}_NETWORK"
  if [ -n "${!default_network_var:-}" ] && [ "$network" != "${!default_network_var}" ]; then
    log ERROR sink_config_invalid chain "$chain" field NETWORK \
      message "network override does not match this chain's network"
    continue
  fi
  # Module params come from the package manifest only. An override could point the module at
  # another contract, and it would change the module hash the progress sampler reads.
  params_override_var="SINK_PARAMS_${key}"
  if [ -n "${!params_override_var:-}" ]; then
    log ERROR sink_config_invalid chain "$chain" field PARAMS \
      message "params come from the package manifest; SINK_PARAMS overrides are not allowed"
    continue
  fi
  # Extra sink flags are allow-listed: an override must never re-add the DSN, TLS, token,
  # params, endpoint or network flags that the supervisor owns.
  extra_var="SINK_EXTRA_ARGS_${key}"
  extra_words=()
  extra_error=''
  if [ -n "${!extra_var:-}" ]; then
    read -r -d '' -a extra_words <<<"${!extra_var}" || true
    w=0
    while [ "$w" -lt "${#extra_words[@]}" ]; do
      flag=${extra_words[$w]} value=${extra_words[$((w + 1))]:-}
      case "$flag" in
        --final-blocks-only) w=$((w + 1)); continue ;;
        --batch-block-flush-interval | --batch-row-flush-interval | --live-block-flush-interval | \
          --flush-retry-count)
          value_re='^[0-9]+$' ;;
        --flush-retry-delay) value_re='^[0-9]+(ms|s|m|h)$' ;;
        *)
          extra_error="flag not allowed: ${flag}"
          break ;;
      esac
      if ! [[ $value =~ $value_re ]]; then
        extra_error="invalid value for ${flag}"
        break
      fi
      w=$((w + 2))
    done
  fi
  if [ -n "$extra_error" ]; then
    log ERROR sink_config_invalid chain "$chain" field EXTRA_ARGS message "$extra_error"
    continue
  fi
  # Confirmation depth: rows are written only once their block is this many blocks deep, so a
  # payment in a block that is later reorged out never reaches the payments database.
  undo_override="SINK_UNDO_BUFFER_SIZE_${key}" undo_default="${key}_UNDO_BUFFER_SIZE"
  undo=${!undo_override:-${!undo_default:-$SINK_UNDO_BUFFER_SIZE}}
  if ! [[ $undo =~ ^[0-9]+$ ]]; then
    log ERROR sink_config_invalid chain "$chain" field UNDO_BUFFER_SIZE message "not a non-negative integer"
    continue
  fi
  hash=$(module_hash "$spkg" "$network")
  if [ -z "$hash" ]; then
    log ERROR sink_config_invalid chain "$chain" field NETWORK \
      message "substreams info could not resolve the db_out module hash for this network"
    continue
  fi

  if [[ $base_dsn == *\?* ]]; then sep='&'; else sep='?'; fi
  start_var="SINK_START_BLOCK_${key}"
  stop_var="SINK_STOP_BLOCK_${key}"

  chain_names+=("$chain")
  chain_dsns+=("${base_dsn}${sep}schemaName=${schema}")
  chain_spkgs+=("$spkg")
  chain_endpoints+=("$endpoint")
  chain_networks+=("$network")
  chain_schemas+=("$schema")
  chain_tokens+=("$token_env")
  chain_starts+=("${!start_var:-}")
  chain_stops+=("${!stop_var:-}")
  chain_extras+=("${extra_words[*]}")
  chain_hashes+=("$hash")
  chain_undo+=("$undo")
done

# Two chains resolving to one schema would be two writers on one cursor: refuse to start either.
for i in "${!chain_schemas[@]}"; do
  for j in "${!chain_schemas[@]}"; do
    if [ "$j" -gt "$i" ] && [ "${chain_schemas[$j]}" = "${chain_schemas[$i]}" ]; then
      log ERROR sink_config_invalid chain null field SCHEMA reason "duplicate schema"
      exit 1
    fi
  done
done

if [ "${#chain_names[@]}" -eq 0 ]; then
  log ERROR sink_config_invalid chain null field CHAINS message "no chain has a valid configuration"
  exit 1
fi

# --- Children ---------------------------------------------------------------------------------

# Per-chain loops run in background subshells; a chain reports "finished" to the sampler by
# touching $state_dir/<index>.finished.
state_dir=$(mktemp -d "${TMPDIR:-/tmp}/sink-supervisor.XXXXXX")

# pause <seconds>: interruptible sleep for the child loops (`child` is the caller's variable, so
# the TERM trap can kill it).
pause() {
  sleep "$1" &
  child=$!
  wait "$child" || true
  child=''
}

# run_chain <index>: setup with retries, then the restart loop for one chain.
run_chain() {
  local i=$1 child='' backoff=5 started code
  local chain=${chain_names[$i]}
  local -a cmd extra
  trap 'if [ -n "$child" ]; then kill -TERM "$child" 2>/dev/null; wait "$child" 2>/dev/null || true; fi; exit 0' TERM

  # Setup creates the tables inside the chain's schema. It fails until the schema exists
  # (setup-payments-db.sql / local-init.sql) or while Postgres is unreachable, so retry it with
  # the same backoff as the sink instead of giving the chain up for the container's lifetime.
  while true; do
    code=0
    # The DSN (with the sink password) goes through the environment, never argv: a process's
    # command line is world-readable inside the container, its environment is not.
    SUBSTREAMS_SINK_DSN="${chain_dsns[$i]}" substreams sink postgres setup "${chain_spkgs[$i]}" >&2 &
    child=$!
    wait "$child" || code=$?
    child=''
    [ "$code" -ne 0 ] || break
    log ERROR sink_setup_failed chain "$chain" code "$code" \
      hint "create the schema first (setup-payments-db.sql)" retry_in_seconds "$backoff"
    pause "$backoff"
    backoff=$((backoff * 2))
    if [ "$backoff" -gt 60 ]; then backoff=60; fi
  done
  backoff=5

  cmd=(substreams sink postgres "${chain_spkgs[$i]}"
    -e "${chain_endpoints[$i]}"
    --network "${chain_networks[$i]}"
    --api-token-envvar "${chain_tokens[$i]}"
    --on-module-hash-mismatch "$ON_MODULE_HASH_MISMATCH"
    --max-retries "$SINK_MAX_RETRIES"
    --undo-buffer-size "${chain_undo[$i]}"
    --prometheus-addr "127.0.0.1:$((9100 + i))")
  if [ -n "${chain_starts[$i]}" ]; then cmd+=(-s "${chain_starts[$i]}"); fi
  if [ -n "${chain_stops[$i]}" ]; then cmd+=(-t "${chain_stops[$i]}"); fi
  if [ -n "${chain_extras[$i]}" ]; then
    read -r -a extra <<<"${chain_extras[$i]}"
    cmd+=("${extra[@]}")
  fi

  while true; do
    log INFO sink_started chain "$chain" endpoint "${chain_endpoints[$i]}" \
      network "${chain_networks[$i]}" schema "${chain_schemas[$i]}" module_hash "${chain_hashes[$i]}" \
      undo_buffer_size "${chain_undo[$i]}"
    started=$SECONDS
    SUBSTREAMS_SINK_DSN="${chain_dsns[$i]}" "${cmd[@]}" &
    child=$!
    code=0
    wait "$child" || code=$?
    child=''

    if [ "$code" -eq 0 ] && [ -n "${chain_stops[$i]}" ]; then
      log INFO sink_finished chain "$chain"
      : >"$state_dir/$i.finished"
      return 0
    fi
    # A run that lasted longer than the backoff ceiling was healthy: start backing off afresh.
    if [ $((SECONDS - started)) -ge 60 ]; then backoff=5; fi
    log WARNING sink_exited chain "$chain" exit_code "$code" restart_in_seconds "$backoff"
    pause "$backoff"
    backoff=$((backoff * 2))
    if [ "$backoff" -gt 60 ]; then backoff=60; fi
  done
}

loop_pids=()
stopping=false

shutdown() {
  stopping=true
  local pid
  for pid in "${loop_pids[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
  for pid in "${loop_pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  rm -rf "$state_dir"
  exit 0
}
trap shutdown TERM INT

for i in "${!chain_names[@]}"; do
  run_chain "$i" &
  loop_pids+=("$!")
done

# --- Progress sampler -------------------------------------------------------------------------

# cursor_blocks <index>: prints "<current-hash block> <highest block>" (each "null" when absent)
# from `tools cursor read`, whose lines read `Module <hash>: Block #<num> (...) [...]`. One row
# exists per module hash that ever ran in the schema; only the current hash's row is progress.
# A read that outlasts SINK_CURSOR_READ_TIMEOUT_SECONDS gets TERM, and KILL 5 s later if it is
# still running; it prints "timeout timeout", so one slow or stuck database read never stops the
# sampler from reporting the other chains. A read that fails (non-zero exit, e.g. a refused
# connection) prints "error error", so it is never mistaken for a schema with no cursor yet.
cursor_blocks() {
  local out rc=0
  out=$(SUBSTREAMS_SINK_DSN="${chain_dsns[$1]}" timeout --kill-after=5 \
    "$SINK_CURSOR_READ_TIMEOUT_SECONDS" substreams sink postgres tools cursor read 2>/dev/null) || rc=$?
  # 124: timed out and exited on TERM; 137: still running after the grace period, killed.
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    printf 'timeout timeout\n'
    return
  fi
  if [ "$rc" -ne 0 ]; then
    printf 'error error\n'
    return
  fi
  printf '%s\n' "$out" | awk -v hash="${chain_hashes[$1]}" '
    /^Module [^:]+: Block #?[0-9]+/ {
      module = $2; sub(/:$/, "", module)
      block = $4; sub(/^#/, "", block)
      if (module == hash) current = block
      if (highest == "" || block + 0 > highest + 0) highest = block
    }
    END { print (current == "" ? "null" : current), (highest == "" ? "null" : highest) }'
}

# prev_block: the last sample of the CURRENT hash's cursor (null until it has a row). A first
# current-hash sample is a baseline, never an advance; an inherited (old-hash) block is never
# progress either -- the sink adopts it under the new hash and the next sample is the baseline.
prev_block=()
last_advance=()
for i in "${!chain_names[@]}"; do
  prev_block[i]=null
  last_advance[i]=$SECONDS
done
idle_logged=false

while true; do
  sleep "$SINK_PROGRESS_INTERVAL_SECONDS" &
  wait "$!" || true
  [ "$stopping" = false ] || break

  running=0
  for i in "${!chain_names[@]}"; do
    chain=${chain_names[$i]}
    read -r block highest <<<"$(cursor_blocks "$i")"
    if [ -e "$state_dir/$i.finished" ]; then
      # Replay done (stop block reached): the sampler keeps reporting it, never as stalled.
      case $block in timeout | error) block=null ;; esac
      log INFO sink_progress chain "$chain" block_num "$block" cursor current status finished
      continue
    fi
    running=$((running + 1))
    if [ "$block" = timeout ] || [ "$block" = error ]; then
      # Not a sample: keep the previous one and let the stall clock run.
      log WARNING sink_progress chain "$chain" block_num null cursor unreadable reason "$block" \
        timeout_seconds "$SINK_CURSOR_READ_TIMEOUT_SECONDS"
      block=null
    elif [ "$block" != null ]; then
      log INFO sink_progress chain "$chain" block_num "$block" cursor current
      if [ "${prev_block[i]}" != null ] && [ "$block" -gt "${prev_block[i]}" ]; then
        log INFO sink_progress_advanced chain "$chain" block_num "$block" \
          previous_block_num "${prev_block[i]}"
        last_advance[i]=$SECONDS
      fi
      prev_block[i]=$block
    elif [ "$highest" != null ]; then
      log INFO sink_progress chain "$chain" block_num "$highest" cursor inherited
    else
      log INFO sink_progress chain "$chain" block_num null cursor none
    fi
    stalled=$((SECONDS - last_advance[i]))
    if [ "$stalled" -ge "$SINK_STALL_SECONDS" ]; then
      log WARNING sink_stalled chain "$chain" block_num "$block" stalled_seconds "$stalled"
    fi
  done

  # Every chain finished its replay: stay alive and idle. Exiting 0 would make the worker pool
  # restart the container and replay-finish in a loop; disabling the pool is the operator's call.
  if [ "$running" -eq 0 ] && [ "$idle_logged" = false ]; then
    log INFO supervisor_idle reason all_chains_finished
    idle_logged=true
  fi
done
