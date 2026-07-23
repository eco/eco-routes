// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IProver} from "./interfaces/IProver.sol";
import {IInbox} from "./interfaces/IInbox.sol";
import {IExecutor} from "./interfaces/IExecutor.sol";

import {Route, Call, TokenAmount} from "./types/Intent.sol";
import {Semver} from "./libs/Semver.sol";
import {Refund} from "./libs/Refund.sol";

import {DestinationSettler} from "./ERC7683/DestinationSettler.sol";
import {Executor} from "./Executor.sol";

/**
 * @title Inbox
 * @notice Main entry point for fulfilling intents on the destination chain
 * @dev Validates intent hash authenticity and executes calldata. Destination fulfillment storage
 *      lives in the prover, not here: {fulfill} names the prover (policy) to record into, and the
 *      prover both stores the claimant and builds/dispatches the cross-chain proof from its own
 *      store. The Inbox is transport- and policy-agnostic — it only re-derives the intent hash,
 *      executes the route, and hands the fulfillment fact to the named prover.
 */
abstract contract Inbox is DestinationSettler, IInbox {
    using SafeERC20 for IERC20;

    IExecutor public immutable executor;

    /**
     * @notice Chain ID stored as immutable for gas efficiency
     * @dev Used to prepend to proof messages for cross-chain identification
     */
    uint64 private immutable CHAIN_ID;

    /**
     * @notice Initializes the Inbox contract
     * @dev Sets up the base contract for handling intent fulfillment on destination chains
     */
    constructor() {
        executor = new Executor();

        // Validate that chain ID fits in uint64 and store it
        if (block.chainid > type(uint64).max) {
            revert ChainIdTooLarge(block.chainid);
        }
        CHAIN_ID = uint64(block.chainid);
    }

    /**
     * @notice Fulfills an intent, recording the fulfillment into the named prover
     * @dev Validates intent hash, executes calls, and records the fulfillment into `prover`. The
     *      solver names the prover (policy) that will settle the reward. Naming a prover other than
     *      the reward's committed `reward.prover` is solver self-harm only — settlement reads
     *      `reward.prover`, so a mismatched fulfillment records against a prover that never settles.
     * @param intentHash The hash of the intent to fulfill
     * @param route The route of the intent
     * @param rewardHash The hash of the reward details
     * @param claimant Cross-VM compatible claimant identifier
     * @param prover Prover (policy) to record the fulfillment into
     * @return Array of execution results from each call
     */
    function fulfill(
        bytes32 intentHash,
        Route memory route,
        bytes32 rewardHash,
        bytes32 claimant,
        address prover
    ) external payable returns (bytes[] memory) {
        bytes[] memory result = _fulfill(
            intentHash,
            route,
            rewardHash,
            claimant,
            prover
        );

        // Refund any remaining balance (excess ETH)
        Refund.excessNative();

        return result;
    }

    /**
     * @notice Fulfills an intent and initiates proving in one transaction
     * @dev Executes intent actions and sends proof message to source chain
     * @param intentHash The hash of the intent to fulfill
     * @param route The route of the intent
     * @param rewardHash The hash of the reward details
     * @param claimant Cross-VM compatible claimant identifier
     * @param prover Address of prover on the destination chain
     * @param sourceChainDomainID Domain ID of the source chain where the intent was created
     * @param data Additional data for message formatting
     * @return Array of execution results
     *
     * @dev WARNING: sourceChainDomainID is NOT necessarily the same as chain ID.
     *      Each bridge provider uses their own domain ID mapping system:
     *      - Hyperlane: Uses custom domain IDs that may differ from chain IDs
     *      - LayerZero: Uses endpoint IDs that map to chains differently
     *      - Metalayer: Uses domain IDs specific to their routing system
     *      - Polymer: Uses chain IDs
     *      You MUST consult the specific bridge provider's documentation to determine
     *      the correct domain ID for the source chain.
     */
    function fulfillAndProve(
        bytes32 intentHash,
        Route memory route,
        bytes32 rewardHash,
        bytes32 claimant,
        address prover,
        uint64 sourceChainDomainID,
        bytes memory data
    )
        public
        payable
        override(DestinationSettler, IInbox)
        returns (bytes[] memory)
    {
        bytes[] memory result = _fulfill(
            intentHash,
            route,
            rewardHash,
            claimant,
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
     *
     * @dev WARNING: sourceChainDomainID is NOT necessarily the same as chain ID.
     *      Each bridge provider uses their own domain ID mapping system:
     *      - Hyperlane: Uses custom domain IDs that may differ from chain IDs
     *      - LayerZero: Uses endpoint IDs that map to chains differently
     *      - Metalayer: Uses domain IDs specific to their routing system
     *      - Polymer: Uses chainIDs
     *      You MUST consult the specific bridge provider's documentation to determine
     *      the correct domain ID for the source chain.
     */
    function prove(
        address prover,
        uint64 sourceChainDomainID,
        bytes32[] memory intentHashes,
        bytes memory data
    ) public payable {
        // The prover owns the destination fulfillment store and builds its own proof message from
        // it, so the Inbox only forwards the intent hashes to prove. Any remaining balance (the
        // cross-chain message fee) is forwarded to the prover, which refunds the sender if overpaid.
        IProver(prover).prove{value: address(this).balance}(
            msg.sender,
            sourceChainDomainID,
            intentHashes,
            data
        );
    }

    /**
     * @notice Internal function to fulfill intents
     * @dev Validates intent, records the fulfillment into the named prover, and executes calls.
     *      The prover's {IProver-recordFulfillment} enforces the one-shot gate (a second fulfillment
     *      of the same intent under the same prover reverts {IProver-IntentAlreadyFulfilled}).
     * @param intentHash The hash of the intent to fulfill
     * @param route The route of the intent
     * @param rewardHash The hash of the reward
     * @param claimant Cross-VM compatible claimant identifier
     * @param prover Prover (policy) to record the fulfillment into
     * @return Array of execution results
     */
    function _fulfill(
        bytes32 intentHash,
        Route memory route,
        bytes32 rewardHash,
        bytes32 claimant,
        address prover
    ) internal returns (bytes[] memory) {
        // Check if the route has expired
        if (block.timestamp > route.deadline) {
            revert IntentExpired();
        }

        bytes32 routeHash = keccak256(abi.encode(route));
        bytes32 computedIntentHash = keccak256(
            abi.encodePacked(CHAIN_ID, routeHash, rewardHash)
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

        // Record the fulfillment into the named prover (policy). The prover is the owner of
        // destination fulfillment storage and enforces the one-shot gate.
        IProver(prover).recordFulfillment(intentHash, CHAIN_ID, claimant);

        emit IntentFulfilled(intentHash, claimant);

        // Transfer ERC20 tokens to the executor
        uint256 tokensLength = route.tokens.length;

        // Validate that msg.value is at least the route's nativeAmount
        // Allow extra value for cross-chain message fees when using fulfillAndProve
        if (msg.value < route.nativeAmount) {
            revert InsufficientNativeAmount(msg.value, route.nativeAmount);
        }

        for (uint256 i = 0; i < tokensLength; ++i) {
            TokenAmount memory token = route.tokens[i];

            IERC20(token.token).safeTransferFrom(
                msg.sender,
                address(executor),
                token.amount
            );
        }

        return executor.execute{value: route.nativeAmount}(route.calls);
    }
}
