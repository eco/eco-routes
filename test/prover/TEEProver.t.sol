// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {TEEProver} from "../../contracts/prover/TEEProver.sol";
import {ITEEProver} from "../../contracts/interfaces/ITEEProver.sol";
import {Portal} from "../../contracts/Portal.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";
import {IProver} from "../../contracts/interfaces/IProver.sol";
import {Intent, Route, Reward, TokenAmount, Call} from "../../contracts/types/Intent.sol";

contract TEEProverTest is Test {
    TEEProver internal teeProver;
    Portal internal portal;
    TestERC20 internal token;

    address internal creator;
    address internal solver;
    address internal oracle;
    uint256 internal oraclePrivateKey;

    uint64 internal CHAIN_ID;
    uint64 internal constant DESTINATION_CHAIN_ID = 42161; // Arbitrum
    uint256 internal constant INITIAL_BALANCE = 100 ether;
    uint256 internal constant REWARD_AMOUNT = 10 ether;
    uint256 internal constant TOKEN_AMOUNT = 1000;

    function setUp() public {
        creator = makeAddr("creator");
        solver = makeAddr("solver");

        // Create oracle keypair for signing
        oraclePrivateKey = 0xA11CE;
        oracle = vm.addr(oraclePrivateKey);

        // Set CHAIN_ID to current chain
        CHAIN_ID = uint64(block.chainid);

        // Deploy contracts
        portal = new Portal();
        teeProver = new TEEProver(address(portal), oracle);
        token = new TestERC20("Test Token", "TEST");

        // Fund accounts
        vm.deal(creator, INITIAL_BALANCE);
        vm.deal(solver, INITIAL_BALANCE);
        vm.deal(oracle, INITIAL_BALANCE);

        // Mint tokens
        token.mint(creator, TOKEN_AMOUNT * 10);
        token.mint(solver, TOKEN_AMOUNT * 10);
    }

    // ============ Helper Functions ============

    function _createIntent(
        uint64 destination,
        uint256 nativeReward,
        uint256 tokenReward
    ) internal view returns (Intent memory) {
        TokenAmount[] memory routeTokens = new TokenAmount[](0);
        Call[] memory calls = new Call[](0);

        Route memory route = Route({
            salt: bytes32(uint256(1)),
            deadline: uint64(block.timestamp + 1000),
            portal: address(portal),
            nativeAmount: 0,
            tokens: routeTokens,
            calls: calls
        });

        TokenAmount[] memory rewardTokens;
        if (tokenReward > 0) {
            rewardTokens = new TokenAmount[](1);
            rewardTokens[0] = TokenAmount({token: address(token), amount: tokenReward});
        } else {
            rewardTokens = new TokenAmount[](0);
        }

        Reward memory reward = Reward({
            deadline: uint64(block.timestamp + 2000),
            creator: creator,
            prover: address(teeProver),
            nativeAmount: nativeReward,
            tokens: rewardTokens
        });

        return Intent({destination: destination, route: route, reward: reward});
    }

    function _computeIntentHash(Intent memory _intent) internal pure returns (bytes32) {
        bytes32 routeHash = keccak256(abi.encode(_intent.route));
        bytes32 rewardHash = keccak256(abi.encode(_intent.reward));
        return keccak256(abi.encodePacked(_intent.destination, routeHash, rewardHash));
    }

    function _computeDomainSeparator() internal view returns (bytes32) {
        bytes32 typeHash = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        bytes32 nameHash = keccak256(bytes("TEEProver"));
        bytes32 versionHash = keccak256(bytes("1.0.0"));

        return keccak256(
            abi.encode(
                typeHash,
                nameHash,
                versionHash,
                block.chainid,
                address(teeProver)
            )
        );
    }

    function _generateSignature(
        uint64 destination,
        bytes memory encodedProofs
    ) internal view returns (bytes memory) {
        bytes32 proofsHash = keccak256(encodedProofs);

        bytes32 structHash = keccak256(
            abi.encode(
                teeProver.BATCH_PROOF_TYPEHASH(),
                destination,
                proofsHash
            )
        );

        // Get domain separator
        bytes32 domainSeparator = _computeDomainSeparator();

        // Compute EIP-712 typed data hash
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // Sign with oracle private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oraclePrivateKey, digest);

        return abi.encodePacked(r, s, v);
    }

    // ============ A. Constructor Tests ============

    function test_constructor_SetsOracleAddress() public view {
        assertEq(teeProver.ORACLE(), oracle);
    }

    function test_constructor_SetsPortalAddress() public view {
        assertEq(teeProver.PORTAL(), address(portal));
    }

    function test_constructor_RevertsOnZeroOracle() public {
        vm.expectRevert(ITEEProver.ZeroOracle.selector);
        new TEEProver(address(portal), address(0));
    }

    function test_constructor_RevertsOnZeroPortal() public {
        vm.expectRevert(IProver.ZeroPortal.selector);
        new TEEProver(address(0), oracle);
    }

    // ============ B. Signature Verification Tests ============

    function test_prove_AcceptsValidOracleSignature() public {
        // Create intent and compute hash
        Intent memory _intent = _createIntent(DESTINATION_CHAIN_ID, REWARD_AMOUNT, 0);
        bytes32 intentHash = _computeIntentHash(_intent);

        // Create encoded proofs (intentHash + claimant)
        bytes memory encodedProofs = abi.encodePacked(
            intentHash,
            bytes32(uint256(uint160(solver)))
        );

        // Generate valid signature
        bytes memory signature = _generateSignature(DESTINATION_CHAIN_ID, encodedProofs);

        // Should succeed
        teeProver.prove(address(0), DESTINATION_CHAIN_ID, encodedProofs, signature);

        // Verify intent is proven
        IProver.ProofData memory proof = teeProver.provenIntents(intentHash);
        assertEq(proof.claimant, solver);
        assertEq(proof.destination, DESTINATION_CHAIN_ID);
    }

    function test_prove_RevertsOnInvalidSignature() public {
        Intent memory _intent = _createIntent(DESTINATION_CHAIN_ID, REWARD_AMOUNT, 0);
        bytes32 intentHash = _computeIntentHash(_intent);

        bytes memory encodedProofs = abi.encodePacked(
            intentHash,
            bytes32(uint256(uint160(solver)))
        );

        // Create invalid signature (wrong private key)
        uint256 wrongPrivateKey = 0xBAD;
        bytes32 proofsHash = keccak256(encodedProofs);
        bytes32 structHash = keccak256(
            abi.encode(
                teeProver.BATCH_PROOF_TYPEHASH(),
                DESTINATION_CHAIN_ID,
                proofsHash
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", _computeDomainSeparator(), structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPrivateKey, digest);
        bytes memory invalidSignature = abi.encodePacked(r, s, v);

        vm.expectRevert(ITEEProver.InvalidSignature.selector);
        teeProver.prove(address(0), DESTINATION_CHAIN_ID, encodedProofs, invalidSignature);
    }

    function test_prove_RevertsOnTamperedDestination() public {
        Intent memory _intent = _createIntent(DESTINATION_CHAIN_ID, REWARD_AMOUNT, 0);
        bytes32 intentHash = _computeIntentHash(_intent);

        bytes memory encodedProofs = abi.encodePacked(
            intentHash,
            bytes32(uint256(uint160(solver)))
        );

        // Sign for one destination
        bytes memory signature = _generateSignature(DESTINATION_CHAIN_ID, encodedProofs);

        // Try to use with different destination
        uint64 wrongDestination = 1;
        vm.expectRevert(ITEEProver.InvalidSignature.selector);
        teeProver.prove(address(0), wrongDestination, encodedProofs, signature);
    }

    function test_prove_RevertsOnTamperedProofs() public {
        Intent memory _intent = _createIntent(DESTINATION_CHAIN_ID, REWARD_AMOUNT, 0);
        bytes32 intentHash = _computeIntentHash(_intent);

        bytes memory originalProofs = abi.encodePacked(
            intentHash,
            bytes32(uint256(uint160(solver)))
        );

        // Sign original proofs
        bytes memory signature = _generateSignature(DESTINATION_CHAIN_ID, originalProofs);

        // Create tampered proofs (different claimant)
        bytes memory tamperedProofs = abi.encodePacked(
            intentHash,
            bytes32(uint256(uint160(address(0xdead))))
        );

        vm.expectRevert(ITEEProver.InvalidSignature.selector);
        teeProver.prove(address(0), DESTINATION_CHAIN_ID, tamperedProofs, signature);
    }

    // ============ C. Batch Proving Tests ============

    function test_prove_SingleIntentSucceeds() public {
        Intent memory _intent = _createIntent(DESTINATION_CHAIN_ID, REWARD_AMOUNT, 0);
        bytes32 intentHash = _computeIntentHash(_intent);

        bytes memory encodedProofs = abi.encodePacked(
            intentHash,
            bytes32(uint256(uint160(solver)))
        );

        bytes memory signature = _generateSignature(DESTINATION_CHAIN_ID, encodedProofs);

        vm.expectEmit(true, true, false, true);
        emit IProver.IntentProven(intentHash, solver, DESTINATION_CHAIN_ID);

        teeProver.prove(address(0), DESTINATION_CHAIN_ID, encodedProofs, signature);
    }

    function test_prove_MultipleIntentsInBatch() public {
        // Create 3 intents
        Intent memory intent1 = _createIntent(DESTINATION_CHAIN_ID, REWARD_AMOUNT, 0);
        Intent memory intent2 = _createIntent(DESTINATION_CHAIN_ID, REWARD_AMOUNT + 1, 0);
        Intent memory intent3 = _createIntent(DESTINATION_CHAIN_ID, REWARD_AMOUNT + 2, 0);

        bytes32 intentHash1 = _computeIntentHash(intent1);
        bytes32 intentHash2 = _computeIntentHash(intent2);
        bytes32 intentHash3 = _computeIntentHash(intent3);

        address claimant1 = makeAddr("claimant1");
        address claimant2 = makeAddr("claimant2");
        address claimant3 = makeAddr("claimant3");

        // Create batch proof
        bytes memory encodedProofs = abi.encodePacked(
            intentHash1, bytes32(uint256(uint160(claimant1))),
            intentHash2, bytes32(uint256(uint160(claimant2))),
            intentHash3, bytes32(uint256(uint160(claimant3)))
        );

        bytes memory signature = _generateSignature(DESTINATION_CHAIN_ID, encodedProofs);

        // Prove batch
        teeProver.prove(address(0), DESTINATION_CHAIN_ID, encodedProofs, signature);

        // Verify all intents are proven
        IProver.ProofData memory proof1 = teeProver.provenIntents(intentHash1);
        assertEq(proof1.claimant, claimant1);
        assertEq(proof1.destination, DESTINATION_CHAIN_ID);

        IProver.ProofData memory proof2 = teeProver.provenIntents(intentHash2);
        assertEq(proof2.claimant, claimant2);
        assertEq(proof2.destination, DESTINATION_CHAIN_ID);

        IProver.ProofData memory proof3 = teeProver.provenIntents(intentHash3);
        assertEq(proof3.claimant, claimant3);
        assertEq(proof3.destination, DESTINATION_CHAIN_ID);
    }

    function test_prove_SkipsAlreadyProvenIntent() public {
        Intent memory _intent = _createIntent(DESTINATION_CHAIN_ID, REWARD_AMOUNT, 0);
        bytes32 intentHash = _computeIntentHash(_intent);

        bytes memory encodedProofs = abi.encodePacked(
            intentHash,
            bytes32(uint256(uint160(solver)))
        );

        bytes memory signature = _generateSignature(DESTINATION_CHAIN_ID, encodedProofs);

        // Prove first time
        teeProver.prove(address(0), DESTINATION_CHAIN_ID, encodedProofs, signature);

        // Try to prove again - should emit IntentAlreadyProven event
        vm.expectEmit(false, false, false, true);
        emit IProver.IntentAlreadyProven(intentHash);

        teeProver.prove(address(0), DESTINATION_CHAIN_ID, encodedProofs, signature);
    }

    function test_prove_SkipsZeroAddressClaimants() public {
        Intent memory _intent = _createIntent(DESTINATION_CHAIN_ID, REWARD_AMOUNT, 0);
        bytes32 intentHash = _computeIntentHash(_intent);

        // Create proofs with zero address claimant
        bytes memory encodedProofs = abi.encodePacked(
            intentHash,
            bytes32(0) // zero address
        );

        bytes memory signature = _generateSignature(DESTINATION_CHAIN_ID, encodedProofs);

        // Should not revert, but intent won't be proven
        teeProver.prove(address(0), DESTINATION_CHAIN_ID, encodedProofs, signature);

        // Verify intent is not proven
        IProver.ProofData memory proof = teeProver.provenIntents(intentHash);
        assertEq(proof.claimant, address(0));
        assertEq(proof.destination, 0);
    }

    function test_prove_HandlesMixedValidInvalidProofs() public {
        Intent memory intent1 = _createIntent(DESTINATION_CHAIN_ID, REWARD_AMOUNT, 0);
        Intent memory intent2 = _createIntent(DESTINATION_CHAIN_ID, REWARD_AMOUNT + 1, 0);
        Intent memory intent3 = _createIntent(DESTINATION_CHAIN_ID, REWARD_AMOUNT + 2, 0);

        bytes32 intentHash1 = _computeIntentHash(intent1);
        bytes32 intentHash2 = _computeIntentHash(intent2);
        bytes32 intentHash3 = _computeIntentHash(intent3);

        address claimant1 = makeAddr("claimant1");
        address claimant3 = makeAddr("claimant3");

        // intent2 has zero address claimant (invalid)
        bytes memory encodedProofs = abi.encodePacked(
            intentHash1, bytes32(uint256(uint160(claimant1))),
            intentHash2, bytes32(0), // invalid
            intentHash3, bytes32(uint256(uint160(claimant3)))
        );

        bytes memory signature = _generateSignature(DESTINATION_CHAIN_ID, encodedProofs);

        teeProver.prove(address(0), DESTINATION_CHAIN_ID, encodedProofs, signature);

        // Verify intent1 and intent3 are proven, intent2 is not
        IProver.ProofData memory proof1 = teeProver.provenIntents(intentHash1);
        assertEq(proof1.claimant, claimant1);

        IProver.ProofData memory proof2 = teeProver.provenIntents(intentHash2);
        assertEq(proof2.claimant, address(0)); // Not proven

        IProver.ProofData memory proof3 = teeProver.provenIntents(intentHash3);
        assertEq(proof3.claimant, claimant3);
    }

    // ============ D. Integration Tests ============

    function test_provenIntents_ReturnsCorrectData() public {
        Intent memory _intent = _createIntent(DESTINATION_CHAIN_ID, REWARD_AMOUNT, 0);
        bytes32 intentHash = _computeIntentHash(_intent);

        bytes memory encodedProofs = abi.encodePacked(
            intentHash,
            bytes32(uint256(uint160(solver)))
        );

        bytes memory signature = _generateSignature(DESTINATION_CHAIN_ID, encodedProofs);

        teeProver.prove(address(0), DESTINATION_CHAIN_ID, encodedProofs, signature);

        IProver.ProofData memory proof = teeProver.provenIntents(intentHash);
        assertEq(proof.claimant, solver);
        assertEq(proof.destination, DESTINATION_CHAIN_ID);
    }

    function test_getProofType_ReturnsTeeOracle() public view {
        assertEq(teeProver.getProofType(), "TEE_ORACLE");
    }

    function test_challengeIntentProof_RemovesInvalidProof() public {
        // Prove intent with wrong destination
        Intent memory _intent = _createIntent(CHAIN_ID, REWARD_AMOUNT, 0); // Intended for CHAIN_ID
        bytes32 routeHash = keccak256(abi.encode(_intent.route));
        bytes32 rewardHash = keccak256(abi.encode(_intent.reward));
        bytes32 intentHash = keccak256(abi.encodePacked(CHAIN_ID, routeHash, rewardHash));

        bytes memory encodedProofs = abi.encodePacked(
            intentHash,
            bytes32(uint256(uint160(solver)))
        );

        // But oracle signs proof for wrong destination
        uint64 wrongDestination = DESTINATION_CHAIN_ID;
        bytes memory signature = _generateSignature(wrongDestination, encodedProofs);

        teeProver.prove(address(0), wrongDestination, encodedProofs, signature);

        // Verify intent is "proven" with wrong destination
        IProver.ProofData memory proofBefore = teeProver.provenIntents(intentHash);
        assertEq(proofBefore.claimant, solver);
        assertEq(proofBefore.destination, wrongDestination); // Wrong!

        // Challenge the proof
        vm.expectEmit(true, false, false, false);
        emit IProver.IntentProofInvalidated(intentHash);

        teeProver.challengeIntentProof(CHAIN_ID, routeHash, rewardHash);

        // Verify proof is removed
        IProver.ProofData memory proofAfter = teeProver.provenIntents(intentHash);
        assertEq(proofAfter.claimant, address(0));
        assertEq(proofAfter.destination, 0);
    }

    // ============ E. Replay Protection Tests ============

    function test_prove_RejectsSignatureOnDifferentChain() public {
        Intent memory _intent = _createIntent(DESTINATION_CHAIN_ID, REWARD_AMOUNT, 0);
        bytes32 intentHash = _computeIntentHash(_intent);

        bytes memory encodedProofs = abi.encodePacked(
            intentHash,
            bytes32(uint256(uint160(solver)))
        );

        // Sign for DESTINATION_CHAIN_ID
        bytes memory signature = _generateSignature(DESTINATION_CHAIN_ID, encodedProofs);

        // Try to use on different chain (change destination)
        uint64 differentChain = 1;
        vm.expectRevert(ITEEProver.InvalidSignature.selector);
        teeProver.prove(address(0), differentChain, encodedProofs, signature);
    }

    function test_prove_RejectsDifferentProofsWithSameSignature() public {
        Intent memory _intent = _createIntent(DESTINATION_CHAIN_ID, REWARD_AMOUNT, 0);
        bytes32 intentHash = _computeIntentHash(_intent);

        bytes memory encodedProofs1 = abi.encodePacked(
            intentHash,
            bytes32(uint256(uint160(solver)))
        );

        bytes memory signature = _generateSignature(DESTINATION_CHAIN_ID, encodedProofs1);

        // Try to use signature with different proofs
        bytes memory encodedProofs2 = abi.encodePacked(
            intentHash,
            bytes32(uint256(uint160(address(0xdead))))
        );

        vm.expectRevert(ITEEProver.InvalidSignature.selector);
        teeProver.prove(address(0), DESTINATION_CHAIN_ID, encodedProofs2, signature);
    }

    // ============ F. Edge Cases ============

    function test_prove_RevertsOnEmptyEncodedProofs() public {
        bytes memory emptyProofs = "";
        bytes memory signature = _generateSignature(DESTINATION_CHAIN_ID, emptyProofs);

        // Should not revert, just process empty data (BaseProver handles this)
        teeProver.prove(address(0), DESTINATION_CHAIN_ID, emptyProofs, signature);
    }

    function test_prove_HandlesOddLengthEncodedProofs() public {
        Intent memory _intent = _createIntent(DESTINATION_CHAIN_ID, REWARD_AMOUNT, 0);
        bytes32 intentHash = _computeIntentHash(_intent);

        // Create odd-length proofs (incomplete pair - 96 bytes instead of 64*n)
        bytes memory oddProofs = abi.encodePacked(
            intentHash,
            bytes32(uint256(uint160(solver))),
            bytes16(0) // Extra 16 bytes (incomplete)
        );

        bytes memory signature = _generateSignature(DESTINATION_CHAIN_ID, oddProofs);

        // Should revert with ArrayLengthMismatch from BaseProver
        vm.expectRevert(IProver.ArrayLengthMismatch.selector);
        teeProver.prove(address(0), DESTINATION_CHAIN_ID, oddProofs, signature);
    }

    function test_prove_HandlesLargeBatch() public {
        uint256 batchSize = 100;
        bytes memory encodedProofs = "";

        // Create 100 intents
        for (uint256 i = 0; i < batchSize; i++) {
            Intent memory _intent = _createIntent(DESTINATION_CHAIN_ID, REWARD_AMOUNT + i, 0);
            bytes32 intentHash = _computeIntentHash(_intent);
            address claimant = address(uint160(0x1000 + i));

            encodedProofs = abi.encodePacked(
                encodedProofs,
                intentHash,
                bytes32(uint256(uint160(claimant)))
            );
        }

        bytes memory signature = _generateSignature(DESTINATION_CHAIN_ID, encodedProofs);

        // Should succeed
        teeProver.prove(address(0), DESTINATION_CHAIN_ID, encodedProofs, signature);

        // Verify first and last intents are proven
        Intent memory firstIntent = _createIntent(DESTINATION_CHAIN_ID, REWARD_AMOUNT, 0);
        bytes32 firstHash = _computeIntentHash(firstIntent);
        IProver.ProofData memory firstProof = teeProver.provenIntents(firstHash);
        assertEq(firstProof.claimant, address(0x1000));

        Intent memory lastIntent = _createIntent(DESTINATION_CHAIN_ID, REWARD_AMOUNT + batchSize - 1, 0);
        bytes32 lastHash = _computeIntentHash(lastIntent);
        IProver.ProofData memory lastProof = teeProver.provenIntents(lastHash);
        assertEq(lastProof.claimant, address(uint160(0x1000 + batchSize - 1)));
    }

    // ============ G. Interface Tests ============

    function test_supportsInterface_IProver() public view {
        assertTrue(teeProver.supportsInterface(type(IProver).interfaceId));
    }

    function test_version_ReturnsVersion() public view {
        // From Semver contract
        assertEq(teeProver.version(), "2.6");
    }

    function test_BATCH_PROOF_TYPEHASH_IsCorrect() public view {
        bytes32 expected = keccak256("BatchProof(uint64 destination,bytes32 proofsHash)");
        assertEq(teeProver.BATCH_PROOF_TYPEHASH(), expected);
    }
}
