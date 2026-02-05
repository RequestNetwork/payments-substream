# Request Network TRON Substreams

This package contains a Substreams module for indexing ERC20FeeProxy payment events on the TRON blockchain.

## Overview

The module indexes `TransferWithReferenceAndFee` events from the deployed ERC20FeeProxy contract:

- **Mainnet**: `TCUDPYnS9dH3WvFEaE7wN7vnDa51J4R4fd` (block 79216121)

## Prerequisites

1. **Rust toolchain** with `wasm32-unknown-unknown` target:

   ```bash
   rustup target add wasm32-unknown-unknown
   ```

2. **Substreams CLI**:

   ```bash
   brew install streamingfast/tap/substreams
   ```

3. **bs58 crate** for Base58 encoding (included in dependencies)

## Building

```bash
# Build the WASM module
make build

# Generate protobuf types
make protogen

# Package for deployment
make package
```

## Running Locally

```bash
# Run with GUI for debugging
make gui

# Run and output to console
make run
```

## Deployment

> **Note**: Substreams-Powered Subgraphs are not supported for non-EVM chains like TRON.
> Use SQL sink or direct streaming for production deployments.

### Substreams Endpoint

- **Mainnet (Streamingfast)**: `mainnet-evm.tron.streamingfast.io:443`

### Option 1: SQL Sink (PostgreSQL/ClickHouse)

1. Install the SQL sink:
   ```bash
   go install github.com/streamingfast/substreams-sink-sql/cmd/substreams-sink-sql@latest
   ```

2. Build and package:
   ```bash
   make package
   ```

3. Run the sink:
   ```bash
   substreams-sink-sql run \
     "postgres://user:password@host:5432/database?sslmode=disable" \
     ./request-network-tron-v0.1.0.spkg \
     map_erc20_fee_proxy_payments \
     -e mainnet-evm.tron.streamingfast.io:443
   ```

### Option 2: Direct Streaming

Use the Go, Rust, or JavaScript SDKs to stream data directly to your application:

- [Go SDK](https://github.com/streamingfast/substreams-sink)
- [Rust SDK](https://github.com/streamingfast/substreams-sink-rust)
- [JavaScript SDK](https://github.com/substreams-js/substreams-js)

### Option 3: Files/CSV

Export data to files for batch processing:
```bash
substreams-sink-files run \
  ./request-network-tron-v0.1.0.spkg \
  map_erc20_fee_proxy_payments \
  -e mainnet-evm.tron.streamingfast.io:443 \
  --output-path ./output
```

## Module Details

### `map_erc20_fee_proxy_payments`

Extracts payment events from TRON blocks:

**Input**: `sf.tron.type.v1.Block`

**Output**: `request.tron.v1.Payments`

**Fields extracted**:

- `token_address` - TRC20 token contract address
- `to` - Payment recipient
- `amount` - Payment amount
- `payment_reference` - Indexed payment reference (hex)
- `fee_amount` - Fee amount
- `fee_address` - Fee recipient
- `from` - Sender address
- `block` - Block number
- `timestamp` - Block timestamp (Unix seconds)
- `tx_hash` - Transaction hash
- `contract_address` - ERC20FeeProxy contract address

## Testing

```bash
make test
```

## License

MIT
