#\!/usr/bin/env bash

# Load environment variables from .env, prioritizing existing env vars
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../utils/load_env.sh"
load_env

# Define paths
DEPLOYMENT_DATA_DIR="out"
DEPLOYED_CONTRACTS_FILE="$RESULTS_FILE"
VERIFICATION_KEYS_FILE="verification-keys.json"

# Verify deployment data exists
if [ \! -f "$DEPLOYED_CONTRACTS_FILE" ]; then
  echo "❌ Error: Deployment data file not found at $DEPLOYED_CONTRACTS_FILE"
  echo "Please run deployCore.sh first to deploy contracts and generate verification data."
  exit 1
fi

# Get the deployment data from the specified URL (needed for RPC URLs)
if [ -z "$CHAIN_DATA_URL" ]; then
  echo "❌ Error: CHAIN_DATA_URL is not set in .env\!"
  exit 1
fi
CHAIN_JSON=$(curl -s "$CHAIN_DATA_URL")

# Ensure chain data is pulled
if [ -z "$CHAIN_JSON" ]; then
  echo "❌ Error: Could not get chain data from URL: $CHAIN_DATA_URL"
  exit 1
fi
echo "Chain JSON loaded successfully"

# Load verification keys from environment variable or file
VERIFICATION_KEYS=""
if [ \! -z "$VERIFICATION_KEYS" ]; then
  echo "📝 Using verification keys from VERIFICATION_KEYS environment variable"
  VERIFICATION_KEYS="$VERIFICATION_KEYS"
elif [ -f "$VERIFICATION_KEYS_FILE" ]; then
  echo "📝 Using verification keys from $VERIFICATION_KEYS_FILE"
  VERIFICATION_KEYS=$(cat "$VERIFICATION_KEYS_FILE")
else
  echo "❌ Error: Neither VERIFICATION_KEYS environment variable nor $VERIFICATION_KEYS_FILE found."
  exit 1
fi

# Process the deployment data for verification
echo "📝 Starting contract verification process..."
echo "Reading deployment data from: $DEPLOYED_CONTRACTS_FILE"

# Count total contracts to verify (skip header)
TOTAL_CONTRACTS=$(tail -n +2 "$DEPLOYED_CONTRACTS_FILE"  < /dev/null |  wc -l | tr -d ' ')
CURRENT_CONTRACT=0
SUCCESSFUL_VERIFICATIONS=0
FAILED_VERIFICATIONS=0

# Skip the header line and process each deployed contract
tail -n +2 "$DEPLOYED_CONTRACTS_FILE" | while IFS=, read -r CHAIN_ID ENV_NAME CONTRACT_NAME CONTRACT_ADDRESS CONTRACT_PATH; do
  # Increment contract counter
  CURRENT_CONTRACT=$((CURRENT_CONTRACT + 1))

  echo "🔄 Verifying contract ($CURRENT_CONTRACT of $TOTAL_CONTRACTS): $CONTRACT_NAME (Chain ID: $CHAIN_ID)"
  echo "   Address: $CONTRACT_ADDRESS"
  echo "   Contract Path: $CONTRACT_PATH"
  echo "   Environment: $ENV_NAME"

  # Get the verification key using JQ with simple key access
  VERIFY_KEY=""
  if [ -n "$VERIFICATION_KEYS" ]; then
    # Use --arg to properly handle the CHAIN_ID as a string key
    VERIFY_KEY=$(echo "$VERIFICATION_KEYS" | jq -r --arg chain "$CHAIN_ID" '.[$chain] // empty')
  fi

  # If we have a verification key for this chain
  if [ -n "$VERIFY_KEY" ] && [ "$VERIFY_KEY" \!= "null" ]; then
    echo "   🔑 Using chain-specific verification key for chain ID $CHAIN_ID"

    # Build verification command
    VERIFY_CMD="forge verify-contract --chain $CHAIN_ID --etherscan-api-key \"$VERIFY_KEY\" --watch --constructor-args \"\" $CONTRACT_ADDRESS $CONTRACT_PATH"

    # Execute verification command
    echo "   📝 Executing verification with chain-specific key..."
    eval "$VERIFY_CMD"

    VERIFY_RESULT=$?
    if [ $VERIFY_RESULT -eq 0 ]; then
      echo "   ✅ Verification succeeded for $CONTRACT_NAME on chain $CHAIN_ID"
      SUCCESSFUL_VERIFICATIONS=$((SUCCESSFUL_VERIFICATIONS + 1))
    else
      echo "   ❌ Verification failed for $CONTRACT_NAME on chain $CHAIN_ID"
      FAILED_VERIFICATIONS=$((FAILED_VERIFICATIONS + 1))
    fi
  else
    # If no verification key found, try fallback to ETHERSCAN_API_KEY
    if [ -n "$ETHERSCAN_API_KEY" ]; then
      echo "   🔑 Using fallback ETHERSCAN_API_KEY for verification"
      forge verify-contract --chain $CHAIN_ID --etherscan-api-key "$ETHERSCAN_API_KEY" --watch --constructor-args "" $CONTRACT_ADDRESS $CONTRACT_PATH
      
      VERIFY_RESULT=$?
      if [ $VERIFY_RESULT -eq 0 ]; then
        echo "   ✅ Verification succeeded for $CONTRACT_NAME on chain $CHAIN_ID with fallback key"
        SUCCESSFUL_VERIFICATIONS=$((SUCCESSFUL_VERIFICATIONS + 1))
      else
        echo "   ❌ Verification failed for $CONTRACT_NAME on chain $CHAIN_ID with fallback key"
        FAILED_VERIFICATIONS=$((FAILED_VERIFICATIONS + 1))
      fi
    else
      # Try standard verification without specific key
      echo "   📝 Executing standard verification..."
      forge verify-contract --chain $CHAIN_ID --watch --constructor-args "" $CONTRACT_ADDRESS $CONTRACT_PATH

      VERIFY_RESULT=$?
      if [ $VERIFY_RESULT -eq 0 ]; then
        echo "   ✅ Verification succeeded for $CONTRACT_NAME on chain $CHAIN_ID"
        SUCCESSFUL_VERIFICATIONS=$((SUCCESSFUL_VERIFICATIONS + 1))
      else
        echo "   ❌ Verification failed for $CONTRACT_NAME on chain $CHAIN_ID"
        FAILED_VERIFICATIONS=$((FAILED_VERIFICATIONS + 1))
      fi
    fi
  fi

  echo ""
done

# Display verification summary
echo "📊 Verification Summary:"
echo "Total contracts processed: $TOTAL_CONTRACTS"
echo "Successfully verified: $SUCCESSFUL_VERIFICATIONS"
echo "Failed to verify: $FAILED_VERIFICATIONS"

if [ $SUCCESSFUL_VERIFICATIONS -eq $TOTAL_CONTRACTS ]; then
  echo "✅ All contracts were successfully verified\!"
else
  if [ $SUCCESSFUL_VERIFICATIONS -gt 0 ]; then
    echo "⚠️ Some contracts were verified, but others failed. Check the logs for details."
  else
    echo "❌ No contracts could be verified. Check the logs for details."
  fi
fi
