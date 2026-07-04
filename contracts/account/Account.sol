/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import {IAccount} from "../interfaces/IAccount.sol";
import {IPermit} from "../interfaces/IPermit.sol";
import {IPolicy} from "../interfaces/IPolicy.sol";
import {Reward, RewardToken} from "../types/Intent.sol";

/**
 * @title Account
 * @notice Escrow contract for managing cross-chain reward payments (v3 rate+flat legs)
 * @dev Implements a lifecycle-based account that can be funded, withdrawn from, or refunded. Rewards are
 *      per-token legs; native folds in as a leg with `token == address(0)`. On withdraw the Account
 *      consults `reward.prover` (as a VIEW — no reentrancy surface) to turn the core-verified
 *      `fulfilled[]` into per-leg amounts, pays each capped at its own balance to the claimant, and
 *      sweeps the residual to the keeper.
 */
contract Account is IAccount {
    /// @notice Address of the portal contract that can call this account
    address private immutable portal;

    using SafeERC20 for IERC20;
    using Math for uint256;

    /**
     * @notice Creates a new account instance
     * @dev Sets the deployer (IntentSource) as the authorized portal contract
     */
    constructor() {
        portal = msg.sender;
    }

    /**
     * @notice Restricts function access to only the portal contract
     */
    modifier onlyPortal() {
        if (msg.sender != portal) {
            revert NotPortalCaller(msg.sender);
        }

        _;
    }

    /**
     * @notice Funds the account with reward legs from the funder
     * @dev `targets[j]` is the escrow target for reward leg `j` (computed by IntentSource from the paired
     *      `minTokens` and the leg's rate/flat). Native (`token == address(0)`) is funded from `msg.value`;
     *      ERC20 legs are pulled via permit then standing allowance.
     * @param reward The reward structure containing the legs
     * @param targets Per-leg escrow targets, index-aligned with `reward.tokens`
     * @param funder Address that will provide the funding
     * @param permit Optional permit contract for gasless token approvals
     * @return fullyFunded True if every leg reached its target, false otherwise
     */
    function fundFor(
        Reward calldata reward,
        uint256[] calldata targets,
        address funder,
        IPermit permit
    ) external payable onlyPortal returns (bool fullyFunded) {
        fullyFunded = true;

        uint256 rewardsLength = reward.tokens.length;
        for (uint256 i; i < rewardsLength; ++i) {
            address tokenAddr = reward.tokens[i].token;
            uint256 target = targets[i];

            if (tokenAddr == address(0)) {
                // Native leg: funded from the value already delivered to the account.
                fullyFunded = fullyFunded && address(this).balance >= target;
                continue;
            }

            IERC20 token = IERC20(tokenAddr);
            uint256 remaining = _fundFromPermit(funder, token, target, permit);
            remaining = _fundFrom(funder, token, remaining);

            fullyFunded = fullyFunded && remaining == 0;
        }
    }

    /**
     * @notice Withdraws the owed reward to the claimant and sweeps the residual to the keeper
     * @dev Consults `reward.prover.previewRelease(reward, fulfilled)` (a VIEW) for the per-leg amounts,
     *      pays each capped at its own balance to `claimant`, and returns the leftover of each leg token
     *      to `reward.keeper`.
     * @param reward The reward structure defining the legs and the prover
     * @param claimant Address that will receive the owed reward
     * @param fulfilled Core-verified per-leg delivered amounts (paired prefix)
     */
    function withdraw(
        Reward calldata reward,
        address claimant,
        uint256[] calldata fulfilled
    ) external onlyPortal {
        uint256[] memory payNow = IPolicy(reward.prover).previewRelease(
            reward,
            fulfilled
        );

        uint256 rewardsLength = reward.tokens.length;
        for (uint256 i; i < rewardsLength; ++i) {
            address tokenAddr = reward.tokens[i].token;

            if (tokenAddr == address(0)) {
                uint256 pay = payNow[i].min(address(this).balance);
                if (pay > 0) {
                    // Try to send to claimant - if it fails, ETH remains for the keeper sweep below
                    claimant.call{value: pay}("");
                }
                uint256 residual = address(this).balance;
                if (residual > 0) {
                    reward.keeper.call{value: residual}("");
                }
                continue;
            }

            IERC20 token = IERC20(tokenAddr);
            uint256 balance = token.balanceOf(address(this));
            uint256 payAmount = payNow[i].min(balance);
            if (payAmount > 0) {
                _transferToken(token, claimant, payAmount);
            }
            uint256 tokenResidual = token.balanceOf(address(this));
            if (tokenResidual > 0) {
                _transferToken(token, reward.keeper, tokenResidual);
            }
        }
    }

    /**
     * @notice Refunds all account contents to a specified address
     * @param reward The reward structure containing the leg tokens
     * @param refundee Address to receive the refunded rewards
     */
    function refund(
        Reward calldata reward,
        address refundee
    ) external onlyPortal {
        uint256 rewardsLength = reward.tokens.length;
        for (uint256 i; i < rewardsLength; ++i) {
            address tokenAddr = reward.tokens[i].token;
            if (tokenAddr == address(0)) {
                continue;
            }
            IERC20 token = IERC20(tokenAddr);
            uint256 amount = token.balanceOf(address(this));

            if (amount > 0) {
                _transferToken(token, refundee, amount);
            }
        }

        uint256 nativeAmount = address(this).balance;
        if (nativeAmount > 0) {
            // Try to send to refundee - if it fails, ETH remains in account for future refund attempts
            refundee.call{value: nativeAmount}("");
        }
    }

    /**
     * @notice Recovers tokens that are not part of the reward to the keeper
     * @param refundee Address to receive the recovered tokens
     * @param token Address of the token to recover (must not be a reward token)
     */
    function recover(address refundee, address token) external onlyPortal {
        IERC20 tokenContract = IERC20(token);
        uint256 balance = tokenContract.balanceOf(address(this));

        if (balance == 0) {
            revert ZeroRecoverTokenBalance(token);
        }

        _transferToken(tokenContract, refundee, balance);
    }

    /**
     * @notice Internal function to fund account with tokens using standard ERC20 transfers
     * @param funder Address providing the tokens
     * @param token ERC20 token contract
     * @param remainingAmount Remaining amount needed to fully fund the leg
     * @return uint256 Remaining amount needed to fully fund the leg
     */
    function _fundFrom(
        address funder,
        IERC20 token,
        uint256 remainingAmount
    ) internal returns (uint256) {
        if (remainingAmount == 0) {
            return 0;
        }

        uint256 allowance = token.allowance(funder, address(this));
        uint256 funderBalance = token.balanceOf(funder);

        uint256 transferAmount = remainingAmount.min(funderBalance).min(
            allowance
        );

        if (transferAmount > 0) {
            token.safeTransferFrom(funder, address(this), transferAmount);
        }

        return remainingAmount - transferAmount;
    }

    /**
     * @notice Internal function to fund account using permit-based transfers
     * @param funder Address providing the tokens
     * @param token ERC20 token contract
     * @param rewardAmount Required token amount for the leg
     * @param permit Permit contract for gasless approvals
     * @return uint256 Remaining amount needed to fully fund the leg
     */
    function _fundFromPermit(
        address funder,
        IERC20 token,
        uint256 rewardAmount,
        IPermit permit
    ) internal returns (uint256) {
        uint256 balance = token.balanceOf(address(this));

        if (balance >= rewardAmount) {
            return 0;
        }

        if (address(permit) == address(0)) {
            return rewardAmount - balance;
        }

        (uint160 allowance, , ) = permit.allowance(
            funder,
            address(token),
            address(this)
        );
        uint256 funderBalance = token.balanceOf(funder);

        uint256 transferAmount = (rewardAmount - balance)
            .min(funderBalance)
            .min(uint256(allowance));

        if (transferAmount > 0) {
            permit.transferFrom(
                funder,
                address(this),
                uint160(transferAmount),
                address(token)
            );
        }

        return rewardAmount - token.balanceOf(address(this));
    }

    /**
     * @notice Transfers ERC20 tokens out of the account.
     * @dev Virtual so subclasses can override for non-standard tokens (e.g. Tron USDT).
     * @param token ERC20 token to transfer
     * @param to Recipient address
     * @param amount Amount to transfer
     */
    function _transferToken(
        IERC20 token,
        address to,
        uint256 amount
    ) internal virtual {
        token.safeTransfer(to, amount);
    }
}
