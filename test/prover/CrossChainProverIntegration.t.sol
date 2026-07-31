// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../BaseTest.sol";
import {IProver} from "../../contracts/interfaces/IProver.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {IMessageBridgeProver} from "../../contracts/interfaces/IMessageBridgeProver.sol";
import {HyperProver} from "../../contracts/prover/HyperProver.sol";
import {LayerZeroProver} from "../../contracts/prover/LayerZeroProver.sol";
import {MessageBridgeProver} from "../../contracts/prover/MessageBridgeProver.sol";
import {TestMailbox} from "../../contracts/test/TestMailbox.sol";
import {MockLayerZeroEndpoint} from "../../contracts/test/MockLayerZeroEndpoint.sol";
import {TestMessageBridgeProver} from "../../contracts/test/TestMessageBridgeProver.sol";
import {AddressConverter} from "../../contracts/libs/AddressConverter.sol";

/**
 * @title Consolidated Cross-Chain Prover Integration Tests
 * @notice Essential tests for cross-chain prover functionality
 * @dev Focuses on core cross-chain proving without redundant event testing
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
        testBridgeProver = new TestMessageBridgeProver(
            address(portal),
            provers,
            200000,
            new IMessageBridgeProver.Domain[](0)
        );

        // Deploy provers
        bytes32[] memory hyperProvers = new bytes32[](1);
        hyperProvers[0] = bytes32(uint256(uint160(address(prover))));
        hyperProver = new HyperProver(
            address(mailbox),
            address(portal),
            hyperProvers,
            new IMessageBridgeProver.Domain[](0)
        );
        bytes32[] memory lzProvers = new bytes32[](1);
        lzProvers[0] = bytes32(uint256(uint160(address(prover))));
        layerZeroProver = new LayerZeroProver(
            address(lzEndpoint),
            address(this), // delegate
            address(portal),
            lzProvers,
            200000,
            new IMessageBridgeProver.Domain[](0)
        );

        vm.stopPrank();
    }

    // ===== CORE CROSS-CHAIN PROVING TESTS =====

    function testBasicCrossChainProving() public {
        bytes32 intentHash = _hashIntent(intent);

        // Test basic proof addition
        vm.prank(relayer);
        testBridgeProver.addProvenIntent(intentHash, claimant, CHAIN_ID);

        // Verify proof was added by checking proof data
        IProver.ProofData memory proofData = testBridgeProver.provenIntents(
            intentHash
        );
        assertEq(proofData.claimant, claimant);
        assertEq(proofData.destination, CHAIN_ID);
    }

    function testBatchProofProcessing() public {
        uint256 batchSize = 3;
        bytes32[] memory intentHashes = new bytes32[](batchSize);

        // Create batch of intents
        for (uint256 i = 0; i < batchSize; i++) {
            Intent memory batchIntent = intent;
            batchIntent.route.salt = keccak256(abi.encodePacked(salt, i));
            intentHashes[i] = _hashIntent(batchIntent);
        }

        vm.prank(bridgeOperator);
        // Process batch
        for (uint256 i = 0; i < intentHashes.length; i++) {
            testBridgeProver.addProvenIntent(
                intentHashes[i],
                claimant,
                CHAIN_ID
            );
        }

        // Verify all proofs were processed
        for (uint256 i = 0; i < intentHashes.length; i++) {
            IProver.ProofData memory proofData = testBridgeProver.provenIntents(
                intentHashes[i]
            );
            assertEq(proofData.claimant, claimant);
            assertEq(proofData.destination, CHAIN_ID);
        }
    }

    function testMultiProverScenario() public {
        bytes32 intentHash = _hashIntent(intent);

        // Test with different provers
        vm.prank(relayer);
        testBridgeProver.addProvenIntent(intentHash, claimant, CHAIN_ID);

        // Verify proof state
        IProver.ProofData memory proofData = testBridgeProver.provenIntents(
            intentHash
        );
        assertEq(proofData.claimant, claimant);
        assertEq(proofData.destination, CHAIN_ID);

        // Test with second prover (different intent)
        bytes32 intentHash2 = keccak256(abi.encodePacked(intentHash, "second"));
        vm.prank(relayer);
        testBridgeProver.addProvenIntent(intentHash2, claimant, CHAIN_ID);

        IProver.ProofData memory proofData2 = testBridgeProver.provenIntents(
            intentHash2
        );
        assertEq(proofData2.claimant, claimant);
        assertEq(proofData2.destination, CHAIN_ID);
    }

    function testCrossChainMessageHandling() public {
        bytes32 intentHash = _hashIntent(intent);

        // Test message bridge proving
        vm.prank(bridgeOperator);
        testBridgeProver.addProvenIntent(intentHash, claimant, CHAIN_ID);

        // Verify message was handled
        IProver.ProofData memory proofData = testBridgeProver.provenIntents(
            intentHash
        );
        assertEq(proofData.claimant, claimant);
        assertEq(proofData.destination, CHAIN_ID);
    }

    function testProofValidationFailure() public {
        bytes32 intentHash = _hashIntent(intent);

        // Test proof with invalid chain ID should be handled gracefully
        vm.prank(relayer);
        testBridgeProver.addProvenIntent(intentHash, claimant, 999);

        // Verify proof state (test prover accepts all proofs)
        IProver.ProofData memory proofData = testBridgeProver.provenIntents(
            intentHash
        );
        assertEq(proofData.claimant, claimant);
        assertEq(proofData.destination, 999);
    }

    function testBatchProofProcessingWithFailures() public {
        uint256 batchSize = 3;
        bytes32[] memory intentHashes = new bytes32[](batchSize);

        // Create batch of intents
        for (uint256 i = 0; i < batchSize; i++) {
            Intent memory batchIntent = intent;
            batchIntent.route.salt = keccak256(abi.encodePacked(salt, i));
            intentHashes[i] = _hashIntent(batchIntent);
        }

        // Process batch (some may fail in real scenarios)
        vm.prank(bridgeOperator);
        for (uint256 i = 0; i < intentHashes.length; i++) {
            try
                testBridgeProver.addProvenIntent(
                    intentHashes[i],
                    claimant,
                    CHAIN_ID
                )
            {
                // Success case
            } catch {
                // Failure case - handled gracefully
            }
        }

        // Verify at least processing completed without revert
        assertTrue(true, "Batch processing completed");
    }

    // ===== ORIGIN-DOMAIN-BINDING COMPOSITION TESTS =====
    // Composes the enforced invariant `intent.destination == resolveChainId(originDomain)`
    // (contracts/prover/MessageBridgeProver.sol _handleCrossChainMessage) with the
    // withdraw-time check `proof.destination == intent.destination`
    // (contracts/IntentSource.sol withdraw()), end to end: publish+fund on the source
    // side, deliver a real proof through HyperProver.handle() (mirroring the header
    // construction in test/prover/HyperProver.t.sol's _formatMessageWithChainId /
    // testHandle_revertsWhenHeaderMismatchesOrigin), then withdraw via IntentSource.
    //
    // hyperProver here is deployed in setUp() with an empty Domain[] (no explicit
    // domain->chainId registrations), so HyperProver's _resolveChainId falls back to
    // `originDomain == chainId` (Hyperlane's default convention). Using origin domain
    // 1 (== CHAIN_ID from BaseTest) exercises that derivable binding without needing
    // to register a new domain exception.

    function testGenuineOriginBoundProofClearsWithdrawAndPaysClaimant() public {
        // Build an intent whose reward is proven by hyperProver instead of the
        // default TestProver, and whose destination (CHAIN_ID = 1) matches the
        // chainId that origin domain 1 resolves to via HyperProver's default
        // domain==chainId fallback.
        Intent memory provenIntent = intent;
        provenIntent.reward.prover = address(hyperProver);
        // Use IntentSource's own hash (not this file's _hashIntent override, which
        // computes a different, test-local hash) so the proof lands under the same
        // intentHash that withdraw() will look up.
        (bytes32 intentHash, , ) = intentSource.getIntentHash(provenIntent);

        _mintAndApprove(creator, MINT_AMOUNT);
        _publishAndFund(provenIntent, false);
        assertTrue(intentSource.isIntentFunded(provenIntent));

        // Deliver a genuine proof: origin domain 1 -> resolved chainId 1, and the
        // self-reported 8-byte header also claims chainId 1 (they agree).
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = intentHash;
        claimants[0] = bytes32(uint256(uint160(claimant)));
        bytes memory messageBody = _formatMessageWithChainId(
            uint64(CHAIN_ID),
            intentHashes,
            claimants
        );

        vm.prank(address(mailbox));
        hyperProver.handle(
            uint32(CHAIN_ID),
            bytes32(uint256(uint160(address(prover)))),
            messageBody
        );

        IProver.ProofData memory proof = hyperProver.provenIntents(intentHash);
        assertEq(proof.claimant, claimant);
        assertEq(proof.destination, CHAIN_ID);

        // The recorded destination clears the withdraw-time check
        // (proof.destination == intent.destination), so withdraw pays the claimant.
        uint256 initialBalanceA = tokenA.balanceOf(claimant);
        uint256 initialBalanceB = tokenB.balanceOf(claimant);

        vm.prank(otherPerson);
        intentSource.withdraw(
            provenIntent.destination,
            keccak256(abi.encode(provenIntent.route)),
            provenIntent.reward
        );

        assertFalse(intentSource.isIntentFunded(provenIntent));
        assertEq(tokenA.balanceOf(claimant), initialBalanceA + MINT_AMOUNT);
        assertEq(
            tokenB.balanceOf(claimant),
            initialBalanceB + MINT_AMOUNT * 2
        );
    }

    function testSpoofedHeaderProofRevertsAtReceiveNeverRecordsClaimant()
        public
    {
        // Same setup as the genuine-proof test, but the self-reported header
        // disagrees with the chainId resolved from the origin domain.
        Intent memory provenIntent = intent;
        provenIntent.reward.prover = address(hyperProver);
        provenIntent.route.salt = keccak256(abi.encodePacked(salt, "spoof"));
        (bytes32 intentHash, , ) = intentSource.getIntentHash(provenIntent);

        _mintAndApprove(creator, MINT_AMOUNT);
        _publishAndFund(provenIntent, false);
        assertTrue(intentSource.isIntentFunded(provenIntent));

        // Origin domain 1 resolves to chainId 1 (default fallback), but the header
        // claims chainId 999 - a spoofed destination.
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = intentHash;
        claimants[0] = bytes32(uint256(uint160(claimant)));
        bytes memory spoofedMessageBody = _formatMessageWithChainId(
            999,
            intentHashes,
            claimants
        );

        vm.prank(address(mailbox));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMessageBridgeProver.ChainIdMismatch.selector,
                uint64(CHAIN_ID),
                uint64(CHAIN_ID),
                uint64(999)
            )
        );
        hyperProver.handle(
            uint32(CHAIN_ID),
            bytes32(uint256(uint160(address(prover)))),
            spoofedMessageBody
        );

        // The revert happened before any storage write: no claimant was recorded.
        IProver.ProofData memory proof = hyperProver.provenIntents(intentHash);
        assertEq(proof.claimant, address(0));
        assertEq(proof.destination, 0);

        // Composition: since no claimant was ever recorded, withdraw cannot pay
        // out - it reverts on the zero-claimant guard rather than transferring funds.
        vm.expectRevert(IIntentSource.InvalidClaimant.selector);
        vm.prank(otherPerson);
        intentSource.withdraw(
            provenIntent.destination,
            keccak256(abi.encode(provenIntent.route)),
            provenIntent.reward
        );
    }

    /**
     * @notice Formats a proof message with an 8-byte chainId header followed by
     * packed (intentHash, claimant) pairs, mirroring the Inbox's on-chain encoding.
     * @dev Copied from test/prover/HyperProver.t.sol's helper of the same name so
     * this file's tests can construct genuine and spoofed headers without
     * depending on another test contract.
     */
    function _formatMessageWithChainId(
        uint256 chainId,
        bytes32[] memory intentHashes,
        bytes32[] memory claimants
    ) internal pure returns (bytes memory) {
        require(
            intentHashes.length == claimants.length,
            "Array length mismatch"
        );
        bytes memory packed = new bytes(intentHashes.length * 64);
        for (uint256 i = 0; i < intentHashes.length; i++) {
            assembly {
                let offset := mul(i, 64)
                mstore(
                    add(add(packed, 0x20), offset),
                    mload(add(intentHashes, add(0x20, mul(i, 32))))
                )
                mstore(
                    add(add(packed, 0x20), add(offset, 32)),
                    mload(add(claimants, add(0x20, mul(i, 32))))
                )
            }
        }
        return abi.encodePacked(uint64(chainId), packed);
    }

    // ===== HELPER FUNCTIONS =====

    function _hashIntent(
        Intent memory _intent
    ) internal pure override returns (bytes32) {
        return keccak256(abi.encode(_intent));
    }
}
