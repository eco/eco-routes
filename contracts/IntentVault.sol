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
            state.status != uint8(IIntentSource.ClaimStatus.Initiated)
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

            // If creator is claiming, send full balance
            if (claimant == reward.creator) {
                if (balance > 0) {
                    try IERC20(token).transfer(claimant, balance) {
                        // If transfer succeeds, continue
                                              
                    } catch {
                        // if transfer fails, skip to next token
                    }
                }
            } else {
                // For solver claims, verify sufficient balance and send reward amount
                if (balance < amount) {
                    revert InsufficientTokenBalance();
                }

                try IERC20(token).transfer(claimant, balance) {
                    // If transfer succeeds, continue
                } catch {
                    // if transfer fails, skip to next token
                }
                // Return excess balance to creator
                if (balance > amount) {
                    try IERC20(token).transfer(reward.creator, balance) {
                        // If transfer succeeds, continue
                    } catch {
                        // if transfer fails, skip to next token
                    }
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
}
