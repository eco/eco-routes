// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMetalayerRecipient, ReadOperation} from "@metalayer/contracts/src/interfaces/IMetalayerRecipient.sol";
import {FinalityState} from "@metalayer/contracts/src/lib/MetalayerMessage.sol";
import {TypeCasts} from "@hyperlane-xyz/core/contracts/libs/TypeCasts.sol";
import {MessageBridgeProver} from "./MessageBridgeProver.sol";
// Import Semver for versioning support
import {Semver} from "../libs/Semver.sol";
import {IMetalayerRouter} from "@metalayer/contracts/src/interfaces/IMetalayerRouter.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title MetaProver
 * @notice Prover implementation using Caldera Metalayer's cross-chain messaging system
 * @notice the terms "source" and "destination" are used in reference to a given intent: created on source chain, fulfilled on destination chain
 * @dev Processes proof messages from Metalayer router and records proven intents
 */
contract MetaProver is IMetalayerRecipient, MessageBridgeProver, Semver {
    using TypeCasts for bytes32;
    using TypeCasts for address;
    using SafeCast for uint256;

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
     * @param router Address of local Metalayer router
     * @param portal Address of Portal contract
     * @param provers Array of trusted prover addresses (as bytes32 for cross-VM compatibility)
     * @param defaultGasLimit Default gas limit for cross-chain messages (200k if not specified)
     */
    constructor(
        address router,
        address portal,
        bytes32[] memory provers,
        uint256 defaultGasLimit
    ) MessageBridgeProver(portal, provers, defaultGasLimit) {
        if (router == address(0)) revert RouterCannotBeZeroAddress();
        ROUTER = router;
    }

    /**
     * @notice Handles incoming Metalayer messages containing proof data
     * @dev Processes batch updates to proven intents from valid sources
     * @dev called by the Metalayer Router on the source chain
     * @param origin Origin chain ID from the destination chain
     * @param sender Address that dispatched the message on destination chain
     * @param message Encoded array of intent hashes and claimants
     */
    function handle(
        uint32 origin,
        bytes32 sender,
        bytes calldata message,
        ReadOperation[] calldata /* operations */,
        bytes[] calldata /* operationsData */
    ) external payable {
        // Verify message is from authorized router
        _validateMessageSender(msg.sender, ROUTER);

        // Verify origin and sender are valid
        if (origin == 0) revert InvalidOriginChainId();

        // Validate sender is not zero
        if (sender == bytes32(0)) revert SenderCannotBeZeroAddress();

        _handleCrossChainMessage(origin, sender, message);
    }

    /**
     * @notice Implementation of message dispatch for Metalayer
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
        // Decode source chain prover address only once
        bytes32 sourceChainProver = abi.decode(data, (bytes32));

        // Decode any additional gas limit data from the data parameter
        uint256 gasLimit = DEFAULT_GAS_LIMIT;

        // For Metalayer, we expect data to include sourceChainProver(32 bytes)
        // If data is long enough, the gas limit is packed at position 64-96
        // will only use custom gas limit if it is greater than the default
        if (data.length >= 64) {
            uint256 customGasLimit = uint256(bytes32(data[32:64]));
            if (customGasLimit > DEFAULT_GAS_LIMIT) {
                gasLimit = customGasLimit;
            }
        }

        // Format message for dispatch using pre-decoded value
        (
            uint32 sourceChainDomain,
            bytes32 recipient,
            bytes memory message
        ) = _formatMetalayerMessage(
                sourceChainId,
                intentHashes,
                claimants,
                sourceChainProver
            );

        // Call Metalayer router's send message function
        IMetalayerRouter(ROUTER).dispatch{value: fee}(
            sourceChainDomain,
            recipient,
            new ReadOperation[](0),
            message,
            FinalityState.INSTANT,
            gasLimit
        );
    }

    /**
     * @notice Fetches fee required for message dispatch
     * @dev Queries Metalayer router for fee information
     * @param sourceChainID Chain ID of source chain
     * @param intentHashes Array of intent hashes to prove
     * @param claimants Array of claimant addresses (as bytes32 for cross-chain compatibility) (as bytes32 for cross-chain compatibility)
     * @param data Additional data for message formatting
     * @return Fee amount required for message dispatch
     */
    function fetchFee(
        uint256 sourceChainID,
        bytes32[] calldata intentHashes,
        bytes32[] calldata claimants,
        bytes calldata data
    ) public view override returns (uint256) {
        // Decode source chain prover once at the entry point
        bytes32 sourceChainProver = abi.decode(data, (bytes32));

        // Delegate to internal function with pre-decoded value
        return
            _fetchFee(
                sourceChainID,
                intentHashes,
                claimants,
                sourceChainProver
            );
    }

    /**
     * @notice Internal function to calculate fee with pre-decoded data
     * @param sourceChainID Chain ID of source chain
     * @param intentHashes Array of intent hashes to prove
     * @param claimants Array of claimant addresses (as bytes32 for cross-chain compatibility) (as bytes32 for cross-chain compatibility)
     * @param sourceChainProver Pre-decoded prover address on source chain
     * @return Fee amount required for message dispatch
     */
    function _fetchFee(
        uint256 sourceChainID,
        bytes32[] calldata intentHashes,
        bytes32[] calldata claimants,
        bytes32 sourceChainProver
    ) internal view returns (uint256) {
        (
            uint32 sourceChainDomain,
            bytes32 recipient,
            bytes memory message
        ) = _formatMetalayerMessage(
                sourceChainID,
                intentHashes,
                claimants,
                sourceChainProver
            );

        return
            IMetalayerRouter(ROUTER).quoteDispatch(
                sourceChainDomain,
                recipient,
                message
            );
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
     * @param sourceChainID Chain ID of the source chain
     * @param hashes Array of intent hashes to prove
     * @param claimants Array of claimant addresses (as bytes32 for cross-chain compatibility)
     * @param sourceChainProver Pre-decoded prover address on source chain
     * @return domain Metalayer domain ID
     * @return recipient Recipient address encoded as bytes32
     * @return message Encoded message body with intent hashes and claimants
     */
    function _formatMetalayerMessage(
        uint256 sourceChainID,
        bytes32[] calldata hashes,
        bytes32[] calldata claimants,
        bytes32 sourceChainProver
    )
        internal
        pure
        returns (uint32 domain, bytes32 recipient, bytes memory message)
    {
        // Centralized validation ensures arrays match exactly once in the call flow
        _validateArrayLengths(hashes, claimants);

        // Convert and validate chain ID to domain
        domain = _validateChainId(sourceChainID);

        // Use pre-decoded source chain prover address as recipient
        recipient = sourceChainProver;

        // Pack intent hashes and claimant addresses together as message payload
        message = abi.encode(hashes, claimants);
    }
}
