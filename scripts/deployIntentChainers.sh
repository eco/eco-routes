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
: "${ALCHEMY_API_KEY:?ALCHEMY_API_KEY is required for the RPC templates}"


# Confirmed to hold Portal bytecode. Sanko (1996), inEVM (2525), Rari
# (1380012617), Form (478) and Molten (360) are in eco-chains but were not
# reachable over a public endpoint — add them once an RPC is available and the
# Portal is confirmed there.
MAINNETS="1 10 56 130 137 146 169 466 480 999 5000 5330 8333 8453 9745 33139 42161 42220 57073 10241024"
TESTNETS="84532 11155111 11155420"

CHAIN_IDS="${CHAIN_IDS:-$MAINNETS}"

rpc_url() {
    local override
    override="$(eval "echo \${RPC_$1:-}")"
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

    echo
    echo "  [$chain_id] ..."
    (
        cd "$ROOT_DIR" && PRIVATE_KEY="$PRIVATE_KEY" SALT="$SALT" \
            forge script scripts/DeployIntentChainer.s.sol \
            --rpc-url "$rpc" --broadcast --slow
    )
done

echo
echo "done — IntentChainer at $EXPECTED on: $CHAIN_IDS"
