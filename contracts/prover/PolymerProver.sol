// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseProver} from "./BaseProver.sol";
import {Semver} from "../libs/Semver.sol";
import {ICrossL2ProverV2} from "../interfaces/ICrossL2ProverV2.sol";
import {IIntentSource} from "../interfaces/IIntentSource.sol";
import {Reward, TokenAmount} from "../types/Intent.sol";

/**
 * @title PolyNativeProver
 * @notice Prover implementation using Polymer's cross-chain messaging system
 * @dev Processes proof messages from Polymer's CrossL2ProverV2 and records proven intents
 */
contract PolyNativeProver is BaseProver, Semver {
    // Constants
    string public constant PROOF_TYPE = "Polymer";
    bytes32 public constant PROOF_SELECTOR =
        keccak256("IntentFulfilled(bytes32,bytes32)");

    // Errors
    error InvalidEventSignature();
    error UnsupportedChainId();
    error InvalidEmittingContract();
    error InvalidTopicsLength();
    error SizeMismatch();
    error IntentHashMismatch();

    // Immutable state variables
    ICrossL2ProverV2 public immutable CROSS_L2_PROVER_V2;

    // State variables
    mapping(uint32 => bool) public supportedChainIds;

    /**
     * @notice Initializes the PolyNativeProver contract
     * @param _crossL2ProverV2 Address of the Polymer CrossL2ProverV2 contract
     * @param _portal Address of the Portal contract
     * @param _supportedChainIds Array of chain IDs that this prover will accept proofs from
     */
    constructor(
        address _crossL2ProverV2,
        address _portal,
        uint32[] memory _supportedChainIds
    ) BaseProver(_portal) {
        CROSS_L2_PROVER_V2 = ICrossL2ProverV2(_crossL2ProverV2);
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
            bytes memory data
        ) = CROSS_L2_PROVER_V2.validateEvent(proof);

        checkPortalContract(emittingContract);
        checkSupportedChainId(destinationChainId);
        checkTopicLength(topics, 96); // 3 topics: signature + hash + claimant

        bytes32[] memory topicsArray = new bytes32[](3);

        // Use assembly for efficient memory operations when splitting topics
        assembly {
            let topicsPtr := add(topics, 32)
            for {
                let i := 0
            } lt(i, 3) {
                i := add(i, 1)
            } {
                mstore(
                    add(add(topicsArray, 32), mul(i, 32)),
                    mload(add(topicsPtr, mul(i, 32)))
                )
            }
        }

        checkTopicSignature(topicsArray[0], PROOF_SELECTOR);
        // Convert bytes32 claimant to address
        claimant = address(uint160(uint256(topicsArray[2])));
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

    // ------------- INTERNAL FUNCTIONS - MESSAGE DECODING -------------

    /**
     * @notice Decodes a message body into intent hashes and claimants and stores them
     * @param messageBody The message body to decode
     * @param destinationChainId Chain ID where the intents were fulfilled
     */
    function decodeMessageandStore(bytes memory messageBody, uint32 destinationChainId) internal {
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
                processIntent(intentHash, claimant, destinationChainId);
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
     * @notice Validates that the emitting contract is the expected portal contract
     * @param emittingContract The contract that emitted the event
     */
    function checkPortalContract(address emittingContract) internal view {
        if (emittingContract != PORTAL) revert InvalidEmittingContract();
    }

    /**
     * @notice Validates that the chain ID is supported by this prover
     * @param chainId The chain ID to check
     */
    function checkSupportedChainId(uint32 chainId) internal view {
        if (!supportedChainIds[chainId]) revert UnsupportedChainId();
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
     * @notice Satisfies the IProver interface
     * @dev This function should not need to be called. Call only Inbox.fulFill on the destination chain.
     * @dev This function does nothing since Polymer does not require sending a message from the destination chain.
     * @param sender Address of the original transaction sender
     * @param sourceChainId Chain ID of the source chain
     * @param encodedProofs Encoded (intentHash, claimant) pairs as bytes
     * @param data Additional data specific to the proving implementation
    */
    function prove(
        address sender,
        uint256 sourceChainId,
        bytes calldata encodedProofs,
        bytes calldata data
    ) external payable {}
}
