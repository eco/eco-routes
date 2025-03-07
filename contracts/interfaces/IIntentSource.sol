/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISemver} from "./ISemver.sol";
import {IVaultStorage} from "./IVaultStorage.sol";

import {Intent, Reward, Call, TokenAmount} from "../types/Intent.sol";

/**
 * @title IIntentSource
 * @notice Interface for managing cross-chain intents and their associated rewards on the source chain
 * @dev This contract works in conjunction with an inbox contract on the destination chain
 *      and a prover contract for verification. It handles intent creation, funding,
 *      and reward distribution.
 */
interface IIntentSource is ISemver, IVaultStorage {
    /**
     * @notice Indicates an attempt to fund an intent on an incorrect chain
     * @param intentHash The hash of the intent that was incorrectly targeted
     */
    error WrongSourceChain(bytes32 intentHash);

    /**
     * @notice Indicates a failed native token transfer during reward distribution
     * @param intentHash The hash of the intent whose reward transfer failed
     */
    error NativeRewardTransferFailed(bytes32 intentHash);

    /**
     * @notice Indicates an attempt to publish a duplicate intent
     * @param intentHash The hash of the pre-existing intent
     */
    error IntentAlreadyExists(bytes32 intentHash);

    /**
     * @notice Indicates an attempt to fund an already funded intent
     * @param intentHash The hash of the previously funded intent
     */
    error IntentAlreadyFunded(bytes32 intentHash);

    /**
     * @notice Indicates insufficient native token payment for the required reward
     * @param intentHash The hash of the intent with insufficient funding
     */
    error InsufficientNativeReward(bytes32 intentHash);

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
     * @notice Thrown when a permit call to a contract fails
     */
    error PermitCallFailed();

    /**
     * @notice Thrown when attempting to publish an intent that already exists
     * @param intentHash Hash of the intent that already exists in the system
     */
    error IntentAlreadyExists(bytes32 intentHash);

    /**
     * @notice Indicates a premature withdrawal attempt before intent expiration
     * @param intentHash The hash of the unexpired intent
     */
    error IntentNotExpired(bytes32 intentHash);

    /**
     * @notice Indicates a premature refund attempt before intent completion
     * @param intentHash The hash of the unclaimed intent
     */
    error IntentNotClaimed(bytes32 intentHash);

    /**
     * @notice Indicates an invalid token specified for refund
     */
    error InvalidRefundToken();

    /**
     * @notice Indicates mismatched array lengths in batch operations
     */
    error ArrayLengthMismatch();

    /**
     * @notice Status of an intent's reward claim
     */
    enum ClaimStatus {
        Initiated,
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
    event IntentFunded(bytes32 intentHash, address funder);

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
    event Withdrawal(bytes32 hash, address indexed recipient);

    /**
     * @notice Emitted when rewards are successfully withdrawn
     * @param _hash Hash of the claimed intent
     * @param _recipient Address receiving the rewards
     */
    event Refund(bytes32 hash, address indexed recipient);

    /**
     * @notice Gets the claim state for a given intent
     * @param intentHash Hash of the intent to query
     * @return Claim state struct containing claimant and status
     */
    function getRewardStatus(
        bytes32 intentHash
    ) external view returns (RewardStatus status);

    /**
     * @notice Retrieves the current state of an intent's vault
     * @param intentHash The hash of the intent
     * @return Current vault state
     */
    function getVaultState(
        bytes32 intentHash
    ) external view returns (VaultState memory);

    /**
     * @notice Retrieves the permit contract for token transfers
     * @param intentHash The hash of the intent
     * @return Address of the permit contract
     */
    function getPermitContract(
        bytes32 intentHash
    ) external view returns (address);

    /**
     * @notice Computes the hash components of an intent
     * @param intent The intent to hash
     * @return intentHash Combined hash of route and reward components
     * @return routeHash Hash of the route specifications
     * @return rewardHash Hash of the reward specifications
     */
    function getIntentHash(
        Intent calldata intent
    )
        external
        pure
        returns (bytes32 intentHash, bytes32 routeHash, bytes32 rewardHash);

    /**
     * @notice Computes the deterministic vault address for an intent
     * @param intent The intent to calculate the vault address for
     * @return Predicted vault address
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
     * @param permitCalls Array of permit calls to approve token transfers
     * @param recoverToken Address of the token to recover if sent to the vault
     */
    function fundFor(
        bytes32 routeHash,
        Reward calldata reward,
        address fundingAddress,
        address permitContract,
        bool allowPartial
    ) external returns (bytes32 intentHash);

    /**
     * @notice Creates and funds an intent on behalf of another address
     * @param intent The complete intent specification
     * @param funder The address providing the funding
     * @param permitContact The permit contract for token approvals
     * @param allowPartial Whether to accept partial funding
     * @return intentHash The hash of the created and funded intent
     */
    function publishAndFundFor(
        Intent calldata intent,
        address funder,
        address permitContact,
        bool allowPartial
    ) external returns (bytes32 intentHash);

    /**
     * @notice Checks if an intent's rewards are valid and fully funded
     * @param intent The intent to validate
     * @return True if the intent is properly funded
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
     * @notice Returns rewards to the intent creator
     * @param routeHash The hash of the intent's route component
     * @param reward The reward specification
     */
    function refund(bytes32 routeHash, Reward calldata reward) external;

    /**
     * @notice Recovers mistakenly transferred tokens from the intent vault
     * @dev Token must not be part of the intent's reward structure
     * @param routeHash The hash of the intent's route component
     * @param reward The reward specification
     * @param token The address of the token to recover
     */
    function recoverToken(
        bytes32 routeHash,
        Reward calldata reward,
        address token
    ) external;
}
