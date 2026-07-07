#!/usr/bin/env bash
#
# deployGatewayERC20Factories.sh
#
# Deploys DepositFactory_CCTPMint_GatewayERC20 to Eco-supported CCTP source
# chains using CREATE3 for deterministic same-address deployment.
#
# Salt: GATEWAY_ERC20_FACTORY_V3 (bumped from V2 to ship the FLAT_FEE ABI to a fresh address
#       on every chain — the V2 factories on Base/Optimism/Arbitrum predate flatFee).
# V2 already deployed on: Base (8453), Optimism (10), Arbitrum (42161).
# V3 default targets: Ethereum (1), Optimism (10), Arbitrum (42161), Unichain (130),
#                     Sonic (146), World Chain (480), HyperEVM (999), Base (8453).
#
# Destination chain: Polygon PoS (137).
#
# Environment variables (required):
#   PRIVATE_KEY   - Deployer private key
#   SALT          - Root salt for CREATE3 (bytes32 hex)
#
# Optional:
#   CHAIN_IDS     - Space-separated override, e.g. CHAIN_IDS="1 130"
#   <NAME>_RPC_URL - Per-chain RPC override (ETHEREUM_RPC_URL, UNICHAIN_RPC_URL, ...)
#
# Usage:
#   PRIVATE_KEY=0x... SALT=0x... ./scripts/deployGatewayERC20Factories.sh
#   PRIVATE_KEY=0x... SALT=0x... ./scripts/deployGatewayERC20Factories.sh --predict  # dry-run
#   PRIVATE_KEY=0x... SALT=0x... CHAIN_IDS="1 130" ./scripts/deployGatewayERC20Factories.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load .env if present. Caller-provided env vars take precedence over .env values.
_CALLER_CHAIN_IDS="${CHAIN_IDS:-}"
if [ -f "$ROOT_DIR/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "$ROOT_DIR/.env"
    set +a
fi
if [ -n "$_CALLER_CHAIN_IDS" ]; then
    CHAIN_IDS="$_CALLER_CHAIN_IDS"
fi
unset _CALLER_CHAIN_IDS

# Validate required env vars
: "${PRIVATE_KEY:?PRIVATE_KEY is required}"
: "${SALT:?SALT is required}"

# Per-chain config lookups (case-based for bash 3.2 compatibility on macOS).
# USDC addresses sourced from developers.circle.com/stablecoins/usdc-contract-addresses.
chain_name() {
    case "$1" in
        1)     echo "Ethereum" ;;
        10)    echo "Optimism" ;;
        130)   echo "Unichain" ;;
        146)   echo "Sonic" ;;
        480)   echo "World Chain" ;;
        999)   echo "HyperEVM" ;;
        8453)  echo "Base" ;;
        42161) echo "Arbitrum" ;;
        *)     return 1 ;;
    esac
}

usdc_address() {
    case "$1" in
        1)     echo "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48" ;;
        10)    echo "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85" ;;
        130)   echo "0x078D782b760474a361dDA0AF3839290b0EF57AD6" ;;
        146)   echo "0x29219dd400f2Bf60E5a23d13be72b486d4038894" ;;
        480)   echo "0x79A02482A880bCe3F13E09da970dC34dB4cD24D1" ;;
        999)   echo "0xb88339CB7199b77E23DB6E890353E22632Ba630f" ;;
        8453)  echo "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" ;;
        42161) echo "0xaf88d065e77c8cC2239327C5EDb3A432268e5831" ;;
        *)     return 1 ;;
    esac
}

rpc_url() {
    case "$1" in
        1)     echo "${ETHEREUM_RPC_URL:-https://ethereum.publicnode.com}" ;;
        10)    echo "${OPTIMISM_RPC_URL:-https://mainnet.optimism.io}" ;;
        130)   echo "${UNICHAIN_RPC_URL:-https://mainnet.unichain.org}" ;;
        146)   echo "${SONIC_RPC_URL:-https://rpc.soniclabs.com}" ;;
        480)   echo "${WORLDCHAIN_RPC_URL:-https://worldchain-mainnet.g.alchemy.com/public}" ;;
        999)   echo "${HYPEREVM_RPC_URL:-https://rpc.hyperliquid.xyz/evm}" ;;
        8453)  echo "${BASE_RPC_URL:-https://mainnet.base.org}" ;;
        42161) echo "${ARBITRUM_RPC_URL:-https://arb1.arbitrum.io/rpc}" ;;
        *)     return 1 ;;
    esac
}

# Default: deploy to chains that don't already have the factory.
# Base, Optimism, and Arbitrum are already deployed — pass CHAIN_IDS="8453 10 42161"
# to re-run on those, or override entirely: CHAIN_IDS="1 130" ./scripts/...
DEFAULT_CHAIN_IDS="1 130 146 480 999"
read -r -a CHAIN_IDS <<< "${CHAIN_IDS:-$DEFAULT_CHAIN_IDS}"

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
printf "  Chains: "
for CID in "${CHAIN_IDS[@]}"; do
    printf "%s (%s)  " "$(chain_name "$CID")" "$CID"
done
printf "\n"
echo "  Destination: Polygon (137)"
echo ""

if $PREDICT_ONLY; then
    echo "  Mode: PREDICT ONLY (dry-run)"
    echo ""

    # Just predict on one chain (address is same on all)
    CHAIN_ID="${CHAIN_IDS[0]}"
    SOURCE_TOKEN="$(usdc_address "$CHAIN_ID")" \
    SALT="$SALT" \
    PRIVATE_KEY="$PRIVATE_KEY" \
    forge script "$ROOT_DIR/scripts/DeployGatewayERC20Factory.s.sol" \
        --sig "predictAddress()" \
        --rpc-url "$(rpc_url "$CHAIN_ID")" \
        2>&1

    exit 0
fi

echo "  Mode: DEPLOY (broadcast)"
echo ""

for CHAIN_ID in "${CHAIN_IDS[@]}"; do
    CHAIN_NAME="$(chain_name "$CHAIN_ID")"
    SOURCE_TOKEN="$(usdc_address "$CHAIN_ID")"
    RPC_URL="$(rpc_url "$CHAIN_ID")"

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
