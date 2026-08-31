#!/usr/bin/env bash
#
# deployIntentChainers.sh
#
# Deploys IntentChainer to every named chain using CREATE3, so the contract
# lands at the SAME address everywhere. That matters more here than usual: a
# chained order names the chainer inside `intent1.route.calls[k].target`, which
# is covered by intent1's hash, so an SDK building orders for several source
# chains wants one address to hard-code rather than a per-chain table.
#
# Salt: INTENT_CHAINER_V1 (see CHAINER_VERSION in DeployIntentChainer.s.sol).
# Bump it there on any constructor or `Order` ABI change — CREATE3 derives the
# address from (deployer, salt) alone, so without a bump a new ABI lands on the
# old address and orders committed against the old shape decode into the new one.
#
# DEFAULTS TO A DRY RUN. Nothing is broadcast without an explicit --broadcast.
#
# Environment variables (required):
#   PRIVATE_KEY        - Deployer private key
#   SALT               - Root salt for CREATE3 (bytes32 hex)
#   CHAIN_IDS          - Space-separated chain ids. No default: this repo holds
#                        no registry of where eco-routes is deployed, so the list
#                        has to come from whoever owns that record.
#   PORTAL_<chain id>  - Portal address on that chain, e.g. PORTAL_8453=0x...
#                        The chainer's only constructor argument, and it differs
#                        per chain even though the chainer's own address does not.
#
# Optional:
#   RPC_<chain id>     - RPC override, e.g. RPC_8453=https://...
#                        Falls back to a public endpoint for known chains.
#
# Usage:
#   PRIVATE_KEY=0x... SALT=0x... CHAIN_IDS="10 8453 42161" \
#     PORTAL_10=0x... PORTAL_8453=0x... PORTAL_42161=0x... \
#     ./scripts/deployIntentChainers.sh
#
#   ... same, plus --broadcast   # actually deploys
#
# NOT FOR TRON. eco-routes supports TRON through a separate toolchain, and the
# CREATE3 deployer this script targets does not exist there. A TRON chainer needs
# its own path; do not add a TRON chain id to CHAIN_IDS.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BROADCAST=0
for arg in "$@"; do
    case "$arg" in
        --broadcast) BROADCAST=1 ;;
        *) echo "unknown argument: $arg" >&2; exit 1 ;;
    esac
done

# Load .env if present. Caller-provided env vars take precedence.
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

: "${PRIVATE_KEY:?PRIVATE_KEY is required}"
: "${SALT:?SALT is required}"
: "${CHAIN_IDS:?CHAIN_IDS is required — this repo has no registry of deployed chains}"

rpc_url() {
    local override
    override="$(eval "echo \${RPC_$1:-}")"
    if [ -n "$override" ]; then
        echo "$override"
        return
    fi

    case "$1" in
        1)     echo "https://ethereum.publicnode.com" ;;
        10)    echo "https://mainnet.optimism.io" ;;
        130)   echo "https://mainnet.unichain.org" ;;
        137)   echo "https://polygon-rpc.com" ;;
        146)   echo "https://rpc.soniclabs.com" ;;
        480)   echo "https://worldchain-mainnet.g.alchemy.com/public" ;;
        8453)  echo "https://mainnet.base.org" ;;
        42161) echo "https://arb1.arbitrum.io/rpc" ;;
        *)     echo "" ;;
    esac
}

portal_address() {
    eval "echo \${PORTAL_$1:-}"
}

# ---------- preflight ----------
#
# Every check here runs against every chain BEFORE anything is broadcast
# anywhere, so a misconfigured chain halts the run instead of leaving a partial
# deployment across the fleet.

echo "IntentChainer deployment"
echo "chains : $CHAIN_IDS"
echo "mode   : $([ "$BROADCAST" -eq 1 ] && echo BROADCAST || echo 'dry run (pass --broadcast to deploy)')"
echo

FAILED=0
for chain_id in $CHAIN_IDS; do
    rpc="$(rpc_url "$chain_id")"
    portal="$(portal_address "$chain_id")"

    if [ -z "$rpc" ]; then
        echo "  [$chain_id] no RPC — set RPC_$chain_id" >&2
        FAILED=1
        continue
    fi
    if [ -z "$portal" ]; then
        echo "  [$chain_id] no Portal — set PORTAL_$chain_id" >&2
        FAILED=1
        continue
    fi

    # A chainer bound to an address with no code is dead on arrival: it would
    # publish into a Portal whose Executor never calls it, stranding every order
    # ever built against it. Cheaper to catch here than after broadcast.
    code="$(cast code "$portal" --rpc-url "$rpc" 2>/dev/null || echo "0x")"
    if [ "$code" = "0x" ] || [ -z "$code" ]; then
        echo "  [$chain_id] Portal $portal has no code on this chain" >&2
        FAILED=1
        continue
    fi

    echo "  [$chain_id] portal $portal ok"
done

if [ "$FAILED" -ne 0 ]; then
    echo >&2
    echo "preflight failed — nothing was deployed" >&2
    exit 1
fi

# ---------- predict ----------
#
# CREATE3 derives the address from (deployer, salt) only, so every chain must
# predict the SAME address. A mismatch means a different deployer key or root
# salt slipped in, which would fragment the fleet — halt rather than deploy.

echo
echo "predicting addresses"
EXPECTED=""
for chain_id in $CHAIN_IDS; do
    rpc="$(rpc_url "$chain_id")"

    predicted="$(
        cd "$ROOT_DIR" && PRIVATE_KEY="$PRIVATE_KEY" SALT="$SALT" \
            forge script scripts/DeployIntentChainer.s.sol \
            --sig "predictAddress()" --rpc-url "$rpc" 2>/dev/null |
            grep -oE "Predicted addr *: 0x[0-9a-fA-F]{40}" | grep -oE "0x[0-9a-fA-F]{40}" | head -1
    )"

    if [ -z "$predicted" ]; then
        echo "  [$chain_id] could not predict address" >&2
        exit 1
    fi

    if [ -z "$EXPECTED" ]; then
        EXPECTED="$predicted"
    elif [ "$predicted" != "$EXPECTED" ]; then
        echo "  [$chain_id] predicts $predicted, expected $EXPECTED" >&2
        echo >&2
        echo "address mismatch across chains — check PRIVATE_KEY and SALT" >&2
        exit 1
    fi

    echo "  [$chain_id] $predicted"
done

echo
echo "one address on every chain: $EXPECTED"

if [ "$BROADCAST" -ne 1 ]; then
    echo
    echo "dry run complete. re-run with --broadcast to deploy."
    exit 0
fi

# ---------- deploy ----------

echo
echo "deploying"
for chain_id in $CHAIN_IDS; do
    rpc="$(rpc_url "$chain_id")"
    portal="$(portal_address "$chain_id")"

    echo
    echo "  [$chain_id] ..."
    (
        cd "$ROOT_DIR" && PRIVATE_KEY="$PRIVATE_KEY" SALT="$SALT" PORTAL="$portal" \
            forge script scripts/DeployIntentChainer.s.sol \
            --rpc-url "$rpc" --broadcast --slow
    )
done

echo
echo "done — IntentChainer at $EXPECTED on: $CHAIN_IDS"
