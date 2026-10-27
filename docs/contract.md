# Payments sink contract (D')

This is the contract between the Substreams sinks (`tron/`, `evm/`), the Postgres schema
(`schema.sql`), and the request-api readers that consume it. It is the source of truth for
column formats, identity rules, physical layout, verified contract addresses, and the
supervisor/request-api env contracts. Code must match this file; if they disagree, fix the code.

## Column contract

`schema.sql` (root) is authoritative; `evm/schema.sql` and `tron/schema.sql` are generated
byte-identical copies (`make sync-schema` / `make check-schema` in `evm/` and `tron/`).

- `timestamp`: unix seconds.
- `amount`, `fee_amount`, `gas_used`, `gas_price`: decimal strings, stored as `NUMERIC`.
- `payment_reference`: `0x` + 64 lowercase hex characters of `topics[1]` -- this is already the
  keccak256 hash of the event's indexed `bytes` argument (see `tron/src/lib.rs` L197) and must
  never be hashed again.
- EVM: `contract_address`, `token_address`, `from_address`, `to_address`, `fee_address` and
  `tx_hash` are lowercase `0x`.
- TRON: addresses are Base58 and `tx_hash` is hex without `0x` (unchanged from the existing TRON
  sink).
- `log_index`: index of the log within the transaction. TRON: `tron/src/lib.rs` L66
  `enumerate()` order over `info.log`. EVM: the receipt log index within the transaction.
- `energy_used`, `energy_fee`, `net_fee`: TRON-only, `NULL` on EVM chains.
- `gas_used`, `gas_price`: EVM-only, `NULL` on TRON.
- `inbox_seq`: `BIGINT` per-schema insert cursor (`DEFAULT nextval`), `NULL` on rows inserted
  before it existed, set once, never updated on conflict; gaps are normal; it is an arrival cursor,
  not a block cursor. A backfill or replay can insert an older block after newer ones and a reader
  tailing `inbox_seq` still sees it. Readers treat `NULL` as 'no cursor position' and cover those
  rows by reference. Partial index `idx_payments_inbox_seq`.
  - **Visibility is not strictly ordered.** A value is allocated when the row is inserted but only
    becomes visible when its transaction commits. With one sink writing a schema (the normal state;
    a block is one transaction) commits land in `inbox_seq` order, so a cursor over it is gap-free.
    Nothing enforces a single writer, though: while two sink processes overlap on one schema, for
    example during a worker-pool rollout, a transaction still in progress can hold a lower value
    than rows that are already committed, and no filter a reader can apply to visible rows (a
    numeric margin, or comparing each row's `xmin` with the snapshot horizon) reveals that hidden
    value. A consumer must therefore not treat `inbox_seq` as gap-free while writers can overlap:
    make re-reads idempotent on `(chain, tx_hash, log_index)`, re-scan behind the position already
    consumed, and keep the periodic reference sweep as the completeness backstop. A gap-free
    boundary under overlapping writers needs single-writer enforcement or a commit-ordered source;
    that is decided with the consumer (REQ-823), not here.

## Identity

- The physical primary key is `id` (`TEXT`).
- TRON `id` stays the legacy key `chain:tx_hash:payment_reference:log_index`
  (`tron/src/lib.rs` L113), so imported VM rows and live sink rows upsert in place.
- EVM `id` is the short key `chain:tx_hash:log_index` (REQ-385).
- `uq_payments_chain_tx_log` (`UNIQUE (chain, tx_hash, log_index)`) is what forbids two different
  `id` shapes from referring to the same log.
- Readers must look up rows by `payment_reference`, `tx_hash`, or wallet address -- never by `id`.
- `inbox_seq` is never an identity, only a cursor.

## Physical layout

One Postgres schema per chain, named by the request-api chain name with hyphens converted to
underscores: `tron`, `sepolia`, `base`, `mainnet`, `matic`, `bsc`, `arbitrum_one`, `optimism`.
The schema is selected with the sink DSN option `schemaName=<schema>`, because the sink's
`cursors` / `substreams_history` bookkeeping tables are per schema and reorg prune/revert is
keyed by block number only (no chain column) -- mixing chains into one schema would corrupt
cursor/revert bookkeeping across chains.

## Verified ERC20FeeProxy deployments

All chains share one `topic0`:
`0x9f16cbcc523c67a60c450e5ffe4f3b7b6dbe772e7abcadb2686ce029a9a0a2b6`
(`TransferWithReferenceAndFee(address,address,uint256,bytes,uint256,address)`).

| chain | address(es) | initial block |
|---|---|---|
| mainnet | `0x370DE27fdb7D1Ff1e1BaA7D11c5820a324Cf623C` (only live mainnet proxy) | 10774767 |
| matic | `0x2171a0dc12a9E5b1659feF2BB20E54c84Fa7dB0C`, `0x0DfbEe143b42B41eFC5A6F87bFD1fFC78c2f0aC9` | 14163521 (first), second @ 17427742 |
| bsc | `0x0DfbEe143b42B41eFC5A6F87bFD1fFC78c2f0aC9` | 11540173 |
| arbitrum-one | `0x0DfbEe143b42B41eFC5A6F87bFD1fFC78c2f0aC9` | 5309741 |
| base | `0x1892196E80C4c17ea5100Da765Ab48c1fE2Fb814` | 10827274 |
| optimism | `0x399F5EE127ce7432E4921a61b8CF52b0af52cbfE` | 34638633 |
| sepolia | `0x399F5EE127ce7432E4921a61b8CF52b0af52cbfE` | 4733364 |
| tron | `TCUDPYnS9dH3WvFEaE7wN7vnDa51J4R4fd` (hex `0x1b6ca35d39842cf8fbe49000653a1505412da659`) | 79216121 |

Indexers must filter on address **and** `topic0`: delegatecalling contracts (conversion proxy,
escrow, transferable receivable) emit the same `topic0` and must stay on Hasura, not this sink.

EVM module params format: `chain=<request-api name>;addresses=<comma-separated lowercase 0x>`
(see `evm/chains.yaml`; the values live in the `networks:` section of `evm/substreams.yaml`).

## request-api routing rule

A request routes to this sink only when its extension key starting with `pn-` equals
`pn-erc20-fee-proxy-contract` on a chain in `src/constants/chains.ts`
`PayeeDestinationNetworkName` (`mainnet`, `arbitrum-one`, `optimism`, `base`, `matic`, `bsc`,
`sepolia`, `tron`). It then uses `PAYMENTS_SOURCE_<CHAIN>` (uppercase, hyphens to underscores)
= `hasura` | `shadow` | `postgres`.

- Missing key, any other key, `nile`, an unknown chain, or an unset/invalid flag -> `hasura`.
- `shadow` reads both Hasura and Postgres and acts on Hasura.
- A Postgres row confirms a request only when its non-empty `to_address` equals that request's
  own non-empty payee (EVM: case-insensitive; TRON: exact match). Fee-leg requests need no
  special case, because request-api creates them with the fee recipient as their payee. The zero
  address never matches. A same-reference transfer to the payer (escrow refund/void) is never a
  payment.

## Supervisor env contract (wave 3)

The image entrypoint (`sinks/entrypoint.sh`, run by `/bin/sh`) passes the supervisor only these
variables: `CHAINS`, `SUBSTREAMS_SINK_DSN`, `DSN`, `SUBSTREAMS_API_TOKEN`,
`SUBSTREAMS_API_TOKEN_ALT`, `SUBSTREAMS_ENDPOINTS_CONFIG_TRON`, `ON_MODULE_HASH_MISMATCH` and
`SINK_*`. It also pins `PATH`, `HOME` and `TMPDIR`. Everything else set on the pool is dropped
before bash starts, so bash startup variables (`SHELLOPTS`, `PS4`, `BASH_ENV`, `BASH_FUNC_*`) can
never trace the DSN or run code. A new variable must be added to that allow-list.

- `CHAINS`: comma-separated chain list to run.
- `SUBSTREAMS_SINK_DSN`: the base DSN (scheme `postgres://` or `psql://`; `postgresql://` is normalised to `postgres://` because the Substreams CLI rejects it). The supervisor appends `schemaName=<schema>` per chain and passes it to every child through the environment, never argv. Legacy `DSN` is accepted for back-compat (tron in `public` only).
- `SUBSTREAMS_API_TOKEN`, optional `SUBSTREAMS_API_TOKEN_ALT`.
- `ON_MODULE_HASH_MISMATCH` default `warn`.
- `SINK_MAX_RETRIES` default `-1`.
- Confirmation depth per chain (`--undo-buffer-size`): `SINK_UNDO_BUFFER_SIZE_<CHAIN>` → `<CHAIN>_UNDO_BUFFER_SIZE` (image defaults in sinks/chains.env: mainnet/sepolia 12, matic 64, bsc 15, arbitrum-one 40, base/optimism/tron 20) → `SINK_UNDO_BUFFER_SIZE` (last-resort fallback, default `0`). Deployed depths come from request-infrastructure `environments/{stage,prod}/variables.tf:91-98` (`SINK_UNDO_BUFFER_SIZE_MAINNET` and `_SEPOLIA` = 1, every other chain = 3). A block's rows are written only once it is that many blocks deep, so payments in reorged-out blocks never reach the database (the sink's in-database reorg undo is then not used); detection latency grows by about depth × block time.
  - **Accepted risk: L2 depths are not L1 finality.** The deployed L2 depth is 3 blocks, accepted 20 Oct as equal to Hasura's zero depth; REQ-688 tracks the fix. A block can still be that deep before its batch is final on Ethereum, so a rare sequencer reorg could still drop a payment that was already written.
- `SINK_PROGRESS_INTERVAL_SECONDS` default `60`.
- `SINK_STALL_SECONDS` default `600`: a chain whose cursor block has not advanced for this long
  logs `sink_stalled` on every sampling interval until it advances again.
- `SINK_CURSOR_READ_TIMEOUT_SECONDS` default `20`: bound on each `tools cursor read`. A read that
  hits it logs `sink_progress{cursor:"unreadable", reason:"timeout", block_num:null}` (severity
  WARNING), and a read that fails outright (non-zero exit, e.g. a refused connection) logs the same
  with `reason:"error"`; `cursor:"none"` only ever means a successful read found no cursor. Either
  way the event is for that chain only; the sampler goes on with the other chains, and the stall
  clock keeps running.
- Per chain: `SINK_ENDPOINT_<CHAIN>`, `SINK_NETWORK_<CHAIN>`,
  `SINK_START_BLOCK_<CHAIN>`, `SINK_STOP_BLOCK_<CHAIN>`, `SINK_SCHEMA_<CHAIN>`,
  `SINK_TOKEN_ENV_<CHAIN>`, `SINK_EXTRA_ARGS_<CHAIN>`.
- Legacy `SUBSTREAMS_ENDPOINTS_CONFIG_TRON` is honoured for `tron`.
- `<CHAIN>` = chain name uppercased, hyphens converted to underscores.

### Defaults and resolution order

`sinks/chains.env` holds the per-chain DEFAULTS, named `<CHAIN>_<FIELD>` (chain first, the reverse
of the `SINK_<FIELD>_<CHAIN>` runtime overrides): `<CHAIN>_ENDPOINT`, `<CHAIN>_NETWORK`,
`<CHAIN>_SCHEMA`, `<CHAIN>_SPKG`, `<CHAIN>_TOKEN_ENV`. Module params have no default in
`sinks/chains.env`: they come from the manifests (the `params:` block of `tron/substreams.yaml`;
the per-network `networks:` section of `evm/substreams.yaml`, selected with `--network`), and
there is no params override (see "Supervisor behaviour"). For each of those fields the supervisor
resolves the value as:

1. `SINK_<FIELD>_<CHAIN>` (runtime override from the supervisor env), else
2. `<CHAIN>_<FIELD>` (default from `sinks/chains.env`), else
3. error -- the supervisor refuses to start that chain.

The start block has no default in either place. Each module's start is its per-network
`initialBlock` in the manifest (`networks:` in `evm/substreams.yaml`; `initialBlock: 79216121`
in `tron/substreams.yaml`), and the sink starts there whenever its schema has no cursor; with a
cursor it resumes from the cursor. `SINK_START_BLOCK_<CHAIN>` (and `SINK_STOP_BLOCK_<CHAIN>`)
exist only for replays and recent-window runs, never for normal operation.
`sinks/chains.env` deliberately carries no `<CHAIN>_INITIAL_BLOCK` copy: the manifest is
authoritative and the deployment table above already documents the blocks, so a third copy
would only add a value that can drift.
- JSON log events (one JSON object per stdout line, field `event`): `supervisor_started` (once per
  container start; counts restarts even when a crash writes nothing else), `sink_started`
  (includes `module_hash`, the chain's current `db_out` hash), `sink_exited`, `sink_finished`,
  `sink_setup_failed`, `sink_config_invalid`, `sink_progress` (every chain, every sampling
  interval — its absence means the pool is silent), `sink_progress_advanced`, `sink_stalled`,
  `supervisor_idle`. request-infrastructure's payments-sink-alerts module builds its log-based
  metrics on `supervisor_started`, `sink_exited`, `sink_stalled` and `sink_progress`.

### Supervisor behaviour

- Whole-list rules (fatal, exit 1): a `CHAINS` list that contains the same chain twice after
  normalisation (`sink_config_invalid{field:"CHAINS", reason:"duplicate chain"}` -- two writers on
  one schema corrupt its cursor); with only the legacy `DSN` set, every schema is `public`, so the
  only accepted chain set is exactly `tron` (`CHAINS` unset or `tron`), anything else is
  `sink_config_invalid{chain:null, field:"CHAINS", reason:"legacy DSN supports tron only"}`.
  Two chains that resolve to the same schema are also fatal for both:
  `sink_config_invalid{chain:null, field:"SCHEMA", reason:"duplicate schema"}`, exit 1.
  Per-chain config errors still skip only that chain; the supervisor exits 1 only when no chain
  has a valid configuration.
- Per-chain override validation (each failure logs `sink_config_invalid{chain, field, message}`
  and skips only that chain):
  - `ENDPOINT` (override, chains.env or legacy `SUBSTREAMS_ENDPOINTS_CONFIG_TRON`) receives the
    API token as a bearer header, so it must be a known provider host on port 443:
    `<host>.streamingfast.io:443` or `<host>.pinax.network:443` (no scheme). `NETWORK` must match
    `^[a-z0-9-]+$` and equal the chain's `<CHAIN>_NETWORK`.
  - `TOKEN_ENV` must be `SUBSTREAMS_API_TOKEN` or `SUBSTREAMS_API_TOKEN_ALT`: the named variable
    is sent to the endpoint, so it can never name the DSN or any other variable.
  - `SPKG` must be `tron` or `evm`, the two packages built into the image. `chains.env` and the
    packages are read from paths fixed relative to the supervisor (`/app` in the image), never
    from the environment.
  - `SCHEMA`: with `SUBSTREAMS_SINK_DSN`, a `SINK_SCHEMA_<CHAIN>` override must equal the chain's
    `<CHAIN>_SCHEMA` in `sinks/chains.env` (a chain never writes another chain's schema). The
    legacy `DSN`-only layout (`public`) is exempt.
  - `PARAMS`: `SINK_PARAMS_<CHAIN>` is rejected for every chain. The chain label, contract
    addresses and TRON proxy come from the manifest only. An override could only point the module
    at another contract, and it would change the module hash the progress sampler reads.
  - `EXTRA_ARGS`: `SINK_EXTRA_ARGS_<CHAIN>` is split on whitespace (newlines included) and only
    these flags are accepted, each as separate words: `--final-blocks-only`,
    `--batch-block-flush-interval <int>`, `--batch-row-flush-interval <int>`,
    `--live-block-flush-interval <int>`, `--flush-retry-count <int>`,
    `--flush-retry-delay <duration>` (`<int>` plus `ms`, `s`, `m` or `h`, e.g. `500ms`). Anything
    else (`--dsn`, `--plaintext`, `--insecure`, `--api-token-envvar`, `--params`, `--flag=value`
    forms, ...) is rejected.
- Log safety: every JSON string value escapes `\`, `"`, `\n`, `\r` and `\t` and drops any other
  control character, so no env value can split a log line or forge an event the alerts count.
- Setup is per chain and retried: `substreams sink postgres setup` runs inside each chain's own
  loop with the sink's backoff (5 s doubling to 60 s), logging
  `sink_setup_failed{chain,code,hint,retry_in_seconds}` on every failure, while the other chains
  run. The chain's sink starts as soon as its setup succeeds (for example once the schema exists).
- Module hash: at start the supervisor computes each chain's current `db_out` hash with
  `substreams info <spkg> db_out --network <network>` (the hash differs per network). Progress is
  read from the `cursors` row of exactly that hash. `sink_progress` carries `cursor:"current"`
  when that row exists, `cursor:"inherited"` with the highest row's block before it does (first
  start, or right after a module-hash change before the sink stored its adopted cursor), and
  `cursor:"none"` with `block_num:null` when the schema has no cursor at all.
  `sink_progress_advanced` fires only when the current-hash block strictly increases versus the
  previous current-hash sample (the first sample is a baseline, never an advance; inherited
  blocks never count). `sink_stalled{chain,block_num,stalled_seconds}` uses the current-hash
  block (`null` before it exists) and the time since the last advance (or since boot).
- Finished replays: after `sink_finished` (stop block set, sink exited 0) the chain is done: it
  keeps appearing in `sink_progress` with `status:"finished"` but never in `sink_stalled` or
  `sink_progress_advanced`. When every chain has finished, the supervisor logs
  `supervisor_idle{reason:"all_chains_finished"}` once, writes `/tmp/payments-sink-idle` (so the image's
  healthcheck, `sinks/healthcheck.sh`, reports it healthy) and stays alive idle (still handling TERM)
  rather than exiting 0, which would make the worker pool restart it and replay-finish in a loop.

## request-api config contract

- Secret `request-api-{env}-payments-database-url` -> env var `PAYMENTS_DATABASE_URL`.
- App-config keys: `PAYMENTS_SOURCE_MAINNET`, `PAYMENTS_SOURCE_ARBITRUM_ONE`,
  `PAYMENTS_SOURCE_OPTIMISM`, `PAYMENTS_SOURCE_BASE`, `PAYMENTS_SOURCE_MATIC`,
  `PAYMENTS_SOURCE_BSC`, `PAYMENTS_SOURCE_SEPOLIA`, `PAYMENTS_SOURCE_TRON`.

## Quota note

StreamingFast Free tier is 7M blocks/month and 2 concurrent streams per token. The VM TRON sink
holds one stream per environment until cutover; a base replay from the TRON deployment block is
about 26M blocks. Provider and token selection are per-chain env config (`sinks/chains.env` +
supervisor env), never code.
