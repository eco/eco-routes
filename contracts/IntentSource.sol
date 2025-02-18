/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IIntentSource} from "./interfaces/IIntentSource.sol";
import {BaseProver} from "./prover/BaseProver.sol";
import {Intent, Route, Reward, Call} from "./types/Intent.sol";
import {Semver} from "./libs/Semver.sol";

import {IntentVault} from "./IntentVault.sol";

/**
 * @notice Source chain contract for the Eco Protocol's intent system
 * @dev Used to create intents and withdraw associated rewards. Works in conjunction with
 *      an inbox contract on the destination chain. Verifies intent fulfillment through
 *      a prover contract on the source chain
 * @dev This contract should not hold any funds or hold any roles for other contracts,
 *      as it executes arbitrary calls to other contracts when funding intents.
 */
contract IntentSource is IIntentSource, Semver {
    using SafeERC20 for IERC20;

    mapping(bytes32 intentHash => VaultStorage) public vaults;

    constructor() {}

    /**
     * @notice Retrieves claim state for a given intent hash
     * @param intentHash Hash of the intent to query
     * @return status Current status of the intent
     */
    function getRewardStatus(
        bytes32 intentHash
    ) external view returns (RewardStatus status) {
        return RewardStatus(vaults[intentHash].state.status);
    }

    /**
     * @notice Retrieves vault state for a given intent hash
     * @param intentHash Hash of the intent to query
     * @return VaultState struct containing vault information
     */
    function getVaultState(
        bytes32 intentHash
    ) external view returns (VaultState memory) {
        return vaults[intentHash].state;
    }

    /**
     * @notice Retrieves the permit2 address funding an intent
     */
    function getPermit2(bytes32 intentHash) external view returns (address) {
        return vaults[intentHash].permit2;
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
    ) external view returns (address) {
        (bytes32 intentHash, bytes32 routeHash, ) = getIntentHash(intent);
        return _getIntentVaultAddress(intentHash, routeHash, intent.reward);
    }

    /**
     * @notice Funds an intent with native tokens and ERC20 tokens
     * @dev Security: this allows to call any contract from the IntentSource,
     *      which can impose a risk if anything relies on IntentSource to be msg.sender
     * @param routeHash Hash of the route component
     * @param reward Reward structure containing distribution details
     * @param fundingAddress Address to fund the intent from
     * @param permit2 Address of the permit2 instance to approve token transfers
     * @param allowPartial Whether to allow partial funding or not
     * @return intentHash Hash of the funded intent
     */
    function fundIntent(
        bytes32 routeHash,
        Reward calldata reward,
        address fundingAddress,
        address permit2,
        bool allowPartial
    ) external returns (bytes32 intentHash) {
        bytes32 rewardHash = keccak256(abi.encode(reward));
        intentHash = keccak256(abi.encodePacked(routeHash, rewardHash));
        address vault = _getIntentVaultAddress(intentHash, routeHash, reward);

        if (reward.nativeValue > 0 && vault.balance > 0) {
            revert CannotFundNativeReward(intentHash);
        }

        emit IntentFunded(intentHash, fundingAddress);

        VaultState memory state = vaults[intentHash].state;

        if (
            state.status != uint8(RewardStatus.Initial) &&
            state.status != uint8(RewardStatus.PartiallyFunded)
        ) {
            revert IntentAlreadyFunded(intentHash);
        }

        if (state.status == uint8(RewardStatus.Initial)) {
            state.status = allowPartial
                ? uint8(RewardStatus.PartiallyFunded)
                : uint8(RewardStatus.Funded);
        }

        state.mode = uint8(VaultMode.Fund);
        state.allowPartialFunding = allowPartial ? 1 : 0;
        state.isPermit2 = permit2 != address(0) ? 1 : 0;
        state.target = fundingAddress;

        if (permit2 != address(0)) {
            vaults[intentHash].permit2 = permit2;
        }

        vaults[intentHash].state = state;

        new IntentVault{salt: routeHash}(intentHash, reward);

        if (
            state.status == uint8(RewardStatus.PartiallyFunded) &&
            _isRewardFunded(reward, vault)
        ) {
            state.status = uint8(RewardStatus.Funded);
            vaults[intentHash].state = state;

            emit IntentFunded(intentHash, fundingAddress);
        } else {
            emit IntentPartiallyFunded(intentHash, fundingAddress);
        }
    }

    /**
     * @notice Creates an intent to execute instructions on a supported chain in exchange for assets
     * @dev If source chain proof isn't completed by expiry, rewards aren't redeemable regardless of execution.
     *      Solver must manage timing considerations (e.g., L1 data posting delays)
     * @param intent The intent struct containing all parameters
     * @param fund Whether to fund the reward or not
     * @return intentHash The hash of the created intent
     */
    function publishIntent(
        Intent calldata intent,
        bool fund
    ) external payable returns (bytes32 intentHash) {
        Route calldata route = intent.route;
        Reward calldata reward = intent.reward;

        uint256 rewardsLength = reward.tokens.length;
        bytes32 routeHash;

        (intentHash, routeHash, ) = getIntentHash(intent);

        VaultState memory state = vaults[intentHash].state;

        if (
            state.status == uint8(RewardStatus.Claimed) ||
            state.status == uint8(RewardStatus.Refunded)
        ) {
            revert IntentAlreadyExists(intentHash);
        }

        emit IntentCreated(
            intentHash,
            route.salt,
            route.source,
            route.destination,
            route.inbox,
            route.tokens,
            route.calls,
            reward.creator,
            reward.prover,
            reward.deadline,
            reward.nativeValue,
            reward.tokens
        );

        address vault = _getIntentVaultAddress(intentHash, routeHash, reward);

        if (fund && !_isRewardFunded(intent.reward, vault)) {
            if (route.source != block.chainid) {
                revert WrongSourceChain(intentHash);
            }
            if (reward.nativeValue > 0) {
                if (msg.value < reward.nativeValue) {
                    revert InsufficientNativeReward(intentHash);
                }

                payable(vault).transfer(reward.nativeValue);
            }

            for (uint256 i = 0; i < rewardsLength; ++i) {
                IERC20(reward.tokens[i].token).safeTransferFrom(
                    msg.sender,
                    vault,
                    reward.tokens[i].amount
                );
            }
        }

        uint256 currentBalance = address(this).balance;

        if (currentBalance > 0) {
            (bool success, ) = payable(msg.sender).call{value: currentBalance}(
                ""
            );

            if (!success) {
                revert NativeRewardTransferFailed(intentHash);
            }
        }
    }

    /**
     * @notice Checks if an intent is properly funded
     * @param intent Intent to validate
     * @return True if intent is properly funded, false otherwise
     */
    function isIntentFunded(
        Intent calldata intent
    ) external view returns (bool) {
        if (intent.route.source != block.chainid) return false;

        (bytes32 intentHash, bytes32 routeHash, ) = getIntentHash(intent);
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
    function withdrawRewards(bytes32 routeHash, Reward calldata reward) public {
        bytes32 rewardHash = keccak256(abi.encode(reward));
        bytes32 intentHash = keccak256(abi.encodePacked(routeHash, rewardHash));

        address claimant = BaseProver(reward.prover).provenIntents(intentHash);
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
            state.isPermit2 = 0;
            state.target = claimant;
            vaults[intentHash].state = state;

            emit Withdrawal(intentHash, claimant);

            new IntentVault{salt: routeHash}(intentHash, reward);

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
    ) external {
        uint256 length = routeHashes.length;

        if (length != rewards.length) {
            revert ArrayLengthMismatch();
        }

        for (uint256 i = 0; i < length; ++i) {
            withdrawRewards(routeHashes[i], rewards[i]);
        }
    }

    /**
     * @notice Refunds rewards to the intent creator
     * @param routeHash Hash of the intent's route
     * @param reward Reward structure of the intent
     */
    function refundIntent(bytes32 routeHash, Reward calldata reward) external {
        bytes32 rewardHash = keccak256(abi.encode(reward));
        bytes32 intentHash = keccak256(abi.encodePacked(routeHash, rewardHash));

        VaultState memory state = vaults[intentHash].state;

        if (
            state.status != uint8(RewardStatus.Claimed) &&
            state.status != uint8(RewardStatus.Refunded) &&
            block.timestamp <= reward.deadline
        ) {
            revert IntentNotExpired(intentHash);
        }

        if (state.status != uint8(RewardStatus.Claimed)) {
            state.status = uint8(RewardStatus.Refunded);
        }

        state.mode = uint8(VaultMode.Refund);
        state.allowPartialFunding = 0;
        state.isPermit2 = 0;
        state.target = address(0);
        vaults[intentHash].state = state;

        emit Refund(intentHash, reward.creator);

        new IntentVault{salt: routeHash}(intentHash, reward);
    }

    /**
     * @notice Refunds rewards to the intent creator
     * @param routeHash Hash of the intent's route
     * @param reward Reward structure of the intent
     * @param token Optional token address for handling incorrect vault transfers
     */
    function refundToken(
        bytes32 routeHash,
        Reward calldata reward,
        address token
    ) external {
        if (token == address(0)) {
            revert InvalidRefundToken();
        }

        bytes32 rewardHash = keccak256(abi.encode(reward));
        bytes32 intentHash = keccak256(abi.encodePacked(routeHash, rewardHash));

        VaultState memory state = vaults[intentHash].state;

        if (
            state.status != uint8(RewardStatus.Claimed) &&
            state.status != uint8(RewardStatus.Refunded) &&
            reward.nativeValue > 0
        ) {
            revert IntentNotClaimed(intentHash);
        }

        state.mode = uint8(VaultMode.RecoverToken);
        state.allowPartialFunding = 0;
        state.isPermit2 = 0;
        state.target = token;
        vaults[intentHash].state = state;

        emit Refund(intentHash, reward.creator);

        new IntentVault{salt: routeHash}(intentHash, reward);
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
                                        type(IntentVault).creationCode,
                                        abi.encode(intentHash, reward)
                                    )
                                )
                            )
                        )
                    )
                )
            );
    }
}
