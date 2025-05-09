/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IUniversalIntentSource} from "./interfaces/IUniversalIntentSource.sol";
import {BaseProver} from "./prover/BaseProver.sol";
import {Reward as EvmReward} from "./types/Intent.sol";
import {Intent, Route, Reward, Call, TokenAmount} from "./types/UniversalIntent.sol";
import {AddressConverter} from "./libs/AddressConverter.sol";
import {Semver} from "./libs/Semver.sol";

import {Vault} from "./Vault.sol";

/**
 * @title UniversalIntentSource
 * @notice Abstract base contract for the Eco Protocol's intent system with cross-chain support
 * @dev Implements core functionality using bytes32 for cross-chain compatibility
 *      Derived contracts can inherit and implement interface-specific methods
 */
abstract contract UniversalIntentSource is IUniversalIntentSource, Semver {
    using SafeERC20 for IERC20;
    using AddressConverter for bytes32;

    mapping(bytes32 intentHash => VaultStorage) public vaults;

    /**
     * @notice Retrieves reward status for a given intent hash
     * @param intentHash Hash of the intent to query
     * @return status Current status of the intent
     */
    function getRewardStatus(
        bytes32 intentHash
    ) external view virtual override returns (RewardStatus status) {
        return RewardStatus(vaults[intentHash].state.status);
    }

    /**
     * @notice Retrieves vault state for a given intent hash
     * @param intentHash Hash of the intent to query
     * @return VaultState struct containing vault information
     */
    function getVaultState(
        bytes32 intentHash
    ) external view virtual override returns (VaultState memory) {
        return vaults[intentHash].state;
    }

    /**
     * @notice Retrieves the permitContact address funding an intent
     */
    function getPermitContract(
        bytes32 intentHash
    ) external view virtual override returns (address) {
        return vaults[intentHash].permitContract;
    }

    /**
     * @notice Calculates the hash of an intent and its components
     * @param intent The intent to hash
     * @return intentHash Combined hash of route and reward
     * @return routeHash Hash of the route component
     * @return rewardHash Hash of the reward component
     */
    function getIntentHash(
        Intent calldata intent
    )
        external
        pure
        override
        returns (bytes32 intentHash, bytes32 routeHash, bytes32 rewardHash)
    {
        routeHash = keccak256(abi.encode(intent.route));
        rewardHash = keccak256(abi.encode(intent.reward));
        intentHash = keccak256(abi.encodePacked(routeHash, rewardHash));
    }

    /**
     * @notice Calculates the deterministic address of the intent vault
     * @param intent Intent to calculate vault address for
     * @return Address of the intent vault
     */
    function intentVaultAddress(
        Intent calldata intent
    ) external view override returns (address) {
        (bytes32 intentHash, bytes32 routeHash, ) = getIntentHashInternal(intent);
        return _getIntentVaultAddress(intentHash, routeHash, intent.reward);
    }

    /**
     * @notice Internal function to calculate intent hash (needed since getIntentHash is external)
     * @param intent Intent to calculate hash for
     * @return intentHash Combined hash of route and reward
     * @return routeHash Hash of the route component
     * @return rewardHash Hash of the reward component
     */
    function getIntentHashInternal(
        Intent calldata intent
    ) internal pure returns (bytes32 intentHash, bytes32 routeHash, bytes32 rewardHash) {
        routeHash = keccak256(abi.encode(intent.route));
        rewardHash = keccak256(abi.encode(intent.reward));
        intentHash = keccak256(abi.encodePacked(routeHash, rewardHash));
    }

    /**
     * @notice Creates an intent without funding
     * @param intent The complete intent struct to be published
     * @return intentHash Hash of the created intent
     */
    function publish(
        Intent calldata intent
    ) external override returns (bytes32 intentHash) {
        (intentHash, , ) = getIntentHashInternal(intent);
        VaultState memory state = vaults[intentHash].state;

        _validateAndPublishIntent(intent, intentHash, state);
        return intentHash;
    }

    /**
     * @notice Creates and funds an intent in a single transaction
     * @param intent The complete intent struct to be published and funded
     * @return intentHash Hash of the created and funded intent
     */
    function publishAndFund(
        Intent calldata intent,
        bool allowPartial
    ) external payable override returns (bytes32 intentHash) {
        bytes32 routeHash;
        (intentHash, routeHash, ) = getIntentHashInternal(intent);
        VaultState memory state = vaults[intentHash].state;

        _validateInitialFundingState(state, intentHash);
        _validateSourceChain(intent.route.source, intentHash);
        _validateAndPublishIntent(intent, intentHash, state);

        address vault = _getIntentVaultAddress(
            intentHash,
            routeHash,
            intent.reward
        );
        _fundIntent(intentHash, intent.reward, vault, msg.sender, allowPartial);

        _returnExcessEth(intentHash, address(this).balance);
        return intentHash;
    }

    /**
     * @notice Funds an existing intent
     * @param routeHash Hash of the route component
     * @param reward Reward structure containing distribution details
     * @return intentHash Hash of the funded intent
     */
    function fund(
        bytes32 routeHash,
        Reward calldata reward,
        bool allowPartial
    ) external payable virtual returns (bytes32 intentHash) {
        bytes32 rewardHash = keccak256(abi.encode(reward));
        intentHash = keccak256(abi.encodePacked(routeHash, rewardHash));
        VaultState memory state = vaults[intentHash].state;

        _validateInitialFundingState(state, intentHash);

        address vault = _getIntentVaultAddress(intentHash, routeHash, reward);
        _fundIntent(intentHash, reward, vault, msg.sender, allowPartial);

        _returnExcessEth(intentHash, address(this).balance);
        return intentHash;
    }

    /**
     * @notice Funds an intent for a user with permit/allowance
     * @param routeHash Hash of the route component
     * @param reward Reward structure containing distribution details
     * @param funder Address to fund the intent from
     * @param permitContact Address of the permitContact instance
     * @param allowPartial Whether to allow partial funding
     * @return intentHash Hash of the funded intent
     */
    function fundFor(
        bytes32 routeHash,
        Reward calldata reward,
        address funder,
        address permitContact,
        bool allowPartial
    ) external virtual returns (bytes32 intentHash) {
        bytes32 rewardHash = keccak256(abi.encode(reward));
        intentHash = keccak256(abi.encodePacked(routeHash, rewardHash));
        VaultState memory state = vaults[intentHash].state;

        address vault = _getIntentVaultAddress(intentHash, routeHash, reward);

        _fundIntentFor(
            state,
            reward,
            intentHash,
            routeHash,
            vault,
            funder,
            permitContact,
            allowPartial
        );

        return intentHash;
    }

    /**
     * @notice Creates and funds an intent using permit/allowance
     * @param intent The complete intent struct
     * @param funder Address to fund the intent from
     * @param permitContact Address of the permitContact instance
     * @param allowPartial Whether to allow partial funding
     * @return intentHash Hash of the created and funded intent
     */
    function publishAndFundFor(
        Intent calldata intent,
        address funder,
        address permitContact,
        bool allowPartial
    ) external override returns (bytes32 intentHash) {
        bytes32 routeHash;
        (intentHash, routeHash, ) = getIntentHashInternal(intent);
        VaultState memory state = vaults[intentHash].state;

        _validateAndPublishIntent(intent, intentHash, state);
        _validateSourceChain(intent.route.source, intentHash);

        address vault = _getIntentVaultAddress(
            intentHash,
            routeHash,
            intent.reward
        );

        _fundIntentFor(
            state,
            intent.reward,
            intentHash,
            routeHash,
            vault,
            funder,
            permitContact,
            allowPartial
        );

        return intentHash;
    }

    /**
     * @notice Checks if an intent is completely funded
     * @param intent Intent to validate
     * @return True if intent is completely funded, false otherwise
     */
    function isIntentFunded(
        Intent calldata intent
    ) external view override returns (bool) {
        if (intent.route.source != block.chainid) return false;

        (bytes32 intentHash, bytes32 routeHash, ) = getIntentHashInternal(intent);
        address vault = _getIntentVaultAddress(
            intentHash,
            routeHash,
            intent.reward
        );

        return _isRewardFunded(intent.reward, vault);
    }

    /**
     * @notice Withdraws rewards associated with an intent to its claimant
     * @param routeHash Hash of the intent's route
     * @param reward Reward structure of the intent
     */
    function withdrawRewards(bytes32 routeHash, Reward calldata reward) external virtual {
        _withdrawRewards(routeHash, reward);
    }

    /**
     * @notice Internal implementation of withdrawRewards
     * @param routeHash Hash of the intent's route
     * @param reward Reward structure of the intent
     */
    function _withdrawRewards(bytes32 routeHash, Reward calldata reward) internal {
        bytes32 rewardHash = keccak256(abi.encode(reward));
        bytes32 intentHash = keccak256(abi.encodePacked(routeHash, rewardHash));

        address claimant = BaseProver(reward.prover.toAddress()).provenIntents(intentHash);
        VaultState memory state = vaults[intentHash].state;

        // Claim the rewards if the intent has not been claimed
        if (
            claimant != address(0) &&
            state.status != uint8(RewardStatus.Claimed) &&
            state.status != uint8(RewardStatus.Refunded)
        ) {
            state.status = uint8(RewardStatus.Claimed);
            state.mode = uint8(VaultMode.Claim);
            state.allowPartialFunding = 0;
            state.usePermit = 0;
            state.target = claimant;
            vaults[intentHash].state = state;

            emit Withdrawal(intentHash, claimant);

            // Deploy Vault using assembly for better gas efficiency
            bytes memory bytecode = abi.encodePacked(
                type(Vault).creationCode,
                abi.encode(intentHash, reward)
            );

            address vault;
            assembly {
                vault := create2(0, add(bytecode, 0x20), mload(bytecode), routeHash)
                if iszero(extcodesize(vault)) {
                    revert(0, 0)
                }
            }

            return;
        }

        if (claimant == address(0)) {
            revert UnauthorizedWithdrawal(intentHash);
        } else {
            revert RewardsAlreadyWithdrawn(intentHash);
        }
    }

    /**
     * @notice Batch withdraws multiple intents
     * @param routeHashes Array of route hashes for the intents
     * @param rewards Array of reward structures for the intents
     */
    function batchWithdraw(
        bytes32[] calldata routeHashes,
        Reward[] calldata rewards
    ) external virtual {
        uint256 length = routeHashes.length;

        if (length != rewards.length) {
            revert ArrayLengthMismatch();
        }

        for (uint256 i = 0; i < length; ++i) {
            // Call the internal implementation instead of the external function
            _withdrawRewards(routeHashes[i], rewards[i]);
        }
    }

    /**
     * @notice Refunds rewards to the intent creator
     * @param routeHash Hash of the intent's route
     * @param reward Reward structure of the intent
     */
    function refund(bytes32 routeHash, Reward calldata reward) external virtual {
        bytes32 rewardHash = keccak256(abi.encode(reward));
        bytes32 intentHash = keccak256(abi.encodePacked(routeHash, rewardHash));

        VaultState memory state = vaults[intentHash].state;

        if (
            state.status != uint8(RewardStatus.Claimed) &&
            state.status != uint8(RewardStatus.Refunded)
        ) {
            address claimant = BaseProver(reward.prover.toAddress()).provenIntents(
                intentHash
            );
            // Check if the intent has been proven to prevent unauthorized refunds
            if (claimant != address(0)) {
                revert IntentNotClaimed(intentHash);
            }
            // Revert if intent has not expired
            if (block.timestamp <= reward.deadline) {
                revert IntentNotExpired(intentHash);
            }
        }

        if (state.status != uint8(RewardStatus.Claimed)) {
            state.status = uint8(RewardStatus.Refunded);
        }

        state.mode = uint8(VaultMode.Refund);
        state.allowPartialFunding = 0;
        state.usePermit = 0;
        state.target = address(0);
        vaults[intentHash].state = state;

        emit Refund(intentHash, reward.creator.toAddress());

        // Deploy Vault using assembly for better gas efficiency
        bytes memory bytecode = abi.encodePacked(
            type(Vault).creationCode,
            abi.encode(intentHash, reward)
        );

        address vault;
        assembly {
            vault := create2(0, add(bytecode, 0x20), mload(bytecode), routeHash)
            if iszero(extcodesize(vault)) {
                revert(0, 0)
            }
        }
    }

    /**
     * @notice Recover tokens that were sent to the intent vault by mistake
     * @dev Must not be among the intent's rewards
     * @param routeHash Hash of the intent's route
     * @param reward Reward structure of the intent
     * @param token Token address for handling incorrect vault transfers
     */
    function recoverToken(
        bytes32 routeHash,
        Reward calldata reward,
        address token
    ) external virtual {
        if (token == address(0)) {
            revert InvalidRefundToken();
        }

        bytes32 rewardHash = keccak256(abi.encode(reward));
        bytes32 intentHash = keccak256(abi.encodePacked(routeHash, rewardHash));

        VaultState memory state = vaults[intentHash].state;

        // selfdestruct() will refund all native tokens to the creator
        // we can't refund native intents before the claim/refund happens
        // because deploying and destructing the vault will refund the native reward prematurely
        if (
            state.status != uint8(RewardStatus.Claimed) &&
            state.status != uint8(RewardStatus.Refunded) &&
            reward.nativeValue > 0
        ) {
            revert IntentNotClaimed(intentHash);
        }

        // Check if the token is part of the reward
        for (uint256 i = 0; i < reward.tokens.length; ++i) {
            if (reward.tokens[i].token.toAddress() == token) {
                revert InvalidRefundToken();
            }
        }

        state.mode = uint8(VaultMode.RecoverToken);
        state.allowPartialFunding = 0;
        state.usePermit = 0;
        state.target = token;
        vaults[intentHash].state = state;

        emit Refund(intentHash, reward.creator.toAddress());

        // Deploy Vault using assembly for better gas efficiency
        bytes memory bytecode = abi.encodePacked(
            type(Vault).creationCode,
            abi.encode(intentHash, reward)
        );

        address vault;
        assembly {
            vault := create2(0, add(bytecode, 0x20), mload(bytecode), routeHash)
            if iszero(extcodesize(vault)) {
                revert(0, 0)
            }
        }
    }

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
            address token = reward.tokens[i].token.toAddress();
            uint256 amount = reward.tokens[i].amount;
            uint256 balance = IERC20(token).balanceOf(vault);

            if (balance < amount) return false;
        }

        return true;
    }

    /**
     * @notice Calculates the deterministic address of an intent vault using CREATE2
     * @dev Follows EIP-1014 for address calculation
     * @param intentHash Hash of the full intent
     * @param routeHash Hash of the route component
     * @param reward Reward structure
     * @return The calculated vault address
     */
    function _getIntentVaultAddress(
        bytes32 intentHash,
        bytes32 routeHash,
        Reward calldata reward
    ) internal view returns (address) {
        /* Convert a hash which is bytes32 to an address which is 20-byte long
        according to https://docs.soliditylang.org/en/v0.8.9/control-structures.html?highlight=create2#salted-contract-creations-create2 */
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                hex"ff",
                                address(this),
                                routeHash,
                                keccak256(
                                    abi.encodePacked(
                                        type(Vault).creationCode,
                                        abi.encode(intentHash, reward)
                                    )
                                )
                            )
                        )
                    )
                )
            );
    }

    /**
     * @notice Validates and publishes a new intent
     * @param intent The intent to validate and publish
     * @param intentHash Hash of the intent
     * @param state Current vault state
     */
    function _validateAndPublishIntent(
        Intent calldata intent,
        bytes32 intentHash,
        VaultState memory state
    ) internal {
        if (
            state.status == uint8(RewardStatus.Claimed) ||
            state.status == uint8(RewardStatus.Refunded)
        ) {
            revert IntentAlreadyExists(intentHash);
        }

        // Use a separate function to emit event to avoid stack-too-deep errors
        _emitIntentCreated(intent, intentHash);
    }

    /**
     * @notice Separate function to emit the IntentCreated event
     * @dev This helps avoid stack-too-deep errors in the calling function
     * @param intent The intent being created
     * @param intentHash Hash of the intent
     */
    function _emitIntentCreated(
        Intent calldata intent,
        bytes32 intentHash
    ) internal {
        emit UniversalIntentCreated(
            intentHash,
            intent.route.salt,
            intent.route.source,
            intent.route.destination,
            intent.route.inbox,
            intent.route.tokens,
            intent.route.calls,
            intent.reward.creator.toAddress(),
            intent.reward.prover.toAddress(),
            intent.reward.deadline,
            intent.reward.nativeValue,
            intent.reward.tokens
        );
    }

    /**
     * @notice Disabling fundFor for native intents
     * @dev Deploying vault in Fund mode might cause a loss of native reward
     * @param nativeValue Amount of native tokens in the intent reward
     * @param vault Address of the intent vault
     * @param intentHash Hash of the intent
     */
    function _disableNativeReward(
        uint256 nativeValue,
        address vault,
        bytes32 intentHash
    ) internal view {
        // selfdestruct() will refund all native tokens to the creator
        // we can't use Fund mode for intents with native value
        // because deploying and destructing the vault will refund the native reward prematurely
        if (nativeValue > 0 && vault.balance > 0) {
            revert CannotFundForWithNativeReward(intentHash);
        }
    }

    /**
     * @notice Validates the initial funding state
     * @param state Current vault state
     * @param intentHash Hash of the intent
     */
    function _validateInitialFundingState(
        VaultState memory state,
        bytes32 intentHash
    ) internal pure {
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
    ) internal pure {
        if (
            state.status != uint8(RewardStatus.Initial) &&
            state.status != uint8(RewardStatus.PartiallyFunded)
        ) {
            revert IntentAlreadyFunded(intentHash);
        }
    }

    /**
     * @notice Handles the funding of an intent
     * @param intentHash Hash of the intent
     * @param reward Reward structure to fund
     * @param vault Address of the intent vault
     * @param funder Address providing the funds
     * @param allowPartial Whether to allow partial funding
     */
    function _fundIntent(
        bytes32 intentHash,
        Reward calldata reward,
        address vault,
        address funder,
        bool allowPartial
    ) internal {
        bool partiallyFunded;

        if (reward.nativeValue > 0) {
            uint256 vaultBalance = vault.balance;

            if (vaultBalance < reward.nativeValue) {
                uint256 remainingAmount = reward.nativeValue - vaultBalance;
                uint256 transferAmount;

                if (msg.value >= remainingAmount) {
                    transferAmount = remainingAmount;
                } else if (allowPartial) {
                    transferAmount = msg.value;
                    partiallyFunded = true;
                } else {
                    revert InsufficientNativeReward(intentHash);
                }

                payable(vault).transfer(transferAmount);
            }
        }

        uint256 rewardsLength = reward.tokens.length;

        // Iterate through each token in the reward structure
        for (uint256 i; i < rewardsLength; ++i) {
            // Get token address and required amount for current reward
            address token = reward.tokens[i].token.toAddress();
            uint256 amount = reward.tokens[i].amount;
            uint256 vaultBalance = IERC20(token).balanceOf(vault);

            // Only proceed if vault needs more tokens and we have permission to transfer them
            if (vaultBalance < amount) {
                // Calculate how many more tokens the vault needs to be fully funded
                uint256 remainingAmount = amount - vaultBalance;

                // Check how many tokens this contract is allowed to transfer from funding source
                uint256 allowance = IERC20(token).allowance(
                    funder,
                    address(this)
                );
                uint256 funderBalance = IERC20(token).balanceOf(funder);
                allowance = allowance < funderBalance
                    ? allowance
                    : funderBalance;

                uint256 transferAmount;
                // Calculate transfer amount as minimum of what's needed and what's allowed
                if (allowance >= remainingAmount) {
                    transferAmount = remainingAmount;
                } else if (allowPartial) {
                    transferAmount = allowance;
                    partiallyFunded = true;
                } else {
                    revert InsufficientTokenAllowance(
                        token,
                        funder,
                        remainingAmount
                    );
                }

                if (transferAmount > 0) {
                    // Transfer tokens from funding source to vault using safe transfer
                    IERC20(token).safeTransferFrom(
                        funder,
                        vault,
                        transferAmount
                    );
                }
            }
        }

        if (partiallyFunded) {
            emit IntentPartiallyFunded(intentHash, funder);
        } else {
            emit IntentFunded(intentHash, funder);
        }
    }

    /**
     * @notice Handles the funding of an intent for another address
     * @param state Current vault state
     * @param reward Reward structure to fund
     * @param intentHash Hash of the intent
     * @param routeHash Hash of the route component
     * @param vault Address of the intent vault
     * @param funder Address providing the funds
     * @param permitContact Address of the permitContact instance
     * @param allowPartial Whether to allow partial funding
     */
    function _fundIntentFor(
        VaultState memory state,
        Reward calldata reward,
        bytes32 intentHash,
        bytes32 routeHash,
        address vault,
        address funder,
        address permitContact,
        bool allowPartial
    ) internal {
        _disableNativeReward(reward.nativeValue, vault, intentHash);
        _validateFundingState(state, intentHash);

        if (state.status == uint8(RewardStatus.Initial)) {
            state.status = allowPartial
                ? uint8(RewardStatus.PartiallyFunded)
                : uint8(RewardStatus.Funded);
        }

        state.mode = uint8(VaultMode.Fund);
        state.allowPartialFunding = allowPartial ? 1 : 0;
        state.usePermit = permitContact != address(0) ? 1 : 0;
        state.target = funder;

        if (permitContact != address(0)) {
            vaults[intentHash].permitContract = permitContact;
        }

        vaults[intentHash].state = state;

        // Deploy Vault using assembly for better gas efficiency
        bytes memory bytecode = abi.encodePacked(
            type(Vault).creationCode,
            abi.encode(intentHash, reward)
        );

        address deployedVault;
        assembly {
            deployedVault := create2(0, add(bytecode, 0x20), mload(bytecode), routeHash)
            if iszero(extcodesize(deployedVault)) {
                revert(0, 0)
            }
        }

        if (state.status == uint8(RewardStatus.Funded)) {
            emit IntentFunded(intentHash, funder);
        } else if (
            state.status == uint8(RewardStatus.PartiallyFunded) &&
            _isRewardFunded(reward, vault) // Using the vault parameter, not deployedVault
        ) {
            state.status = uint8(RewardStatus.Funded);
            vaults[intentHash].state = state;

            emit IntentFunded(intentHash, funder);
        } else {
            emit IntentPartiallyFunded(intentHash, funder);
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
    ) internal view {
        if (sourceChain != block.chainid) {
            revert WrongSourceChain(intentHash);
        }
    }

    /**
     * @notice Returns excess ETH to the sender
     * @param intentHash Hash of the intent
     * @param amount Amount of ETH to return
     */
    function _returnExcessEth(bytes32 intentHash, uint256 amount) internal {
        if (amount > 0) {
            (bool success, ) = payable(msg.sender).call{value: amount}("");
            if (!success) revert NativeRewardTransferFailed(intentHash);
        }
    }
}