/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IProver} from "./interfaces/IProver.sol";
import {IUniversalIntentSource} from "./interfaces/IUniversalIntentSource.sol";

import {Intent, Route, Call, TokenAmount, Reward} from "./types/UniversalIntent.sol";
import {AddressConverter} from "./libs/AddressConverter.sol";

import {Vault} from "./Vault.sol";
import {IntentSource} from "./IntentSource.sol";

/**
 * @title UniversalSource
 * @notice Implementation of Universal Intent Source interface using bytes32 types for cross-chain compatibility
 * @dev Extends EvmSource to add cross-chain intent functionality
 */
abstract contract UniversalSource is IntentSource, IUniversalIntentSource {
    using SafeERC20 for IERC20;
    using AddressConverter for bytes32;
    using AddressConverter for address;

    // Event UniversalIntentPublished is defined in IUniversalIntentSource interface

    /**
     * @notice Calculates the hash of an intent and its components
     * @param intent The intent to hash
     * @param routeHash Hash of the route component
     * @return intentHash Combined hash of route and reward
     */
    function getIntentHash(
        Intent calldata intent,
        bytes32 routeHash
    ) public pure virtual returns (bytes32 intentHash) {
        bytes32 rewardHash = keccak256(abi.encode(intent.reward));
        intentHash = keccak256(
            abi.encodePacked(intent.destination, routeHash, rewardHash)
        );
    }

    /**
     * @notice Calculates the deterministic address of the intent vault
     * @param intent Intent to calculate vault address for
     * @return Address of the intent vault
     */
    function intentVaultAddress(
        Intent calldata intent,
        bytes32 routeHash
    ) external view virtual returns (address) {
        bytes32 intentHash = getIntentHash(intent, routeHash);

        // Direct calculation for Vault address using CREATE2
        return _getUniversalVaultAddress(intentHash, routeHash, intent.reward);
    }

    /**
     * @notice Creates an intent without funding
     * @param intent The complete intent struct to be published
     * @param routeHash The hash of the route component (pre-calculated)
     * @return intentHash Hash of the created intent
     * @return vault Address of the created vault
     */
    function publish(
        Intent calldata intent,
        bytes32 routeHash
    ) external virtual returns (bytes32 intentHash, address vault) {
        intentHash = getIntentHash(intent, routeHash);
        VaultState memory state = vaults[intentHash].state;

        _validatePublishState(intentHash, state);
        _emitIntentPublished(intent, intentHash, routeHash);

        vault = _getUniversalVaultAddress(intentHash, routeHash, intent.reward);
        return (intentHash, vault);
    }

    /**
     * @notice Creates and funds an intent in a single transaction
     * @param intent The complete intent struct to be published and funded
     * @param routeHash The hash of the route component (pre-calculated)
     * @param allowPartial Whether to allow partial funding
     * @return intentHash Hash of the created and funded intent
     * @return vault Address of the created vault
     */
    function publishAndFund(
        Intent calldata intent,
        bytes32 routeHash,
        bool allowPartial
    ) external payable virtual returns (bytes32 intentHash, address vault) {
        bytes32 rewardHash = keccak256(abi.encode(intent.reward));
        intentHash = keccak256(
            abi.encodePacked(intent.destination, routeHash, rewardHash)
        );
        VaultState memory state = vaults[intentHash].state;

        _validateInitialFundingState(state, intentHash);
        _validateSourceChain(block.chainid, intentHash);
        _validatePublishState(intentHash, state);
        _emitIntentPublished(intent, intentHash, routeHash);

        vault = _getUniversalVaultAddress(intentHash, routeHash, intent.reward);
        _fundUniversalIntent(
            intentHash,
            intent.reward,
            vault,
            msg.sender,
            allowPartial
        );

        _returnExcessEth(intentHash, address(this).balance);

        return (intentHash, vault);
    }

    /**
     * @notice Creates and funds an intent using permit/allowance
     * @param intent The complete intent struct
     * @param routeHash The hash of the route component (pre-calculated)
     * @param funder Address to fund the intent from
     * @param permitContact Address of the permitContact instance
     * @param allowPartial Whether to allow partial funding
     * @return intentHash Hash of the created and funded intent
     * @return vault Address of the created vault
     */
    function publishAndFundFor(
        Intent calldata intent,
        bytes32 routeHash,
        address funder,
        address permitContact,
        bool allowPartial
    ) external virtual returns (bytes32 intentHash, address vault) {
        bytes32 rewardHash = keccak256(abi.encode(intent.reward));
        intentHash = keccak256(
            abi.encodePacked(intent.destination, routeHash, rewardHash)
        );
        VaultState memory state = vaults[intentHash].state;

        _validatePublishState(intentHash, state);
        _emitIntentPublished(intent, intentHash, routeHash);
        _validateSourceChain(block.chainid, intentHash);

        vault = _getUniversalVaultAddress(intentHash, routeHash, intent.reward);

        _fundUniversalIntentFor(
            state,
            intent.reward,
            intentHash,
            routeHash,
            vault,
            funder,
            permitContact,
            allowPartial
        );

        return (intentHash, vault);
    }

    /**
     * @notice Checks if an intent is completely funded
     * @param intent Intent to validate
     * @return True if intent is completely funded, false otherwise
     */
    function isIntentFunded(
        Intent calldata intent
    ) external view virtual returns (bool) {
        // Source chain validation is implicit since intents are created on the source chain
        // The following check is not needed with the new structure

        bytes32 routeHash = keccak256(abi.encode(intent.route));
        bytes32 intentHash = getIntentHash(intent, routeHash);

        address vault = _getUniversalVaultAddress(
            intentHash,
            routeHash,
            intent.reward
        );
        return _isUniversalRewardFunded(intent.reward, vault);
    }

    /**
     * @notice Funds an existing universal intent
     * @param destination Destination chain ID for the intent
     * @param reward The reward specification
     * @param routeHash The hash of the intent's route component
     * @param allowPartial Whether to allow partial funding
     * @return intentHash The hash of the funded intent
     */
    function fund(
        uint64 destination,
        Reward calldata reward,
        bytes32 routeHash,
        bool allowPartial
    ) external payable virtual returns (bytes32 intentHash) {
        bytes32 rewardHash = keccak256(abi.encode(reward));
        intentHash = keccak256(
            abi.encodePacked(destination, routeHash, rewardHash)
        );
        VaultState memory state = vaults[intentHash].state;

        _validateInitialFundingState(state, intentHash);

        address vault = _getUniversalVaultAddress(
            intentHash,
            routeHash,
            reward
        );
        _fundUniversalIntent(
            intentHash,
            reward,
            vault,
            msg.sender,
            allowPartial
        );

        _returnExcessEth(intentHash, address(this).balance);

        return intentHash;
    }

    /**
     * @notice Funds a universal intent on behalf of another address using permit
     * @param destination Destination chain ID for the intent
     * @param reward The universal reward specification
     * @param routeHash The hash of the intent's route component
     * @param fundingAddress The address providing the funding
     * @param permitContract The permit contract for external token approvals
     * @param allowPartial Whether to accept partial funding
     * @return intentHash The hash of the funded intent
     */
    function fundFor(
        uint64 destination,
        Reward calldata reward,
        bytes32 routeHash,
        address fundingAddress,
        address permitContract,
        bool allowPartial
    ) external virtual returns (bytes32 intentHash) {
        bytes32 rewardHash = keccak256(abi.encode(reward));
        intentHash = keccak256(
            abi.encodePacked(destination, routeHash, rewardHash)
        );
        VaultState memory state = vaults[intentHash].state;

        address vault = _getUniversalVaultAddress(
            intentHash,
            routeHash,
            reward
        );

        _fundUniversalIntentFor(
            state,
            reward,
            intentHash,
            routeHash,
            vault,
            fundingAddress,
            permitContract,
            allowPartial
        );

        return intentHash;
    }

    /**
     * @notice Claims rewards for a successfully fulfilled and proven universal intent
     * @param destination Destination chain ID for the intent
     * @param reward The universal reward specification
     * @param routeHash The hash of the intent's route component
     */
    function withdraw(
        uint64 destination,
        Reward calldata reward,
        bytes32 routeHash
    ) external virtual {
        bytes32 rewardHash = keccak256(abi.encode(reward));
        bytes32 intentHash = keccak256(
            abi.encodePacked(destination, routeHash, rewardHash)
        );

        IProver.ProofData memory proof = IProver(reward.prover.toAddress())
            .provenIntents(intentHash);
        address claimant = proof.claimant;
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

            emit IntentWithdrawn(intentHash, claimant);

            // Use assembly to deploy Vault with the original reward struct
            bytes memory code = type(Vault).creationCode;
            bytes memory initCode = abi.encodePacked(
                code,
                abi.encode(intentHash, reward)
            );

            address vaultAddress;
            assembly {
                vaultAddress := create2(
                    0,
                    add(initCode, 0x20),
                    mload(initCode),
                    routeHash
                )
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
     * @notice Claims rewards for multiple fulfilled and proven universal intents
     * @param destinations Array of destination chain IDs for the intents
     * @param rewards Array of corresponding universal reward specifications
     * @param routeHashes Array of route component hashes
     */
    function batchWithdraw(
        uint64[] calldata destinations,
        Reward[] calldata rewards,
        bytes32[] calldata routeHashes
    ) external virtual {
        uint256 length = routeHashes.length;

        if (length != rewards.length || length != destinations.length) {
            revert ArrayLengthMismatch();
        }

        for (uint256 i = 0; i < length; ++i) {
            this.withdraw(destinations[i], rewards[i], routeHashes[i]);
        }
    }

    /**
     * @notice Returns rewards to the universal intent creator
     * @param destination Destination chain ID for the intent
     * @param reward The universal reward specification
     * @param routeHash The hash of the intent's route component
     */
    function refund(
        uint64 destination,
        Reward calldata reward,
        bytes32 routeHash
    ) external virtual {
        bytes32 rewardHash = keccak256(abi.encode(reward));
        bytes32 intentHash = keccak256(
            abi.encodePacked(destination, routeHash, rewardHash)
        );

        VaultState memory state = vaults[intentHash].state;

        if (
            state.status != uint8(RewardStatus.Claimed) &&
            state.status != uint8(RewardStatus.Refunded)
        ) {
            IProver.ProofData memory proof = IProver(reward.prover.toAddress())
                .provenIntents(intentHash);
            address claimant = proof.claimant;
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

        emit IntentRefunded(intentHash, reward.creator.toAddress());

        // Use assembly to deploy Vault with the original reward struct
        bytes memory code = type(Vault).creationCode;
        bytes memory initCode = abi.encodePacked(
            code,
            abi.encode(intentHash, reward)
        );

        address vaultAddress;
        assembly {
            vaultAddress := create2(
                0,
                add(initCode, 0x20),
                mload(initCode),
                routeHash
            )
        }
    }

    /**
     * @notice Recovers mistakenly transferred tokens from the universal intent vault
     * @dev Token must not be part of the intent's reward structure
     * @param destination Destination chain ID for the intent
     * @param reward The universal reward specification
     * @param routeHash The hash of the intent's route component
     * @param token The token address to recover
     */
    function recoverToken(
        uint64 destination,
        Reward calldata reward,
        bytes32 routeHash,
        address token
    ) external virtual {
        if (token == address(0)) {
            revert InvalidRefundToken();
        }

        bytes32 rewardHash = keccak256(abi.encode(reward));
        bytes32 intentHash = keccak256(
            abi.encodePacked(destination, routeHash, rewardHash)
        );

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

        emit IntentRefunded(intentHash, reward.creator.toAddress());

        // Use assembly to deploy Vault with the original reward struct
        bytes memory code = type(Vault).creationCode;
        bytes memory initCode = abi.encodePacked(
            code,
            abi.encode(intentHash, reward)
        );

        address vaultAddress;
        assembly {
            vaultAddress := create2(
                0,
                add(initCode, 0x20),
                mload(initCode),
                routeHash
            )
        }
    }

    /**
     * @notice Separate function to emit the UniversalIntentPublished event
     * @dev This helps avoid stack-too-deep errors in the calling function
     * @param intent The intent being created
     * @param intentHash Hash of the intent
     */
    function _emitIntentPublished(
        Intent calldata intent,
        bytes32 intentHash,
        bytes32 routeHash
    ) internal virtual {
        emit IntentPublished(
            intentHash,
            routeHash,
            intent.destination,
            intent.route.salt,
            intent.route.deadline,
            intent.route.portal,
            intent.route.tokens,
            intent.route.calls,
            intent.reward.creator,
            intent.reward.prover,
            intent.reward.deadline,
            intent.reward.nativeValue,
            intent.reward.tokens
        );
    }

    /**
     * @notice Checks if a Universal reward is fully funded
     * @param reward Universal reward structure
     * @param vault Vault address
     * @return True if the reward is fully funded
     */
    function _isUniversalRewardFunded(
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

    /* Removed ERC20Reward conversion function as we'll use original types */

    /**
     * @notice Calculates the deterministic address of an intent vault using CREATE2
     * @dev Follows EIP-1014 for address calculation
     * @param intentHash Hash of the full intent
     * @param routeHash Hash of the route component
     * @param reward Universal reward structure
     * @return The calculated vault address
     */
    function _getUniversalVaultAddress(
        bytes32 intentHash,
        bytes32 routeHash,
        Reward calldata reward
    ) internal view returns (address) {
        /* Direct calculation of vault address using CREATE2
           Since abi encode of bytes32 is the same as address for the vault calculation,
           we can use the universal reward directly */
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
     * @notice Handles the funding of an intent
     * @param intentHash Hash of the intent
     * @param reward Universal reward structure
     * @param vault Address of the intent vault
     * @param funder Address providing the funds
     */
    function _fundUniversalIntent(
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

        emit IntentFunded(intentHash, funder, !partiallyFunded);
    }

    /**
     * @notice Funds an intent using a permit contract
     */
    function _fundUniversalIntentFor(
        VaultState memory state,
        Reward calldata reward,
        bytes32 intentHash,
        bytes32 routeHash,
        address vault,
        address funder,
        address permitContact,
        bool allowPartial
    ) internal {
        // Check if native reward is enabled
        if (reward.nativeValue > 0 && vault.balance > 0) {
            revert CannotFundForWithNativeReward(intentHash);
        }

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

        // Use assembly to deploy Vault with the original reward struct
        // This will ensure that the abi encoding is consistent
        bytes memory code = type(Vault).creationCode;
        bytes memory initCode = abi.encodePacked(
            code,
            abi.encode(intentHash, reward)
        );

        address vaultAddress;
        assembly {
            vaultAddress := create2(
                0,
                add(initCode, 0x20),
                mload(initCode),
                routeHash
            )
        }

        // Check if vault creation succeeded (has code) or if it's a valid self-destructed vault
        if (vaultAddress == address(0)) {
            // CREATE2 failed completely
            revert VaultCreationFailed(intentHash);
        }

        // Additional check for permit contracts - verify tokens were transferred
        if (permitContact != address(0)) {
            // Check if the intent is actually funded after vault creation
            if (!_isUniversalRewardFunded(reward, vault)) {
                // Vault creation succeeded but funding failed
                // Reset state and revert
                state.status = uint8(RewardStatus.Initial);
                state.mode = uint8(VaultMode.Fund);
                state.allowPartialFunding = 0;
                state.usePermit = 0;
                state.target = address(0);
                vaults[intentHash].state = state;
                delete vaults[intentHash].permitContract;

                revert InsufficientTokenAllowance(address(0), funder, 0);
            }
        }

        if (state.status == uint8(RewardStatus.Funded)) {
            emit IntentFunded(intentHash, funder, true);
        } else if (
            state.status == uint8(RewardStatus.PartiallyFunded) &&
            _isUniversalRewardFunded(reward, vault)
        ) {
            state.status = uint8(RewardStatus.Funded);
            vaults[intentHash].state = state;

            emit IntentFunded(intentHash, funder, true);
        } else {
            emit IntentFunded(intentHash, funder, false);
        }
    }
}
