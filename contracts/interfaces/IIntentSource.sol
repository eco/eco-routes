/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISemver} from "./ISemver.sol";

import {Intent, Reward, Call, TokenAmount} from "../types/Intent.sol";

/**
 * @title IIntentSource
 * @notice Interface for the source chain portion of the Eco Protocol's intent system
 * @dev Used to create intents and withdraw their associated rewards. Works with an inbox
 * contract on the destination chain and verifies fulfillment via a prover contract
 */
interface IIntentSource is ISemver {
    /**
     * @notice Thrown when funding an intent is attempted on a chain that isn't the source chain
     */
    error WrongSourceChain();

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
     * @notice Thrown when target addresses and calldata arrays have mismatched lengths or are empty
     */
    error CalldataMismatch();

    /**
     * @notice Thrown when reward tokens and amounts arrays have mismatched lengths or are empty
     */
    error RewardsMismatch();

    /**
     * @notice Thrown when batch withdrawal intent claimant doesn't match provided address
     * @param _hash Hash of the mismatched intent
     */
    error BadClaimant(bytes32 _hash);

    /**
     * @notice Thrown when a token transfer fails
     * @param _token Address of the token
     * @param _to Intended recipient
     * @param _amount Transfer amount
     */
    error TransferFailed(address _token, address _to, uint256 _amount);

    /**
     * @notice Thrown when a native token transfer fails
     */
    error NativeRewardTransferFailed();

    /**
     * @notice Thrown when attempting to publish an intent that already exists
     * @param intentHash Hash of the intent that already exists in the system
     */
    error IntentAlreadyExists(bytes32 intentHash);

    /**
     * @notice Thrown when attempting to fund an intent that has already been funded
     */
    error IntentAlreadyFunded();

    /**
     * @notice Thrown when the sent native token amount is less than the required reward amount
     */
    error InsufficientNativeReward();

    /**
     * @notice Thrown when attempting to validate an intent that fails basic validation checks
     * @dev This includes cases where the vault doesn't have sufficient balance or other validation failures
     */
    error InvalidIntent();

    /**
     * @notice Thrown when array lengths don't match in batch operations
     * @dev Used specifically in batch withdraw operations when routeHashes and rewards arrays have different lengths
     */
    error ArrayLengthMismatch();

    /**
     * @notice Status of an intent's reward claim
     */
    enum ClaimStatus {
        Initial,
        Claimed,
        Refunded
    }

    /**
     * @notice State of an intent's reward claim
     * @dev Tracks claimant address and claim status
     */
    struct ClaimState {
        address claimant;
        uint8 status;
    }

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
     * @return Claim state struct containing claimant and status
     */
    function getClaim(
        bytes32 intentHash
    ) external view returns (ClaimState memory);

    /**
     * @notice Gets the funding source for the intent funder
     * @return Address of the native token funding source
     */
    function getFundingSource() external view returns (address);

    /**
     * @notice Gets the override token used for vault refunds
     * @return Address of the vault refund token
     */
    function getRefundToken() external view returns (address);

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
     * @notice Calculates the deterministic address of the intent funder
     * @param intent Intent to calculate vault address for
     * @return Address of the intent funder
     */
    function intentFunderAddress(
        Intent calldata intent
    ) external view returns (address);

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
     * @dev Allows for permit calls to approve token transfers
     * @param routeHash Hash of the route component
     * @param reward Reward structure containing distribution details
     * @param fundingAddress Address to fund the intent from
     * @param recoverToken Address of the token to recover if sent to the vault
     */
    function fundIntent(
        bytes32 routeHash,
        Reward calldata reward,
        address fundingAddress,
        address recoverToken
    ) external payable;

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
     * @param token Optional token to refund if incorrectly sent to vault
     */
    function refundIntent(
        bytes32 routeHash,
        Reward calldata reward,
        address token
    ) external;
}
