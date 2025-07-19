// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseTest} from "../BaseTest.sol";
import {LayerZeroProver} from "../../contracts/prover/LayerZeroProver.sol";
import {ILayerZeroEndpointV2} from "../../contracts/interfaces/layerzero/ILayerZeroEndpointV2.sol";
import {ILayerZeroReceiver} from "../../contracts/interfaces/layerzero/ILayerZeroReceiver.sol";
import {Portal} from "../../contracts/Portal.sol";

contract MockLayerZeroEndpoint {
    mapping(uint32 => mapping(bytes32 => address)) public delegates;

    function send(
        ILayerZeroEndpointV2.MessagingParams calldata params,
        address /* refundAddress */
    ) external payable returns (ILayerZeroEndpointV2.MessagingReceipt memory) {
        return
            ILayerZeroEndpointV2.MessagingReceipt({
                guid: keccak256(abi.encode(params, block.timestamp)),
                nonce: 1,
                fee: ILayerZeroEndpointV2.MessagingFee({
                    nativeFee: msg.value,
                    lzTokenFee: 0
                })
            });
    }

    function quote(
        ILayerZeroEndpointV2.MessagingParams calldata /* params */,
        bool /* payInLzToken */
    ) external pure returns (ILayerZeroEndpointV2.MessagingFee memory) {
        return
            ILayerZeroEndpointV2.MessagingFee({
                nativeFee: 0.001 ether,
                lzTokenFee: 0
            });
    }

    function setDelegate(address delegate) external {
        delegates[uint32(block.chainid)][
            bytes32(uint256(uint160(msg.sender)))
        ] = delegate;
    }
}

contract LayerZeroProverTest is BaseTest {
    LayerZeroProver public lzProver;
    MockLayerZeroEndpoint public endpoint;

    uint256 constant SOURCE_CHAIN_ID = 10;
    uint256 constant DEST_CHAIN_ID = 1;
    bytes32 constant SOURCE_PROVER =
        bytes32(uint256(uint160(0x1234567890123456789012345678901234567890)));

    function setUp() public override {
        super.setUp();

        endpoint = new MockLayerZeroEndpoint();

        bytes32[] memory trustedProvers = new bytes32[](1);
        trustedProvers[0] = SOURCE_PROVER;

        lzProver = new LayerZeroProver(
            address(endpoint),
            address(portal),
            trustedProvers,
            200000
        );
    }

    function test_constructor() public view {
        assertEq(lzProver.ENDPOINT(), address(endpoint));
        assertEq(lzProver.PORTAL(), address(portal));
        assertTrue(lzProver.isWhitelisted(SOURCE_PROVER));
        assertEq(lzProver.DEFAULT_GAS_LIMIT(), 200000);
    }

    function test_getProofType() public view {
        assertEq(lzProver.getProofType(), "LayerZero");
    }

    function test_fetchFee() public view {
        bytes32[] memory intentHashes = new bytes32[](1);
        intentHashes[0] = keccak256("intent");

        bytes32[] memory claimants = new bytes32[](1);
        claimants[0] = bytes32(uint256(uint160(address(this))));

        bytes memory options = "";
        bytes memory data = abi.encode(SOURCE_PROVER, options);

        uint256 fee = lzProver.fetchFee(
            SOURCE_CHAIN_ID,
            intentHashes,
            claimants,
            data
        );
        assertEq(fee, 0.001 ether);
    }

    function test_prove() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        intentHashes[0] = keccak256("intent");

        bytes32[] memory claimants = new bytes32[](1);
        claimants[0] = bytes32(uint256(uint160(address(this))));

        bytes memory options = "";
        bytes memory data = abi.encode(SOURCE_PROVER, options);

        uint256 fee = lzProver.fetchFee(
            SOURCE_CHAIN_ID,
            intentHashes,
            claimants,
            data
        );

        vm.deal(address(portal), fee);
        vm.prank(address(portal));
        lzProver.prove{value: fee}(
            address(portal),
            SOURCE_CHAIN_ID,
            intentHashes,
            claimants,
            data
        );
    }

    function test_lzReceive() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        intentHashes[0] = keccak256("intent");

        bytes32[] memory claimants = new bytes32[](1);
        claimants[0] = bytes32(uint256(uint160(address(this))));

        ILayerZeroReceiver.Origin memory origin = ILayerZeroReceiver.Origin({
            srcEid: uint32(SOURCE_CHAIN_ID),
            sender: SOURCE_PROVER,
            nonce: 1
        });

        bytes memory message = abi.encode(intentHashes, claimants);

        vm.prank(address(endpoint));
        lzProver.lzReceive(origin, bytes32(0), message, address(0), "");

        LayerZeroProver.ProofData memory proofData = lzProver.provenIntents(
            intentHashes[0]
        );
        assertEq(proofData.claimant, address(this));
        assertEq(proofData.destination, SOURCE_CHAIN_ID);
    }

    function test_allowInitializePath() public view {
        ILayerZeroReceiver.Origin memory origin = ILayerZeroReceiver.Origin({
            srcEid: uint32(SOURCE_CHAIN_ID),
            sender: SOURCE_PROVER,
            nonce: 1
        });

        assertTrue(lzProver.allowInitializePath(origin));

        origin.sender = bytes32(uint256(uint160(address(0x9999))));
        assertFalse(lzProver.allowInitializePath(origin));
    }

    function test_constructor_revertEndpointZero() public {
        bytes32[] memory trustedProvers = new bytes32[](1);
        trustedProvers[0] = SOURCE_PROVER;

        vm.expectRevert(LayerZeroProver.EndpointCannotBeZeroAddress.selector);
        new LayerZeroProver(
            address(0),
            address(portal),
            trustedProvers,
            200000
        );
    }

    function test_lzReceive_revertInvalidSender() public {
        ILayerZeroReceiver.Origin memory origin = ILayerZeroReceiver.Origin({
            srcEid: uint32(SOURCE_CHAIN_ID),
            sender: SOURCE_PROVER,
            nonce: 1
        });

        vm.expectRevert();
        lzProver.lzReceive(origin, bytes32(0), "", address(0), "");
    }

    function test_lzReceive_revertInvalidExecutor() public {
        ILayerZeroReceiver.Origin memory origin = ILayerZeroReceiver.Origin({
            srcEid: uint32(SOURCE_CHAIN_ID),
            sender: SOURCE_PROVER,
            nonce: 1
        });

        vm.prank(address(endpoint));
        vm.expectRevert(
            abi.encodeWithSelector(
                LayerZeroProver.InvalidExecutor.selector,
                address(this)
            )
        );
        lzProver.lzReceive(origin, bytes32(0), "", address(this), "");
    }

    function test_prove_withCustomGasLimit() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        intentHashes[0] = keccak256("intent");

        bytes32[] memory claimants = new bytes32[](1);
        claimants[0] = bytes32(uint256(uint160(address(this))));

        bytes memory options = "";
        uint256 customGasLimit = 300000;
        bytes memory data = abi.encode(SOURCE_PROVER, options, customGasLimit);

        uint256 fee = lzProver.fetchFee(
            SOURCE_CHAIN_ID,
            intentHashes,
            claimants,
            data
        );

        vm.deal(address(portal), fee);
        vm.prank(address(portal));
        lzProver.prove{value: fee}(
            address(portal),
            SOURCE_CHAIN_ID,
            intentHashes,
            claimants,
            data
        );
    }

    function test_prove_chainIdValidation() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        intentHashes[0] = keccak256("intent");

        bytes32[] memory claimants = new bytes32[](1);
        claimants[0] = bytes32(uint256(uint160(address(this))));

        bytes memory options = "";
        bytes memory data = abi.encode(SOURCE_PROVER, options);

        uint256 invalidChainId = uint256(type(uint32).max) + 1;

        vm.expectRevert();
        lzProver.fetchFee(invalidChainId, intentHashes, claimants, data);
    }

    // ============ Challenge Intent Proof Tests ============
    // Note: Comprehensive challenge tests are in MetaProver.t.sol
    // Keeping only LayerZero-specific challenge test

    function testChallengeIntentProofWithWrongChain() public {
        // Create test data
        uint64 actualDestination = 1;
        uint64 wrongDestination = 2;
        bytes32 routeHash = keccak256("route");
        bytes32 rewardHash = keccak256("reward");
        bytes32 intentHash = keccak256(
            abi.encodePacked(actualDestination, routeHash, rewardHash)
        );

        // Setup a proof with wrong destination chain
        bytes32[] memory intentHashes = new bytes32[](1);
        intentHashes[0] = intentHash;

        bytes32[] memory claimants = new bytes32[](1);
        claimants[0] = bytes32(uint256(uint160(address(this))));

        ILayerZeroReceiver.Origin memory origin = ILayerZeroReceiver.Origin({
            srcEid: uint32(wrongDestination), // Wrong destination
            sender: SOURCE_PROVER,
            nonce: 1
        });

        bytes memory message = abi.encode(intentHashes, claimants);

        // Add the proof with wrong destination
        vm.prank(address(endpoint));
        lzProver.lzReceive(origin, bytes32(0), message, address(0), "");

        // Verify proof exists with wrong destination
        LayerZeroProver.ProofData memory proofBefore = lzProver.provenIntents(
            intentHash
        );
        assertEq(proofBefore.claimant, address(this));
        assertEq(proofBefore.destination, wrongDestination);

        // Challenge the proof with correct destination
        vm.expectEmit(true, true, true, true);
        emit IntentProven(intentHash, address(0)); // Emits with zero address to indicate removal

        lzProver.challengeIntentProof(actualDestination, routeHash, rewardHash);

        // Verify proof was cleared
        LayerZeroProver.ProofData memory proofAfter = lzProver.provenIntents(
            intentHash
        );
        assertEq(proofAfter.claimant, address(0));
        assertEq(proofAfter.destination, 0);
    }

    // ============================================================================
    // LayerZero-Specific Challenge Tests
    // ============================================================================

    function testChallengeIntentProofWithCorrectChain() public {
        // Create test data
        uint64 correctDestination = 1;
        bytes32 routeHash = keccak256("route");
        bytes32 rewardHash = keccak256("reward");
        bytes32 intentHash = keccak256(
            abi.encodePacked(correctDestination, routeHash, rewardHash)
        );

        // Setup a proof with correct destination chain
        bytes32[] memory intentHashes = new bytes32[](1);
        intentHashes[0] = intentHash;

        bytes32[] memory claimants = new bytes32[](1);
        claimants[0] = bytes32(uint256(uint160(address(this))));

        ILayerZeroReceiver.Origin memory origin = ILayerZeroReceiver.Origin({
            srcEid: uint32(correctDestination), // Correct destination
            sender: SOURCE_PROVER,
            nonce: 1
        });

        bytes memory message = abi.encode(intentHashes, claimants);

        // Add the proof with correct destination
        vm.prank(address(endpoint));
        lzProver.lzReceive(origin, bytes32(0), message, address(0), "");

        // Verify proof exists with correct destination
        LayerZeroProver.ProofData memory proofBefore = lzProver.provenIntents(
            intentHash
        );
        assertEq(proofBefore.claimant, address(this));
        assertEq(proofBefore.destination, correctDestination);

        // Challenge the proof with correct destination (should do nothing)
        lzProver.challengeIntentProof(
            correctDestination,
            routeHash,
            rewardHash
        );

        // Verify proof still exists
        LayerZeroProver.ProofData memory proofAfter = lzProver.provenIntents(
            intentHash
        );
        assertEq(proofAfter.claimant, address(this));
        assertEq(proofAfter.destination, correctDestination);
    }

    function testChallengeIntentProofLayerZeroSpecific() public {
        // Test LayerZero-specific edge cases
        uint64 actualDestination = 1;
        uint64 wrongDestination = 2;
        bytes32 routeHash = keccak256("route");
        bytes32 rewardHash = keccak256("reward");
        bytes32 intentHash = keccak256(
            abi.encodePacked(actualDestination, routeHash, rewardHash)
        );

        // Test with invalid srcEid
        bytes32[] memory intentHashes = new bytes32[](1);
        intentHashes[0] = intentHash;
        bytes32[] memory claimants = new bytes32[](1);
        claimants[0] = bytes32(uint256(uint160(address(this))));

        ILayerZeroReceiver.Origin memory origin = ILayerZeroReceiver.Origin({
            srcEid: uint32(wrongDestination), // Wrong destination
            sender: SOURCE_PROVER,
            nonce: 1
        });

        bytes memory message = abi.encode(intentHashes, claimants);

        // Add proof with wrong srcEid
        vm.prank(address(endpoint));
        lzProver.lzReceive(origin, bytes32(0), message, address(0), "");

        // Challenge should succeed for LayerZero-specific validation
        vm.expectEmit(true, true, true, true);
        emit IntentProven(intentHash, address(0));

        lzProver.challengeIntentProof(actualDestination, routeHash, rewardHash);

        // Verify proof was cleared
        LayerZeroProver.ProofData memory proofAfter = lzProver.provenIntents(
            intentHash
        );
        assertEq(proofAfter.claimant, address(0));
        assertEq(proofAfter.destination, 0);
    }

    // Helper to import the event for testing
    event IntentProven(bytes32 indexed hash, address indexed claimant);
}
