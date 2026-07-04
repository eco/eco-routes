// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPolicy} from "./interfaces/IPolicy.sol";
import {IInbox} from "./interfaces/IInbox.sol";
import {IAccount} from "./interfaces/IAccount.sol";

import {Route} from "./types/Intent.sol";
import {IntentLib} from "./types/Intent.sol";
import {Refund} from "./libs/Refund.sol";

import {DestinationSettler} from "./ERC7683/DestinationSettler.sol";
import {AccountDeployer} from "./account/AccountDeployer.sol";

/**
 * @title Inbox
 * @notice Main entry point for fulfilling intents on the destination chain
 * @dev Validates intent hash authenticity (with `source` in the preimage, Model C), enforces a
 *      solver-INPUT floor, and executes the route INSIDE the per-intent DESTINATION Account. There is no
 *      separate `Executor`: the solver's route inputs are staged onto the destination Account and
 *      `route.runtime(payload)` runs in that Account's `delegatecall` context (the Account merged in the
 *      Executor's execution sandbox). The destination Account is chain-parameterized by
 *      `intent.destination` (== this chain), so its address is DISTINCT from the source escrow Account
 *      (`intent.source`) for a cross-chain intent (Model C address separation) and identical for a
 *      same-chain intent.
 *
 *      The solver must provide AT LEAST `route.minTokens[j].amount` of each min-in token (it may provide
 *      more, via `providedAmounts`); the provided input is staged onto the Account and becomes
 *      `fulfilled[j]`. The core is UNOPINIONATED about fund destinations: there is no `recipient` and no
 *      protocol-level auto-sweep — DELIVERY IS THE PAYLOAD'S JOB. Any input the runtime does not consume
 *      simply STAYS in the destination Account (leftover stays WITH THE INTENT for `route.keeper` to
 *      retrieve via {executeAsOwner}) — no sweep call at all. The Inbox commits
 *      `(intentHash, claimant, fulfilled[])` into a HASH-ONLY fact and records it into the named prover
 *      (policy), which owns the fulfillment store and cross-chain proof.
 */
abstract contract Inbox is AccountDeployer, DestinationSettler, IInbox {
    using SafeERC20 for IERC20;

    /**
     * @notice Chain ID stored as immutable for gas efficiency
     * @dev This is the DESTINATION chain id: it is the `destination` component of the intent hash for an
     *      intent fulfilled here, and the role chain id of the destination (execution) Account.
     */
    uint64 private immutable CHAIN_ID;

    /**
     * @notice Initializes the Inbox contract
     * @dev Sets up the base contract for handling intent fulfillment on destination chains
     */
    constructor() {
        // Validate that chain ID fits in uint64 and store it
        if (block.chainid > type(uint64).max) {
            revert ChainIdTooLarge(block.chainid);
        }
        CHAIN_ID = uint64(block.chainid);
    }

    /**
     * @notice Fulfills an intent, recording the fulfillment into the named prover
     * @dev Validates intent hash (with `source` in the preimage), stages the solver's provided input onto
     *      the DESTINATION Account, executes `route.runtime(payload)` in it, and records the hash-only
     *      fulfillment fact into `prover`. Naming a prover other than the reward's committed
     *      `reward.prover` is solver self-harm only.
     * @param source Origin chain ID committed in the intent hash
     * @param intentHash The hash of the intent to fulfill
     * @param route The route of the intent
     * @param rewardHash The hash of the reward details
     * @param claimant Cross-VM compatible claimant identifier
     * @param providedAmounts Per-leg input the solver provides, index-aligned with `route.minTokens` (each
     *        `>= route.minTokens[j].amount`)
     * @param prover Prover (policy) to record the fulfillment into
     * @return The runtime's raw return data
     */
    function fulfill(
        uint64 source,
        bytes32 intentHash,
        Route memory route,
        bytes32 rewardHash,
        bytes32 claimant,
        uint256[] memory providedAmounts,
        address prover
    ) external payable returns (bytes memory) {
        (bytes memory result, ) = _fulfill(
            source,
            intentHash,
            route,
            rewardHash,
            claimant,
            providedAmounts,
            prover
        );

        // Refund any remaining balance (excess ETH)
        Refund.excessNative();

        return result;
    }

    /**
     * @notice Fulfills an intent and initiates proving in one transaction
     * @dev Executes intent actions and sends proof message to source chain
     * @param source Origin chain ID committed in the intent hash
     * @param intentHash The hash of the intent to fulfill
     * @param route The route of the intent
     * @param rewardHash The hash of the reward details
     * @param claimant Cross-VM compatible claimant identifier
     * @param providedAmounts Per-leg input the solver provides, index-aligned with `route.minTokens`
     * @param prover Address of prover on the destination chain
     * @param sourceChainDomainID Bridge transport domain ID of the source chain
     * @param data Additional data for message formatting
     * @return The runtime's raw return data
     *
     * @dev WARNING: sourceChainDomainID is NOT necessarily the same as chain ID (nor the same as
     *      `source`): `source` is the origin CHAIN ID committed in the hash, while sourceChainDomainID
     *      is the bridge transport's domain id used to route the proof back.
     */
    function fulfillAndProve(
        uint64 source,
        bytes32 intentHash,
        Route memory route,
        bytes32 rewardHash,
        bytes32 claimant,
        uint256[] memory providedAmounts,
        address prover,
        uint64 sourceChainDomainID,
        bytes memory data
    ) public payable override(DestinationSettler, IInbox) returns (bytes memory) {
        (bytes memory result, ) = _fulfill(
            source,
            intentHash,
            route,
            rewardHash,
            claimant,
            providedAmounts,
            prover
        );

        // Create array with single intent hash
        bytes32[] memory intentHashes = new bytes32[](1);
        intentHashes[0] = intentHash;

        // Call prove with the intent hash array
        // This will also refund any excess ETH
        prove(prover, sourceChainDomainID, intentHashes, data);

        return result;
    }

    /**
     * @notice Initiates proving process for fulfilled intents
     * @dev Sends message to source chain to verify intent execution
     * @param prover Address of prover on the destination chain
     * @param sourceChainDomainID Domain ID of the source chain
     * @param intentHashes Array of intent hashes to prove
     * @param data Additional data for message formatting
     */
    function prove(
        address prover,
        uint64 sourceChainDomainID,
        bytes32[] memory intentHashes,
        bytes memory data
    ) public payable {
        // The prover owns the destination fulfillment store and builds its own proof message from it,
        // so the Inbox only forwards the intent hashes to prove. Any remaining balance (the cross-chain
        // message fee) is forwarded to the prover, which refunds the sender if overpaid.
        IPolicy(prover).prove{value: address(this).balance}(
            msg.sender,
            sourceChainDomainID,
            intentHashes,
            data
        );
    }

    /**
     * @notice Owner-cook on the DESTINATION side: `route.keeper` runs an arbitrary runtime against the
     *         intent's DESTINATION (execution) Account via delegatecall.
     * @dev The destination-side counterpart to {IntentSource-executeAsOwner}. Only `route.keeper` may
     *      call. The Account is derived from THIS chain id (`CHAIN_ID`) as the role chain id, so it
     *      operates the destination execution Account — the one that holds any unconsumed solver input —
     *      and never the source escrow Account (which lives at `keccak(intentHash, source)`, a different
     *      address for a cross-chain intent). Because the Account salt is keyed by `CHAIN_ID`, this is
     *      structurally the `block.chainid == intent.destination` gate: the Inbox only ever reaches the
     *      local (this-chain) execution Account. This is the destination stray-fund / leftover retrieval
     *      path (there is no `recipient` / auto-sweep). The delegatecall bubbles the runtime's raw
     *      return/revert verbatim.
     * @param source Origin chain ID committed in the intent hash
     * @param route The route of the intent (supplies `route.keeper` + `route.portal`)
     * @param rewardHash The hash of the reward details (opaque on the destination)
     * @param runtime The delegatecall target to run against the Account
     * @param payload The opaque program forwarded to `runtime`
     * @return The runtime's raw return data
     */
    function executeAsOwner(
        uint64 source,
        Route memory route,
        bytes32 rewardHash,
        address runtime,
        bytes calldata payload
    ) external payable returns (bytes memory) {
        if (route.portal != address(this)) {
            revert InvalidPortal(route.portal);
        }
        if (msg.sender != route.keeper) {
            revert NotAccountKeeper(msg.sender);
        }

        bytes32 routeHash = keccak256(abi.encode(route));
        bytes32 intentHash = IntentLib.hashIntent(
            source,
            CHAIN_ID,
            routeHash,
            rewardHash
        );

        // Operate on the DESTINATION (execution) Account — keyed by this chain id.
        address account = _getOrDeployAccount(intentHash, CHAIN_ID);
        return IAccount(account).execute{value: msg.value}(runtime, payload);
    }

    /**
     * @notice Internal function to fulfill intents
     * @dev Validates intent, enforces the solver-INPUT floor, stages the provided input onto the
     *      DESTINATION Account, runs `route.runtime(payload)` in the Account's delegatecall context,
     *      and records the hash-only fulfillment fact into the named prover. `fulfilled[j] =
     *      providedAmounts[j]` (the actual input provided; the reward scales on it). The prover's
     *      {IPolicy-recordFulfillment} enforces the one-shot gate. Recording happens AFTER execution; a
     *      re-entrant second fulfillment of the same intent reverts the whole tx (the one-shot gate), so
     *      recording after effects cannot double-deliver.
     * @param source Origin chain ID committed in the intent hash
     * @param intentHash The hash of the intent to fulfill
     * @param route The route of the intent
     * @param rewardHash The hash of the reward
     * @param claimant Cross-VM compatible claimant identifier
     * @param providedAmounts Per-leg input the solver provides, index-aligned with `route.minTokens`
     * @param prover Prover (policy) to record the fulfillment into
     * @return result The runtime's raw return data
     * @return fulfilled Per-leg provided-input amounts, index-aligned with `route.minTokens`
     */
    function _fulfill(
        uint64 source,
        bytes32 intentHash,
        Route memory route,
        bytes32 rewardHash,
        bytes32 claimant,
        uint256[] memory providedAmounts,
        address prover
    ) internal returns (bytes memory result, uint256[] memory fulfilled) {
        // Check if the route has expired
        if (block.timestamp > route.deadline) {
            revert IntentExpired();
        }

        bytes32 routeHash = keccak256(abi.encode(route));
        // Re-derive the hash from `source` + this chain (the destination). A wrong-destination intent
        // will not match `intentHash` and reverts below.
        bytes32 computedIntentHash = IntentLib.hashIntent(
            source,
            CHAIN_ID,
            routeHash,
            rewardHash
        );

        if (route.portal != address(this)) {
            revert InvalidPortal(route.portal);
        }
        if (computedIntentHash != intentHash) {
            revert InvalidHash(intentHash);
        }
        if (claimant == bytes32(0)) {
            revert ZeroClaimant();
        }

        // min-in legs must be canonical (strictly ascending by token -> deduped) so the provided inputs
        // pair unambiguously with the reward legs at settlement.
        IntentLib.requireStrictlyAscending(route.minTokens);

        uint256 inLen = route.minTokens.length;
        if (providedAmounts.length != inLen) {
            revert ProvidedAmountsLengthMismatch(providedAmounts.length, inLen);
        }

        emit IntentFulfilled(intentHash, claimant);

        // The DESTINATION (execution) Account is keyed by this chain id (== intent.destination). For a
        // cross-chain intent this is a DIFFERENT address than the source escrow Account; for a same-chain
        // intent it is the SAME Account that holds the escrow.
        address account = _getOrDeployAccount(intentHash, CHAIN_ID);

        // Enforce the solver INPUT floor per leg and stage the provided input onto the DESTINATION
        // Account. The solver must provide at least `minTokens[j].amount` and MAY provide more;
        // `fulfilled[j]` records the actual amount provided (what the reward scales on). Native folds in
        // as the `address(0)` leg — its provided amount is forwarded into execution as the Account's value.
        fulfilled = providedAmounts;
        uint256 nativeProvided = 0;
        for (uint256 j = 0; j < inLen; ++j) {
            address token = route.minTokens[j].token;
            uint256 provided = providedAmounts[j];
            if (provided < route.minTokens[j].amount) {
                revert InsufficientTokens(
                    token,
                    provided,
                    route.minTokens[j].amount
                );
            }
            if (token == address(0)) {
                nativeProvided = provided;
            } else {
                IERC20(token).safeTransferFrom(msg.sender, account, provided);
            }
        }

        // The solver must actually deliver the native input it committed to. Extra value (e.g. a
        // cross-chain message fee for fulfillAndProve) is allowed and refunded / forwarded by the caller.
        if (msg.value < nativeProvided) {
            revert InsufficientNativeAmount(msg.value, nativeProvided);
        }

        // Execute the keeper-committed runtime in the Account (delegatecall), forwarding the provided
        // native input to the Account to be spent by the runtime. Any input the runtime does not consume
        // stays in the Account — leftover stays WITH THE INTENT (no sweep).
        result = IAccount(account).execute{value: nativeProvided}(
            route.runtime,
            route.payload
        );

        // Commit the (intentHash, claimant, fulfilled[]) preimage as a hash-only fact and record it into
        // the named prover (policy). The prover enforces the one-shot gate.
        bytes32 fulfillmentHash = IntentLib.fulfillmentHash(
            intentHash,
            claimant,
            fulfilled
        );
        IPolicy(prover).recordFulfillment(
            intentHash,
            CHAIN_ID,
            fulfillmentHash
        );
    }
}
