/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IIntentVault
 * @notice Interface defining errors for the IntentVault contract
 */
interface IIntentVault {
    /**
     * @notice Thrown when attempting to withdraw rewards before the intent has expired
     */
    error IntentNotExpired();

    /**
     * @notice Thrown when trying to use a reward token as a refund token
     */
    error RefundTokenCannotBeRewardToken();

    /**
     * @notice Thrown when the vault has insufficient token balance for reward distribution
     */
    error InsufficientTokenBalance();

    /**
     * @notice Thrown when the vault has insufficient native token balance
     */
    error InsufficientNativeBalance();

    /**
     * @notice Thrown when the native token transfer to the claimant fails
     */
    error NativeRewardTransferFailed();

    event RewardTransferFailed(
        address indexed token,
        address indexed to,
        uint256 amount
    );
}
