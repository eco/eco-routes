#!/usr/bin/env bash

# Load environment variables from .env, prioritizing existing env vars
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../utils/load_env.sh"
load_env

# Define file paths
VERIFICATION_DATA_FILE=${RESULTS_FILE:-"out/verify-data.txt"}
BYTECODE_FILE=${BYTECODE_FILE:-"build/deployBytecode.json"}

# Ensure verification data file exists
if [ ! -f "$VERIFICATION_DATA_FILE" ]; then
    echo "❌ Error: Verification data file not found at $VERIFICATION_DATA_FILE!"
    exit 1
fi

# Ensure bytecode file exists
if [ ! -f "$BYTECODE_FILE" ]; then
    echo "❌ Error: Bytecode file not found at $BYTECODE_FILE!"
    exit 1
fi

# Check if verification key is provided in the environment
if [ -n "$VERIFICATION_KEY" ]; then
    echo "📄 Using single verification key from VERIFICATION_KEY environment variable"
else
    echo "❌ Error: No verification key provided in VERIFICATION_KEY environment variable."
    exit 1
fi

# Read the bytecode file to get constructor arguments and contract paths
echo "📄 Reading bytecode file for contract data..."
BYTECODE_JSON=$(cat "$BYTECODE_FILE")

# Read deployment data and verify contracts
while IFS=, read -r CHAIN_ID CONTRACT_ADDRESS CONTRACT_NAME ENVIRONMENT; do
    # Skip empty lines
    if [ -z "$CHAIN_ID" ] || [ -z "$CONTRACT_ADDRESS" ] || [ -z "$CONTRACT_NAME" ]; then
        continue
    fi
    
    # Clean up input
    CHAIN_ID=$(echo "$CHAIN_ID" | tr -d '[:space:]')
    CONTRACT_ADDRESS=$(echo "$CONTRACT_ADDRESS" | tr -d '[:space:]')
    CONTRACT_NAME=$(echo "$CONTRACT_NAME" | tr -d '[:space:]')
    ENVIRONMENT=$(echo "$ENVIRONMENT" | tr -d '[:space:]')
    
    echo "🔍 Verifying contract $CONTRACT_NAME at $CONTRACT_ADDRESS on Chain ID $CHAIN_ID"
    
    # Get the contract path from the environment and chain-specific data
    CONTRACT_PATH=$(echo "$BYTECODE_JSON" | jq -r --arg env "$ENVIRONMENT" --arg chain "$CHAIN_ID" --arg contract "$CONTRACT_NAME" '.[$env][$chain].contracts[$contract].contractPath // ""')
    
    # If not found, fall back to default
    if [ -z "$CONTRACT_PATH" ] || [ "$CONTRACT_PATH" = "null" ]; then
        echo "⚠️ Contract path not found in bytecode file, using default pattern"
        CONTRACT_PATH="contracts/${CONTRACT_NAME}.sol:${CONTRACT_NAME}"
    fi
    
    # Extract constructor arguments from the environment and chain-specific data
    ENCODED_ARGS=$(echo "$BYTECODE_JSON" | jq -r --arg env "$ENVIRONMENT" --arg chain "$CHAIN_ID" --arg contract "$CONTRACT_NAME" '.[$env][$chain].contracts[$contract].encodedArgs // ""')
    
    # Log what we found
    if [ -n "$ENCODED_ARGS" ] && [ "$ENCODED_ARGS" != "null" ]; then
        echo "📝 Found encoded constructor arguments for $CONTRACT_NAME"
    else
        echo "⚠️ No constructor arguments found for $CONTRACT_NAME"
        ENCODED_ARGS=""
    fi

    # Use the single verification key for all chains
    ETHERSCAN_API_KEY="$VERIFICATION_KEY"

    VERIFY_CMD="forge verify-contract \
        --chain-id $CHAIN_ID \
        --etherscan-api-key $ETHERSCAN_API_KEY"
    
    # Only add constructor args if they exist
    if [ -n "$ENCODED_ARGS" ]; then
        VERIFY_CMD+=" --constructor-args $ENCODED_ARGS"
    fi
    
    VERIFY_CMD+=" $CONTRACT_ADDRESS $CONTRACT_PATH"

    # Attempt verification
    echo "Running: $VERIFY_CMD"
    eval $VERIFY_CMD
    exit_code=$?

    if [ $exit_code -ne 0 ]; then
        echo "❌ Verification failed for $CONTRACT_ADDRESS ($CONTRACT_NAME) on Chain ID $CHAIN_ID. Retrying in 3 seconds..."
        sleep 3
        eval $VERIFY_CMD  # Retry once
        exit_code=$?

        if [ $exit_code -ne 0 ]; then
            echo "❌ Verification failed again for $CONTRACT_ADDRESS ($CONTRACT_NAME) on Chain ID $CHAIN_ID. Skipping..."
        else
            echo "✅ Successfully verified $CONTRACT_ADDRESS ($CONTRACT_NAME) on retry!"
        fi
    else
        echo "✅ Successfully verified $CONTRACT_ADDRESS ($CONTRACT_NAME) on Chain ID $CHAIN_ID"
    fi

    # New lines
    echo ""
    echo ""
done < "$VERIFICATION_DATA_FILE"