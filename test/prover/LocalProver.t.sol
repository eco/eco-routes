// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {LocalProver} from "../../contracts/prover/LocalProver.sol";
import {Portal} from "../../contracts/Portal.sol";
import {TestProver} from "../../contracts/test/TestProver.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";
import {IProver} from "../../contracts/interfaces/IProver.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {Intent, Route, Reward, TokenAmount, Call} from "../../contracts/types/Intent.sol";

contract LocalProverTest is Test {
    LocalProver internal localProver;
    Portal internal portal;
    TestProver internal secondaryProver;
    TestERC20 internal token;

    address internal creator;
    address internal solver;
    address internal user;

    uint64 internal CHAIN_ID;
    uint64 internal constant SECONDARY_CHAIN_ID = 2;
    uint256 internal constant INITIAL_BALANCE = 100 ether;
    uint256 internal constant REWARD_AMOUNT = 10 ether;
    uint256 internal constant TOKEN_AMOUNT = 1000;

    event FlashFulfilled(
        bytes32 indexed intentHash,
        bytes32 indexed claimant,
        bytes32 indexed secondaryIntentHash
    );

    event EscrowReleased(
        bytes32 indexed intentHash,
        address indexed claimant,
        uint256 nativeAmount
    );

    event EscrowRefunded(
        bytes32 indexed intentHash,
        address indexed originalVault,
        uint256 nativeAmount
    );

    function setUp() public {
        creator = makeAddr("creator");
        solver = makeAddr("solver");
        user = makeAddr("user");

        // Set CHAIN_ID to current chain
        CHAIN_ID = uint64(block.chainid);

        // Deploy contracts
        portal = new Portal();
        localProver = new LocalProver(address(portal));
        secondaryProver = new TestProver(address(portal));
        token = new TestERC20("Test Token", "TEST");

        // Fund accounts
        vm.deal(creator, INITIAL_BALANCE);
        vm.deal(solver, INITIAL_BALANCE);
        vm.deal(user, INITIAL_BALANCE);

        // Mint tokens
        token.mint(creator, TOKEN_AMOUNT);
        token.mint(solver, TOKEN_AMOUNT);
    }

    function _createIntent(
        address proverAddress,
        uint256 nativeReward,
        uint256 tokenReward
    ) internal view returns (Intent memory) {
        TokenAmount[] memory routeTokens = new TokenAmount[](0);
        Call[] memory calls = new Call[](0);  // Empty calls array for testing

        Route memory route = Route({
            salt: bytes32(uint256(1)),
            deadline: uint64(block.timestamp + 1000),
            portal: address(portal),
            nativeAmount: 0,
            tokens: routeTokens,
            calls: calls
        });

        TokenAmount[] memory rewardTokens = new TokenAmount[](1);
        rewardTokens[0] = TokenAmount({token: address(token), amount: tokenReward});

        Reward memory reward = Reward({
            deadline: uint64(block.timestamp + 2000),
            creator: creator,
            prover: proverAddress,
            nativeAmount: nativeReward,
            tokens: rewardTokens
        });

        return Intent({destination: CHAIN_ID, route: route, reward: reward});
    }

    function _publishAndFundIntent(
        Intent memory _intent
    ) internal returns (bytes32 intentHash, address vault) {
        vm.startPrank(creator);

        // Approve tokens
        if (_intent.reward.tokens.length > 0) {
            token.approve(address(portal), _intent.reward.tokens[0].amount);
        }

        // Publish and fund
        (intentHash, vault) = portal.publishAndFund{value: _intent.reward.nativeAmount}(
            _intent,
            false
        );

        vm.stopPrank();
    }

    // ============ provenIntents Tests ============

    function test_provenIntents_ReturnsLocalProverForFlashFulfilled() public {
        Intent memory _intent = _createIntent(address(localProver), REWARD_AMOUNT, TOKEN_AMOUNT);
        (bytes32 intentHash, ) = _publishAndFundIntent(_intent);

        bytes32 secondaryIntentHash = keccak256("secondary");
        bytes32 claimantBytes = bytes32(uint256(uint160(solver)));

        // Create escrow via flashFulfill
        vm.prank(solver);
        localProver.flashFulfill(
            intentHash,
            _intent,
            claimantBytes,
            secondaryIntentHash,
            address(secondaryProver),
            uint64(block.timestamp + 1000)
        );

        // Should return LocalProver as claimant (for withdrawal purposes)
        IProver.ProofData memory proof = localProver.provenIntents(intentHash);
        assertEq(proof.claimant, address(localProver));
        assertEq(proof.destination, CHAIN_ID);
    }

    function test_provenIntents_ReturnsPortalClaimantForNormalIntent() public {
        Intent memory _intent = _createIntent(address(localProver), REWARD_AMOUNT, TOKEN_AMOUNT);
        (bytes32 intentHash, ) = _publishAndFundIntent(_intent);

        // Fulfill normally (not flash-fulfill)
        vm.startPrank(solver);
        vm.deal(solver, _intent.reward.nativeAmount);
        token.mint(solver, TOKEN_AMOUNT);
        token.approve(address(portal), TOKEN_AMOUNT);

        portal.fulfill{value: 0}(
            intentHash,
            _intent.route,
            keccak256(abi.encode(_intent.reward)),
            bytes32(uint256(uint160(solver)))
        );
        vm.stopPrank();

        // Should return solver from Portal's claimants
        IProver.ProofData memory proof = localProver.provenIntents(intentHash);
        assertEq(proof.claimant, solver);
        assertEq(proof.destination, CHAIN_ID);
    }

    function test_provenIntents_ReturnsZeroForNonExistentIntent() public {
        bytes32 nonExistentHash = keccak256("nonexistent");

        IProver.ProofData memory proof = localProver.provenIntents(nonExistentHash);
        assertEq(proof.claimant, address(0));
        assertEq(proof.destination, 0);
    }

    // ============ flashFulfill Tests ============

    function test_flashFulfill_Success() public {
        Intent memory _intent = _createIntent(address(localProver), REWARD_AMOUNT, TOKEN_AMOUNT);
        (bytes32 intentHash, ) = _publishAndFundIntent(_intent);

        bytes32 secondaryIntentHash = keccak256("secondary");
        bytes32 claimantBytes = bytes32(uint256(uint160(solver)));
        uint64 secondaryDeadline = uint64(block.timestamp + 3000);

        // Fund LocalProver with execution funds
        vm.deal(address(localProver), _intent.reward.nativeAmount);

        vm.startPrank(solver);
        vm.expectEmit(true, true, true, false);
        emit FlashFulfilled(intentHash, claimantBytes, secondaryIntentHash);

        localProver.flashFulfill(
            intentHash,
            _intent,
            claimantBytes,
            secondaryIntentHash,
            address(secondaryProver),
            secondaryDeadline
        );
        vm.stopPrank();

        // Verify escrow created by checking individual fields
        // Note: Can't directly destructure struct with dynamic array
        LocalProver.EscrowData memory escrow = _getEscrowData(intentHash);

        assertEq(escrow.claimant, solver);
        assertEq(escrow.secondaryIntentHash, secondaryIntentHash);
        assertEq(escrow.secondaryProver, address(secondaryProver));
        assertEq(escrow.secondaryDeadline, secondaryDeadline);
        assertFalse(escrow.released);
        assertGt(escrow.nativeAmount, 0); // Should have some native tokens from reward
    }

    function test_flashFulfill_RevertsIfInvalidSecondaryHash() public {
        Intent memory _intent = _createIntent(address(localProver), REWARD_AMOUNT, TOKEN_AMOUNT);
        (bytes32 intentHash, ) = _publishAndFundIntent(_intent);

        vm.startPrank(solver);
        vm.expectRevert("Invalid secondary intent hash");
        localProver.flashFulfill(
            intentHash,
            _intent,
            bytes32(uint256(uint160(solver))),
            bytes32(0), // Invalid
            address(secondaryProver),
            uint64(block.timestamp + 1000)
        );
        vm.stopPrank();
    }

    function test_flashFulfill_RevertsIfInvalidSecondaryProver() public {
        Intent memory _intent = _createIntent(address(localProver), REWARD_AMOUNT, TOKEN_AMOUNT);
        (bytes32 intentHash, ) = _publishAndFundIntent(_intent);

        vm.startPrank(solver);
        vm.expectRevert("Invalid secondary prover");
        localProver.flashFulfill(
            intentHash,
            _intent,
            bytes32(uint256(uint160(solver))),
            keccak256("secondary"),
            address(0), // Invalid
            uint64(block.timestamp + 1000)
        );
        vm.stopPrank();
    }

    function test_flashFulfill_RevertsIfAlreadyFlashFulfilled() public {
        Intent memory _intent = _createIntent(address(localProver), REWARD_AMOUNT, TOKEN_AMOUNT);
        (bytes32 intentHash, ) = _publishAndFundIntent(_intent);

        bytes32 secondaryIntentHash = keccak256("secondary");
        bytes32 claimantBytes = bytes32(uint256(uint160(solver)));

        vm.startPrank(solver);

        // First flashFulfill
        localProver.flashFulfill(
            intentHash,
            _intent,
            claimantBytes,
            secondaryIntentHash,
            address(secondaryProver),
            uint64(block.timestamp + 1000)
        );

        // Second flashFulfill should revert
        vm.expectRevert("Already flash-fulfilled");
        localProver.flashFulfill(
            intentHash,
            _intent,
            claimantBytes,
            secondaryIntentHash,
            address(secondaryProver),
            uint64(block.timestamp + 1000)
        );
        vm.stopPrank();
    }

    // ============ releaseEscrow Tests ============

    function test_releaseEscrow_Success() public {
        Intent memory _intent = _createIntent(address(localProver), REWARD_AMOUNT, TOKEN_AMOUNT);
        (bytes32 intentHash, ) = _publishAndFundIntent(_intent);

        bytes32 secondaryIntentHash = keccak256("secondary");
        bytes32 claimantBytes = bytes32(uint256(uint160(solver)));

        // FlashFulfill
        vm.prank(solver);
        localProver.flashFulfill(
            intentHash,
            _intent,
            claimantBytes,
            secondaryIntentHash,
            address(secondaryProver),
            uint64(block.timestamp + 1000)
        );

        // Simulate secondary intent proven
        vm.startPrank(address(secondaryProver));
        bytes32[] memory hashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        hashes[0] = secondaryIntentHash;
        claimants[0] = claimantBytes;

        bytes memory encodedProofs = _encodeProofs(hashes, claimants);
        secondaryProver.prove(solver, SECONDARY_CHAIN_ID, encodedProofs, "");
        vm.stopPrank();

        uint256 solverBalanceBefore = solver.balance;

        // Release escrow (permissionless)
        vm.prank(user);
        vm.expectEmit(true, true, false, false);
        emit EscrowReleased(intentHash, solver, 0);
        localProver.releaseEscrow(intentHash);

        // Verify funds transferred
        assertGt(solver.balance, solverBalanceBefore);

        // Verify escrow marked as released
        LocalProver.EscrowData memory escrow = _getEscrowData(intentHash);
        assertTrue(escrow.released);
    }

    function test_releaseEscrow_RevertsIfNoEscrow() public {
        bytes32 nonExistentHash = keccak256("nonexistent");

        vm.expectRevert("No escrow found");
        localProver.releaseEscrow(nonExistentHash);
    }

    function test_releaseEscrow_RevertsIfAlreadyReleased() public {
        Intent memory _intent = _createIntent(address(localProver), REWARD_AMOUNT, TOKEN_AMOUNT);
        (bytes32 intentHash, ) = _publishAndFundIntent(_intent);

        bytes32 secondaryIntentHash = keccak256("secondary");
        bytes32 claimantBytes = bytes32(uint256(uint160(solver)));

        // FlashFulfill
        vm.prank(solver);
        localProver.flashFulfill(
            intentHash,
            _intent,
            claimantBytes,
            secondaryIntentHash,
            address(secondaryProver),
            uint64(block.timestamp + 1000)
        );

        // Prove secondary
        vm.startPrank(address(secondaryProver));
        bytes32[] memory hashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        hashes[0] = secondaryIntentHash;
        claimants[0] = claimantBytes;
        bytes memory encodedProofs = _encodeProofs(hashes, claimants);
        secondaryProver.prove(solver, SECONDARY_CHAIN_ID, encodedProofs, "");
        vm.stopPrank();

        // Release once
        localProver.releaseEscrow(intentHash);

        // Try to release again
        vm.expectRevert("Already released");
        localProver.releaseEscrow(intentHash);
    }

    function test_releaseEscrow_RevertsIfSecondaryNotProven() public {
        Intent memory _intent = _createIntent(address(localProver), REWARD_AMOUNT, TOKEN_AMOUNT);
        (bytes32 intentHash, ) = _publishAndFundIntent(_intent);

        bytes32 secondaryIntentHash = keccak256("secondary");

        // FlashFulfill
        vm.prank(solver);
        localProver.flashFulfill(
            intentHash,
            _intent,
            bytes32(uint256(uint160(solver))),
            secondaryIntentHash,
            address(secondaryProver),
            uint64(block.timestamp + 1000)
        );

        // Try to release without proving secondary
        vm.expectRevert("Secondary intent not proven");
        localProver.releaseEscrow(intentHash);
    }

    // ============ refundEscrow Tests ============

    function test_refundEscrow_Success() public {
        Intent memory originalIntent = _createIntent(address(localProver), REWARD_AMOUNT, TOKEN_AMOUNT);
        (bytes32 originalIntentHash, address originalVault) = _publishAndFundIntent(originalIntent);

        // Create secondary intent (crosschain, using TestProver)
        // Note: Creator must be LocalProver so it can refund later
        Intent memory secondaryIntent = _createIntent(
            address(secondaryProver),
            REWARD_AMOUNT / 2,
            TOKEN_AMOUNT / 2
        );
        // Manually set creator to LocalProver
        secondaryIntent.reward.creator = address(localProver);

        (bytes32 secondaryIntentHash, , ) = portal.getIntentHash(secondaryIntent);
        uint64 secondaryDeadline = secondaryIntent.reward.deadline;

        // Pre-fund LocalProver with tokens for secondary intent
        // (In reality, this would come from the original flashFulfill's withdraw)
        token.mint(address(localProver), secondaryIntent.reward.tokens[0].amount);

        // Publish and fund secondary intent with LocalProver as creator
        vm.startPrank(address(localProver));
        token.approve(address(portal), secondaryIntent.reward.tokens[0].amount);
        vm.deal(address(localProver), secondaryIntent.reward.nativeAmount);
        portal.publishAndFund{value: secondaryIntent.reward.nativeAmount}(secondaryIntent, false);
        vm.stopPrank();

        // FlashFulfill original intent
        vm.prank(solver);
        localProver.flashFulfill(
            originalIntentHash,
            originalIntent,
            bytes32(uint256(uint160(solver))),
            secondaryIntentHash,
            address(secondaryProver),
            secondaryDeadline
        );

        // Fast forward past secondary intent's reward deadline (not just escrow deadline)
        vm.warp(secondaryIntent.reward.deadline + 1);

        // Get original vault balance before refund
        uint256 vaultBalanceBefore = originalVault.balance;

        // Refund escrow (permissionless)
        vm.prank(user);
        localProver.refundEscrow(originalIntentHash, originalIntent, secondaryIntent);

        // Verify funds transferred to original vault
        assertGt(originalVault.balance, vaultBalanceBefore);

        // Verify escrow marked as released
        LocalProver.EscrowData memory escrow = _getEscrowData(originalIntentHash);
        assertTrue(escrow.released);
    }

    function test_refundEscrow_RevertsIfNoEscrow() public {
        Intent memory originalIntent = _createIntent(address(localProver), REWARD_AMOUNT, TOKEN_AMOUNT);
        Intent memory secondaryIntent = _createIntent(address(secondaryProver), REWARD_AMOUNT, TOKEN_AMOUNT);
        bytes32 nonExistentHash = keccak256("nonexistent");

        vm.expectRevert("No escrow found");
        localProver.refundEscrow(nonExistentHash, originalIntent, secondaryIntent);
    }

    function test_refundEscrow_RevertsIfAlreadyReleased() public {
        Intent memory originalIntent = _createIntent(address(localProver), REWARD_AMOUNT, TOKEN_AMOUNT);
        (bytes32 originalIntentHash, ) = _publishAndFundIntent(originalIntent);

        bytes32 secondaryIntentHash = keccak256("secondary");
        bytes32 claimantBytes = bytes32(uint256(uint160(solver)));
        uint64 secondaryDeadline = uint64(block.timestamp + 1000);

        // FlashFulfill
        vm.prank(solver);
        localProver.flashFulfill(
            originalIntentHash,
            originalIntent,
            claimantBytes,
            secondaryIntentHash,
            address(secondaryProver),
            secondaryDeadline
        );

        // Prove secondary intent
        vm.startPrank(address(secondaryProver));
        bytes32[] memory hashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        hashes[0] = secondaryIntentHash;
        claimants[0] = claimantBytes;
        bytes memory encodedProofs = _encodeProofs(hashes, claimants);
        secondaryProver.prove(solver, SECONDARY_CHAIN_ID, encodedProofs, "");
        vm.stopPrank();

        // Release escrow once
        localProver.releaseEscrow(originalIntentHash);

        // Try to refund after release
        Intent memory secondaryIntent = _createIntent(address(secondaryProver), REWARD_AMOUNT, TOKEN_AMOUNT);
        vm.expectRevert("Already released");
        localProver.refundEscrow(originalIntentHash, originalIntent, secondaryIntent);
    }

    function test_refundEscrow_RevertsIfSecondaryNotExpired() public {
        Intent memory originalIntent = _createIntent(address(localProver), REWARD_AMOUNT, TOKEN_AMOUNT);
        (bytes32 originalIntentHash, ) = _publishAndFundIntent(originalIntent);

        Intent memory secondaryIntent = _createIntent(address(secondaryProver), REWARD_AMOUNT, TOKEN_AMOUNT);
        (bytes32 secondaryIntentHash, , ) = portal.getIntentHash(secondaryIntent);
        uint64 secondaryDeadline = uint64(block.timestamp + 1000);

        // FlashFulfill
        vm.prank(solver);
        localProver.flashFulfill(
            originalIntentHash,
            originalIntent,
            bytes32(uint256(uint160(solver))),
            secondaryIntentHash,
            address(secondaryProver),
            secondaryDeadline
        );

        // Try to refund before deadline (should fail)
        vm.expectRevert("Secondary intent not expired");
        localProver.refundEscrow(originalIntentHash, originalIntent, secondaryIntent);
    }

    function test_refundEscrow_SuccessEvenIfSecondaryAlreadyRefunded() public {
        Intent memory originalIntent = _createIntent(address(localProver), REWARD_AMOUNT, TOKEN_AMOUNT);
        (bytes32 originalIntentHash, address originalVault) = _publishAndFundIntent(originalIntent);

        // Create secondary intent
        Intent memory secondaryIntent = _createIntent(
            address(secondaryProver),
            REWARD_AMOUNT / 2,
            TOKEN_AMOUNT / 2
        );
        secondaryIntent.reward.creator = address(localProver);

        (bytes32 secondaryIntentHash, , ) = portal.getIntentHash(secondaryIntent);
        uint64 secondaryDeadline = secondaryIntent.reward.deadline;

        // Pre-fund and publish secondary intent
        token.mint(address(localProver), secondaryIntent.reward.tokens[0].amount);
        vm.startPrank(address(localProver));
        token.approve(address(portal), secondaryIntent.reward.tokens[0].amount);
        vm.deal(address(localProver), secondaryIntent.reward.nativeAmount);
        portal.publishAndFund{value: secondaryIntent.reward.nativeAmount}(secondaryIntent, false);
        vm.stopPrank();

        // FlashFulfill original intent
        vm.prank(solver);
        localProver.flashFulfill(
            originalIntentHash,
            originalIntent,
            bytes32(uint256(uint160(solver))),
            secondaryIntentHash,
            address(secondaryProver),
            secondaryDeadline
        );

        // Fast forward past deadline
        vm.warp(secondaryIntent.reward.deadline + 1);

        // Someone refunds the secondary vault SEPARATELY first
        vm.prank(user);
        portal.refund(
            secondaryIntent.destination,
            keccak256(abi.encode(secondaryIntent.route)),
            secondaryIntent.reward
        );

        // Verify LocalProver received the refund
        assertGt(address(localProver).balance, 0);

        // Now call refundEscrow - should still work even though secondary already refunded
        uint256 vaultBalanceBefore = originalVault.balance;
        vm.prank(user);
        localProver.refundEscrow(originalIntentHash, originalIntent, secondaryIntent);

        // Verify funds transferred to original vault (only the original escrow, not the separately refunded amount)
        assertGt(originalVault.balance, vaultBalanceBefore);

        // Verify escrow marked as released
        LocalProver.EscrowData memory escrow = _getEscrowData(originalIntentHash);
        assertTrue(escrow.released);
    }

    function test_refundEscrow_RevertsIfSecondaryAlreadyProven() public {
        Intent memory originalIntent = _createIntent(address(localProver), REWARD_AMOUNT, TOKEN_AMOUNT);
        (bytes32 originalIntentHash, ) = _publishAndFundIntent(originalIntent);

        Intent memory secondaryIntent = _createIntent(address(secondaryProver), REWARD_AMOUNT, TOKEN_AMOUNT);
        (bytes32 secondaryIntentHash, , ) = portal.getIntentHash(secondaryIntent);
        bytes32 claimantBytes = bytes32(uint256(uint160(solver)));
        uint64 secondaryDeadline = uint64(block.timestamp + 1000);

        // FlashFulfill
        vm.prank(solver);
        localProver.flashFulfill(
            originalIntentHash,
            originalIntent,
            claimantBytes,
            secondaryIntentHash,
            address(secondaryProver),
            secondaryDeadline
        );

        // Prove secondary intent
        vm.startPrank(address(secondaryProver));
        bytes32[] memory hashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        hashes[0] = secondaryIntentHash;
        claimants[0] = claimantBytes;
        bytes memory encodedProofs = _encodeProofs(hashes, claimants);
        secondaryProver.prove(solver, SECONDARY_CHAIN_ID, encodedProofs, "");
        vm.stopPrank();

        // Fast forward past secondary deadline
        vm.warp(secondaryDeadline + 1);

        // Try to refund after secondary is proven (should fail)
        vm.expectRevert("Secondary intent already proven");
        localProver.refundEscrow(originalIntentHash, originalIntent, secondaryIntent);
    }

    // ============ Helper Functions ============

    function _getEscrowData(
        bytes32 intentHash
    ) internal view returns (LocalProver.EscrowData memory) {
        return localProver.getEscrow(intentHash);
    }

    function _encodeProofs(
        bytes32[] memory intentHashes,
        bytes32[] memory claimants
    ) internal view returns (bytes memory) {
        require(intentHashes.length == claimants.length, "Length mismatch");

        bytes memory encodedProofs = new bytes(8 + intentHashes.length * 64);
        uint64 chainId = uint64(block.chainid);

        assembly {
            mstore(add(encodedProofs, 0x20), shl(192, chainId))
        }

        for (uint256 i = 0; i < intentHashes.length; i++) {
            assembly {
                let offset := add(8, mul(i, 64))
                mstore(
                    add(add(encodedProofs, 0x20), offset),
                    mload(add(intentHashes, add(0x20, mul(i, 32))))
                )
                mstore(
                    add(add(encodedProofs, 0x20), add(offset, 32)),
                    mload(add(claimants, add(0x20, mul(i, 32))))
                )
            }
        }

        return encodedProofs;
    }

    // Allow test contract to receive ETH
    receive() external payable {}
}
