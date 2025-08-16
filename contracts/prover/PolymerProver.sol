// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseProver} from "./BaseProver.sol";
import {Semver} from "../libs/Semver.sol";
import {ICrossL2ProverV2} from "../interfaces/ICrossL2ProverV2.sol";
import {IProver} from "../interfaces/IProver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AddressConverter} from "../libs/AddressConverter.sol";

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
    uint256 public constant EXPECTED_TOPIC_LENGTH = 128; // 4 topics * 32 bytes each

    // Events
    event IntentFulfilledFromSource(
        bytes32 indexed intentHash,
        bytes32 indexed claimant,
        uint64 source
    );

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
        address _portal
    ) BaseProver(_portal) Ownable(_owner) {}

    /**
     * @notice Initializes the contract with CrossL2ProverV2 and whitelist settings
     * @param _crossL2ProverV2 Address of the CrossL2ProverV2 contract
     * @param _chainIds Array of chain IDs for whitelisted emitters
     * @param _whitelistedEmitters Array of whitelisted emitter addresses
     */
    function initialize(
        address _crossL2ProverV2,
        uint64[] calldata _chainIds,
        bytes32[] calldata _whitelistedEmitters
    ) external onlyOwner {
        if (_crossL2ProverV2 == address(0)) revert ZeroAddress();
        if (_chainIds.length != _whitelistedEmitters.length)
            revert SizeMismatch();

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
    function validate(bytes calldata proof) public {
        (
            bytes32 intentHash,
            address claimant,
            uint64 destinationChainId
        ) = _validateProof(proof);
        processIntent(intentHash, claimant, destinationChainId);
    }

    /**
     * @notice Validates multiple proofs in a batch
     * @param proofs Array of proof data to validate
     */
    function validateBatch(bytes[] calldata proofs) external {
        for (uint256 i = 0; i < proofs.length; i++) {
            validate(proofs[i]);
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
    )
        internal
        view
        returns (bytes32 intentHash, address claimant, uint64 chainId)
    {
        (
            uint32 destinationChainId,
            address emittingContract,
            bytes memory topics /* bytes memory data */,

        ) = CROSS_L2_PROVER_V2.validateEvent(proof);

        if (
            !isWhitelisted(
                uint64(destinationChainId),
                AddressConverter.toBytes32(emittingContract)
            )
        ) {
            revert InvalidEmittingContract(emittingContract);
        }

        if (topics.length != EXPECTED_TOPIC_LENGTH)
            revert InvalidTopicsLength();

        bytes32 eventSignature;
        bytes32 claimantBytes32;
        bytes32 sourceChainIdBytes32;

        assembly {
            let topicsPtr := add(topics, 32)

            eventSignature := mload(topicsPtr)
            intentHash := mload(add(topicsPtr, 32))
            claimantBytes32 := mload(add(topicsPtr, 64))
            sourceChainIdBytes32 := mload(add(topicsPtr, 96))
        }

        checkTopicSignature(eventSignature, PROOF_SELECTOR);
        // Convert bytes32 claimant to address
        claimant = AddressConverter.toAddress(claimantBytes32);
        // Get sourceChainId from event topic and verify it matches current chain
        uint64 eventSourceChainId = uint64(uint256(sourceChainIdBytes32));
        if (eventSourceChainId != block.chainid) revert InvalidSourceChain();

        return (intentHash, claimant, uint64(destinationChainId));
    }

    // ------------- INTERNAL FUNCTIONS - INTENT PROCESSING -------------

    /**
     * @notice Processes a single intent proof
     * @param intentHash Hash of the intent being proven
     * @param claimant Address that fulfilled the intent and should receive rewards
     */
    function processIntent(
        bytes32 intentHash,
        address claimant,
        uint64 destination
    ) internal {
        ProofData storage proof = _provenIntents[intentHash];
        if (proof.claimant != address(0)) {
            emit IntentAlreadyProven(intentHash);

            return;
        }
        proof.claimant = claimant;
        proof.destination = destination;

        emit IntentProven(intentHash, claimant, destination);
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

    function isWhitelisted(
        uint64 chainID,
        bytes32 addr
    ) internal view returns (bool) {
        bytes32 whitelistedEmitter = WHITELISTED_EMITTERS[chainID];
        return whitelistedEmitter != bytes32(0) && whitelistedEmitter == addr;
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
     * @param sourceChainDomainID Domain ID of the source chain (treated as chain ID for Polymer)
     * @param encodedProofs Encoded (intentHash, claimant) pairs as bytes
     */
    function prove(
        address,
        uint64 sourceChainDomainID,
        bytes calldata encodedProofs,
        bytes calldata
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
            bytes32 claimantBytes = bytes32(
                encodedProofs[offset + 32:offset + 64]
            );

            // Emit event that can be proven by Polymer
            emit IntentFulfilledFromSource(
                intentHash,
                claimantBytes,
                sourceChainDomainID
            );
        }
    }
}
