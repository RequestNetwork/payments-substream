# Request Network Payments Substream

Substreams module for indexing Request Network ERC20FeeProxy payment events across multiple blockchain networks. Currently supports TRON with a multi-chain architecture ready for additional networks.

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

# Linux
curl -sSL https://github.com/streamingfast/substreams/releases/latest/download/substreams_linux_x86_64.tar.gz | tar xz
sudo mv substreams /usr/local/bin/
```

### Install Buf CLI

```bash
brew install bufbuild/buf/buf
```

## Project Structure

```
payments-substream/
├── tron/                          # TRON substream module
│   ├── src/
│   │   ├── lib.rs                 # Main substream logic
│   │   └── pb/                    # Generated protobuf code
│   ├── proto/
│   │   └── request/tron/v1/
│   │       └── payments.proto     # Payment message definitions
│   ├── schema.sql                 # PostgreSQL schema for SQL sink
│   ├── substreams.yaml            # Substream manifest
│   ├── Cargo.toml                 # Rust dependencies
│   └── Makefile                   # Build commands
├── docker-compose.yml             # Local development setup
├── docker-compose.prod.yml        # Production deployment
├── Dockerfile.sink                # SQL sink Docker image
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

Edit `tron/schema.sql` to add new columns:

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
substreams run ./request-network-tron-v0.1.0.spkg \
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

# Start PostgreSQL and sink
docker compose up -d

# View logs
docker compose logs -f sink
```

#### Query Local Database

```bash
# Connect to PostgreSQL
docker exec -it tron-payments-db psql -U postgres -d tron_payments

# Query payments
SELECT * FROM payments LIMIT 10;
SELECT chain, COUNT(*) FROM payments GROUP BY chain;
```

#### Stop Local Services

```bash
docker compose down

# Remove data volumes (fresh start)
docker compose down -v
```

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

### Environment Variables

| Variable | Description |
|----------|-------------|
| `SUBSTREAMS_API_TOKEN` | Streamingfast API authentication token |
| `DSN` | PostgreSQL connection string |
| `POSTGRES_PASSWORD` | PostgreSQL password (local dev) |

## Deployment

### Deploy to Easypanel (Production)

#### 1. Create PostgreSQL Database

In Easypanel:
1. Create a new PostgreSQL service
2. Note the internal hostname (e.g., `shared_payments-substream-postgres`)

#### 2. Deploy the Sink

1. Create a new Docker Compose app pointing to this repository
2. Set compose file path: `docker-compose.prod.yml`
3. Configure environment variables:

```
DSN=postgres://postgres:PASSWORD@shared_payments-substream-postgres:5432/shared?sslmode=disable
SUBSTREAMS_API_TOKEN=your-streamingfast-token
```

4. Enable "Create .env file" checkbox
5. Deploy

#### 3. Monitor the Sink

Check logs in Easypanel to verify:
- Connection to Streamingfast endpoint
- Database writes (`db_flush_rate`)
- Block processing (`progress_total_processed_blocks`)

### Manual Deployment

```bash
# Build the Docker image
docker build -f Dockerfile.sink -t payments-sink .

# Run with environment variables
docker run -d \
  -e DSN="postgres://user:pass@host:5432/db?sslmode=disable" \
  -e SUBSTREAMS_API_TOKEN="your-token" \
  payments-sink
```

## Multi-Chain Support

The payments table includes a `chain` field to support multiple networks:

```sql
SELECT chain, COUNT(*) as payments FROM payments GROUP BY chain;
```

### Adding a New Network

1. Create a new substream module (e.g., `ethereum/`)
2. Configure the appropriate Streamingfast endpoint
3. Set the `chain` parameter in `substreams.yaml`
4. Deploy an additional sink pointing to the same database

Example for Ethereum:

```yaml
params:
  map_erc20_fee_proxy_payments: |
    mainnet_proxy_address=0x...
    chain=ethereum
```

## Troubleshooting

### Module Hash Mismatch

If you see `cursor module hash mismatch`:

```sql
-- Connect to PostgreSQL and reset
DROP TABLE IF EXISTS payments;
DROP TABLE IF EXISTS cursors;
```

Then redeploy the sink.

### Column Does Not Exist

Schema changes require dropping and recreating tables:

```sql
DROP TABLE IF EXISTS payments;
DROP TABLE IF EXISTS cursors;
```

### DNS Resolution Issues

Ensure services are on the same Docker network. In `docker-compose.prod.yml`:

```yaml
networks:
  easypanel:
    external: true
```

## Streamingfast Endpoints

| Network | Endpoint |
|---------|----------|
| TRON Mainnet | `mainnet.tron.streamingfast.io:443` |
| TRON Shasta (Testnet) | `shasta.tron.streamingfast.io:443` |
| Ethereum Mainnet | `mainnet.eth.streamingfast.io:443` |

## License

MIT
