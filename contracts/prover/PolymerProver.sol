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
    uint256 public constant EXPECTED_TOPIC_LENGTH = 128; // 4 topics * 32 bytes each

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
        (bytes32 intentHash, address claimant) = _validateProof(proof);
        _processIntent(intentHash, claimant);
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
     */
    function _validateProof(
        bytes calldata proof
    ) internal view returns (bytes32 intentHash, address claimant) {
        (
            uint32 destinationChainId,
            address emittingContract,
            bytes memory topics /* bytes memory data */,

        ) = CROSS_L2_PROVER_V2.validateEvent(proof);

        if (
            !isWhitelisted(
                uint64(destinationChainId),
                bytes32(uint256(uint160(emittingContract)))
            )
        ) {
            revert InvalidEmittingContract(emittingContract);
        }
        if (topics.length != EXPECTED_TOPIC_LENGTH)
            revert InvalidTopicsLength();

        bytes32 eventSignature;
        bytes32 sourceChainIdBytes32;
        bytes32 claimantBytes32;

        assembly {
            let topicsPtr := add(topics, 32)

            eventSignature := mload(topicsPtr)
            intentHash := mload(add(topicsPtr, 32))
            sourceChainIdBytes32 := mload(add(topicsPtr, 64))
            claimantBytes32 := mload(add(topicsPtr, 96))
        }

        if (eventSignature != PROOF_SELECTOR) revert InvalidEventSignature();
        claimant = address(uint160(uint256(claimantBytes32)));
        uint64 eventSourceChainId = uint64(uint256(sourceChainIdBytes32));
        if (eventSourceChainId != block.chainid) revert InvalidSourceChain();

        return (intentHash, claimant);
    }

    /**
     * @notice Processes a single intent proof
     * @param intentHash Hash of the intent being proven
     * @param claimant Address that fulfilled the intent and should receive rewards
     */
    function _processIntent(bytes32 intentHash, address claimant) internal {
        if (provenIntents[intentHash] != address(0)) {
            emit IntentAlreadyProven(intentHash);

            return;
        }
        provenIntents[intentHash] = claimant;

        emit IntentProven(intentHash, claimant);
    }

    // ------------- INTERNAL FUNCTIONS - VALIDATION HELPERS -------------

    /**
     * @notice Checks if an emitting contract is whitelisted for a given chain
     * @param chainID The chain ID to check
     * @param addr The address to check (as bytes32)
     * @return Whether the address is whitelisted for the chain
     */
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
     * @return ProofType indicating the prover's mechanism
     */
    function getProofType() external pure override returns (ProofType) {
        return PROOF_TYPE;
    }
}
