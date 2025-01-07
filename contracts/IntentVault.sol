/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IIntentSource.sol";
import "./types/Intent.sol";

contract IntentVault {
    using SafeERC20 for IERC20;

    constructor(bytes32 intentHash, Reward memory reward) payable {
        uint256 rewardsLength = reward.tokens.length;

        address claimant = IIntentSource(msg.sender).getClaimed(intentHash);
        address refundToken = IIntentSource(msg.sender).getVaultRefundToken();

        if (claimant == address(0)) {
            claimant = reward.creator;
        }

        for (uint256 i; i < rewardsLength; ++i) {
            address token = reward.tokens[i].token;
            uint256 amount = reward.tokens[i].amount;
            uint256 balance = IERC20(token).balanceOf(address(this));

            require(
                token != refundToken,
                "IntentVault: refund token cannot be a reward token"
            );

            if (claimant == reward.creator) {
                if (balance > 0) {
                    IERC20(token).safeTransfer(claimant, balance);
                }
            } else {
                require(amount >= balance, "IntentVault: insufficient balance");

                IERC20(token).safeTransfer(claimant, amount);
                if (balance > amount) {
                    IERC20(token).safeTransfer(reward.creator, balance - amount);
                }
            }
        }

        if (claimant != reward.creator && reward.nativeValue > 0) {
            require(
                address(this).balance >= reward.nativeValue,
                "IntentVault: insufficient balance"
            );

            (bool success, ) = payable(claimant).call{value: reward.nativeValue}("");

            require(success, "IntentVault: native reward transfer failed");
        }

        if (refundToken != address(0)) {
            uint256 refundAmount = IERC20(refundToken).balanceOf(address(this));
            if (refundAmount > 0)
                IERC20(refundToken).safeTransfer(reward.creator, refundAmount);
        }

        selfdestruct(payable(reward.creator));
    }

    receive() external payable {}
}
