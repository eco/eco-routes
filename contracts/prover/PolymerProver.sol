// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseProver} from "./BaseProver.sol";
import {Semver} from "../libs/Semver.sol";
import {ICrossL2ProverV2} from "../interfaces/ICrossL2ProverV2.sol";
import {INativeProver, ProveScalarArgs} from "../interfaces/INativeProver.sol";
import {IIntentSource} from "../interfaces/IIntentSource.sol";
import {Reward, TokenAmount} from "../types/Intent.sol";

/**
 * @title PolyNativeProver
 * @notice Prover implementation using Polymer's cross-chain messaging system
 * @dev Processes proof messages from Polymer's CrossL2ProverV2 and records proven intents
 */
contract PolyNativeProver is BaseProver, Semver {
    // Constants
    ProofType public constant PROOF_TYPE = ProofType.Polymer;
    bytes32 public constant PROOF_SELECTOR =
        keccak256("ToBeProven(bytes32,uint256,address)");
    bytes32 public constant BATCH_PROOF_SELECTOR =
        keccak256("BatchToBeProven(uint256,bytes)");
    uint256 public constant _STARTING_INBOX_FULFILLED_SLOT = 1; // Slot where we expect the fullfilled mapping to be populated in the inbox contract. Used in native proof path.

    // Events
    event IntentAlreadyProven(bytes32 _intentHash);

    // Errors
    error InvalidEventSignature();
    error UnsupportedChainId();
    error InvalidEmittingContract();
    error InvalidTopicsLength();
    error SizeMismatch();
    error IntentHashMismatch();
    error IncorrectStorageSlot(bytes32 expected, bytes32 actual);

    // Structs
    struct ProverReward {
        address creator;
        uint256 deadline;
        uint256 nativeValue;
        TokenAmount[] tokens;
    }

    // Immutable state variables
    ICrossL2ProverV2 public immutable CROSS_L2_PROVER_V2;
    INativeProver public immutable NATIVE_PROVER;
    address public immutable INBOX;

    // State variables
    mapping(uint32 => bool) public supportedChainIds;

    /**
     * @notice Initializes the PolyNativeProver contract
     * @param _crossL2ProverV2 Address of the Polymer CrossL2ProverV2 contract
     * @param _inbox Address of the Inbox contract that emits proof events
     * @param _supportedChainIds Array of chain IDs that this prover will accept proofs from
     */
    constructor(
        address _crossL2ProverV2,
        address _nativeProver,
        address _inbox,
        uint32[] memory _supportedChainIds
    ) {
        CROSS_L2_PROVER_V2 = ICrossL2ProverV2(_crossL2ProverV2);
        NATIVE_PROVER = INativeProver(_nativeProver);
        INBOX = _inbox;
        for (uint32 i = 0; i < _supportedChainIds.length; i++) {
            supportedChainIds[_supportedChainIds[i]] = true;
        }
    }

    // ------------- STANDARD PROOF VALIDATION -------------

    /**
     * @notice Validates a single proof
     * @param proof The proof data for CROSS_L2_PROVER_V2 to validate
     */
    function validate(bytes calldata proof) external {
        (bytes32 intentHash, address claimant) = _validateProof(proof);
        processIntent(intentHash, claimant);
    }

    /**
     * @notice Validate a native proof of storage through this L2's view of the L1 blockhash.
     * This is more expensive than validate() but is useful as a fallback if polymer is ever down.
     * The storage proof we are interested in is the fullilled mapping of a given intentHash.
     * @param proof A storage proof using the native L1 proof.
     * @notice This cli tool can be used to generate this proof: https://github.com/polymerdao/fallback-prover
     */
    function validateNative(bytes calldata proof, bytes32 intentHash) external {
        address claimant = _validateNativeProof(proof, intentHash);
        processIntent(intentHash, claimant);
    }

    /**
     * @notice Validates multiple proofs in a batch
     * @param proofs Array of proof data to validate
     */
    function validateBatch(bytes[] calldata proofs) external {
        for (uint256 i = 0; i < proofs.length; i++) {
            (bytes32 intentHash, address claimant) = _validateProof(proofs[i]);
            processIntent(intentHash, claimant);
        }
    }

    // ------------- PACKED PROOF VALIDATION -------------

    /**
     * @notice Validates a packed format proof
     * @param proof The packed proof data to validate
     */
    function validatePacked(bytes calldata proof) external {
        _validatePackedProof(proof);
    }

    /**
     * @notice Validates multiple packed format proofs in a batch
     * @param proofs Array of packed proof data to validate
     */
    function validateBatchPacked(bytes[] calldata proofs) external {
        for (uint256 i = 0; i < proofs.length; i++) {
            _validatePackedProof(proofs[i]);
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
    ) internal returns (bytes32 intentHash, address claimant) {
        (
            uint32 chainId,
            address emittingContract,
            bytes memory topics,
            bytes memory data
        ) = CROSS_L2_PROVER_V2.validateEvent(proof);

        checkInboxContract(emittingContract);
        checkSupportedChainId(chainId);
        checkTopicLength(topics, 128);

        bytes32[] memory topicsArray = new bytes32[](4);

        // Use assembly for efficient memory operations when splitting topics
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
        claimant = address(uint160(uint256(topicsArray[3])));
        return (topicsArray[1], claimant);
    }

    /**
     * The storage proof we are interested in is the fullilled mapping of a given intentHash.
     * @param proof The proof data to validate. See cli tool https://github.com/polymerdao/fallback-prover
     * @param intentHash Used to calculate the storage key of the inbox contract we are proving.
     * @return claimant Address that fulfilled the intent
     */
    function _validateNativeProof(
        bytes calldata proof,
        bytes32 intentHash
    ) internal returns (address claimant) {
        (
            ProveScalarArgs memory _proveArgs,
            bytes memory _rlpEncodedL1Header,
            bytes memory _rlpEncodedL2Header,
            bytes memory _settledStateProof,
            bytes[] memory _l2StorageProof,
            bytes memory _rlpEncodedContractAccount,
            bytes[] memory _l2AccountProof
        ) = abi.decode(
                proof,
                (ProveScalarArgs, bytes, bytes, bytes, bytes[], bytes, bytes[])
            );

        checkInboxContract(_proveArgs.contractAddr);
        checkSupportedChainId(uint32(_proveArgs.chainID));
        checkStorageSlot(intentHash, _proveArgs.storageSlot);

        NATIVE_PROVER.prove(
            _proveArgs,
            _rlpEncodedL1Header,
            _rlpEncodedL2Header,
            _settledStateProof,
            _l2StorageProof,
            _rlpEncodedContractAccount,
            _l2AccountProof
        );

        return slotToClaimant(_proveArgs.storageValue);
    }

    /**
     * @notice Internal function to validate a packed proof
     * @param proof The packed proof data to validate
     */
    function _validatePackedProof(bytes calldata proof) internal {
        (
            uint32 chainId,
            address emittingContract,
            bytes memory topics,
            bytes memory data
        ) = CROSS_L2_PROVER_V2.validateEvent(proof);

        checkInboxContract(emittingContract);
        checkSupportedChainId(chainId);
        checkTopicLength(topics, 64);
        checkTopicSignature(bytes32(topics), BATCH_PROOF_SELECTOR);

        decodeMessageandStore(data);
    }

    // ------------- INTERNAL FUNCTIONS - INTENT PROCESSING -------------

    /**
     * @notice Processes a single intent proof
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

    /**
     * @notice Validates that a calculated intent hash matches the expected intent hash
     * @param routeHash The route hash component of the intent
     * @param reward The reward structure to encode
     * @param expectedIntentHash The expected intent hash to compare against
     */
    function validateIntentHash(
        bytes32 routeHash,
        Reward memory reward,
        bytes32 expectedIntentHash
    ) internal pure {
        bytes32 calculatedRewardHash = keccak256(abi.encode(reward));
        bytes32 calculatedIntentHash = keccak256(
            abi.encodePacked(routeHash, calculatedRewardHash)
        );
        if (calculatedIntentHash != expectedIntentHash) {
            revert IntentHashMismatch();
        }
    }

    /**
     * @notice Converts a proverReward struct to a Reward struct
     * @param _proverReward The proverReward struct to convert
     * @return Reward struct with this contract as the prover
     */
    function _toReward(
        ProverReward memory _proverReward
    ) internal view returns (Reward memory) {
        return
            Reward(
                _proverReward.creator,
                address(this),
                _proverReward.deadline,
                _proverReward.nativeValue,
                _proverReward.tokens
            );
    }

    // ------------- INTERNAL FUNCTIONS - MESSAGE DECODING -------------

    /**
     * @notice Decodes a message body into intent hashes and claimants and stores them
     * @param messageBody The message body to decode
     */
    function decodeMessageandStore(bytes memory messageBody) internal {
        uint256 size = messageBody.length;
        uint256 offset = 0;

        while (offset < size) {
            // Get chunkSize and check for truncation
            uint16 chunkSize;
            require(offset + 2 <= size, "truncated chunkSize");
            assembly {
                chunkSize := mload(add(messageBody, add(offset, 2)))
                offset := add(offset, 2)
            }

            // Get claimant address and check for truncation
            require(offset + 20 <= size, "truncated claimant address");
            address claimant;
            assembly {
                claimant := mload(add(messageBody, add(offset, 20)))
                offset := add(offset, 20)
            }

            // Get intentHash and check for truncation
            require(offset + 32 * chunkSize <= size, "truncated intent set");
            bytes32 intentHash;
            for (uint16 i = 0; i < chunkSize; i++) {
                assembly {
                    intentHash := mload(add(messageBody, add(offset, 32)))
                    offset := add(offset, 32)
                }
                processIntent(intentHash, claimant);
            }
        }
    }

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
     * @notice Validates that the emitting contract is the expected inbox
     * @param emittingContract The contract that emitted the event
     */
    function checkInboxContract(address emittingContract) internal view {
        if (emittingContract != INBOX) revert InvalidEmittingContract();
    }

    /**
     * @notice Validates that the chain ID is supported by this prover
     * @param chainId The chain ID to check
     */
    function checkSupportedChainId(uint32 chainId) internal view {
        if (!supportedChainIds[chainId]) revert UnsupportedChainId();
    }

    /**
     * @notice Check that storage slot of a given intent indeed matches the expected storage slot in the inbox contract on counterparty chain.
     * mapping is declared in Inbox contract as follows:
     *     mapping(bytes32 => ClaimantAndBatcherReward) public fulfilled;
     */
    function checkStorageSlot(
        bytes32 intentHash,
        bytes32 storageSlot
    ) internal view {
        if (
            keccak256(abi.encode(intentHash, _STARTING_INBOX_FULFILLED_SLOT)) !=
            storageSlot
        ) {
            revert IncorrectStorageSlot(
                storageSlot,
                keccak256(
                    abi.encode(intentHash, _STARTING_INBOX_FULFILLED_SLOT)
                )
            );
        }
    }

    /**
     * @notice Convert a raw Inbox contract storage slot to a claimant address.
     */
    function slotToClaimant(bytes32 slotValue) internal pure returns (address) {
        // The storage slot should be in this format:
        // struct ClaimantAndBatcherReward {
        //     address claimant;
        //     uint96 reward;
        // }

        // Shift to discard the reward bits
        return address(uint160(uint256(slotValue >> 96)));
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
     * @return ProofType The type of proof mechanism (Polymer)
     */
    function getProofType() external pure override returns (ProofType) {
        return PROOF_TYPE;
    }
}
