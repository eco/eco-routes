// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMessageRecipient} from "@hyperlane-xyz/core/contracts/interfaces/IMessageRecipient.sol";
import {TypeCasts} from "@hyperlane-xyz/core/contracts/libs/TypeCasts.sol";
import {MessageBridgeProver} from "./MessageBridgeProver.sol";
import {Semver} from "../libs/Semver.sol";
import {IMailbox, IPostDispatchHook} from "@hyperlane-xyz/core/contracts/interfaces/IMailbox.sol";
import {MinimalRoute, Route} from "../types/Intent.sol";
import {console} from "hardhat/console.sol";

/**
 * @title HyperProver
 * @notice Prover implementation using Hyperlane's cross-chain messaging system
 * @notice the terms "source" and "destination" are used in reference to a given intent: created on source chain, fulfilled on destination chain
 * @dev Processes proof messages from Hyperlane mailbox and records proven intents
 */
contract HyperProver is IMessageRecipient, MessageBridgeProver, Semver {
    using TypeCasts for bytes32;

    /**
     * @notice Struct for unpacked data from _data parameter
     * @dev Only contains fields decoded from the _data parameter
     */
    struct UnpackedData {
        bytes32 sourceChainProver; // Address of prover on source chain
        bytes metadata; // Metadata for Hyperlane message
        address hookAddr; // Address of post-dispatch hook
    }

    /**
     * @notice Constant indicating this contract uses Hyperlane for proving
     */
    string public constant PROOF_TYPE = "Hyperlane";

    /**
     * @notice Address of local Hyperlane mailbox
     */
    address public immutable MAILBOX;

    /**
     * @param _mailbox Address of local Hyperlane mailbox
     * @param _inbox Address of Inbox contract
     * @param _provers Array of trusted prover addresses
     */
    constructor(
        address _mailbox,
        address _inbox,
        address[] memory _provers
    ) MessageBridgeProver(_inbox, _provers, 0) {
        if (_mailbox == address(0)) revert MailboxCannotBeZeroAddress();
        MAILBOX = _mailbox;
    }

    /**
     * @notice Handles incoming Hyperlane messages containing proof data
     * @dev called by the Hyperlane mailbox on the source chain
     * @dev Processes batch updates to proven intents from valid sources
     * @param _origin DomainID of the destination chain
     * @param _sender Address that dispatched the message on source chain
     * @param _messageBody Encoded array of intent hashes and claimants
     */
    function handle(
        uint32 _origin,
        bytes32 _sender,
        bytes calldata _messageBody
    ) public payable {
        // Verify message is from authorized mailbox
        _validateMessageSender(msg.sender, MAILBOX);

        // Verify _origin and _sender are valid
        if (_origin == 0) revert InvalidOriginChainID();

        // Convert bytes32 sender to address and delegate to shared handler
        address sender = _sender.bytes32ToAddress();
        if (sender == address(0)) revert SenderCannotBeZeroAddress();

        _handleCrossChainMessage(_origin, sender, _messageBody);
    }

    /**
     * @notice Initiates proving of intents via Hyperlane
     * @dev Sends message to source chain prover with intent data
     * @dev called by the Inbox contract on the destination chain
     * @param _sender Address that initiated the proving request
     * @param _sourceChainID Chain ID of source chain
     * @param _minimalRoutes Array of MinimalRoute structs for the intents being proven
     * @param _rewardHashes Array of reward hashes for the intents being proven
     * @param _claimants Array of claimant addresses
     * @param _data Additional data for message formatting
     */
    function prove(
        address _sender,
        uint256 _sourceChainID,
        MinimalRoute[] calldata _minimalRoutes,
        bytes32[] calldata _rewardHashes,
        address[] calldata _claimants,
        bytes calldata _data
    ) external payable override {
        // Validate the request is from Inbox
        _validateProvingRequest(msg.sender);

        // Parse incoming data into a structured format for processing
        UnpackedData memory unpacked = _unpackData(_data);

        // Calculate fee
        uint256 fee = _fetchFee(
            _sourceChainID,
            _minimalRoutes,
            _rewardHashes,
            _claimants,
            unpacked
        );

        // Check if enough fee was provided
        if (msg.value < fee) {
            revert InsufficientFee(fee);
        }

        // Calculate refund amount if overpaid
        uint256 _refundAmount = 0;
        if (msg.value > fee) {
            _refundAmount = msg.value - fee;
        }
        bytes32[] memory intentHashes = new bytes32[](_rewardHashes.length);
        for (uint256 i = 0; i < _rewardHashes.length; i++) {
            Route memory route = Route(
                _minimalRoutes[i].salt,
                _sourceChainID,
                block.chainid,
                address(this),
                _minimalRoutes[i].tokens,
                _minimalRoutes[i].calls
            );
            intentHashes[i] = keccak256(
                abi.encodePacked(keccak256(abi.encode(route)), _rewardHashes[i])
            );
        }

        emit BatchSent(intentHashes, _sourceChainID);

        // Declare dispatch parameters for cross-chain message delivery
        uint32 destinationDomain;
        bytes32 recipientAddress;
        bytes memory messageBody;
        bytes memory metadata;
        IPostDispatchHook hook;

        // Prepare parameters for cross-chain message dispatch
        (
            destinationDomain,
            recipientAddress,
            messageBody,
            metadata,
            hook
        ) = _formatHyperlaneMessage(
            _sourceChainID,
            _minimalRoutes,
            _rewardHashes,
            _claimants,
            unpacked
        );

        // Send the message through Hyperlane mailbox using local variables
        // Note: Some Hyperlane versions have different dispatch signatures.
        // This matches the expected signature for testing.
        IMailbox(MAILBOX).dispatch{value: fee}(
            destinationDomain,
            recipientAddress,
            messageBody,
            metadata,
            hook
        );

        // Send refund if needed
        _sendRefund(_sender, _refundAmount);
    }

    /**
     * @notice Calculates the fee required for Hyperlane message dispatch
     * @dev Queries the Mailbox contract for accurate fee estimation
     * @param _sourceChainID Chain ID of source chain
     * @param _minimalRoutes Array of minimal routes for the intents being proven
     * @param _rewardHashes Array of reward hashes of intents being proven
     * @param _claimants Array of claimant addresses
     * @param _data Additional data for message formatting
     * @return Fee amount required for message dispatch
     */
    function fetchFee(
        uint256 _sourceChainID,
        MinimalRoute[] calldata _minimalRoutes,
        bytes32[] calldata _rewardHashes,
        address[] calldata _claimants,
        bytes calldata _data
    ) public view override returns (uint256) {
        // Decode structured data from the raw input
        UnpackedData memory unpacked = _unpackData(_data);

        // Process fee calculation using the decoded struct
        // This architecture separates decoding from core business logic
        return
            _fetchFee(
                _sourceChainID,
                _minimalRoutes,
                _rewardHashes,
                _claimants,
                unpacked
            );
    }

    /**
     * @notice Decodes the raw cross-chain message data into a structured format
     * @dev Parses ABI-encoded parameters into the UnpackedData struct
     * @param _data Raw message data containing source chain information
     * @return unpacked Structured representation of the decoded parameters
     */
    function _unpackData(
        bytes calldata _data
    ) internal pure returns (UnpackedData memory unpacked) {
        (unpacked.sourceChainProver, unpacked.metadata, unpacked.hookAddr) = abi
            .decode(_data, (bytes32, bytes, address));

        return unpacked;
    }

    /**
     * @notice Internal function to calculate the fee with pre-decoded data
     * @param _sourceChainID Chain ID of source chain
     * @param _minimalRoutes Array of MinimalRoute structs for the intents being proven
     * @param _rewardHashes Array of reward hashes of intents being proven
     * @param _claimants Array of claimant addresses
     * @param unpacked Struct containing decoded data from _data parameter
     * @return Fee amount required for message dispatch
     */
    function _fetchFee(
        uint256 _sourceChainID,
        MinimalRoute[] calldata _minimalRoutes,
        bytes32[] calldata _rewardHashes,
        address[] calldata _claimants,
        UnpackedData memory unpacked
    ) internal view returns (uint256) {
        // Format and prepare message parameters for dispatch
        (
            uint32 sourceChainDomain,
            bytes32 recipientAddress,
            bytes memory messageBody,
            bytes memory metadata,
            IPostDispatchHook hook
        ) = _formatHyperlaneMessage(
                _sourceChainID,
                _minimalRoutes,
                _rewardHashes,
                _claimants,
                unpacked
            );

        // Query Hyperlane mailbox for accurate fee estimate
        return
            IMailbox(MAILBOX).quoteDispatch(
                sourceChainDomain,
                recipientAddress,
                messageBody,
                metadata,
                hook
            );
    }

    /**
     * @notice Returns the proof type used by this prover
     * @return ProofType indicating Hyperlane proving mechanism
     */
    function getProofType() external pure override returns (string memory) {
        return PROOF_TYPE;
    }

    /**
     * @notice Formats data for Hyperlane message dispatch with pre-decoded values
     * @dev Prepares all parameters needed for the Mailbox dispatch call
     * @param _sourceChainID Chain ID of source chain
     * @param _minimalRoutes Array of MinimalRoute structs for the intents being proven
     * @param _rewardHashes Array of reward hashes for the intents
     * @param _claimants Array of claimant addresses
     * @param _unpacked Struct containing decoded data from _data parameter
     * @return domain Hyperlane domain ID
     * @return recipient Recipient address encoded as bytes32
     * @return message Encoded message body with routes, reward hashes, and claimants
     * @return metadata Additional metadata for the message
     * @return hook Post-dispatch hook contract
     */
    function _formatHyperlaneMessage(
        uint256 _sourceChainID,
        MinimalRoute[] calldata _minimalRoutes,
        bytes32[] calldata _rewardHashes,
        address[] calldata _claimants,
        UnpackedData memory _unpacked
    )
        internal
        view
        returns (
            uint32 domain,
            bytes32 recipient,
            bytes memory message,
            bytes memory metadata,
            IPostDispatchHook hook
        )
    {
        // Centralized validation ensures arrays match exactly once in the call flow
        // This prevents security issues where hashes and claimants could be mismatched
        if (_rewardHashes.length != _claimants.length) {
            revert ArrayLengthMismatch();
        }

        domain = _convertChainIDToDomainID(_sourceChainID);

        // Use the source chain prover address as the message recipient
        recipient = _unpacked.sourceChainProver;

        // Pack intent hashes and claimant addresses together as the message payload

        message = abi.encode(INBOX, _minimalRoutes, _rewardHashes, _claimants);

        // Pass through metadata as provided
        metadata = _unpacked.metadata;

        // Default to mailbox's hook if none provided, following Hyperlane best practices
        hook = (_unpacked.hookAddr == address(0))
            ? IMailbox(MAILBOX).defaultHook()
            : IPostDispatchHook(_unpacked.hookAddr);
    }
}
