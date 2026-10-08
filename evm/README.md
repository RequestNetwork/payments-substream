# Request Network EVM Substreams

This package contains one Substreams module set for indexing ERC20FeeProxy
`TransferWithReferenceAndFee` payment events on every supported EVM chain. A single `.spkg`
serves all chains; the chain is selected at run time with `--network`.

## Overview

- `map_erc20_fee_proxy_payments` (map): reads `sf.ethereum.type.v2.Block`, keeps only
  successful transactions, and keeps a receipt log only if its address is one of the configured
  proxies AND topic0 is `0x9f16cbcc523c67a60c450e5ffe4f3b7b6dbe772e7abcadb2686ce029a9a0a2b6`.
  Contracts that delegatecall the proxy (conversion proxy, escrow, transferable receivable) emit
  the same topic0 from their own address and are deliberately not indexed here.
- `db_out` (map): turns payments into `DatabaseChanges` upserts (operation 4,
  `INSERT ... ON CONFLICT (id) DO UPDATE`) for the `payments` table in `schema.sql`.

Row format (see `../docs/contract.md`): addresses and `tx_hash` are lowercase `0x`, `timestamp`
is unix seconds, `gas_used` / `gas_price` are decimal strings, `log_index` is the log's position
within the transaction receipt, and `id` is `chain:tx_hash:log_index`.

## Prerequisites

1. **Rust toolchain** 1.93.0 with the `wasm32-unknown-unknown` target (pinned by the repository
   `rust-toolchain.toml`).
2. **Substreams CLI** v1.24.0 (the version CI pins and sha256-verifies).

## Building

```bash
make build         # Build the WASM module
make test          # Unit tests
make clippy        # Clippy on wasm32, warnings denied
make check-schema  # schema.sql must be a byte copy of ../schema.sql
make package       # sync-schema + build + substreams pack -> request-network-evm-v0.1.0.spkg
make protogen      # Regenerate src/pb from proto/ and the imported packages
```

`schema.sql` is generated: edit `../schema.sql` and run `make sync-schema` (also run by
`make package`). Never edit `evm/schema.sql` directly.

> `make protogen` with CLI v1.24.0 currently fails with a `name conflict over
> sf.substreams.sink.sql.v1.Service` while buf re-parses the image (the same happens in `tron/`).
> The committed `src/pb` was generated from this manifest with the `sql:` import temporarily
> removed; `sf/substreams` is excluded from generation anyway, so the output is unchanged.

## Params

The map module takes one string param, `;`-separated:

```
chain=<request-api chain name>;addresses=<comma-separated lowercase 0x addresses>
```

Checksummed addresses are accepted (they are lowercased). Params are never set by the sink
configuration: they come from the `networks:` section of `substreams.yaml`, which is the single
source of per-network `initialBlock` and params. `SINK_PARAMS_<CHAIN>` exists only as a runtime
override.

## Networks

| `--network`    | request-api chain | initialBlock | ERC20FeeProxy address(es) |
| -------------- | ----------------- | ------------ | ------------------------- |
| `mainnet`      | `mainnet`         | 10774767     | `0x370de27fdb7d1ff1e1baa7d11c5820a324cf623c` |
| `sepolia`      | `sepolia`         | 4733364      | `0x399f5ee127ce7432e4921a61b8cf52b0af52cbfe` |
| `polygon`      | `matic`           | 14163521     | `0x2171a0dc12a9e5b1659fef2bb20e54c84fa7db0c`, `0x0dfbee143b42b41efc5a6f87bfd1ffc78c2f0ac9` |
| `arbitrum-one` | `arbitrum-one`    | 5309741      | `0x0dfbee143b42b41efc5a6f87bfd1ffc78c2f0ac9` |
| `bsc`          | `bsc`             | 11540173     | `0x0dfbee143b42b41efc5a6f87bfd1ffc78c2f0ac9` |
| `optimism`     | `optimism`        | 34638633     | `0x399f5ee127ce7432e4921a61b8cf52b0af52cbfe` |
| `base`         | `base`            | 10827274     | `0x1892196e80c4c17ea5100da765ab48c1fe2fb814` |

`network: sepolia` is the default when `--network` is omitted. Inspect the per-network values
with `substreams info request-network-evm-v0.1.0.spkg --expand-networks`.

## Running Locally

```bash
make run   # 100 blocks of sepolia from its initialBlock (needs SUBSTREAMS_API_TOKEN)
make gui
```

## SQL Sink (PostgreSQL)

One Postgres schema per chain. `setup` applies `schema.sql` inside `schemaName` but does not
create the schema itself, so create it first:

```bash
psql "<dsn without schemaName>" -c "CREATE SCHEMA IF NOT EXISTS base"

substreams sink postgres setup ./request-network-evm-v0.1.0.spkg \
  --dsn "postgres://<user>:<password>@<host>:5432/<database>?sslmode=disable&schemaName=base"

substreams sink postgres ./request-network-evm-v0.1.0.spkg \
  --dsn "postgres://<user>:<password>@<host>:5432/<database>?sslmode=disable&schemaName=base" \
  -e base-mainnet.streamingfast.io:443 \
  --network base
```

Endpoints per chain live in `../sinks/chains.env`.

## Adding a chain

1. `chains.yaml`: add the chain (schema, request-api name, substreams network, initial block,
   lowercase proxy addresses).
2. `substreams.yaml`: add a `networks:` entry with `initialBlock` for both modules and the
   `params` line. CI fails if an address from `chains.yaml` is missing here.
3. `../sinks/chains.env`: add the `<CHAIN>_SPKG=evm`, `_NETWORK`, `_ENDPOINT`, `_SCHEMA` and
   `_TOKEN_ENV` block.
4. Terraform (request-infrastructure): add the chain to the sink worker's `CHAINS` list.
5. Optionally add a verified payment to `testdata/known-payments.json` so the CI integration job
   sinks and asserts it.

## CI

`.github/workflows/evm-build.yml`: build, unit tests, clippy, schema copy check and the
chains.yaml/substreams.yaml address check on every PR; on push to `main` (or manual dispatch) it
also sinks each `testdata/known-payments.json` fixture into a throwaway Postgres, asserts the row,
deletes the cursor and replays the block to prove the upsert, then uploads the `.spkg` artifact.
