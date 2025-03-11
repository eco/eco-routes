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

# Convert comma-separated CHAIN_IDS into an array
IFS=',' read -r -a CHAINS <<< "$CHAIN_IDS"

# Loop through each chain and deploy contracts
for CHAIN_ID in "${CHAINS[@]}"; do
    RPC_URL_VAR="RPC_URL_$CHAIN_ID"
    MAILBOX_VAR="MAILBOX_$CHAIN_ID"
    GAS_MULTIPLIER_VAR="GAS_MULTIPLIER_$CHAIN_ID"

    RPC_URL="${!RPC_URL_VAR}"
    MAILBOX_CONTRACT="${!MAILBOX_VAR}"
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