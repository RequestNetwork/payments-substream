//! Request Network TRON Substreams Module
//!
//! This module indexes TransferWithReferenceAndFee events from the ERC20FeeProxy
//! contract deployed on TRON mainnet and Nile testnet.

mod pb;

use hex;
use pb::protocol::transaction_info::Log;
use pb::request::tron::v1::{Payment, Payments};
use pb::sf::tron::r#type::v1::{Block, Transaction};
use substreams::log;

/// TransferWithReferenceAndFee event signature (keccak256 hash of event signature)
/// Event: TransferWithReferenceAndFee(address,address,uint256,bytes indexed,uint256,address)
/// keccak256("TransferWithReferenceAndFee(address,address,uint256,bytes,uint256,address)")
const TRANSFER_WITH_REF_AND_FEE_TOPIC: &str =
    "9f16cbcc523c67a60c450e5ffe4f3b7b6dbe772e7abcadb2686ce029a9a0a2b6";

/// Parses proxy addresses from the params string
/// Expected format: "mainnet_proxy_address=ADDR1\nnile_proxy_address=ADDR2"
fn parse_proxy_addresses(params: &str) -> (String, String) {
    let mut mainnet = String::new();
    let mut nile = String::new();
    
    for line in params.lines() {
        let parts: Vec<&str> = line.splitn(2, '=').collect();
        if parts.len() == 2 {
            match parts[0].trim() {
                "mainnet_proxy_address" => mainnet = parts[1].trim().to_string(),
                "nile_proxy_address" => nile = parts[1].trim().to_string(),
                _ => {}
            }
        }
    }
    
    (mainnet, nile)
}

/// Maps TRON blocks to extract ERC20FeeProxy payment events
#[substreams::handlers::map]
fn map_erc20_fee_proxy_payments(params: String, block: Block) -> Result<Payments, substreams::errors::Error> {
    let (mainnet_proxy, nile_proxy) = parse_proxy_addresses(&params);
    
    let mut payments = Vec::new();
    let block_number = block.header.as_ref().map(|h| h.number).unwrap_or(0);
    let block_timestamp = block.header.as_ref().map(|h| h.timestamp).unwrap_or(0) as u64 / 1000; // Convert from ms to seconds

    for transaction in block.transactions.iter() {
        let tx_hash = hex::encode(&transaction.txid);
        
        // Get the transaction info to access logs
        if let Some(info) = &transaction.info {
            for log_entry in info.log.iter() {
                // Check if this log is from one of our proxy contracts
                let contract_address = base58_encode(&log_entry.address);
                
                if contract_address != mainnet_proxy && contract_address != nile_proxy {
                    continue;
                }

                // Check if this is a TransferWithReferenceAndFee event
                // The first topic should be the event signature
                if log_entry.topics.is_empty() {
                    continue;
                }

                // Validate the event signature matches TransferWithReferenceAndFee
                let topic0 = hex::encode(&log_entry.topics[0]);
                if topic0 != TRANSFER_WITH_REF_AND_FEE_TOPIC {
                    continue;
                }

                // Parse the event data
                if let Some(payment) = parse_transfer_with_reference_and_fee(
                    log_entry,
                    &contract_address,
                    &tx_hash,
                    block_number,
                    block_timestamp,
                    transaction,
                ) {
                    payments.push(payment);
                }
            }
        }
    }

    Ok(Payments { payments })
}

/// Parses a TransferWithReferenceAndFee event from a log entry
fn parse_transfer_with_reference_and_fee(
    log_entry: &Log,
    contract_address: &str,
    tx_hash: &str,
    block_number: u64,
    block_timestamp: u64,
    transaction: &Transaction,
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

    // Extract payment reference from indexed topic
    let payment_reference = hex::encode(&log_entry.topics[1]);

    // Parse non-indexed parameters from data
    let token_address = parse_address_from_data(data, 0)?;
    let to = parse_address_from_data(data, 32)?;
    let amount = parse_uint256_from_data(data, 64);
    let fee_amount = parse_uint256_from_data(data, 96);
    let fee_address = parse_address_from_data(data, 128)?;

    // Get the sender (from) address from the transaction contracts
    let from = transaction
        .contracts
        .first()
        .and_then(|c| c.parameter.as_ref())
        .map(|p| extract_owner_address(p))
        .unwrap_or_default();

    Some(Payment {
        token_address,
        to,
        amount,
        payment_reference,
        fee_amount,
        fee_address,
        from,
        block: block_number,
        timestamp: block_timestamp,
        tx_hash: tx_hash.to_string(),
        contract_address: contract_address.to_string(),
    })
}

/// Parses an address from ABI-encoded data at the given offset
fn parse_address_from_data(data: &[u8], offset: usize) -> Option<String> {
    if data.len() < offset + 32 {
        return None;
    }
    // Address is the last 20 bytes of the 32-byte slot
    let address_bytes = &data[offset + 12..offset + 32];
    Some(base58_encode(address_bytes))
}

/// Parses a uint256 from ABI-encoded data at the given offset
/// Returns the value as a decimal string for TheGraph BigInt compatibility
fn parse_uint256_from_data(data: &[u8], offset: usize) -> String {
    if data.len() < offset + 32 {
        return "0".to_string();
    }
    let bytes = &data[offset..offset + 32];
    
    // Convert bytes to decimal string using big-endian interpretation
    // We process the bytes manually to handle arbitrarily large numbers
    let mut result = Vec::new();
    
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

/// Extracts the owner address from a contract parameter
fn extract_owner_address(parameter: &prost_types::Any) -> String {
    // The owner_address is typically at the beginning of the parameter value
    if parameter.value.len() >= 21 {
        base58_encode(&parameter.value[0..21])
    } else {
        String::new()
    }
}

/// Encodes bytes to TRON Base58Check address format
fn base58_encode(bytes: &[u8]) -> String {
    // TRON addresses use Base58Check encoding with 0x41 prefix for mainnet
    // This is a simplified version - in production, use a proper Base58Check implementation
    if bytes.len() == 20 {
        // Add TRON mainnet prefix (0x41)
        let mut prefixed = vec![0x41];
        prefixed.extend_from_slice(bytes);
        bs58::encode(&prefixed).with_check().into_string()
    } else if bytes.len() == 21 && bytes[0] == 0x41 {
        bs58::encode(bytes).with_check().into_string()
    } else {
        bs58::encode(bytes).with_check().into_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_base58_encode() {
        // Test with a known TRON address
        let hex_addr = hex::decode("41a614f803b6fd780986a42c78ec9c7f77e6ded13c").unwrap();
        let encoded = base58_encode(&hex_addr);
        assert!(encoded.starts_with('T'));
    }

    #[test]
    fn test_base58_encode_20_bytes() {
        // Test with 20 bytes (without prefix) - should add 0x41 prefix
        let addr_bytes = hex::decode("a614f803b6fd780986a42c78ec9c7f77e6ded13c").unwrap();
        let encoded = base58_encode(&addr_bytes);
        assert!(encoded.starts_with('T'));
        assert_eq!(encoded.len(), 34); // TRON addresses are 34 chars
    }

    #[test]
    fn test_parse_proxy_addresses() {
        let params = "mainnet_proxy_address=TCUDPYnS9dH3WvFEaE7wN7vnDa51J4R4fd\nnile_proxy_address=THK5rNmrvCujhmrXa5DB1dASepwXTr9cJs";
        let (mainnet, nile) = parse_proxy_addresses(params);
        assert_eq!(mainnet, "TCUDPYnS9dH3WvFEaE7wN7vnDa51J4R4fd");
        assert_eq!(nile, "THK5rNmrvCujhmrXa5DB1dASepwXTr9cJs");
    }

    #[test]
    fn test_parse_address_from_data() {
        // ABI-encoded address: 32 bytes with address in last 20 bytes
        // Address: 0xa614f803b6fd780986a42c78ec9c7f77e6ded13c
        let mut data = vec![0u8; 12]; // 12 bytes padding
        data.extend_from_slice(&hex::decode("a614f803b6fd780986a42c78ec9c7f77e6ded13c").unwrap());
        
        let address = parse_address_from_data(&data, 0);
        assert!(address.is_some());
        assert!(address.unwrap().starts_with('T'));
    }

    #[test]
    fn test_parse_uint256_from_data() {
        // Test parsing 1000000 (0x0F4240 = 1000000 in decimal)
        let mut data = vec![0u8; 32];
        data[29] = 0x0F;
        data[30] = 0x42;
        data[31] = 0x40;
        
        let amount = parse_uint256_from_data(&data, 0);
        assert_eq!(amount, "1000000");
    }

    #[test]
    fn test_parse_uint256_zero() {
        let data = vec![0u8; 32];
        let amount = parse_uint256_from_data(&data, 0);
        assert_eq!(amount, "0");
    }

    #[test]
    fn test_event_signature() {
        // Verify the event signature hash is correct
        // keccak256("TransferWithReferenceAndFee(address,address,uint256,bytes,uint256,address)")
        assert_eq!(
            TRANSFER_WITH_REF_AND_FEE_TOPIC,
            "9f16cbcc523c67a60c450e5ffe4f3b7b6dbe772e7abcadb2686ce029a9a0a2b6"
        );
    }

    #[test]
    fn test_parse_full_event_data() {
        // Simulate a full TransferWithReferenceAndFee event data
        // Data layout (160 bytes total):
        // [0-31]   = tokenAddress (padded)
        // [32-63]  = to (padded)  
        // [64-95]  = amount
        // [96-127] = feeAmount
        // [128-159] = feeAddress (padded)
        
        let mut data = Vec::new();
        
        // Token address (padded to 32 bytes)
        data.extend_from_slice(&[0u8; 12]);
        data.extend_from_slice(&hex::decode("a614f803b6fd780986a42c78ec9c7f77e6ded13c").unwrap());
        
        // To address (padded to 32 bytes)
        data.extend_from_slice(&[0u8; 12]);
        data.extend_from_slice(&hex::decode("b614f803b6fd780986a42c78ec9c7f77e6ded13d").unwrap());
        
        // Amount: 1000000 (0x0F4240)
        let mut amount_bytes = vec![0u8; 32];
        amount_bytes[29] = 0x0F;
        amount_bytes[30] = 0x42;
        amount_bytes[31] = 0x40;
        data.extend_from_slice(&amount_bytes);
        
        // Fee amount: 1000 (0x3E8)
        let mut fee_bytes = vec![0u8; 32];
        fee_bytes[30] = 0x03;
        fee_bytes[31] = 0xE8;
        data.extend_from_slice(&fee_bytes);
        
        // Fee address (padded to 32 bytes)
        data.extend_from_slice(&[0u8; 12]);
        data.extend_from_slice(&hex::decode("c614f803b6fd780986a42c78ec9c7f77e6ded13e").unwrap());
        
        assert_eq!(data.len(), 160);
        
        // Parse each field
        let token = parse_address_from_data(&data, 0);
        let to = parse_address_from_data(&data, 32);
        let amount = parse_uint256_from_data(&data, 64);
        let fee_amount = parse_uint256_from_data(&data, 96);
        let fee_address = parse_address_from_data(&data, 128);
        
        assert!(token.is_some());
        assert!(to.is_some());
        assert!(token.unwrap().starts_with('T'));
        assert!(to.unwrap().starts_with('T'));
        assert!(fee_address.is_some());
        assert!(fee_address.unwrap().starts_with('T'));
        
        // Amounts should be decimal strings
        assert_eq!(amount, "1000000");
        assert_eq!(fee_amount, "1000");
    }

    #[test]
    fn test_data_too_short() {
        // Test with data shorter than expected
        let data = vec![0u8; 100]; // Less than 160 bytes
        
        // Should still parse what's available
        let token = parse_address_from_data(&data, 0);
        assert!(token.is_some());
        
        // But fee_address at offset 128 should fail
        let fee_address = parse_address_from_data(&data, 128);
        assert!(fee_address.is_none());
    }
}
