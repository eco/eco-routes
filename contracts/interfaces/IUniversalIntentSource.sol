/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IVaultStorage} from "./IVaultStorage.sol";

import {Reward} from "../types/UniversalIntent.sol";

/**
 * @title IUniversalIntentSource
 * @notice Interface for managing cross-chain intents with Universal types for cross-chain compatibility
 * @dev This contract works in conjunction with a portal contract on the destination chain
 *      and a prover contract for verification. It handles intent creation, funding,
 *      and reward distribution using bytes32 identifiers for cross-chain compatibility.
 */
interface IUniversalIntentSource is IVaultStorage {
    /**
     * @notice Computes the hash of an intent
     * @param destination Destination chain ID
     * @param route Encoded route data
     * @param reward Reward structure
     * @return intentHash Combined hash of route and reward
     * @return routeHash Hash of the route
     */
    function getIntentHash(
        uint64 destination,
        bytes calldata route,
        Reward calldata reward
    ) external pure returns (bytes32 intentHash, bytes32 routeHash);

    /**
     * @notice Computes the deterministic vault address for an intent
     * @param destination Destination chain ID
     * @param route Encoded route data
     * @param reward Reward structure
     * @return Predicted vault address (returns address since vault is on EVM)
     */
    function intentVaultAddress(
        uint64 destination,
        bytes calldata route,
        Reward calldata reward
    ) external view returns (address);

    /**
     * @notice Creates a new cross-chain intent with associated rewards
     * @dev Intent must be proven on source chain before expiration for valid reward claims
     * @param destination Destination chain ID
     * @param route Encoded route data
     * @param reward Reward structure
     * @return intentHash Unique identifier of the created intent
     * @return vault Address of the created vault
     */
    function publish(
        uint64 destination,
        bytes calldata route,
        Reward calldata reward
    ) external returns (bytes32 intentHash, address vault);

    /**
     * @notice Creates and funds an intent in a single transaction
     * @param destination Destination chain ID
     * @param route Encoded route data
     * @param reward Reward structure
     * @param allowPartial Whether to allow partial funding
     * @return intentHash Unique identifier of the created and funded intent
     * @return vault Address of the created vault
     */
    function publishAndFund(
        uint64 destination,
        bytes calldata route,
        Reward calldata reward,
        bool allowPartial
    ) external payable returns (bytes32 intentHash, address vault);

    /**
     * @notice Funds an existing intent
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
    ) external payable returns (bytes32 intentHash);

    /**
     * @notice Funds an intent on behalf of another address using permit
     * @param destination Destination chain ID for the intent
     * @param reward The reward specification
     * @param routeHash The hash of the intent's route component
     * @param fundingAddress The bytes32 identifier providing the funding
     * @param permitContract The bytes32 identifier for external token approvals
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
    ) external returns (bytes32 intentHash);

    /**
     * @notice Creates and funds an intent on behalf of another address
     * @param destination Destination chain ID
     * @param route Encoded route data
     * @param reward Reward structure
     * @param funder The bytes32 identifier providing the funding
     * @param permitContract The bytes32 identifier for token approvals
     * @param allowPartial Whether to accept partial funding
     * @return intentHash The hash of the created and funded intent
     * @return vault Address of the created vault
     */
    function publishAndFundFor(
        uint64 destination,
        bytes calldata route,
        Reward calldata reward,
        address funder,
        address permitContract,
        bool allowPartial
    ) external returns (bytes32 intentHash, address vault);

    /**
     * @notice Checks if an intent's rewards are valid and fully funded
     * @param destination Destination chain ID
     * @param route Encoded route data
     * @param reward Reward structure
     * @return True if the intent is properly funded
     */
    function isIntentFunded(
        uint64 destination,
        bytes calldata route,
        Reward calldata reward
    ) external view returns (bool);

    /**
     * @notice Claims rewards for a successfully fulfilled and proven intent
     * @param destination Destination chain ID for the intent
     * @param reward The reward specification
     * @param routeHash The hash of the intent's route component
     */
    function withdraw(
        uint64 destination,
        Reward calldata reward,
        bytes32 routeHash
    ) external;

    /**
     * @notice Claims rewards for multiple fulfilled and proven intents
     * @param destinations Array of destination chain IDs for the intents
     * @param rewards Array of corresponding reward specifications
     * @param routeHashes Array of route component hashes
     */
    function batchWithdraw(
        uint64[] calldata destinations,
        Reward[] calldata rewards,
        bytes32[] calldata routeHashes
    ) external;

    /**
     * @notice Returns rewards to the intent creator
     * @param destination Destination chain ID for the intent
     * @param reward The reward specification
     * @param routeHash The hash of the intent's route component
     */
    function refund(
        uint64 destination,
        Reward calldata reward,
        bytes32 routeHash
    ) external;

    /**
     * @notice Recovers mistakenly transferred tokens from the intent vault
     * @dev Token must not be part of the intent's reward structure
     * @param destination Destination chain ID for the intent
     * @param reward The reward specification
     * @param routeHash The hash of the intent's route component
     * @param token The bytes32 identifier of the token to recover
     */
    function recoverToken(
        uint64 destination,
        Reward calldata reward,
        bytes32 routeHash,
        address token
    ) external;
}
