# Request Network Payments Substream

Substreams modules for indexing Request Network ERC20FeeProxy payment events across multiple blockchain networks: `tron/` (TRON) and `evm/` (one package for every EVM chain, selected with `--network`). A multi-chain supervisor (`sinks/supervisor.sh`) runs one `substreams sink postgres` per chain into its own Postgres schema. `docs/contract.md` is the source of truth for the schema, layout and env contract.

## Prerequisites

- [Rust](https://rustup.rs/) with `wasm32-unknown-unknown` target
- [Substreams CLI](https://substreams.streamingfast.io/getting-started/installing-the-cli)
- [Docker](https://docs.docker.com/get-docker/) and Docker Compose
- [Buf CLI](https://buf.build/product/cli) (for protobuf generation)
- [Streamingfast API Token](https://app.streamingfast.io/)

### Install Rust WASM target

```bash
rustup target add wasm32-unknown-unknown
```

### Install Substreams CLI

```bash
# macOS
brew install streamingfast/tap/substreams

# Linux (pinned to the version the sink image uses; verify the sha256 from the release's checksums.txt)
curl -sSLO https://github.com/streamingfast/substreams/releases/download/v1.24.0/substreams_linux_x86_64.tar.gz
echo "8ed58a785c00657fb71c7bc390b781357cd13e415497e4b4f016a9e315d751a6  substreams_linux_x86_64.tar.gz" | sha256sum -c -
tar xzf substreams_linux_x86_64.tar.gz substreams
sudo mv substreams /usr/local/bin/
```

### Install Buf CLI

```bash
brew install bufbuild/buf/buf
```

## Project Structure

```
payments-substream/
├── schema.sql                     # PostgreSQL schema (authoritative; edit this one)
├── rust-toolchain.toml            # Pinned Rust toolchain (1.93.0 + wasm32)
├── tron/                          # TRON substream module
│   ├── src/
│   │   ├── lib.rs                 # Main substream logic
│   │   └── pb/                    # Generated protobuf code (committed)
│   ├── proto/
│   │   └── request/tron/v1/
│   │       └── payments.proto     # Payment message definitions
│   ├── schema.sql                 # Generated copy of ../schema.sql (make sync-schema)
│   ├── schema.graphql             # GraphQL schema (for future use)
│   ├── substreams.yaml            # Substream manifest
│   ├── Cargo.toml                 # Rust dependencies
│   └── Makefile                   # Build commands
├── evm/                           # EVM substream module (same layout; chains.yaml per-chain config)
├── sinks/
│   ├── entrypoint.sh              # Image entrypoint: allow-listed env, then supervisor.sh
│   ├── supervisor.sh              # Multi-chain sink supervisor
│   ├── chains.env                 # Per-chain defaults (endpoint, network, schema, package, token env)
│   └── local-init.sql             # Creates the per-chain schemas for local docker compose
├── docs/
│   ├── contract.md                # Schema/layout/env contract
│   └── cutover.md                 # VM -> GCP cutover runbook
├── docker-compose.yml             # Local development setup
├── docker-compose.prod.yml        # Legacy Easypanel VM sink (frozen, retired at cutover)
├── Dockerfile.sink                # Sink image (both packages + supervisor)
└── .env.example                   # Environment variables template
```

## Development

### 1. Make Changes to the Substream

#### Modify the Rust Code

Edit `tron/src/lib.rs` to change payment parsing logic:

```rust
// Example: Add new field extraction
fn parse_transfer_with_reference_and_fee(...) -> Option<Payment> {
    // Your parsing logic here
}
```

#### Update Protobuf Messages

Edit `tron/proto/request/tron/v1/payments.proto`:

```protobuf
message Payment {
  string token_address = 1;
  // Add new fields here
  string new_field = 13;
}
```

After changing `.proto` files, regenerate the Rust code:

```bash
cd tron
make protogen
```

#### Update SQL Schema

Edit the ROOT `schema.sql` only. `tron/schema.sql` and `evm/schema.sql` are generated copies:
refresh them with `make sync-schema` in each package (`make package` does it too; CI and the
image build fail when they differ). Never hand-edit the copies.

```sql
ALTER TABLE payments ADD COLUMN new_field TEXT;
```

### 2. Build the Substream

```bash
cd tron

# Build WASM module
make build

# Run unit tests
make test

# Package into .spkg file
make package
```

### 3. Run the Stream Locally

Test the substream against live blockchain data without a database:

```bash
cd tron

# Set your API token
export SUBSTREAMS_API_TOKEN="your-token-here"

# Run against TRON mainnet (100 blocks from deployment)
substreams run ./request-network-tron-v0.2.0.spkg \
  map_erc20_fee_proxy_payments \
  -e mainnet.tron.streamingfast.io:443 \
  --start-block 79216121 \
  --stop-block +100
```

#### Output Options

```bash
# JSON output (for debugging)
substreams run ... -o json

# Protobuf output (default)
substreams run ... -o proto
```

### 4. Run the Sink Locally (with PostgreSQL)

Test the full pipeline with a local PostgreSQL database:

#### Start Local Services

```bash
# Create .env file
cp .env.example .env

# Edit .env with your values
# SUBSTREAMS_API_TOKEN=your-token
# POSTGRES_PASSWORD=your-password

# Start PostgreSQL and the sink supervisor (CHAINS defaults to tron).
# sinks/local-init.sql creates the per-chain schemas on a fresh volume.
docker compose up -d

# View logs
docker compose logs -f sink
```

#### Query Local Database

```bash
# Connect to PostgreSQL
docker exec -it payments-db psql -U postgres -d payments

# Query payments (one schema per chain)
SELECT * FROM tron.payments LIMIT 10;
SELECT block_num FROM tron.cursors;
```

#### Stop Local Services

```bash
docker compose down

# Remove data volumes (fresh start)
docker compose down -v
```

The compose file now uses the `payments_pg17_data` volume (postgres:17). If you ran the old
postgres:15 setup, its `postgres_data` volume is left untouched and can be removed manually
(`docker volume ls`, then `docker volume rm <project>_postgres_data`).

## Configuration

### Substream Parameters

Parameters are configured in `tron/substreams.yaml`:

```yaml
params:
  map_erc20_fee_proxy_payments: |
    mainnet_proxy_address=TCUDPYnS9dH3WvFEaE7wN7vnDa51J4R4fd
    chain=tron
```

| Parameter | Description | Example |
|-----------|-------------|---------|
| `mainnet_proxy_address` | ERC20FeeProxy contract address | `TCUDPYnS9dH3WvFEaE7wN7vnDa51J4R4fd` |
| `chain` | Chain identifier for multi-chain support | `tron`, `ethereum`, `polygon` |

EVM chains take their params and initial block from the `networks:` section of
`evm/substreams.yaml`, selected with `--network`.

### Environment Variables (sink supervisor)

The full contract is in `docs/contract.md`; the supervisor implements it.

| Variable | Default | Description |
|----------|---------|-------------|
| `CHAINS` | none | Comma-separated chains to run (e.g. `tron,base`). Empty is fatal. |
| `SUBSTREAMS_SINK_DSN` | none | Base Postgres DSN; the supervisor appends `schemaName=<schema>` per chain. |
| `DSN` | none | Legacy DSN. When it is the only DSN set, every chain's schema defaults to `public` and `CHAINS` defaults to `tron` (the VM layout). |
| `SUBSTREAMS_API_TOKEN` | none | StreamingFast API token (`SUBSTREAMS_API_TOKEN_ALT` optional, selected per chain via the token env). |
| `ON_MODULE_HASH_MISMATCH` | `warn` | Passed to the sink; `warn` adopts the stored cursor under a new module hash. |
| `SINK_MAX_RETRIES` | `-1` | Sink retries (`-1` = infinite). |
| `SINK_UNDO_BUFFER_SIZE` | `0` | `0` keeps reorg handling in the database. |
| `SINK_PROGRESS_INTERVAL_SECONDS` | `60` | Cursor sampling interval. |
| `SINK_STALL_SECONDS` | `600` | No cursor advance for this long logs `sink_stalled`. |
| `POSTGRES_PASSWORD` | none | PostgreSQL password (local dev compose only) |

Per-chain overrides (`<CHAIN>` = chain name uppercased, hyphens to underscores):
`SINK_ENDPOINT_<CHAIN>`, `SINK_NETWORK_<CHAIN>`, `SINK_SCHEMA_<CHAIN>`, `SINK_TOKEN_ENV_<CHAIN>`,
`SINK_PARAMS_<CHAIN>` (TRON only, passed as `--params` only when set), `SINK_START_BLOCK_<CHAIN>` /
`SINK_STOP_BLOCK_<CHAIN>` (replays only), `SINK_EXTRA_ARGS_<CHAIN>` (word-split extra flags,
allow-listed: only the flush/batch flags and `--final-blocks-only`). Overrides are validated
(schema must equal chains.env, TRON params keep one `chain=` and the manifest proxy address,
the endpoint is a `streamingfast.io` or `pinax.network` host on port 443, the token variable is
`SUBSTREAMS_API_TOKEN` or `SUBSTREAMS_API_TOKEN_ALT`, the package is `tron` or `evm`); see
`docs/contract.md` "Supervisor behaviour" for the rules.
The legacy `SUBSTREAMS_ENDPOINTS_CONFIG_TRON` is still honoured for `tron`. Each field resolves
`SINK_<FIELD>_<CHAIN>` -> `<CHAIN>_<FIELD>` in `sinks/chains.env` -> error (the chain is skipped
with `sink_config_invalid`). There is no default start block: without a cursor a chain starts at
its manifest `initialBlock`, otherwise it resumes from the cursor.

The supervisor logs one JSON object per stdout line, field `event`: `supervisor_started`,
`sink_started`, `sink_exited`, `sink_finished`, `sink_setup_failed`, `sink_config_invalid`,
`sink_progress`, `sink_progress_advanced`, `sink_stalled`. request-infrastructure's alerts are
built on these names; do not rename them. It never logs the DSN, tokens or the environment.

## Deployment

The sink runs as a GCP Cloud Run **worker pool** (one live pool per environment, plus an optional
replay pool). The Easypanel VM sink (`docker-compose.prod.yml`) is frozen and retired at the
REQ-390 cutover: its deploy workflows no longer run on push/release and refuse to run unless
`confirm_vm_redeploy=I_UNDERSTAND`. Follow `docs/cutover.md` for the VM -> GCP cutover.

### 1. Build the image (`.github/workflows/image.yml`)

- Pull requests touching the sink build `Dockerfile.sink` and smoke-test it (no push).
- Pushes to `main` and `v*` tags push `ghcr.io/requestnetwork/payments-substream:<full sha>`
  plus `main` or the tag. There is no `latest` tag.

### 2. Deploy to a worker pool (`.github/workflows/deploy-worker-pool.yml`)

Run it manually (workflow_dispatch) with:

- `environment`: `stage` or `production`
- `pool`: `live` (`payments-substream-<env>`) or `replay` (`payments-substream-replay-<env>`)
- `image_tag`: the GHCR tag to deploy (a full commit sha, `main`, or a release tag)

It authenticates with Workload Identity Federation, copies the image from GHCR to
`us-central1-docker.pkg.dev/<project>/request-docker/payments-substream:<tag>`, and runs
`gcloud run worker-pools update ... --image=...`. It needs the repository secrets
`GCP_WIF_PROVIDER`, `GCP_SA_EMAIL` and `GCP_PROJECT_ID`.

### 3. Terraform owns the pool

The worker pools, their env (`CHAINS`, per-chain overrides, the DSN and token secrets) and their
instance count are defined in request-infrastructure (`payments_sink_enabled=true`). The deploy
workflow only changes the image and never sets `--instances`. The per-chain Postgres schemas are
created by request-infrastructure `scripts/setup-payments-db.sql`; the supervisor does not create
schemas (a missing schema logs `sink_setup_failed`).

### Manual run

```bash
docker build -f Dockerfile.sink -t payments-sink .

docker run -d \
  -e CHAINS=tron \
  -e SUBSTREAMS_SINK_DSN="postgres://<user>:<password>@<host>:5432/payments?sslmode=disable" \
  -e SUBSTREAMS_API_TOKEN="<token>" \
  payments-sink
```

## GraphQL API (Hasura)

> **Transitional.** Hasura over the VM database is what request-api reads today. After the
> REQ-390 cutover request-api reads the per-chain Postgres schemas directly
> (`PAYMENTS_SOURCE_<CHAIN>`, see `docs/contract.md`) and this section goes away.

The PostgreSQL database is exposed via Hasura, providing a GraphQL API for the Request Network SDK to query payments.

### Architecture

```
┌─────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│    TRON     │────▶│  Substream   │────▶│  PostgreSQL  │────▶│    Hasura    │
│  Blockchain │     │    Sink      │     │  (payments)  │     │   GraphQL    │
└─────────────┘     └──────────────┘     └──────────────┘     └──────┬───────┘
                                                                     │
                                                                     ▼
                                                             ┌──────────────┐
                                                             │ Request SDK  │
                                                             │  (payment    │
                                                             │  detection)  │
                                                             └──────────────┘
```

### GraphQL Endpoint

- **Staging**: `https://graphql.stage.request.network/v1/graphql`
- **Production**: `https://graphql.request.network/v1/graphql`

### Example Query

```graphql
query GetPayments($reference: String!, $chain: String) {
  payments(
    where: {
      payment_reference: { _eq: $reference }
      chain: { _eq: $chain }
    }
    order_by: { block_number: asc }
  ) {
    id
    chain
    tx_hash
    block_number
    timestamp
    token_address
    from_address
    to_address
    amount
    fee_amount
    fee_address
    payment_reference
    contract_address
  }
}
```

### Query by Payment Reference

```bash
curl -X POST https://graphql.stage.request.network/v1/graphql \
  -H "Content-Type: application/json" \
  -d '{
    "query": "query { payments(where: { payment_reference: { _eq: \"0xabc123...\" } }) { tx_hash amount chain } }"
  }'
```

### SDK Integration

The Request Network SDK uses a custom info retriever to query the Hasura endpoint for TRON payments. See the `@requestnetwork/payment-detection` package for implementation details.

## Multi-Chain Support

Each chain has its own Postgres schema (`tron`, `sepolia`, `base`, `mainnet`, `matic`, `bsc`,
`arbitrum_one`, `optimism`) with its own `payments`, `cursors` and `substreams_history` tables,
because cursor and reorg bookkeeping is per schema (see `docs/contract.md`).

```sql
SELECT COUNT(*) FROM base.payments;
```

### Adding a New Network

Adding an EVM chain is configuration only, no new module:

1. `evm/chains.yaml`: add the chain (schema, request-api name, Substreams network, initial block,
   ERC20FeeProxy addresses).
2. `evm/substreams.yaml`: add the matching `networks:` entry (`initialBlock` and
   `params: chain=<name>;addresses=<lowercase 0x,...>`).
3. `sinks/chains.env`: add the `<CHAIN>_SPKG=evm`, `_NETWORK`, `_ENDPOINT`, `_SCHEMA` and
   `_TOKEN_ENV` defaults.
4. request-infrastructure: create the schema (`setup-payments-db.sql`) and add the chain to the
   pool's `CHAINS` in Terraform.

## Troubleshooting

### Module Hash Mismatch

A new package version changes the module hash. The sink runs with
`ON_MODULE_HASH_MISMATCH=warn`: it logs a warning and adopts the stored cursor under the new hash,
so it resumes where it left off. Cursors are never dropped in stage or production -- dropping them
replays the chain from its initial block (quota) and is not a fix for a hash change.

### Column Does Not Exist

Schema changes are additive migrations against the existing tables (`ALTER TABLE ... ADD COLUMN`
in each chain schema), applied before deploying an image whose `schema.sql` uses them. Do not
drop `payments` or `cursors`.

### `no schema has been selected to create in`

`sink postgres setup` needs the chain's Postgres schema to exist. Run request-infrastructure
`scripts/setup-payments-db.sql` (GCP) or recreate the local volume so `sinks/local-init.sql`
runs (`docker compose down -v`). The supervisor logs `sink_setup_failed` for that chain and
retries its setup with backoff (5 s doubling to 60 s) while the other chains keep running, so the
chain starts on its own once the schema exists.

### Connecting with psql

`psql` rejects a DSN that carries `schemaName=`. Use the base DSN and `SET search_path TO <schema>;`
(or schema-qualified names) instead.

### No progress / stalled chain

`sink_progress` is logged for every running chain on every sampling interval; `sink_stalled`
means a chain's cursor has not advanced for `SINK_STALL_SECONDS`. Check that chain's
`sink_exited` lines and the StreamingFast quota (see `docs/contract.md`, Quota note).

## Streamingfast Endpoints

| Network | Endpoint |
|---------|----------|
| TRON Mainnet | `mainnet.tron.streamingfast.io:443` |
| TRON Shasta (Testnet) | `shasta.tron.streamingfast.io:443` |
| Ethereum Mainnet | `mainnet.eth.streamingfast.io:443` |

## License

MIT
