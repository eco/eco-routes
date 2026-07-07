/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Fixed-point scale (1e18) used as the denominator for `RewardToken.rate`. A `rate` of one WAD is a
// 1:1 same-asset reward (reward == fulfilled amount).
uint256 constant WAD = 1e18;

// Upper bound on the number of input (min-tokens) legs an intent may carry.
// Bounds gas on the destination input-pull loop and the settlement loop.
uint256 constant MAX_IN_TOKENS = 8;

// Upper bound on the number of reward legs an intent may carry. `reward.tokens` is `>= minTokens.length`
// (each input leg needs a paired reward leg) plus flat-only extras (e.g. a native gas reward); this caps
// the total so the O(n^2) uniqueness scan ({IntentLib.requireCanonicalRewardTokens}) and the O(n)
// fund / fulfill / settle loops over `reward.tokens.length` are gas-bounded. Set to 2x MAX_IN_TOKENS:
// every paired leg plus an equal budget of flat-only extras.
uint256 constant MAX_REWARD_TOKENS = MAX_IN_TOKENS * 2;

/**
 * @notice Represents a single contract call with encoded function data
 * @dev Used to execute arbitrary function calls on the destination chain
 * @param target The contract address to call
 * @param data ABI-encoded function call data
 * @param value Amount of native tokens to send with the call
 */
struct Call {
    address target;
    bytes data;
    uint256 value;
}

/**
 * @notice Represents a token amount pair
 * @dev Used to specify min-tokens floors and reward amounts. A `token` of `address(0)` denotes native.
 * @param token Address of the ERC20 token contract (or `address(0)` for native)
 * @param amount Amount of tokens in the token's smallest unit
 */
struct TokenAmount {
    address token;
    uint256 amount;
}

/**
 * @notice A dynamic reward leg (v3 rate+flat model).
 * @dev PAIRED legs (index `j < minTokens.length`): the reward owed is `fulfilled[j] * rate / WAD + flat`,
 *      capped at the account balance of `token`. `fulfilled[j]` is the amount the solver actually PROVIDED
 *      as input for leg `j` (`>= minTokens[j].amount`). The keeper bakes price/fee into `rate` (fixed-point,
 *      WAD); a same-asset, no-fee leg uses `rate == WAD`. The reward `token` MAY differ from the paired
 *      input token — `rate` encodes the conversion.
 *
 *      EXTRA legs (index `j >= minTokens.length`): FLAT-ONLY — there is no paired input leg, so the
 *      reward is exactly `flat` (the `rate` term is ignored; a well-formed extra leg sets `rate == 0`).
 *      A common extra leg is `{address(0), 0, gasAmount}` — a flat native gas reward. Native folds in as
 *      a `RewardToken` leg with `token == address(0)`; there is no separate native reward field.
 * @param token ERC20 token address escrowed in the Account, or `address(0)` for native.
 * @param rate Fixed-point (WAD) multiplier applied to the solver-provided input amount (paired legs
 *        only; ignored / expected 0 for extra flat-only legs).
 * @param flat Flat reward added on top of the rate-scaled amount (paired legs) or the whole reward
 *        (extra flat-only legs).
 */
struct RewardToken {
    address token;
    uint256 rate;
    uint256 flat;
}

/**
 * @notice Defines the routing and execution instructions for cross-chain messages
 * @dev Contains all necessary information to route and execute a message on the destination chain.
 *      `minTokens` is the enforced solver-INPUT floor: the solver must provide AT LEAST `minTokens[j].amount`
 *      of each `minTokens[j].token` into the destination execution (it may provide more). It is
 *      POSITIONALLY PAIRED with the first `minTokens.length` entries of `Reward.tokens`.
 *
 *      The core is UNOPINIONATED about where funds go: there is no `recipient` and no protocol-level
 *      output floor or auto-sweep. DELIVERY IS THE JOB OF THE COMMITTED `calls` (the payload) — any
 *      beneficiary address lives INSIDE a call's calldata, not in the Route. Any solver input the calls
 *      do not consume is not stranded: it stays WITH THE INTENT (moved to the intent's Account), where
 *      `route.keeper` can retrieve it later. See {Inbox} for the destination-side handling.
 * @param salt Unique identifier provided by the intent keeper, used to prevent duplicates
 * @param deadline Timestamp by which the route must be executed
 * @param portal Address of the portal contract on the destination chain that receives messages
 * @param keeper Owner of the DESTINATION-side account: the authority that may retrieve leftover / execute
 *        the account as owner (executeAsOwner arrives in a later stage). It lives in the Route because the
 *        destination only sees the route plus the opaque `rewardHash` and cannot read `Reward.keeper`;
 *        this is the same logical entity as `Reward.keeper` (the SOURCE escrow owner) but MAY be a
 *        DIFFERENT address across a cross-VM lane (e.g. a Solana source, an EVM destination).
 * @param calls Array of contract calls to execute on the destination chain in sequence
 * @param minTokens Minimum inputs the solver must provide into the execution (per token). Native folds in
 *        as a leg with `token == address(0)` (its `amount` is the native forwarded into execution).
 *        Length must be <= {MAX_IN_TOKENS} and MUST be STRICTLY ASCENDING by token address
 *        (native `address(0)` sorts first). Paired positionally with `Reward.tokens`.
 */
struct Route {
    bytes32 salt;
    uint64 deadline;
    address portal;
    address keeper;
    Call[] calls;
    TokenAmount[] minTokens;
}

/**
 * @notice Defines the reward and validation parameters for cross-chain execution
 * @dev `tokens` is POSITIONALLY PAIRED with `Route.minTokens` for its first `minTokens.length` entries and
 *      `tokens.length >= minTokens.length`. Legs split into PAIRED (rate+flat on `fulfilled[j]`) and EXTRA
 *      (flat-only). Native is a `RewardToken` leg with `token == address(0)` (no separate native field).
 * @param deadline Timestamp after which the intent can no longer be executed / is refundable
 * @param keeper Address that created the intent and receives remainders / refunds
 * @param prover Address of the prover (settlement policy) that must approve execution
 * @param tokens Reward legs escrowed in the Account: paired with `Route.minTokens` then optional flat-only extras
 */
struct Reward {
    uint64 deadline;
    address keeper;
    address prover;
    RewardToken[] tokens;
}

/**
 * @notice Complete cross-chain intent combining routing and reward information
 * @dev Main structure used to process and execute cross-chain messages
 * @param destination Target chain ID where the intent should be executed
 * @param route Routing and execution instructions
 * @param reward Reward and validation parameters
 */
struct Intent {
    uint64 destination;
    Route route;
    Reward reward;
}

/**
 * @title IntentLib
 * @notice Canonicalization + fulfillment-hash helpers for v3 intents.
 * @dev The intent hash algorithm is UNCHANGED from v2 (`keccak256(abi.encodePacked(uint64 destination,
 *      routeHash, rewardHash))` where `routeHash = keccak256(abi.encode(route))` and `rewardHash =
 *      keccak256(abi.encode(reward))`); only the struct contents changed. This lib adds the leg
 *      canonicalization validators and the hash-only fulfillment commitment:
 *
 *        fulfillmentHash = keccak256(abi.encode(intentHash, claimant, fulfilled))
 *
 *      Only `(intentHash, fulfillmentHash)` crosses chains; the `(claimant, fulfilled[])` preimage is
 *      supplied as calldata at `settle`, where this same helper re-derives and checks it.
 */
library IntentLib {
    /**
     * @notice A `Route.minTokens` list is not STRICTLY ASCENDING by token address.
     * @dev Strictly increasing by `uint160(token)` makes leg ordering canonical (one valid order, no
     *      reorder malleability) and AUTOMATICALLY dedupes (no repeated token). Native (`address(0)`)
     *      sorts first.
     * @param prev The earlier token address.
     * @param next The later token address that is not strictly greater than `prev`.
     */
    error MinTokensNotSorted(address prev, address next);

    /**
     * @notice The EXTRA (flat-only) reward legs are not STRICTLY ASCENDING by token address.
     * @param prev The earlier extra leg's token address.
     * @param next The later extra leg's token address that is not strictly greater than `prev`.
     */
    error RewardExtrasNotSorted(address prev, address next);

    /**
     * @notice A reward token appears more than once across all reward legs (paired + extra).
     * @dev Uniqueness is required so the Account escrows/settles each token exactly once per leg.
     * @param token The reward token that appears in more than one leg.
     */
    error RewardTokensNotUnique(address token);

    /**
     * @notice `reward.tokens.length` exceeds {MAX_REWARD_TOKENS}.
     * @param count The offending reward-leg count.
     * @param max The maximum permitted ({MAX_REWARD_TOKENS}).
     */
    error TooManyRewardTokens(uint256 count, uint256 max);

    /**
     * @notice `route.minTokens.length` exceeds {MAX_IN_TOKENS}.
     * @param count The offending min-tokens count.
     * @param max The maximum permitted ({MAX_IN_TOKENS}).
     */
    error TooManyInTokens(uint256 count, uint256 max);

    /**
     * @notice `reward.tokens.length` is less than `route.minTokens.length` (every input leg needs a paired
     *         reward leg).
     * @param rewardCount The reward-leg count.
     * @param minTokensCount The min-tokens count.
     */
    error RewardShorterThanMinTokens(uint256 rewardCount, uint256 minTokensCount);

    /**
     * @notice Requires `minTokens` to be STRICTLY ASCENDING by token address and within {MAX_IN_TOKENS}.
     * @dev Native (`address(0)`) is the smallest value and so must appear first if present. An empty or
     *      single-element list is trivially sorted (only the length bound applies).
     * @param minTokens The min-tokens legs to validate.
     */
    function requireStrictlyAscending(TokenAmount[] memory minTokens) internal pure {
        uint256 len = minTokens.length;
        if (len > MAX_IN_TOKENS) {
            revert TooManyInTokens(len, MAX_IN_TOKENS);
        }
        if (len < 2) {
            return;
        }
        address prev = minTokens[0].token;
        for (uint256 i = 1; i < len; ++i) {
            address next = minTokens[i].token;
            if (uint160(next) <= uint160(prev)) {
                revert MinTokensNotSorted(prev, next);
            }
            prev = next;
        }
    }

    /**
     * @notice Requires `reward.tokens` to be canonical relative to a strictly-ascending `minTokens`:
     *         `tokens.length >= minTokens.length` and `<= MAX_REWARD_TOKENS`, the flat-only extras strictly
     *         ascending by token, and reward tokens UNIQUE across ALL legs.
     * @dev The PAIRED prefix `[0, minTokens.length)` inherits its canonical order from `minTokens` by index
     *      (no token-equality constraint — the reward token may differ from the input token). The EXTRA
     *      range `[minTokens.length, end)` must be strictly ascending. Uniqueness across all legs is
     *      enforced by a bounded O(n^2) scan (n <= {MAX_REWARD_TOKENS}). Native (`address(0)`) folds in
     *      as a leg, so two native legs collide and are rejected.
     * @param minTokensLen The paired count (`route.minTokens.length`).
     * @param rewardTokens The reward legs to validate.
     */
    function requireCanonicalRewardTokens(
        uint256 minTokensLen,
        RewardToken[] memory rewardTokens
    ) internal pure {
        uint256 total = rewardTokens.length;

        if (total > MAX_REWARD_TOKENS) {
            revert TooManyRewardTokens(total, MAX_REWARD_TOKENS);
        }
        if (total < minTokensLen) {
            revert RewardShorterThanMinTokens(total, minTokensLen);
        }

        // EXTRA range [minTokensLen, end): flat-only legs; must be strictly ascending by token address.
        if (total > minTokensLen + 1) {
            address prev = rewardTokens[minTokensLen].token;
            for (uint256 j = minTokensLen + 1; j < total; ++j) {
                address next = rewardTokens[j].token;
                if (uint160(next) <= uint160(prev)) {
                    revert RewardExtrasNotSorted(prev, next);
                }
                prev = next;
            }
        }

        // UNIQUENESS across ALL reward legs: paired reward tokens are arbitrary source tokens (ordered by
        // the paired minOut, not by reward token), so uniqueness cannot be derived from ordering alone.
        for (uint256 a = 0; a < total; ++a) {
            address ta = rewardTokens[a].token;
            for (uint256 b = a + 1; b < total; ++b) {
                if (rewardTokens[b].token == ta) {
                    revert RewardTokensNotUnique(ta);
                }
            }
        }
    }

    /**
     * @notice Requires reward legs to be UNIQUE by token and within {MAX_REWARD_TOKENS}, without needing
     *         the route (source-side check that preserves cross-VM route opacity).
     * @dev The source escrows each reward token once per leg; a duplicate would double-count. Native
     *      (`address(0)`) folds in as a leg, so two native legs collide. The paired-vs-`minTokens` ORDER is
     *      not checkable here (the source treats the route as opaque bytes for cross-VM compatibility);
     *      it is a keeper-side canonical form, while `minTokens` dedup is enforced at the destination
     *      fulfill via {requireStrictlyAscending}.
     *
     *      On a deployment where `nativeErc20` is configured (non-zero), its ERC20 balance mirrors the
     *      account's native balance 1:1 — a native (`address(0)`) leg and a `nativeErc20` leg are two
     *      interfaces onto the SAME underlying funds, not two independent legs. Funding one would
     *      silently satisfy the other's balance check for free, and payout would then short whichever
     *      leg is processed second against an already-drained pool. Having both legs present at once is
     *      therefore treated the same as a literal duplicate.
     * @param rewardTokens The reward legs to validate.
     * @param nativeErc20 The deployment's configured native/ERC20 alias, or `address(0)` if none.
     */
    function requireUniqueRewardTokens(
        RewardToken[] memory rewardTokens,
        address nativeErc20
    ) internal pure {
        uint256 total = rewardTokens.length;
        if (total > MAX_REWARD_TOKENS) {
            revert TooManyRewardTokens(total, MAX_REWARD_TOKENS);
        }

        bool nativeLegPresent;
        bool nativeErc20LegPresent;
        for (uint256 a = 0; a < total; ++a) {
            address ta = rewardTokens[a].token;
            for (uint256 b = a + 1; b < total; ++b) {
                if (rewardTokens[b].token == ta) {
                    revert RewardTokensNotUnique(ta);
                }
            }
            if (ta == address(0)) {
                nativeLegPresent = true;
            } else if (nativeErc20 != address(0) && ta == nativeErc20) {
                nativeErc20LegPresent = true;
            }
        }

        if (nativeLegPresent && nativeErc20LegPresent) {
            revert RewardTokensNotUnique(nativeErc20);
        }
    }

    /**
     * @notice Bind a proven `(claimant, fulfilled[])` preimage to its intent (hash-only proof model).
     * @dev `keccak256(abi.encode(intentHash, claimant, fulfilled))`. The destination computes and stores
     *      this; the cross-chain message carries only `(intentHash, fulfillmentHash)`. At `settle`, the
     *      caller supplies the preimage and the source re-derives this hash and checks equality before
     *      paying. `intentHash` inside the tuple prevents replay across intents.
     * @param intentHash The intent hash this fulfillment belongs to.
     * @param claimant Cross-VM claimant identifier (EVM claimant in the low 20 bytes).
     * @param fulfilled Per-leg amounts the solver actually provided as input on the destination,
     *        index-aligned with `Route.minTokens` (`fulfilled.length == minTokens.length`).
     * @return The fulfillment hash.
     */
    function fulfillmentHash(
        bytes32 intentHash,
        bytes32 claimant,
        uint256[] memory fulfilled
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(intentHash, claimant, fulfilled));
    }
}
