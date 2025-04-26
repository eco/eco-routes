// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMetalayerRecipient, ReadOperation} from "@metalayer/contracts/src/interfaces/IMetalayerRecipient.sol";
import {FinalityState} from "@metalayer/contracts/src/lib/MetalayerMessage.sol";
import {TypeCasts} from "@hyperlane-xyz/core/contracts/libs/TypeCasts.sol";
import {MessageBridgeProver} from "./MessageBridgeProver.sol";
// Import Semver for versioning support
import {Semver} from "../libs/Semver.sol";
import {IMetalayerRouter} from "@metalayer/contracts/src/interfaces/IMetalayerRouter.sol";

/**
 * @title MetaProver
 * @notice Prover implementation using Caldera Metalayer's cross-chain messaging system
 * @dev Processes proof messages from Metalayer router and records proven intents
 */
contract MetaProver is IMetalayerRecipient, MessageBridgeProver, Semver {
    using TypeCasts for bytes32;
    using TypeCasts for address;

    /**
     * @notice Constant indicating this contract uses Metalayer for proving
     */
    string public constant PROOF_TYPE = "Metalayer";


    /**
     * @notice Address of local Metalayer router
     */
    address public immutable ROUTER;

    /**
     * @notice Initializes the MetaProver contract
     * @param _router Address of local Metalayer router
     * @param _inbox Address of Inbox contract
     * @param _provers Array of trusted provers to whitelist
     * @param _defaultGasLimit Default gas limit for cross-chain messages (200k if not specified)
     */
    constructor(
        address _router,
        address _inbox,
        TrustedProver[] memory _provers,
        uint256 _defaultGasLimit
    ) MessageBridgeProver(_inbox, _provers, _defaultGasLimit) {
        require(_router != address(0), "Router cannot be zero address");
        ROUTER = _router;
    }

    /**
     * @notice Handles incoming Metalayer messages containing proof data
     * @dev Processes batch updates to proven intents from valid sources
     * @param _origin Origin chain ID from the source chain
     * @param _sender Address that dispatched the message on source chain
     * @param _message Encoded array of intent hashes and claimants
     */
    function handle(
        uint32 _origin,
        bytes32 _sender,
        bytes calldata _message,
        ReadOperation[] calldata /* _operations */,
        bytes[] calldata /* _operationsData */
    ) external payable {
        // Verify message is from authorized router
        _validateMessageSender(msg.sender, ROUTER);

        // Verify _origin and _sender are valid
        require(_origin > 0, "Invalid origin chain ID");

        // Convert bytes32 sender to address and delegate to shared handler
        address sender = _sender.bytes32ToAddress();
        require(sender != address(0), "Sender cannot be zero address");

        _handleCrossChainMessage(_origin, sender, _message);
    }

    /**
     * @notice Initiates proving of intents via Metalayer
     * @dev Sends message to source chain prover with intent data
     * @param _sender Address that initiated the proving request
     * @param _sourceChainId Chain ID of source chain
     * @param _intentHashes Array of intent hashes to prove
     * @param _claimants Array of claimant addresses
     * @param _data Additional data for message formatting
     */
    function sendProof(
        address _sender,
        uint256 _sourceChainId,
        bytes32[] calldata _intentHashes,
        address[] calldata _claimants,
        bytes calldata _data
    ) external payable override {
        // Validate the request is from Inbox
        _validateProvingRequest(msg.sender);

        // Decode source chain prover address only once
        bytes32 sourceChainProver = abi.decode(_data, (bytes32));

        // Calculate fee with pre-decoded value
        uint256 fee = _fetchFee(
            _sourceChainId,
            _intentHashes,
            _claimants,
            sourceChainProver
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

        // Decode any additional gas limit data from the _data parameter
        uint256 gasLimit = DEFAULT_GAS_LIMIT;

        // For Metalayer, we expect data to include sourceChainProver(32 bytes)
        // If data is long enough, the gas limit is packed at position 32-64
        if (_data.length >= 64) {
            uint256 customGasLimit = uint256(bytes32(_data[32:64]));
            if (customGasLimit > 0) {
                gasLimit = customGasLimit;
            }
        }

        // Format message for dispatch using pre-decoded value
        (
            uint32 domain,
            bytes32 recipient,
            bytes memory message
        ) = _formatMetalayerMessage(
                _sourceChainId,
                _intentHashes,
                _claimants,
                sourceChainProver
            );

        // Call Metalayer router's send message function
        IMetalayerRouter(ROUTER).dispatch{value: fee}(
            domain,
            recipient,
            new ReadOperation[](0),
            message,
            FinalityState.INSTANT,
            gasLimit
        );

        // Send refund if needed
        _sendRefund(_sender, _refundAmount);
    }

    /**
     * @notice Fetches fee required for message dispatch
     * @dev Queries Metalayer router for fee information
     * @param _sourceChainId Chain ID of source chain
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
        // Decode source chain prover once at the entry point
        bytes32 sourceChainProver = abi.decode(_data, (bytes32));

        // Delegate to internal function with pre-decoded value
        return
            _fetchFee(
                _sourceChainId,
                _intentHashes,
                _claimants,
                sourceChainProver
            );
    }

    /**
     * @notice Internal function to calculate fee with pre-decoded data
     * @param _sourceChainId Chain ID of source chain
     * @param _intentHashes Array of intent hashes to prove
     * @param _claimants Array of claimant addresses
     * @param _sourceChainProver Pre-decoded prover address on source chain
     * @return Fee amount required for message dispatch
     */
    function _fetchFee(
        uint256 _sourceChainId,
        bytes32[] calldata _intentHashes,
        address[] calldata _claimants,
        bytes32 _sourceChainProver
    ) internal view returns (uint256) {
        (
            uint32 domain,
            bytes32 recipient,
            bytes memory message
        ) = _formatMetalayerMessage(
                _sourceChainId,
                _intentHashes,
                _claimants,
                _sourceChainProver
            );

        return
            IMetalayerRouter(ROUTER).quoteDispatch(domain, recipient, message);
    }

    /**
     * @notice Returns the proof type used by this prover
     * @return ProofType indicating Metalayer proving mechanism
     */
    function getProofType() external pure override returns (string memory) {
        return PROOF_TYPE;
    }

    /**
     * @notice Formats data for Metalayer message dispatch with pre-decoded values
     * @param _sourceChainId Chain ID of the source chain
     * @param _hashes Array of intent hashes to prove
     * @param _claimants Array of claimant addresses
     * @param _sourceChainProver Pre-decoded prover address on source chain
     * @return domain Metalayer domain ID
     * @return recipient Recipient address encoded as bytes32
     * @return message Encoded message body with intent hashes and claimants
     */
    function _formatMetalayerMessage(
        uint256 _sourceChainId,
        bytes32[] calldata _hashes,
        address[] calldata _claimants,
        bytes32 _sourceChainProver
    )
        internal
        pure
        returns (uint32 domain, bytes32 recipient, bytes memory message)
    {
        // Centralized validation ensures arrays match exactly once in the call flow
        if (_hashes.length != _claimants.length) {
            revert ArrayLengthMismatch();
        }

        // Convert chain ID to Metalayer domain format
        // Validate the chain ID can fit in uint32 to prevent truncation issues
        if (_sourceChainId > type(uint32).max) {
            revert ChainIdTooLarge(_sourceChainId);
        }
        domain = uint32(_sourceChainId);

        // Use pre-decoded source chain prover address as recipient
        recipient = _sourceChainProver;

        // Pack intent hashes and claimant addresses together as message payload
        message = abi.encode(_hashes, _claimants);
    }
}
