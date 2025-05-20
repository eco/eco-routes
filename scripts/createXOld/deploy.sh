#!/usr/bin/env bash

# Load environment variables from .env, prioritizing existing env vars
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../utils/load_env.sh"
load_env

# Ensure RESULTS_FILE is set
if [ -z "$RESULTS_FILE" ]; then
    echo "❌ Error: RESULTS_FILE is not set in .env!"
    exit 1
fi

# We'll create the header for RESULTS_FILE once we know all the contract names
echo "🧹 Will clean up $RESULTS_FILE for new deployment"

# Function to compute CREATE2 address and check if contract is already deployed
check_create2_deployed() {
    local createX_deployer=$1
    local salt=$2
    local initCodeHash=$3
    local rpc_url=$4
    local contract_name=$5

    # Call the CreateX deployer to compute the deterministic address
    # Using computeCreate2Address function as per https://github.com/pcaversaccio/createx
    echo "🧮 Computing CREATE2 address for $contract_name..."
    local predicted_address=$(cast call "$createX_deployer" "computeCreate2Address(bytes32,bytes32)(address)" "$salt" "$initCodeHash" --rpc-url "$rpc_url")

    if [ $? -ne 0 ]; then
        echo "⚠️ Failed to compute CREATE2 address. The deployer might not support this function."
        return 1
    fi
    
    echo "🔍 Predicted address: $predicted_address"
    
    # Check if there's already code deployed at this address
    # local code_size=$(cast code "$predicted_address" --rpc-url "$rpc_url" | wc -c)
    local code=$(cast code "$predicted_address" --rpc-url "$rpc_url" )
    # echo "📏 Code size at $predicted_address: $code_size "
    # If code length is more than 2 (which would be just "0x"), then there's code at the address
    if [ "$code" == "0x" ]; then
        echo "🆕 No contract found at $predicted_address. Need to deploy."
        return 1
    else
        echo "✅ Contract already deployed at $predicted_address"
        return 0
    fi
}

# Check if PRIVATE_KEY is set
if [ -z "$PRIVATE_KEY" ]; then
    echo "❌ Error: PRIVATE_KEY is not set in environment variables!"
    exit 1
fi

# Get the deployment data URL from the same source as MultiDeploy.sh
if [ -z "$DEPLOY_DATA_URL" ]; then
    echo "❌ Error: DEPLOY_DATA_URL is not set!"
    exit 1
fi

# Path to the bytecode file
BYTECODE_FILE="./build/deployBytecode.json"
if [ ! -f "$BYTECODE_FILE" ]; then
    echo "❌ Error: Bytecode file not found at $BYTECODE_FILE"
    exit 1
fi

# Get the deployment data from the URL for RPC endpoints
echo "📥 Fetching deployment data from $DEPLOY_DATA_URL..."
DEPLOY_JSON=$(curl -s "$DEPLOY_DATA_URL")

# Ensure deploy data is pulled
if [ -z "$DEPLOY_JSON" ]; then
    echo "❌ Error: Could not get deployment data from URL: $DEPLOY_DATA_URL"
    exit 1
fi
echo "✅ Deployment data loaded successfully"

# Get the wallet address
PUBLIC_ADDRESS=$(cast wallet address --private-key "$PRIVATE_KEY")
echo "👛 Wallet Public Address: $PUBLIC_ADDRESS"

# Get root level keys from deployBytecode.json (these are environment names like "default", "production", etc.)
ROOT_KEYS=$(jq -r 'keys[]' "$BYTECODE_FILE")

# Create header for RESULTS_FILE
echo -n "Environment,ChainID" > $RESULTS_FILE

# First, collect all unique contract names across all environments
ALL_CONTRACT_NAMES=""
for ENV_KEY in $ROOT_KEYS; do
    ENV_CONTRACT_KEYS=$(jq -r ".[\"$ENV_KEY\"].contracts | keys[]" "$BYTECODE_FILE")
    ALL_CONTRACT_NAMES="$ALL_CONTRACT_NAMES $ENV_CONTRACT_KEYS"
done

# Add unique contract names to header
UNIQUE_CONTRACT_NAMES=$(echo $ALL_CONTRACT_NAMES | tr ' ' '\n' | sort | uniq)
for CONTRACT_NAME in $UNIQUE_CONTRACT_NAMES; do
    echo -n ",$CONTRACT_NAME" >> $RESULTS_FILE
done
echo "" >> $RESULTS_FILE
echo "📋 Created CSV header with all contract names"

# Loop through each environment in the bytecode file
for ENV_KEY in $ROOT_KEYS; do
    echo "🔄 Processing environment: $ENV_KEY"
    
    # Get a contract list by finding unique contract names across all chains for this environment
    CONTRACT_KEYS=$(jq -r --arg env "$ENV_KEY" '.[$env] | .[] | .contracts | keys | .[]' "$BYTECODE_FILE" | sort -u)
    echo "📜 Contracts to deploy: $CONTRACT_KEYS"

     # Get the createX deployer address and keccak salt from a specific environment and chain
    # We need to find a chain ID in the specified environment
    FIRST_CHAIN_ID=$(jq -r --arg env "$ENV_KEY" '.[$env] | keys | .[0]' "$BYTECODE_FILE")

    if [[ "$FIRST_CHAIN_ID" == "null" || -z "$FIRST_CHAIN_ID" ]]; then
        echo "❌ Error: No chain IDs found in bytecode file for environment $ENV_KEY."
        exit 1
    fi

    echo "🔍 Using environment $ENV_KEY, chain ID $FIRST_CHAIN_ID to get common deployment data"

    # Get the default CREATE2 deployer address
    CREATEX_DEPLOYER_ADDRESS="0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed"  # Default CREATE2 deployer address
    
    # Get data from the bytecode file
    KECCAK_SALT=$(jq -r --arg env "$ENV_KEY" --arg chainId "$FIRST_CHAIN_ID" '.[$env][$chainId].keccakSalt' "$BYTECODE_FILE")
    if [[ "$KECCAK_SALT" == "null" || -z "$KECCAK_SALT" ]]; then
        echo "❌ Error: Salt not set in bytecode file for environment $ENV_KEY, chain $FIRST_CHAIN_ID."
        exit 1
    fi
    echo "🔑 Using salt: $KECCAK_SALT"

    # Process each chain from the deployment JSON data
    echo "$DEPLOY_JSON" | jq -c 'to_entries[]' | while IFS= read -r entry; do
        CHAIN_ID=$(echo "$entry" | jq -r '.key')
        value=$(echo "$entry" | jq -c '.value')
        
        RPC_URL=$(echo "$value" | jq -r '.url')
        GAS_MULTIPLIER=$(echo "$value" | jq -r '.gasMultiplier // ""')

        if [[ "$RPC_URL" == "null" || -z "$RPC_URL" ]]; then
            echo "⚠️  Warning: Missing required data for Chain ID $CHAIN_ID. Skipping..."
            continue
        fi
        
        # Replace environment variable placeholders if necessary
        RPC_URL=$(eval echo "$RPC_URL")
        
        # Check for API keys in URL
        if [[ "$RPC_URL" == *"${ALCHEMY_API_KEY}"* && -z "$ALCHEMY_API_KEY" ]]; then
            echo "❌ Error: ALCHEMY_API_KEY is required but not set."
            exit 1
        fi
        
        echo "🌐 Deploying contracts to Chain ID: $CHAIN_ID with RPC: $RPC_URL"
        
        # Initialize CSV row with environment and chain ID
        CSV_ROW="$ENV_KEY,$CHAIN_ID"
        # Create a map for contract addresses - must be declared local to avoid name conflicts
        declare -A CONTRACT_ADDRESSES=()
        # Debug information
        echo "🔍 Starting fresh contract addresses map for $ENV_KEY on chain $CHAIN_ID"
        
        # Loop through each contract and deploy using cast
        for CONTRACT_NAME in $CONTRACT_KEYS; do
            echo "📝 Processing contract: $CONTRACT_NAME"
            
            # Extract bytecode from the environment-specific and chain-specific sections
            BYTECODE=$(jq -r --arg env "$ENV_KEY" --arg chain "$CHAIN_ID" --arg contract "$CONTRACT_NAME" '.[$env][$chain].contracts[$contract].deployBytecode // ""' "$BYTECODE_FILE")
            
            # Skip if bytecode is empty or null
            if [[ -z "$BYTECODE" || "$BYTECODE" == "null" ]]; then
                echo "⚠️ Warning: No bytecode found for $CONTRACT_NAME on chain $CHAIN_ID in environment $ENV_KEY. Skipping..."
                CONTRACT_ADDRESSES["$CONTRACT_NAME"]="undefined"
                continue
            fi

            # Extract init code hash
            INIT_CODE_HASH=$(jq -r --arg env "$ENV_KEY" --arg chain "$CHAIN_ID" --arg contract "$CONTRACT_NAME" '.[$env][$chain].contracts[$contract].initCodeHash // ""' "$BYTECODE_FILE")
            
            if [[ -z "$INIT_CODE_HASH" || "$INIT_CODE_HASH" == "null" ]]; then
                echo "❌ Error: initCodeHash not set for contract $CONTRACT_NAME on chain $CHAIN_ID in environment $ENV_KEY"
                CONTRACT_ADDRESSES["$CONTRACT_NAME"]="undefined"
                continue
            fi

            # Check if contract is already deployed using CREATE2
            if check_create2_deployed "$CREATEX_DEPLOYER_ADDRESS" "$KECCAK_SALT" "$INIT_CODE_HASH" "$RPC_URL" "$CONTRACT_NAME"; then
                # Get the predicted address
                PREDICTED_ADDRESS=$(cast call "$CREATEX_DEPLOYER_ADDRESS" "computeCreate2Address(bytes32,bytes32)(address)" "$KECCAK_SALT" "$INIT_CODE_HASH" --rpc-url "$RPC_URL")
                echo " ⏭️ Skipping deployment for $CONTRACT_NAME as it's already deployed at $PREDICTED_ADDRESS"
                CONTRACT_ADDRESSES["$CONTRACT_NAME"]="$PREDICTED_ADDRESS"
                continue
            fi
            
            # Deploy using cast
            echo "🚀 Deploying $CONTRACT_NAME to chain $CHAIN_ID..."
            TEMP_BYTECODE_FILE=$(mktemp)
            echo "$BYTECODE" > "$TEMP_BYTECODE_FILE"
            # Deploy using cast with bytecode from file
            FOUNDRY_CMD="cast send \"$CREATEX_DEPLOYER_ADDRESS\" \"$(cat $TEMP_BYTECODE_FILE)\" --private-key \"$PRIVATE_KEY\" --rpc-url \"$RPC_URL\"" 
            echo "Executing command: FOUNDRY_CMD"
            eval $FOUNDRY_CMD
            DEPLOY_EXIT_CODE=$?
            # Clean up temp file                                                                                                                  
            rm "$TEMP_BYTECODE_FILE"  
            
            if [ $DEPLOY_EXIT_CODE -eq 0 ]; then
                # Get the deployed address after successful deployment
                DEPLOYED_ADDRESS=$(cast call "$CREATEX_DEPLOYER_ADDRESS" "computeCreate2Address(bytes32,bytes32)(address)" "$KECCAK_SALT" "$INIT_CODE_HASH" --rpc-url "$RPC_URL")
                echo "✅ $CONTRACT_NAME deployed to: $DEPLOYED_ADDRESS on chain $CHAIN_ID"
                CONTRACT_ADDRESSES["$CONTRACT_NAME"]="$DEPLOYED_ADDRESS"
            else
                echo "❌ Failed to deploy $CONTRACT_NAME to chain $CHAIN_ID"
                CONTRACT_ADDRESSES["$CONTRACT_NAME"]="undefined"
            fi
        done
        
        # Build the CSV row with contract addresses
        for CONTRACT_NAME in $UNIQUE_CONTRACT_NAMES; do
            if [[ -v CONTRACT_ADDRESSES["$CONTRACT_NAME"] ]]; then
                CSV_ROW="$CSV_ROW,${CONTRACT_ADDRESSES[$CONTRACT_NAME]}"
            else
                CSV_ROW="$CSV_ROW,undefined"
            fi
        done
        
        # Append to CSV file
        echo "$CSV_ROW" >> $RESULTS_FILE
        
        echo "✅ Deployment on Chain ID: $CHAIN_ID completed!"
    done
done

echo "🎉 All deployments completed!"
echo "📋 Deployment results saved to $RESULTS_FILE"