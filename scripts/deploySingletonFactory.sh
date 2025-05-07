#!/usr/bin/env bash

# Script to check and deploy the SingletonFactory (ERC-2470)
# This script checks if a contract exists at the standard ERC-2470 address
# and deploys it if not present

# Load environment variables from .env, prioritizing existing env vars
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils/load_env.sh"
load_env

# Load the chain data utility function
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils/load_chain_data.sh"

# Address that will deploy the factory
FACTORY_DEPLOYER="0xBb6e024b9cFFACB947A71991E386681B1Cd1477D"

# Standard ERC-2470 Singleton Factory address
SINGLETON_FACTORY_ADDRESS="0xce0042B868300000d44A59004Da54A005ffdcf9f"

# Signed transaction to deploy the factory - this is the exact same for all chains
# Source: https://github.com/ethereum/ercs/blob/master/ERCS/erc-2470.md
SIGNED_TRANSACTION="0xf9016c8085174876e8008303c4d88080b90154608060405234801561001057600080fd5b50610134806100206000396000f3fe6080604052348015600f57600080fd5b506004361060285760003560e01c80634af63f0214602d575b600080fd5b60cf60048036036040811015604157600080fd5b810190602081018135640100000000811115605b57600080fd5b820183602082011115606c57600080fd5b80359060200191846001830284011164010000000083111715608d57600080fd5b91908080601f016020809104026020016040519081016040528093929190818152602001838380828437600092019190915250929550509135925060eb915050565b604080516001600160a01b039092168252519081900360200190f35b6000818351602085016000f5939250505056fea26469706673582212206b44f8a82cb6b156bfcc3dc6aadd6df4eefd204bc928a4397fd15dacf6d5320564736f6c634300060200331b83247000822470"

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

  echo "🔄 Processing Chain ID: $CHAIN_ID with RPC URL"

  # Check EIP-2470 deployment
  code=$(cast code $SINGLETON_FACTORY_ADDRESS --rpc-url "$RPC_URL")
  if [ "$code" == "0x" ]; then
    echo "🔄 Preparing to publish EIP-2470 on Chain ID: $CHAIN_ID"

    # Check if we need to fund the deployer account
    balance=$(cast balance $FACTORY_DEPLOYER --rpc-url "$RPC_URL")
    # Convert to eth for comparison
    balance_eth=$(cast --from-wei "$balance")

    # Check if the balance is less than 0.0247 ETH
    if (($(echo "$balance_eth < 0.0247" | bc -l))); then
      # We need to fund the account with exactly 0.0247 ETH
      echo "💰 Funding deployer account with exactly 0.0247 ETH..."

      # Calculate how much to send (0.0247 - current balance)
      to_send=$(echo "0.0247 - $balance_eth" | bc -l)

      if [ -z "$PRIVATE_KEY" ]; then
        echo "❌ Error: PRIVATE_KEY environment variable is required to fund the deployer account."
        echo "   Please set PRIVATE_KEY in your .env file or export it directly."
        continue
      fi

      # Send the exact amount needed
      echo "Sending $to_send ETH to deployer account..."
      tx_hash=$(cast send --private-key "$PRIVATE_KEY" --value $(cast --to-wei "$to_send" eth) $FACTORY_DEPLOYER --rpc-url "$RPC_URL")
      echo "Funding transaction: $tx_hash"

      # Wait for transaction to be confirmed
      echo "Waiting for funding transaction to be confirmed..."
      cast receipt "$tx_hash" --rpc-url "$RPC_URL" --async

      # Verify the balance after funding
      new_balance=$(cast balance $FACTORY_DEPLOYER --rpc-url "$RPC_URL")
      new_balance_eth=$(cast --from-wei "$new_balance")
      echo "New deployer balance: $new_balance_eth ETH"
    else
      echo "✅ Deployer account already has sufficient funds: $balance_eth ETH"
    fi

    # Now publish the signed transaction
    echo "🚀 Publishing EIP-2470 singleton factory transaction..."
    tx_hash=$(cast publish $SIGNED_TRANSACTION --rpc-url "$RPC_URL")

    if [ -n "$tx_hash" ]; then
      echo "Transaction submitted: $tx_hash"
      echo "Waiting for confirmation..."
      cast receipt "$tx_hash" --rpc-url "$RPC_URL" --async

      # Verify deployment
      code=$(cast code $SINGLETON_FACTORY_ADDRESS --rpc-url "$RPC_URL")
      if [ "$code" != "0x" ]; then
        echo "✅ EIP-2470 Singleton Factory successfully deployed on Chain ID: $CHAIN_ID"
      else
        echo "❌ Deployment failed on Chain ID: $CHAIN_ID"
      fi
    else
      echo "❌ Failed to publish transaction on Chain ID: $CHAIN_ID"
    fi
  else
    echo "✅ EIP-2470 Singleton Factory already deployed on Chain ID: $CHAIN_ID"
  fi

done
echo "ERC-2470 Singleton Factory deployment check completed."
