#!/usr/bin/env bash
#
# deployGatewayERC20Factories.sh
#
# Deploys DepositFactory_CCTPMint_GatewayERC20 to Base, Optimism, and Arbitrum
# using CREATE3 for deterministic same-address deployment.
#
# Environment variables (required):
#   PRIVATE_KEY   - Deployer private key
#   SALT          - Root salt for CREATE3 (bytes32 hex)
#
# Optional:
#   ALCHEMY_API_KEY - For Alchemy RPC URLs (default RPCs used otherwise)
#
# Usage:
#   PRIVATE_KEY=0x... SALT=0x... ./scripts/deployGatewayERC20Factories.sh
#   PRIVATE_KEY=0x... SALT=0x... ./scripts/deployGatewayERC20Factories.sh --predict  # dry-run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load .env if present
if [ -f "$ROOT_DIR/.env" ]; then
    set -a
    source "$ROOT_DIR/.env"
    set +a
fi

# Validate required env vars
: "${PRIVATE_KEY:?PRIVATE_KEY is required}"
: "${SALT:?SALT is required}"

# USDC addresses per source chain
declare -A USDC_ADDRESSES=(
    [8453]="0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"   # Base
    [10]="0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85"      # Optimism
    [42161]="0xaf88d065e77c8cC2239327C5EDb3A432268e5831"    # Arbitrum
)

# RPC URLs (override with env vars if needed)
declare -A RPC_URLS
RPC_URLS[8453]="${BASE_RPC_URL:-https://mainnet.base.org}"
RPC_URLS[10]="${OPTIMISM_RPC_URL:-https://mainnet.optimism.io}"
RPC_URLS[42161]="${ARBITRUM_RPC_URL:-https://arb1.arbitrum.io/rpc}"

CHAIN_NAMES=([8453]="Base" [10]="Optimism" [42161]="Arbitrum")
CHAIN_IDS=(8453 10 42161)

# Check for --predict flag
PREDICT_ONLY=false
if [[ "${1:-}" == "--predict" ]]; then
    PREDICT_ONLY=true
fi

echo "══════════════════════════════════════════════════════════════"
echo "  Deploy DepositFactory_CCTPMint_GatewayERC20 (→ Polygon)"
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "  Salt: $SALT"
echo "  Chains: Base (8453), Optimism (10), Arbitrum (42161)"
echo "  Destination: Polygon (137)"
echo ""

if $PREDICT_ONLY; then
    echo "  Mode: PREDICT ONLY (dry-run)"
    echo ""

    # Just predict on one chain (address is same on all)
    CHAIN_ID="${CHAIN_IDS[0]}"
    SOURCE_TOKEN="${USDC_ADDRESSES[$CHAIN_ID]}" \
    SALT="$SALT" \
    PRIVATE_KEY="$PRIVATE_KEY" \
    forge script "$ROOT_DIR/scripts/DeployGatewayERC20Factory.s.sol" \
        --sig "predictAddress()" \
        --rpc-url "${RPC_URLS[$CHAIN_ID]}" \
        2>&1

    exit 0
fi

echo "  Mode: DEPLOY (broadcast)"
echo ""

DEPLOYED_ADDRESSES=()

for CHAIN_ID in "${CHAIN_IDS[@]}"; do
    CHAIN_NAME="${CHAIN_NAMES[$CHAIN_ID]}"
    SOURCE_TOKEN="${USDC_ADDRESSES[$CHAIN_ID]}"
    RPC_URL="${RPC_URLS[$CHAIN_ID]}"

    echo "──────────────────────────────────────────────────────────────"
    echo "  Deploying to $CHAIN_NAME ($CHAIN_ID)"
    echo "  Source Token (USDC): $SOURCE_TOKEN"
    echo "  RPC: $RPC_URL"
    echo "──────────────────────────────────────────────────────────────"

    SOURCE_TOKEN="$SOURCE_TOKEN" \
    SALT="$SALT" \
    PRIVATE_KEY="$PRIVATE_KEY" \
    forge script "$ROOT_DIR/scripts/DeployGatewayERC20Factory.s.sol" \
        --rpc-url "$RPC_URL" \
        --broadcast \
        --slow \
        2>&1

    echo ""
    echo "  ✓ $CHAIN_NAME deployment complete"
    echo ""
done

echo "══════════════════════════════════════════════════════════════"
echo "  All deployments complete!"
echo "══════════════════════════════════════════════════════════════"
