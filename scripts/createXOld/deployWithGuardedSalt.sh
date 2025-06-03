#!/usr/bin/env bash

# deployWithGuardedSalt.sh
# This script deploys a contract with a guarded salt using the CreateX contract (https://github.com/pcaversaccio/createx).
# The guarded salt is generated using the deployer's address, a flag byte, and a hash of the original salt.
# This ensures that your contract cannot be redeployed with the same salt by another account, providing a layer of protection against redeployment attacks.
# It requires the following environment variables:
# - BYTECODE: The bytecode of the contract to deploy.
# - PRIVATE_KEY: The private key of the deployer.
# - SALT: The original salt to be used for deployment.
# - RPC_URL: The RPC URL of the Ethereum network to deploy to.
# - CREATEX_ADDRESS: The address of the deployed CreateX contract.
# Usage: ./deployWithGuardedSalt.sh

# Load environment variables from .env, prioritizing existing env vars
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../utils/load_env.sh"
load_env
set -e

# Check required environment variables
if [ -z "$BYTECODE" ]; then
  echo "Error: BYTECODE environment variable is required"
  exit 1
fi

if [ -z "$PRIVATE_KEY" ]; then
  echo "Error: PRIVATE_KEY environment variable is required"
  exit 1
fi

if [ -z "$SALT" ]; then
  echo "Error: SALT environment variable is required"
  exit 1
fi

if [ -z "$RPC_URL" ]; then
  echo "Error: RPC_URL environment variable is required"
  exit 1
fi

if [ -z "$CREATEX_ADDRESS" ]; then
  echo "Error: CREATEX_ADDRESS environment variable is required"
  exit 1
fi

# Get the Ethereum address from the private key
ADDRESS=$(cast wallet address --private-key "$PRIVATE_KEY")
echo "Deployer address: $ADDRESS"

# Generate guarded salt with formula:
# First 20 bytes: ADDRESS
# Next 1 byte: '0' (RedeployProtectionFlag.False)
# Remaining bytes: hash of SALT truncated to fit

# Convert address to hex without 0x prefix
ADDRESS_HEX=$(echo $ADDRESS | cut -c 3-)
echo "Address hex (20 bytes): $ADDRESS_HEX"

# Flag byte for RedeployProtectionFlag.False = '0'
FLAG_BYTE="00"
echo "Flag byte: $FLAG_BYTE"

# Hash the original salt to get the remaining bytes
SALT_HASH=$(cast keccak "$SALT")
echo "Salt hash: $SALT_HASH"

# We need to take only enough bytes from the salt hash to fill the remaining space
# A bytes32 has 64 hex chars (32 bytes)
# We already used 20 bytes for address + 1 byte for flag = 21 bytes
# So we need the first 11 bytes of the salt hash (32 - 21 = 11 bytes = 22 hex chars)
TRUNCATED_SALT_HASH=$(echo $SALT_HASH | cut -c 3-24) # Take 22 chars (11 bytes) after 0x
echo "Truncated salt hash (11 bytes): $TRUNCATED_SALT_HASH"

# Combine all parts to form the guarded salt
GUARDED_SALT="0x${ADDRESS_HEX}${FLAG_BYTE}${TRUNCATED_SALT_HASH}"
echo "Original salt: $SALT"
echo "Guarded salt: $GUARDED_SALT"

# Deploy the contract using CreateX's deployCreate3 function
echo "Deploying contract with guarded salt via CreateX..."
TX_HASH=$(cast send --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --gas-limit 2000000 \
  "$CREATEX_ADDRESS" \
  "deployCreate3(bytes32,bytes)(address)" \
  "$GUARDED_SALT" \
  "$BYTECODE")

echo "Transaction hash: $TX_HASH"

# Verify deployment was successful
echo "Verifying deployment..."
sleep 2 # Wait for transaction to be mined
DEPLOYED_ADDRESS=$(cast receipt --rpc-url "$RPC_URL" "$TX_HASH" | grep -A1 "address" | tail -n 1 | awk '{print $1}')

if [ "$DEPLOYED_ADDRESS" = "$EXPECTED_ADDRESS" ]; then
  echo "✅ Contract successfully deployed at: $DEPLOYED_ADDRESS"
else
  echo "⚠️  Deployment verification issue. Expected: $EXPECTED_ADDRESS, Got: $DEPLOYED_ADDRESS"
  echo "Check transaction details at: https://etherscan.io/tx/$TX_HASH"
fi

echo "Deployment completed!"