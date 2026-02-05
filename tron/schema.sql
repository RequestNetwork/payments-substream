-- Schema for Request Network TRON ERC20FeeProxy payments

CREATE TABLE IF NOT EXISTS payments (
    id TEXT PRIMARY KEY,
    tx_hash TEXT NOT NULL,
    block_number BIGINT NOT NULL,
    timestamp BIGINT NOT NULL,
    contract_address TEXT NOT NULL,
    token_address TEXT NOT NULL,
    from_address TEXT NOT NULL,
    to_address TEXT NOT NULL,
    amount NUMERIC NOT NULL,
    fee_amount NUMERIC NOT NULL,
    fee_address TEXT NOT NULL,
    payment_reference TEXT NOT NULL
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_payments_tx_hash ON payments(tx_hash);
CREATE INDEX IF NOT EXISTS idx_payments_block_number ON payments(block_number);
CREATE INDEX IF NOT EXISTS idx_payments_timestamp ON payments(timestamp);
CREATE INDEX IF NOT EXISTS idx_payments_payment_reference ON payments(payment_reference);
CREATE INDEX IF NOT EXISTS idx_payments_from_address ON payments(from_address);
CREATE INDEX IF NOT EXISTS idx_payments_to_address ON payments(to_address);
CREATE INDEX IF NOT EXISTS idx_payments_token_address ON payments(token_address);
