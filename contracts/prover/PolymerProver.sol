// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseProver} from "./BaseProver.sol";
import {Semver} from "../libs/Semver.sol";
import {ICrossL2ProverV2} from "../interfaces/ICrossL2ProverV2.sol";
import {IProver} from "../interfaces/IProver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PolymerProver
 * @notice Prover implementation using Polymer's cross-chain messaging system
 * @dev Processes proof messages from Polymer's CrossL2ProverV2 and records proven intents
 */
contract PolymerProver is BaseProver, Semver, Ownable {
    // Constants
    string public constant PROOF_TYPE = "Polymer";
    bytes32 public constant PROOF_SELECTOR =
        keccak256("IntentFulfilledFromSource(bytes32,bytes32,uint64)");

    // Events
    event IntentFulfilledFromSource(bytes32 indexed intentHash, bytes32 indexed claimant, uint64 source);

    // Errors
    error InvalidEventSignature();
    error InvalidEmittingContract(address emittingContract);
    error InvalidSourceChain();
    error InvalidTopicsLength();
    error ZeroAddress();
    error SizeMismatch();
    error OnlyPortal();

    // State variables
    ICrossL2ProverV2 public CROSS_L2_PROVER_V2;
    mapping(uint64 => bytes32) public WHITELISTED_EMITTERS;


    /**
     * @notice Initializes the PolymerProver contract
     * @param _owner Temporary owner address for initialization
     * @param _portal Address of the Portal contract
     */
    constructor(
        address _owner,
        address _portal) BaseProver(_portal) Ownable(_owner) {
    }

    /**
     * @notice Initializes the contract with CrossL2ProverV2 and whitelist settings
     * @param _crossL2ProverV2 Address of the CrossL2ProverV2 contract
     * @param _chainIds Array of chain IDs for whitelisted emitters
     * @param _whitelistedEmitters Array of whitelisted emitter addresses
     */
    function initialize(
        address _crossL2ProverV2,
        uint64[] calldata _chainIds,
        bytes32[] calldata _whitelistedEmitters) external onlyOwner {
        if (_crossL2ProverV2 == address(0)) revert ZeroAddress();
        if (_chainIds.length != _whitelistedEmitters.length) revert SizeMismatch();

        CROSS_L2_PROVER_V2 = ICrossL2ProverV2(_crossL2ProverV2);

        for (uint256 i = 0; i < _chainIds.length; i++) {
            WHITELISTED_EMITTERS[_chainIds[i]] = _whitelistedEmitters[i];
        }

        renounceOwnership();
    }

    // ------------- STANDARD PROOF VALIDATION -------------

    /**
     * @notice Validates a single proof
     * @param proof The proof data for CROSS_L2_PROVER_V2 to validate
     */
    function validate(bytes calldata proof) external {
        (bytes32 intentHash, address claimant, uint64 destinationChainId) = _validateProof(proof);
        processIntent(intentHash, claimant, destinationChainId);
    }


    /**
     * @notice Validates multiple proofs in a batch
     * @param proofs Array of proof data to validate
     */
    function validateBatch(bytes[] calldata proofs) external {
        for (uint256 i = 0; i < proofs.length; i++) {
            (bytes32 intentHash, address claimant, uint64 destinationChainId) = _validateProof(proofs[i]);
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
    ) internal view returns (bytes32 intentHash, address claimant, uint64 chainId) {
        (
            uint32 destinationChainId,
            address emittingContract,
            bytes memory topics,
            /* bytes memory data */
        ) = CROSS_L2_PROVER_V2.validateEvent(proof);

        if (!isWhitelisted(uint64(destinationChainId), bytes32(uint256(uint160(emittingContract))))) {
            revert InvalidEmittingContract(emittingContract);
        }
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
        if (eventSourceChainId != block.chainid) revert InvalidSourceChain();

        return (topicsArray[1], claimant, uint64(destinationChainId));
    }

    // ------------- INTERNAL FUNCTIONS - INTENT PROCESSING -------------

    /**
     * @notice Processes a single intent proof
     * @param intentHash Hash of the intent being proven
     * @param claimant Address that fulfilled the intent and should receive rewards
     */
    function processIntent(bytes32 intentHash, address claimant, uint64 destination) internal {
        ProofData storage proof = _provenIntents[intentHash];
        if (proof.claimant != address(0)) {
            emit IntentAlreadyProven(intentHash);
        } else {
            proof.claimant = claimant;
            proof.destination = destination;
            emit IntentProven(intentHash, claimant, destination);
        }
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

    function isWhitelisted(uint64 chainID, bytes32 addr) internal view returns (bool) {
        bytes32 whitelistedEmitter = WHITELISTED_EMITTERS[chainID];
        if (whitelistedEmitter == bytes32(0)) {
            return false;
        }
        return whitelistedEmitter == addr;
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
     * @param sourceChainDomainID Domain ID of the source chain (treated as chain ID for Polymer)
     * @param encodedProofs Encoded (intentHash, claimant) pairs as bytes
     * @param data Additional data specific to the proving implementation (unused)
    */
    function prove(
        address sender,
        uint64 sourceChainDomainID,
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
            emit IntentFulfilledFromSource(intentHash, claimantBytes, sourceChainDomainID);
        }
    }
}
