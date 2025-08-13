#!/usr/bin/env node

const { TronWeb } = require('tronweb');

function tronAddressToBytes32(tronAddress) {
  try {
    // Convert Tron base58 address to hex
    const hexAddress = TronWeb.address.toHex(tronAddress);
    
    // Remove '0x41' prefix (Tron's address prefix) and get the 20-byte address
    const addressWithoutPrefix = hexAddress.slice(4);
    
    // Pad to 32 bytes (64 hex characters) by adding zeros on the left
    const bytes32 = '0x' + addressWithoutPrefix.padStart(64, '0');
    
    console.log('Tron Address (Base58):', tronAddress);
    console.log('Tron Address (Hex):', hexAddress);
    console.log('Address without prefix:', '0x' + addressWithoutPrefix);
    console.log('Bytes32 format:', bytes32);
    
    return bytes32;
  } catch (error) {
    console.error('Error converting address:', error.message);
    process.exit(1);
  }
}

function ethAddressToBytes32(ethAddress) {
  try {
    // Remove 0x prefix if present
    const cleanAddress = ethAddress.startsWith('0x') ? ethAddress.slice(2) : ethAddress;
    
    // Validate it's a valid 40-character hex string (20 bytes)
    if (!/^[0-9a-fA-F]{40}$/.test(cleanAddress)) {
      throw new Error('Invalid Ethereum address format');
    }
    
    // Pad to 32 bytes (64 hex characters) by adding zeros on the left
    const bytes32 = '0x' + cleanAddress.toLowerCase().padStart(64, '0');
    
    console.log('Ethereum Address:', '0x' + cleanAddress);
    console.log('Bytes32 format:', bytes32);
    
    return bytes32;
  } catch (error) {
    console.error('Error converting address:', error.message);
    process.exit(1);
  }
}

// Get address from command line argument
const address = process.argv[2];

if (!address) {
  console.log('Usage: node tron-address-to-bytes32.js <ADDRESS>');
  console.log('Examples:');
  console.log('  Tron: node tron-address-to-bytes32.js TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7');
  console.log('  Ethereum: node tron-address-to-bytes32.js 0x6BF8bC357498dEF607D0d8331B18c334812bDA83');
  process.exit(1);
}

// Auto-detect address type
if (address.startsWith('0x') && address.length === 42) {
  // Ethereum address
  ethAddressToBytes32(address);
} else if (address.startsWith('T') && address.length === 34) {
  // Tron address
  tronAddressToBytes32(address);
} else {
  console.error('Unknown address format. Supported formats:');
  console.error('  Tron: T... (34 characters, base58)');
  console.error('  Ethereum: 0x... (42 characters, hex)');
  process.exit(1);
}