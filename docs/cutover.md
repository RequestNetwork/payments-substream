# TRON sink cutover (REQ-390)

Human runbook for moving TRON payment indexing from the EasyPanel/VM Substreams sink to the
Cloud Run worker pool (`payments-substream-{env}`) backed by Cloud SQL, without losing history or
burning a full TRON replay (about 20M+ blocks from `initialBlock: 79216121`, `tron/substreams.yaml`).

**Every command below prefixed `HUMAN` is run by a person, from their own machine, with their own
credentials. Agents and CI never run these.** Stage (`request-api-stage` / `payments-substream-stage`)
goes first, end to end; only repeat on production once stage's parallel run and shadow period are
clean.

See also: `request-infrastructure/docs/RUNBOOK.md` ["Payments sink (payments-substream worker
pools)"](../../request-infrastructure/docs/RUNBOOK.md) for the Terraform-side steps (a) apply
defaults, through (j) rotate, and `docs/contract.md` for the column/identity contract this
cutover must not violate.

## 0. Prerequisites

Before touching TRON:

- `request-infrastructure` Terraform applied with `payments_sink_enabled=false` (defaults only:
  the `payments` database and the four empty secret containers exist, no worker pool yet).
- The four secret versions added (`payments-substream-{env}-dsn`,
  `payments-substream-{env}-substreams-api-token`, the `-alt` token container may stay
  version-less, `request-api-{env}-payments-database-url`) -- see RUNBOOK.md step (c).
- `scripts/setup-payments-db.sql` has been run as `postgres` against the `payments` database, and
  **both** role passwords have been set with `\password` in the same psql session (`\password
  payments_sink`, `\password payments_reader`), each a freshly generated random password of at
  least 32 characters. Never set a password with `ALTER ROLE ... PASSWORD` or a psql `-v`
  variable -- the instances run `pgaudit` with `pgaudit.log = all`, and either form lands the
  password in Cloud Logging in plaintext. Never paste a real password into this file, a commit,
  or a terminal that gets logged -- use `<pw>` placeholders everywhere below.
- The `payments-substream` image is published (RUNBOOK.md step (d)).
- `request-api` is running the build that routes TRON through `PAYMENTS_SOURCE_TRON` (REQ-385/390)
  with `PAYMENTS_DATABASE_URL` set from the secret above, and **`PAYMENTS_SOURCE_TRON` unset**
  (defaults to `hasura`, i.e. unchanged behavior) until step 5.
- EasyPanel auto-deploys for the TRON sink app are **frozen** (disable the deploy webhook / auto-
  deploy toggle) and the VM app is left running its current build. The VM sink must keep writing
  until step 1's dump is taken.
- The pool has **not** yet run `setup` for `tron`. If `payments_sink_enabled` was ever turned on
  with `tron` in `CHAINS` before this runbook's step 2 has run, the TRON sink will have created
  empty `tron.payments` / `tron.cursors` / `tron.substreams_history` tables and stored a blank
  cursor -- do **not** let it resume from there (that cursor has no history and the sink would
  stay at `initialBlock`, which step 2 treats as the "already empty" case and drops). If you are
  not sure, keep `payments_sink_enabled=false` until the import in steps 1-2 below is done.

## 1. Snapshot the VM (while the VM sink keeps running)

The VM sink must still be writing when the dump is taken -- do not stop it before this step, or
the snapshot misses payments written between stopping it and the dump.

```bash
# HUMAN -- on the EasyPanel VM, dump only the TRON sink's tables (public schema there)
docker exec <postgres-container> pg_dump -U postgres -d shared \
  --no-owner --no-privileges \
  -t public.payments -t public.cursors -t public.substreams_history \
  > ~/tron-dump.sql
```

Then move it to Cloud SQL the same way as a Fresh Database Migration
(`request-infrastructure/docs/RUNBOOK.md` L290-312):

```bash
# HUMAN -- download the dump locally
gcloud compute scp <vm-host>:~/tron-dump.sql /tmp/tron-dump.sql \
  --zone=us-central1-a --project=requestnetwork

# HUMAN -- upload to GCS
gsutil cp /tmp/tron-dump.sql gs://requestnetwork-terraform-state/db-migration/tron-dump.sql

# HUMAN -- import into the payments database on the request-api-{env} instance
# (imports into the public schema there; step 2 moves it into the tron schema)
gcloud sql import sql request-api-{env} \
  gs://requestnetwork-terraform-state/db-migration/tron-dump.sql \
  --database=payments --user=postgres --project=requestnetwork

# HUMAN -- clean up the bucket copy
gsutil rm gs://requestnetwork-terraform-state/db-migration/tron-dump.sql
```

## 2. Move the imported tables into the `tron` schema

Run `request-infrastructure/scripts/payments-tron-snapshot.sql` as `postgres`, against the
`payments` database, **after** `scripts/setup-payments-db.sql` (step 0) has already run. That
order matters: `setup-payments-db.sql` grants `payments_sink` to the executing role, which Cloud
SQL's non-superuser `postgres` needs both for `ALTER TABLE ... OWNER TO payments_sink` and for
moving tables into a schema `payments_sink` owns.

```bash
# HUMAN -- through the tunnel described in request-infrastructure/docs/DEVOPS.md
# (Option C: ephemeral VM via IAP tunnel)
psql -v ON_ERROR_STOP=1 -d payments \
  -f request-infrastructure/scripts/payments-tron-snapshot.sql
```

What it does (idempotent, safe to re-run, never rewrites `id` or `substreams_history`'s pk):

- If `tron.payments` already exists and is empty (the pool ran `setup` too early -- see step 0),
  drops the empty `tron.payments`, `tron.cursors` and `tron.substreams_history` so the imported
  dump can take their place.
- `ALTER TABLE public.payments SET SCHEMA tron` (and the same for `cursors` and
  `substreams_history`).
- `ALTER TABLE tron.<t> OWNER TO payments_sink` for all three.
- `ALTER TABLE tron.payments ADD COLUMN IF NOT EXISTS gas_used NUMERIC, ADD COLUMN IF NOT EXISTS
  gas_price NUMERIC` -- the VM dump predates these EVM-only columns (`docs/contract.md`); they
  come back `NULL` on every existing TRON row, which is correct.
- A duplicate pre-check that aborts with a clear message if
  `SELECT chain, tx_hash, log_index FROM tron.payments GROUP BY 1,2,3 HAVING count(*) > 1`
  returns any row. Only once that passes: `CREATE UNIQUE INDEX IF NOT EXISTS
  uq_payments_chain_tx_log ON tron.payments(chain, tx_hash, log_index)`.
- `CREATE INDEX IF NOT EXISTS idx_payments_chain_reference ON tron.payments(chain,
  payment_reference)`.
- `GRANT SELECT` on the three tables to `payments_reader`.

Verification (the script prints these; read the output, nothing is asserted automatically):

```sql
SELECT count(*), max(block_number) FROM tron.payments;
SELECT count(*) FROM tron.cursors;  -- expect exactly 1 row
```

If the duplicate pre-check fails, stop here -- do not create the index with duplicates present;
investigate the offending rows before continuing.

## 3. Start the TRON sink

Pool settings are persisted in git, never passed with a one-shot `-var` (request-infrastructure
`docs/RUNBOOK.md` "Payments sink", step e): open a request-infrastructure PR that sets
`payments_sink_enabled = true` in `environments/{env}/variables.tf` (`payments_substream_chains`
already defaults to `"tron"`), merge it, then:

```bash
# HUMAN -- request-infrastructure
cd environments/{stage,prod}
terraform apply
```

The pool starts on the placeholder sample image; then run the payments-substream
`deploy-worker-pool` workflow (environment `{env}`, pool `live`, the published image tag).

The TRON writer's `db_out` module changed (operation 4, REQ-385/390), so its module hash is
different from the one the VM sink stored in `cursors`. With
`ON_MODULE_HASH_MISMATCH=warn` (the supervisor default) the sink, finding no cursor row for the
new hash, resumes from the **highest-block cursor row already in that schema's `cursors` table**
(the one step 2 imported) and stores it under the new hash. Expect a module-hash mismatch
*warning* in the logs, not an error.

```bash
# HUMAN -- verify
gcloud logging read \
  'resource.type="cloud_run_worker_pool" AND resource.labels.worker_pool_name="payments-substream-{env}"' \
  --project=requestnetwork --limit=50 --freshness=15m
```

Expect `sink_progress_advanced` for `tron`, and:

```sql
SELECT id, block_num FROM tron.cursors;
```

should show a row keyed by the **new** module hash, with `block_num` at or very near the
imported block from step 2 -- not near 79216121.

**If the sink instead errors out, or starts at the initial block (`79216121`):** stop the pool at
once, before it burns block budget:

```bash
# HUMAN -- emergency stop; Terraform owns the count, so follow it with a request-infrastructure
# PR setting payments_sink_enabled = false (the next apply would otherwise restart the pool)
gcloud run worker-pools update payments-substream-{env} \
  --region=us-central1 --project=requestnetwork --instances=0
```

The failed start has already written a `tron.cursors` row keyed by the **new** module hash (a
blank cursor at `79216121`, or whatever it reached), so inserting a copy of the imported row under
that hash would collide with it. Instead, delete the bad row so the next start adopts the imported
one again. The new hash is in the `module_hash` field of the `sink_started` event the failed
start logged:

```sql
-- HUMAN -- as postgres, database payments
DELETE FROM tron.cursors WHERE id = '<new module hash>';
SELECT id, block_num FROM tron.cursors;  -- expect exactly the imported row, at the imported block
```

Then restart (PR setting `payments_sink_enabled = true`, `terraform apply`, `deploy-worker-pool`):
with `ON_MODULE_HASH_MISMATCH=warn` the sink finds no row for its hash and adopts the
highest-block row, the imported one, exactly as on a first start. Do **not** delete the rows the
failed start wrote to `tron.payments` above the imported block: upserts are idempotent and the next
run rewrites the same `id`s, so they are harmless. Leave `tron.substreams_history` untouched.
**Never let TRON replay from 79216121 during the parallel run** -- it burns the StreamingFast Free
plan's 7M blocks/month budget and stalls the live head for a chain that already has ~20M blocks of
history imported.

## 4. Parallel run (>= 24 h)

Let the VM sink and the new pool both write for at least 24 hours. Compare:

```sql
-- On the VM
SELECT count(*), max(block_number) FROM public.payments;

-- On Cloud SQL
SELECT count(*), max(block_number) FROM tron.payments;
```

The pool writes TRON blocks only once they are 20 blocks deep (`TRON_UNDO_BUFFER_SIZE`, the
confirmation depth in `sinks/chains.env`), so its `max(block_number)` trails the VM's by about 20
blocks (~1 min) by design: compare everything below `(VM max) - 20`. Then export
`(chain, tx_hash, payment_reference, log_index, amount, to_address)` for both, over
the last 5000 blocks below that bound, sort each, and diff with `comm`. Do **not** compare `id` -- TRON `id` stays
the legacy key (`docs/contract.md`) so it matches, but it is not the comparison's point; a content
diff over the columns above is what proves the two sinks agree on payments.

Also check the two known rows from
`request-api/src/utils/request.payment.tron.integration.test.ts` L27-47 (tx `d73764e9...`, ref
`0x09989861...`, amount 100, fee 1, block 79216759; tx `1997e68c...`, ref `0x07110707...`, amount
200, fee 0, block 79273752) exist identically in `tron.payments`.

Do not proceed to step 5 until the parallel run has run >= 24 h with zero unexplained diffs.

## 5. Flip request-api to Postgres

Shadow first (`DEVOPS.md` "Add a New Environment Variable" / "Restarting a Service" procedure):

```bash
# HUMAN -- stage
gcloud secrets versions access latest \
  --secret=request-api-stage-app-config --project=requestnetwork \
  | jq '. + {"PAYMENTS_SOURCE_TRON": "shadow"}' \
  | gcloud secrets versions add request-api-stage-app-config \
      --project=requestnetwork --data-file=-

gcloud run services update request-api-stage \
  --region=us-central1 --project=requestnetwork \
  --update-env-vars="RESTART_TRIGGER=$(date +%s)"
```

Also enable `payments_shadow_alert_enabled` (a request-infrastructure PR setting its default to
`true` in `environments/{env}/variables.tf`, then `terraform apply`) and watch the `payment_detection_shadow_mismatch_total`
metric for >= 24 h with **zero unexplained mismatches** (a TRON Hasura error counts as skipped,
not a mismatch -- `docs/contract.md` "shadow reads both Hasura and Postgres and acts on Hasura").

Only once that is clean:

```bash
# HUMAN -- stage
gcloud secrets versions access latest \
  --secret=request-api-stage-app-config --project=requestnetwork \
  | jq '. + {"PAYMENTS_SOURCE_TRON": "postgres"}' \
  | gcloud secrets versions add request-api-stage-app-config \
      --project=requestnetwork --data-file=-

gcloud run services update request-api-stage \
  --region=us-central1 --project=requestnetwork \
  --update-env-vars="RESTART_TRIGGER=$(date +%s)"
```

Smoke test: send (or wait for) a real TRON stage payment and confirm it is detected, then
`GET /v2/payments?paymentReference=<reference>` returns it.

Repeat this whole runbook (steps 1-5) for production only after stage has been on
`PAYMENTS_SOURCE_TRON=postgres` cleanly for a reasonable bake-in period.

## 6. Stop the VM sink

Stop (do **not** delete) the EasyPanel TRON sink app. Keep the VM Postgres instance and its data
for 14 days (step 10).

Rollback, if needed: set `PAYMENTS_SOURCE_TRON=hasura` and restart request-api, then restart the
VM sink app in EasyPanel -- it resumes from its own cursor, untouched by anything above.

## 7. Decision gate: Hasura and the SDK (owner decision, not made in this run)

Hasura's `REQUEST_PAYMENTS` source and the Request Network SDK's TRON client both read the VM's
Postgres table directly, not Cloud SQL. Once the VM sink stops (step 6), both go stale. Options,
for the owner to decide separately:

- Keep the VM sink running indefinitely, at the cost of one StreamingFast Free-plan stream.
- Accept SDK TRON staleness as a known limitation.
- A separate change to expose the Cloud SQL `tron` schema to Hasura (new data source / schema
  stitching) -- out of scope here.

**Do not drop the Hasura `REQUEST_PAYMENTS` source and do not change the SDK's TRON client as
part of this cutover.**

## 8. Sepolia and base (reference: do after TRON is stable, REQ-641/643 ordering)

These two EVM chains follow the same shadow pattern as TRON but start from a replay, not an
imported dump (no VM history to migrate).

**Stage:** use the replay pool with `SINK_START_BLOCK_<CHAIN>` set to a recent block (write the
exact block number down when you pick it -- it is this chain's fresh starting point, there is no
existing cursor to resume from) and `SINK_STOP_BLOCK_<CHAIN>` set to a block near the chain head
when you open the PR. The supervisor logs `sink_finished` only when a stop block is set; without
one the replay follows the head forever. Wait for `sink_finished`, disable the replay pool, add the
chain to `payments_substream_chains` (the live pool resumes from the replay's cursor in the same
schema), then shadow (step 5's pattern, per chain).

```hcl
# HUMAN -- stage replay: a request-infrastructure PR editing environments/stage/variables.tf
#   payments_replay_enabled = true
#   payments_replay_env     = { CHAINS = "<chain>", SINK_START_BLOCK_<CHAIN> = "<recent-block>",
#                               SINK_STOP_BLOCK_<CHAIN> = "<block near the head>" }
# merge, `terraform apply`, then deploy-worker-pool (pool: replay) with the published tag.
```

**Prod:** replay from the deployment block in `evm/chains.yaml`/`docs/contract.md`
(sepolia 4733364, base 10827274). Quota reality: base's replay is roughly 26M blocks, more than
the StreamingFast Free plan's 7M blocks/month, so it needs a second provider or a paid plan. The
prod Free token's 2 concurrent streams are occupied by the VM TRON sink and the pool's TRON
stream until the VM sink stops (step 6) -- until then, run EVM chains with
`SINK_TOKEN_ENV_<CHAIN>=SUBSTREAMS_API_TOKEN_ALT` (once the `-alt` secret has a version and
`payments_alt_token_enabled=true`) or wait for a free stream slot.

```hcl
# HUMAN -- prod replay: a request-infrastructure PR editing environments/prod/variables.tf
#   payments_replay_enabled = true
#   payments_replay_env     = { CHAINS = "base", SINK_START_BLOCK_BASE = "10827274",
#                               SINK_STOP_BLOCK_BASE = "<block near the head>",
#                               SINK_TOKEN_ENV_BASE = "SUBSTREAMS_API_TOKEN_ALT" }
# merge, `terraform apply`, then deploy-worker-pool (pool: replay) with the published tag.
# <CHAIN> in variable names is the chain uppercased, hyphens to underscores (docs/contract.md).
```

After `sink_finished`, add the chain to `payments_substream_chains` and shadow it, same as TRON
step 5. The replay pool must be disabled before the live pool lists that chain
(request-infrastructure's invariant: a chain is listed in exactly one pool at a time; its plan
fails if both pools list the same chain).

## 9. Rotation

The Substreams API token, the Hasura admin/JWT secrets and the TRON sink's VM database password
were shared in plaintext at some point before this cutover. Rotate:

- The Substreams API token, **right after the VM sink stops** (step 6) -- not before, since the
  VM sink still needs its current token until then. Add the new token as a new secret version, then
  roll a new revision so the pool reads `latest`: re-run the payments-substream
  `deploy-worker-pool` workflow with the currently deployed image tag. (Do not set ad-hoc env vars
  on the pool with gcloud: Terraform owns its env and would revert them.)
- The Hasura admin secret and JWT secret -- tracked separately, REQ-642.

Never reuse an EasyPanel-era value (token, password) in Secret Manager -- issue fresh ones.

## 10. Cleanup (after the 14-day retention in step 6)

- Delete the EasyPanel TRON sink app.
- Remove its deploy webhooks.
- Remove the `EASYPANEL_DEPLOY_KEY_*` repo secrets that targeted it.
- Update this repo's README to note the TRON sink now runs on the `payments-substream-{env}`
  worker pool, not EasyPanel.
