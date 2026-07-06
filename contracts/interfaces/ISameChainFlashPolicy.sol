// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPolicy} from "./IPolicy.sol";
import {Route, Reward} from "../types/Intent.sol";

/**
 * @title ISameChainFlashPolicy
 * @notice Interface for the ONE-SHOT zero-capital same-chain flash policy.
 * @dev Restores v2's {LocalProver-flashFulfill} withdraw-before-fulfill flow with v3 primitives: the
 *      policy self-vouches a synthetic session fact through its own {IPolicy-provenIntents} so the
 *      generic {IIntentSource-settle} releases the escrow advance to the policy BEFORE the fulfill, all
 *      inside one atomic, reentrancy-guarded session. Any misalignment reverts the whole transaction.
 */
interface ISameChainFlashPolicy is IPolicy {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice The claimant is zero, the policy itself, or not a valid EVM address.
    error InvalidClaimant();

    /// @notice The intent's `reward.prover` does not name this policy.
    error InvalidProver();

    /// @notice A native transfer that must succeed (the advance hand-off to the solver) failed.
    error NativeTransferFailed();

    /**
     * @notice A fulfillment record arrived during a flash session that is not the session's expected
     *         real-claimant fact (wrong intent, wrong claimant, or wrong amounts).
     * @param intentHash Hash the record was attempted for.
     */
    error UnexpectedSessionFulfillment(bytes32 intentHash);

    /**
     * @notice After the session's fulfill, the recorded fact does not equal the expected real-claimant
     *         fact (belt-and-braces re-check of the {UnexpectedSessionFulfillment} gate).
     * @param intentHash Hash of the misaligned intent.
     */
    error MisalignedFulfillment(bytes32 intentHash);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when an intent is flash-fulfilled (advance -> fulfill -> margin, one tx).
     * @param intentHash Hash of the fulfilled intent
     * @param claimant Claimant that received the margin (cross-VM identifier)
     * @param nativeMargin Native margin forwarded to the claimant (ERC20 margins are transferred but not
     *        tracked here — v2 event parity)
     */
    event FlashFulfilled(
        bytes32 indexed intentHash,
        bytes32 indexed claimant,
        uint256 nativeMargin
    );

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Atomically settles the reward escrow to this policy (the flash advance), funds and executes
     *         the route with it, records the real-claimant fulfillment, and forwards the remaining margin
     *         to `claimant` — the solver fronts ZERO capital.
     * @dev `fulfilled[]` is pinned to the exact `route.minTokens` floors (one-shot intents commit exact
     *      amounts). With non-empty `solverData` the advance is handed to the caller via
     *      {IFlashSolver-onFlashAdvance} (swap mode); with empty `solverData` the advance funds the route
     *      inputs directly (same-token / deposit mode). Permissionless and front-runnable — standard MEV
     *      behavior in intent systems.
     * @param protocolVersion Creator-declared Portal implementation version committed in the intent hash
     * @param route Route information for the intent
     * @param reward Reward details for the intent (`reward.prover` must be this policy)
     * @param claimant Cross-VM identifier that receives the margin and is committed in the fulfillment
     * @param solverData Empty for direct funding; otherwise opaque data forwarded to the caller's
     *        {IFlashSolver-onFlashAdvance} callback
     * @return results The runtime's raw return data from the fulfill execution
     */
    function flashFulfill(
        uint32 protocolVersion,
        Route calldata route,
        Reward calldata reward,
        bytes32 claimant,
        bytes calldata solverData
    ) external payable returns (bytes memory results);
}
