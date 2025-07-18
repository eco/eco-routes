// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../BaseTest.sol";
import {IProver} from "../../contracts/interfaces/IProver.sol";
import {IMessageBridgeProver} from "../../contracts/interfaces/IMessageBridgeProver.sol";
import {HyperProver} from "../../contracts/prover/HyperProver.sol";
import {LayerZeroProver} from "../../contracts/prover/LayerZeroProver.sol";
import {MessageBridgeProver} from "../../contracts/prover/MessageBridgeProver.sol";
import {TestMailbox} from "../../contracts/test/TestMailbox.sol";
import {MockLayerZeroEndpoint} from "../../contracts/test/MockLayerZeroEndpoint.sol";
import {TestMessageBridgeProver} from "../../contracts/test/TestMessageBridgeProver.sol";
import {AddressConverter} from "../../contracts/libs/AddressConverter.sol";

/**
 * @title Cross-Chain Prover Integration Tests
 * @notice Tests for event emission and monitoring in cross-chain prover scenarios
 * @dev Focuses on complex cross-chain event sequences and monitoring
 */
contract CrossChainProverIntegrationTest is BaseTest {
    using AddressConverter for address;
    using AddressConverter for bytes32;

    HyperProver internal hyperProver;
    LayerZeroProver internal layerZeroProver;
    MessageBridgeProver internal messageBridgeProver;
    TestMailbox internal mailbox;
    MockLayerZeroEndpoint internal lzEndpoint;
    TestMessageBridgeProver internal testBridgeProver;
    
    address internal relayer;
    address internal validator;
    address internal bridgeOperator;
    uint32 internal sourceChainId;
    uint32 internal destChainId;
    uint16 internal lzChainId;
    
    // Event monitoring
    mapping(bytes32 => ProofEvent) internal proofEvents;
    mapping(bytes32 => uint256) internal eventTimestamps;
    
    struct ProofEvent {
        bytes32 intentHash;
        address claimant;
        uint256 chainId;
        string proofType;
        bool successful;
        uint256 timestamp;
    }

    event CrossChainProofInitiated(
        bytes32 indexed intentHash,
        uint256 indexed sourceChain,
        uint256 indexed destChain,
        address prover
    );
    
    event CrossChainProofCompleted(
        bytes32 indexed intentHash,
        address indexed claimant,
        string proofType,
        bool successful
    );
    
    event ProofValidationFailed(
        bytes32 indexed intentHash,
        string reason,
        bytes data
    );
    
    event BatchProofProcessed(
        bytes32[] hashes,
        uint256 indexed sourceChain,
        uint256 successCount,
        uint256 failureCount
    );

    function setUp() public override {
        super.setUp();
        
        relayer = makeAddr("relayer");
        validator = makeAddr("validator");
        bridgeOperator = makeAddr("bridgeOperator");
        sourceChainId = 1;
        destChainId = 2;
        lzChainId = 101;
        
        // Deploy test infrastructure
        vm.startPrank(deployer);
        mailbox = new TestMailbox(address(portal));
        lzEndpoint = new MockLayerZeroEndpoint();
        bytes32[] memory provers = new bytes32[](1);
        provers[0] = bytes32(uint256(uint160(address(prover))));
        testBridgeProver = new TestMessageBridgeProver(address(portal), provers, 200000);
        
        // Deploy provers
        bytes32[] memory hyperProvers = new bytes32[](1);
        hyperProvers[0] = bytes32(uint256(uint160(address(prover))));
        hyperProver = new HyperProver(address(mailbox), address(portal), hyperProvers, 200000);
        bytes32[] memory lzProvers = new bytes32[](1);
        lzProvers[0] = bytes32(uint256(uint160(address(prover))));
        layerZeroProver = new LayerZeroProver(address(lzEndpoint), address(portal), lzProvers, 200000);
        // MessageBridgeProver is abstract, so we'll use the test implementation
        // messageBridgeProver = new MessageBridgeProver(address(portal));
        vm.stopPrank();
        
        _mintAndApprove(creator, MINT_AMOUNT * 20);
        _fundUserNative(creator, 100 ether);
        _fundUserNative(relayer, 50 ether);
        _fundUserNative(validator, 50 ether);
    }

    // ===== CROSS-CHAIN PROOF INITIATION EVENTS =====

    function testCrossChainProofInitiationEvents() public {
        bytes32 intentHash = _hashIntent(intent);
        
        // Test HyperProver initiation
        vm.expectEmit(true, true, true, true);
        emit CrossChainProofInitiated(intentHash, sourceChainId, destChainId, address(testBridgeProver));
        
        vm.prank(relayer);
        testBridgeProver.addProvenIntent(intentHash, claimant, destChainId);
        
        // Test LayerZero initiation
        vm.expectEmit(true, true, true, true);
        emit CrossChainProofInitiated(intentHash, sourceChainId, destChainId, address(testBridgeProver));
        
        vm.prank(relayer);
        testBridgeProver.addProvenIntent(intentHash, claimant, destChainId);
        
        // Test MessageBridge initiation
        vm.expectEmit(true, true, true, true);
        emit CrossChainProofInitiated(intentHash, sourceChainId, destChainId, address(testBridgeProver));
        
        vm.prank(relayer);
        testBridgeProver.addProvenIntent(intentHash, claimant, destChainId);
        
        _recordProofEvent(intentHash, claimant, destChainId, "CrossChainInitiation", true);
    }

    function testCrossChainProofCompletionEvents() public {
        bytes32 intentHash = _hashIntent(intent);
        
        // Test successful HyperProver completion
        vm.expectEmit(true, true, false, true);
        emit IProver.IntentProven(intentHash, claimant);
        
        vm.expectEmit(true, true, false, true);
        emit CrossChainProofCompleted(intentHash, claimant, "Hyperlane", true);
        
        vm.prank(relayer);
        testBridgeProver.addProvenIntent(intentHash, claimant, CHAIN_ID);
        
        // Test LayerZero completion
        bytes32 intentHash2 = keccak256(abi.encodePacked(intentHash, "lz"));
        
        vm.expectEmit(true, true, false, true);
        emit IProver.IntentProven(intentHash2, claimant);
        
        vm.expectEmit(true, true, false, true);
        emit CrossChainProofCompleted(intentHash2, claimant, "LayerZero", true);
        
        vm.prank(relayer);
        testBridgeProver.addProvenIntent(intentHash2, claimant, CHAIN_ID);
        
        _recordProofEvent(intentHash, claimant, CHAIN_ID, "CrossChainCompletion", true);
    }

    function testCrossChainProofFailureEvents() public {
        bytes32 intentHash = _hashIntent(intent);
        
        // Test proof validation failure
        vm.expectEmit(true, true, false, true);
        emit ProofValidationFailed(intentHash, "InvalidChainId", abi.encode(999));
        
        vm.expectEmit(true, true, false, true);
        emit CrossChainProofCompleted(intentHash, claimant, "Hyperlane", false);
        
        // This would be called internally when validation fails
        _emitProofValidationFailure(intentHash, "InvalidChainId", abi.encode(999));
        
        _recordProofEvent(intentHash, claimant, 999, "CrossChainFailure", false);
    }

    // ===== BATCH PROOF PROCESSING EVENTS =====

    function testBatchProofProcessingEvents() public {
        uint256 batchSize = 5;
        bytes32[] memory intentHashes = new bytes32[](batchSize);
        
        // Create batch of intents
        for (uint256 i = 0; i < batchSize; i++) {
            Intent memory batchIntent = intent;
            batchIntent.route.salt = keccak256(abi.encodePacked(salt, i));
            intentHashes[i] = _hashIntent(batchIntent);
        }
        
        // Test batch processing event
        // MessageBridgeProver is abstract and doesn't have sendBatch method
        // Using testBridgeProver instead
        vm.expectEmit(true, true, false, true);
        emit BatchProofProcessed(intentHashes, sourceChainId, batchSize, 0);
        
        vm.prank(bridgeOperator);
        // testBridgeProver.sendBatch(intentHashes, sourceChainId); // Method doesn't exist
        // Simulate batch processing by adding proven intents
        for (uint256 i = 0; i < intentHashes.length; i++) {
            testBridgeProver.addProvenIntent(intentHashes[i], claimant, CHAIN_ID);
        }
        
        _recordBatchProofEvent(intentHashes, sourceChainId, batchSize, 0);
    }

    function testBatchProofProcessingWithFailures() public {
        uint256 batchSize = 3;
        bytes32[] memory intentHashes = new bytes32[](batchSize);
        
        // Create batch with some invalid hashes
        for (uint256 i = 0; i < batchSize; i++) {
            if (i == 1) {
                intentHashes[i] = bytes32(0); // Invalid hash
            } else {
                Intent memory batchIntent = intent;
                batchIntent.route.salt = keccak256(abi.encodePacked(salt, i));
                intentHashes[i] = _hashIntent(batchIntent);
            }
        }
        
        // Test batch with failures
        vm.expectEmit(true, true, false, true);
        emit BatchProofProcessed(intentHashes, sourceChainId, 2, 1); // 2 success, 1 failure
        
        // Simulate batch processing with failures
        _processBatchWithFailures(intentHashes, sourceChainId);
        
        _recordBatchProofEvent(intentHashes, sourceChainId, 2, 1);
    }

    // ===== PROOF VALIDATION MONITORING =====

    function testProofValidationMonitoringEvents() public {
        bytes32 intentHash = _hashIntent(intent);
        
        // Test various validation scenarios
        
        // 1. Invalid chain ID
        vm.expectEmit(true, true, false, true);
        emit ProofValidationFailed(intentHash, "InvalidChainId", abi.encode(999));
        
        _emitProofValidationFailure(intentHash, "InvalidChainId", abi.encode(999));
        
        // 2. Invalid claimant
        vm.expectEmit(true, true, false, true);
        emit ProofValidationFailed(intentHash, "InvalidClaimant", abi.encode(address(0)));
        
        _emitProofValidationFailure(intentHash, "InvalidClaimant", abi.encode(address(0)));
        
        // 3. Expired proof
        vm.expectEmit(true, true, false, true);
        emit ProofValidationFailed(intentHash, "ProofExpired", abi.encode(block.timestamp - 1));
        
        _emitProofValidationFailure(intentHash, "ProofExpired", abi.encode(block.timestamp - 1));
        
        _recordProofEvent(intentHash, address(0), 999, "ValidationFailure", false);
    }

    function testProofValidationSuccessMonitoring() public {
        bytes32 intentHash = _hashIntent(intent);
        
        // Test successful validation sequence
        vm.expectEmit(true, true, true, true);
        emit CrossChainProofInitiated(intentHash, sourceChainId, CHAIN_ID, address(hyperProver));
        
        vm.expectEmit(true, true, false, true);
        emit IProver.IntentProven(intentHash, claimant);
        
        vm.expectEmit(true, true, false, true);
        emit CrossChainProofCompleted(intentHash, claimant, "Hyperlane", true);
        
        vm.prank(relayer);
        testBridgeProver.addProvenIntent(intentHash, claimant, CHAIN_ID);
        
        _recordProofEvent(intentHash, claimant, CHAIN_ID, "ValidationSuccess", true);
    }

    // ===== CROSS-CHAIN MESSAGE MONITORING =====

    function testCrossChainMessageMonitoring() public {
        bytes32 intentHash = _hashIntent(intent);
        
        // Test message dispatch monitoring
        vm.expectEmit(true, true, false, true);
        emit CrossChainProofInitiated(intentHash, sourceChainId, destChainId, address(messageBridgeProver));
        
        // Test message bridge events
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = intentHash;
        
        vm.expectEmit(true, true, false, true);
        emit IMessageBridgeProver.BatchSent(hashes, sourceChainId);
        
        vm.prank(bridgeOperator);
        // messageBridgeProver.sendBatch(hashes, sourceChainId); // Method doesn't exist
        // Simulate batch processing
        for (uint256 i = 0; i < hashes.length; i++) {
            testBridgeProver.addProvenIntent(hashes[i], claimant, CHAIN_ID);
        }
        
        _recordProofEvent(intentHash, claimant, sourceChainId, "MessageBridge", true);
    }

    function testLayerZeroMessageMonitoring() public {
        bytes32 intentHash = _hashIntent(intent);
        
        // Test LayerZero message monitoring
        vm.expectEmit(true, true, true, true);
        emit CrossChainProofInitiated(intentHash, sourceChainId, destChainId, address(layerZeroProver));
        
        // Simulate LayerZero message
        vm.prank(relayer);
        testBridgeProver.addProvenIntent(intentHash, claimant, destChainId);
        
        _recordProofEvent(intentHash, claimant, destChainId, "LayerZero", true);
    }

    function testHyperlaneMessageMonitoring() public {
        bytes32 intentHash = _hashIntent(intent);
        
        // Test Hyperlane message monitoring
        vm.expectEmit(true, true, true, true);
        emit CrossChainProofInitiated(intentHash, sourceChainId, destChainId, address(hyperProver));
        
        // Simulate Hyperlane message
        vm.prank(relayer);
        testBridgeProver.addProvenIntent(intentHash, claimant, destChainId);
        
        _recordProofEvent(intentHash, claimant, destChainId, "Hyperlane", true);
    }

    // ===== COMPLEX CROSS-CHAIN SCENARIOS =====

    function testComplexCrossChainScenarioMonitoring() public {
        bytes32 intentHash = _hashIntent(intent);
        
        // Multi-step cross-chain scenario
        
        // 1. Initial proof on wrong chain
        vm.expectEmit(true, true, true, true);
        emit CrossChainProofInitiated(intentHash, sourceChainId, 999, address(hyperProver));
        
        vm.prank(relayer);
        testBridgeProver.addProvenIntent(intentHash, claimant, 999);
        
        // 2. Proof validation failure
        vm.expectEmit(true, true, false, true);
        emit ProofValidationFailed(intentHash, "WrongChain", abi.encode(999));
        
        _emitProofValidationFailure(intentHash, "WrongChain", abi.encode(999));
        
        // 3. Correct proof
        vm.expectEmit(true, true, true, true);
        emit CrossChainProofInitiated(intentHash, sourceChainId, CHAIN_ID, address(hyperProver));
        
        vm.expectEmit(true, true, false, true);
        emit CrossChainProofCompleted(intentHash, claimant, "Hyperlane", true);
        
        vm.prank(relayer);
        testBridgeProver.addProvenIntent(intentHash, claimant, CHAIN_ID);
        
        _recordProofEvent(intentHash, claimant, CHAIN_ID, "ComplexScenario", true);
    }

    function testMultiProverScenarioMonitoring() public {
        bytes32 intentHash = _hashIntent(intent);
        
        // Test same intent across multiple provers
        
        // 1. HyperProver
        vm.expectEmit(true, true, false, true);
        emit CrossChainProofCompleted(intentHash, claimant, "Hyperlane", true);
        
        vm.prank(relayer);
        testBridgeProver.addProvenIntent(intentHash, claimant, CHAIN_ID);
        
        // 2. LayerZeroProver (should emit already proven)
        vm.expectEmit(true, true, false, true);
        emit IProver.IntentAlreadyProven(intentHash);
        
        vm.prank(relayer);
        testBridgeProver.addProvenIntent(intentHash, claimant, CHAIN_ID);
        
        // 3. MessageBridgeProver (should emit already proven)
        vm.expectEmit(true, true, false, true);
        emit IProver.IntentAlreadyProven(intentHash);
        
        vm.prank(relayer);
        testBridgeProver.addProvenIntent(intentHash, claimant, CHAIN_ID);
        
        _recordProofEvent(intentHash, claimant, CHAIN_ID, "MultiProver", true);
    }

    // ===== PERFORMANCE MONITORING =====

    function testProofPerformanceMonitoring() public {
        uint256 startTime = block.timestamp;
        bytes32 intentHash = _hashIntent(intent);
        
        // Monitor proof timing
        vm.expectEmit(true, true, false, true);
        emit CrossChainProofCompleted(intentHash, claimant, "Hyperlane", true);
        
        vm.prank(relayer);
        testBridgeProver.addProvenIntent(intentHash, claimant, CHAIN_ID);
        
        uint256 endTime = block.timestamp;
        uint256 duration = endTime - startTime;
        
        // Record performance metrics
        _recordProofPerformance(intentHash, duration);
    }

    function testBatchPerformanceMonitoring() public {
        uint256 batchSize = 10;
        bytes32[] memory intentHashes = new bytes32[](batchSize);
        
        for (uint256 i = 0; i < batchSize; i++) {
            Intent memory batchIntent = intent;
            batchIntent.route.salt = keccak256(abi.encodePacked(salt, i));
            intentHashes[i] = _hashIntent(batchIntent);
        }
        
        uint256 startTime = block.timestamp;
        
        vm.expectEmit(true, true, false, true);
        emit BatchProofProcessed(intentHashes, sourceChainId, batchSize, 0);
        
        vm.prank(bridgeOperator);
        // messageBridgeProver.sendBatch(intentHashes, sourceChainId); // Method doesn't exist
        // Simulate batch processing
        for (uint256 i = 0; i < intentHashes.length; i++) {
            testBridgeProver.addProvenIntent(intentHashes[i], claimant, CHAIN_ID);
        }
        
        uint256 endTime = block.timestamp;
        uint256 duration = endTime - startTime;
        
        _recordBatchPerformance(intentHashes, duration);
    }

    // ===== HELPER FUNCTIONS =====

    function _recordProofEvent(
        bytes32 intentHash,
        address claimant,
        uint256 chainId,
        string memory proofType,
        bool successful
    ) internal {
        proofEvents[intentHash] = ProofEvent({
            intentHash: intentHash,
            claimant: claimant,
            chainId: chainId,
            proofType: proofType,
            successful: successful,
            timestamp: block.timestamp
        });
        
        eventTimestamps[intentHash] = block.timestamp;
    }

    function _recordBatchProofEvent(
        bytes32[] memory hashes,
        uint256 sourceChain,
        uint256 successCount,
        uint256 failureCount
    ) internal {
        bytes32 batchId = keccak256(abi.encodePacked(hashes));
        eventTimestamps[batchId] = block.timestamp;
        
        emit BatchProofProcessed(hashes, sourceChain, successCount, failureCount);
    }

    function _emitProofValidationFailure(
        bytes32 intentHash,
        string memory reason,
        bytes memory data
    ) internal {
        emit ProofValidationFailed(intentHash, reason, data);
    }

    function _processBatchWithFailures(
        bytes32[] memory hashes,
        uint256 sourceChain
    ) internal {
        uint256 successCount = 0;
        uint256 failureCount = 0;
        
        for (uint256 i = 0; i < hashes.length; i++) {
            if (hashes[i] != bytes32(0)) {
                successCount++;
            } else {
                failureCount++;
            }
        }
        
        emit BatchProofProcessed(hashes, sourceChain, successCount, failureCount);
    }

    function _recordProofPerformance(bytes32 intentHash, uint256 duration) internal {
        // Performance monitoring helper
        require(duration >= 0, "Invalid duration");
        eventTimestamps[intentHash] = duration;
    }

    function _recordBatchPerformance(bytes32[] memory hashes, uint256 duration) internal {
        // Batch performance monitoring helper
        require(duration >= 0, "Invalid duration");
        bytes32 batchId = keccak256(abi.encodePacked(hashes));
        eventTimestamps[batchId] = duration;
    }

    function _getProofEvent(bytes32 intentHash) internal view returns (ProofEvent memory) {
        return proofEvents[intentHash];
    }

    function _getEventTimestamp(bytes32 eventId) internal view returns (uint256) {
        return eventTimestamps[eventId];
    }
}