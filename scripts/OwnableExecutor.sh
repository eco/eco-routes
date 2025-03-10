#!/bin/bash

# Load environment variables from .env safely
if [ -f .env ]; then
    set -a  # Export all variables automatically
    source .env
    set +a
fi

# Ensure CHAIN_IDS is set
if [ -z "$CHAIN_IDS" ]; then
    echo "❌ Error: CHAIN_IDS variable is empty! Set it in the .env file."
    exit 1
fi

# Ensure chain.json exists
CHAIN_JSON="./scripts/assets/chain.json"
if [ ! -f "$CHAIN_JSON" ]; then
    echo "❌ Error: Missing chain.json file!"
    exit 1
fi

# Convert comma-separated CHAIN_IDS into an array
IFS=',' read -r -a CHAINS <<< "$CHAIN_IDS"

# Read chain.json into a variable
CHAIN_DATA=$(cat "$CHAIN_JSON")

# Loop through each chain and deploy Ownable Executor
for CHAIN_ID in "${CHAINS[@]}"; do
    RPC_URL=$(echo "$CHAIN_DATA" | jq -r --arg CHAIN_ID "$CHAIN_ID" '.[$CHAIN_ID].url')

    if [[ "$RPC_URL" == "null" || -z "$RPC_URL" ]]; then
        echo "⚠️  Warning: No RPC URL found for Chain ID $CHAIN_ID. Skipping..."
        continue
    fi

    # Replace environment variable placeholders if necessary
    RPC_URL=$(eval echo "$RPC_URL")
    
    if [[ "$RPC_URL" == *"${ALCHEMY_API_KEY}"* && -z "$ALCHEMY_API_KEY" ]]; then
        echo "❌ Error: ALCHEMY_API_KEY is required but not set."
        exit 1
    fi

    EXECUTOR_ADDRESS="0x4Fd8d57b94966982B62e9588C27B4171B55E8354"
    CODE=$(cast code $EXECUTOR_ADDRESS --rpc-url "$RPC_URL")

    if [ "$CODE" == "0x" ]; then
        echo "🔄 Deploying Ownable Executor on Chain ID: $CHAIN_ID"
        cast send 0x000000000069E2a187AEFFb852bF3cCdC95151B2 \
            0x03b79c840000000000000000000000000000000000000000000000000000000000001337dbca873b13c783c0c9c6ddfc4280e505580bf6cc3dac83f8a0f7b44acaafca4f \
            --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY"
        echo "✅ Ownable Executor deployed on Chain ID: $CHAIN_ID"
    else
        echo "✅ Ownable Executor already deployed on Chain ID: $CHAIN_ID"
    fi

done
