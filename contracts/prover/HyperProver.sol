// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMessageRecipient} from "@hyperlane-xyz/core/contracts/interfaces/IMessageRecipient.sol";
import {TypeCasts} from "@hyperlane-xyz/core/contracts/libs/TypeCasts.sol";
import {MessageBridgeProver} from "./MessageBridgeProver.sol";
import {Semver} from "../libs/Semver.sol";
import {IMailbox, IPostDispatchHook} from "@hyperlane-xyz/core/contracts/interfaces/IMailbox.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title HyperProver
 * @notice Prover implementation using Hyperlane's cross-chain messaging system
 * @notice the terms "source" and "destination" are used in reference to a given intent: created on source chain, fulfilled on destination chain
 * @dev Processes proof messages from Hyperlane mailbox and records proven intents
 */
contract HyperProver is IMessageRecipient, MessageBridgeProver, Semver {
    using TypeCasts for bytes32;
    using SafeCast for uint256;

    /**
     * @notice Struct for unpacked data from _data parameter
     * @dev Only contains fields decoded from the _data parameter
     */
    struct UnpackedData {
        bytes32 sourceChainProver; // Address of prover on source chain
        bytes metadata; // Metadata for Hyperlane message
        address hookAddr; // Address of post-dispatch hook
    }

    // Rarichain uses a different domain ID than its chain ID, representing an edge case
    uint32 public constant RARICHAIN_CHAIN_ID = 1380012617;
    uint32 public constant RARICHAIN_DOMAIN_ID = 1000012617;

    /**
     * @notice Struct for Hyperlane dispatch parameters
     * @dev Consolidates message dispatch parameters to reduce stack usage
     */
    struct DispatchParams {
        uint32 destinationDomain; // Hyperlane domain ID
        bytes32 recipientAddress; // Recipient address encoded as bytes32
        bytes messageBody; // Encoded message body with intent hashes and claimants
        bytes metadata; // Additional metadata for the message
        IPostDispatchHook hook; // Post-dispatch hook contract
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
     * @param _provers Array of trusted prover addresses (as bytes32 for cross-VM compatibility)
     * @param _defaultGasLimit Default gas limit for cross-chain messages (200k if not specified)
     */
    constructor(
        address _mailbox,
        address _inbox,
        bytes32[] memory _provers,
        uint256 _defaultGasLimit
    ) MessageBridgeProver(_inbox, _provers, _defaultGasLimit) {
        if (_mailbox == address(0)) revert MailboxCannotBeZeroAddress();
        MAILBOX = _mailbox;
    }

    /**
     * @notice Handles incoming Hyperlane messages containing proof data
     * @dev called by the Hyperlane mailbox on the source chain
     * @dev Processes batch updates to proven intents from valid sources
     * @param _origin DomainID of the destination chain
     * @param _sender Address that dispatched the message on destination chain
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
        if (_origin == 0) revert InvalidOriginChainId();

        // Validate sender is not zero
        if (_sender == bytes32(0)) revert SenderCannotBeZeroAddress();

        if (_origin == RARICHAIN_DOMAIN_ID) {
            _handleCrossChainMessage(RARICHAIN_CHAIN_ID, _sender, _messageBody);
        } else {
            _handleCrossChainMessage(_origin, _sender, _messageBody);
        }
    }

    /**
     * @notice Initiates proving of intents via Hyperlane
     * @dev Sends message to source chain prover with intent data
     * @dev called by the Inbox contract on the destination chain
     * @param _sender Address that initiated the proving request
     * @param _sourceChainId Chain ID of the source chain
     * @param _intentHashes Array of intent hashes to prove
     * @param _claimants Array of claimant addresses
     * @param _data Additional data for message formatting
     */
    function prove(
        address _sender,
        uint256 _sourceChainId,
        bytes32[] calldata _intentHashes,
        address[] calldata _claimants,
        bytes calldata _data
    ) external payable override {
        // Validate the request is from Inbox
        _validateProvingRequest(msg.sender);

        // Parse incoming data into a structured format for processing
        UnpackedData memory unpacked = _unpackData(_data);

        // Calculate fee
        uint256 fee = _fetchFee(
            _sourceChainId,
            _intentHashes,
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

        emit BatchSent(_intentHashes, _sourceChainId);

        // Prepare parameters for cross-chain message dispatch using a struct
        // to reduce stack usage and improve code maintainability
        DispatchParams memory params = _formatHyperlaneMessage(
            _sourceChainId,
            _intentHashes,
            _claimants,
            unpacked
        );

        // Send the message through Hyperlane mailbox using params from the struct
        // Note: Some Hyperlane versions have different dispatch signatures.
        // This matches the expected signature for testing.
        IMailbox(MAILBOX).dispatch{value: fee}(
            params.destinationDomain,
            params.recipientAddress,
            params.messageBody,
            params.metadata,
            params.hook
        );

        // Send refund if needed
        _sendRefund(_sender, _refundAmount);
    }

    /**
     * @notice Calculates the fee required for Hyperlane message dispatch
     * @dev Queries the Mailbox contract for accurate fee estimation
     * @param _sourceChainId Chain ID of the source chain
     * @param _intentHashes Array of intent hashes to prove
     * @param _claimants Array of claimant addresses
     * @param _data Additional data for message formatting
     * @return Fee amount required for message dispatch
     */
    function fetchFee(
        uint256 _sourceChainId,
        bytes32[] calldata _intentHashes,
        address[] calldata _claimants,
        bytes calldata _data
    ) public view override returns (uint256) {
        // Decode structured data from the raw input
        UnpackedData memory unpacked = _unpackData(_data);

        // Process fee calculation using the decoded struct
        // This architecture separates decoding from core business logic
        return _fetchFee(_sourceChainId, _intentHashes, _claimants, unpacked);
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
     * @param _sourceChainID Chain ID of the source chain
     * @param _intentHashes Array of intent hashes to prove
     * @param _claimants Array of claimant addresses
     * @param unpacked Struct containing decoded data from _data parameter
     * @return Fee amount required for message dispatch
     */
    function _fetchFee(
        uint256 _sourceChainID,
        bytes32[] calldata _intentHashes,
        address[] calldata _claimants,
        UnpackedData memory unpacked
    ) internal view returns (uint256) {
        // Format and prepare message parameters for dispatch
        DispatchParams memory params = _formatHyperlaneMessage(
            _sourceChainID,
            _intentHashes,
            _claimants,
            unpacked
        );

        // Query Hyperlane mailbox for accurate fee estimate
        return
            IMailbox(MAILBOX).quoteDispatch(
                params.destinationDomain,
                params.recipientAddress,
                params.messageBody,
                params.metadata,
                params.hook
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
     * @param _sourceChainID Chain ID of the source chain
     * @param _hashes Array of intent hashes to prove
     * @param _claimants Array of claimant addresses
     * @param _unpacked Struct containing decoded data from _data parameter
     * @return params Structured dispatch parameters for Hyperlane message
     */
    function _formatHyperlaneMessage(
        uint256 _sourceChainID,
        bytes32[] calldata _hashes,
        address[] calldata _claimants,
        UnpackedData memory _unpacked
    ) internal view returns (DispatchParams memory params) {
        // Centralized validation ensures arrays match exactly once in the call flow
        // This prevents security issues where hashes and claimants could be mismatched
        if (_hashes.length != _claimants.length) {
            revert ArrayLengthMismatch();
        }

        // Convert chain ID to domain
        params.destinationDomain = _convertChainID(_sourceChainID);

        // Use the source chain prover address as the message recipient
        params.recipientAddress = _unpacked.sourceChainProver;

        // Pack intent hashes and claimant addresses together as the message payload
        params.messageBody = abi.encode(_hashes, _claimants);

        // Pass through metadata as provided
        params.metadata = _unpacked.metadata;

        // Default to mailbox's hook if none provided, following Hyperlane best practices
        params.hook = (_unpacked.hookAddr == address(0))
            ? IMailbox(MAILBOX).defaultHook()
            : IPostDispatchHook(_unpacked.hookAddr);
    }

    function _convertChainID(uint256 _chainID) internal pure returns (uint32) {
        if (_chainID == RARICHAIN_CHAIN_ID) {
            return RARICHAIN_DOMAIN_ID;
        }
        return _chainID.toUint32();
    }
}
