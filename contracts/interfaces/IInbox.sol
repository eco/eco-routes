// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISemver} from "./ISemver.sol";

import {Route} from "../types/Intent.sol";

/**
 * @title IInbox
 * @notice Interface for the destination chain portion of the Eco Protocol's intent system
 * @dev Handles intent fulfillment and proving via different mechanisms (storage proofs,
 * Hyperlane instant/batched)
 */
interface IInbox is ISemver {
    /**
     * @notice Emitted when an intent is successfully fulfilled
     * @param _hash Hash of the fulfilled intent
     * @param _sourceChainID ID of the source chain
     * @param _claimant Address eligible to claim rewards
     */
    event Fulfillment(
        bytes32 indexed _hash,
        uint256 indexed _sourceChainID,
        address indexed _claimant
    );

    /**
     * @notice Emitted when an intent is ready for storage proof validation
     * @param _hash Hash of the intent to prove
     * @param _sourceChainID ID of the source chain
     * @param _claimant Address eligible to claim rewards
     */
    event ToBeProven(
        bytes32 indexed _hash,
        uint256 indexed _sourceChainID,
        address indexed _claimant
    );

    /**
     * @notice Emitted when an intent is fulfilled using Hyperlane instant proving
     * @param _hash Hash of the fulfilled intent
     * @param _sourceChainID ID of the source chain
     * @param _claimant Address eligible to claim rewards
     */
    event HyperInstantFulfillment(
        bytes32 indexed _hash,
        uint256 indexed _sourceChainID,
        address indexed _claimant
    );

    /**
     * @notice Emitted when an intent is to be added to a message bridge proving batch
     * @param _hash Hash of the batched intent
     * @param _sourceChainID ID of the source chain
     * @param _claimant Address eligible to claim rewards
     * @param _localProver Address of prover on the destination chain
     * @param _sourceChainProver Address of prover on the source chain
     */
    event AddToBatch(
        bytes32 indexed _hash,
        uint256 indexed _sourceChainID,
        address indexed _claimant,
        address _localProver,
        address _sourceChainProver
    );

    /**
     * @notice Emitted when a batch of fulfilled intents is sent to the Hyperlane mailbox to be relayed to the source chain
     * @param _hashes the intent hashes sent in the batch
     * @param _sourceChainID ID of the source chain
     */
    event BatchSent(bytes32[] indexed _hashes, uint256 indexed _sourceChainID);

    /**
     * @notice Emitted when intent solving is made public
     */
    event SolvingIsPublic();

    /**
     * @notice Emitted when Hyperlane mailbox address is set
     * @param _mailbox Address of the mailbox contract
     */
    event MailboxSet(address indexed _mailbox);

    /**
     * @notice Emitted when minimum batcher reward is set
     * @param _minBatcherReward new minimum batcher reward
     */
    event MinBatcherRewardSet(uint96 _minBatcherReward);

    /**
     * @notice Emitted when solver whitelist status changes
     * @param _solver Address of the solver
     * @param _canSolve Updated whitelist status
     */
    event SolverWhitelistChanged(
        address indexed _solver,
        bool indexed _canSolve
    );

    /**
     * @notice Unauthorized solver attempted to fulfill intent
     * @param _solver Address of the unauthorized solver
     */
    error UnauthorizedSolveAttempt(address _solver);

    /**
     * @notice Thrown when an attempt is made to fulfill an intent on the wrong destination chain
     * @param _chainID Chain ID of the destination chain on which this intent should be fulfilled
     */
    error WrongChain(uint256 _chainID);

    /**
     * @notice Intent has already been fulfilled
     * @param _hash Hash of the fulfilled intent
     */
    error IntentAlreadyFulfilled(bytes32 _hash);

    /**
     * @notice Invalid inbox address provided
     * @param _inbox Address that is not a valid inbox
     */
    error InvalidInbox(address _inbox);

    /**
     * @notice Generated hash doesn't match expected hash
     * @param _expectedHash Hash that was expected
     */
    error InvalidHash(bytes32 _expectedHash);

    /**
     * @notice Zero address provided as claimant
     */
    error ZeroClaimant();

    /**
     * @notice Call during intent execution failed
     * @param _addr Target contract address
     * @param _data Call data that failed
     * @param value Native token value sent
     * @param _returnData Error data returned
     */
    error IntentCallFailed(
        address _addr,
        bytes _data,
        uint256 value,
        bytes _returnData
    );

    /**
     * @notice Attempted call to a destination-chain prover
     */
    error CallToProver();

    /**
     * @notice Attempted call to an EOA
     * @param _EOA EOA address to which call was attempted
     */
    error CallToEOA(address _EOA);

    /**
     * @notice Attempted to batch an unfulfilled intent
     * @param _hash Hash of the unfulfilled intent
     */
    error IntentNotFulfilled(bytes32 _hash);

    /**
     * @notice Insufficient fee provided for Hyperlane fulfillment
     * @param _requiredFee Amount of fee required
     */
    error InsufficientFee(uint256 _requiredFee);

    /**
     * @notice Native token transfer failed
     */
    error NativeTransferFailed();

    /**
     * @notice Fulfills an intent using storage proofs
     * @dev Validates intent hash, executes calls, and marks as fulfilled
     * @param _route Route information for the intent
     * @param _rewardHash Hash of the reward details
     * @param _claimant Address eligible to claim rewards
     * @param _expectedHash Expected hash for validation
     * @return Array of execution results
     */
    function fulfillStorage(
        Route calldata _route,
        bytes32 _rewardHash,
        address _claimant,
        bytes32 _expectedHash
    ) external payable returns (bytes[] memory);

    /**
     * @notice Fulfills an intent and initiates proving via message bridge
     * @param _route The route of the intent
     * @param _rewardHash The hash of the reward
     * @param _claimant The address that will receive the reward on the source chain
     * @param _expectedHash The hash of the intent as created on the source chain
     * @param _localProver Address of prover on the destination chain
     * @param _sourceChainProver Address of prover on the source chain
     */
    function fulfillMessageBridge(
        Route memory _route,
        bytes32 _rewardHash,
        address _claimant,
        bytes32 _expectedHash,
        address _localProver,
        address _sourceChainProver,
        bytes calldata _data
    ) external payable returns (bytes[] memory);

    /**
     * @notice Fulfills an intent to be proven in a batch via a meessage bridge
     * @dev Less expensive but slower fulfillMessageBridge. Batch dispatched when sendBatch is called.
     * @param _route The route of the intent
     * @param _rewardHash The hash of the reward
     * @param _claimant The address that will receive the reward on the source chain
     * @param _expectedHash The hash of the intent as created on the source chain
     * @param _localProver Address of prover on the destination chain
     * @param _sourceChainProver Address of prover on the source chain
     */
    function fulfillMessageBridgeBatched(
        Route calldata _route,
        bytes32 _rewardHash,
        address _claimant,
        bytes32 _expectedHash,
        address _localProver,
        address _sourceChainProver
    ) external payable returns (bytes[] memory);

    /**
     * @notice initiates proving of a batch of fulfilled intents
     * @dev Intent hashes must correspond to fulfilled intents from specified source chain
     * @param _sourceChainID Chain ID of the source chain
     * @param _intentHashes Hashes of the intents to be proven
     * @param _localProver Address of prover on the destination chain
     * @param _sourceChainProver Address of prover on the source chain
     */
    function messageBridgeSendBatch(
        uint256 _sourceChainID,
        bytes32[] calldata _intentHashes,
        address _localProver,
        address _sourceChainProver,
        bytes calldata _data
    ) external payable;
}
