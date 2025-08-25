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
    using AddressConverter for bytes32;
    using AddressConverter for address;

    // Constants
    string public constant PROOF_TYPE = "Polymer";
    bytes32 public constant PROOF_SELECTOR =
        keccak256("IntentFulfilledFromSource(uint64,bytes)");
    uint256 public constant EXPECTED_TOPIC_LENGTH = 64; // 2 topics * 32 bytes each
    uint256 constant MAX_LOG_DATA_SIZE = 32 * 1024;

    // Events
    event IntentFulfilledFromSource(uint64 indexed source, bytes encodedProofs);

    // Errors
    error InvalidEventSignature();
    error InvalidEmittingContract(address emittingContract);
    error InvalidSourceChain();
    error InvalidDestinationChain();
    error InvalidTopicsLength();
    error ZeroAddress();
    error SizeMismatch();
    error MaxDataSizeExceeded();
    error EmptyProofData();
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

    // ------------- LOG EVENT PROOF VALIDATION -------------

    /**
     * @notice Validates multiple proofs in a batch
     * @param proofs Array of proof data to validate
     */
    function validateBatch(bytes[] calldata proofs) external {
        for (uint256 i = 0; i < proofs.length; i++) {
            validate(proofs[i]);
        }
    }

    /**
     * @notice Validates a single proof and processes contained intents
     * @param proof of a IntentFulfilledFromSource event
     */
    function validate(bytes calldata proof) public {
        (
            uint32 destinationChainId,
            address emittingContract,
            bytes memory topics,
            bytes memory data
        ) = CROSS_L2_PROVER_V2.validateEvent(proof);

        if (
            !isWhitelisted(
                uint64(destinationChainId),
                emittingContract.toBytes32()
            )
        ) {
            revert InvalidEmittingContract(emittingContract);
        }

        if (topics.length != EXPECTED_TOPIC_LENGTH)
            revert InvalidTopicsLength();

        if (data.length == 0) {
            revert EmptyProofData();
        }

        if ((data.length - 8) % 64 != 0) {
            revert ArrayLengthMismatch();
        }

        bytes32 eventSignature;
        bytes32 sourceChainIdBytes32;
        uint64 proofDataChainId;

        assembly {
            let topicsPtr := add(topics, 32)
            let dataPtr := add(data, 32)

            eventSignature := mload(topicsPtr)
            sourceChainIdBytes32 := mload(add(topicsPtr, 32))
            proofDataChainId := shr(192, mload(dataPtr)) // Extract first 8 bytes (64 bits) from the 32-byte word
        }

        if (eventSignature != PROOF_SELECTOR) revert InvalidEventSignature();
        uint256 sourceChainIdUint256 = uint256(sourceChainIdBytes32);
        if (sourceChainIdUint256 > type(uint64).max) {
            revert InvalidSourceChain();
        }
        uint64 eventSourceChainId = uint64(sourceChainIdUint256);
        if (eventSourceChainId != block.chainid) revert InvalidSourceChain();
        
        // Verify the chain ID from proof data matches the destination chain from validateEvent
        if (proofDataChainId != uint64(destinationChainId)) revert InvalidDestinationChain();

        uint256 numPairs = (data.length - 8) / 64;
        for (uint256 i = 0; i < numPairs; i++) {
            uint256 offset = 8 + i * 64;

            bytes32 intentHash;
            bytes32 claimantBytes;

            assembly {
                let dataPtr := add(data, 32)
                intentHash := mload(add(dataPtr, offset))
                claimantBytes := mload(add(dataPtr, add(offset, 32)))
            }

            address claimant = claimantBytes.toAddress();
            processIntent(intentHash, claimant, destinationChainId);
        }
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

        if (encodedProofs.length == 0) return;

        if ((encodedProofs.length - 8 ) % 64 != 0) {
            revert ArrayLengthMismatch();
        }
        if (encodedProofs.length > MAX_LOG_DATA_SIZE) {
            revert MaxDataSizeExceeded();
        }

        emit IntentFulfilledFromSource(sourceChainDomainID, encodedProofs);
    }
}
