/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IIntentSource} from "./interfaces/IIntentSource.sol";
import {IIntentVault} from "./interfaces/IIntentVault.sol";
import {Reward} from "./types/Intent.sol";

/**
 * @title IntentVault
 * @notice A self-destructing contract that handles reward distribution for intents
 * @dev Created by IntentSource for each intent, handles token and native currency transfers,
 * then self-destructs after distributing rewards
 */
contract IntentVault is IIntentVault {
    using SafeERC20 for IERC20;

    /**
     * @notice Creates and immediately executes reward distribution
     * @dev Contract self-destructs after execution
     * @param intentHash Hash of the intent being claimed/refunded
     * @param reward Reward data structure containing distribution details
     */
    constructor(bytes32 intentHash, Reward memory reward) {
        // Get reference to the IntentSource contract that created this vault
        IIntentSource intentSource = IIntentSource(msg.sender);
        uint256 rewardsLength = reward.tokens.length;

        // Get current claim state and any refund token override
        IIntentSource.ClaimState memory state = intentSource.getClaim(
            intentHash
        );
        address claimant = state.claimant;
        address refundToken = intentSource.getRefundToken();

        // Ensure intent has expired if there's no claimant
        if (claimant == address(0) && block.timestamp <= reward.deadline) {
            revert IntentNotExpired();
        }

        // Withdrawing to creator if intent is expired or already claimed/refunded
        if (
            (claimant == address(0) && block.timestamp > reward.deadline) ||
            state.status != uint8(IIntentSource.ClaimStatus.Initial)
        ) {
            claimant = reward.creator;
        }

        // Process each reward token
        for (uint256 i; i < rewardsLength; ++i) {
            address token = reward.tokens[i].token;
            uint256 amount = reward.tokens[i].amount;
            uint256 balance = IERC20(token).balanceOf(address(this));

            // Prevent reward tokens from being used as refund tokens
            if (token == refundToken) {
                revert RefundTokenCannotBeRewardToken();
            }

            // If creator is claiming or balance is below expected amount, send full balance
            if (claimant == reward.creator || balance < amount) {
                if (balance > 0) {
                    _tryTransfer(token, claimant, balance);
                }
            } else {
                _tryTransfer(token, claimant, amount);

                // Return excess balance to creator
                if (balance > amount) {
                    _tryTransfer(token, reward.creator, balance - amount);
                }
            }
        }

        // Handle native token rewards for solver claims
        if (claimant != reward.creator && reward.nativeValue > 0) {
            if (address(this).balance < reward.nativeValue) {
                revert InsufficientNativeBalance();
            }

            (bool success, ) = payable(claimant).call{
                value: reward.nativeValue
            }("");

            if (!success) {
                revert NativeRewardTransferFailed();
            }
        }

        // Process any refund token if specified
        if (refundToken != address(0)) {
            uint256 refundAmount = IERC20(refundToken).balanceOf(address(this));
            if (refundAmount > 0)
                IERC20(refundToken).safeTransfer(reward.creator, refundAmount);
        }

        // Self-destruct and send remaining ETH to creator
        selfdestruct(payable(reward.creator));
    }

    /**
     * @notice Attempts to transfer tokens to a recipient, emitting an event on failure
     * @param token Address of the token being transferred
     * @param to Address of the recipient
     * @param amount Amount of tokens to transfer
     */
    function _tryTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );

        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) {
            emit RewardTransferFailed(token, to, amount);
        }
    }
}
