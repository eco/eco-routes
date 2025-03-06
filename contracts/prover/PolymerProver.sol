pragma solidity ^0.8.26;

import {BaseProver} from "./BaseProver.sol";
import {Semver} from "../libs/Semver.sol";
import {ICrossL2ProverV2} from "../interfaces/ICrossL2ProverV2.sol";
import {IIntentSource} from "../interfaces/IIntentSource.sol";
import {Reward, TokenAmount} from "../types/Intent.sol";

/**
 * @title PolymerProver
 * @notice Prover implementation using Polymer's cross-chain messaging system
 * @dev Processes proof messages from Polymer's CrossL2ProverV2 and records proven intents
 */
contract PolymerProver is BaseProver, Semver {
    // Constants
    ProofType public constant PROOF_TYPE = ProofType.Polymer;
    bytes32 public constant PROOF_SELECTOR = keccak256("ToBeProven(bytes32,uint256,address)");
    bytes32 public constant BATCH_PROOF_SELECTOR = keccak256("BatchToBeProven(uint256,bytes)");
    
    // Events
    event IntentAlreadyProven(bytes32 _intentHash);
    
    // Errors
    error InvalidEventSignature();
    error UnsupportedChainId();
    error InvalidEmittingContract();
    error InvalidTopicsLength();
    error SizeMismatch();
    error IntentHashMismatch();
    
    // Structs
    struct ProverReward {
        address creator;
        uint256 deadline;
        uint256 nativeValue;
        TokenAmount[] tokens;
    }
    
    // Immutable state variables
    ICrossL2ProverV2 public immutable CROSS_L2_PROVER_V2;
    address public immutable INBOX;
    address public immutable INTENT_SOURCE;
    
    // State variables
    mapping(uint32 => bool) public supportedChainIds;

    /**
     * @notice Initializes the PolymerProver contract
     * @param _crossL2ProverV2 Address of the Polymer CrossL2ProverV2 contract
     * @param _inbox Address of the Inbox contract that emits proof events
     * @param _supportedChainIds Array of chain IDs that this prover will accept proofs from
     * @param _intentSource Address of the IntentSource contract
     */
    constructor(
        address _crossL2ProverV2,
        address _inbox,
        uint32[] memory _supportedChainIds,
        address _intentSource
    ) {
        CROSS_L2_PROVER_V2 = ICrossL2ProverV2(_crossL2ProverV2);
        INBOX = _inbox;
        INTENT_SOURCE = _intentSource;
        
        for (uint32 i = 0; i < _supportedChainIds.length; i++) {
            supportedChainIds[_supportedChainIds[i]] = true;
        }
    }

    /**
     * @notice Validates a single proof
     * @param proof The proof data for CROSS_L2_PROVER_V2 to validate
     */
    function validate(bytes calldata proof) external {
        (bytes32 intentHash, address claimant) = _validateProof(proof);
        processIntent(intentHash, claimant);
    }

    /**
     * @notice Validates a proof and claims the reward
     * @param proof The proof data to validate
     * @param routeHash The route hash component of the intent
     * @param proverReward The reward structure for the intent
     */
    function validateAndClaim(
        bytes calldata proof,
        bytes32 routeHash,
        ProverReward calldata proverReward
    ) external {
        (bytes32 intentHash, address claimant) = _validateProof(proof);
        Reward memory reward = _toReward(proverReward);

        validateIntentHash(routeHash, reward, intentHash);
        IIntentSource(INTENT_SOURCE).pushWithdraw(
            intentHash,
            routeHash,
            reward,
            claimant
        );
        emit IntentProven(intentHash, claimant); //might want a new event, but I think its ok
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

    /**
     * @notice Validates multiple proofs in a batch and claims rewards
     * @param proofs Array of proof data to validate
     * @param routeHashes Array of route hashes corresponding to each proof
     * @param proverRewards Array of reward structures corresponding to each proof
     */
    function validateBatchAndClaim(
        bytes[] calldata proofs,
        bytes32[] calldata routeHashes,
        ProverReward[] calldata proverRewards
    ) external {
        bytes32[] memory intentHashes = new bytes32[](proofs.length);
        address[] memory claimants = new address[](proofs.length);
        Reward[] memory rewards = new Reward[](proverRewards.length);

        for (uint256 i = 0; i < proofs.length; i++) {
            (bytes32 intentHash, address claimant) = _validateProof(proofs[i]);
            intentHashes[i] = intentHash;
            claimants[i] = claimant;
            rewards[i] = _toReward(proverRewards[i]);
            validateIntentHash(routeHashes[i], rewards[i], intentHashes[i]);
            emit IntentProven(intentHash, claimant); //might want a new event, but I think its ok
        }

        IIntentSource(INTENT_SOURCE).batchPushWithdraw(
            intentHashes,
            routeHashes,
            rewards,
            claimants
        );
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
        if (calculatedIntentHash != expectedIntentHash)
            revert IntentHashMismatch();
    }

    /**
     * @notice Converts a proverReward struct to a Reward struct
     * @param _proverReward The proverReward struct to convert
     * @return Reward struct with this contract as the prover
     */
    function _toReward(
        ProverReward memory _proverReward
    ) internal view returns (Reward memory) {
        return Reward(
            _proverReward.creator,
            address(this),
            _proverReward.deadline,
            _proverReward.nativeValue,
            _proverReward.tokens
        );
    }

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

    // Packed proof validation functions

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

    /**
     * @notice Validates a packed proof and claims rewards
     * @param proof The packed proof data to validate
     * @param routeHashes Array of route hashes corresponding to intents in the proof
     * @param proverRewards Array of reward structures corresponding to intents in the proof
     */
    function validatePackedAndClaim(
        bytes calldata proof,
        bytes32[] calldata routeHashes,
        ProverReward[] calldata proverRewards
    ) external {
        if (routeHashes.length != proverRewards.length) revert SizeMismatch();
        _validatePackedAndClaim(proof, routeHashes, proverRewards);
    }

    /**
     * @notice Validates multiple packed proofs in a batch and claims rewards
     * @param proofs Array of packed proof data to validate
     * @param routeHashes 2D array of route hashes corresponding to intents in each proof
     * @param proverRewards 2D array of reward structures corresponding to intents in each proof
     */
    function validateBatchPackedAndClaim(
        bytes[] calldata proofs,
        bytes32[][] calldata routeHashes,
        ProverReward[][] calldata proverRewards
    ) external {
        for (uint256 i = 0; i < proofs.length; i++) {
            if (routeHashes[i].length != proverRewards[i].length)
                revert SizeMismatch();
            _validatePackedAndClaim(
                proofs[i],
                routeHashes[i],
                proverRewards[i]
            );
        }
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

    /**
     * @notice Internal function to validate a packed proof and prepare for claiming
     * @param proof The packed proof data to validate
     * @param routeHashes Array of route hashes corresponding to intents in the proof
     * @param proverRewards Array of reward structures corresponding to intents in the proof
     */
    function _validatePackedAndClaim(
        bytes calldata proof,
        bytes32[] calldata routeHashes,
        ProverReward[] calldata proverRewards
    ) internal {
        (
            uint32 chainId,
            address emittingContract,
            bytes memory topics,
            bytes memory data
        ) = CROSS_L2_PROVER_V2.validateEvent(proof);

        checkInboxContract(emittingContract);
        checkSupportedChainId(chainId);
        checkTopicLength(topics, 64); //signature and chainId
        checkTopicSignature(bytes32(topics), BATCH_PROOF_SELECTOR);

        uint256 expectedSize = routeHashes.length;
        (
            bytes32[] memory intentHashes,
            address[] memory claimants
        ) = decodeMessageBeforeClaim(data, expectedSize);

        Reward[] memory rewards = new Reward[](expectedSize);
        for (uint256 i = 0; i < expectedSize; i++) {
            rewards[i] = _toReward(proverRewards[i]);
            validateIntentHash(routeHashes[i], rewards[i], intentHashes[i]);
            emit IntentProven(intentHashes[i], claimants[i]); 
        }
        IIntentSource(INTENT_SOURCE).batchPushWithdraw(
            intentHashes,
            routeHashes,
            rewards,
            claimants
        );
    }

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

    // Validation helper functions
    function checkTopicSignature(bytes32 topic, bytes32 selector) internal pure {
        if (topic != selector) revert InvalidEventSignature();
    }

    function checkInboxContract(address emittingContract) internal view {
        if (emittingContract != INBOX) revert InvalidEmittingContract();
    }

    function checkSupportedChainId(uint32 chainId) internal view {
        if (!supportedChainIds[chainId]) revert UnsupportedChainId();
    }

    function checkTopicLength(bytes memory topics, uint256 length) internal pure {
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
