#!/bin/bash

# Load environment variables from .env safely
if [ -f .env ]; then
    set -a  # Export all variables automatically
    source .env
    set +a
fi

# Ensure RESULTS_FILE is set
if [ -z "$RESULTS_FILE" ]; then
    echo "❌ Error: RESULTS_FILE is not set in .env!"
    exit 1
fi

# Ensure deploy file exists
if [ ! -f "$RESULTS_FILE" ]; then
    echo "❌ Error: $RESULTS_FILE not found!"
    exit 1
fi

# Check if verification keys are provided in the environment
if [ -n "$VERIFICATION_KEYS" ]; then
    echo "📄 Using verification keys from VERIFICATION_KEYS environment variable"
else
    echo "⚠️ No verification keys provided in VERIFICATION_KEYS environment variable."
    echo "⚠️ Will attempt to use individual API key environment variables for verification."
fi

# Read deployment data and verify contracts
while IFS=, read -r CHAIN_ID CONTRACT_ADDRESS CONTRACT_PATH CONSTRUCTOR_ARGS; do
    # Skip empty lines
    if [ -z "$CHAIN_ID" ] || [ -z "$CONTRACT_ADDRESS" ]; then
        continue
    fi

    CHAIN_ID=$(echo "$CHAIN_ID" | tr -d '[:space:]')
    CONTRACT_ADDRESS=$(echo "$CONTRACT_ADDRESS" | tr -d '[:space:]')
    CONTRACT_PATH=$(echo "$CONTRACT_PATH" | xargs)
    CONSTRUCTOR_ARGS=$(echo "$CONSTRUCTOR_ARGS" | xargs 2>/dev/null || echo "")

    echo "🔍 Verifying contract $CONTRACT_ADDRESS on Chain ID $CHAIN_ID"

    # Try to get the API key from the verification keys json first
    if [ -n "$VERIFICATION_KEYS" ]; then
        ETHERSCAN_API_KEY=$(echo "$VERIFICATION_KEYS" | jq -r --arg chain "$CHAIN_ID" '.[$chain] // empty')
    fi
    
    # Fallback to environment variables if not found in VERIFICATION_KEYS
    if [ -z "$ETHERSCAN_API_KEY" ]; then
        eval "ETHERSCAN_API_KEY=\$ETHERSCAN_API_KEY_$CHAIN_ID"
    fi

    if [ -z "$ETHERSCAN_API_KEY" ]; then
        echo "❌ Error: No API key found for Chain ID $CHAIN_ID, skipping verification."
        continue
    fi

    VERIFY_CMD="forge verify-contract \
        --chain-id $CHAIN_ID \
        --etherscan-api-key $ETHERSCAN_API_KEY"
    
    # Only add constructor args if they exist
    if [ -n "$CONSTRUCTOR_ARGS" ]; then
        VERIFY_CMD+=" --constructor-args $CONSTRUCTOR_ARGS"
    fi
    
    VERIFY_CMD+=" $CONTRACT_ADDRESS $CONTRACT_PATH"

    # Attempt verification
    echo "Running: $VERIFY_CMD"
    eval $VERIFY_CMD
    exit_code=$?

    if [ $exit_code -ne 0 ]; then
        echo "❌ Verification failed for $CONTRACT_ADDRESS on Chain ID $CHAIN_ID. Retrying in 3 seconds..."
        sleep 3
        eval $VERIFY_CMD  # Retry once
        exit_code=$?

        if [ $exit_code -ne 0 ]; then
            echo "❌ Verification failed again for $CONTRACT_ADDRESS on Chain ID $CHAIN_ID. Skipping..."
        else
            echo "✅ Successfully verified $CONTRACT_ADDRESS ($CONTRACT_PATH) on retry!"
        fi
    else
        echo "✅ Successfully verified $CONTRACT_ADDRESS ($CONTRACT_PATH) on Chain ID $CHAIN_ID"
    fi

    # New lines
    echo ""
    echo ""
done < "$RESULTS_FILE"