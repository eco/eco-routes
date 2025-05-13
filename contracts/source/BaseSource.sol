/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBaseSource} from "../interfaces/IBaseSource.sol";
import {Vault} from "../Vault.sol";
import {BaseProver} from "../prover/BaseProver.sol";
import {Reward} from "../types/Intent.sol";

/**
 * @title BaseSource
 * @notice Base contract for intent source implementations with common functionality
 */
abstract contract BaseSource is IBaseSource {
    using SafeERC20 for IERC20;

    // Shared state storage across all implementations
    mapping(bytes32 intentHash => VaultStorage) public vaults;

    /**
     * @notice Validates that an intent's vault holds sufficient rewards
     * @dev Checks both native token and ERC20 token balances
     * @param reward Reward to validate
     * @param vault Address of the intent's vault
     * @return True if vault has sufficient funds, false otherwise
     */
    function _isRewardFunded(
        Reward calldata reward,
        address vault
    ) internal view returns (bool) {
        uint256 rewardsLength = reward.tokens.length;

        if (vault.balance < reward.nativeValue) return false;

        for (uint256 i = 0; i < rewardsLength; ++i) {
            address token = reward.tokens[i].token;
            uint256 amount = reward.tokens[i].amount;
            uint256 balance = IERC20(token).balanceOf(vault);

            if (balance < amount) return false;
        }

        return true;
    }

    /**
     * @notice Validates the initial funding state
     * @param state Current vault state
     * @param intentHash Hash of the intent
     */
    function _validateInitialFundingState(
        VaultState memory state,
        bytes32 intentHash
    ) internal pure virtual {
        if (state.status != uint8(RewardStatus.Initial)) {
            revert IntentAlreadyFunded(intentHash);
        }
    }

    /**
     * @notice Validates the funding state for partial funding
     * @param state Current vault state
     * @param intentHash Hash of the intent
     */
    function _validateFundingState(
        VaultState memory state,
        bytes32 intentHash
    ) internal pure virtual {
        if (
            state.status != uint8(RewardStatus.Initial) &&
            state.status != uint8(RewardStatus.PartiallyFunded)
        ) {
            revert IntentAlreadyFunded(intentHash);
        }
    }

    /**
     * @notice Disabling fundFor for native intents
     * @dev Deploying vault in Fund mode might cause a loss of native reward
     * @param reward Reward structure to validate
     * @param vault Address of the intent vault
     * @param intentHash Hash of the intent
     */
    function _disableNativeReward(
        Reward calldata reward,
        address vault,
        bytes32 intentHash
    ) internal view virtual {
        // selfdestruct() will refund all native tokens to the creator
        // we can't use Fund mode for intents with native value
        // because deploying and destructing the vault will refund the native reward prematurely
        if (reward.nativeValue > 0 && vault.balance > 0) {
            revert CannotFundForWithNativeReward(intentHash);
        }
    }

    /**
     * @notice Validates that the intent is being published on correct chain
     * @param sourceChain Chain ID specified in the intent
     * @param intentHash Hash of the intent
     */
    function _validateSourceChain(
        uint256 sourceChain,
        bytes32 intentHash
    ) internal view virtual {
        if (sourceChain != block.chainid) {
            revert WrongSourceChain(intentHash);
        }
    }

    /**
     * @notice Returns excess ETH to the sender
     * @param intentHash Hash of the intent
     * @param amount Amount of ETH to return
     */
    function _returnExcessEth(
        bytes32 intentHash,
        uint256 amount
    ) internal virtual {
        if (amount > 0) {
            (bool success, ) = payable(msg.sender).call{value: amount}("");
            if (!success) revert NativeRewardTransferFailed(intentHash);
        }
    }

    /**
     * @notice Validates and publishes a new intent
     * @param intentHash Hash of the intent
     * @param state Current vault state
     */
    function _validatePublishState(
        bytes32 intentHash,
        VaultState memory state
    ) internal pure virtual {
        if (
            state.status == uint8(RewardStatus.Claimed) ||
            state.status == uint8(RewardStatus.Refunded)
        ) {
            revert IntentAlreadyExists(intentHash);
        }
    }
}
