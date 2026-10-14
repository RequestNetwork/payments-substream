//! Request Network EVM Substreams Module
//!
//! This module indexes TransferWithReferenceAndFee events from the ERC20FeeProxy
//! contracts deployed on EVM chains. One package serves every chain: the chain name and
//! proxy addresses arrive as module params, selected per network in substreams.yaml.

// The #[substreams::handlers::map] macro expands each handler into an extern "C" wrapper that
// takes raw pointers; clippy flags that generated signature and attributes the span back to the
// handler fn, where a local #[allow] on the fn itself is consumed by the macro before clippy
// sees the expansion. Allow crate-wide instead.
#![allow(clippy::not_unsafe_ptr_arg_deref)]

// Generated/vendored protobuf bindings: allow the lints that fire on boilerplate we don't hand-write.
#[allow(dead_code, clippy::enum_variant_names)]
mod pb;

use std::collections::HashSet;

use pb::request::evm::v1::{Payment, Payments};
use pb::sf::ethereum::r#type::v2::{Block, Log, TransactionTrace, TransactionTraceStatus};
use substreams::log;
use substreams_database_change::pb::database::{table_change::Operation, DatabaseChanges};

/// TransferWithReferenceAndFee event signature (keccak256 hash of event signature)
/// Event: TransferWithReferenceAndFee(address,address,uint256,bytes indexed,uint256,address)
/// keccak256("TransferWithReferenceAndFee(address,address,uint256,bytes,uint256,address)")
const TRANSFER_WITH_REF_AND_FEE_TOPIC: &str =
    "9f16cbcc523c67a60c450e5ffe4f3b7b6dbe772e7abcadb2686ce029a9a0a2b6";

/// Parses the module params.
/// Expected format: "chain=<request-api chain>;addresses=<0x addr>,<0x addr>" (`;` or newline
/// separated). Addresses are lowercased so checksummed input still matches.
fn parse_params(params: &str) -> (String, HashSet<String>) {
    let mut chain = String::new();
    let mut addresses = HashSet::new();

    for pair in params.split([';', '\n']) {
        let mut parts = pair.splitn(2, '=');
        let key = parts.next().unwrap_or("").trim();
        let value = parts.next().unwrap_or("").trim();
        match key {
            "chain" => chain = value.to_string(),
            "addresses" => {
                for address in value.split(',') {
                    let address = address.trim();
                    if !address.is_empty() {
                        addresses.insert(address.to_lowercase());
                    }
                }
            }
            _ => {}
        }
    }

    (chain, addresses)
}

/// Rejects params that would make the module silently index nothing: a missing or malformed
/// `chain` (rows would be written under the wrong chain) or an empty / malformed `addresses`
/// list (every block would yield zero payments while the sink still advances its cursor).
fn validate_params(params: &str) -> Result<(), String> {
    let (chain, addresses) = parse_params(params);
    let chain_ok = !chain.is_empty()
        && chain
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-');
    if !chain_ok {
        return Err(format!("invalid params: missing or malformed `chain` in {params:?}"));
    }
    if addresses.is_empty() {
        return Err(format!("invalid params: empty `addresses` in {params:?}"));
    }
    if let Some(bad) = addresses.iter().find(|a| {
        a.len() != 42 || !a.starts_with("0x") || !a[2..].chars().all(|c| c.is_ascii_hexdigit())
    }) {
        return Err(format!("invalid params: malformed address {bad:?}"));
    }
    Ok(())
}

/// Maps EVM blocks to extract ERC20FeeProxy payment events
#[substreams::handlers::map]
fn map_erc20_fee_proxy_payments(params: String, block: Block) -> Result<Payments, substreams::errors::Error> {
    validate_params(&params).map_err(|e| anyhow::anyhow!(e))?;
    Ok(extract_payments(&params, &block))
}

/// Extracts the payments from a block. Factored out of the handler so it is unit-testable.
fn extract_payments(params: &str, block: &Block) -> Payments {
    let (chain, addresses) = parse_params(params);

    let mut payments = Vec::new();
    let block_number = block.header.as_ref().map(|h| h.number).unwrap_or(0);
    let block_timestamp = block
        .header
        .as_ref()
        .and_then(|h| h.timestamp.as_ref())
        .map(|t| t.seconds as u64)
        .unwrap_or(0);

    for trace in block.transaction_traces.iter() {
        // Reverted/failed transactions emit no effective logs
        if trace.status != TransactionTraceStatus::Succeeded as i32 {
            continue;
        }

        let receipt = match &trace.receipt {
            Some(receipt) => receipt,
            None => continue,
        };

        // log_index is the position of the log within this transaction's receipt
        for (log_index, log_entry) in receipt.logs.iter().enumerate() {
            // Check if this log is from one of our proxy contracts
            let contract_address = format!("0x{}", hex::encode(&log_entry.address));
            if !addresses.contains(&contract_address) {
                continue;
            }

            // Validate the event signature matches TransferWithReferenceAndFee
            if log_entry.topics.is_empty()
                || hex::encode(&log_entry.topics[0]) != TRANSFER_WITH_REF_AND_FEE_TOPIC
            {
                continue;
            }

            if let Some(payment) = parse_transfer_with_reference_and_fee(
                log_entry,
                &contract_address,
                block_number,
                block_timestamp,
                trace,
                &chain,
                log_index as u64,
            ) {
                payments.push(payment);
            }
        }
    }

    Payments { payments }
}

/// sf.substreams.sink.database.v1 OPERATION_UPSERT. The crate's `Operation` enum (1.3.1) only
/// defines Unspecified/Create/Update/Delete, but `TableChange.operation` is a plain `i32` field,
/// and substreams-sink-postgres switches on the decoded wire value: 4 renders
/// `INSERT ... ON CONFLICT (pk) DO UPDATE`, while `Operation::Create` renders a plain `INSERT`
/// that fails on replay once the row already exists.
const OPERATION_UPSERT: i32 = 4;

/// Builds the DatabaseChanges for a batch of payments. Factored out of the `db_out` handler
/// below so it is unit-testable (the `#[substreams::handlers::map]` macro wraps the handler
/// itself, which substreams-test cannot invoke directly).
pub fn build_database_changes(payments: &Payments) -> DatabaseChanges {
    let mut database_changes = DatabaseChanges::default();

    for payment in &payments.payments {
        // EVM key: chain + tx_hash + log_index (docs/contract.md; TRON keeps its legacy key)
        let key = format!("{}:{}:{}", payment.chain, payment.tx_hash, payment.log_index);

        let table_change = database_changes
            .push_change("payments", &key, 0, Operation::Create)
            .change("id", ("", key.as_str()))
            .change("chain", ("", payment.chain.as_str()))
            .change("tx_hash", ("", payment.tx_hash.as_str()))
            .change("block_number", ("", payment.block.to_string().as_str()))
            .change("timestamp", ("", payment.timestamp.to_string().as_str()))
            .change("contract_address", ("", payment.contract_address.as_str()))
            .change("token_address", ("", payment.token_address.as_str()))
            .change("from_address", ("", payment.from.as_str()))
            .change("to_address", ("", payment.to.as_str()))
            .change("amount", ("", payment.amount.as_str()))
            .change("fee_amount", ("", payment.fee_amount.as_str()))
            .change("fee_address", ("", payment.fee_address.as_str()))
            .change("payment_reference", ("", payment.payment_reference.as_str()))
            .change("gas_used", ("", payment.gas_used.as_str()))
            .change("gas_price", ("", payment.gas_price.as_str()))
            .change("log_index", ("", payment.log_index.to_string().as_str()));

        // Set the i32 field directly (no transmute): push_change only accepts the crate's
        // Operation enum, which has no Upsert variant.
        table_change.operation = OPERATION_UPSERT;
    }

    database_changes
}

/// Converts Payments to DatabaseChanges for SQL sink
#[substreams::handlers::map]
fn db_out(payments: Payments) -> Result<DatabaseChanges, substreams::errors::Error> {
    Ok(build_database_changes(&payments))
}

/// Parses a TransferWithReferenceAndFee event from a log entry
fn parse_transfer_with_reference_and_fee(
    log_entry: &Log,
    contract_address: &str,
    block_number: u64,
    block_timestamp: u64,
    trace: &TransactionTrace,
    chain: &str,
    log_index: u64,
) -> Option<Payment> {
    // Event: TransferWithReferenceAndFee(address tokenAddress, address to, uint256 amount,
    //                                    bytes indexed paymentReference, uint256 feeAmount, address feeAddress)
    //
    // Topics:
    // [0] = Event signature hash
    // [1] = paymentReference (indexed)
    //
    // Data (non-indexed parameters, ABI encoded):
    // [0-31]   = tokenAddress
    // [32-63]  = to
    // [64-95]  = amount
    // [96-127] = feeAmount
    // [128-159] = feeAddress

    if log_entry.topics.len() < 2 {
        return None;
    }

    let data = &log_entry.data;
    if data.len() < 160 {
        log::info!("Log data too short: {} bytes", data.len());
        return None;
    }

    // Payment reference from the indexed topic (0x prefix, matching the Ethereum subgraph format)
    let payment_reference = format!("0x{}", hex::encode(&log_entry.topics[1]));

    // Parse non-indexed parameters from data
    let token_address = parse_address_from_data(data, 0)?;
    let to = parse_address_from_data(data, 32)?;
    let amount = parse_uint256_from_data(data, 64);
    let fee_amount = parse_uint256_from_data(data, 96);
    let fee_address = parse_address_from_data(data, 128)?;

    let gas_price = trace
        .gas_price
        .as_ref()
        .map(|price| bytes_to_decimal(&price.bytes))
        .unwrap_or_else(|| "0".to_string());

    Some(Payment {
        token_address,
        to,
        amount,
        payment_reference,
        fee_amount,
        fee_address,
        from: format!("0x{}", hex::encode(&trace.from)),
        block: block_number,
        timestamp: block_timestamp,
        tx_hash: format!("0x{}", hex::encode(&trace.hash)),
        contract_address: contract_address.to_string(),
        chain: chain.to_string(),
        gas_used: trace.gas_used.to_string(),
        gas_price,
        log_index,
    })
}

/// Parses an address from ABI-encoded data at the given offset (lowercase 0x + 40 hex)
fn parse_address_from_data(data: &[u8], offset: usize) -> Option<String> {
    if data.len() < offset + 32 {
        return None;
    }
    // Address is the last 20 bytes of the 32-byte slot
    Some(format!("0x{}", hex::encode(&data[offset + 12..offset + 32])))
}

/// Parses a uint256 from ABI-encoded data at the given offset
/// Returns the value as a decimal string for TheGraph BigInt compatibility
fn parse_uint256_from_data(data: &[u8], offset: usize) -> String {
    if data.len() < offset + 32 {
        return "0".to_string();
    }
    bytes_to_decimal(&data[offset..offset + 32])
}

/// Converts big-endian bytes of any length to a decimal string ("0" when empty or all zero)
fn bytes_to_decimal(bytes: &[u8]) -> String {
    // Process the bytes manually to handle arbitrarily large numbers
    let mut result: Vec<u8> = Vec::new();

    for &byte in bytes.iter() {
        // Multiply result by 256 and add the new byte
        let mut carry = byte as u32;
        for digit in result.iter_mut().rev() {
            let val = (*digit as u32) * 256 + carry;
            *digit = (val % 10) as u8;
            carry = val / 10;
        }
        while carry > 0 {
            result.insert(0, (carry % 10) as u8);
            carry /= 10;
        }
    }

    if result.is_empty() {
        "0".to_string()
    } else {
        result.iter().map(|d| (b'0' + d) as char).collect()
    }
}

#[cfg(test)]
mod tests {

    #[test]
    fn validate_params_accepts_the_manifest_format() {
        assert!(validate_params("chain=matic;addresses=0x2171a0dc12a9e5b1659fef2bb20e54c84fa7db0c,0x0dfbee143b42b41efc5a6f87bfd1ffc78c2f0ac9").is_ok());
        assert!(validate_params("chain=arbitrum-one;addresses=0x0DfbEe143b42B41eFC5A6F87bFD1fFC78c2f0aC9").is_ok());
    }

    #[test]
    fn validate_params_rejects_params_that_would_index_nothing() {
        assert!(validate_params("addresses=0x2171a0dc12a9e5b1659fef2bb20e54c84fa7db0c").is_err());
        assert!(validate_params("chain=base").is_err());
        assert!(validate_params("chain=base;addresses=").is_err());
        assert!(validate_params("chain=base;addresses=2171a0dc12a9e5b1659fef2bb20e54c84fa7db0c").is_err());
        assert!(validate_params("chain=Base;addresses=0x2171a0dc12a9e5b1659fef2bb20e54c84fa7db0c").is_err());
        assert!(validate_params("chain=base;adresses=0x2171a0dc12a9e5b1659fef2bb20e54c84fa7db0c").is_err());
    }
    use super::*;
    use pb::sf::ethereum::r#type::v2::{BigInt, BlockHeader, TransactionReceipt};
    use substreams_database_change::pb::database::table_change::PrimaryKey;

    const PROXY: &str = "0x399f5ee127ce7432e4921a61b8cf52b0af52cbfe";
    const REFERENCE: &str = "2b48d257af6a1014bafae1d1cf3dbe39b62b65715a6c0863770005e839c9e797";
    const TOKEN: &str = "1c7d4b196cb0c7b01d743fbc6116a902379c7238";
    const TO: &str = "325d3e74a054e38b8b45a18e0d45db793657d3a9";
    const FEE_ADDRESS: &str = "35d0e078755cd84d3e0656caab417dee1d7939c7";

    fn word_address(hex_address: &str) -> Vec<u8> {
        let mut word = vec![0u8; 12];
        word.extend_from_slice(&hex::decode(hex_address).unwrap());
        word
    }

    fn word_uint(value: u64) -> Vec<u8> {
        let mut word = vec![0u8; 24];
        word.extend_from_slice(&value.to_be_bytes());
        word
    }

    fn event_data(amount: u64, fee_amount: u64) -> Vec<u8> {
        let mut data = Vec::new();
        data.extend(word_address(TOKEN));
        data.extend(word_address(TO));
        data.extend(word_uint(amount));
        data.extend(word_uint(fee_amount));
        data.extend(word_address(FEE_ADDRESS));
        data
    }

    fn payment_log(address: &str, data: Vec<u8>) -> Log {
        Log {
            address: hex::decode(address.trim_start_matches("0x")).unwrap(),
            topics: vec![
                hex::decode(TRANSFER_WITH_REF_AND_FEE_TOPIC).unwrap(),
                hex::decode(REFERENCE).unwrap(),
            ],
            data,
            ..Default::default()
        }
    }

    fn other_log() -> Log {
        Log {
            address: hex::decode(TOKEN).unwrap(),
            topics: vec![vec![0xddu8; 32]],
            data: vec![0u8; 32],
            ..Default::default()
        }
    }

    fn trace(status: TransactionTraceStatus, logs: Vec<Log>) -> TransactionTrace {
        TransactionTrace {
            hash: vec![0xabu8; 32],
            from: hex::decode("22080b164346366ef5ee15606d5ee1c5a9f27708").unwrap(),
            gas_used: 79772,
            gas_price: Some(BigInt {
                bytes: 1_500_000_017u64.to_be_bytes().to_vec(),
            }),
            status: status as i32,
            receipt: Some(TransactionReceipt {
                logs,
                ..Default::default()
            }),
            ..Default::default()
        }
    }

    fn block(traces: Vec<TransactionTrace>) -> Block {
        Block {
            number: 11861545,
            header: Some(BlockHeader {
                number: 11861545,
                timestamp: Some(prost_types::Timestamp {
                    seconds: 1_791_358_752,
                    nanos: 0,
                }),
                ..Default::default()
            }),
            transaction_traces: traces,
            ..Default::default()
        }
    }

    fn params() -> String {
        format!("chain=sepolia;addresses={}", PROXY)
    }

    fn sample_payment(tx_hash: &str, log_index: u64) -> Payment {
        Payment {
            token_address: format!("0x{}", TOKEN),
            to: format!("0x{}", TO),
            amount: "10000".to_string(),
            payment_reference: format!("0x{}", REFERENCE),
            fee_amount: "0".to_string(),
            fee_address: format!("0x{}", FEE_ADDRESS),
            from: "0x22080b164346366ef5ee15606d5ee1c5a9f27708".to_string(),
            block: 11861545,
            timestamp: 1_791_358_752,
            tx_hash: tx_hash.to_string(),
            contract_address: PROXY.to_string(),
            chain: "sepolia".to_string(),
            gas_used: "79772".to_string(),
            gas_price: "1500000017".to_string(),
            log_index,
        }
    }

    fn primary_key(changes: &DatabaseChanges, i: usize) -> String {
        match &changes.table_changes[i].primary_key {
            Some(PrimaryKey::Pk(pk)) => pk.clone(),
            _ => panic!("expected a single primary key"),
        }
    }

    #[test]
    fn test_parse_params() {
        let (chain, addresses) = parse_params(
            "chain=matic;addresses=0x2171a0dc12a9e5b1659fef2bb20e54c84fa7db0c,0x0dfbee143b42b41efc5a6f87bfd1ffc78c2f0ac9",
        );
        assert_eq!(chain, "matic");
        assert_eq!(addresses.len(), 2);
        assert!(addresses.contains("0x2171a0dc12a9e5b1659fef2bb20e54c84fa7db0c"));
        assert!(addresses.contains("0x0dfbee143b42b41efc5a6f87bfd1ffc78c2f0ac9"));
    }

    #[test]
    fn test_parse_params_lowercases_checksummed_addresses_and_trims() {
        let (chain, addresses) =
            parse_params(" chain = base ; addresses = 0x1892196E80C4c17ea5100Da765Ab48c1fE2Fb814 ");
        assert_eq!(chain, "base");
        assert_eq!(addresses.len(), 1);
        assert!(addresses.contains("0x1892196e80c4c17ea5100da765ab48c1fe2fb814"));
    }

    #[test]
    fn test_parse_params_empty() {
        let (chain, addresses) = parse_params("");
        assert_eq!(chain, "");
        assert!(addresses.is_empty());
    }

    #[test]
    fn test_full_synthetic_log_decode() {
        let blk = block(vec![trace(
            TransactionTraceStatus::Succeeded,
            vec![other_log(), payment_log(PROXY, event_data(10000, 25))],
        )]);

        let payments = extract_payments(&params(), &blk).payments;

        assert_eq!(payments.len(), 1);
        let p = &payments[0];
        assert_eq!(p.chain, "sepolia");
        assert_eq!(p.contract_address, PROXY);
        assert_eq!(p.token_address, format!("0x{}", TOKEN));
        assert_eq!(p.to, format!("0x{}", TO));
        assert_eq!(p.amount, "10000");
        assert_eq!(p.fee_amount, "25");
        assert_eq!(p.fee_address, format!("0x{}", FEE_ADDRESS));
        assert_eq!(p.payment_reference, format!("0x{}", REFERENCE));
        assert_eq!(p.from, "0x22080b164346366ef5ee15606d5ee1c5a9f27708");
        assert_eq!(p.tx_hash, format!("0x{}", "ab".repeat(32)));
        assert_eq!(p.block, 11861545);
        assert_eq!(p.timestamp, 1_791_358_752);
        assert_eq!(p.gas_used, "79772");
        assert_eq!(p.gas_price, "1500000017");
        // Second log in the receipt
        assert_eq!(p.log_index, 1);
        // Rendered addresses are lowercase 0x + 40 hex
        for address in [&p.token_address, &p.to, &p.fee_address, &p.from, &p.contract_address] {
            assert_eq!(address.len(), 42);
            assert_eq!(address.as_str(), address.to_lowercase());
        }
    }

    #[test]
    fn test_address_filter_is_case_insensitive() {
        let blk = block(vec![trace(
            TransactionTraceStatus::Succeeded,
            vec![payment_log(PROXY, event_data(1, 0))],
        )]);

        let checksummed = "chain=sepolia;addresses=0x399F5EE127ce7432E4921a61b8CF52b0af52cbfe";
        assert_eq!(extract_payments(checksummed, &blk).payments.len(), 1);
    }

    #[test]
    fn test_other_address_skipped() {
        let blk = block(vec![trace(
            TransactionTraceStatus::Succeeded,
            vec![payment_log("0x0dfbee143b42b41efc5a6f87bfd1ffc78c2f0ac9", event_data(1, 0))],
        )]);

        assert!(extract_payments(&params(), &blk).payments.is_empty());
    }

    #[test]
    fn test_topic0_mismatch_skipped() {
        let mut log_entry = payment_log(PROXY, event_data(1, 0));
        log_entry.topics[0] = vec![0x11u8; 32];
        let blk = block(vec![trace(TransactionTraceStatus::Succeeded, vec![log_entry])]);

        assert!(extract_payments(&params(), &blk).payments.is_empty());
    }

    #[test]
    fn test_missing_reference_topic_skipped() {
        let mut log_entry = payment_log(PROXY, event_data(1, 0));
        log_entry.topics.truncate(1);
        let blk = block(vec![trace(TransactionTraceStatus::Succeeded, vec![log_entry])]);

        assert!(extract_payments(&params(), &blk).payments.is_empty());
    }

    #[test]
    fn test_short_data_skipped() {
        let mut data = event_data(1, 0);
        data.truncate(159);
        let blk = block(vec![trace(TransactionTraceStatus::Succeeded, vec![payment_log(PROXY, data)])]);

        assert!(extract_payments(&params(), &blk).payments.is_empty());
    }

    #[test]
    fn test_reverted_and_failed_traces_skipped() {
        let blk = block(vec![
            trace(TransactionTraceStatus::Reverted, vec![payment_log(PROXY, event_data(1, 0))]),
            trace(TransactionTraceStatus::Failed, vec![payment_log(PROXY, event_data(1, 0))]),
            trace(TransactionTraceStatus::Unknown, vec![payment_log(PROXY, event_data(1, 0))]),
        ]);

        assert!(extract_payments(&params(), &blk).payments.is_empty());
    }

    #[test]
    fn test_missing_gas_price_is_zero() {
        let mut tx = trace(TransactionTraceStatus::Succeeded, vec![payment_log(PROXY, event_data(1, 0))]);
        tx.gas_price = None;
        let payments = extract_payments(&params(), &block(vec![tx])).payments;

        assert_eq!(payments[0].gas_price, "0");
    }

    #[test]
    fn test_uint256_decoding() {
        assert_eq!(parse_uint256_from_data(&[0u8; 32], 0), "0");
        assert_eq!(parse_uint256_from_data(&word_uint(1_000_000), 0), "1000000");
        assert_eq!(
            parse_uint256_from_data(&[0xffu8; 32], 0),
            "115792089237316195423570985008687907853269984665640564039457584007913129639935"
        );
        // Out-of-range offset
        assert_eq!(parse_uint256_from_data(&[0u8; 32], 32), "0");
    }

    #[test]
    fn test_gas_price_decoding() {
        assert_eq!(bytes_to_decimal(&[]), "0");
        assert_eq!(bytes_to_decimal(&[0]), "0");
        assert_eq!(bytes_to_decimal(&[0x0b, 0x36, 0xc4]), "734916");
        assert_eq!(bytes_to_decimal(&u64::MAX.to_be_bytes()), "18446744073709551615");
        assert_eq!(
            bytes_to_decimal(&[0xffu8; 32]),
            "115792089237316195423570985008687907853269984665640564039457584007913129639935"
        );
    }

    #[test]
    fn test_parse_address_from_data() {
        let address = parse_address_from_data(&word_address(TOKEN), 0);
        assert_eq!(address, Some(format!("0x{}", TOKEN)));
        assert_eq!(parse_address_from_data(&[0u8; 100], 128), None);
    }

    #[test]
    fn test_event_signature() {
        // keccak256("TransferWithReferenceAndFee(address,address,uint256,bytes,uint256,address)")
        assert_eq!(
            TRANSFER_WITH_REF_AND_FEE_TOPIC,
            "9f16cbcc523c67a60c450e5ffe4f3b7b6dbe772e7abcadb2686ce029a9a0a2b6"
        );
    }

    #[test]
    fn test_build_database_changes_sets_operation_upsert() {
        let payments = Payments {
            payments: vec![sample_payment("0xdeadbeef", 0)],
        };

        let changes = build_database_changes(&payments);

        assert_eq!(changes.table_changes.len(), 1);
        assert_eq!(changes.table_changes[0].operation, OPERATION_UPSERT);
        assert_eq!(changes.table_changes[0].operation, 4);
    }

    #[test]
    fn test_build_database_changes_key_and_columns() {
        let payments = Payments {
            payments: vec![sample_payment("0xdeadbeef", 7)],
        };

        let changes = build_database_changes(&payments);

        let pk = primary_key(&changes, 0);
        assert_eq!(pk, "sepolia:0xdeadbeef:7");
        // chain + exactly two more parts (tx_hash, log_index): no payment_reference segment
        let parts: Vec<&str> = pk.split(':').collect();
        assert_eq!(parts.len(), 3);
        assert_eq!(parts[0], "sepolia");

        let fields = &changes.table_changes[0].fields;
        assert_eq!(fields.len(), 16);
        let names: Vec<&str> = fields.iter().map(|f| f.name.as_str()).collect();
        for column in ["id", "gas_used", "gas_price", "log_index", "payment_reference"] {
            assert!(names.contains(&column), "missing column {}", column);
        }
        assert!(
            !names.iter().any(|n| *n == "energy_used" || *n == "energy_fee" || *n == "net_fee"),
            "EVM rows must not set TRON-only resource fields"
        );
    }

    #[test]
    fn test_build_database_changes_two_log_indexes_produce_distinct_keys() {
        let payments = Payments {
            payments: vec![sample_payment("0xdeadbeef", 0), sample_payment("0xdeadbeef", 1)],
        };

        let changes = build_database_changes(&payments);

        assert_eq!(changes.table_changes.len(), 2);
        assert_eq!(primary_key(&changes, 0), "sepolia:0xdeadbeef:0");
        assert_eq!(primary_key(&changes, 1), "sepolia:0xdeadbeef:1");
    }
}
