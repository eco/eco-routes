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
# Salt: INTENT_CHAINER_V5 (see CHAINER_VERSION in DeployIntentChainer.s.sol).
# Bump it there on any implementation change — CREATE3 derives the address from
# (deployer, salt) alone. An occupied salt cannot replace an older implementation;
# existing code must match the current compiled runtime exactly.
#
# DEFAULTS TO A DRY RUN. Nothing is broadcast without an explicit --broadcast.
#
# Environment variables (required):
#   PRIVATE_KEY        - Deployer private key
#   SALT               - Root salt for CREATE3 (bytes32 hex)
#   ALCHEMY_API_KEY    - Fills the Alchemy RPC templates below
#
# Optional:
#   CHAIN_IDS          - Space-separated override. Defaults to MAINNETS below.
#   RPC_<chain id>     - Per-chain RPC override
#
# The default chain list was MEASURED: each entry was confirmed to carry a
# Portal deployment. The chainer itself binds to NO Portal -- `order.portal`
# names it per order -- so this list is only "where chaining is useful", not a
# binding. Testnets are listed separately and not deployed to by default.
#
# Usage:
#   PRIVATE_KEY=0x... SALT=0x... CHAIN_IDS="10 8453 42161" \
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

# Load .env if present, preserving the caller's explicit chain selection.
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
: "${ALCHEMY_API_KEY:?ALCHEMY_API_KEY is required for the RPC templates}"


# Operator-selected V4 rollout, verified on 2026-09-09. Unfunded networks were
# explicitly excluded; CHAIN_IDS can opt them back in after they are ready.
MAINNETS="1 10 56 130 137 143 146 480 999 8453 9745 42161 42220 57073"
TESTNETS="84532 11155111 11155420"

CHAIN_IDS="${CHAIN_IDS:-$MAINNETS}"

rpc_url() {
    local override_name="RPC_$1"
    local override="${!override_name:-}"
    if [ -n "$override" ]; then
        echo "$override"
        return
    fi

    # Mirrors eco/eco-chains src/assets/chain.json, the source the release
    # tooling already uses, with public endpoints where that file has none.
    case "$1" in
        1)          echo "https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" ;;
        10)         echo "https://opt-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" ;;
        56)         echo "https://bnb-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" ;;
        130)        echo "https://unichain-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" ;;
        137)        echo "https://polygon-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" ;;
        146)        echo "https://sonic-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" ;;
        169)        echo "https://manta-pacific.calderachain.xyz/http" ;;
        466)        echo "https://rpc.appchain.xyz/http" ;;
        480)        echo "https://worldchain-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" ;;
        999)        echo "https://hyperliquid-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" ;;
        5000)       echo "https://mantle-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" ;;
        5330)       echo "https://superseed-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" ;;
        8333)       echo "https://mainnet-rpc.b3.fun/http" ;;
        8453)       echo "https://base-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" ;;
        9745)       echo "https://rpc.plasma.to" ;;
        33139)      echo "https://rpc.apechain.com/http" ;;
        42161)      echo "https://arb-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" ;;
        42220)      echo "https://celo-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" ;;
        57073)      echo "https://ink-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY" ;;
        10241024)   echo "https://rpc.alienxchain.io/http" ;;
        143)        echo "https://rpc.monad.xyz" ;;
        84532)      echo "https://base-sepolia.g.alchemy.com/v2/$ALCHEMY_API_KEY" ;;
        11155111)   echo "https://eth-sepolia.g.alchemy.com/v2/$ALCHEMY_API_KEY" ;;
        11155420)   echo "https://opt-sepolia.g.alchemy.com/v2/$ALCHEMY_API_KEY" ;;
        *)          echo "" ;;
    esac
}

gas_estimate_multiplier() {
    # HyperEVM's V4 deployment simulates below 2.9M gas. Default 130% padding
    # exceeds its live 3M small-block limit; 105% was simulated and deployed.
    # Revalidate this headroom whenever the implementation changes.
    case "$1" in
        999) echo 105 ;;
        *)   echo 130 ;;
    esac
}

# ---------- preflight ----------
#
# RPC selection, chain identity, CREATE3, precompiles, existing runtime and
# consistent address prediction are checked fleet-wide before broadcasting.
# This is not an atomic cross-chain deployment: later RPC/gas failures can still
# leave a partial rollout. Verified existing deployments make reruns idempotent.

echo "IntentChainer deployment"
echo "chains : $CHAIN_IDS"
echo "mode   : $([ "$BROADCAST" -eq 1 ] && echo BROADCAST || echo 'dry run (pass --broadcast to deploy)')"
echo

FAILED=0
for chain_id in $CHAIN_IDS; do
    if ! [[ "$chain_id" =~ ^[1-9][0-9]*$ ]]; then
        echo "invalid chain id: $chain_id" >&2
        exit 1
    fi
    rpc="$(rpc_url "$chain_id")"

    if [ -z "$rpc" ]; then
        echo "  [$chain_id] no RPC — set RPC_$chain_id" >&2
        FAILED=1
        continue
    fi

    echo "  [$chain_id] rpc ok"
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

    if ! predicted="$(
        cd "$ROOT_DIR" && PRIVATE_KEY="$PRIVATE_KEY" SALT="$SALT" EXPECTED_CHAIN_ID="$chain_id" \
            forge script scripts/DeployIntentChainer.s.sol \
            --sig "predictAddress()" --rpc-url "$rpc" 2>/dev/null |
            grep -oE "Predicted addr *: 0x[0-9a-fA-F]{40}" | grep -oE "0x[0-9a-fA-F]{40}" | head -1
    )"; then
        echo "  [$chain_id] preflight failed — check RPC chain, CREATE3, precompiles and existing runtime" >&2
        exit 1
    fi

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

    echo
    echo "  [$chain_id] ..."
    (
        cd "$ROOT_DIR" && PRIVATE_KEY="$PRIVATE_KEY" SALT="$SALT" EXPECTED_CHAIN_ID="$chain_id" \
            forge script scripts/DeployIntentChainer.s.sol \
            --rpc-url "$rpc" --broadcast --slow \
            --gas-estimate-multiplier "$(gas_estimate_multiplier "$chain_id")"
    )

    # A receipt can reach one RPC backend before another sees the new runtime.
    # Retry read-only verification, never the deployment transaction itself.
    verified=0
    for attempt in 1 2 3 4 5; do
        if (
            cd "$ROOT_DIR" && PRIVATE_KEY="$PRIVATE_KEY" SALT="$SALT" EXPECTED_CHAIN_ID="$chain_id" \
                forge script scripts/DeployIntentChainer.s.sol \
                --sig "verifyAddress()" --rpc-url "$rpc" >/dev/null 2>&1
        ); then
            verified=1
            break
        fi
        if [ "$attempt" -lt 5 ]; then sleep 2; fi
    done
    if [ "$verified" -ne 1 ]; then
        echo "  [$chain_id] runtime verification failed — reconcile the receipt before retrying" >&2
        exit 1
    fi
    echo "  [$chain_id] runtime verified"
done

echo
echo "done — IntentChainer at $EXPECTED on: $CHAIN_IDS"
