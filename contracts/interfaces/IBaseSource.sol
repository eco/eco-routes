/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IVaultStorage} from "./IVaultStorage.sol";

/**
 * @title IBaseSource
 * @notice Base interface for intent sources containing common error definitions
 * @dev This interface defines the shared errors and events used across intent source implementations
 */
interface IBaseSource is IVaultStorage {
    /**
     * @notice Indicates an attempt to fund an intent on an incorrect chain
     * @param intentHash The hash of the intent that was incorrectly targeted
     */
    error WrongSourceChain(bytes32 intentHash);

    /**
     * @notice Indicates a failed native token transfer during reward distribution
     * @param intentHash The hash of the intent whose reward transfer failed
     */
    error NativeRewardTransferFailed(bytes32 intentHash);

    /**
     * @notice Indicates an attempt to publish a duplicate intent
     * @param intentHash The hash of the pre-existing intent
     */
    error IntentAlreadyExists(bytes32 intentHash);

    /**
     * @notice Indicates an attempt to fund an already funded intent
     * @param intentHash The hash of the previously funded intent
     */
    error IntentAlreadyFunded(bytes32 intentHash);

    /**
     * @notice Indicates insufficient native token payment for the required reward
     * @param intentHash The hash of the intent with insufficient funding
     */
    error InsufficientNativeReward(bytes32 intentHash);

    /**
     * @notice Thrown when the vault has insufficient token allowance for reward funding
     */
    error InsufficientTokenAllowance(
        address token,
        address spender,
        uint256 amount
    );

    /**
     * @notice Indicates an invalid attempt to fund with native tokens
     * @param intentHash The hash of the intent that cannot accept native tokens
     */
    error CannotFundForWithNativeReward(bytes32 intentHash);

    /**
     * @notice Indicates an unauthorized reward withdrawal attempt
     * @param hash The hash of the intent with protected rewards
     */
    error UnauthorizedWithdrawal(bytes32 hash);

    /**
     * @notice Indicates an attempt to withdraw already claimed rewards
     * @param hash The hash of the intent with depleted rewards
     */
    error RewardsAlreadyWithdrawn(bytes32 hash);

    /**
     * @notice Indicates a premature withdrawal attempt before intent expiration
     * @param intentHash The hash of the unexpired intent
     */
    error IntentNotExpired(bytes32 intentHash);

    /**
     * @notice Indicates a premature refund attempt before intent completion
     * @param intentHash The hash of the unclaimed intent
     */
    error IntentNotClaimed(bytes32 intentHash);

    /**
     * @notice Indicates an invalid token specified for refund
     */
    error InvalidRefundToken();

    /**
     * @notice Indicates mismatched array lengths in batch operations
     */
    error ArrayLengthMismatch();

    /**
     * @notice Signals partial funding of an intent
     * @param intentHash The hash of the partially funded intent
     * @param funder The address providing the partial funding
     */
    event IntentPartiallyFunded(bytes32 intentHash, address funder);

    /**
     * @notice Signals complete funding of an intent
     * @param intentHash The hash of the fully funded intent
     * @param funder The address providing the complete funding
     */
    event IntentFunded(bytes32 intentHash, address funder);

    /**
     * @notice Signals successful reward withdrawal
     * @param hash The hash of the claimed intent
     * @param recipient The address receiving the rewards
     */
    event Withdrawal(bytes32 hash, address indexed recipient);

    /**
     * @notice Signals successful reward refund
     * @param hash The hash of the refunded intent
     * @param recipient The address receiving the refund
     */
    event Refund(bytes32 hash, address indexed recipient);
}