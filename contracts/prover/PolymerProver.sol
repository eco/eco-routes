pragma solidity ^0.8.26;

import {BaseProver} from "./BaseProver.sol";
import {Semver} from "../libs/Semver.sol";
import {ICrossL2ProverV2} from "../interfaces/ICrossL2ProverV2.sol";

/**
 * @title PolymerProver
 * @notice Prover implementation using Polymer's cross-chain messaging system
 * @dev Processes proof messages from Polymer's CrossL2ProverV2 and records proven intents
 */
contract PolymerProver is BaseProver, Semver {
    /**
     * @notice Constant indicating this contract uses Polymer for proving
     */
    ProofType public constant PROOF_TYPE = ProofType.Polymer;

    /**
     * @notice Emitted when attempting to prove an already-proven intent
     * @dev Event instead of error to allow batch processing to continue
     * @param _intentHash Hash of the already proven intent
     */
    event IntentAlreadyProven(bytes32 _intentHash);

    // write custom errors
    error InvalidEventSignature();
    error UnsupportedChainId();
    error InvalidEmittingContract();
    error InvalidTopicsLength();
    error SizeMismatch();

    /**
     * @notice Address of local Polymer CrossL2ProverV2 contract
     * @dev Immutable contract reference used to validate cross-chain proofs
     */
    ICrossL2ProverV2 public immutable CROSS_L2_PROVER_V2;

    /**
     * @notice Address of local Inbox contract
     * @dev Immutable reference to verify proof origin
     */
    address public immutable INBOX;

    /**
     * @notice Mapping of supported source chain IDs
     * @dev Chain IDs that this prover accepts proofs from
     */
    mapping(uint32 => bool) public supportedChainIds;

    /**
     * @notice Keccak256 hash of the event signature for intent proofs
     * @dev Used to validate proof event topics
     */
    bytes32 public constant PROOF_SELECTOR =
        keccak256("ToBeProven(bytes32,uint256,address)");

    bytes32 public constant BATCH_PROOF_SELECTOR =
        keccak256("BatchToBeProven(uint256,bytes)");

    /**
     * @notice Initializes the PolymerProver contract
     * @dev Sets up core contract references and supported chain IDs
     * @param _crossL2ProverV2 Address of the Polymer CrossL2ProverV2 contract
     * @param _inbox Address of the Inbox contract that emits proof events
     * @param _supportedChainIds Array of chain IDs that this prover will accept proofs from
     */
    constructor(
        address _crossL2ProverV2,
        address _inbox,
        uint32[] memory _supportedChainIds
    ) {
        CROSS_L2_PROVER_V2 = ICrossL2ProverV2(_crossL2ProverV2);
        INBOX = _inbox;
        for (uint32 i = 0; i < _supportedChainIds.length; i++) {
            supportedChainIds[_supportedChainIds[i]] = true;
        }
    }

    /**
     * @notice Validates a single proof
     * @dev External function called to validate single event proof
     * @param proof The proof data for CROSS_L2_PROVER_V2 to validate
     */
    function validate(bytes calldata proof) external {
        _validateProof(proof);
    }

    /**
     * @notice Validates multiple proofs in a batch
     * @dev Processes each proof sequentially
     * @param proofs Array of proof data for CROSS_L2_PROVER_V2 to validate
     */
    function validateBatch(bytes[] calldata proofs) external {
        for (uint256 i = 0; i < proofs.length; i++) {
            _validateProof(proofs[i]);
        }
    }

    /**
     * @notice Core proof validation logic
     * @dev Internal method to validate proof using CrossL2ProverV2 and records proven intents
     * @param proof The proof data to validate
     */
    function _validateProof(bytes calldata proof) internal {
        (
            uint32 chainId,
            address emittingContract,
            bytes memory topics,
            bytes memory data
        ) = CROSS_L2_PROVER_V2.validateEvent(proof);

        // revert checks (might not need chainId check)
        checkInboxContract(emittingContract);
        checkSupportedChainId(chainId);
        checkTopicLength(topics, 128);

        bytes32[] memory topicsArray = new bytes32[](4);

        // Use assembly for efficient memory operations when splitting topics per example
        assembly {
            let topicsPtr := add(topics, 32)
            for {
                let i := 0
            } lt(i, 4) {
                i := add(i, 1)
            } {
                mstore(
                    add(add(topicsArray, 32), mul(i, 32)),
                    mload(add(topicsPtr, mul(i, 32)))
                )
            }
        }

        checkTopicSignature(topicsArray[0], PROOF_SELECTOR);

        address claimant = address(uint160(uint256(topicsArray[3])));

        processIntent(topicsArray[1], claimant);
    }

    /**
     * @notice Validates a packed format proof
     * @dev Currently unimplemented
     * @param proof The packed proof data to validate
     */
    function validatePacked(bytes calldata proof) external {
        _validatePackedProof(proof);
    }

    /**
     * @notice Validates multiple packed format proofs in a batch
     * @dev Currently unimplemented
     * @param proofs Array of packed proof data to validate
     */
    function validateBatchPacked(bytes[] calldata proofs) external {
        for (uint256 i = 0; i < proofs.length; i++) {
            _validatePackedProof(proofs[i]);
        }
    }

    /**
     * @notice Internal function to validate a packed proof
     * @dev Currently unimplemented
     * @param proof The packed proof data to validate
     */
    function _validatePackedProof(bytes calldata proof) internal {
        (
            uint32 chainId,
            address emittingContract,
            bytes memory topics,
            bytes memory data
        ) = CROSS_L2_PROVER_V2.validateEvent(proof);

        // revert checks (might not need chainId check)
        checkInboxContract(emittingContract);
        checkSupportedChainId(chainId);
        checkTopicLength(topics, 64); //signature and chainId
        checkTopicSignature(bytes32(topics), BATCH_PROOF_SELECTOR);

        //maybe add check that chainId from topics matches this chainId
        //but not needed because hash uniqueness is guaranteed by the source chain

        //add decode messageBody to skip offset and length encoding
        data = abi.decode(data, (bytes));
        
        (
            bytes32[] memory hashes,
            address[] memory claimants
        ) = decodeMessageBody(data);

        for (uint256 i = 0; i < hashes.length; i++) {
            processIntent(hashes[i], claimants[i]);
        }
    }

    /**
     * @notice Decodes a message body into intent hashes and claimants
     * @dev Used to decode the data from the BatchToBeProven event
     * @param messageBody The message body to decode
     * @return intentHashes The array of intent hashes
     * @return claimants The array of claimants
     */
    function decodeMessageBody(
        bytes memory messageBody
    )
        public
        pure
        returns (bytes32[] memory intentHashes, address[] memory claimants)
    {
        if (messageBody.length % 52 != 0) revert SizeMismatch(); // 32 bytes per hash + 20 per address
        uint256 size = messageBody.length / 52;

        intentHashes = new bytes32[](size);
        claimants = new address[](size);

        uint256 offset = 0;
        for (uint256 i = 0; i < size; i++) {
            bytes32 temp;
            assembly {
                temp := mload(add(messageBody, add(32, offset)))
            }
            intentHashes[i] = temp;
            offset += 32;
        }

        for (uint256 i = 0; i < size; i++) {
            address temp;
            assembly {
                temp := mload(add(messageBody, add(20, offset)))
            }
            claimants[i] = temp;
            offset += 20;
        }
    }

    /**
     * @notice Processes a single intent proof
     * @dev Updates proven intent mapping and emits event if not already proven
     * @param intentHash Hash of the intent being proven
     * @param claimant Address that fulfilled the intent and should receive rewards
     */
    function processIntent(bytes32 intentHash, address claimant) internal {
        if (provenIntents[intentHash] != address(0)) {
            emit IntentAlreadyProven(intentHash);
        } else {
            provenIntents[intentHash] = claimant;
            emit IntentProven(intentHash, claimant);
        }
    }

    function checkTopicSignature(
        bytes32 topic,
        bytes32 selector
    ) internal pure {
        if (topic != selector) revert InvalidEventSignature();
    }

    function checkInboxContract(address emittingContract) internal view {
        if (emittingContract != INBOX) revert InvalidEmittingContract();
    }

    function checkSupportedChainId(uint32 chainId) internal view {
        if (!supportedChainIds[chainId]) revert UnsupportedChainId();
    }

    function checkTopicLength(
        bytes memory topics,
        uint256 length
    ) internal pure {
        if (topics.length != length) revert InvalidTopicsLength();
    }

    /**
     * @notice Returns the proof type used by this prover
     * @dev Implementation of IProver interface method
     * @return ProofType The type of proof mechanism (Polymer)
     */
    function getProofType() external pure override returns (ProofType) {
        return PROOF_TYPE;
    }
}
