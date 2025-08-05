/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import {IVaultV2} from "./interfaces/IVaultV2.sol";
import {IPermit} from "./interfaces/IPermit.sol";
import {Reward} from "./types/Intent.sol";

/**
 * @title VaultV2
 * @notice Escrow contract for managing cross-chain reward payments
 * @dev Implements a lifecycle-based vault that can be funded, withdrawn from, or refunded
 */
contract VaultV2 is IVaultV2 {
    /// @notice Address of the portal contract that can call this vault
    address private immutable portal;

    /// @notice Current status of the vault in its lifecycle
    Status private status;

    using SafeERC20 for IERC20;
    using Math for uint256;

    /**
     * @notice Creates a new vault instance
     * @dev Sets the deployer as the portal and initializes status to Initial
     */
    constructor() {
        portal = msg.sender;
        status = Status.Initial;
    }

    /// @notice Restricts function access to only the portal contract
    modifier onlyPortal() {
        if (msg.sender != portal) {
            revert NotPortalCaller(msg.sender);
        }

        _;
    }

    /// @notice Ensures vault can be funded (must be in Initial status)
    modifier canFund() {
        if (status != Status.Initial) {
            revert InvalidStatusForFunding(status);
        }

        _;
    }

    /// @notice Ensures vault can be withdrawn from and claimant is valid
    modifier canWithdraw(address claimant) {
        if (status != Status.Initial && status != Status.Funded) {
            revert InvalidStatusForWithdrawal(status);
        }

        if (claimant == address(0)) {
            revert InvalidClaimant(claimant);
        }

        _;
    }

    /// @notice Ensures vault can be refunded (deadline must have passed)
    modifier canRefund(uint256 deadline) {
        if (
            (status == Status.Initial || status == Status.Funded) &&
            block.timestamp < deadline
        ) {
            revert InvalidStatusForRefund(status, block.timestamp, deadline);
        }

        _;
    }

    /**
     * @notice Funds the vault with tokens and native currency from the reward
     * @param reward The reward structure containing token addresses, amounts, and native value
     * @param funder Address that will provide the funding
     * @param permit Optional permit contract for gasless token approvals
     * @return bool True if the vault was fully funded, false otherwise
     */
    function fund(
        Reward calldata reward,
        address funder,
        IPermit permit
    ) external payable override onlyPortal canFund returns (bool) {
        bool funded = address(this).balance >= reward.nativeValue;

        uint256 rewardsLength = reward.tokens.length;
        for (uint256 i; i < rewardsLength; ++i) {
            IERC20 token = IERC20(reward.tokens[i].token);

            bool tokenFunded = fundFrom(
                funder,
                token,
                reward.tokens[i].amount
            ) || fundFromPermit(funder, token, reward.tokens[i].amount, permit);
            funded = funded && tokenFunded;
        }

        if (funded) {
            status = Status.Funded;
        }

        return funded;
    }

    /**
     * @notice Withdraws rewards from the vault to the specified claimant
     * @param reward The reward structure defining what to withdraw
     * @param claimant Address that will receive the withdrawn rewards
     */
    function withdraw(
        Reward calldata reward,
        address claimant
    ) external override onlyPortal canWithdraw(claimant) {
        status = Status.Withdrawn;

        uint256 rewardsLength = reward.tokens.length;
        for (uint256 i; i < rewardsLength; ++i) {
            IERC20 token = IERC20(reward.tokens[i].token);
            uint256 amount = reward.tokens[i].amount.min(
                token.balanceOf(address(this))
            );

            if (amount > 0) {
                token.safeTransfer(claimant, amount);
            }
        }

        uint256 nativeAmount = address(this).balance.min(reward.nativeValue);
        if (nativeAmount == 0) {
            return;
        }

        (bool success, ) = claimant.call{value: nativeAmount}("");
        if (!success) {
            revert NativeTransferFailed(claimant, nativeAmount);
        }
    }

    /**
     * @notice Refunds all vault contents back to the reward creator
     * @param reward The reward structure containing creator address and deadline
     */
    function refund(
        Reward calldata reward
    ) external override onlyPortal canRefund(reward.deadline) {
        address refundee = reward.creator;

        status = Status.Refunded;

        uint256 rewardsLength = reward.tokens.length;
        for (uint256 i; i < rewardsLength; ++i) {
            IERC20 token = IERC20(reward.tokens[i].token);
            uint256 amount = token.balanceOf(address(this));

            if (amount > 0) {
                token.safeTransfer(refundee, amount);
            }
        }

        uint256 nativeAmount = address(this).balance;
        if (nativeAmount == 0) {
            return;
        }

        (bool success, ) = refundee.call{value: nativeAmount}("");
        if (!success) {
            revert NativeTransferFailed(refundee, nativeAmount);
        }
    }

    /**
     * @notice Returns the current status of the vault
     * @return Status The current vault status
     */
    function getStatus() external view override returns (Status) {
        return status;
    }

    /**
     * @notice Internal function to fund vault with tokens using standard ERC20 transfers
     * @param funder Address providing the tokens
     * @param token ERC20 token contract
     * @param rewardAmount Required token amount for the reward
     * @return bool True if vault has sufficient balance after transfer attempt
     */
    function fundFrom(
        address funder,
        IERC20 token,
        uint256 rewardAmount
    ) internal returns (bool) {
        uint256 balance = token.balanceOf(address(this));

        if (balance >= rewardAmount) {
            return true;
        }

        uint256 allowance = token.allowance(funder, address(this));
        uint256 funderBalance = token.balanceOf(funder);

        uint256 transferAmount = (rewardAmount - balance)
            .min(funderBalance)
            .min(allowance);

        if (transferAmount > 0) {
            token.safeTransferFrom(funder, address(this), transferAmount);
        }

        return balance + transferAmount >= rewardAmount;
    }

    /**
     * @notice Internal function to fund vault using permit-based transfers
     * @param funder Address providing the tokens
     * @param token ERC20 token contract
     * @param rewardAmount Required token amount for the reward
     * @param permit Permit contract for gasless approvals
     * @return bool True if vault has sufficient balance after transfer attempt
     */
    function fundFromPermit(
        address funder,
        IERC20 token,
        uint256 rewardAmount,
        IPermit permit
    ) internal returns (bool) {
        uint256 balance = token.balanceOf(address(this));

        if (address(permit) == address(0)) {
            return balance >= rewardAmount;
        }

        if (balance >= rewardAmount) {
            return true;
        }

        (uint160 allowance, , ) = permit.allowance(
            funder,
            address(token),
            address(this)
        );
        uint256 funderBalance = IERC20(token).balanceOf(funder);

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

        return balance + transferAmount >= rewardAmount;
    }
}
