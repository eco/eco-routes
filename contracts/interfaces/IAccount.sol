/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Reward} from "../types/Intent.sol";
import {IPermit} from "./IPermit.sol";

/**
 * @title IAccount
 * @notice Interface for Account contract that manages reward escrow functionality
 * @dev Handles funding, withdrawal, and refund operations for cross-chain rewards
 */
interface IAccount {
    /// @notice Thrown when caller is not the portal contract
    error NotPortalCaller(address caller);

    /// @notice Thrown when attempting to recover a token with zero balance
    error ZeroRecoverTokenBalance(address token);

    /// @notice Thrown when native token transfer fails
    error NativeTransferFailed(address to, uint256 amount);

    /// @notice Thrown when the gated fallback forwarder is hit outside an in-flight {execute}
    /// @param caller The address whose callback was rejected
    error FallbackNotInExecute(address caller);

    /**
     * @notice Runs a runtime against this Account's own funds via `delegatecall`
     * @dev Delegatecalls `runtime` with `payload` (forwarded verbatim), bubbling the raw return/revert.
     *      While in progress the gated fallback forwards in-flight callbacks to `runtime`.
     * @param runtime The delegatecall target (committed in the route hash)
     * @param payload The opaque program forwarded to `runtime`
     * @return The runtime's raw return data
     */
    function execute(
        address runtime,
        bytes calldata payload
    ) external payable returns (bytes memory);

    /**
     * @notice Runs a keeper-committed delegate hook against this Account via `delegatecall`
     * @dev Decodes `hooks` as the default `abi.encode(Hook[2])` and runs slot `index` (0 = reward hook,
     *      1 = refund hook) in the SAME gated-execute sandbox as {execute}: it sets the in-execute slot,
     *      `delegatecall`s `Hook.target` with `Hook.data`, and clears the slot, so an in-flight callback is
     *      forwarded to the hook via the gated fallback. An empty `hooks` (length 0) or a slot with
     *      `target == address(0)` is a no-op. On hook revert the raw revert data is bubbled verbatim (the
     *      Portal wraps the call in try/catch so a reverting hook cannot break settle/refund).
     * @param hooks The opaque `Reward.hooks` bytes (default: `abi.encode(Hook[2])`)
     * @param index Which hook slot to run (0 = reward, 1 = refund)
     */
    function runHook(bytes calldata hooks, uint256 index) external;

    /**
     * @notice Funds the account with reward legs
     * @param reward The reward structure containing the legs
     * @param targets Per-leg escrow targets, index-aligned with `reward.tokens`
     * @param funder Address providing the funding
     * @param permit Optional permit contract for token transfers
     * @return fullyFunded True if every leg reached its target
     */
    function fundFor(
        Reward calldata reward,
        uint256[] calldata targets,
        address funder,
        IPermit permit
    ) external payable returns (bool fullyFunded);

    /**
     * @notice Withdraws the owed reward to the claimant and sweeps the residual to the keeper
     * @dev Consults `reward.prover.previewRelease(reward, fulfilled)` for the per-leg amounts
     * @param reward The reward structure to withdraw
     * @param claimant Address that will receive the owed reward
     * @param fulfilled Core-verified per-leg delivered amounts (paired prefix)
     */
    function withdraw(
        Reward calldata reward,
        address claimant,
        uint256[] calldata fulfilled
    ) external;

    /**
     * @notice Refunds rewards to a specified address
     * @param reward The reward structure to refund
     * @param refundee Address to receive the refunded rewards
     */
    function refund(Reward calldata reward, address refundee) external;

    /**
     * @notice Recovers tokens that are not part of the reward to the keeper
     * @param refundee Address to receive the recovered tokens
     * @param token Address of the token to recover (must not be a reward token)
     */
    function recover(address refundee, address token) external;
}
