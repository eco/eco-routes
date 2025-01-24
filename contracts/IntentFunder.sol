/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IIntentSource} from "./interfaces/IIntentSource.sol";
import {Reward} from "./types/Intent.sol";

/**
 * @title IntentFunder
 * @notice Handles the funding process for intent rewards by transferring tokens and native currency to vaults
 * @dev This is a single-use contract that is deployed by IntentSource for each funding operation
 * and self-destructs after completing its task. It transfers any approved tokens from the funding
 * source to the vault up to the required amount or available allowance.
 */
contract IntentFunder {
    // Use OpenZeppelin's SafeERC20 for safe token transfers
    using SafeERC20 for IERC20;

    /**
     * @notice Instantiates and executes the funding operation in a single transaction
     * @dev The constructor performs all funding operations and then self-destructs.
     * The contract can only be deployed by IntentSource, which is checked implicitly
     * by accessing msg.sender as the IntentSource contract
     * @param vault The address of the vault that will receive the tokens and native currency
     * @param reward The reward structure containing token amounts and recipient details
     */
    constructor(address vault, Reward memory reward) {
        // Cast msg.sender to IIntentSource since we know it must be the IntentSource contract
        IIntentSource intentSource = IIntentSource(msg.sender);

        // Cache array length to save gas in loop
        uint256 rewardsLength = reward.tokens.length;

        // Get the address that is providing the tokens for funding
        address fundingSource = intentSource.getFundingSource();
        address refundToken = intentSource.getRefundToken();

        if (refundToken != address(0)) {
            IERC20(refundToken).safeTransfer(
                reward.creator,
                IERC20(refundToken).balanceOf(address(this))
            );
        }

        // Iterate through each token in the reward structure
        for (uint256 i; i < rewardsLength; ++i) {
            // Get token address and required amount for current reward
            address token = reward.tokens[i].token;
            uint256 amount = reward.tokens[i].amount;

            // Check how many tokens this contract is allowed to transfer from funding source
            uint256 allowance = IERC20(token).allowance(
                fundingSource,
                address(this)
            );

            // Calculate how many more tokens the vault needs to be fully funded
            // Cast to int256 to handle the case where vault is already overfunded
            int256 balanceDeficit = int256(amount) -
                int256(IERC20(token).balanceOf(vault));

            // Only proceed if vault needs more tokens and we have permission to transfer them
            if (balanceDeficit > 0 && allowance > 0) {
                // Calculate transfer amount as minimum of what's needed and what's allowed
                uint256 transferAmount = allowance > uint256(balanceDeficit)
                    ? uint256(balanceDeficit)
                    : allowance;

                // Transfer tokens from funding source to vault using safe transfer
                IERC20(token).safeTransferFrom(
                    fundingSource,
                    vault,
                    transferAmount
                );
            }
        }

        // After all transfers are complete, self-destruct and send any remaining ETH to reward creator
        selfdestruct(payable(reward.creator));
    }
}
