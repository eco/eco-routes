// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../BaseTest.sol";
import {PolymerProver} from "../../contracts/prover/PolymerProver.sol";
import {IProver} from "../../contracts/interfaces/IProver.sol";
import {TestCrossL2ProverV2} from "../../contracts/test/TestCrossL2ProverV2.sol";
import {Intent, Route, Reward, TokenAmount, Call} from "../../contracts/types/Intent.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Base58} from "../../contracts/libs/Base58.sol";
import {Vm} from "forge-std/Vm.sol";

contract PolymerProverTest is BaseTest {
    PolymerProver internal polymerProver;
    TestCrossL2ProverV2 internal crossL2ProverV2;
    address internal destinationProver;

    uint32 constant OPTIMISM_CHAIN_ID = 10;
    uint32 constant ARBITRUM_CHAIN_ID = 42161;

    uint32 internal constant SOLANA_POLYMER_CHAIN_ID = 2;
    uint64 internal constant SOLANA_CHAIN_ID = 1399811149;
    /// Raw key of the whitelisted Solana polymer-prover program.
    bytes32 internal constant SOLANA_PROGRAM_ID =
        0xec0000000000000000000000000000000000000000000000000000000000ec00;
    /// SOLANA_PROGRAM_ID >> 8 and >> 16: keys whose first byte(s) are 0x00, so their
    /// canonical base58 carries one leading `1` per zero byte. Their encodings in
    /// testBase58EncodesLeadingZeroBytes were computed off-chain with a reference
    /// base58 implementation, not with Base58.sol.
    bytes32 internal constant SOLANA_PROGRAM_ID_ONE_ZERO =
        0x00ec0000000000000000000000000000000000000000000000000000000000ec;
    bytes32 internal constant SOLANA_PROGRAM_ID_TWO_ZEROS =
        0x0000ec0000000000000000000000000000000000000000000000000000000000;
    /// Mirrors PolymerProver.SOLANA_LOG_HEX_LENGTH; asserted in testInitializesSolanaConfig
    uint256 internal constant SOLANA_LOG_HEX_LENGTH = 160;

    /// The exact line eco-routes-svm's polymer-prover emits, copied verbatim from
    /// programs/polymer-prover/src/instructions/prove/testdata/prove_log_line_format.golden.
    /// Do not regenerate locally: this pins the cross-repo wire format (the `Prove: `
    /// prefix, `program: `, the `, ` separator, and the 8/8/32/32 field widths and order).
    /// If the SVM golden changes, this literal and its counterpart must change together.
    /// Nothing mechanically enforces that pair yet (no CI job on either side reads the
    /// other repo): regenerating the SVM golden without updating this literal leaves both
    /// suites green. Tracked as a follow-up; until then this comment and the SVM spec's
    /// release checklist are the whole contract. Same exposure for SVM_PROGRAM_KEY and
    /// SVM_GOLDEN_DEST_CHAIN_ID below.
    string internal constant SVM_GOLDEN_LOG =
        "Prove: program: EcotL2wbUqtRAjnf1p6aa842dM4fc8ZX6JhygibtBreo, 000000000000210500000000536f6c4e11111111111111111111111111111111111111111111111111111111111111112222222222222222222222222222222222222222222222222222222222222222";
    /// Raw key of `EcotL2wbUqtRAjnf1p6aa842dM4fc8ZX6JhygibtBreo` (lib.rs `declare_id!`),
    /// computed independently of Base58.sol so this also pins the vendored decoder.
    bytes32 internal constant SVM_PROGRAM_KEY =
        0xca5445780a23c1d4727275c6bf8058df776758b51fb5059eda89aaa673fd1934;
    /// Intent hash field of the golden payload (offset 16, 32 bytes of 0x11).
    bytes32 internal constant SVM_GOLDEN_INTENT_HASH =
        0x1111111111111111111111111111111111111111111111111111111111111111;
    /// Source chain in the golden payload (0x2105) and the eco-svm-std NON-mainnet
    /// CHAIN_ID in its destination field (0x536f6c4e = 1399811150, Solana devnet).
    /// Deliberately not SOLANA_CHAIN_ID (1399811149, mainnet): the golden was produced
    /// without `--features mainnet`. Do not "fix" this to the mainnet constant.
    uint64 internal constant SVM_GOLDEN_SOURCE_CHAIN_ID = 8453;
    uint64 internal constant SVM_GOLDEN_DEST_CHAIN_ID = 0x536f6c4e;

    bytes32 constant PROOF_SELECTOR =
        keccak256("IntentFulfilledFromSource(uint64,bytes)");

    bytes internal emptyTopics =
        hex"0000000000000000000000000000000000000000000000000000000000000000";
    bytes internal emptyData = hex"";

    /**
     * @notice Helper function to encode proofs from separate arrays with 8-byte chain ID prefix
     * @param intentHashes Array of intent hashes
     * @param claimants Array of claimant addresses (as bytes32)
     * @return encodedProofs Encoded 8-byte chain ID + (intentHash, claimant) pairs as bytes
     */
    function encodeProofs(
        bytes32[] memory intentHashes,
        bytes32[] memory claimants
    ) internal view returns (bytes memory encodedProofs) {
        return
            encodeProofsWithChainId(
                intentHashes,
                claimants,
                uint64(block.chainid)
            );
    }

    /**
     * @notice Helper function to encode proofs with specific chain ID prefix
     * @param intentHashes Array of intent hashes
     * @param claimants Array of claimant addresses (as bytes32)
     * @param chainId Chain ID to encode in the prefix
     * @return encodedProofs Encoded 8-byte chain ID + (intentHash, claimant) pairs as bytes
     */
    function encodeProofsWithChainId(
        bytes32[] memory intentHashes,
        bytes32[] memory claimants,
        uint64 chainId
    ) internal pure returns (bytes memory encodedProofs) {
        require(
            intentHashes.length == claimants.length,
            "Array length mismatch"
        );

        encodedProofs = new bytes(8 + intentHashes.length * 64);

        // Add 8-byte chain ID prefix
        assembly {
            mstore(add(encodedProofs, 0x20), shl(192, chainId))
        }

        for (uint256 i = 0; i < intentHashes.length; i++) {
            assembly {
                let offset := add(8, mul(i, 64))
                // Store hash in first 32 bytes of each pair (after 8-byte prefix)
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

    /// @notice Hex-encodes `data` without the `0x` prefix that vm.toString adds
    function _hexNoPrefix(
        bytes memory data
    ) internal pure returns (string memory) {
        bytes memory hexWithPrefix = bytes(vm.toString(data));
        bytes memory out = new bytes(hexWithPrefix.length - 2);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = hexWithPrefix[i + 2];
        }
        return string(out);
    }

    /// @notice One Solana `Prove:` log in its emitted `program: <id>, <hex>` form, minus the
    ///         `Prove: ` prefix. Polymer itself returns only the hex payload; see
    ///         LIVE_DEVNET_POLYMER_LINE.
    function _solanaLog(
        bytes32 programId,
        uint64 source,
        uint64 destination,
        bytes32 intentHash,
        bytes32 claimantBytes
    ) internal pure returns (string memory) {
        bytes memory payload = abi.encodePacked(
            source,
            destination,
            intentHash,
            claimantBytes
        );
        return
            string.concat(
                "program: ",
                Base58.encode(abi.encodePacked(programId)),
                ", ",
                _hexNoPrefix(payload)
            );
    }

    function setUp() public override {
        super.setUp();

        crossL2ProverV2 = new TestCrossL2ProverV2(
            OPTIMISM_CHAIN_ID,
            address(portal),
            emptyTopics,
            emptyData
        );

        // Create mock destination prover address
        destinationProver = makeAddr("destinationProver");

        // Create whitelist array for constructor: the EVM destination prover
        // plus the raw key of the Solana polymer-prover program
        bytes32[] memory provers = new bytes32[](2);
        provers[0] = bytes32(uint256(uint160(destinationProver)));
        provers[1] = SOLANA_PROGRAM_ID;

        // Deploy PolymerProver with portal, crossL2ProverV2, maxLogDataSize,
        // Solana chain configuration, and whitelist
        polymerProver = new PolymerProver(
            address(portal),
            address(crossL2ProverV2),
            32 * 1024, // maxLogDataSize
            SOLANA_POLYMER_CHAIN_ID,
            SOLANA_CHAIN_ID,
            provers
        );

        _mintAndApprove(creator, MINT_AMOUNT);
        _fundUserNative(creator, 10 ether);
    }

    function testInitializesCorrectly() public view {
        assertTrue(address(polymerProver) != address(0));
        assertEq(polymerProver.getProofType(), "Polymer");
        assertEq(
            address(polymerProver.CROSS_L2_PROVER_V2()),
            address(crossL2ProverV2)
        );
        assertEq(polymerProver.PORTAL(), address(portal));

        // Test whitelist functionality
        assertTrue(
            polymerProver.isWhitelisted(
                bytes32(uint256(uint160(destinationProver)))
            )
        );
        assertEq(polymerProver.getWhitelistSize(), 2);
    }

    function testInitializesSolanaConfig() public view {
        assertEq(
            polymerProver.SOLANA_POLYMER_CHAIN_ID(),
            SOLANA_POLYMER_CHAIN_ID
        );
        assertEq(polymerProver.SOLANA_CHAIN_ID(), SOLANA_CHAIN_ID);
        assertTrue(polymerProver.isWhitelisted(SOLANA_PROGRAM_ID));
        assertEq(polymerProver.getWhitelistSize(), 2);

        // 160 hex chars = eco-routes-svm polymer-prover PROVE_LOG_PAYLOAD_LEN (80 bytes):
        // source u64 || destination u64 || intent hash || claimant. Shared ABI.
        assertEq(polymerProver.SOLANA_LOG_HEX_LENGTH(), SOLANA_LOG_HEX_LENGTH);
        // the test encoder must agree with the contract's expected payload length
        bytes memory line = bytes(_validLog(keccak256("abi-pin")));
        assertEq(
            line.length,
            bytes("program: ").length +
                bytes(Base58.encode(abi.encodePacked(SOLANA_PROGRAM_ID)))
                    .length +
                2 +
                SOLANA_LOG_HEX_LENGTH
        );
    }

    function testConstructorRejectsZeroSolanaEcoChainId() public {
        bytes32[] memory provers = new bytes32[](0);
        vm.expectRevert(PolymerProver.InvalidSolanaChainConfig.selector);
        new PolymerProver(
            address(portal),
            address(crossL2ProverV2),
            32 * 1024,
            SOLANA_POLYMER_CHAIN_ID,
            0,
            provers
        );
    }

    function testConstructorRejectsZeroSolanaPolymerChainId() public {
        bytes32[] memory provers = new bytes32[](0);
        vm.expectRevert(PolymerProver.InvalidSolanaChainConfig.selector);
        new PolymerProver(
            address(portal),
            address(crossL2ProverV2),
            32 * 1024,
            0,
            SOLANA_CHAIN_ID,
            provers
        );
    }

    function testImplementsIProverInterface() public view {
        assertTrue(polymerProver.supportsInterface(type(IProver).interfaceId));
    }

    function testSupportsInterface() public view {
        assertTrue(polymerProver.supportsInterface(type(IProver).interfaceId));
        assertTrue(polymerProver.supportsInterface(0x01ffc9a7)); // ERC165
    }

    function testProveOnlyCallableByPortal() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        claimants[0] = bytes32(uint256(uint160(claimant)));

        bytes memory encodedProofs = encodeProofs(intentHashes, claimants);

        // Should revert when called by non-portal
        vm.expectRevert(PolymerProver.OnlyPortal.selector);
        polymerProver.prove(
            creator,
            uint64(block.chainid),
            encodedProofs,
            hex""
        );
    }

    function testProveEmitsEvents() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        bytes32 intentHash = _hashIntent(intent);
        intentHashes[0] = intentHash;
        claimants[0] = bytes32(uint256(uint160(claimant)));

        bytes memory encodedProofs = encodeProofs(intentHashes, claimants);

        _expectEmit();
        emit PolymerProver.IntentFulfilledFromSource(
            uint64(block.chainid),
            encodedProofs
        );

        vm.prank(address(portal));
        polymerProver.prove(
            creator,
            uint64(block.chainid),
            encodedProofs,
            hex""
        );
    }

    function testProveHandlesEmptyProofs() public {
        vm.prank(address(portal));
        polymerProver.prove(creator, uint64(block.chainid), hex"", hex"");
    }

    /// @dev Pins the MaxDataSizeExceeded guard at the boundary, derived rather than
    ///      hard-coded: encodedProofs is 8 + 64*n bytes for an n-intent Inbox.prove
    ///      batch, so a prover with maxLogDataSize = 8 + 64*2 takes a two-pair payload
    ///      and rejects three. Stays correct if the deploy default (2048, 31 pairs) moves.
    function testProveRevertsAboveMaxLogDataSize() public {
        uint256 maxLogDataSize = 8 + 64 * 2;
        bytes32[] memory provers = new bytes32[](1);
        provers[0] = bytes32(uint256(uint160(destinationProver)));
        PolymerProver smallProver = new PolymerProver(
            address(portal),
            address(crossL2ProverV2),
            maxLogDataSize,
            SOLANA_POLYMER_CHAIN_ID,
            SOLANA_CHAIN_ID,
            provers
        );
        assertEq(smallProver.MAX_LOG_DATA_SIZE(), maxLogDataSize);

        bytes memory twoPairs = new bytes(8 + 64 * 2);
        _expectEmit();
        emit PolymerProver.IntentFulfilledFromSource(
            uint64(block.chainid),
            twoPairs
        );
        vm.prank(address(portal));
        smallProver.prove(creator, uint64(block.chainid), twoPairs, hex"");

        bytes memory threePairs = new bytes(8 + 64 * 3);
        vm.prank(address(portal));
        vm.expectRevert(PolymerProver.MaxDataSizeExceeded.selector);
        smallProver.prove(creator, uint64(block.chainid), threePairs, hex"");
    }

    function testProveEmitsMultipleIntents() public {
        bytes32[] memory intentHashes = new bytes32[](3);
        bytes32[] memory claimants = new bytes32[](3);

        for (uint256 i = 0; i < 3; i++) {
            Intent memory testIntent = intent;
            testIntent.route.salt = keccak256(abi.encodePacked(salt, i));
            intentHashes[i] = _hashIntent(testIntent);
            claimants[i] = bytes32(uint256(uint160(claimant)));
        }

        bytes memory encodedProofs = encodeProofs(intentHashes, claimants);

        _expectEmit();
        emit PolymerProver.IntentFulfilledFromSource(
            uint64(block.chainid),
            encodedProofs
        );

        vm.prank(address(portal));
        polymerProver.prove(
            creator,
            uint64(block.chainid),
            encodedProofs,
            hex""
        );
    }

    /**
     * @notice prove() must refund forwarded ETH to the caller rather than trap it
     * @dev Regression test for V9: Polymer proving requires no bridge fee, but
     *      Inbox.prove forwards the Portal's entire balance (forced dust or
     *      overpayment). Previously prove() was payable and only emitted an event,
     *      permanently trapping any msg.value in the prover. It must now refund
     *      the forwarded value to the sender.
     */
    function testProveRefundsForwardedValueToSender() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        claimants[0] = bytes32(uint256(uint160(claimant)));

        bytes memory encodedProofs = encodeProofs(intentHashes, claimants);

        uint256 forwarded = 1 ether;
        vm.deal(address(portal), forwarded);
        uint256 creatorBalanceBefore = creator.balance;

        vm.prank(address(portal));
        polymerProver.prove{value: forwarded}(
            creator,
            uint64(block.chainid),
            encodedProofs,
            hex""
        );

        // Forwarded ETH is refunded to the sender, nothing trapped in the prover
        assertEq(creator.balance, creatorBalanceBefore + forwarded);
        assertEq(address(polymerProver).balance, 0);
    }

    /**
     * @notice prove() must REVERT when the refund recipient cannot receive ETH
     * @dev V9 behavior change: the refund now reverts with RefundFailed instead of
     *      swallowing the failed all-gas call. Polymer charges no bridge fee, so
     *      the entire forwarded amount is refunded to the caller; if that caller
     *      (always msg.sender) cannot receive, reverting surfaces the unpayable
     *      recipient loudly rather than stranding the ETH as dust in the prover.
     *      (The uncapped all-gas call still lets legitimate smart-account
     *      recipients receive — see testProveRefundsForwardedValueToSender and
     *      testInboxProveReentrancyIsBlocked.)
     */
    function testProveRevertsWhenRefundRecipientRejects() public {
        RejectingRefundRecipient rejecting = new RejectingRefundRecipient();

        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        claimants[0] = bytes32(uint256(uint160(claimant)));

        bytes memory encodedProofs = encodeProofs(intentHashes, claimants);

        uint256 forwarded = 1 ether;
        vm.deal(address(portal), forwarded);

        // Refund recipient reverts on receive. Polymer charges no fee, so the full
        // forwarded amount is refunded; the failed refund must revert prove() with
        // RefundFailed(recipient, forwarded).
        vm.prank(address(portal));
        vm.expectRevert(
            abi.encodeWithSelector(
                PolymerProver.RefundFailed.selector,
                address(rejecting),
                forwarded
            )
        );
        polymerProver.prove{value: forwarded}(
            address(rejecting),
            uint64(block.chainid),
            encodedProofs,
            hex""
        );
    }

    /**
     * @notice The nonReentrant guard on Inbox.prove blocks a refund recipient
     *         from reentering prove().
     * @dev Regression test for V9: Inbox.prove forwards the Portal's full balance
     *      into the prover, which refunds it with an all-gas call back to
     *      msg.sender. Polymer has no fee, so the whole forwarded amount is
     *      refunded to the caller. A malicious caller reenters Inbox.prove from its
     *      receive(); the guard must revert that reentrant call
     *      (ReentrancyGuardReentrantCall). The attacker's receive() catches that
     *      reentrant revert itself (low-level call) and returns normally, so the
     *      legitimate outer refund still lands (returns true) and the OUTER prove()
     *      succeeds — the refund now reverts only if the recipient itself fails to
     *      receive, which is not the case here.
     */
    function testInboxProveReentrancyIsBlocked() public {
        // Build a fulfillable intent on this chain with no route tokens/calls so
        // fulfillment needs no token setup. Inbox computes the hash with its own
        // CHAIN_ID (== block.chainid), so destination must match.
        Intent memory localIntent = intent;
        localIntent.destination = uint64(block.chainid);
        localIntent.route.tokens = new TokenAmount[](0);
        localIntent.route.calls = new Call[](0);

        bytes32 intentHash = _hashIntent(localIntent);
        bytes32 rewardHash = keccak256(abi.encode(localIntent.reward));

        // A solver fulfills the intent so claimants[intentHash] is set.
        address solver = makeAddr("polySolver");
        vm.prank(solver);
        portal.fulfill(
            intentHash,
            localIntent.route,
            rewardHash,
            bytes32(uint256(uint160(claimant)))
        );

        bytes32[] memory intentHashes = new bytes32[](1);
        intentHashes[0] = intentHash;

        // The malicious caller reenters Inbox.prove from its receive().
        ReentrantProveCaller attacker = new ReentrantProveCaller(
            address(portal),
            address(polymerProver),
            uint64(block.chainid),
            intentHashes
        );

        uint256 amount = 1 ether;
        vm.deal(address(attacker), amount);

        // Outer prove() must succeed despite the blocked reentrant attempt.
        attacker.attack();

        // The reentrant call was attempted and reverted with the guard error.
        assertTrue(attacker.reentrancyAttempted(), "reentry not attempted");
        assertTrue(attacker.reentrantReverted(), "guard did not block reentry");
        assertEq(
            bytes4(attacker.reentrantRevertData()),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector
        );

        // Portal drained its balance before the callback; the refund was
        // delivered out to the caller, leaving nothing trapped in prover/portal.
        assertEq(address(portal).balance, 0);
        assertEq(address(polymerProver).balance, 0);
        assertEq(address(attacker).balance, amount);
    }

    function testValidateSingleProof() public {
        bytes32 intentHash = _hashIntent(intent);
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = intentHash;
        claimants[0] = bytes32(uint256(uint160(claimant)));

        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR, // event signature
            bytes32(uint256(uint64(block.chainid))) // source chain ID
        );

        bytes memory data = encodeProofsWithChainId(
            intentHashes,
            claimants,
            OPTIMISM_CHAIN_ID
        );

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            destinationProver,
            topics,
            data
        );

        bytes memory proof = abi.encodePacked(uint256(1));

        _expectEmit();
        emit IProver.IntentProven(intentHash, claimant, OPTIMISM_CHAIN_ID);

        polymerProver.validate(proof);

        IProver.ProofData memory proofData = polymerProver.provenIntents(
            intentHash
        );
        assertEq(proofData.claimant, claimant);
        assertEq(proofData.destination, OPTIMISM_CHAIN_ID);
    }

    /// @dev processIntent is shared with validateSolana; a zero claimant is the
    ///      "unproven" sentinel and must never be recorded or announced (BaseProver parity)
    function testValidateSkipsZeroClaimant() public {
        bytes32 hashZero = keccak256("zero-claimant");
        bytes32 hashKept = keccak256("kept-claimant");
        bytes32[] memory intentHashes = new bytes32[](2);
        bytes32[] memory claimants = new bytes32[](2);
        intentHashes[0] = hashZero;
        claimants[0] = bytes32(0);
        intentHashes[1] = hashKept;
        claimants[1] = bytes32(uint256(uint160(claimant)));

        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR,
            bytes32(uint256(uint64(block.chainid)))
        );
        bytes memory data = encodeProofsWithChainId(
            intentHashes,
            claimants,
            OPTIMISM_CHAIN_ID
        );
        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            destinationProver,
            topics,
            data
        );

        vm.recordLogs();
        polymerProver.validate(abi.encodePacked(uint256(1)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1); // only the kept pair emits IntentProven
        assertEq(logs[0].topics[1], hashKept);

        IProver.ProofData memory zero = polymerProver.provenIntents(hashZero);
        assertEq(zero.claimant, address(0));
        assertEq(zero.destination, 0); // slot untouched
        assertEq(polymerProver.provenIntents(hashKept).claimant, claimant);
    }

    /// @dev Mirror of testValidateSolanaSkipsNonEvmClaimantAndContinues on the EVM path.
    ///      A non-EVM (32-byte) claimant must be skipped before AddressConverter.toAddress,
    ///      which reverts InvalidAddress on non-zero high bits — without the skip one such
    ///      pair would revert the whole proof and strand every co-batched intent.
    function testValidateSkipsNonEvmClaimantAndContinues() public {
        bytes32 hashSkipped = keccak256("non-evm-claimant");
        bytes32 hashKept = keccak256("kept-claimant");
        bytes32[] memory intentHashes = new bytes32[](2);
        bytes32[] memory claimants = new bytes32[](2);
        intentHashes[0] = hashSkipped;
        claimants[0] = bytes32(uint256(1) << 200);
        intentHashes[1] = hashKept;
        claimants[1] = bytes32(uint256(uint160(claimant)));

        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR,
            bytes32(uint256(uint64(block.chainid)))
        );
        bytes memory data = encodeProofsWithChainId(
            intentHashes,
            claimants,
            OPTIMISM_CHAIN_ID
        );
        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            destinationProver,
            topics,
            data
        );

        vm.recordLogs();
        polymerProver.validate(abi.encodePacked(uint256(1)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1); // only the kept pair emits IntentProven
        assertEq(logs[0].topics[1], hashKept);

        IProver.ProofData memory skipped = polymerProver.provenIntents(
            hashSkipped
        );
        assertEq(skipped.claimant, address(0));
        assertEq(skipped.destination, 0); // slot untouched
        assertEq(polymerProver.provenIntents(hashKept).claimant, claimant);
        assertEq(
            polymerProver.provenIntents(hashKept).destination,
            OPTIMISM_CHAIN_ID
        );
    }

    function testValidateEmitsAlreadyProvenForDuplicate() public {
        bytes32 intentHash = _hashIntent(intent);
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = intentHash;
        claimants[0] = bytes32(uint256(uint160(claimant)));

        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR, // event signature
            bytes32(uint256(uint64(block.chainid))) // source chain ID
        );

        bytes memory data = encodeProofsWithChainId(
            intentHashes,
            claimants,
            OPTIMISM_CHAIN_ID
        );

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            destinationProver,
            topics,
            data
        );

        bytes memory proof = abi.encodePacked(uint256(1));

        polymerProver.validate(proof);

        _expectEmit();
        emit IProver.IntentAlreadyProven(intentHash);

        polymerProver.validate(proof);
    }

    function testValidateMultipleIntentsInSingleEvent() public {
        bytes32[] memory intentHashes = new bytes32[](3);
        bytes32[] memory claimants = new bytes32[](3);

        for (uint256 i = 0; i < 3; i++) {
            Intent memory testIntent = intent;
            testIntent.route.salt = keccak256(abi.encodePacked(salt, i));
            intentHashes[i] = _hashIntent(testIntent);
            claimants[i] = bytes32(uint256(uint160(claimant)));
        }

        bytes memory data = encodeProofsWithChainId(
            intentHashes,
            claimants,
            OPTIMISM_CHAIN_ID
        );

        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR,
            bytes32(uint256(uint64(block.chainid)))
        );

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            destinationProver,
            topics,
            data
        );

        bytes memory proof = abi.encodePacked(uint256(1));

        _expectEmit();
        emit IProver.IntentProven(intentHashes[0], claimant, OPTIMISM_CHAIN_ID);
        _expectEmit();
        emit IProver.IntentProven(intentHashes[1], claimant, OPTIMISM_CHAIN_ID);
        _expectEmit();
        emit IProver.IntentProven(intentHashes[2], claimant, OPTIMISM_CHAIN_ID);

        polymerProver.validate(proof);

        for (uint256 i = 0; i < 3; i++) {
            IProver.ProofData memory proofData = polymerProver.provenIntents(
                intentHashes[i]
            );
            assertEq(proofData.claimant, claimant);
            assertEq(proofData.destination, OPTIMISM_CHAIN_ID);
        }
    }

    function testValidateBatch() public {
        bytes32[] memory intentHashes = new bytes32[](3);
        address[] memory claimants = new address[](3);

        for (uint256 i = 0; i < 3; i++) {
            Intent memory testIntent = intent;
            testIntent.route.salt = keccak256(abi.encodePacked(salt, i));
            intentHashes[i] = _hashIntent(testIntent);
            claimants[i] = claimant;
        }

        bytes[] memory proofs = new bytes[](3);
        uint32[] memory chainIds = new uint32[](3);
        chainIds[0] = OPTIMISM_CHAIN_ID;
        chainIds[1] = ARBITRUM_CHAIN_ID;
        chainIds[2] = OPTIMISM_CHAIN_ID;

        for (uint256 i = 0; i < 3; i++) {
            bytes32[] memory singleIntentHash = new bytes32[](1);
            bytes32[] memory singleClaimant = new bytes32[](1);
            singleIntentHash[0] = intentHashes[i];
            singleClaimant[0] = bytes32(uint256(uint160(claimants[i])));

            bytes memory topics = abi.encodePacked(
                PROOF_SELECTOR, // event signature
                bytes32(uint256(uint64(block.chainid))) // source chain ID
            );

            bytes memory data = encodeProofsWithChainId(
                singleIntentHash,
                singleClaimant,
                chainIds[i]
            );

            crossL2ProverV2.setAll(
                chainIds[i],
                destinationProver,
                topics,
                data
            );

            proofs[i] = abi.encodePacked(uint256(i + 1));
        }

        polymerProver.validateBatch(proofs);

        for (uint256 i = 0; i < 3; i++) {
            IProver.ProofData memory proofData = polymerProver.provenIntents(
                intentHashes[i]
            );
            assertEq(proofData.claimant, claimants[i]);
            assertEq(proofData.destination, chainIds[i]);
        }
    }

    function testValidateBatchWithDuplicate() public {
        bytes32[] memory intentHashes = new bytes32[](2);
        address[] memory claimants = new address[](2);

        for (uint256 i = 0; i < 2; i++) {
            Intent memory testIntent = intent;
            testIntent.route.salt = keccak256(abi.encodePacked(salt, i));
            intentHashes[i] = _hashIntent(testIntent);
            claimants[i] = claimant;
        }

        bytes[] memory proofs = new bytes[](3);
        uint32[] memory chainIds = new uint32[](3);
        chainIds[0] = OPTIMISM_CHAIN_ID;
        chainIds[1] = ARBITRUM_CHAIN_ID;
        chainIds[2] = OPTIMISM_CHAIN_ID;

        for (uint256 i = 0; i < 2; i++) {
            bytes32[] memory singleIntentHash = new bytes32[](1);
            bytes32[] memory singleClaimant = new bytes32[](1);
            singleIntentHash[0] = intentHashes[i];
            singleClaimant[0] = bytes32(uint256(uint160(claimants[i])));

            bytes memory topics = abi.encodePacked(
                PROOF_SELECTOR, // event signature
                bytes32(uint256(uint64(block.chainid))) // source chain ID
            );

            bytes memory data = encodeProofsWithChainId(
                singleIntentHash,
                singleClaimant,
                chainIds[i]
            );

            crossL2ProverV2.setAll(
                chainIds[i],
                destinationProver,
                topics,
                data
            );

            proofs[i] = abi.encodePacked(uint256(i + 1));
        }

        bytes32[] memory duplicateIntentHash = new bytes32[](1);
        bytes32[] memory duplicateClaimant = new bytes32[](1);
        duplicateIntentHash[0] = intentHashes[0]; // Same as first
        duplicateClaimant[0] = bytes32(uint256(uint160(claimants[0])));

        bytes memory duplicateTopics = abi.encodePacked(
            PROOF_SELECTOR, // event signature
            bytes32(uint256(uint64(block.chainid))) // source chain ID
        );

        bytes memory duplicateData = encodeProofsWithChainId(
            duplicateIntentHash,
            duplicateClaimant,
            chainIds[2]
        );

        crossL2ProverV2.setAll(
            chainIds[2],
            destinationProver,
            duplicateTopics,
            duplicateData
        );

        proofs[2] = abi.encodePacked(uint256(3));

        _expectEmit();
        emit IProver.IntentProven(intentHashes[0], claimant, OPTIMISM_CHAIN_ID);
        _expectEmit();
        emit IProver.IntentProven(intentHashes[1], claimant, ARBITRUM_CHAIN_ID);
        _expectEmit();
        emit IProver.IntentAlreadyProven(intentHashes[0]);

        polymerProver.validateBatch(proofs);

        for (uint256 i = 0; i < 2; i++) {
            IProver.ProofData memory proofData = polymerProver.provenIntents(
                intentHashes[i]
            );
            assertEq(proofData.claimant, claimants[i]);
            assertEq(proofData.destination, chainIds[i]);
        }
    }

    function testValidateRevertsOnInvalidEmittingContract() public {
        bytes32 intentHash = _hashIntent(intent);
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = intentHash;
        claimants[0] = bytes32(uint256(uint160(claimant)));

        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR, // event signature
            bytes32(uint256(uint64(block.chainid))) // source chain ID
        );

        bytes memory data = encodeProofsWithChainId(
            intentHashes,
            claimants,
            OPTIMISM_CHAIN_ID
        );

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            creator, // wrong contract
            topics,
            data
        );

        bytes memory proof = abi.encodePacked(uint256(1));

        vm.expectRevert(
            abi.encodeWithSelector(
                PolymerProver.InvalidEmittingContract.selector,
                creator
            )
        );
        polymerProver.validate(proof);
    }

    function testValidateRevertsOnInvalidTopicsLength() public {
        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR
            // missing source chain ID topic
        );

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            destinationProver,
            topics,
            emptyData
        );

        bytes memory proof = abi.encodePacked(uint256(1));

        vm.expectRevert(PolymerProver.InvalidTopicsLength.selector);
        polymerProver.validate(proof);
    }

    function testValidateRevertsOnTruncatedProofData() public {
        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR,
            bytes32(uint256(uint64(block.chainid)))
        );

        // 7 bytes: shorter than the 8-byte destination header. Must revert with the
        // declared error, not underflow to Panic(0x11) in the `% 64` shape check.
        bytes memory truncated = hex"00000000000000";

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            destinationProver,
            topics,
            truncated
        );

        bytes memory proof = abi.encodePacked(uint256(1));

        vm.expectRevert(IProver.ArrayLengthMismatch.selector);
        polymerProver.validate(proof);
    }

    /// @dev Sibling of testValidateRevertsOnTruncatedProofData: pins the other half of the
    ///      length guard. A trailing partial (hash, claimant) pair is the realistic encoder
    ///      or relayer corruption, and must hit the declared error, not decode garbage.
    function testValidateRevertsOnPartialPairProofData() public {
        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR,
            bytes32(uint256(uint64(block.chainid)))
        );

        // All >= 8 (so the floor passes) and not 8 + 64k: one stray byte, half a pair,
        // one byte short of a pair, one byte long.
        uint256[4] memory lengths = [uint256(9), 8 + 32, 8 + 63, 8 + 65];

        for (uint256 i = 0; i < lengths.length; i++) {
            // setAll pushes; the constructor used index 0, so this entry is i + 1
            crossL2ProverV2.setAll(
                OPTIMISM_CHAIN_ID,
                destinationProver,
                topics,
                new bytes(lengths[i])
            );

            bytes memory proof = abi.encodePacked(uint256(i + 1));

            vm.expectRevert(IProver.ArrayLengthMismatch.selector);
            polymerProver.validate(proof);
        }
    }

    function testValidateIsNoOpOnZeroPairProofData() public {
        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR,
            bytes32(uint256(uint64(block.chainid)))
        );

        // Exactly the 8-byte big-endian destination and no (hash, claimant) pairs.
        // Passes the shape check and is a well-formed no-op, as on BaseProver: it
        // records nothing and emits nothing, and must not revert (see the batch test
        // below for why).
        bytes32[] memory noHashes = new bytes32[](0);
        bytes32[] memory noClaimants = new bytes32[](0);
        bytes memory destinationOnly = encodeProofsWithChainId(
            noHashes,
            noClaimants,
            OPTIMISM_CHAIN_ID
        );
        assertEq(destinationOnly.length, 8);

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            destinationProver,
            topics,
            destinationOnly
        );

        bytes memory proof = abi.encodePacked(uint256(1));

        vm.recordLogs();
        polymerProver.validate(proof);
        assertEq(vm.getRecordedLogs().length, 0); // no IntentProven
        assertEq(
            polymerProver.provenIntents(_hashIntent(intent)).claimant,
            address(0)
        );
    }

    /// @dev Anyone can mint the destination-only event for one destination-chain
    ///      transaction: Inbox.prove has no access control and no empty-array guard,
    ///      so `intentHashes.length == 0` never reaches IntentNotFulfilled and emits
    ///      IntentFulfilledFromSource with exactly the 8-byte chain-id header. Pinned
    ///      so the "free, permissionless" property is stated, not rediscovered.
    function testInboxProveEmitsDestinationOnlyEventForEmptyBatch() public {
        address griefer = makeAddr("griefer");
        bytes memory destinationOnly = abi.encodePacked(uint64(block.chainid));
        assertEq(destinationOnly.length, 8);

        _expectEmit();
        emit PolymerProver.IntentFulfilledFromSource(
            uint64(block.chainid),
            destinationOnly
        );
        vm.prank(griefer);
        portal.prove(
            address(polymerProver),
            uint64(block.chainid),
            new bytes32[](0),
            ""
        );
    }

    /// @dev Regression for the attack shape that a zero-pair revert would enable: a
    ///      whitelisted emitter's destination-only event (see the Inbox test above)
    ///      co-batched with a genuine proof must not discard the genuine one. validateBatch
    ///      is atomic, so the only defence is that the poison element does not revert.
    function testValidateBatchSurvivesDestinationOnlyElement() public {
        bytes32 intentHash = _hashIntent(intent);
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = intentHash;
        claimants[0] = bytes32(uint256(uint160(claimant)));

        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR,
            bytes32(uint256(uint64(block.chainid)))
        );

        // proof index 1: destination-only; index 2: a well-formed one-pair payload
        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            destinationProver,
            topics,
            abi.encodePacked(uint64(OPTIMISM_CHAIN_ID))
        );
        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            destinationProver,
            topics,
            encodeProofsWithChainId(intentHashes, claimants, OPTIMISM_CHAIN_ID)
        );

        bytes[] memory proofs = new bytes[](2);
        proofs[0] = abi.encodePacked(uint256(1));
        proofs[1] = abi.encodePacked(uint256(2));

        _expectEmit();
        emit IProver.IntentProven(intentHash, claimant, OPTIMISM_CHAIN_ID);
        polymerProver.validateBatch(proofs);

        IProver.ProofData memory proofData = polymerProver.provenIntents(
            intentHash
        );
        assertEq(proofData.claimant, claimant);
        assertEq(proofData.destination, OPTIMISM_CHAIN_ID);
    }

    function testValidateRevertsOnInvalidEventSignature() public {
        bytes32 wrongSignature = keccak256("WrongSignature(uint64,bytes)");
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        claimants[0] = bytes32(uint256(uint160(claimant)));

        bytes memory topics = abi.encodePacked(
            wrongSignature, // wrong event signature
            bytes32(uint256(uint64(block.chainid))) // source chain ID
        );

        bytes memory data = encodeProofsWithChainId(
            intentHashes,
            claimants,
            OPTIMISM_CHAIN_ID
        );

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            destinationProver,
            topics,
            data
        );

        bytes memory proof = abi.encodePacked(uint256(1));

        vm.expectRevert(PolymerProver.InvalidEventSignature.selector);
        polymerProver.validate(proof);
    }

    /// @dev EVM twin of testValidateSolanaRevertsOnWrongSourceChain: a genuine, whitelisted
    ///      event proven from another chain must not replay here. Payload header still
    ///      matches setAll's chain id so the source gate is the only thing that can fire.
    function testValidateRevertsOnWrongSourceChain() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        claimants[0] = bytes32(uint256(uint160(claimant)));

        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR,
            bytes32(uint256(uint64(block.chainid) + 1)) // event emitted for another chain
        );

        bytes memory data = encodeProofsWithChainId(
            intentHashes,
            claimants,
            OPTIMISM_CHAIN_ID
        );

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            destinationProver,
            topics,
            data
        );

        bytes memory proof = abi.encodePacked(uint256(1));

        vm.expectRevert(PolymerProver.InvalidSourceChain.selector);
        polymerProver.validate(proof);
    }

    /// @dev Mirrors eco-routes-svm's parse_rejects_source_wider_than_u64: an indexed
    ///      uint64 is zero-padded by solc, so a topic word with dirty high bits is not a
    ///      well-formed source. Narrowing to uint64 before comparing would accept
    ///      `0xffff…ffff_<chainid>` as this chain; the full-word compare rejects it.
    function testValidateRevertsOnSourceChainWiderThanUint64() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        claimants[0] = bytes32(uint256(uint160(claimant)));

        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR,
            bytes32((type(uint256).max << 64) | uint256(uint64(block.chainid)))
        );

        bytes memory data = encodeProofsWithChainId(
            intentHashes,
            claimants,
            OPTIMISM_CHAIN_ID
        );

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            destinationProver,
            topics,
            data
        );

        bytes memory proof = abi.encodePacked(uint256(1));

        vm.expectRevert(PolymerProver.InvalidSourceChain.selector);
        polymerProver.validate(proof);
        assertEq(
            polymerProver.provenIntents(intentHashes[0]).claimant,
            address(0)
        );
    }

    /// @dev EVM twin of testValidateSolanaRevertsOnWrongDestinationChain: the 8-byte
    ///      destination header must equal the chain Polymer authenticated, so a payload
    ///      header cannot be swapped away from the attested destination.
    function testValidateRevertsOnWrongDestinationChain() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        claimants[0] = bytes32(uint256(uint160(claimant)));

        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR,
            bytes32(uint256(uint64(block.chainid)))
        );

        // Header says Arbitrum; Polymer attributes the event to Optimism.
        bytes memory data = encodeProofsWithChainId(
            intentHashes,
            claimants,
            ARBITRUM_CHAIN_ID
        );

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            destinationProver,
            topics,
            data
        );

        bytes memory proof = abi.encodePacked(uint256(1));

        vm.expectRevert(PolymerProver.InvalidDestinationChain.selector);
        polymerProver.validate(proof);
    }

    function testChallengeIntentProofWithWrongDestination() public {
        bytes32 intentHash = _hashIntent(intent);
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = intentHash;
        claimants[0] = bytes32(uint256(uint160(claimant)));

        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR, // event signature
            bytes32(uint256(uint64(block.chainid))) // source chain ID
        );

        bytes memory data = encodeProofsWithChainId(
            intentHashes,
            claimants,
            OPTIMISM_CHAIN_ID
        );

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            destinationProver,
            topics,
            data
        );

        bytes memory proof = abi.encodePacked(uint256(1));
        polymerProver.validate(proof);

        IProver.ProofData memory proofData = polymerProver.provenIntents(
            intentHash
        );
        assertEq(proofData.claimant, claimant);
        assertEq(proofData.destination, OPTIMISM_CHAIN_ID);

        // Challenge with different destination (intent.destination = 1 from BaseTest, proof.destination = 10)
        polymerProver.challengeIntentProof(
            intent.destination, // 1
            keccak256(abi.encode(intent.route)),
            keccak256(abi.encode(intent.reward))
        );

        // Verify proof was cleared since destinations don't match
        proofData = polymerProver.provenIntents(intentHash);
        assertEq(proofData.claimant, address(0));
    }

    function testChallengeIntentProofWithCorrectDestination() public {
        Intent memory localIntent = intent;
        localIntent.destination = OPTIMISM_CHAIN_ID;
        bytes32 intentHash = _hashIntent(localIntent);
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = intentHash;
        claimants[0] = bytes32(uint256(uint160(claimant)));

        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR, // event signature
            bytes32(uint256(uint64(block.chainid))) // source chain ID
        );

        bytes memory data = encodeProofsWithChainId(
            intentHashes,
            claimants,
            OPTIMISM_CHAIN_ID
        );

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            destinationProver,
            topics,
            data
        );

        bytes memory proof = abi.encodePacked(uint256(1));
        polymerProver.validate(proof);

        // Challenge with correct destination should do nothing
        polymerProver.challengeIntentProof(
            localIntent.destination,
            keccak256(abi.encode(localIntent.route)),
            keccak256(abi.encode(localIntent.reward))
        );

        // Verify proof is still there
        IProver.ProofData memory proofData = polymerProver.provenIntents(
            intentHash
        );
        assertEq(proofData.claimant, claimant);
        assertEq(proofData.destination, OPTIMISM_CHAIN_ID);
    }

    function testWhitelistFunctionality() public {
        // Test that our destination prover is whitelisted (address only)
        assertTrue(
            polymerProver.isWhitelisted(
                bytes32(uint256(uint160(destinationProver)))
            )
        );

        // Test that a random address is not whitelisted
        address randomAddr = makeAddr("random");
        assertFalse(
            polymerProver.isWhitelisted(bytes32(uint256(uint160(randomAddr))))
        );

        // Test zero address is not whitelisted
        assertFalse(polymerProver.isWhitelisted(bytes32(0)));
    }

    function testConstructorWithEmptyWhitelist() public {
        bytes32[] memory emptyProvers = new bytes32[](0);

        PolymerProver newProver = new PolymerProver(
            address(portal),
            address(crossL2ProverV2),
            32 * 1024, // maxLogDataSize
            SOLANA_POLYMER_CHAIN_ID,
            SOLANA_CHAIN_ID,
            emptyProvers
        );

        assertEq(newProver.getWhitelistSize(), 0);
        assertFalse(
            newProver.isWhitelisted(
                bytes32(uint256(uint160(destinationProver)))
            )
        );
    }

    // ------------- SOLANA LOG PROOF VALIDATION -------------

    /// @notice Registers `logs` as a fresh Solana proof entry attributed to
    ///         `polymerChainId` / `programId` and returns its handle. Always use the
    ///         returned handle: the mock appends, so a literal index is only right
    ///         for the first proof a test registers.
    function _setSolanaProofFor(
        uint32 polymerChainId,
        bytes32 programId,
        string[] memory logs
    ) internal returns (bytes memory proof) {
        return
            abi.encodePacked(
                crossL2ProverV2.setSolLogs(polymerChainId, programId, logs)
            );
    }

    /// @notice `_setSolanaProofFor` with the whitelisted program on Polymer's Solana id
    function _setSolanaProof(
        string[] memory logs
    ) internal returns (bytes memory proof) {
        return
            _setSolanaProofFor(
                SOLANA_POLYMER_CHAIN_ID,
                SOLANA_PROGRAM_ID,
                logs
            );
    }

    /// @dev A line whose program segment is `programSegment`, payload otherwise valid
    function _solanaLogWithProgramSegment(
        string memory programSegment,
        bytes32 intentHash
    ) internal view returns (string memory) {
        bytes memory payload = abi.encodePacked(
            uint64(block.chainid),
            SOLANA_CHAIN_ID,
            intentHash,
            bytes32(uint256(uint160(claimant)))
        );
        return
            string.concat(
                "program: ",
                programSegment,
                ", ",
                _hexNoPrefix(payload)
            );
    }

    /// @dev Deploys a prover matching the environment the SVM golden was produced in
    function _deployGoldenProver() internal returns (PolymerProver) {
        bytes32[] memory provers = new bytes32[](1);
        provers[0] = SVM_PROGRAM_KEY;
        return
            new PolymerProver(
                address(portal),
                address(crossL2ProverV2),
                32 * 1024,
                SOLANA_POLYMER_CHAIN_ID,
                SVM_GOLDEN_DEST_CHAIN_ID,
                provers
            );
    }

    function testValidateSolanaSingleLog() public {
        bytes32 intentHash = _hashIntent(intent);
        string[] memory logs = new string[](1);
        logs[0] = _solanaLog(
            SOLANA_PROGRAM_ID,
            uint64(block.chainid),
            SOLANA_CHAIN_ID,
            intentHash,
            bytes32(uint256(uint160(claimant)))
        );
        bytes memory proof = _setSolanaProof(logs);

        _expectEmit();
        emit IProver.IntentProven(intentHash, claimant, SOLANA_CHAIN_ID);
        polymerProver.validateSolana(proof);

        IProver.ProofData memory proofData = polymerProver.provenIntents(
            intentHash
        );
        assertEq(proofData.claimant, claimant);
        assertEq(proofData.destination, SOLANA_CHAIN_ID);
    }

    function testValidateSolanaMultipleLogs() public {
        string[] memory logs = new string[](3);
        bytes32[] memory hashes = new bytes32[](3);
        for (uint256 i = 0; i < 3; i++) {
            hashes[i] = keccak256(abi.encode("solana-intent", i));
            logs[i] = _solanaLog(
                SOLANA_PROGRAM_ID,
                uint64(block.chainid),
                SOLANA_CHAIN_ID,
                hashes[i],
                bytes32(uint256(uint160(claimant)))
            );
        }
        bytes memory proof = _setSolanaProof(logs);

        polymerProver.validateSolana(proof);

        for (uint256 i = 0; i < 3; i++) {
            assertEq(polymerProver.provenIntents(hashes[i]).claimant, claimant);
            assertEq(
                polymerProver.provenIntents(hashes[i]).destination,
                SOLANA_CHAIN_ID
            );
        }
    }

    /// @dev Pins every head shape `_processSolanaLog` tolerates, since Polymer's exact
    ///      stripping is documented but unverified against the deployed indexer: bare
    ///      (both prefixes gone), Polymer's `Prove: ` left in, `Prove:` without its
    ///      trailing space, the runtime prefix with `Prove: ` stripped as Polymer
    ///      documents, the raw runtime line with both, extra spaces after the runtime
    ///      prefix, and a bare leading space. Keep in sync with the head in
    ///      PolymerProver._processSolanaLog.
    function testValidateSolanaToleratesPrefixShapes() public {
        string[7] memory prefixes = [
            "",
            "Prove: ",
            "Prove:",
            "Program log: ",
            "Program log:  ",
            "Program log: Prove: ",
            " "
        ];
        for (uint256 i = 0; i < prefixes.length; i++) {
            bytes32 intentHash = keccak256(abi.encode("prefix-shape", i));
            string[] memory logs = new string[](1);
            logs[0] = string.concat(prefixes[i], _validLog(intentHash));
            bytes memory proof = _setSolanaProof(logs);

            _expectEmit();
            emit IProver.IntentProven(intentHash, claimant, SOLANA_CHAIN_ID);
            polymerProver.validateSolana(proof);
            assertEq(
                polymerProver.provenIntents(intentHash).claimant,
                claimant
            );
        }
    }

    /// @dev The exact line Polymer's devnet Prove API returned for a real `Prove:` log that
    ///      polymer-prover emitted inside Portal's CPI (probe, 2026-09-24): Polymer strips the
    ///      whole `Prove: program: <id>, ` head and returns only the 160-hex payload. Program
    ///      APwQiAKtuaWrKzP2e9nXPd93NHU4ekHJEWkXihFfL6Kn, source Base Sepolia (84532),
    ///      destination Solana devnet (1399811150).
    string internal constant LIVE_DEVNET_POLYMER_LINE =
        "0000000000014a3400000000536f6c4e6cf05f7ed1a5b987b8066359a1db42dd997c6d3a710c36f256644fbafbffda9d000000000000000000000000256b70644f5d77bc8e2bb82c731ddf747ecb1471";

    function testValidateSolanaAcceptsLiveDevnetPolymerLine() public {
        bytes32 programKey = 0x8b997af82487204a693e481b8423996d0172d4a88e4c69e1d7d56258a947068d;
        bytes32 intentHash = 0x6cf05f7ed1a5b987b8066359a1db42dd997c6d3a710c36f256644fbafbffda9d;
        address liveClaimant = 0x256B70644f5D77bc8e2bb82C731Ddf747ecb1471;
        bytes32[] memory provers = new bytes32[](1);
        provers[0] = programKey;
        vm.chainId(84532);
        PolymerProver devnetProver = new PolymerProver(
            address(portal),
            address(crossL2ProverV2),
            32 * 1024,
            SOLANA_POLYMER_CHAIN_ID,
            1399811150,
            provers
        );
        string[] memory logs = new string[](1);
        logs[0] = LIVE_DEVNET_POLYMER_LINE;
        bytes memory proof = _setSolanaProofFor(
            SOLANA_POLYMER_CHAIN_ID,
            programKey,
            logs
        );

        _expectEmit();
        emit IProver.IntentProven(intentHash, liveClaimant, 1399811150);
        devnetProver.validateSolana(proof);
        assertEq(devnetProver.provenIntents(intentHash).claimant, liveClaimant);
    }

    function testValidateSolanaAcceptsBarePayload() public {
        bytes32 intentHash = keccak256("bare");
        bytes memory payload = abi.encodePacked(
            uint64(block.chainid),
            SOLANA_CHAIN_ID,
            intentHash,
            bytes32(uint256(uint160(claimant)))
        );
        string[] memory logs = new string[](1);
        logs[0] = _hexNoPrefix(payload);
        bytes memory proof = _setSolanaProof(logs);

        _expectEmit();
        emit IProver.IntentProven(intentHash, claimant, SOLANA_CHAIN_ID);
        polymerProver.validateSolana(proof);
        assertEq(polymerProver.provenIntents(intentHash).claimant, claimant);
    }

    function testValidateSolanaRevertsOnBarePayloadOfWrongLength() public {
        bytes memory payload = abi.encodePacked(
            uint64(block.chainid),
            SOLANA_CHAIN_ID,
            keccak256("bare"),
            bytes32(uint256(uint160(claimant)))
        );
        string memory full = _hexNoPrefix(payload);
        string[] memory logs = new string[](1);

        logs[0] = string.concat(full, "00");
        bytes memory proof = _setSolanaProof(logs);
        vm.expectRevert(PolymerProver.InvalidSolanaLog.selector);
        polymerProver.validateSolana(proof);

        bytes memory shortLine = new bytes(158);
        for (uint256 i = 0; i < shortLine.length; i++)
            shortLine[i] = bytes(full)[i];
        logs[0] = string(shortLine);
        proof = _setSolanaProof(logs);
        vm.expectRevert(PolymerProver.InvalidSolanaLog.selector);
        polymerProver.validateSolana(proof);
    }

    function testValidateSolanaRevertsOnBarePayloadWithNonHex() public {
        bytes memory line = bytes(
            _hexNoPrefix(
                abi.encodePacked(
                    uint64(block.chainid),
                    SOLANA_CHAIN_ID,
                    keccak256("bare"),
                    bytes32(uint256(uint160(claimant)))
                )
            )
        );
        line[40] = "g";
        string[] memory logs = new string[](1);
        logs[0] = string(line);
        bytes memory proof = _setSolanaProof(logs);
        vm.expectRevert(PolymerProver.InvalidSolanaLog.selector);
        polymerProver.validateSolana(proof);
    }

    function testValidateSolanaRevertsOnNearMissPrefix() public {
        // The widened head must not swallow a near miss of Polymer's prefix.
        string[] memory logs = new string[](1);
        logs[0] = string.concat(
            "Program log: Proven: ",
            _validLog(keccak256("x"))
        );
        bytes memory proof = _setSolanaProof(logs);

        vm.expectRevert(PolymerProver.InvalidSolanaLog.selector);
        polymerProver.validateSolana(proof);
    }

    function testValidateSolanaAcceptsUppercaseHex() public {
        bytes32 intentHash = keccak256("upper");
        bytes memory line = bytes(_validLog(intentHash));
        // Upper-case only the hex payload; the base58 program ID is case-sensitive.
        uint256 hexLen = polymerProver.SOLANA_LOG_HEX_LENGTH();
        for (uint256 i = line.length - hexLen; i < line.length; i++) {
            if (line[i] >= 0x61 && line[i] <= 0x66) {
                line[i] = bytes1(uint8(line[i]) - 0x20);
            }
        }
        string[] memory logs = new string[](1);
        logs[0] = string(line);
        bytes memory proof = _setSolanaProof(logs);

        _expectEmit();
        emit IProver.IntentProven(intentHash, claimant, SOLANA_CHAIN_ID);
        polymerProver.validateSolana(proof);

        assertEq(polymerProver.provenIntents(intentHash).claimant, claimant);
        assertEq(
            polymerProver.provenIntents(intentHash).destination,
            SOLANA_CHAIN_ID
        );
    }

    function testValidateSolanaEmitsAlreadyProvenForDuplicate() public {
        bytes32 intentHash = _hashIntent(intent);
        string[] memory logs = new string[](1);
        logs[0] = _solanaLog(
            SOLANA_PROGRAM_ID,
            uint64(block.chainid),
            SOLANA_CHAIN_ID,
            intentHash,
            bytes32(uint256(uint160(claimant)))
        );
        bytes memory proof = _setSolanaProof(logs);
        polymerProver.validateSolana(proof);

        _expectEmit();
        emit IProver.IntentAlreadyProven(intentHash);
        polymerProver.validateSolana(proof);
    }

    function testValidateSolanaSkipsNonEvmClaimantAndContinues() public {
        bytes32 hashSkipped = keccak256("skipped");
        bytes32 hashKept = keccak256("kept");
        string[] memory logs = new string[](2);
        // non-EVM (32-byte) claimant: skipped, must not abort the remaining logs
        logs[0] = _solanaLog(
            SOLANA_PROGRAM_ID,
            uint64(block.chainid),
            SOLANA_CHAIN_ID,
            hashSkipped,
            bytes32(uint256(1) << 200)
        );
        logs[1] = _validLog(hashKept);
        bytes memory proof = _setSolanaProof(logs);

        _expectEmit();
        emit IProver.IntentProven(hashKept, claimant, SOLANA_CHAIN_ID);
        polymerProver.validateSolana(proof);

        // skipped: no partial write (and therefore no IntentProven — processIntent
        // writes and emits together)
        assertEq(polymerProver.provenIntents(hashSkipped).claimant, address(0));
        assertEq(polymerProver.provenIntents(hashSkipped).destination, 0);
        // kept: the loop continued past the skip
        assertEq(polymerProver.provenIntents(hashKept).claimant, claimant);
        assertEq(
            polymerProver.provenIntents(hashKept).destination,
            SOLANA_CHAIN_ID
        );
    }

    function testValidateSolanaSkipsZeroClaimant() public {
        bytes32 intentHash = keccak256("zero");
        string[] memory logs = new string[](1);
        logs[0] = _solanaLog(
            SOLANA_PROGRAM_ID,
            uint64(block.chainid),
            SOLANA_CHAIN_ID,
            intentHash,
            bytes32(0)
        );
        bytes memory proof = _setSolanaProof(logs);

        vm.recordLogs();
        polymerProver.validateSolana(proof);
        assertEq(vm.getRecordedLogs().length, 0); // no IntentProven

        IProver.ProofData memory pd = polymerProver.provenIntents(intentHash);
        assertEq(pd.claimant, address(0));
        assertEq(pd.destination, 0); // slot untouched — fails without the guard
    }

    function testValidateSolanaSkipsZeroClaimantAndContinues() public {
        bytes32 hashZero = keccak256("zero");
        bytes32 hashKept = keccak256("kept");
        string[] memory logs = new string[](2);
        logs[0] = _solanaLog(
            SOLANA_PROGRAM_ID,
            uint64(block.chainid),
            SOLANA_CHAIN_ID,
            hashZero,
            bytes32(0)
        );
        logs[1] = _validLog(hashKept);
        bytes memory proof = _setSolanaProof(logs);

        _expectEmit();
        emit IProver.IntentProven(hashKept, claimant, SOLANA_CHAIN_ID);
        polymerProver.validateSolana(proof);

        assertEq(polymerProver.provenIntents(hashZero).claimant, address(0));
        assertEq(polymerProver.provenIntents(hashZero).destination, 0);
        assertEq(polymerProver.provenIntents(hashKept).claimant, claimant);
    }

    function testValidateSolanaSkipsForeignSourceLineAndRecordsOurs() public {
        // One Solana tx can carry `Prove:` lines for several EVM source chains;
        // a line for another chain is skipped, ours is still recorded.
        string[] memory logs = new string[](2);
        logs[0] = _solanaLog(
            SOLANA_PROGRAM_ID,
            uint64(block.chainid) + 1,
            SOLANA_CHAIN_ID,
            keccak256("foreign"),
            bytes32(uint256(uint160(claimant)))
        );
        logs[1] = _validLog(keccak256("ours"));
        bytes memory proof = _setSolanaProof(logs);

        _expectEmit();
        emit IProver.IntentProven(keccak256("ours"), claimant, SOLANA_CHAIN_ID);
        polymerProver.validateSolana(proof);

        assertEq(
            polymerProver.provenIntents(keccak256("ours")).claimant,
            claimant
        );
        assertEq(
            polymerProver.provenIntents(keccak256("foreign")).claimant,
            address(0)
        );
    }

    /// @dev 24 = eco-routes-svm polymer-prover MAX_INTENTS_PER_PROVE, the most
    ///      `Prove:` lines one Solana tx can emit untruncated. The EVM side has no
    ///      per-proof cap, so this pins that the production batch size parses.
    function testValidateSolanaAtSvmBatchCeiling() public {
        uint256 n = 24;
        string[] memory logs = new string[](n);
        bytes32[] memory hashes = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            hashes[i] = keccak256(abi.encode("svm-ceiling", i));
            logs[i] = _validLog(hashes[i]);
        }
        polymerProver.validateSolana(_setSolanaProof(logs));
        for (uint256 i = 0; i < n; i++) {
            assertEq(polymerProver.provenIntents(hashes[i]).claimant, claimant);
            assertEq(
                polymerProver.provenIntents(hashes[i]).destination,
                SOLANA_CHAIN_ID
            );
        }
    }

    /// @dev Differential mutation test over the hand-rolled parser: flip one byte of a
    ///      valid line and assert the exact outcome a model of the wire format predicts.
    ///      A flip in the head reverts SolanaLogProgramMismatch when it only perturbs the
    ///      base58 id, and InvalidSolanaLog when it breaks the `program: ` prefix or
    ///      moves the `, ` anchor (a `,` written into the id, or the real `,`/` ` flipped);
    ///      a non-hex byte in the payload must revert InvalidSolanaLog; a hex byte is
    ///      patched into a model payload and the contract must then revert on the
    ///      mutated destination, skip a foreign source or a non-EVM/zero claimant, or
    ///      record exactly the mutated intent hash and claimant. A control proof
    ///      recorded before the fuzzed call pins that no branch touches other slots
    ///      (a revert rolls back only the fuzzed call).
    function testFuzzValidateSolanaMutatedLog(uint256 idx, uint8 b) public {
        bytes32 controlHash = keccak256("fuzz-control");
        string[] memory controlLogs = new string[](1);
        controlLogs[0] = _validLog(controlHash);
        polymerProver.validateSolana(_setSolanaProof(controlLogs));

        bytes32 intentHash = keccak256("fuzz-line");
        bytes memory line = bytes(_validLog(intentHash));
        idx = bound(idx, 0, line.length - 1);
        vm.assume(uint8(line[idx]) != b);
        uint256 hexStart = line.length - SOLANA_LOG_HEX_LENGTH;
        uint256 commaIdx = hexStart - 2; // index of the ',' that anchors the head
        uint256 prefixLen = bytes("program: ").length;
        line[idx] = bytes1(b);
        string[] memory logs = new string[](1);
        logs[0] = string(line);
        bytes memory proof = _setSolanaProof(logs);

        if (idx < hexStart) {
            // Head model, in the contract's own check order:
            //  - idx < prefixLen: the `program: ` prefix check fails first, whatever b is.
            //  - program segment flipped to ',': the comma anchor moves left, so the
            //    `comma + 2 + HEX != length` check fails.
            //  - the real ',' or the ' ' after it: the anchor breaks the same way.
            //  - any other program-segment flip: length/anchor still hold, the
            //    base58 string no longer hashes to the authenticated program id.
            bool expectMismatch = idx >= prefixLen &&
                idx < commaIdx &&
                b != uint8(bytes1(","));
            vm.expectRevert(
                expectMismatch
                    ? PolymerProver.SolanaLogProgramMismatch.selector
                    : PolymerProver.InvalidSolanaLog.selector
            );
            polymerProver.validateSolana(proof);
        } else if (!_isHexChar(b)) {
            vm.expectRevert(PolymerProver.InvalidSolanaLog.selector);
            polymerProver.validateSolana(proof);
        } else {
            _assertMutatedPayloadOutcome(proof, intentHash, idx - hexStart, b);
        }

        assertEq(polymerProver.provenIntents(controlHash).claimant, claimant);
        assertEq(
            polymerProver.provenIntents(controlHash).destination,
            SOLANA_CHAIN_ID
        );
    }

    /// @dev Model for a hex-region flip: patch nibble `o` of the valid payload with the
    ///      hex char `b`, read the fields back, and assert in the contract's own order
    ///      (destination is checked before source).
    function _assertMutatedPayloadOutcome(
        bytes memory proof,
        bytes32 intentHash,
        uint256 o,
        uint8 b
    ) internal {
        bytes memory payload = abi.encodePacked(
            uint64(block.chainid),
            SOLANA_CHAIN_ID,
            intentHash,
            bytes32(uint256(uint160(claimant)))
        );
        uint8 cur = uint8(payload[o / 2]);
        payload[o / 2] = o % 2 == 0
            ? bytes1((_nibbleOf(b) << 4) | (cur & 0x0f))
            : bytes1((cur & 0xf0) | _nibbleOf(b));
        uint64 source = uint64(bytes8(_word(payload, 0)));
        uint64 destination = uint64(bytes8(_word(payload, 8)));
        bytes32 mutHash = _word(payload, 16);
        bytes32 mutClaimant = _word(payload, 48);

        if (destination != SOLANA_CHAIN_ID) {
            vm.expectRevert(PolymerProver.InvalidDestinationChain.selector);
            polymerProver.validateSolana(proof);
        } else if (source != block.chainid) {
            // the line returns false, so matched == 0
            vm.expectRevert(PolymerProver.InvalidSourceChain.selector);
            polymerProver.validateSolana(proof);
        } else if (
            uint256(mutClaimant) >> 160 != 0 ||
            uint160(uint256(mutClaimant)) == 0
        ) {
            polymerProver.validateSolana(proof);
            assertEq(polymerProver.provenIntents(mutHash).claimant, address(0));
        } else {
            address mutAddr = address(uint160(uint256(mutClaimant)));
            _expectEmit();
            emit IProver.IntentProven(mutHash, mutAddr, SOLANA_CHAIN_ID);
            polymerProver.validateSolana(proof);
            assertEq(polymerProver.provenIntents(mutHash).claimant, mutAddr);
            assertEq(
                polymerProver.provenIntents(mutHash).destination,
                SOLANA_CHAIN_ID
            );
        }
    }

    /// @dev Reads 32 bytes of `data` at `offset`; the model's copy of _slice32
    function _word(
        bytes memory data,
        uint256 offset
    ) internal pure returns (bytes32 out) {
        assembly {
            out := mload(add(add(data, 0x20), offset))
        }
    }

    function _isHexChar(uint8 c) internal pure returns (bool) {
        return
            (c >= 0x30 && c <= 0x39) ||
            (c >= 0x61 && c <= 0x66) ||
            (c >= 0x41 && c <= 0x46);
    }

    /// @dev Value of a hex char the caller has already checked with _isHexChar
    function _nibbleOf(uint8 c) internal pure returns (uint8) {
        if (c <= 0x39) return c - 0x30;
        if (c >= 0x61) return c - 0x61 + 10;
        return c - 0x41 + 10;
    }

    function testValidateSolanaBatch() public {
        bytes32 hashA = keccak256("a");
        bytes32 hashB = keccak256("b");
        string[] memory logsA = new string[](1);
        logsA[0] = _validLog(hashA);
        string[] memory logsB = new string[](1);
        logsB[0] = _validLog(hashB);

        bytes[] memory proofs = new bytes[](2);
        proofs[0] = _setSolanaProof(logsA);
        proofs[1] = _setSolanaProof(logsB);
        polymerProver.validateSolanaBatch(proofs);

        assertEq(polymerProver.provenIntents(hashA).claimant, claimant);
        assertEq(polymerProver.provenIntents(hashB).claimant, claimant);
    }

    /// @dev The batch loop has no per-element try/catch: one malformed proof reverts every
    ///      element, including intents earlier proofs already recorded. All-or-nothing is a
    ///      decision, not an accident — a relayer must resubmit the batch without the bad proof.
    function testValidateSolanaBatchOneBadProofRevertsAll() public {
        string[] memory logsA = new string[](1);
        logsA[0] = _validLog(keccak256("a"));
        string[] memory logsB = new string[](1);
        logsB[0] = "program: garbage";

        bytes[] memory proofs = new bytes[](2);
        proofs[0] = _setSolanaProof(logsA);
        proofs[1] = _setSolanaProof(logsB);

        vm.expectRevert(PolymerProver.InvalidSolanaLog.selector);
        polymerProver.validateSolanaBatch(proofs);
        assertEq(
            polymerProver.provenIntents(keccak256("a")).claimant,
            address(0)
        );
    }

    // ------------- SOLANA LOG PROOF REJECTION -------------

    /// @notice A well-formed line for this chain, SOLANA_CHAIN_ID and `claimant`
    function _validLog(
        bytes32 intentHash
    ) internal view returns (string memory) {
        return
            _solanaLog(
                SOLANA_PROGRAM_ID,
                uint64(block.chainid),
                SOLANA_CHAIN_ID,
                intentHash,
                bytes32(uint256(uint160(claimant)))
            );
    }

    function testValidateSolanaRevertsOnWrongPolymerChainId() public {
        string[] memory logs = new string[](1);
        logs[0] = _validLog(keccak256("x"));
        bytes memory proof = _setSolanaProofFor(
            SOLANA_POLYMER_CHAIN_ID + 1,
            SOLANA_PROGRAM_ID,
            logs
        );

        vm.expectRevert(PolymerProver.InvalidDestinationChain.selector);
        polymerProver.validateSolana(proof);
    }

    function testValidateSolanaRevertsOnNonWhitelistedProgram() public {
        bytes32 other = keccak256("other program");
        string[] memory logs = new string[](1);
        logs[0] = _solanaLog(
            other,
            uint64(block.chainid),
            SOLANA_CHAIN_ID,
            keccak256("x"),
            bytes32(uint256(uint160(claimant)))
        );
        bytes memory proof = _setSolanaProofFor(
            SOLANA_POLYMER_CHAIN_ID,
            other,
            logs
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                PolymerProver.InvalidSolanaProgram.selector,
                other
            )
        );
        polymerProver.validateSolana(proof);
    }

    function testValidateSolanaRevertsOnNoLogs() public {
        string[] memory logs = new string[](0);
        bytes memory proof = _setSolanaProof(logs);

        vm.expectRevert(PolymerProver.EmptyProofData.selector);
        polymerProver.validateSolana(proof);
    }

    function testValidateSolanaRevertsOnProgramMismatchInLog() public {
        // Proof says SOLANA_PROGRAM_ID, the line names another program.
        string[] memory logs = new string[](1);
        logs[0] = _solanaLog(
            keccak256("impostor"),
            uint64(block.chainid),
            SOLANA_CHAIN_ID,
            keccak256("x"),
            bytes32(uint256(uint160(claimant)))
        );
        bytes memory proof = _setSolanaProof(logs);

        vm.expectRevert(PolymerProver.SolanaLogProgramMismatch.selector);
        polymerProver.validateSolana(proof);
    }

    function testValidateSolanaRevertsOnNonCanonicalProgramId() public {
        // Same numeric value as the canonical id, but with base58 leading-zero padding:
        // the comparison is against the canonical string, not the decoded number. The
        // prefixed `1` is non-canonical only because SOLANA_PROGRAM_ID's first byte is
        // nonzero; for a key that starts with 0x00 a leading `1` IS canonical, see
        // testBase58EncodesLeadingZeroBytes and testValidateSolanaAcceptsLeadingZeroProgramId.
        string[] memory logs = new string[](1);
        logs[0] = _solanaLogWithProgramSegment(
            string.concat(
                "1",
                Base58.encode(abi.encodePacked(SOLANA_PROGRAM_ID))
            ),
            keccak256("x")
        );
        bytes memory proof = _setSolanaProof(logs);

        vm.expectRevert(PolymerProver.SolanaLogProgramMismatch.selector);
        polymerProver.validateSolana(proof);
    }

    function testValidateSolanaRevertsOnNonBase58ProgramChars() public {
        // `0`, `O`, `I`, `l` are outside the base58 alphabet; no library decode
        // is involved, so this is the contract's own error, not Base58's.
        string[] memory logs = new string[](1);
        logs[0] = _solanaLogWithProgramSegment("0OIl", keccak256("x"));
        bytes memory proof = _setSolanaProof(logs);

        vm.expectRevert(PolymerProver.SolanaLogProgramMismatch.selector);
        polymerProver.validateSolana(proof);
    }

    function testValidateSolanaRevertsOnOverlongProgramField() public {
        // 50 base58 chars would overflow a 256-bit decode; the canonical-string
        // comparison never decodes, so it fails closed with the declared error.
        bytes memory big = new bytes(50);
        for (uint256 i = 0; i < big.length; i++) {
            big[i] = "z";
        }
        string[] memory logs = new string[](1);
        logs[0] = _solanaLogWithProgramSegment(string(big), keccak256("x"));
        bytes memory proof = _setSolanaProof(logs);

        vm.expectRevert(PolymerProver.SolanaLogProgramMismatch.selector);
        polymerProver.validateSolana(proof);
    }

    function testValidateSolanaRevertsOnMissingProgramPrefix() public {
        string[] memory logs = new string[](1);
        logs[0] = "hello world";
        bytes memory proof = _setSolanaProof(logs);

        vm.expectRevert(PolymerProver.InvalidSolanaLog.selector);
        polymerProver.validateSolana(proof);
    }

    function testValidateSolanaRevertsOnTruncatedLog() public {
        // Shorter than both `Prove:` and `program: `, so the bounds guard in
        // _startsWithAt is what rejects, not a byte compare.
        string[] memory logs = new string[](1);

        logs[0] = "prog";
        bytes memory proof = _setSolanaProof(logs);
        vm.expectRevert(PolymerProver.InvalidSolanaLog.selector);
        polymerProver.validateSolana(proof);

        logs[0] = "";
        proof = _setSolanaProof(logs);
        vm.expectRevert(PolymerProver.InvalidSolanaLog.selector);
        polymerProver.validateSolana(proof);
    }

    function testValidateSolanaRevertsOnShortPayload() public {
        string[] memory logs = new string[](1);
        bytes memory line = bytes(_validLog(keccak256("x")));
        bytes memory truncated = new bytes(line.length - 2);
        for (uint256 i = 0; i < truncated.length; i++) {
            truncated[i] = line[i];
        }
        logs[0] = string(truncated);
        bytes memory proof = _setSolanaProof(logs);

        vm.expectRevert(PolymerProver.InvalidSolanaLog.selector);
        polymerProver.validateSolana(proof);
    }

    function testValidateSolanaRevertsOnTrailingGarbage() public {
        string[] memory logs = new string[](1);
        logs[0] = string.concat(_validLog(keccak256("x")), ", extra");
        bytes memory proof = _setSolanaProof(logs);

        vm.expectRevert(PolymerProver.InvalidSolanaLog.selector);
        polymerProver.validateSolana(proof);
    }

    function testValidateSolanaRevertsOnWrongSeparator() public {
        // The byte after the comma must be a space. Same total length, so the
        // length check still passes and the separator check is what reverts.
        // It sits deterministically at length - hexLen - 1 because the length
        // check pins `comma + 2 + hexLen == length`.
        uint256 sep = bytes(_validLog(keccak256("x"))).length -
            polymerProver.SOLANA_LOG_HEX_LENGTH() -
            1;
        bytes1[2] memory replacements = [bytes1(","), bytes1("0")];
        for (uint256 i = 0; i < replacements.length; i++) {
            bytes memory line = bytes(_validLog(keccak256("x")));
            assertEq(line[sep], " ");
            line[sep] = replacements[i];
            string[] memory logs = new string[](1);
            logs[0] = string(line);
            bytes memory proof = _setSolanaProof(logs);

            vm.expectRevert(PolymerProver.InvalidSolanaLog.selector);
            polymerProver.validateSolana(proof);
        }
    }

    function testValidateSolanaRevertsOnNonHexPayload() public {
        string[] memory logs = new string[](1);
        bytes memory line = bytes(_validLog(keccak256("x")));
        line[line.length - 1] = "z";
        logs[0] = string(line);
        bytes memory proof = _setSolanaProof(logs);

        vm.expectRevert(PolymerProver.InvalidSolanaLog.selector);
        polymerProver.validateSolana(proof);
    }

    function testValidateSolanaRevertsOnWrongSourceChain() public {
        string[] memory logs = new string[](1);
        logs[0] = _solanaLog(
            SOLANA_PROGRAM_ID,
            uint64(block.chainid) + 1,
            SOLANA_CHAIN_ID,
            keccak256("x"),
            bytes32(uint256(uint160(claimant)))
        );
        bytes memory proof = _setSolanaProof(logs);

        vm.expectRevert(PolymerProver.InvalidSourceChain.selector);
        polymerProver.validateSolana(proof);
    }

    function testValidateSolanaRevertsOnWrongDestinationChain() public {
        string[] memory logs = new string[](1);
        logs[0] = _solanaLog(
            SOLANA_PROGRAM_ID,
            uint64(block.chainid),
            SOLANA_CHAIN_ID + 1,
            keccak256("x"),
            bytes32(uint256(uint160(claimant)))
        );
        bytes memory proof = _setSolanaProof(logs);

        vm.expectRevert(PolymerProver.InvalidDestinationChain.selector);
        polymerProver.validateSolana(proof);
    }

    function testValidateSolanaOneBadLogRevertsWholeProof() public {
        string[] memory logs = new string[](2);
        logs[0] = _validLog(keccak256("good"));
        logs[1] = "program: garbage";
        bytes memory proof = _setSolanaProof(logs);

        vm.expectRevert(PolymerProver.InvalidSolanaLog.selector);
        polymerProver.validateSolana(proof);
        assertEq(
            polymerProver.provenIntents(keccak256("good")).claimant,
            address(0)
        );
    }

    function testValidateSolanaProofSurvivesMatchingChallenge() public {
        // A Solana-recorded proof carries destination SOLANA_CHAIN_ID; challenging
        // with that same destination is a no-op and the proof is kept.
        bytes32 routeHash = keccak256("route");
        bytes32 rewardHash = keccak256("reward");
        bytes32 intentHash = keccak256(
            abi.encodePacked(SOLANA_CHAIN_ID, routeHash, rewardHash)
        );
        string[] memory logs = new string[](1);
        logs[0] = _validLog(intentHash);
        polymerProver.validateSolana(_setSolanaProof(logs));
        assertEq(
            polymerProver.provenIntents(intentHash).destination,
            SOLANA_CHAIN_ID
        );

        polymerProver.challengeIntentProof(
            SOLANA_CHAIN_ID,
            routeHash,
            rewardHash
        );
        // matching destination: kept
        assertEq(polymerProver.provenIntents(intentHash).claimant, claimant);
    }

    function testValidateSolanaProofIsChallengeable() public {
        // A log may carry an intentHash committed to a destination other than Solana;
        // challengeIntentProof is the safety mechanism that removes such a proof.
        bytes32 routeHash = keccak256("route");
        bytes32 rewardHash = keccak256("reward");
        uint64 otherDestination = SOLANA_CHAIN_ID + 1;
        bytes32 wrongHash = keccak256(
            abi.encodePacked(otherDestination, routeHash, rewardHash)
        );

        string[] memory logs = new string[](1);
        logs[0] = _validLog(wrongHash); // payload destination is still SOLANA_CHAIN_ID
        polymerProver.validateSolana(_setSolanaProof(logs));
        assertEq(
            polymerProver.provenIntents(wrongHash).destination,
            SOLANA_CHAIN_ID
        );

        _expectEmit();
        emit IProver.IntentProofInvalidated(wrongHash);
        polymerProver.challengeIntentProof(
            otherDestination,
            routeHash,
            rewardHash
        );
        assertEq(polymerProver.provenIntents(wrongHash).claimant, address(0));
    }

    // ------------- SOLANA GOLDEN (cross-repo wire format) -------------

    function testBase58DecodesSvmProgramId() public pure {
        assertEq(
            Base58.decodeWord("EcotL2wbUqtRAjnf1p6aa842dM4fc8ZX6JhygibtBreo"),
            SVM_PROGRAM_KEY
        );
        assertEq(
            Base58.encode(abi.encodePacked(SVM_PROGRAM_KEY)),
            "EcotL2wbUqtRAjnf1p6aa842dM4fc8ZX6JhygibtBreo"
        );
    }

    /// @dev Pins Base58.encode's leading-zero-byte branch (one `1` per 0x00 lead byte),
    ///      which validateSolana's canonical-string comparison depends on and which no
    ///      other program ID in this suite reaches. Literals are from an off-chain
    ///      reference base58, not from Base58.sol, so a mis-vendoring of that assembly
    ///      fails here rather than rejecting every proof from such a program.
    function testBase58EncodesLeadingZeroBytes() public pure {
        assertEq(
            Base58.encode(abi.encodePacked(SOLANA_PROGRAM_ID_ONE_ZERO)),
            "14bijitV5HcXvZTNHKpmiXWtC7s9b8JE8fDsCWTZNKco"
        );
        assertEq(
            Base58.encode(abi.encodePacked(SOLANA_PROGRAM_ID_TWO_ZEROS)),
            "11pHhwoZBwWoRpgWHqfvBKF2BDtEjAox5ucYK1nSTaf"
        );
        assertEq(
            Base58.decodeWord("14bijitV5HcXvZTNHKpmiXWtC7s9b8JE8fDsCWTZNKco"),
            SOLANA_PROGRAM_ID_ONE_ZERO
        );
        assertEq(
            Base58.decodeWord("11pHhwoZBwWoRpgWHqfvBKF2BDtEjAox5ucYK1nSTaf"),
            SOLANA_PROGRAM_ID_TWO_ZEROS
        );
    }

    /// @dev End to end through expectedProgramStrHash for a program whose canonical
    ///      base58 carries a leading `1`.
    function testValidateSolanaAcceptsLeadingZeroProgramId() public {
        bytes32[] memory provers = new bytes32[](1);
        provers[0] = SOLANA_PROGRAM_ID_ONE_ZERO;
        PolymerProver p = new PolymerProver(
            address(portal),
            address(crossL2ProverV2),
            32 * 1024,
            SOLANA_POLYMER_CHAIN_ID,
            SOLANA_CHAIN_ID,
            provers
        );
        bytes32 intentHash = keccak256("leading-zero-program");
        string[] memory logs = new string[](1);
        logs[0] = _solanaLog(
            SOLANA_PROGRAM_ID_ONE_ZERO,
            uint64(block.chainid),
            SOLANA_CHAIN_ID,
            intentHash,
            bytes32(uint256(uint160(claimant)))
        );
        bytes memory proof = _setSolanaProofFor(
            SOLANA_POLYMER_CHAIN_ID,
            SOLANA_PROGRAM_ID_ONE_ZERO,
            logs
        );

        p.validateSolana(proof);
        assertEq(p.provenIntents(intentHash).claimant, claimant);
        assertEq(p.provenIntents(intentHash).destination, SOLANA_CHAIN_ID);
    }

    function testValidateSolanaAcceptsSvmGoldenLogLine() public {
        PolymerProver golden = _deployGoldenProver();
        vm.chainId(SVM_GOLDEN_SOURCE_CHAIN_ID);

        string[] memory logs = new string[](1);
        logs[0] = SVM_GOLDEN_LOG;
        bytes memory proof = _setSolanaProofFor(
            SOLANA_POLYMER_CHAIN_ID,
            SVM_PROGRAM_KEY,
            logs
        );

        // Parses end to end (a foreign source or any malformed field would revert);
        // the non-EVM claimant (0x2222..22) is skipped, not recorded.
        golden.validateSolana(proof);
        assertEq(
            golden.provenIntents(SVM_GOLDEN_INTENT_HASH).claimant,
            address(0)
        );
        assertEq(golden.provenIntents(SVM_GOLDEN_INTENT_HASH).destination, 0);
    }

    /// Same pinned line with ONLY the trailing 64-char claimant field swapped for an
    /// EVM-shaped one. Everything before it is the golden, byte for byte. This is the
    /// vector that catches a field-order swap: it asserts the hash comes from offset
    /// 16 and the claimant from offset 48.
    function testValidateSolanaGoldenLineWithEvmClaimantEmitsIntentProven()
        public
    {
        PolymerProver golden = _deployGoldenProver();
        vm.chainId(SVM_GOLDEN_SOURCE_CHAIN_ID);

        bytes memory line = bytes(SVM_GOLDEN_LOG);
        bytes memory claimantHex = bytes(
            _hexNoPrefix(abi.encodePacked(bytes32(uint256(uint160(claimant)))))
        );
        for (uint256 i = 0; i < 64; i++) {
            line[line.length - 64 + i] = claimantHex[i];
        }

        string[] memory logs = new string[](1);
        logs[0] = string(line);
        bytes memory proof = _setSolanaProofFor(
            SOLANA_POLYMER_CHAIN_ID,
            SVM_PROGRAM_KEY,
            logs
        );

        _expectEmit();
        emit IProver.IntentProven(
            SVM_GOLDEN_INTENT_HASH,
            claimant,
            SVM_GOLDEN_DEST_CHAIN_ID
        );
        golden.validateSolana(proof);
    }
}

/// @notice Minimal view of Inbox.prove used by the reentrancy attacker.
interface IInboxProve {
    function prove(
        address prover,
        uint64 sourceChainDomainID,
        bytes32[] memory intentHashes,
        bytes memory data
    ) external payable;
}

/// @notice Refund recipient that rejects ETH, forcing the dust-retention branch.
contract RejectingRefundRecipient {
    receive() external payable {
        revert("RejectingRefundRecipient: I reject your ETH");
    }

    fallback() external payable {
        revert("RejectingRefundRecipient: I reject your ETH");
    }
}

/// @notice Malicious refund recipient that attempts to reenter Inbox.prove from
/// its receive() when it is paid the forwarded refund. Records whether the
/// reentrant call reverted so the guard can be asserted from the test.
contract ReentrantProveCaller {
    IInboxProve public immutable portal;
    address public immutable prover;
    uint64 public immutable domain;
    bytes32[] public intentHashes;

    bool public reentrancyAttempted;
    bool public reentrantReverted;
    bytes public reentrantRevertData;

    constructor(
        address _portal,
        address _prover,
        uint64 _domain,
        bytes32[] memory _intentHashes
    ) {
        portal = IInboxProve(_portal);
        prover = _prover;
        domain = _domain;
        intentHashes = _intentHashes;
    }

    /// @notice Kick off the outer Inbox.prove call, forwarding our full balance.
    function attack() external {
        portal.prove{value: address(this).balance}(
            prover,
            domain,
            intentHashes,
            ""
        );
    }

    /// @notice Invoked when the prover refunds the forwarded value. Attempts to
    /// reenter Inbox.prove; the nonReentrant guard must revert this. We swallow
    /// the revert (low-level call, not propagated) so this receive() returns
    /// success — the outer refund call therefore returns true and, under V9's
    /// revert-on-failure refund, does NOT trigger RefundFailed. This keeps the
    /// test's meaning: the reentrant prove is blocked, but the legitimate refund
    /// to the caller still lands and the outer prove succeeds.
    receive() external payable {
        if (reentrancyAttempted) {
            return;
        }
        reentrancyAttempted = true;

        (bool ok, bytes memory ret) = address(portal).call(
            abi.encodeWithSelector(
                IInboxProve.prove.selector,
                prover,
                domain,
                intentHashes,
                bytes("")
            )
        );

        reentrantReverted = !ok;
        reentrantRevertData = ret;
    }
}
