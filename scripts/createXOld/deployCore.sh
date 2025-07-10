#!/usr/bin/env bash

# Load environment variables from .env, prioritizing existing env vars
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../utils/load_env.sh"
load_env

# Load the chain data utility function
source "$SCRIPT_DIR/../../utils/load_chain_data.sh"

# Ensure CHAIN_DATA_URL is set
if [ -z "$CHAIN_DATA_URL" ]; then
    echo "❌ Error: CHAIN_DATA_URL is not set in .env\!"
    exit 1
fi

# Load the chain data using the utility function
CHAIN_JSON=$(load_chain_data "$CHAIN_DATA_URL")
if [ $? -ne 0 ]; then
    # Error messages are already displayed by the function
    exit 1
fi

# Verify bytecode file exists
if [ \! -f "$BYTECODE_PATH" ]; then
    echo "❌ Error: Bytecode deployment file not found at $BYTECODE_PATH"
    exit 1
fi
echo "Using bytecode file: $BYTECODE_PATH"

# Create output directories for deployment verification data
DEPLOYMENT_DATA_DIR="out"
mkdir -p $DEPLOYMENT_DATA_DIR
echo "Created deployment data directory: $DEPLOYMENT_DATA_DIR"

# File to store all deployment data for verification
DEPLOYED_CONTRACTS_FILE="$DEPLOYMENT_DATA_DIR/deployed_contracts.csv"

# Delete the deployment contracts file if it exists
if [ -f "$DEPLOYED_CONTRACTS_FILE" ]; then
    echo "🗑️ Removing existing deployment data file: $DEPLOYED_CONTRACTS_FILE"
    rm "$DEPLOYED_CONTRACTS_FILE"
fi

# Create header for CSV file
echo "ChainID,Environment,ContractName,ContractAddress,ContractPath" > $DEPLOYED_CONTRACTS_FILE
echo "📝 Created new deployment data file with header"

PUBLIC_ADDRESS=$(cast wallet address --private-key "$PRIVATE_KEY")
echo "Wallet Public Address: $PUBLIC_ADDRESS"

CREATE_X_DEPLOYER_ADDRESS='0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed'

# Process each chain from the JSON data
echo "$CHAIN_JSON" | jq -c 'to_entries[]' | while IFS= read -r entry; do
    CHAIN_ID=$(echo "$entry" | jq -r '.key')
    value=$(echo "$entry" | jq -c '.value')

    RPC_URL=$(echo "$value" | jq -r '.url')

    if [ "$RPC_URL" = "null" ] || [ -z "$RPC_URL" ]; then
        echo "⚠️  Warning: Missing required data for Chain ID $CHAIN_ID. Skipping..."
        continue
    fi

    # Replace environment variable placeholders if necessary
    RPC_URL=$(eval echo "$RPC_URL")
    
    # Check for API keys in URL
    if [ -z "$ALCHEMY_API_KEY" ] && echo "$RPC_URL" | grep -q "${ALCHEMY_API_KEY}"; then
        echo "❌ Error: ALCHEMY_API_KEY is required but not set."
        exit 1
    fi

    echo "🔄 Processing Chain ID: $CHAIN_ID with RPC URL: $RPC_URL"

    # Check if CREATE_X_DEPLOYER is deployed on this chain
    code=$(cast code $CREATE_X_DEPLOYER_ADDRESS --rpc-url "$RPC_URL")
    if [ "$code" = "0x" ]; then
        echo "❌ Error: CREATE_X_DEPLOYER_ADDRESS not deployed on chain ID: $CHAIN_ID"
        continue
    fi

    # Process each environment (default and pre) from the bytecode deployment file
    jq -c 'keys[]' "$BYTECODE_PATH" | while IFS= read -r env_key; do
        # Remove quotes from env_key
        ENV_NAME=$(echo "$env_key" | tr -d '"')
        echo "🔄 Deploying for environment: $ENV_NAME"

        # Access contracts in this environment
        CONTRACT_DATA=$(jq -c ".$ENV_NAME.contracts" "$BYTECODE_PATH")
        SALT=$(jq -r ".$ENV_NAME.salt" "$BYTECODE_PATH")
        KECCAK_SALT=$(jq -r ".$ENV_NAME.keccakSalt" "$BYTECODE_PATH")
        echo "  🔑 Using salt: $SALT"
        
        # Process each contract
        echo "$CONTRACT_DATA" | jq -c 'keys[]' | while IFS= read -r contract_name; do
            # Remove quotes from contract_name
            CONTRACT_NAME=$(echo "$contract_name" | tr -d '"')
            echo "  🔄 Processing contract: $CONTRACT_NAME"
            
            # Get contract path and initCodeHash
            CONTRACT_PATH=$(jq -r ".$ENV_NAME.contracts.$CONTRACT_NAME.contractPath" "$BYTECODE_PATH")
            INIT_CODE_HASH=$(jq -r ".$ENV_NAME.contracts.$CONTRACT_NAME.initCodeHash" "$BYTECODE_PATH")
            
            if [ "$CONTRACT_PATH" = "null" ] || [ -z "$CONTRACT_PATH" ]; then
                echo "    ❌ Error: contractPath not found for $CONTRACT_NAME"
                continue
            fi
            
            if [ "$INIT_CODE_HASH" = "null" ]; then
                echo "    ❌ Error: initCodeHash not found for $CONTRACT_NAME in $BYTECODE_PATH"
                continue
            fi
            
            # Get deployBytecode
            DEPLOY_BYTECODE=$(jq -r ".$ENV_NAME.contracts.$CONTRACT_NAME.deployBytecode" "$BYTECODE_PATH")
            if [ "$DEPLOY_BYTECODE" = "null" ] || [ -z "$DEPLOY_BYTECODE" ]; then
                echo "    ❌ Error: deployBytecode not found for $CONTRACT_NAME"
                continue
            fi
            
            # Compute the expected address using cast call to CREATE_X_DEPLOYER's computeCreate2Address function
            echo "    🧮 Computing CREATE2 address for $CONTRACT_NAME..."
            EXPECTED_ADDRESS=$(cast call $CREATE_X_DEPLOYER_ADDRESS "computeCreate2Address(bytes32,bytes32)(address)" "$KECCAK_SALT" "$INIT_CODE_HASH" --rpc-url "$RPC_URL")
            echo "    🔍 Computed expected address: $EXPECTED_ADDRESS"
            
            # Check if contract is already deployed
            code=$(cast code "$EXPECTED_ADDRESS" --rpc-url "$RPC_URL")
            if [ "$code" = "0x" ]; then
                echo "    🔄 Deploying $CONTRACT_NAME to expected address: $EXPECTED_ADDRESS"
                
                # Deploy contract using CREATE_X_DEPLOYER_ADDRESS
                # The cast send command sends the deployBytecode to the CREATE_X_DEPLOYER
                cast send $CREATE_X_DEPLOYER_ADDRESS $DEPLOY_BYTECODE --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY"
                
                if [ $? -eq 0 ]; then
                    echo "    ✅ Successfully deployed $CONTRACT_NAME on chain ID: $CHAIN_ID"
                    
                    # Verify deployment worked by checking code at expected address
                    code=$(cast code "$EXPECTED_ADDRESS" --rpc-url "$RPC_URL")
                    if [ "$code" = "0x" ]; then
                        echo "    ❌ Deployment verification failed for $CONTRACT_NAME. No code at expected address."
                    else 
                        echo "    ✅ Deployment verified for $CONTRACT_NAME at $EXPECTED_ADDRESS"
                        
                        # Record successful deployment in the deployment data files
                        echo "$CHAIN_ID,$ENV_NAME,$CONTRACT_NAME,$EXPECTED_ADDRESS,$CONTRACT_PATH" >> $DEPLOYED_CONTRACTS_FILE
                        
                        echo "    📝 Recorded deployment data for verification"
                    fi
                else 
                    echo "    ❌ Failed to deploy $CONTRACT_NAME on chain ID: $CHAIN_ID"
                fi
            else 
                echo "    ✅ $CONTRACT_NAME already deployed at $EXPECTED_ADDRESS"
                
                # Record existing deployment in the deployment data files
                echo "$CHAIN_ID,$ENV_NAME,$CONTRACT_NAME,$EXPECTED_ADDRESS,$CONTRACT_PATH" >> $DEPLOYED_CONTRACTS_FILE
                
                echo "    📝 Recorded existing deployment data for verification"
            fi
        done
    done

    echo "✅ Deployment on Chain ID: $CHAIN_ID completed\!"
done

# Display summary of deployments
if [ -f "$DEPLOYED_CONTRACTS_FILE" ]; then
    DEPLOYMENT_COUNT=$(grep -c "^" "$DEPLOYED_CONTRACTS_FILE")
    DEPLOYMENT_COUNT=$((DEPLOYMENT_COUNT - 1))  # Subtract header line
    echo ""
    echo "📊 Deployment Summary:"
    echo "Total contracts deployed/recorded: $DEPLOYMENT_COUNT"
    echo "Deployment data saved to: $DEPLOYED_CONTRACTS_FILE"
    echo ""
    echo "To verify these contracts, run: ./scripts/verifyCore.sh"
fi
