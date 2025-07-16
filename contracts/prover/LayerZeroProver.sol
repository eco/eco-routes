// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILayerZeroReceiver} from "../interfaces/layerzero/ILayerZeroReceiver.sol";
import {ILayerZeroEndpointV2} from "../interfaces/layerzero/ILayerZeroEndpointV2.sol";
import {MessageBridgeProver} from "./MessageBridgeProver.sol";
import {Semver} from "../libs/Semver.sol";

/**
 * @title LayerZeroProver
 * @notice Prover implementation using LayerZero's cross-chain messaging system
 * @dev Processes proof messages from LayerZero endpoint and records proven intents
 */
contract LayerZeroProver is ILayerZeroReceiver, MessageBridgeProver, Semver {
    /**
     * @notice Struct for unpacked data from _data parameter
     * @dev Contains fields decoded from the _data parameter
     */
    struct UnpackedData {
        bytes32 sourceChainProver; // Address of prover on source chain
        bytes options; // LayerZero message options
        uint256 gasLimit; // Gas limit for execution
    }

    /**
     * @notice Struct for LayerZero dispatch parameters
     * @dev Consolidates message dispatch parameters to reduce stack usage
     */
    struct DispatchParams {
        uint32 destinationEid; // LayerZero endpoint ID
        bytes32 recipientAddress; // Recipient address encoded as bytes32
        bytes messageBody; // Encoded message body with intent hashes and claimants
        bytes options; // LayerZero execution options
        bool payInLzToken; // Whether to pay in LZ token
    }

    /**
     * @notice Constant indicating this contract uses LayerZero for proving
     */
    string public constant PROOF_TYPE = "LayerZero";

    /**
     * @notice Address of local LayerZero endpoint
     */
    address public immutable ENDPOINT;

    /**
     * @notice LayerZero endpoint address cannot be zero
     */
    error EndpointCannotBeZeroAddress();

    /**
     * @notice Invalid executor address
     * @param executor The invalid executor address
     */
    error InvalidExecutor(address executor);

    /**
     * @param endpoint Address of local LayerZero endpoint
     * @param portal Address of Portal contract
     * @param provers Array of trusted prover addresses (as bytes32 for cross-VM compatibility)
     * @param defaultGasLimit Default gas limit for cross-chain messages (200k if not specified)
     */
    constructor(
        address endpoint,
        address portal,
        bytes32[] memory provers,
        uint256 defaultGasLimit
    ) MessageBridgeProver(portal, provers, defaultGasLimit) {
        if (endpoint == address(0)) revert EndpointCannotBeZeroAddress();
        ENDPOINT = endpoint;
    }

    /**
     * @notice Handles incoming LayerZero messages containing proof data
     * @dev Processes batch updates to proven intents from valid sources
     * @param origin Origin information containing source endpoint and sender
     * @param message Encoded array of intent hashes and claimants
     * @param executor Address of the executor (should be endpoint or zero)
     */
    function lzReceive(
        Origin calldata origin,
        bytes32 /* guid */,
        bytes calldata message,
        address executor,
        bytes calldata /* extraData */
    ) external payable override {
        // Verify message is from authorized endpoint
        _validateMessageSender(msg.sender, ENDPOINT);

        // Verify executor is valid (either endpoint or zero address)
        if (executor != address(0) && executor != ENDPOINT) {
            revert InvalidExecutor(executor);
        }

        // Use endpoint ID directly as chain ID
        uint256 originChainId = uint256(origin.srcEid);

        // Validate sender is not zero
        if (origin.sender == bytes32(0)) {
            revert SenderCannotBeZeroAddress();
        }

        _handleCrossChainMessage(originChainId, origin.sender, message);
    }

    /**
     * @notice Check if path is allowed for receiving messages
     * @param origin Origin information to check
     * @return Whether the origin is allowed
     */
    function allowInitializePath(
        Origin calldata origin
    ) external view override returns (bool) {
        // Check if sender is whitelisted
        return isWhitelisted(origin.sender);
    }

    /**
     * @notice Get next expected nonce from a source
     * @dev Always returns 0 as we don't track nonces
     * @return Always returns 0 as we don't track nonces
     */
    function nextNonce(
        uint32 /* srcEid */,
        bytes32 /* sender */
    ) external pure override returns (uint64) {
        // We don't track nonces, return 0
        return 0;
    }

    /**
     * @notice Implementation of message dispatch for LayerZero
     * @dev Called by base prove() function after common validations
     * @param sourceChainId Chain ID of the source chain
     * @param intentHashes Array of intent hashes to prove
     * @param claimants Array of claimant addresses
     * @param data Additional data for message formatting
     * @param fee Fee amount for message dispatch
     */
    function _dispatchMessage(
        uint256 sourceChainId,
        bytes32[] calldata intentHashes,
        bytes32[] calldata claimants,
        bytes calldata data,
        uint256 fee
    ) internal override {
        // Parse incoming data into a structured format
        UnpackedData memory unpacked = _unpackData(data);

        // Prepare parameters for cross-chain message dispatch
        DispatchParams memory params = _formatLayerZeroMessage(
            sourceChainId,
            intentHashes,
            claimants,
            unpacked
        );

        // Create messaging parameters for LayerZero
        ILayerZeroEndpointV2.MessagingParams
            memory lzParams = ILayerZeroEndpointV2.MessagingParams({
                dstEid: params.destinationEid,
                receiver: params.recipientAddress,
                message: params.messageBody,
                options: params.options,
                payInLzToken: params.payInLzToken
            });

        // Send the message through LayerZero endpoint
        // solhint-disable-next-line check-send-result
        ILayerZeroEndpointV2(ENDPOINT).send{value: fee}(
            lzParams,
            msg.sender // refund address
        );
    }

    /**
     * @notice Calculates the fee required for LayerZero message dispatch
     * @dev Queries the Endpoint contract for accurate fee estimation
     * @param sourceChainId Chain ID of the source chain
     * @param intentHashes Array of intent hashes to prove
     * @param claimants Array of claimant addresses (as bytes32 for cross-chain compatibility)
     * @param data Additional data for message formatting
     * @return Fee amount required for message dispatch
     */
    function fetchFee(
        uint256 sourceChainId,
        bytes32[] calldata intentHashes,
        bytes32[] calldata claimants,
        bytes calldata data
    ) public view override returns (uint256) {
        // Decode structured data from the raw input
        UnpackedData memory unpacked = _unpackData(data);

        // Process fee calculation using the decoded struct
        return _fetchFee(sourceChainId, intentHashes, claimants, unpacked);
    }

    /**
     * @notice Decodes the raw cross-chain message data into a structured format
     * @dev Parses ABI-encoded parameters into the UnpackedData struct
     * @param data Raw message data containing source chain information
     * @return unpacked Structured representation of the decoded parameters
     */
    function _unpackData(
        bytes calldata data
    ) internal view returns (UnpackedData memory unpacked) {
        // Decode basic parameters
        (unpacked.sourceChainProver, unpacked.options) = abi.decode(
            data,
            (bytes32, bytes)
        );

        // Extract gas limit if provided in data
        unpacked.gasLimit = DEFAULT_GAS_LIMIT;
        if (data.length >= 96) {
            // Gas limit is at position 64-96 if provided
            unpacked.gasLimit = uint256(bytes32(data[64:96]));
            if (unpacked.gasLimit == 0) {
                unpacked.gasLimit = DEFAULT_GAS_LIMIT;
            }
        }

        return unpacked;
    }

    /**
     * @notice Internal function to calculate the fee with pre-decoded data
     * @param sourceChainId Chain ID of the source chain
     * @param intentHashes Array of intent hashes to prove
     * @param claimants Array of claimant addresses (as bytes32 for cross-chain compatibility)
     * @param unpacked Struct containing decoded data from data parameter
     * @return Fee amount required for message dispatch
     */
    function _fetchFee(
        uint256 sourceChainId,
        bytes32[] calldata intentHashes,
        bytes32[] calldata claimants,
        UnpackedData memory unpacked
    ) internal view returns (uint256) {
        // Format and prepare message parameters for dispatch
        DispatchParams memory params = _formatLayerZeroMessage(
            sourceChainId,
            intentHashes,
            claimants,
            unpacked
        );

        // Create messaging parameters for quote
        ILayerZeroEndpointV2.MessagingParams
            memory lzParams = ILayerZeroEndpointV2.MessagingParams({
                dstEid: params.destinationEid,
                receiver: params.recipientAddress,
                message: params.messageBody,
                options: params.options,
                payInLzToken: params.payInLzToken
            });

        // Query LayerZero endpoint for accurate fee estimate
        ILayerZeroEndpointV2.MessagingFee memory fee = ILayerZeroEndpointV2(
            ENDPOINT
        ).quote(
                lzParams,
                false // payInLzToken
            );

        return fee.nativeFee;
    }

    /**
     * @notice Returns the proof type used by this prover
     * @return ProofType indicating LayerZero proving mechanism
     */
    function getProofType() external pure override returns (string memory) {
        return PROOF_TYPE;
    }

    /**
     * @notice Formats data for LayerZero message dispatch with pre-decoded values
     * @dev Prepares all parameters needed for the Endpoint send call
     * @param sourceChainId Chain ID of the source chain
     * @param hashes Array of intent hashes to prove
     * @param claimants Array of claimant addresses (as bytes32 for cross-chain compatibility)
     * @param unpacked Struct containing decoded data from data parameter
     * @return params Structured dispatch parameters for LayerZero message
     */
    function _formatLayerZeroMessage(
        uint256 sourceChainId,
        bytes32[] calldata hashes,
        bytes32[] calldata claimants,
        UnpackedData memory unpacked
    ) internal pure returns (DispatchParams memory params) {
        // Centralized validation ensures arrays match exactly once in the call flow
        _validateArrayLengths(hashes, claimants);

        // Use source chain ID directly as endpoint ID
        // Validate it fits in uint32
        _validateChainId(sourceChainId);
        params.destinationEid = uint32(sourceChainId);

        // Use the source chain prover address as the message recipient
        params.recipientAddress = unpacked.sourceChainProver;

        // Pack intent hashes and claimant addresses together as the message payload
        params.messageBody = abi.encode(hashes, claimants);

        // Use provided options or create default options with gas limit
        if (unpacked.options.length > 0) {
            params.options = unpacked.options;
        } else {
            // Create default options with gas limit
            // Option type 3 is for gas limit
            params.options = abi.encodePacked(
                uint16(3), // option type
                unpacked.gasLimit // gas amount
            );
        }

        // Default to paying in native token
        params.payInLzToken = false;
    }
}
