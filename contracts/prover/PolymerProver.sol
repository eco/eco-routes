// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseProver} from "./BaseProver.sol";
import {Semver} from "../libs/Semver.sol";
import {ICrossL2ProverV2} from "../interfaces/ICrossL2ProverV2.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PolymerProver
 * @notice Prover implementation using Polymer's cross-chain messaging system
 * @dev Processes proof messages from Polymer's CrossL2ProverV2 and records proven intents
 */
contract PolymerProver is BaseProver, Semver, Ownable {
    // Constants
    ProofType public constant PROOF_TYPE = ProofType.Polymer;
    bytes32 public constant PROOF_SELECTOR =
        keccak256("Fulfillment(bytes32,uint256,address)");

    // Events
    event IntentAlreadyProven(bytes32 _intentHash);

    // Errors
    error InvalidEventSignature();
    error InvalidEmittingContract(address emittingContract);
    error InvalidSourceChain();
    error InvalidTopicsLength();
    error ZeroAddress();
    error SizeMismatch();

    // State variables
    ICrossL2ProverV2 public CROSS_L2_PROVER_V2;
    mapping(uint64 => bytes32) public WHITELISTED_EMITTERS;

    /**
     * @notice Deterministic constructor for consistent deployment addresses
     * @param _owner Address that will own this contract
     */
    constructor(address _owner) Ownable(_owner) {}

    /**
     * @notice Initializes the PolymerProver with CrossL2ProverV2 and whitelist settings
     * @param _crossL2ProverV2 Address of the CrossL2ProverV2 contract
     * @param _chainIds Array of chain IDs for whitelisted emitters
     * @param _whitelistedEmitters Array of whitelisted emitter addresses
     */
    function initialize(
        address _crossL2ProverV2,
        uint64[] memory _chainIds,
        bytes32[] memory _whitelistedEmitters
    ) external onlyOwner {
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
        (bytes32 intentHash, address claimant) = _validateProof(proof);
        _processIntent(intentHash, claimant);
    }

    /**
     * @notice Validates multiple proofs in a batch
     * @param proofs Array of proof data to validate
     */
    function validateBatch(bytes[] calldata proofs) external {
        for (uint256 i = 0; i < proofs.length; i++) {
            (bytes32 intentHash, address claimant) = _validateProof(proofs[i]);
            _processIntent(intentHash, claimant);
        }
    }

    // ------------- INTERNAL FUNCTIONS - PROOF VALIDATION -------------

    /**
     * @notice Core proof validation logic
     * @param proof The proof data to validate
     * @return intentHash Hash of the proven intent
     * @return claimant Address that fulfilled the intent
     */
    function _validateProof(
        bytes calldata proof
    ) internal view returns (bytes32 intentHash, address claimant) {
        (
            uint32 destinationChainId,
            address emittingContract,
            bytes memory topics,
            /* bytes memory data */
        ) = CROSS_L2_PROVER_V2.validateEvent(proof);

        if (!isWhitelisted(uint64(destinationChainId), bytes32(uint256(uint160(emittingContract))))) {
            revert InvalidEmittingContract(emittingContract);
        }
        checkTopicLength(topics, 128); // 4 topics: signature + hash + sourceChainID + claimant

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
        // Fulfillment event signature: Fulfillment(bytes32 indexed _hash, uint256 indexed _sourceChainID, address indexed _claimant)
        // topicsArray[1] = intentHash
        // topicsArray[2] = sourceChainID
        // topicsArray[3] = claimant
        
        // Convert bytes32 claimant to address
        claimant = address(uint160(uint256(topicsArray[3])));
        // Get sourceChainId from event topic and verify it matches current chain
        uint64 eventSourceChainId = uint64(uint256(topicsArray[2]));
        if (eventSourceChainId != block.chainid) revert InvalidSourceChain();

        return (topicsArray[1], claimant);
    }

    /**
     * @notice Processes a single intent proof
     * @param intentHash Hash of the intent being proven
     * @param claimant Address that fulfilled the intent and should receive rewards
     */
    function _processIntent(bytes32 intentHash, address claimant) internal {
        if (provenIntents[intentHash] != address(0)) {
            emit IntentAlreadyProven(intentHash);
        } else {
            provenIntents[intentHash] = claimant;
            emit IntentProven(intentHash, claimant);
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

    /**
     * @notice Checks if an emitting contract is whitelisted for a given chain
     * @param chainID The chain ID to check
     * @param addr The address to check (as bytes32)
     * @return Whether the address is whitelisted for the chain
     */
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
     * @return ProofType indicating the prover's mechanism
     */
    function getProofType() external pure override returns (ProofType) {
        return PROOF_TYPE;
    }
}
