/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IProver} from "./interfaces/IProver.sol";
import {IIntentSource} from "./interfaces/IIntentSource.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IVaultStorage} from "./interfaces/IVaultStorage.sol";

import {Intent, Route, Reward} from "./types/Intent.sol";
import {AddressConverter} from "./libs/AddressConverter.sol";

import {OriginSettler} from "./ERC7683/OriginSettler.sol";
import {Vault} from "./Vault.sol";

/**
 * @title IntentSource
 * @notice Abstract contract for managing cross-chain intents and their associated rewards on the source chain
 * @dev Base contract containing all core intent functionality for EVM chains
 */
abstract contract IntentSource is OriginSettler, IVaultStorage, IIntentSource {
    using SafeERC20 for IERC20;
    using AddressConverter for address;

    // Shared state storage across all implementations
    mapping(bytes32 intentHash => VaultStorage) public vaults;

    /// @dev CREATE2 prefix for address calculation
    bytes1 private immutable CREATE2_PREFIX;

    constructor() {
        // TRON support
        if (block.chainid == 728126428 || block.chainid == 2494104990) {
            // TRON chain custom CREATE2 prefix
            CREATE2_PREFIX = hex"41";
        } else {
            // first byte of the classic CREATE2 prefix
            CREATE2_PREFIX = hex"ff";
        }
    }

    /**
     * @notice Retrieves reward status for a given intent hash
     * @param intentHash Hash of the intent to query
     * @return status Current status of the intent
     */
    function getRewardStatus(
        bytes32 intentHash
    ) external view virtual returns (RewardStatus status) {
        return RewardStatus(vaults[intentHash].state.status);
    }

    /**
     * @notice Retrieves vault state for a given intent hash
     * @param intentHash Hash of the intent to query
     * @return VaultState struct containing vault information
     */
    function getVaultState(
        bytes32 intentHash
    ) external view virtual returns (VaultState memory) {
        return vaults[intentHash].state;
    }

    /**
     * @notice Retrieves the permitContract address funding an intent
     */
    function getPermitContract(
        bytes32 intentHash
    ) external view virtual returns (address) {
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
        public
        pure
        virtual
        returns (bytes32 intentHash, bytes32 routeHash, bytes32 rewardHash)
    {
        return
            getIntentHash(
                intent.destination,
                abi.encode(intent.route),
                intent.reward
            );
    }

    /**
     * @notice Calculates the hash of an intent and its components
     * @param destination Destination chain ID for the intent
     * @param route Encoded route data for the intent as bytes for cross-VM compatibility
     * @param reward Reward structure containing distribution details
     * @return intentHash Combined hash of route and reward
     * @return routeHash Hash of the route component
     * @return rewardHash Hash of the reward component
     */
    function getIntentHash(
        uint64 destination,
        bytes memory route,
        Reward calldata reward
    )
        public
        pure
        virtual
        returns (bytes32 intentHash, bytes32 routeHash, bytes32 rewardHash)
    {
        routeHash = keccak256(route);
        rewardHash = keccak256(abi.encode(reward));
        intentHash = keccak256(
            abi.encodePacked(destination, routeHash, rewardHash)
        );
    }

    /**
     * @notice Calculates the deterministic address of the intent vault
     * @param intent Intent to calculate vault address for
     * @return Address of the intent vault
     */
    function intentVaultAddress(
        Intent calldata intent
    ) public view virtual returns (address) {
        return
            intentVaultAddress(
                intent.destination,
                abi.encode(intent.route),
                intent.reward
            );
    }

    /**
     * @notice Calculates the deterministic address of the intent vault
     * @param destination Destination chain ID for the intent
     * @param route Encoded route data for the intent as bytes
     * @param reward The reward structure containing distribution details
     * @return Address of the intent vault
     */
    function intentVaultAddress(
        uint64 destination,
        bytes memory route,
        Reward calldata reward
    )
        public
        view
        virtual
        override(IIntentSource, OriginSettler)
        returns (address)
    {
        (bytes32 intentHash, bytes32 routeHash, ) = getIntentHash(
            destination,
            route,
            reward
        );
        return _getIntentVaultAddress(intentHash, routeHash, reward);
    }

    /**
     * @notice Checks if an intent is completely funded
     * @param intent Intent to validate
     * @return True if intent is completely funded, false otherwise
     */
    function isIntentFunded(
        Intent calldata intent
    ) public view virtual returns (bool) {
        return
            isIntentFunded(
                intent.destination,
                abi.encode(intent.route),
                intent.reward
            );
    }

    /**
     * @notice Checks if an intent is fully funded using universal format
     * @param destination Destination chain ID for the intent
     * @param route Encoded route data for the intent as bytes
     * @param reward The reward structure containing distribution details
     * @return True if intent is completely funded, false otherwise
     */
    function isIntentFunded(
        uint64 destination,
        bytes memory route,
        Reward calldata reward
    )
        public
        view
        virtual
        override(IIntentSource, OriginSettler)
        returns (bool)
    {
        (bytes32 intentHash, bytes32 routeHash, ) = getIntentHash(
            destination,
            route,
            reward
        );
        address vault = _getIntentVaultAddress(intentHash, routeHash, reward);
        return _isRewardFunded(reward, vault);
    }

    /**
     * @notice Creates an intent without funding
     * @param intent The complete intent struct to be published
     * @return intentHash Hash of the created intent
     * @return vault Address of the created vault
     */
    function publish(
        Intent calldata intent
    ) public virtual returns (bytes32 intentHash, address vault) {
        return
            publish(
                intent.destination,
                abi.encode(intent.route),
                intent.reward
            );
    }

    /**
     * @notice Creates an intent without funding
     * @param destination Destination chain ID for the intent
     * @param route Encoded route data for the intent as bytes
     * @param reward The reward structure containing distribution details
     * @return intentHash Hash of the created intent
     * @return vault Address of the created vault
     */
    function publish(
        uint64 destination,
        bytes memory route,
        Reward calldata reward
    )
        public
        virtual
        override(IIntentSource, OriginSettler)
        returns (bytes32 intentHash, address vault)
    {
        bytes32 routeHash;
        (intentHash, routeHash, ) = getIntentHash(destination, route, reward);
        VaultState memory state = vaults[intentHash].state;

        _validatePublishState(intentHash, state);
        _emitIntentPublished(intentHash, destination, route, reward);

        vault = _getIntentVaultAddress(intentHash, routeHash, reward);
    }

    /**
     * @notice Creates and funds an intent in a single transaction
     * @param intent The complete intent struct to be published and funded
     * @param allowPartial Whether to allow partial funding
     * @return intentHash Hash of the created and funded intent
     * @return vault Address of the created vault
     */
    function publishAndFund(
        Intent calldata intent,
        bool allowPartial
    ) public payable virtual returns (bytes32 intentHash, address vault) {
        return
            publishAndFund(
                intent.destination,
                abi.encode(intent.route),
                intent.reward,
                allowPartial
            );
    }

    /**
     * @notice Creates and funds an intent in a single transaction
     * @param destination Destination chain ID for the intent
     * @param route Encoded route data for the intent as bytes
     * @param reward The reward structure containing distribution details
     * @param allowPartial Whether to allow partial funding
     * @return intentHash Hash of the created and funded intent
     * @return vault Address of the created vault
     */
    function publishAndFund(
        uint64 destination,
        bytes memory route,
        Reward calldata reward,
        bool allowPartial
    ) public payable virtual returns (bytes32 intentHash, address vault) {
        bytes32 routeHash;
        (intentHash, routeHash, ) = getIntentHash(destination, route, reward);
        VaultState memory state = vaults[intentHash].state;

        _validateInitialFundingState(state, intentHash);
        _validateSourceChain(block.chainid, intentHash);
        _validatePublishState(intentHash, state);
        _emitIntentPublished(intentHash, destination, route, reward);

        vault = _getIntentVaultAddress(intentHash, routeHash, reward);
        _fundIntent(intentHash, reward, vault, msg.sender, allowPartial);

        _returnExcessEth(intentHash, address(this).balance);
    }

    /**
     * @notice Funds an existing intent
     * @param destination Destination chain ID for the intent
     * @param routeHash Hash of the route component
     * @param reward Reward structure containing distribution details
     * @param allowPartial Whether to allow partial funding
     * @return intentHash Hash of the funded intent
     */
    function fund(
        uint64 destination,
        bytes32 routeHash,
        Reward calldata reward,
        bool allowPartial
    ) external payable virtual returns (bytes32 intentHash) {
        bytes32 rewardHash = keccak256(abi.encode(reward));
        intentHash = keccak256(
            abi.encodePacked(destination, routeHash, rewardHash)
        );
        VaultState memory state = vaults[intentHash].state;

        _validateInitialFundingState(state, intentHash);

        address vault = _getIntentVaultAddress(intentHash, routeHash, reward);
        _fundIntent(intentHash, reward, vault, msg.sender, allowPartial);

        _returnExcessEth(intentHash, address(this).balance);
    }

    /**
     * @notice Funds an intent for a user with permit/allowance
     * @param destination Destination chain ID for the intent
     * @param routeHash Hash of the route component
     * @param reward Reward structure containing distribution details
     * @param funder Address to fund the intent from
     * @param permitContract Address of the permitContract instance
     * @param allowPartial Whether to allow partial funding
     * @return intentHash Hash of the funded intent
     */
    function fundFor(
        uint64 destination,
        bytes32 routeHash,
        Reward calldata reward,
        address funder,
        address permitContract,
        bool allowPartial
    ) external virtual returns (bytes32 intentHash) {
        bytes32 rewardHash = keccak256(abi.encode(reward));
        intentHash = keccak256(
            abi.encodePacked(destination, routeHash, rewardHash)
        );
        VaultState memory state = vaults[intentHash].state;

        address vault = _getIntentVaultAddress(intentHash, routeHash, reward);

        _fundIntentFor(
            state,
            reward,
            intentHash,
            routeHash,
            vault,
            funder,
            permitContract,
            allowPartial
        );
    }

    /**
     * @notice Creates and funds an intent using permit/allowance
     * @param intent The complete intent struct
     * @param funder Address to fund the intent from
     * @param permitContract Address of the permitContract instance
     * @param allowPartial Whether to allow partial funding
     * @return intentHash Hash of the created and funded intent
     */
    function publishAndFundFor(
        Intent calldata intent,
        address funder,
        address permitContract,
        bool allowPartial
    ) public virtual returns (bytes32 intentHash, address vault) {
        return
            publishAndFundFor(
                intent.destination,
                abi.encode(intent.route),
                intent.reward,
                funder,
                permitContract,
                allowPartial
            );
    }

    /**
     * @notice Creates and funds an intent on behalf of another address using universal format
     * @param destination Destination chain ID for the intent
     * @param route Encoded route data for the intent as bytes
     * @param reward The reward structure containing distribution details
     * @param funder The address providing the funding
     * @param permitContract The permit contract for token approvals
     * @param allowPartial Whether to accept partial funding
     * @return intentHash Hash of the created and funded intent
     * @return vault Address of the created vault
     */
    function publishAndFundFor(
        uint64 destination,
        bytes memory route,
        Reward calldata reward,
        address funder,
        address permitContract,
        bool allowPartial
    ) public virtual returns (bytes32 intentHash, address vault) {
        bytes32 routeHash;
        (intentHash, routeHash, ) = getIntentHash(destination, route, reward);
        VaultState memory state = vaults[intentHash].state;

        _validatePublishState(intentHash, state);
        _emitIntentPublished(intentHash, destination, route, reward);
        _validateSourceChain(block.chainid, intentHash);

        vault = _getIntentVaultAddress(intentHash, routeHash, reward);

        _fundIntentFor(
            state,
            reward,
            intentHash,
            routeHash,
            vault,
            funder,
            permitContract,
            allowPartial
        );

        return (intentHash, vault);
    }

    /**
     * @notice Withdraws rewards associated with an intent to its claimant
     * @param destination Destination chain ID for the intent
     * @param routeHash Hash of the intent's route
     * @param reward Reward structure of the intent
     */
    function withdraw(
        uint64 destination,
        bytes32 routeHash,
        Reward calldata reward
    ) public virtual {
        bytes32 rewardHash = keccak256(abi.encode(reward));
        bytes32 intentHash = keccak256(
            abi.encodePacked(destination, routeHash, rewardHash)
        );

        IProver.ProofData memory proof = IProver(reward.prover).provenIntents(
            intentHash
        );
        address claimant = proof.claimant;
        VaultState memory state = vaults[intentHash].state;

        // If the intent has been proven on a different chain, challenge the proof
        if (proof.destination != destination && claimant != address(0)) {
            // Challenge the proof and emit event
            IProver(reward.prover).challengeIntentProof(
                destination,
                routeHash,
                rewardHash
            );
            emit IntentProofChallenged(intentHash);
            return;
        }

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

            // Try to create vault, ignore if it already exists
            try new Vault{salt: routeHash}(intentHash, reward) {
                // Vault created successfully
            } catch {
                // Vault already exists or creation failed, ignore
            }

            return;
        }

        // If no proof exists and intent has expired, try to refund
        if (claimant == address(0) && block.timestamp >= reward.deadline) {
            if (
                state.status != uint8(RewardStatus.Claimed) &&
                state.status != uint8(RewardStatus.Refunded) &&
                (state.status == uint8(RewardStatus.Funded) ||
                    state.status == uint8(RewardStatus.PartiallyFunded))
            ) {
                state.status = uint8(RewardStatus.Refunded);
                state.mode = uint8(VaultMode.Refund);
                state.allowPartialFunding = 0;
                state.usePermit = 0;
                state.target = address(0);
                vaults[intentHash].state = state;

                emit IntentRefunded(intentHash, reward.creator);

                // Try to create vault, ignore if it already exists
                try new Vault{salt: routeHash}(intentHash, reward) {
                    // Vault created successfully
                } catch {
                    // Vault already exists or creation failed, ignore
                }

                return;
            }
        }

        if (claimant == address(0)) {
            revert UnauthorizedWithdrawal(intentHash);
        } else {
            revert RewardsAlreadyWithdrawn(intentHash);
        }
    }

    /**
     * @notice Batch withdraws multiple intents
     * @param destinations Array of destination chain IDs for the intents
     * @param routeHashes Array of route hashes for the intents
     * @param rewards Array of reward structures for the intents
     */
    function batchWithdraw(
        uint64[] calldata destinations,
        bytes32[] calldata routeHashes,
        Reward[] calldata rewards
    ) external virtual {
        uint256 length = routeHashes.length;

        if (length != rewards.length || length != destinations.length) {
            revert ArrayLengthMismatch();
        }

        for (uint256 i = 0; i < length; ++i) {
            withdraw(destinations[i], routeHashes[i], rewards[i]);
        }
    }

    /**
     * @notice Refunds rewards to the intent creator
     * @param destination Destination chain ID for the intent
     * @param routeHash Hash of the intent's route
     * @param reward Reward structure of the intent
     */
    function refund(
        uint64 destination,
        bytes32 routeHash,
        Reward calldata reward
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
            IProver.ProofData memory proof = IProver(reward.prover)
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
            state.mode = uint8(VaultMode.Refund);
            state.allowPartialFunding = 0;
            state.usePermit = 0;
            state.target = address(0);
            vaults[intentHash].state = state;

            emit IntentRefunded(intentHash, reward.creator);

            // Try to create vault, ignore if it already exists
            try new Vault{salt: routeHash}(intentHash, reward) {
                // Vault created successfully
            } catch {
                // Vault already exists or creation failed, ignore
            }
        } else {
            // Intent was already claimed, just emit the refund event without creating a vault
            emit IntentRefunded(intentHash, reward.creator);
        }
    }

    /**
     * @notice Recover tokens that were sent to the intent vault by mistake
     * @dev Must not be among the intent's rewards
     * @param destination Destination chain ID for the intent
     * @param routeHash Hash of the intent's route
     * @param reward Reward structure of the intent
     * @param token Token address for handling incorrect vault transfers
     */
    function recoverToken(
        uint64 destination,
        bytes32 routeHash,
        Reward calldata reward,
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
            if (reward.tokens[i].token == token) {
                revert InvalidRefundToken();
            }
        }

        state.mode = uint8(VaultMode.RecoverToken);
        state.allowPartialFunding = 0;
        state.usePermit = 0;
        state.target = token;
        vaults[intentHash].state = state;

        emit IntentRefunded(intentHash, reward.creator);

        // Try to create vault, ignore if it already exists
        try new Vault{salt: routeHash}(intentHash, reward) {
            // Vault created successfully
        } catch {
            // Vault already exists or creation failed, ignore
        }
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
    ) internal view virtual returns (address) {
        /* Convert a hash which is bytes32 to an address which is 20-byte long
        according to https://docs.soliditylang.org/en/v0.8.9/control-structures.html?highlight=create2#salted-contract-creations-create2 */
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                CREATE2_PREFIX,
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
     * @notice Separate function to emit the IntentPublished event
     * @dev This helps avoid stack-too-deep errors in the calling function
     * @param intentHash Hash of the intent
     * @param destination Destination chain ID
     * @param route Encoded route data
     * @param reward Reward specification
     */
    function _emitIntentPublished(
        bytes32 intentHash,
        uint64 destination,
        bytes memory route,
        Reward calldata reward
    ) internal virtual {
        emit IntentPublished(
            intentHash,
            destination,
            reward.creator,
            reward.prover,
            reward.deadline,
            reward.nativeValue,
            reward.tokens,
            route
        );
    }

    /**
     * @notice Handles the funding of an intent
     * @param intentHash Hash of the intent
     * @param reward Reward structure to fund
     * @param vault Address of the intent vault
     * @param funder Address providing the funds
     */
    function _fundIntent(
        bytes32 intentHash,
        Reward calldata reward,
        address vault,
        address funder,
        bool allowPartial
    ) internal virtual {
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
            address token = reward.tokens[i].token;
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

        // Update vault state based on funding result
        VaultState memory state = vaults[intentHash].state;

        if (partiallyFunded) {
            state.status = uint8(RewardStatus.PartiallyFunded);
            emit IntentFunded(intentHash, funder, false);
        } else {
            state.status = uint8(RewardStatus.Funded);
            emit IntentFunded(intentHash, funder, true);
        }

        vaults[intentHash].state = state;
    }

    /**
     * @notice Funds an intent using a permit contract
     */
    function _fundIntentFor(
        VaultState memory state,
        Reward calldata reward,
        bytes32 intentHash,
        bytes32 routeHash,
        address vault,
        address funder,
        address permitContract,
        bool allowPartial
    ) internal virtual {
        _disableNativeReward(reward, vault, intentHash);
        _validateFundingState(state, intentHash);

        if (state.status == uint8(RewardStatus.Initial)) {
            state.status = allowPartial
                ? uint8(RewardStatus.PartiallyFunded)
                : uint8(RewardStatus.Funded);
        }

        state.mode = uint8(VaultMode.Fund);
        state.allowPartialFunding = allowPartial ? 1 : 0;
        state.usePermit = permitContract != address(0) ? 1 : 0;
        state.target = funder;

        if (permitContract != address(0)) {
            vaults[intentHash].permitContract = permitContract;
        }

        vaults[intentHash].state = state;

        // Create vault
        new Vault{salt: routeHash}(intentHash, reward);

        // Check if funding was successful and emit appropriate events
        if (state.status == uint8(RewardStatus.Funded)) {
            if (vault.balance < reward.nativeValue) {
                revert InsufficientNativeReward(intentHash);
            }
            emit IntentFunded(intentHash, funder, true);
        } else if (
            state.status == uint8(RewardStatus.PartiallyFunded) &&
            _isRewardFunded(reward, vault)
        ) {
            state.status = uint8(RewardStatus.Funded);
            vaults[intentHash].state = state;

            emit IntentFunded(intentHash, funder, true);
        } else {
            emit IntentFunded(intentHash, funder, false);
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
            state.status != uint8(RewardStatus.PartiallyFunded) &&
            state.status != uint8(RewardStatus.Funded)
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
