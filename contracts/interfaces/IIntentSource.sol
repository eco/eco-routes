/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISemver} from "./ISemver.sol";
import {IVaultStorage} from "./IVaultStorage.sol";

import {Intent, Reward, Call, TokenAmount} from "../types/Intent.sol";

/**
 * @title IIntentSource
 * @notice Interface for the source chain portion of the Eco Protocol's intent system
 * @dev Used to create intents and withdraw their associated rewards. Works with an inbox
 * contract on the destination chain and verifies fulfillment via a prover contract
 */
interface IIntentSource is ISemver, IVaultStorage {
    /**
     * @notice Thrown when funding an intent is attempted on a chain that isn't the source chain
     */
    error WrongSourceChain(bytes32 intentHash);

    /**
     * @notice Thrown when a native token transfer fails
     */
    error NativeRewardTransferFailed(bytes32 intentHash);

    /**
     * @notice Thrown when attempting to publish an intent that already exists
     * @param intentHash Hash of the intent that already exists in the system
     */
    error IntentAlreadyExists(bytes32 intentHash);

    /**
     * @notice Thrown when attempting to fund an intent that has already been funded
     */
    error IntentAlreadyFunded(bytes32 intentHash);

    /**
     * @notice Thrown when the sent native token amount is less than the required reward amount
     */
    error InsufficientNativeReward(bytes32 intentHash);

    /**
     * @notice Thrown when trying to fund an intent with native tokens
     */
    error CannotFundNativeReward(bytes32 intentHash);

    /**
     * @notice Thrown when an unauthorized address attempts to withdraw intent rewards
     * @param _hash Hash of the intent (key in intents mapping)
     */
    error UnauthorizedWithdrawal(bytes32 _hash);

    /**
     * @notice Thrown when attempting to withdraw from an intent with already claimed rewards
     * @param _hash Hash of the intent
     */
    error RewardsAlreadyWithdrawn(bytes32 _hash);

    /**
     * @notice Thrown when attempting to withdraw rewards before the intent has expired
     */
    error IntentNotExpired(bytes32 intentHash);

    /**
     * @notice Thrown when attempting to refund token before the intent is claimed or expired
     */
    error IntentNotClaimed(bytes32 intentHash);

    /**
     * @notice Thrown when refund token is 0 address
     */
    error InvalidRefundToken();

    /**
     * @notice Thrown when array lengths don't match in batch operations
     * @dev Used specifically in batch withdraw operations when routeHashes and rewards arrays have different lengths
     */
    error ArrayLengthMismatch();

    /**
     * @notice Emitted when an intent is funded with native tokens
     * @param intentHash Hash of the funded intent
     * @param fundingSource Address of the funder
     */
    event IntentPartiallyFunded(bytes32 intentHash, address fundingSource);

    /**
     * @notice Emitted when an intent is funded with native tokens
     * @param intentHash Hash of the funded intent
     * @param fundingSource Address of the funder
     */
    event IntentFunded(bytes32 intentHash, address fundingSource);

    /**
     * @notice Emitted when a new intent is created
     * @param hash Hash of the created intent (key in intents mapping)
     * @param salt Creator-provided nonce
     * @param source Source chain ID
     * @param destination Destination chain ID
     * @param inbox Address of inbox contract on destination chain
     * @param routeTokens Array of tokens required for execution of calls on destination chain
     * @param calls Array of instruction calls to execute
     * @param creator Address that created the intent
     * @param prover Address of prover contract for validation
     * @param deadline Timestamp by which intent must be fulfilled for reward claim
     * @param nativeValue Amount of native tokens offered as reward
     * @param rewardTokens Array of ERC20 tokens and amounts offered as rewards
     */
    event IntentCreated(
        bytes32 indexed hash,
        bytes32 salt,
        uint256 source,
        uint256 destination,
        address inbox,
        TokenAmount[] routeTokens,
        Call[] calls,
        address indexed creator,
        address indexed prover,
        uint256 deadline,
        uint256 nativeValue,
        TokenAmount[] rewardTokens
    );

    /**
     * @notice Emitted when rewards are successfully withdrawn
     * @param _hash Hash of the claimed intent
     * @param _recipient Address receiving the rewards
     */
    event Withdrawal(bytes32 _hash, address indexed _recipient);

    /**
     * @notice Emitted when rewards are successfully withdrawn
     * @param _hash Hash of the claimed intent
     * @param _recipient Address receiving the rewards
     */
    event Refund(bytes32 _hash, address indexed _recipient);

    /**
     * @notice Gets the claim state for a given intent
     * @param intentHash Hash of the intent to query
     * @return status Current status of the intent
     */
    function getRewardStatus(
        bytes32 intentHash
    ) external view returns (RewardStatus status);

    /**
     * @notice Gets the funding source for an intent
     */
    function getVaultState(
        bytes32 intentHash
    ) external view returns (VaultState memory);

    /**
     * @notice Gets the token used for vault refunds
     * @return Address of the vault refund token
     */
    function getPermit2(bytes32 intentHash) external view returns (address);

    /**
     * @notice Calculates the hash components of an intent
     * @param intent Intent to hash
     * @return intentHash Combined hash of route and reward
     * @return routeHash Hash of the route component
     * @return rewardHash Hash of the reward component
     */
    function getIntentHash(
        Intent calldata intent
    )
        external
        pure
        returns (bytes32 intentHash, bytes32 routeHash, bytes32 rewardHash);

    /**
     * @notice Calculates the deterministic vault address for an intent
     * @param intent Intent to calculate vault address for
     * @return Predicted address of the intent vault
     */
    function intentVaultAddress(
        Intent calldata intent
    ) external view returns (address);

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
    ) external returns (bytes32 intentHash);

    /**
     * @notice Creates an intent to execute instructions on a supported chain for rewards
     * @dev Source chain proof must complete before expiry or rewards are unclaimable,
     *      regardless of execution status. Solver manages timing of L1 data posting
     * @param intent The complete intent struct
     * @param fund Whether to transfer rewards to vault during creation
     * @return intentHash Hash of the created intent
     */
    function publishIntent(
        Intent calldata intent,
        bool fund
    ) external payable returns (bytes32 intentHash);

    /**
     * @notice Verifies an intent's rewards are valid
     * @param intent Intent to validate
     * @return True if rewards are valid and funded
     */
    function isIntentFunded(
        Intent calldata intent
    ) external view returns (bool);

    /**
     * @notice Withdraws reward funds for a fulfilled intent
     * @param routeHash Hash of the intent's route
     * @param reward Reward struct containing distribution details
     */
    function withdrawRewards(
        bytes32 routeHash,
        Reward calldata reward
    ) external;

    /**
     * @notice Batch withdraws rewards for multiple intents
     * @param routeHashes Array of route hashes
     * @param rewards Array of reward structs
     */
    function batchWithdraw(
        bytes32[] calldata routeHashes,
        Reward[] calldata rewards
    ) external;

    /**
     * @notice Refunds rewards back to the intent creator
     * @param routeHash Hash of the intent's route
     * @param reward Reward struct containing distribution details
     */
    function refundIntent(bytes32 routeHash, Reward calldata reward) external;

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
    ) external;
}
