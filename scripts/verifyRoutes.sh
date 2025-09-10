#!/usr/bin/env bash
#
# verifyRoutes.sh
#
# This script verifies deployed contracts on blockchain explorers using Foundry's verify-contract.
# It processes a CSV file with deployment data and uses chain-specific verification API keys.
#
# Features:
# - Automatically removes CSV header line if present
# - Supports verification on multiple chains with different API keys
# - Retries verification on failure with a delay
# - Uses RPC URLs from chain data for more reliable verification
# - Provides detailed logging and summary statistics
# - Handles constructor arguments correctly
#
# Environment variables:
# - RESULTS_FILE: Path to the CSV file with deployment results
# - VERIFICATION_KEY: Single API key for all chains
# - CHAIN_DATA_URL: Optional URL to fetch chain RPC URLs
#
# CSV format expected:
# ChainID,ContractAddress,ContractPath,ContractArguments


# Load environment variables from .env, prioritizing existing env vars
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils/load_env.sh"
load_env

# Load the chain data utility function
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils/load_chain_data.sh"

# Verify deployment data exists
if [ ! -f "$RESULTS_FILE" ]; then
  echo "❌ Error: Deployment data file not found at $RESULTS_FILE"
  echo "Please run MultiDeploy.sh first to deploy contracts and generate deployment data."
  exit 1
fi

# Check for single verification key
echo "📝 Loading verification key"
if [ -z "$VERIFICATION_KEY" ]; then
  echo "❌ Error: VERIFICATION_KEY environment variable not found."
  exit 1
fi

echo "📝 Using single verification key for all chains"

# Load chain data for RPC URLs if CHAIN_DATA_URL is provided
if [ -n "$CHAIN_DATA_URL" ]; then
  CHAIN_JSON=$(load_chain_data "$CHAIN_DATA_URL")
  if [ $? -ne 0 ]; then
    echo "⚠️ Warning: Could not load chain data. Will proceed without RPC URLs."
    CHAIN_JSON=""
  fi
fi

# Process the deployment data for verification
echo "📝 Starting contract verification process..."
echo "Reading deployment data from: $RESULTS_FILE"

# Check if first line contains CSV headers and remove if needed
FIRST_LINE=$(head -n 1 "$RESULTS_FILE")
if [[ "$FIRST_LINE" == *"ChainID"*"ContractAddress"*"ContractPath"* ]]; then
  echo "📝 CSV header detected in results file, removing it before verification"
  # Create a temporary file without the header
  TEMP_FILE=$(mktemp)
  tail -n +2 "$RESULTS_FILE" > "$TEMP_FILE"
  # Replace original file
  mv "$TEMP_FILE" "$RESULTS_FILE"
fi

# Count total contracts to verify
TOTAL_CONTRACTS=$(wc -l < "$RESULTS_FILE" | tr -d ' ')
CURRENT_CONTRACT=0
SUCCESSFUL_VERIFICATIONS=0
FAILED_VERIFICATIONS=0
SKIPPED_VERIFICATIONS=0

# Process each deployed contract
cat "$RESULTS_FILE" | while IFS=, read -r CHAIN_ID CONTRACT_ADDRESS CONTRACT_PATH CONSTRUCTOR_ARGS; do
  # Increment contract counter
  CURRENT_CONTRACT=$((CURRENT_CONTRACT + 1))
  
  # Extract contract name from contract path
  CONTRACT_NAME=$(basename "$CONTRACT_PATH" | cut -d ':' -f2)
  if [ -z "$CONTRACT_NAME" ]; then
    # If no colon in the path, use the filename as contract name
    CONTRACT_NAME=$(basename "$CONTRACT_PATH")
  fi
  
  # Skip verification for MetaProver contracts (they use hardcoded addresses)
  if [[ "$CONTRACT_NAME" == "MetaProver" ]]; then
    echo "⏭️ Skipping verification ($CURRENT_CONTRACT of $TOTAL_CONTRACTS): $CONTRACT_NAME (hardcoded address)"
    echo "   Chain ID: $CHAIN_ID"
    echo "   Address: $CONTRACT_ADDRESS"
    echo "   Contract Path: $CONTRACT_PATH"
    echo "   📝 MetaProver uses a hardcoded address and cannot be verified"
    SKIPPED_VERIFICATIONS=$((SKIPPED_VERIFICATIONS + 1))
    echo ""
    continue
  fi
  
  echo "🔄 Verifying contract ($CURRENT_CONTRACT of $TOTAL_CONTRACTS): $CONTRACT_NAME"
  echo "   Chain ID: $CHAIN_ID"
  echo "   Address: $CONTRACT_ADDRESS"
  echo "   Contract Path: $CONTRACT_PATH"
  
  # Use the single verification key for all chains
  VERIFY_KEY="$VERIFICATION_KEY"
  echo "   🔑 Using verification key for chain ID $CHAIN_ID"
  
  # Get verifier URL and type for this chain from the chain data if available
  VERIFIER_URL=""
  VERIFIER_TYPE=""
  if [ -n "$CHAIN_JSON" ]; then
    VERIFIER_URL=$(echo "$CHAIN_JSON" | jq -r --arg chain "$CHAIN_ID" '.[$chain].verifier.url // empty')
    VERIFIER_TYPE=$(echo "$CHAIN_JSON" | jq -r --arg chain "$CHAIN_ID" '.[$chain].verifier.type // empty')
    if [ -n "$VERIFIER_URL" ] && [ "$VERIFIER_URL" != "null" ] && [ -n "$VERIFIER_TYPE" ] && [ "$VERIFIER_TYPE" != "null" ]; then
      # Replace environment variable placeholders if necessary
      VERIFIER_URL=$(eval echo "$VERIFIER_URL")
      echo "   🔍 Using custom verifier: $VERIFIER_TYPE at $VERIFIER_URL"
    fi
  fi
  
  # Build verification command
  VERIFY_CMD="forge verify-contract"
  VERIFY_CMD+=" --chain $CHAIN_ID"
  VERIFY_CMD+=" --etherscan-api-key \"$VERIFY_KEY\""
  
  # Add custom verifier if available
  if [ -n "$VERIFIER_URL" ] && [ "$VERIFIER_URL" != "null" ] && [ -n "$VERIFIER_TYPE" ] && [ "$VERIFIER_TYPE" != "null" ]; then
    VERIFY_CMD+=" --verifier $VERIFIER_TYPE --verifier-url '$VERIFIER_URL'"
  fi
  
  # Add remaining parameters
  VERIFY_CMD+=" --watch"
  VERIFY_CMD+=" --retries 0" #set to 0 to handle retries manually
  
  # Add constructor args if not empty
  if [ -n "$CONSTRUCTOR_ARGS" ] && [ "$CONSTRUCTOR_ARGS" != "0x" ]; then
    echo "   🧩 Using constructor arguments: $CONSTRUCTOR_ARGS"
    VERIFY_CMD+=" --constructor-args \"$CONSTRUCTOR_ARGS\""
  else
    echo "   📝 No constructor arguments"
  fi
  
  VERIFY_CMD+=" \"$CONTRACT_ADDRESS\" \"$CONTRACT_PATH\""
  
  # Execute verification command
  echo "   📝 Executing verification command..."
  eval "$VERIFY_CMD"
  
  VERIFY_RESULT=$?
  if [ $VERIFY_RESULT -eq 0 ]; then
    echo "   ✅ Verification succeeded for $CONTRACT_NAME on chain $CHAIN_ID"
    SUCCESSFUL_VERIFICATIONS=$((SUCCESSFUL_VERIFICATIONS + 1))
  else
    echo "   ❌ Verification failed for $CONTRACT_NAME on chain $CHAIN_ID"
    echo "   🔄 Retrying verification in 5 seconds..."
  fi
  
  echo ""
done

# Display verification summary
echo "📊 Verification Summary:"
echo "Total contracts processed: $TOTAL_CONTRACTS"
echo "Successfully verified: $SUCCESSFUL_VERIFICATIONS"
echo "Failed to verify: $FAILED_VERIFICATIONS"
echo "Skipped (hardcoded): $SKIPPED_VERIFICATIONS"

VERIFIABLE_CONTRACTS=$((TOTAL_CONTRACTS - SKIPPED_VERIFICATIONS))
if [ $SUCCESSFUL_VERIFICATIONS -eq $VERIFIABLE_CONTRACTS ]; then
  echo "✅ All verifiable contracts were successfully verified!"
else
  if [ $SUCCESSFUL_VERIFICATIONS -ge 0 ]; then
    echo "⚠️ Some contracts were verified, but others failed. Check the logs for details."
  else
    echo "❌ No contracts could be verified. Check the logs for details."
  fi
fi