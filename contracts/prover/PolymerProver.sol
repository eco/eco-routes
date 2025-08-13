// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseProver} from "./BaseProver.sol";
import {Semver} from "../libs/Semver.sol";
import {ICrossL2ProverV2} from "../interfaces/ICrossL2ProverV2.sol";
import {IProver} from "../interfaces/IProver.sol";

/**
 * @title PolyNativeProver
 * @notice Prover implementation using Polymer's cross-chain messaging system
 * @dev Processes proof messages from Polymer's CrossL2ProverV2 and records proven intents
 */
contract PolyNativeProver is BaseProver, Semver {
    // Constants
    string public constant PROOF_TYPE = "Polymer";
    bytes32 public constant PROOF_SELECTOR =
        keccak256("IntentFulfilledFromSource(bytes32,bytes32,uint64)");

    // Events
    event IntentFulfilledFromSource(bytes32 indexed intentHash, bytes32 indexed claimant, uint64 destination);

    // Errors
    error InvalidEventSignature();
    error InvalidEmittingContract();
    error InvalidTopicsLength();
    error ZeroAddress();
    error SizeMismatch();
    error OnlyPortal();

    // Immutable state variables
    ICrossL2ProverV2 public immutable CROSS_L2_PROVER_V2;


    /**
     * @notice Initializes the PolyNativeProver contract
     * @param _crossL2ProverV2 Address of the Polymer CrossL2ProverV2 contract
     * @param _portal Address of the Portal contract
     */
    constructor(
        address _crossL2ProverV2,
        address _portal
    ) BaseProver(_portal) {
        if (_crossL2ProverV2 == address(0)) revert ZeroAddress();

        CROSS_L2_PROVER_V2 = ICrossL2ProverV2(_crossL2ProverV2);
    }

    // ------------- STANDARD PROOF VALIDATION -------------

    /**
     * @notice Validates a single proof
     * @param proof The proof data for CROSS_L2_PROVER_V2 to validate
     */
    function validate(bytes calldata proof) external {
        (bytes32 intentHash, address claimant, uint32 destinationChainId) = _validateProof(proof);
        processIntent(intentHash, claimant, destinationChainId);
    }


    /**
     * @notice Validates multiple proofs in a batch
     * @param proofs Array of proof data to validate
     */
    function validateBatch(bytes[] calldata proofs) external {
        for (uint256 i = 0; i < proofs.length; i++) {
            (bytes32 intentHash, address claimant, uint32 destinationChainId) = _validateProof(proofs[i]);
            processIntent(intentHash, claimant, destinationChainId);
        }
    }

    // ------------- INTERNAL FUNCTIONS - PROOF VALIDATION -------------

    /**
     * @notice Core proof validation logic
     * @param proof The proof data to validate
     * @return intentHash Hash of the proven intent
     * @return claimant Address that fulfilled the intent
     * @return chainId Chain ID where the event was emitted
     */
    function _validateProof(
        bytes calldata proof
    ) internal view returns (bytes32 intentHash, address claimant, uint32 chainId) {
        (
            uint32 destinationChainId,
            address emittingContract,
            bytes memory topics,
            /* bytes memory data */
        ) = CROSS_L2_PROVER_V2.validateEvent(proof);

        checkProverContract(emittingContract);
        checkTopicLength(topics, 128); // 4 topics: signature + hash + claimant + sourceChainId

        bytes32[] memory topicsArray = new bytes32[](4);

        assembly {
            let topicsPtr := add(topics, 32)
            let arrayPtr := add(topicsArray, 32)

            mstore(arrayPtr, mload(topicsPtr))
            mstore(add(arrayPtr, 32), mload(add(topicsPtr, 32)))
            mstore(add(arrayPtr, 64), mload(add(topicsPtr, 64)))
            mstore(add(arrayPtr, 96), mload(add(topicsPtr, 96)))
        }

        checkTopicSignature(topicsArray[0], PROOF_SELECTOR);
        // Convert bytes32 claimant to address
        claimant = address(uint160(uint256(topicsArray[2])));
        // Get sourceChainId from event topic and verify it matches current chain
        uint64 eventSourceChainId = uint64(uint256(topicsArray[3]));
        if (eventSourceChainId != block.chainid) revert InvalidEmittingContract();

        return (topicsArray[1], claimant, destinationChainId);
    }

    // ------------- INTERNAL FUNCTIONS - INTENT PROCESSING -------------

    /**
     * @notice Processes a single intent proof
     * @param intentHash Hash of the intent being proven
     * @param claimant Address that fulfilled the intent and should receive rewards
     */
    function processIntent(bytes32 intentHash, address claimant, uint256 destination) internal {
        ProofData storage proof = _provenIntents[intentHash];
        if (proof.claimant != address(0)) {
            emit IntentAlreadyProven(intentHash);
        } else {
            proof.claimant = claimant;
            proof.destination = uint64(destination);
            emit IntentProven(intentHash, claimant, uint64(destination));
        }
    }

    // ------------- UTILITY FUNCTIONS -------------

    /**
     * @notice Decodes a message body into intent hashes and claimants for claiming
     * @param messageBody The message body to decode
     * @param expectedSize Expected number of intents to decode
     * @return intentHashes Array of decoded intent hashes
     * @return claimants Array of corresponding claimant addresses
     */
    function decodeMessageBeforeClaim(
        bytes memory messageBody,
        uint256 expectedSize
    )
        public
        pure
        returns (bytes32[] memory intentHashes, address[] memory claimants)
    {
        uint256 size = messageBody.length;
        uint256 offset = 0;
        uint256 totalIntentCount = 0;

        intentHashes = new bytes32[](expectedSize);
        claimants = new address[](expectedSize);

        while (offset < size) {
            if (offset + 2 > size) revert("truncated chunkSize");
            uint16 chunkSize;
            assembly {
                chunkSize := mload(add(messageBody, add(offset, 2)))
                offset := add(offset, 2)
            }

            if (offset + 20 > size) revert("truncated claimant address");
            address claimant;
            assembly {
                claimant := mload(add(messageBody, add(offset, 20)))
                offset := add(offset, 20)
            }

            if (offset + 32 * chunkSize > size) revert("truncated intent set");
            bytes32 intentHash;
            for (uint16 i = 0; i < chunkSize; i++) {
                assembly {
                    intentHash := mload(add(messageBody, add(offset, 32)))
                    offset := add(offset, 32)
                }
                intentHashes[totalIntentCount] = intentHash;
                claimants[totalIntentCount] = claimant;
                totalIntentCount++;
            }
        }

        if (totalIntentCount != expectedSize) revert SizeMismatch();
        return (intentHashes, claimants);
    }

    // ------------- INTERNAL FUNCTIONS - VALIDATION HELPERS -------------

    /**
     * @notice Validates that a topic signature matches the expected selector
     * @param topic The topic signature to check
     * @param selector The expected selector
     */
    function checkTopicSignature(
        bytes32 topic,
        bytes32 selector
    ) internal pure {
        if (topic != selector) revert InvalidEventSignature();
    }

    /**
     * @notice Validates that the emitting contract is this prover contract
     * @notice This expects that the PolymerProver contract on the destination the same address as on source
     * @param emittingContract The contract that emitted the event
     */
    function checkProverContract(address emittingContract) internal view {
        if (emittingContract != address(this)) revert InvalidEmittingContract();
    }



    /**
     * @notice Validates that the topics have the expected length
     * @param topics The topics to check
     * @param length The expected length
     */
    function checkTopicLength(
        bytes memory topics,
        uint256 length
    ) internal pure {
        if (topics.length != length) revert InvalidTopicsLength();
    }

    // ------------- INTERFACE IMPLEMENTATION -------------

    /**
     * @notice Returns the proof type used by this prover
     * @dev Implementation of IProver interface method
     * @return string The type of proof mechanism (Polymer)
     */
    function getProofType() external pure override returns (string memory) {
        return PROOF_TYPE;
    }

    // ------------ EXTERNAL PROVE FUNCTION -------------

    /**
     * @notice Emits IntentFulfilledFromSource events that can be proven by Polymer
     * @dev Only callable by the Portal contract
     * @param sender Address of the original transaction sender (unused)
     * @param sourceChainId Chain ID of the source chain
     * @param encodedProofs Encoded (intentHash, claimant) pairs as bytes
     * @param data Additional data specific to the proving implementation (unused)
    */
    function prove(
        address sender,
        uint256 sourceChainId,
        bytes calldata encodedProofs,
        bytes calldata data
    ) external payable {
        if (msg.sender != PORTAL) revert OnlyPortal();

        // If data is empty, just return early
        if (encodedProofs.length == 0) return;

        // Ensure encodedProofs length is multiple of 64 bytes (32 for hash + 32 for claimant)
        if (encodedProofs.length % 64 != 0) {
            revert ArrayLengthMismatch();
        }

        uint256 numPairs = encodedProofs.length / 64;

        for (uint256 i = 0; i < numPairs; i++) {
            uint256 offset = i * 64;

            // Extract intentHash and claimant using slice
            bytes32 intentHash = bytes32(encodedProofs[offset:offset + 32]);
            bytes32 claimantBytes = bytes32(encodedProofs[offset + 32:offset + 64]);

            // Emit event that can be proven by Polymer
            emit IntentFulfilledFromSource(intentHash, claimantBytes, uint64(sourceChainId));
        }
    }
}
