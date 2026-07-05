// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPolicy} from "./interfaces/IPolicy.sol";
import {IInbox} from "./interfaces/IInbox.sol";
import {IAccount} from "./interfaces/IAccount.sol";
import {IPortalProxy, isProtocolVersionExpired} from "./interfaces/IPortalProxy.sol";

import {Route, Reward} from "./types/Intent.sol";
import {IntentLib} from "./types/Intent.sol";
import {Refund} from "./libs/Refund.sol";

import {DestinationSettler} from "./ERC7683/DestinationSettler.sol";
import {AccountDeployer} from "./account/AccountDeployer.sol";

/**
 * @title Inbox
 * @notice Main entry point for fulfilling intents on the destination chain
 * @dev Derives the intent hash on-chain from `(source, destination, route, reward)`, requires
 *      `destination == block.chainid` ({WrongDestinationChain}), enforces a solver-INPUT floor, executes
 *      the route INSIDE the per-intent DESTINATION Account, and enforces a REWARD-CONSERVATION
 *      postcondition (the reward escrow must survive execution). There is no separate `Executor`: the
 *      solver's input is staged onto the destination Account and `route.runtime(payload)` runs in that
 *      Account's `delegatecall` context. The destination Account is chain-parameterized by
 *      `intent.destination` (== this chain), so for a cross-chain intent it is a DIFFERENT address than
 *      the source escrow Account (`intent.source`) — Model C address separation — and identical for a
 *      same-chain intent (the reward-conservation snapshot then protects the shared escrow).
 *
 *      The core is UNOPINIONATED about fund destinations: no `recipient`, no output floor, no auto-sweep.
 *      DELIVERY IS THE PAYLOAD'S JOB. Any input the runtime does not consume simply STAYS in the
 *      destination Account (leftover stays WITH THE INTENT for `route.keeper`). The Inbox commits
 *      `(intentHash, claimant, fulfilled[])` into a HASH-ONLY fact and records it into the named prover.
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
     * @dev Derives the intent hash from `(source, destination, route, reward)`, requires
     *      `destination == block.chainid`, stages the solver's provided input onto the destination Account,
     *      executes `route.runtime(payload)` in it, enforces reward-conservation, and records the hash-only
     *      fulfillment fact into `prover`. Naming a prover other than the reward's committed `reward.prover`
     *      is solver self-harm only.
     * @param source Origin chain ID committed in the intent hash
     * @param destination Destination chain ID committed in the intent hash (must equal block.chainid)
     * @param route The route of the intent
     * @param reward The reward details of the intent (legs authenticated by the derived intent hash)
     * @param claimant Cross-VM compatible claimant identifier
     * @param providedAmounts Per-leg input the solver provides, index-aligned with `route.minTokens` (each
     *        `>= route.minTokens[j].amount`)
     * @param prover Prover (policy) to record the fulfillment into
     * @return The runtime's raw return data
     */
    function fulfill(
        uint32 protocolVersion,
        uint64 source,
        uint64 destination,
        Route memory route,
        Reward memory reward,
        bytes32 claimant,
        uint256[] memory providedAmounts,
        address prover
    ) external payable returns (bytes memory) {
        (bytes memory result, , ) = _fulfill(
            protocolVersion,
            source,
            destination,
            route,
            reward,
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
     * @param destination Destination chain ID committed in the intent hash (must equal block.chainid)
     * @param route The route of the intent
     * @param reward The reward details of the intent (legs authenticated by the derived intent hash)
     * @param claimant Cross-VM compatible claimant identifier
     * @param providedAmounts Per-leg input the solver provides, index-aligned with `route.minTokens`
     * @param prover Address of prover on the destination chain
     * @param sourceChainDomainID Bridge transport domain ID of the source chain
     * @param data Additional data for message formatting
     * @return The runtime's raw return data
     */
    function fulfillAndProve(
        uint32 protocolVersion,
        uint64 source,
        uint64 destination,
        Route memory route,
        Reward memory reward,
        bytes32 claimant,
        uint256[] memory providedAmounts,
        address prover,
        uint64 sourceChainDomainID,
        bytes memory data
    ) public payable override(DestinationSettler, IInbox) returns (bytes memory) {
        (bytes memory result, , bytes32 intentHash) = _fulfill(
            protocolVersion,
            source,
            destination,
            route,
            reward,
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
     * @dev CROSS-CHAIN ONLY. Reverts {SourceChainOwnerOnly} when `source == block.chainid` — on this chain
     *      the `CHAIN_ID`-keyed Account is (or collapses with) the SOURCE escrow Account, which must be
     *      governed by the reward-aware {IntentSource-executeAsOwner} (reward.keeper + escrow/proof lock),
     *      NOT this reward-blind arbitrary-runtime path. When `source != block.chainid` this chain is
     *      purely the destination, so the `CHAIN_ID`-keyed Account provably holds only unconsumed solver
     *      input (never escrow) and `route.keeper` may retrieve it freely. This is the destination
     *      leftover-retrieval / stray-fund rescue (the core is unopinionated — no `recipient`/auto-sweep).
     * @param source Origin chain ID committed in the intent hash (must NOT equal block.chainid)
     * @param route The route of the intent (supplies `route.keeper` + `route.portal`)
     * @param rewardHash The hash of the reward details (opaque on the destination)
     * @param runtime The delegatecall target to run against the Account
     * @param payload The opaque program forwarded to `runtime`
     * @return The runtime's raw return data
     */
    function executeAsOwner(
        uint32 protocolVersion,
        uint64 source,
        Route memory route,
        bytes32 rewardHash,
        address runtime,
        bytes calldata payload
    ) external payable returns (bytes memory) {
        // CROSS-CHAIN ONLY, for BOTH authorities: on this chain the CHAIN_ID-keyed Account is / collapses
        // with the SOURCE escrow Account, which only the reward-aware source-side executeAsOwner may cook.
        // This restriction is caller-independent — it applies equally to the keeper and the deployer sweep.
        if (source == CHAIN_ID) {
            revert SourceChainOwnerOnly(source);
        }
        if (route.portal != address(this)) {
            revert InvalidPortal(route.portal);
        }
        // Two independent authorities may cook the destination (leftover) Account: (1) `route.keeper`, any
        // time; or (2) the PROTOCOL OWNER, but ONLY once this intent's protocol version is EXPIRED (the
        // deployer sweep for stuck destination leftovers under a retired implementation). The cross-chain
        // restriction above already guarantees this Account provably holds only unconsumed solver input,
        // never escrow, so no reward-conservation lock is needed on this path for either authority.
        bool isKeeper = msg.sender == route.keeper;
        bool isDeployerSweep = msg.sender ==
            IPortalProxy(address(this)).owner() &&
            isProtocolVersionExpired(address(this), protocolVersion);
        if (!isKeeper && !isDeployerSweep) {
            revert NotAccountKeeper(msg.sender);
        }

        bytes32 routeHash = keccak256(abi.encode(route));
        bytes32 intentHash = IntentLib.hashIntent(
            protocolVersion,
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
     * @dev Derives the intent hash from `(source, destination, route, reward)` and requires
     *      `destination == block.chainid` ({WrongDestinationChain}). Snapshots the Account's reward-escrow
     *      balances, enforces the solver-INPUT floor and stages the provided input onto the Account, runs
     *      `route.runtime(payload)` in the Account's delegatecall context, enforces the REWARD-CONSERVATION
     *      postcondition (the reward escrow must survive execution), and records the hash-only fulfillment
     *      fact into the named prover. `fulfilled[j] = providedAmounts[j]`. The prover's
     *      {IPolicy-recordFulfillment} enforces the one-shot gate; recording happens AFTER execution, and a
     *      re-entrant second fulfillment reverts the whole tx, so recording after effects cannot
     *      double-deliver.
     * @param source Origin chain ID committed in the intent hash
     * @param destination Destination chain ID committed in the intent hash (must equal block.chainid)
     * @param route The route of the intent
     * @param reward The reward of the intent (legs authenticated by the derived intent hash)
     * @param claimant Cross-VM compatible claimant identifier
     * @param providedAmounts Per-leg input the solver provides, index-aligned with `route.minTokens`
     * @param prover Prover (policy) to record the fulfillment into
     * @return result The runtime's raw return data
     * @return fulfilled Per-leg provided-input amounts, index-aligned with `route.minTokens`
     * @return intentHash The derived intent hash
     */
    function _fulfill(
        uint32 protocolVersion,
        uint64 source,
        uint64 destination,
        Route memory route,
        Reward memory reward,
        bytes32 claimant,
        uint256[] memory providedAmounts,
        address prover
    )
        internal
        returns (
            bytes memory result,
            uint256[] memory fulfilled,
            bytes32 intentHash
        )
    {
        // Destination gate (belt-and-braces on the Model C address separation): a fulfill can only be
        // recorded on the chain the intent commits to as its destination.
        if (destination != CHAIN_ID) {
            revert WrongDestinationChain(CHAIN_ID, destination);
        }
        // Check if the route has expired
        if (block.timestamp > route.deadline) {
            revert IntentExpired();
        }
        if (route.portal != address(this)) {
            revert InvalidPortal(route.portal);
        }
        if (claimant == bytes32(0)) {
            revert ZeroClaimant();
        }

        // Derive the intent hash from the supplied components. The full `reward` is supplied (not just its
        // hash) so `reward.tokens` are authenticated by this derivation and can be snapshotted below.
        bytes32 routeHash = keccak256(abi.encode(route));
        bytes32 rewardHash = keccak256(abi.encode(reward));
        intentHash = IntentLib.hashIntent(
            protocolVersion,
            source,
            destination,
            routeHash,
            rewardHash
        );

        // min-in legs must be canonical (strictly ascending by token -> deduped) so the provided inputs
        // pair unambiguously with the reward legs at settlement.
        IntentLib.requireStrictlyAscending(route.minTokens);

        uint256 inLen = route.minTokens.length;
        if (providedAmounts.length != inLen) {
            revert ProvidedAmountsLengthMismatch(providedAmounts.length, inLen);
        }

        // H2 anti-poison: an intent with NO input legs AND NO reward asks a solver to provide nothing for
        // no pay, so there is no honest fulfill — and recording one would permanently occupy the prover's
        // fulfillment store, bricking a REUSABLE deposit address for every later deposit. The only
        // legitimate way to run such an Account's committed `runtime(payload)` is the owner-gated
        // {Inbox-executeAsOwner} (cross-chain) / {IIntentSource-executeAsOwner} (source). Reject it here.
        if (route.minTokens.length == 0 && reward.tokens.length == 0) {
            revert NothingToFulfill();
        }

        emit IntentFulfilled(intentHash, claimant);

        // The DESTINATION (execution) Account is keyed by this chain id (== intent.destination). For a
        // cross-chain intent this is a DIFFERENT address than the source escrow Account; for a same-chain
        // intent it is the SAME Account that holds the reward escrow.
        address account = _getOrDeployAccount(intentHash, destination);

        // --- REWARD-CONSERVATION snapshot (before any solver input is staged) ---------------------------
        // Snapshot the Account's balance of every reward-leg token (and native) — the reserved reward
        // escrow `E`. For a same-chain intent the escrow lives in THIS Account; for a cross-chain intent the
        // execution Account holds no source escrow so every snapshot is ~0 and the postcondition below is a
        // cheap no-op. Snapshotting BEFORE staging the route inputs means a reward token that ALSO happens
        // to be a route input is measured as escrow-only, so the runtime legitimately consuming the staged
        // input does not trip conservation.
        uint256 rewardLen = reward.tokens.length;
        uint256[] memory escrowBefore = new uint256[](rewardLen);
        for (uint256 i = 0; i < rewardLen; ++i) {
            escrowBefore[i] = _balanceOf(reward.tokens[i].token, account);
        }

        // Enforce the solver INPUT floor per leg and stage the provided input onto the DESTINATION Account.
        // The solver must provide at least `minTokens[j].amount` and MAY provide more; `fulfilled[j]`
        // records the actual amount provided. Native folds in as the `address(0)` leg — its provided amount
        // is forwarded into execution as the Account's value.
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
        // native input. Any input the runtime does not consume stays in the Account (no sweep).
        result = IAccount(account).execute{value: nativeProvided}(
            route.runtime,
            route.payload
        );

        // --- REWARD-CONSERVATION postcondition ----------------------------------------------------------
        // The runtime may consume only balance ABOVE the reserved reward escrow `E`, never `E` itself.
        // For a same-chain intent this protects the escrow that shares this Account against a malicious
        // keeper-authored runtime; for a cross-chain intent every snapshot was ~0 so this is vacuous. A
        // violation reverts the WHOLE fulfill — worst case a griefing DoS for the solver (who simulates
        // first), never reward theft.
        for (uint256 i = 0; i < rewardLen; ++i) {
            uint256 live = _balanceOf(reward.tokens[i].token, account);
            if (live < escrowBefore[i]) {
                revert RewardEscrowTouched(
                    reward.tokens[i].token,
                    live,
                    escrowBefore[i]
                );
            }
        }

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
     * @notice Reads the balance of `token` held by `account`; `address(0)` denotes native.
     * @param token The token address, or `address(0)` for native
     * @param account The account whose balance to read
     * @return The balance
     */
    function _balanceOf(
        address token,
        address account
    ) internal view returns (uint256) {
        if (token == address(0)) {
            return account.balance;
        }
        return IERC20(token).balanceOf(account);
    }
}
