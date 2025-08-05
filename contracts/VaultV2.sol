/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import {IVaultV2} from "./interfaces/IVaultV2.sol";
import {IPermit} from "./interfaces/IPermit.sol";
import {Reward} from "./types/Intent.sol";

contract VaultV2 is IVaultV2 {
    address private immutable portal;

    Status private status;

    using SafeERC20 for IERC20;
    using Math for uint256;

    constructor() {
        portal = msg.sender;
        status = Status.Initial;
    }

    modifier onlyPortal() {
        if (msg.sender != portal) {
            revert NotPortalCaller(msg.sender);
        }

        _;
    }

    modifier canFund() {
        if (status != Status.Initial) {
            revert InvalidStatusForFunding(status);
        }

        _;
    }

    modifier canWithdraw(address claimant) {
        if (status != Status.Initial && status != Status.Funded) {
            revert InvalidStatusForWithdrawal(status);
        }

        if (claimant == address(0)) {
            revert InvalidClaimant(claimant);
        }

        _;
    }

    modifier canRefund(uint256 deadline) {
        if (
            (status == Status.Initial || status == Status.Funded) &&
            block.timestamp < deadline
        ) {
            revert InvalidStatusForRefund(status, block.timestamp, deadline);
        }

        _;
    }

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

    function getStatus() external view override returns (Status) {
        return status;
    }

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
