// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseTest} from "../BaseTest.sol";
import {LayerZeroPolicy} from "../../contracts/prover/LayerZeroPolicy.sol";
import {ILayerZeroEndpointV2} from "../../contracts/interfaces/layerzero/ILayerZeroEndpointV2.sol";
import {ILayerZeroReceiver} from "../../contracts/interfaces/layerzero/ILayerZeroReceiver.sol";
import {Portal} from "../../contracts/Portal.sol";
import {IPolicy} from "../../contracts/interfaces/IPolicy.sol";

contract MockLayerZeroEndpoint {
    mapping(address => address) public delegates;

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
        ILayerZeroEndpointV2.MessagingParams calldata,
        address
    ) external pure returns (ILayerZeroEndpointV2.MessagingFee memory) {
        return
            ILayerZeroEndpointV2.MessagingFee({
                nativeFee: 0.001 ether,
                lzTokenFee: 0
            });
    }

    function setDelegate(address delegate) external {
        delegates[msg.sender] = delegate;
    }
}

/**
 * @dev Extended mock that (a) records the `options` field from every `send()` call
 *      and (b) supports low-gas message delivery to reproduce the OOG wedge, and
 *      (c) exposes a delegate-gated `skip()` to prove post-revocation unrecoverability.
 */
contract RecordingMockLayerZeroEndpoint {
    mapping(address => address) public delegates;
    bytes public lastOptions;

    // Mirrors LZ V2's lazyInboundNonce: path key => highest successfully delivered nonce.
    // key = keccak256(abi.encode(srcEid, sender, receiver))
    mapping(bytes32 => uint64) public lazyInboundNonce;

    function setDelegate(address delegate) external {
        delegates[msg.sender] = delegate;
    }

    function send(
        ILayerZeroEndpointV2.MessagingParams calldata params,
        address /* refundAddress */
    ) external payable returns (ILayerZeroEndpointV2.MessagingReceipt memory) {
        lastOptions = params.options;
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
        ILayerZeroEndpointV2.MessagingParams calldata,
        address
    ) external pure returns (ILayerZeroEndpointV2.MessagingFee memory) {
        return
            ILayerZeroEndpointV2.MessagingFee({
                nativeFee: 0.001 ether,
                lzTokenFee: 0
            });
    }

    /**
     * @dev Simulate a LZ executor delivering a message with a capped gas budget.
     *      Enforces ordered delivery: origin.nonce must be lazyInboundNonce[path] + 1.
     *      On success the nonce is advanced; on OOG it stays stuck, blocking all subsequent
     *      messages on the same (srcEid, sender, receiver) path.
     */
    function deliverWithGas(
        address target,
        ILayerZeroReceiver.Origin calldata origin,
        bytes calldata message,
        uint256 gasLimit
    ) external returns (bool success) {
        bytes32 pathKey = keccak256(
            abi.encode(origin.srcEid, origin.sender, target)
        );
        require(
            origin.nonce == lazyInboundNonce[pathKey] + 1,
            "RecordingMock: out-of-order delivery"
        );

        bytes memory callData = abi.encodeWithSelector(
            ILayerZeroReceiver.lzReceive.selector,
            origin,
            bytes32(0),
            message,
            address(0),
            new bytes(0)
        );
        // solhint-disable-next-line avoid-low-level-calls
        (success, ) = target.call{gas: gasLimit}(callData);

        if (success) {
            lazyInboundNonce[pathKey] = origin.nonce;
        }
        // On OOG/revert, lazyInboundNonce stays at origin.nonce - 1.
        // The nonce slot is permanently stuck until skip() is called by the delegate.
    }

    /**
     * @dev Delegate-gated skip — mirrors real LZ endpoint access control.
     *      Only the registered delegate for `oapp` may call this.
     */
    function skip(
        address oapp,
        uint32 /* srcEid */,
        bytes32 /* sender */,
        uint64 /* nonce */
    ) external view {
        require(delegates[oapp] == msg.sender, "RecordingMock: not delegate");
    }
}

contract LayerZeroProverTest is BaseTest {
    LayerZeroPolicy public lzProver;
    MockLayerZeroEndpoint public endpoint;

    uint256 constant SOURCE_CHAIN_ID = 10;
    uint256 constant DEST_CHAIN_ID = 1;
    bytes32 constant SOURCE_PROVER =
        bytes32(uint256(uint160(0x1234567890123456789012345678901234567890)));

    /**
     * @notice Helper function to encode proofs from separate arrays
     * @param intentHashes Array of intent hashes
     * @param claimants Array of claimant addresses (as bytes32)
     * @return encodedProofs Encoded (intentHash, claimant) pairs as bytes
     */
    function encodeProofs(
        bytes32[] memory intentHashes,
        bytes32[] memory claimants
    ) internal view returns (bytes memory encodedProofs) {
        require(
            intentHashes.length == claimants.length,
            "Array length mismatch"
        );

        // Simulate what Inbox does - prepend 8 bytes for chain ID
        encodedProofs = new bytes(8 + intentHashes.length * 64);

        // Prepend chain ID
        uint64 chainId = uint64(block.chainid);
        assembly {
            mstore(add(encodedProofs, 0x20), shl(192, chainId))
        }

        for (uint256 i = 0; i < intentHashes.length; i++) {
            assembly {
                let offset := add(8, mul(i, 64))
                // Store hash in first 32 bytes of each pair
                mstore(
                    add(add(encodedProofs, 0x20), offset),
                    mload(add(intentHashes, add(0x20, mul(i, 32))))
                )
                // Store claimant in next 32 bytes of each pair
                mstore(
                    add(add(encodedProofs, 0x20), add(offset, 32)),
                    mload(add(claimants, add(0x20, mul(i, 32))))
                )
            }
        }
    }

    function setUp() public override {
        super.setUp();

        endpoint = new MockLayerZeroEndpoint();

        bytes32[] memory trustedProvers = new bytes32[](1);
        trustedProvers[0] = SOURCE_PROVER;

        lzProver = new LayerZeroPolicy(
            address(endpoint),
            address(this), // delegate
            address(portal),
            trustedProvers,
            200000
        );
    }

    function _encodeProverData(
        bytes32 sourceChainProver,
        uint128 gasLimit
    ) internal pure returns (bytes memory) {
        LayerZeroPolicy.UnpackedData memory unpacked = LayerZeroPolicy
            .UnpackedData({
                sourceChainProver: sourceChainProver,
                gasLimit: gasLimit
            });

        return abi.encode(unpacked);
    }

    /**
     * @notice Records destination fulfillments (as the Portal) on the given prover
     *         so it can build its own wire message during prove(). Mirrors the
     *         claimants the test already constructed for each intent hash.
     */
    function _record(
        LayerZeroPolicy p,
        bytes32[] memory h,
        bytes32[] memory c
    ) internal {
        for (uint256 i; i < h.length; ++i) {
            vm.prank(address(portal));
            p.recordFulfillment(h[i], uint64(block.chainid), c[i]);
        }
    }

    function test_constructor() public view {
        assertEq(lzProver.ENDPOINT(), address(endpoint));
        assertEq(lzProver.PORTAL(), address(portal));
        assertTrue(lzProver.isWhitelisted(SOURCE_PROVER));
        assertEq(lzProver.MIN_GAS_LIMIT(), 200000);
    }

    function test_getProofType() public view {
        assertEq(lzProver.getProofType(), "LayerZero");
    }

    function test_fetchFee() public view {
        bytes32[] memory intentHashes = new bytes32[](1);
        intentHashes[0] = keccak256("intent");

        bytes32[] memory claimants = new bytes32[](1);
        claimants[0] = bytes32(uint256(uint160(address(this))));

        bytes memory data = _encodeProverData(SOURCE_PROVER, 200000);

        bytes memory encodedProofs = encodeProofs(intentHashes, claimants);
        uint256 fee = lzProver.fetchFee(
            uint64(SOURCE_CHAIN_ID),
            encodedProofs,
            data
        );
        assertEq(fee, 0.001 ether);
    }

    function test_prove() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        intentHashes[0] = keccak256("intent");

        bytes32[] memory claimants = new bytes32[](1);
        claimants[0] = bytes32(uint256(uint160(address(this))));

        bytes memory data = _encodeProverData(SOURCE_PROVER, 200000);

        bytes memory encodedProofs = encodeProofs(intentHashes, claimants);
        uint256 fee = lzProver.fetchFee(
            uint64(SOURCE_CHAIN_ID),
            encodedProofs,
            data
        );

        vm.deal(address(portal), fee);
        _record(lzProver, intentHashes, claimants);
        vm.prank(address(portal));
        lzProver.prove{value: fee}(
            address(portal),
            uint64(SOURCE_CHAIN_ID),
            intentHashes,
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

        // Pack hash/claimant pairs as bytes with chain ID prefix
        bytes memory message = _formatMessageWithChainId(
            SOURCE_CHAIN_ID,
            intentHashes,
            claimants
        );

        vm.prank(address(endpoint));
        lzProver.lzReceive(origin, bytes32(0), message, address(0), "");

        LayerZeroPolicy.ProofData memory proofData = lzProver.provenIntents(
            intentHashes[0]
        );
        assertEq(
            proofData.fulfillmentHash,
            bytes32(uint256(uint160(address(this))))
        );
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

        vm.expectRevert(LayerZeroPolicy.EndpointCannotBeZeroAddress.selector);
        new LayerZeroPolicy(
            address(0),
            address(this), // delegate
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

    function test_prove_withCustomGasLimit() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        intentHashes[0] = keccak256("intent");

        bytes32[] memory claimants = new bytes32[](1);
        claimants[0] = bytes32(uint256(uint160(address(this))));

        uint128 customGasLimit = 300000;
        bytes memory data = _encodeProverData(SOURCE_PROVER, customGasLimit);

        bytes memory encodedProofs = encodeProofs(intentHashes, claimants);
        uint256 fee = lzProver.fetchFee(
            uint64(SOURCE_CHAIN_ID),
            encodedProofs,
            data
        );

        vm.deal(address(portal), fee);
        _record(lzProver, intentHashes, claimants);
        vm.prank(address(portal));
        lzProver.prove{value: fee}(
            address(portal),
            uint64(SOURCE_CHAIN_ID),
            intentHashes,
            data
        );
    }

    function test_prove_enforcesMinimumGasLimit() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        intentHashes[0] = keccak256("intent");

        bytes32[] memory claimants = new bytes32[](1);
        claimants[0] = bytes32(uint256(uint160(address(this))));

        // Test with gas limit below minimum (should be automatically increased to MIN_GAS_LIMIT)
        uint128 belowMinGasLimit = 50000; // Below 200k minimum
        bytes memory data = _encodeProverData(SOURCE_PROVER, belowMinGasLimit);

        bytes memory encodedProofs = encodeProofs(intentHashes, claimants);
        uint256 fee = lzProver.fetchFee(
            uint64(SOURCE_CHAIN_ID),
            encodedProofs,
            data
        );

        // Record once — the same intent hash is proved twice below, and
        // recordFulfillment is one-shot per hash.
        _record(lzProver, intentHashes, claimants);

        vm.deal(address(portal), fee);
        vm.prank(address(portal));
        lzProver.prove{value: fee}(
            address(portal),
            uint64(SOURCE_CHAIN_ID),
            intentHashes,
            data
        );

        // Test with zero gas limit (should be automatically increased to MIN_GAS_LIMIT)
        bytes memory zeroGasData = _encodeProverData(SOURCE_PROVER, 0);

        uint256 zeroGasFee = lzProver.fetchFee(
            uint64(SOURCE_CHAIN_ID),
            encodedProofs,
            zeroGasData
        );

        // No second _record — the hash is already recorded above (one-shot).
        vm.deal(address(portal), zeroGasFee);
        vm.prank(address(portal));
        lzProver.prove{value: zeroGasFee}(
            address(portal),
            uint64(SOURCE_CHAIN_ID),
            intentHashes,
            zeroGasData
        );
    }

    // ============ Challenge Intent Proof Tests ============
    // Note: Comprehensive challenge tests are in MetaPolicy.t.sol
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

        // Pack hash/claimant pairs as bytes with chain ID prefix
        bytes memory message = _formatMessageWithChainId(
            wrongDestination,
            intentHashes,
            claimants
        );

        // Add the proof with wrong destination
        vm.prank(address(endpoint));
        lzProver.lzReceive(origin, bytes32(0), message, address(0), "");

        // Verify proof exists with wrong destination
        LayerZeroPolicy.ProofData memory proofBefore = lzProver.provenIntents(
            intentHash
        );
        assertEq(
            proofBefore.fulfillmentHash,
            bytes32(uint256(uint160(address(this))))
        );
        assertEq(proofBefore.destination, wrongDestination);

        // Challenge the proof with correct destination
        vm.expectEmit(true, true, true, true);
        emit IPolicy.IntentProofInvalidated(intentHash);

        lzProver.challengeIntentProof(actualDestination, routeHash, rewardHash);

        // Verify proof was cleared
        LayerZeroPolicy.ProofData memory proofAfter = lzProver.provenIntents(
            intentHash
        );
        assertEq(proofAfter.fulfillmentHash, bytes32(0));
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

        // Pack hash/claimant pairs as bytes with chain ID prefix
        bytes memory message = _formatMessageWithChainId(
            correctDestination,
            intentHashes,
            claimants
        );

        // Add the proof with correct destination
        vm.prank(address(endpoint));
        lzProver.lzReceive(origin, bytes32(0), message, address(0), "");

        // Verify proof exists with correct destination
        LayerZeroPolicy.ProofData memory proofBefore = lzProver.provenIntents(
            intentHash
        );
        assertEq(
            proofBefore.fulfillmentHash,
            bytes32(uint256(uint160(address(this))))
        );
        assertEq(proofBefore.destination, correctDestination);

        // Challenge the proof with correct destination (should do nothing)
        lzProver.challengeIntentProof(
            correctDestination,
            routeHash,
            rewardHash
        );

        // Verify proof still exists
        LayerZeroPolicy.ProofData memory proofAfter = lzProver.provenIntents(
            intentHash
        );
        assertEq(
            proofAfter.fulfillmentHash,
            bytes32(uint256(uint160(address(this))))
        );
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

        // Pack hash/claimant pairs as bytes with chain ID prefix
        bytes memory message = _formatMessageWithChainId(
            wrongDestination,
            intentHashes,
            claimants
        );

        // Add proof with wrong srcEid
        vm.prank(address(endpoint));
        lzProver.lzReceive(origin, bytes32(0), message, address(0), "");

        // Challenge should succeed for LayerZero-specific validation
        vm.expectEmit(true, true, true, true);
        emit IPolicy.IntentProofInvalidated(intentHash);

        lzProver.challengeIntentProof(actualDestination, routeHash, rewardHash);

        // Verify proof was cleared
        LayerZeroPolicy.ProofData memory proofAfter = lzProver.provenIntents(
            intentHash
        );
        assertEq(proofAfter.fulfillmentHash, bytes32(0));
        assertEq(proofAfter.destination, 0);
    }

    // Helper to import the event for testing
    event IntentProven(
        bytes32 indexed intentHash,
        uint64 indexed destination,
        bytes32 fulfillmentHash
    );

    // ── revokeDelegation ──────────────────────────────────────────────────────

    function test_revokeDelegation_succeeds() public {
        // address(this) is the delegate set in setUp
        vm.expectEmit(true, false, false, false, address(lzProver));
        emit LayerZeroPolicy.DelegationRevoked(address(this));

        lzProver.revokeDelegation();

        assertEq(endpoint.delegates(address(lzProver)), address(lzProver));
    }

    function test_revokeDelegation_revertsIfNotDelegate() public {
        address nonDelegate = makeAddr("nonDelegate");
        vm.prank(nonDelegate);
        vm.expectRevert(LayerZeroPolicy.NotDelegate.selector);
        lzProver.revokeDelegation();
    }

    function test_revokeDelegation_locksSubsequentCalls() public {
        // Revoke once — delegate is now address(lzProver)
        lzProver.revokeDelegation();

        // Original delegate can no longer call it
        vm.expectRevert(LayerZeroPolicy.NotDelegate.selector);
        lzProver.revokeDelegation();
    }

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

    // ─────────────────────────────────────────────────────────────────────────
    // DoS / OOG wedge security tests
    //
    // These tests cover three components of the LZ OOG wedge attack:
    //
    //  1. prove() with an empty intentHashes array still dispatches a LZ message,
    //     advancing the nonce without recording any proofs.
    //
    //  2. When the caller supplies non-empty `options` bytes, they are forwarded
    //     verbatim to the endpoint — the MIN_GAS_LIMIT clamp in _unpackData() is
    //     completely bypassed.
    //
    //  3. If the executor honours those low-gas options, lzReceive() OOGs, leaving
    //     the nonce permanently unprocessed and blocking all subsequent messages on
    //     the same (srcEid, sender) path.
    //
    //  4. After revokeDelegation(), no external party can call skip/clear on the
    //     endpoint, making a stuck nonce permanently unrecoverable.
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Deploy a prover wired to a RecordingMockLayerZeroEndpoint.
    function _deployWithRecordingEndpoint()
        internal
        returns (RecordingMockLayerZeroEndpoint recEndpoint, LayerZeroPolicy recProver)
    {
        recEndpoint = new RecordingMockLayerZeroEndpoint();
        bytes32[] memory provers = new bytes32[](1);
        provers[0] = SOURCE_PROVER;
        recProver = new LayerZeroPolicy(
            address(recEndpoint),
            address(this), // delegate
            address(portal),
            provers,
            200_000
        );
    }

    /**
     * @notice prove() with zero intent hashes dispatches a LZ message.
     * @dev An attacker can call Inbox.prove() with an empty array. The Inbox
     *      constructs an 8-byte payload (chain-ID only) and forwards it to the
     *      prover, which sends it to the LZ endpoint — advancing the nonce
     *      without proving anything.
     */
    function test_dos_emptyBatch_dispatchesMessage() public {
        // 8-byte header only — zero intent/claimant pairs
        bytes memory emptyProofs = abi.encodePacked(uint64(block.chainid));
        bytes32[] memory emptyHashes = new bytes32[](0);
        bytes memory data = _encodeProverData(SOURCE_PROVER, 200_000);

        uint256 fee = lzProver.fetchFee(
            uint64(SOURCE_CHAIN_ID),
            emptyProofs,
            data
        );
        vm.deal(address(portal), fee);
        vm.prank(address(portal));
        // Must NOT revert — message is dispatched with zero intent pairs.
        lzProver.prove{value: fee}(
            address(portal),
            uint64(SOURCE_CHAIN_ID),
            emptyHashes,
            data
        );
    }

    /**
     * @notice lzReceive() OOGs when the executor honours low-gas options; the individual
     *         message is undeliverable and the proof is not recorded.
     * @dev The LZ executor calls lzReceive with the gas specified in options. If that gas
     *      is insufficient, lzReceive OOGs and the proof is lost for that message.
     *
     *      NOTE: The RecordingMockLayerZeroEndpoint used here enforces ordered nonce delivery
     *      (nonce N+1 rejected until nonce N succeeds). This matches the behaviour of the
     *      real LZ V2 EndpointV2 when an OApp uses sequential nonce tracking (nextNonce > 0).
     *
     *      This OApp returns nextNonce=0 and allowInitializePath=true for whitelisted senders,
     *      which enables *unordered* delivery in the real endpoint — nonce 2 would be accepted
     *      even if nonce 1 OOG'd. The path is therefore NOT permanently blocked in production;
     *      only the individual OOG'd message is undeliverable without manual recovery.
     */
    function test_dos_lzReceive_oogsWithLowGas() public {
        (
            RecordingMockLayerZeroEndpoint recEndpoint,
            LayerZeroPolicy recProver
        ) = _deployWithRecordingEndpoint();

        // ── Nonce 1: wedge message delivered with insufficient gas ────────────

        bytes32[] memory intentHashes1 = new bytes32[](1);
        intentHashes1[0] = keccak256("wedge-intent");
        bytes32[] memory claimants1 = new bytes32[](1);
        claimants1[0] = bytes32(uint256(uint160(address(this))));

        ILayerZeroReceiver.Origin memory origin1 = ILayerZeroReceiver.Origin({
            srcEid: uint32(SOURCE_CHAIN_ID),
            sender: SOURCE_PROVER,
            nonce: 1
        });

        bytes memory message1 = _formatMessageWithChainId(
            SOURCE_CHAIN_ID,
            intentHashes1,
            claimants1
        );

        // Deliver with only 1 000 gas — far below what lzReceive needs for storage writes.
        bool success1 = recEndpoint.deliverWithGas(
            address(recProver),
            origin1,
            message1,
            1_000
        );

        assertFalse(success1, "lzReceive must OOG with insufficient gas");
        assertEq(
            recProver.provenIntents(intentHashes1[0]).fulfillmentHash,
            bytes32(0),
            "no proof should be stored after OOG delivery"
        );

        // ── Nonce 2: follow-up message is blocked in the mock (ordered delivery) ──
        // The RecordingMock enforces ordered nonces, so it rejects nonce 2 while nonce 1
        // is stuck. In the real LZ V2 endpoint this OApp uses unordered delivery
        // (nextNonce=0, allowInitializePath=true), so nonce 2 would succeed in production.

        bytes32[] memory intentHashes2 = new bytes32[](1);
        intentHashes2[0] = keccak256("follow-up-intent");
        bytes32[] memory claimants2 = new bytes32[](1);
        claimants2[0] = bytes32(uint256(uint160(address(this))));

        ILayerZeroReceiver.Origin memory origin2 = ILayerZeroReceiver.Origin({
            srcEid: uint32(SOURCE_CHAIN_ID),
            sender: SOURCE_PROVER,
            nonce: 2
        });

        bytes memory message2 = _formatMessageWithChainId(
            SOURCE_CHAIN_ID,
            intentHashes2,
            claimants2
        );

        vm.expectRevert("RecordingMock: out-of-order delivery");
        recEndpoint.deliverWithGas(
            address(recProver),
            origin2,
            message2,
            500_000
        );

        // The follow-up intent is unproven because the mock blocked delivery.
        // In production (real endpoint, unordered mode) this message would have been accepted.
        assertEq(
            recProver.provenIntents(intentHashes2[0]).fulfillmentHash,
            bytes32(0),
            "follow-up intent not proven in mock (ordered delivery rejected nonce 2)"
        );
    }

    /**
     * @notice Regression: large batch with gasLimit=0 no longer wedges the path.
     * @dev Before the fix, options gas was always MIN_GAS_LIMIT (200k). A 10-intent batch
     *      costs ~250k gas to process, so delivery would OOG and the nonce would be stuck.
     *      After the fix, gas is MIN_GAS_LIMIT + n*GAS_PER_INTENT, delivery succeeds, and
     *      subsequent messages on the same path are unblocked.
     */
    function test_fix_largeBatch_gasFloorPreventsWedge() public {
        (
            RecordingMockLayerZeroEndpoint recEndpoint,
            LayerZeroPolicy recProver
        ) = _deployWithRecordingEndpoint();

        uint256 numIntents = 10;
        bytes32[] memory intentHashes = new bytes32[](numIntents);
        bytes32[] memory claimants   = new bytes32[](numIntents);
        for (uint256 i = 0; i < numIntents; i++) {
            intentHashes[i] = keccak256(abi.encodePacked("fix-intent", i));
            claimants[i]    = bytes32(uint256(uint160(address(this))));
        }

        bytes memory encodedProofs = encodeProofs(intentHashes, claimants);
        // Caller sets gasLimit to 0; old code would have clamped to MIN_GAS_LIMIT (200k)
        // and OOG'd on delivery. New code computes the floor from batch size.
        bytes memory data = _encodeProverData(SOURCE_PROVER, 0);

        uint256 fee = recProver.fetchFee(uint64(SOURCE_CHAIN_ID), encodedProofs, data);
        vm.deal(address(portal), fee);
        _record(recProver, intentHashes, claimants);
        vm.prank(address(portal));
        recProver.prove{value: fee}(
            address(portal),
            uint64(SOURCE_CHAIN_ID),
            intentHashes,
            data
        );

        // Decode the gas limit baked into the options that were sent to the endpoint.
        // LZ V2 type-3 format: version(2)+worker(1)+len(2)+type(1)+gas(16) = 22 bytes.
        // The uint128 gas occupies bytes [6..21], upper half of a 32-byte mload at offset 6.
        bytes memory opts = recEndpoint.lastOptions();
        uint128 gasInOptions;
        assembly {
            gasInOptions := shr(128, mload(add(add(opts, 0x20), 6)))
        }

        uint256 expectedFloor = recProver.MIN_GAS_LIMIT() +
            numIntents * recProver.GAS_PER_INTENT();
        assertEq(uint256(gasInOptions), expectedFloor, "options gas must equal computed floor");

        ILayerZeroReceiver.Origin memory origin = ILayerZeroReceiver.Origin({
            srcEid: uint32(SOURCE_CHAIN_ID),
            sender: SOURCE_PROVER,
            nonce: 1
        });

        // ── Show the old gas (MIN_GAS_LIMIT only) OOGs for this batch ───────
        bool failedWithOldGas = recEndpoint.deliverWithGas(
            address(recProver),
            origin,
            encodedProofs,
            recProver.MIN_GAS_LIMIT() // 200k — would have been the old floor
        );
        assertFalse(failedWithOldGas, "old MIN_GAS_LIMIT must be insufficient for 10 intents");

        // ── Deliver with the new gas floor — must succeed ────────────────────
        bool success = recEndpoint.deliverWithGas(
            address(recProver),
            origin,
            encodedProofs,
            gasInOptions
        );
        assertTrue(success, "delivery must succeed with the computed gas floor");

        // All 10 proofs recorded.
        for (uint256 i = 0; i < numIntents; i++) {
            assertEq(
                recProver.provenIntents(intentHashes[i]).fulfillmentHash,
                bytes32(uint256(uint160(address(this)))),
                "proof must be stored"
            );
        }

        // ── Path is not wedged: nonce 2 delivers without issue ───────────────
        bytes32[] memory intentHashes2 = new bytes32[](1);
        intentHashes2[0] = keccak256("fix-follow-up");
        bytes32[] memory claimants2 = new bytes32[](1);
        claimants2[0] = bytes32(uint256(uint160(address(this))));

        ILayerZeroReceiver.Origin memory origin2 = ILayerZeroReceiver.Origin({
            srcEid: uint32(SOURCE_CHAIN_ID),
            sender: SOURCE_PROVER,
            nonce: 2
        });

        bytes memory encodedProofs2 = encodeProofs(intentHashes2, claimants2);
        bool success2 = recEndpoint.deliverWithGas(
            address(recProver),
            origin2,
            encodedProofs2,
            recProver.MIN_GAS_LIMIT() + recProver.GAS_PER_INTENT()
        );
        assertTrue(success2, "follow-up message must be deliverable - path is not wedged");
    }

    /**
     * @notice Options bytes produced by _formatLayerZeroMessage conform to LZ V2 type-3 format.
     * @dev LZ V2 type-3 executor gas option (22 bytes):
     *        [0..1]  uint16(3)   — options version
     *        [2]     uint8(1)    — worker ID: executor
     *        [3..4]  uint16(17)  — option data length (1 type byte + 16 gas bytes)
     *        [5]     uint8(1)    — executor option type: lzReceive
     *        [6..21] uint128     — gas forwarded to lzReceive on destination
     *      The LZ SendLib parser validates this structure; any deviation causes a revert on send.
     */
    function test_optionsEncoding_correctLzV2Format() public {
        (
            RecordingMockLayerZeroEndpoint recEndpoint,
            LayerZeroPolicy recProver
        ) = _deployWithRecordingEndpoint();

        uint256 numIntents = 3;
        bytes32[] memory intentHashes = new bytes32[](numIntents);
        bytes32[] memory claimants = new bytes32[](numIntents);
        for (uint256 i = 0; i < numIntents; i++) {
            intentHashes[i] = keccak256(abi.encodePacked("opts-intent", i));
            claimants[i] = bytes32(uint256(uint160(address(this))));
        }

        bytes memory encodedProofs = encodeProofs(intentHashes, claimants);
        bytes memory data = _encodeProverData(SOURCE_PROVER, 0); // gasLimit=0 → floor applies

        uint256 fee = recProver.fetchFee(uint64(SOURCE_CHAIN_ID), encodedProofs, data);
        vm.deal(address(portal), fee);
        _record(recProver, intentHashes, claimants);
        vm.prank(address(portal));
        recProver.prove{value: fee}(address(portal), uint64(SOURCE_CHAIN_ID), intentHashes, data);

        bytes memory opts = recEndpoint.lastOptions();

        // Total: 2 + 1 + 2 + 1 + 16 = 22 bytes
        assertEq(opts.length, 22, "options must be 22 bytes");

        // [0..1] options version = 3
        uint16 version = (uint16(uint8(opts[0])) << 8) | uint16(uint8(opts[1]));
        assertEq(version, 3, "options version must be 3 (type-3)");

        // [2] worker ID = 1 (executor)
        assertEq(uint8(opts[2]), 1, "worker must be 1 (executor)");

        // [3..4] option data length = 17 (1 type byte + 16 gas bytes)
        uint16 optLen = (uint16(uint8(opts[3])) << 8) | uint16(uint8(opts[4]));
        assertEq(optLen, 17, "option data length must be 17");

        // [5] executor option type = 1 (lzReceive gas)
        assertEq(uint8(opts[5]), 1, "executor option type must be 1 (lzReceive)");

        // [6..21] gas as uint128 — upper 16 bytes of a 32-byte mload at byte offset 6
        uint128 gasInOptions;
        assembly {
            gasInOptions := shr(128, mload(add(add(opts, 0x20), 6)))
        }
        uint256 expectedGas = recProver.MIN_GAS_LIMIT() + numIntents * recProver.GAS_PER_INTENT();
        assertEq(uint256(gasInOptions), expectedGas, "gas must equal MIN_GAS_LIMIT + n*GAS_PER_INTENT");
    }

    /**
     * @notice A caller-supplied gasLimit that truncates to 0 in uint128 still produces
     *         a valid message because the gas floor always applies.
     * @dev gasLimit is typed as uint128 in UnpackedData, so abi.decode truncates any
     *      out-of-range value. The floor (MIN_GAS_LIMIT + n*GAS_PER_INTENT) is then
     *      applied, ensuring the encoded gas is always sufficient regardless of input.
     */
    function test_gasLimitTruncation_floorApplies() public {
        (
            RecordingMockLayerZeroEndpoint recEndpoint,
            LayerZeroPolicy recProver
        ) = _deployWithRecordingEndpoint();

        bytes32[] memory intentHashes = new bytes32[](1);
        intentHashes[0] = keccak256("overflow-intent");
        bytes32[] memory claimants = new bytes32[](1);
        claimants[0] = bytes32(uint256(uint160(address(this))));

        bytes memory encodedProofs = encodeProofs(intentHashes, claimants);

        // Pass gasLimit = 0 (simulates what a truncated 2^128 would produce after decode).
        bytes memory data = _encodeProverData(SOURCE_PROVER, 0);

        // fetchFee must succeed — floor is applied, no revert.
        uint256 fee = recProver.fetchFee(uint64(SOURCE_CHAIN_ID), encodedProofs, data);
        vm.deal(address(portal), fee);
        _record(recProver, intentHashes, claimants);
        vm.prank(address(portal));
        recProver.prove{value: fee}(address(portal), uint64(SOURCE_CHAIN_ID), intentHashes, data);

        // Gas in options must equal the floor (MIN_GAS_LIMIT + 1*GAS_PER_INTENT).
        bytes memory opts = recEndpoint.lastOptions();
        uint128 gasInOptions;
        assembly { gasInOptions := shr(128, mload(add(add(opts, 0x20), 6))) }
        assertEq(
            uint256(gasInOptions),
            recProver.MIN_GAS_LIMIT() + recProver.GAS_PER_INTENT(),
            "floor must apply when gasLimit truncates to zero"
        );
    }

    /**
     * @notice After revokeDelegation(), no one can call skip/clear to recover a stuck nonce.
     * @dev revokeDelegation() sets the endpoint delegate to address(lzProver). Since the
     *      prover has no function that calls endpoint.skip() or endpoint.clear(), the
     *      delegate slot is permanently occupied by an account that cannot act on it.
     *      Any previous operator loses the ability to perform recovery operations.
     */
    function test_dos_postRevokeDelegation_skipImpossible() public {
        (
            RecordingMockLayerZeroEndpoint recEndpoint,
            LayerZeroPolicy recProver
        ) = _deployWithRecordingEndpoint();

        // address(this) is the current delegate — revoke it.
        recProver.revokeDelegation();

        // Delegate is now the prover itself.
        assertEq(
            recEndpoint.delegates(address(recProver)),
            address(recProver),
            "delegate must be lzProver after revocation"
        );

        // The original operator is no longer the delegate and cannot call skip.
        vm.expectRevert("RecordingMock: not delegate");
        recEndpoint.skip(
            address(recProver),
            uint32(SOURCE_CHAIN_ID),
            SOURCE_PROVER,
            1
        );

        // address(recProver) is the delegate but exposes no function to call skip —
        // no recovery path exists for a wedged nonce.
        assertTrue(
            recEndpoint.delegates(address(recProver)) == address(recProver),
            "lzProver is its own delegate with no skip capability"
        );
    }
}
