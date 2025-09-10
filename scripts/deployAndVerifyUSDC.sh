#!/usr/bin/env bash
# deployAndVerifyUSDC.sh
#
# Deploys the `TestUSDC` contract and verifies it using Foundry's
# `forge create` and `forge verify-contract`. Supports reading a chain
# configuration JSON (defaults to eco-chains mock.json) to obtain RPC
# URLs and custom verifier endpoints.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils/load_env.sh"
load_env

# Required env vars: PRIVATE_KEY (for deployment), VERIFICATION_KEY (for verification)
if [ -z "$PRIVATE_KEY" ]; then
  echo "❌ Error: PRIVATE_KEY is not set in environment or .env"
  exit 1
fi

if [ -z "$VERIFICATION_KEY" ]; then
  echo "❌ Error: VERIFICATION_KEY is not set in environment or .env"
  exit 1
fi

# Optional: CHAIN_ID to deploy to one chain. Defaults to 9745 so script only publishes that chain
# Set CHAIN_ID environment variable to override.
TARGET_CHAIN_ID=${CHAIN_ID:-9745}

# Use shared utility to load chain data so .env and local files are supported
source "$SCRIPT_DIR/utils/load_chain_data.sh"
echo "📥 Loading chain data from: $CHAIN_DATA_URL"
CHAIN_JSON=$(load_chain_data "$CHAIN_DATA_URL")
if [ $? -ne 0 ]; then
  # load_chain_data already printed a helpful error
  exit 1
fi

echo "🔎 Preparing deployment targets"
if [ -n "$TARGET_CHAIN_ID" ]; then
  # Validate chain exists
  HAS_CHAIN=$(echo "$CHAIN_JSON" | jq -r --arg cid "$TARGET_CHAIN_ID" 'has($cid)')
  if [ "$HAS_CHAIN" != "true" ]; then
    echo "❌ Error: Chain ID $TARGET_CHAIN_ID not found in chain data"
    exit 1
  fi

  # Build a single-entry JSON object for processing
  PROCESS_ENTRIES=$(echo "$CHAIN_JSON" | jq -c --arg cid "$TARGET_CHAIN_ID" '{($cid): .[$cid]}')
else
  PROCESS_ENTRIES=$CHAIN_JSON
fi

echo "$PROCESS_ENTRIES" | jq -c 'to_entries[]' | while IFS= read -r entry; do
  CHAIN_ID_NOW=$(echo "$entry" | jq -r '.key')
  value=$(echo "$entry" | jq -c '.value')

  RPC_URL=$(echo "$value" | jq -r '.url')
  if [[ "$RPC_URL" == "null" || -z "$RPC_URL" ]]; then
    echo "⚠️  Skipping chain $CHAIN_ID_NOW due to missing RPC URL"
    continue
  fi
  RPC_URL=$(eval echo "$RPC_URL")

  echo "🔄 Deploying TestUSDC to chain $CHAIN_ID_NOW (RPC: $RPC_URL)"

  # Build the forge create command to deploy the contract and return address
  # Use the contract path: contracts/test/TestUSDC.sol:TestUSDC
  CREATE_CMD=(forge create --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --legacy --json --broadcast "contracts/test/TestUSDC.sol:TestUSDC")

  # Execute the create command and capture output
  echo "   📝 Executing: ${CREATE_CMD[*]}"
  CREATE_OUT=$(eval "${CREATE_CMD[*]}" 2>&1)
  CREATE_EXIT=$?
  if [ $CREATE_EXIT -ne 0 ]; then
    echo "❌ Deployment failed on chain $CHAIN_ID_NOW"
    echo "$CREATE_OUT"
    continue
  fi

  # Parse address from JSON output if possible
  CONTRACT_ADDRESS=$(echo "$CREATE_OUT" | jq -r '.transaction.contractAddress // .deployedTo // empty' 2>/dev/null)
  if [ -z "$CONTRACT_ADDRESS" ] || [ "$CONTRACT_ADDRESS" == "null" ]; then
    # Fallback: try to grep for 'Deployed to:' line
    CONTRACT_ADDRESS=$(echo "$CREATE_OUT" | grep -Eo "0x[0-9a-fA-F]{40}" | head -n1)
  fi

  if [ -z "$CONTRACT_ADDRESS" ]; then
    echo "⚠️ Could not determine deployed contract address. Skipping verification for chain $CHAIN_ID_NOW"
    continue
  fi

  echo "✅ Deployed TestUSDC at $CONTRACT_ADDRESS on chain $CHAIN_ID_NOW"

  # Get verifier info from chain data if present
  VERIFIER_URL=$(echo "$value" | jq -r '.verifier.url // empty')
  VERIFIER_TYPE=$(echo "$value" | jq -r '.verifier.type // empty')
  if [ -n "$VERIFIER_URL" ] && [ "$VERIFIER_URL" != "null" ]; then
    VERIFIER_URL=$(eval echo "$VERIFIER_URL")
    echo "   🔍 Found custom verifier for chain $CHAIN_ID_NOW: $VERIFIER_TYPE at $VERIFIER_URL"
  else
    VERIFIER_URL=""
    VERIFIER_TYPE=""
  fi

  # Run verification using forge verify-contract
  VERIFY_CMD=(forge verify-contract --chain "$CHAIN_ID_NOW" --watch --etherscan-api-key "$VERIFICATION_KEY")
  if [ -n "$VERIFIER_URL" ] && [ "$VERIFIER_URL" != "null" ] && [ -n "$VERIFIER_TYPE" ] && [ "$VERIFIER_TYPE" != "null" ]; then
    VERIFY_CMD+=(--verifier "$VERIFIER_TYPE" --verifier-url "$VERIFIER_URL")
  fi
  # No constructor args for TestUSDC
  VERIFY_CMD+=("$CONTRACT_ADDRESS" "contracts/test/TestUSDC.sol:TestUSDC")

  echo "   📝 Verifying contract: ${VERIFY_CMD[*]}"
  # Execute verify command
  eval "${VERIFY_CMD[*]}"
  VERIFY_EXIT=$?
  if [ $VERIFY_EXIT -eq 0 ]; then
    echo "   ✅ Verification succeeded for $CONTRACT_ADDRESS on chain $CHAIN_ID_NOW"
  else
    echo "   ❌ Verification failed for $CONTRACT_ADDRESS on chain $CHAIN_ID_NOW"
  fi

  echo ""
done

echo "🏁 Done"
