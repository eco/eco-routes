// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPolicy} from "./interfaces/IPolicy.sol";
import {IInbox} from "./interfaces/IInbox.sol";
import {IExecutor} from "./interfaces/IExecutor.sol";

import {Route} from "./types/Intent.sol";
import {IntentLib} from "./types/Intent.sol";
import {Semver} from "./libs/Semver.sol";
import {Refund} from "./libs/Refund.sol";

import {DestinationSettler} from "./ERC7683/DestinationSettler.sol";
import {Executor} from "./Executor.sol";

/**
 * @title Inbox
 * @notice Main entry point for fulfilling intents on the destination chain
 * @dev Validates intent hash authenticity and enforces a solver-INPUT floor: the solver must provide at
 *      least `route.minTokens[j].amount` of each min-in token (it may provide more, via `providedAmounts`).
 *      The provided input is pulled into the executor and the route `calls` execute. The core is
 *      UNOPINIONATED about fund destinations: there is no `recipient` and no protocol-level auto-sweep to
 *      one — DELIVERY IS THE CALLS' JOB (any beneficiary lives inside a call's calldata). Any input the
 *      calls did not consume is moved to the intent's Vault (so leftover stays WITH THE INTENT for the
 *      creator to retrieve later) rather than being stranded in the shared executor. `fulfilled[j]`
 *      records the amount actually provided; the Inbox commits `(intentHash, claimant, fulfilled[])` into
 *      a HASH-ONLY fact (`fulfillmentHash = keccak256(abi.encode(intentHash, claimant, fulfilled))`) and
 *      records it into the named prover (policy), which owns the fulfillment store and cross-chain proof.
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
     * @dev Validates intent hash, pulls the solver's provided input, executes calls, moves any unconsumed
     *      input to the intent's Vault, and records the hash-only fulfillment fact into `prover`. Naming a
     *      prover other than the reward's committed `reward.prover` is solver self-harm only.
     * @param intentHash The hash of the intent to fulfill
     * @param route The route of the intent
     * @param rewardHash The hash of the reward details
     * @param claimant Cross-VM compatible claimant identifier
     * @param providedAmounts Per-leg input the solver provides, index-aligned with `route.minTokens` (each
     *        `>= route.minTokens[j].amount`)
     * @param prover Prover (policy) to record the fulfillment into
     * @return Array of execution results from each call
     */
    function fulfill(
        bytes32 intentHash,
        Route memory route,
        bytes32 rewardHash,
        bytes32 claimant,
        uint256[] memory providedAmounts,
        address prover
    ) external payable returns (bytes[] memory) {
        (bytes[] memory result, ) = _fulfill(
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
     * @param intentHash The hash of the intent to fulfill
     * @param route The route of the intent
     * @param rewardHash The hash of the reward details
     * @param claimant Cross-VM compatible claimant identifier
     * @param providedAmounts Per-leg input the solver provides, index-aligned with `route.minTokens` (each
     *        `>= route.minTokens[j].amount`)
     * @param prover Address of prover on the destination chain
     * @param sourceChainDomainID Domain ID of the source chain where the intent was created
     * @param data Additional data for message formatting
     * @return Array of execution results
     */
    function fulfillAndProve(
        bytes32 intentHash,
        Route memory route,
        bytes32 rewardHash,
        bytes32 claimant,
        uint256[] memory providedAmounts,
        address prover,
        uint64 sourceChainDomainID,
        bytes memory data
    )
        public
        payable
        override(DestinationSettler, IInbox)
        returns (bytes[] memory)
    {
        (bytes[] memory result, ) = _fulfill(
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
     * @notice Internal function to fulfill intents
     * @dev Validates intent, enforces the solver-INPUT floor, pulls the provided input into the executor,
     *      executes calls, moves any unconsumed input to the intent's Vault, and records the hash-only
     *      fulfillment fact into the named prover. `fulfilled[j] = providedAmounts[j]` (the actual input
     *      provided; the reward scales on it). The prover's {IPolicy-recordFulfillment} enforces the
     *      one-shot gate. Recording happens AFTER execution; a re-entrant second fulfillment of the same
     *      intent reverts the whole tx (the one-shot gate), so recording after effects cannot
     *      double-deliver.
     * @param intentHash The hash of the intent to fulfill
     * @param route The route of the intent
     * @param rewardHash The hash of the reward
     * @param claimant Cross-VM compatible claimant identifier
     * @param providedAmounts Per-leg input the solver provides, index-aligned with `route.minTokens`
     * @param prover Prover (policy) to record the fulfillment into
     * @return result Array of execution results
     * @return fulfilled Per-leg provided-input amounts, index-aligned with `route.minTokens`
     */
    function _fulfill(
        bytes32 intentHash,
        Route memory route,
        bytes32 rewardHash,
        bytes32 claimant,
        uint256[] memory providedAmounts,
        address prover
    ) internal returns (bytes[] memory result, uint256[] memory fulfilled) {
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

        // min-in legs must be canonical (strictly ascending by token -> deduped) so the provided inputs
        // pair unambiguously with the reward legs at settlement.
        IntentLib.requireStrictlyAscending(route.minTokens);

        uint256 inLen = route.minTokens.length;
        if (providedAmounts.length != inLen) {
            revert ProvidedAmountsLengthMismatch(providedAmounts.length, inLen);
        }

        emit IntentFulfilled(intentHash, claimant);

        // Enforce the solver INPUT floor per leg and pull the provided input into the executor. The
        // solver must provide at least `minTokens[j].amount` and MAY provide more; `fulfilled[j]` records the
        // actual amount provided (what the reward scales on). Native folds in as the `address(0)` leg —
        // its provided amount is forwarded into execution as the executor's value.
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
                IERC20(token).safeTransferFrom(
                    msg.sender,
                    address(executor),
                    provided
                );
            }
        }

        // The solver must actually deliver the native input it committed to. Extra value (e.g. a
        // cross-chain message fee for fulfillAndProve) is allowed and refunded / forwarded by the caller.
        if (msg.value < nativeProvided) {
            revert InsufficientNativeAmount(msg.value, nativeProvided);
        }

        // Execute the route, forwarding the committed native input.
        result = executor.execute{value: nativeProvided}(route.calls);

        // Delivery is the calls' job (any beneficiary is inside the calls' calldata). Move any input the
        // calls did not consume to the intent's Vault so leftover stays WITH THE INTENT — the creator
        // retrieves it later — rather than being stranded in the shared executor. The Vault address is
        // deterministic (CREATE2 keyed on the intent hash) and identical across chains, so the same
        // per-intent vault the creator controls on the source chain is addressable here. The executor
        // holds ONLY solver input (never reward escrow), so this can never misdirect escrow.
        executor.sweepTo(route.minTokens, _predictVault(intentHash));

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

    /**
     * @notice Deterministic address of the intent's per-intent Vault for a given intent hash.
     * @dev Implemented by the composition root (the Portal, which also inherits IntentSource) so the
     *      destination-side Inbox can address the same CREATE2 vault the source-side escrow uses. Any
     *      unconsumed solver input is moved here after execution so leftover stays with the intent.
     * @param intentHash The intent hash keying the vault's CREATE2 salt.
     * @return The predicted vault address.
     */
    function _predictVault(
        bytes32 intentHash
    ) internal view virtual returns (address);
}
