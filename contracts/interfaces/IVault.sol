/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Reward} from "../types/Intent.sol";
import {IPermit} from "./IPermit.sol";

/**
 * @title IVault
 * @notice Interface for Vault contract that manages reward escrow functionality
 * @dev Handles funding, withdrawal, and refund operations for cross-chain rewards
 */
interface IVault {
    /// @notice Thrown when caller is not the portal contract
    error NotPortalCaller(address caller);

    /// @notice Thrown when vault status is invalid for funding operation
    error InvalidStatusForFunding(Status status);

    /// @notice Thrown when vault status is invalid for withdrawal operation
    error InvalidStatusForWithdrawal(Status status);

    /// @notice Thrown when attempting to recover an invalid token (zero address or reward token)
    error InvalidRecoverToken(address token);

    /// @notice Thrown when attempting to recover a token with zero balance
    error ZeroRecoverTokenBalance(address token);

    /// @notice Thrown when vault status is invalid for refund operation or deadline not reached
    error InvalidStatusForRefund(
        Status status,
        uint256 currentTime,
        uint256 deadline
    );

    /// @notice Thrown when native token transfer fails
    error NativeTransferFailed(address to, uint256 amount);

    /// @notice Thrown when claimant address is address zero
    error ZeroClaimant();

    /// @notice Vault lifecycle status
    enum Status {
        Initial, /// @dev Vault created, may be partially funded but not fully funded
        Funded, /// @dev Vault has been fully funded with all required rewards
        Withdrawn, /// @dev Rewards have been withdrawn by claimant
        Refunded /// @dev Rewards have been refunded to creator
    }

    /**
     * @notice Funds the vault with reward tokens and native currency
     * @param status Current vault status
     * @param reward The reward structure containing tokens and amounts
     * @param funder Address providing the funding
     * @param permit Optional permit contract for token transfers
     * @return fullyFunded True if vault was successfully fully funded
     */
    function fundFor(
        Status status,
        Reward calldata reward,
        address funder,
        IPermit permit
    ) external payable returns (bool fullyFunded);

    /**
     * @notice Withdraws rewards from the vault to the claimant
     * @param status Current vault status
     * @param reward The reward structure to withdraw
     * @param claimant Address that will receive the rewards
     */
    function withdraw(
        Status status,
        Reward calldata reward,
        address claimant
    ) external;

    /**
     * @notice Refunds rewards back to the original creator
     * @param status Current vault status
     * @param reward The reward structure to refund
     */
    function refund(Status status, Reward calldata reward) external;

    /**
     * @notice Recovers tokens that are not part of the reward to the creator
     * @param reward The reward structure containing creator address
     * @param token Address of the token to recover (must not be a reward token)
     */
    function recover(Reward calldata reward, address token) external;
}