#!/bin/bash

# Load environment variables from .env safely
if [ -f .env ]; then
    set -a  # Export all variables automatically
    source .env
    set +a
fi
# Get the chains from GitHub
CHAIN_JSON=$(curl -s "https://raw.githubusercontent.com/eco/eco-chains/refs/heads/main/src/assets/chain.json")

# Ensure chain.json is pulled
if [ -z "$CHAIN_JSON" ]; then
  echo "❌ Error: Could not get chain.json from GitHub"
  exit 1
fi
echo "Chain JSON: $CHAIN_JSON"


REGISTRY_JSON="./scripts/assets/bytecode/registry.json"
OWNABLE_EXECUTOR_JSON="./scripts/assets/bytecode/ownable_executor.json"
REGISTRY_BYTECODE=$(jq -r '.deployBytecode // empty' "$REGISTRY_JSON")
OWNABLE_EXECUTOR_BYTECODE=$(jq -r '.deployBytecode // empty' "$OWNABLE_EXECUTOR_JSON")

# Check if the bytecode value is empty
if [ -z "$REGISTRY_BYTECODE" ] || [ -z "$OWNABLE_EXECUTOR_BYTECODE" ]; then
  echo "Error: One of the deployBytecode values is empty or not found."
  exit 1
fi

PUBLIC_ADDRESS=$(cast wallet address --private-key "$PRIVATE_KEY")

echo "Wallet Public Address: $PUBLIC_ADDRESS"

echo "$CHAIN_JSON" | jq -c 'to_entries[]' | while IFS= read -r entry; do
    chainID=$(echo "$entry" | jq -r '.key')
    value=$(echo "$entry" | jq -c '.value')

    RPC_URL=$(echo "$value" | jq -c '.url')

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

    # Check required addresses
    # Safe Singleton Factory
    code=$(cast code 0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7 --rpc-url "$RPC_URL")
    if [ "$code" == "0x" ]; then
        printf '%s\n' "Error: Safe Singleton Factory not deployed Chain ID: $chainID" >&2
        exit 1
    fi
    # Registry
    code=$(cast code 0x000000000069E2a187AEFFb852bF3cCdC95151B2 --rpc-url "$RPC_URL")
    if [ "$code" == "0x" ]; then
        echo "🔄 Deploying Rhinestone Registry on Chain ID: $chainID"
        CURRENT_GAS_PRICE=$(cast gas-price --rpc-url "$RPC_URL")
        echo "Current Gas Price: $CURRENT_GAS_PRICE"
        cast send 0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7 $REGISTRY_BYTECODE  \
            --gas-limit 5000000000 \
            --gas-price "$CURRENT_GAS_PRICE"  \
            --rpc-url "$RPC_URL" \
            --private-key "$PRIVATE_KEY" || 
            { 
                echo "❌ Failed to deploy Rhinestone Registry on Chain ID: $chainID" >&2
                exit 1
            }
            
        echo "✅ Rhinestone Registry deployed on Chain ID: $chainID"
    else
        echo "✅ Rhinestone Registry already deployed on Chain ID: $chainID"
    fi
    EXECUTOR_ADDRESS="0x4Fd8d57b94966982B62e9588C27B4171B55E8354"
    code=$(cast code $EXECUTOR_ADDRESS --rpc-url "$RPC_URL")
    if [ "$code" == "0x" ]; then
        echo "🔄 Deploying Ownable Executor on Chain ID: $chainID"
        cast send 0x000000000069E2a187AEFFb852bF3cCdC95151B2 $OWNABLE_EXECUTOR_BYTECODE \
            --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" || 
            { 
                echo "❌ Failed to deploy Ownable Executor on Chain ID: $chainID" >&2
                exit 1
            }
        echo "✅ Ownable Executor deployed on Chain ID: $chainID"
    else
        echo "✅ Ownable Executor already deployed on Chain ID: $chainID"
    fi
done