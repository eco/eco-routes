#!/bin/bash

# Load environment variables from .env safely
if [ -f .env ]; then
    set -a  # Export all variables automatically
    source .env
    set +a
fi

# Ensure DEPLOY_FILE is set
if [ -z "$DEPLOY_FILE" ]; then
    echo "❌ Error: DEPLOY_FILE is not set in .env!"
    exit 1
fi

# Ensure CHAIN_IDS is properly set
if [ -z "$CHAIN_IDS" ]; then
    echo "❌ Error: CHAIN_IDS variable is empty! Set it in the .env file."
    exit 1
fi

# Remove existing deploy file before starting
if [ -f "$DEPLOY_FILE" ]; then
    echo "🗑️  Deleting previous deploy file: $DEPLOY_FILE"
    rm "$DEPLOY_FILE"
fi

touch "$DEPLOY_FILE"

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

# Loop through each chain and deploy contracts
for CHAIN_ID in "${CHAINS[@]}"; do
    RPC_URL=$(echo "$CHAIN_DATA" | jq -r --arg CHAIN_ID "$CHAIN_ID" '.[$CHAIN_ID].url')
    MAILBOX_CONTRACT=$(echo "$CHAIN_DATA" | jq -r --arg CHAIN_ID "$CHAIN_ID" '.[$CHAIN_ID].mailbox')
    # Replace environment variable placeholders if necessary
    RPC_URL=$(eval echo "$RPC_URL")

    GAS_MULTIPLIER_VAR="GAS_MULTIPLIER_$CHAIN_ID"
    GAS_MULTIPLIER="${!GAS_MULTIPLIER_VAR}"

    echo "🔄 Deploying contracts for Chain ID: $CHAIN_ID"
    echo "📬 Mailbox Contract: $MAILBOX_CONTRACT"

    if [[ -z "$RPC_URL" || -z "$MAILBOX_CONTRACT" ]]; then
        echo "⚠️  Warning: Missing variables for Chain ID $CHAIN_ID. Skipping..."
        continue
    fi

    # Construct Foundry command
    FOUNDRY_CMD="MAILBOX=\"$MAILBOX_CONTRACT\" SALT=\"$SALT\" DEPLOY_FILE=\"$DEPLOY_FILE\" forge script scripts/Deploy.s.sol \
            --rpc-url \"$RPC_URL\" \
            --slow \
            --broadcast \
            --private-key \"$PRIVATE_KEY\""

    # Only add --gas-estimate-multiplier if GAS_MULTIPLIER is defined
    if [[ -n "$GAS_MULTIPLIER" ]]; then
        echo "⛽ Gas Multiplier: $GAS_MULTIPLIER x"
        FOUNDRY_CMD+=" --gas-estimate-multiplier \"$GAS_MULTIPLIER\""
    fi

    # Run the command
    eval $FOUNDRY_CMD


    echo "✅ Deployment on Chain ID: $CHAIN_ID completed!"
done