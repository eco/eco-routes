// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {LocalProver} from "../../contracts/prover/LocalProver.sol";
import {Portal} from "../../contracts/Portal.sol";
import {TestProver} from "../../contracts/test/TestProver.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";
import {IProver} from "../../contracts/interfaces/IProver.sol";
import {ILocalProver} from "../../contracts/interfaces/ILocalProver.sol";
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
        uint256 nativeFee
    );

    event BothRefunded(
        bytes32 indexed originalIntentHash,
        bytes32 indexed secondaryIntentHash,
        address indexed originalVault
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
        token.mint(creator, TOKEN_AMOUNT * 10);
        token.mint(solver, TOKEN_AMOUNT * 10);
    }

    function _createIntent(
        address proverAddress,
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

    // ============ A. Core IProver Interface Tests ============

    // A1. provenIntents()
    function test_provenIntents_ReturnsClaimantFromPortalForFulfilledIntent() public {
        // Test: Returns claimant from Portal for fulfilled intent
        Intent memory _intent = _createIntent(address(localProver), REWARD_AMOUNT, 0);
        (bytes32 intentHash, ) = _publishAndFundIntent(_intent);

        // Fulfill via Portal directly (normal path)
        vm.startPrank(solver);
        vm.deal(solver, REWARD_AMOUNT);
        portal.fulfill{value: REWARD_AMOUNT}(
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

    function test_provenIntents_ReturnsZeroForUnfulfilledIntent() public {
        // Test: Returns zero address for unfulfilled intent
        Intent memory _intent = _createIntent(address(localProver), REWARD_AMOUNT, 0);
        (bytes32 intentHash, ) = _publishAndFundIntent(_intent);

        // Don't fulfill it
        IProver.ProofData memory proof = localProver.provenIntents(intentHash);
        assertEq(proof.claimant, address(0));
        assertEq(proof.destination, 0);
    }

    // A2. prove()
    function test_prove_IsNoOp() public {
        // Test: prove() is a no-op (doesn't revert)
        localProver.prove{value: 0}(
            address(0),
            0,
            "",
            ""
        );
        // Should not revert
    }

    // A3. challengeIntentProof()
    function test_challengeIntentProof_IsNoOp() public {
        // Test: challengeIntentProof() is a no-op (doesn't revert)
        localProver.challengeIntentProof(0, bytes32(0), bytes32(0));
        // Should not revert
    }

    // A4. getProofType()
    function test_getProofType_ReturnsSameChain() public {
        // Test: Returns "Same chain"
        assertEq(localProver.getProofType(), "Same chain");
    }

    // ============ B. flashFulfill() Tests ============

    // B4. Validation - Reverts
    function test_flashFulfill_RevertsIfClaimantIsZero() public {
        // Test: Reverts if claimant is zero
        Intent memory _intent = _createIntent(address(localProver), REWARD_AMOUNT, 0);
        (bytes32 intentHash, ) = _publishAndFundIntent(_intent);

        vm.prank(solver);
        vm.expectRevert(ILocalProver.InvalidClaimant.selector);
        localProver.flashFulfill(
            intentHash,
            _intent.route,
            _intent.reward,
            bytes32(0)
        );
    }

    function test_flashFulfill_RevertsIfIntentHashDoesntMatch() public {
        // Test: Reverts if intent hash doesn't match
        Intent memory _intent = _createIntent(address(localProver), REWARD_AMOUNT, 0);
        _publishAndFundIntent(_intent);

        bytes32 wrongIntentHash = keccak256("wrong");

        vm.prank(solver);
        vm.expectRevert(ILocalProver.InvalidIntentHash.selector);
        localProver.flashFulfill(
            wrongIntentHash,
            _intent.route,
            _intent.reward,
            bytes32(uint256(uint160(solver)))
        );
    }

    function test_flashFulfill_RevertsIfIntentAlreadyFulfilled() public {
        // Test: Reverts if intent already fulfilled
        Intent memory _intent = _createIntent(address(localProver), REWARD_AMOUNT, 0);
        (bytes32 intentHash, ) = _publishAndFundIntent(_intent);

        // Fulfill via Portal first
        vm.startPrank(solver);
        vm.deal(solver, REWARD_AMOUNT);
        portal.fulfill{value: REWARD_AMOUNT}(
            intentHash,
            _intent.route,
            keccak256(abi.encode(_intent.reward)),
            bytes32(uint256(uint160(solver)))
        );

        // Try flashFulfill
        vm.expectRevert();
        localProver.flashFulfill(
            intentHash,
            _intent.route,
            _intent.reward,
            bytes32(uint256(uint160(solver)))
        );
        vm.stopPrank();
    }

    function test_flashFulfill_RevertsIfIntentExpired() public {
        // Test: Reverts if intent expired
        Intent memory _intent = _createIntent(address(localProver), REWARD_AMOUNT, 0);
        (bytes32 intentHash, ) = _publishAndFundIntent(_intent);

        // Warp past deadline
        vm.warp(_intent.route.deadline + 1);

        vm.prank(solver);
        vm.expectRevert();
        localProver.flashFulfill(
            intentHash,
            _intent.route,
            _intent.reward,
            bytes32(uint256(uint160(solver)))
        );
    }

    function test_flashFulfill_RevertsIfNativeTransferFails() public {
        // Test: Reverts when claimant can't receive native tokens
        // Deploy a contract that rejects ETH transfers
        RejectEth rejecter = new RejectEth();

        Intent memory _intent = _createIntent(address(localProver), REWARD_AMOUNT, 0);
        (bytes32 intentHash, ) = _publishAndFundIntent(_intent);

        bytes32 rejecterClaimant = bytes32(uint256(uint160(address(rejecter))));

        vm.prank(solver);
        vm.expectRevert(ILocalProver.NativeTransferFailed.selector);
        localProver.flashFulfill(
            intentHash,
            _intent.route,
            _intent.reward,
            rejecterClaimant
        );
    }

    // B5. Happy Path with Route Tokens
    function test_flashFulfill_SucceedsWithRouteTokens() public {
        // Test: flashFulfill succeeds with route tokens (stablecoin)
        // Create intent with route tokens that match reward tokens
        TokenAmount[] memory routeTokens = new TokenAmount[](1);
        routeTokens[0] = TokenAmount({
            token: address(token),
            amount: TOKEN_AMOUNT
        });

        TokenAmount[] memory rewardTokens = new TokenAmount[](1);
        rewardTokens[0] = TokenAmount({
            token: address(token),
            amount: TOKEN_AMOUNT
        });

        Call[] memory calls = new Call[](0);

        Route memory route = Route({
            salt: bytes32(uint256(1)),
            deadline: uint64(block.timestamp + 1000),
            portal: address(portal),
            nativeAmount: 0,
            tokens: routeTokens,
            calls: calls
        });

        Reward memory reward = Reward({
            deadline: uint64(block.timestamp + 2000),
            creator: creator,
            prover: address(localProver),
            nativeAmount: 0,
            tokens: rewardTokens
        });

        Intent memory _intent = Intent({
            destination: CHAIN_ID,
            route: route,
            reward: reward
        });

        (bytes32 intentHash, ) = _publishAndFundIntent(_intent);

        bytes32 claimantBytes = bytes32(uint256(uint160(solver)));

        // FlashFulfill should succeed
        vm.prank(solver);
        localProver.flashFulfill(
            intentHash,
            _intent.route,
            _intent.reward,
            claimantBytes
        );

        // Verify tokens transferred to executor
        assertEq(token.balanceOf(address(portal.executor())), TOKEN_AMOUNT);
    }

    function test_flashFulfill_SucceedsWithTokensAndNativeReward() public {
        // Test: flashFulfill correctly transfers both tokens and remaining native to claimant
        // Create intent with route tokens AND reward native amount
        TokenAmount[] memory routeTokens = new TokenAmount[](1);
        routeTokens[0] = TokenAmount({
            token: address(token),
            amount: TOKEN_AMOUNT
        });

        TokenAmount[] memory rewardTokens = new TokenAmount[](1);
        rewardTokens[0] = TokenAmount({
            token: address(token),
            amount: TOKEN_AMOUNT
        });

        Call[] memory calls = new Call[](0);

        Route memory route = Route({
            salt: bytes32(uint256(2)),
            deadline: uint64(block.timestamp + 1000),
            portal: address(portal),
            nativeAmount: 0,
            tokens: routeTokens,
            calls: calls
        });

        Reward memory reward = Reward({
            deadline: uint64(block.timestamp + 2000),
            creator: creator,
            prover: address(localProver),
            nativeAmount: REWARD_AMOUNT,  // Native reward for solver
            tokens: rewardTokens
        });

        Intent memory _intent = Intent({
            destination: CHAIN_ID,
            route: route,
            reward: reward
        });

        (bytes32 intentHash, ) = _publishAndFundIntent(_intent);

        bytes32 claimantBytes = bytes32(uint256(uint160(solver)));

        // Record solver's balance before flashFulfill
        uint256 solverBalanceBefore = solver.balance;

        // FlashFulfill should succeed
        vm.prank(solver);
        localProver.flashFulfill(
            intentHash,
            _intent.route,
            _intent.reward,
            claimantBytes
        );

        // Verify tokens transferred to executor
        assertEq(token.balanceOf(address(portal.executor())), TOKEN_AMOUNT);

        // Verify native transferred to solver (claimant)
        assertEq(solver.balance, solverBalanceBefore + REWARD_AMOUNT);
    }

    // ============ C. refundBoth() Tests ============

    // C1. Happy Path
    function test_refundBoth_SucceedsWhenSecondaryExpiredAndUnproven() public {
        // Test: refundBoth succeeds when secondary expired and unproven
        Intent memory originalIntent = _createIntent(address(localProver), REWARD_AMOUNT, 0);
        (bytes32 originalIntentHash, address originalVault) = _publishAndFundIntent(originalIntent);

        // Create secondary intent with original vault as creator (links to original)
        Intent memory secondaryIntent = _createIntent(address(secondaryProver), REWARD_AMOUNT / 2, 0);
        secondaryIntent.reward.creator = originalVault;
        secondaryIntent.destination = SECONDARY_CHAIN_ID;

        // Publish secondary intent (solver does this)
        vm.startPrank(solver);
        vm.deal(solver, REWARD_AMOUNT);
        portal.publishAndFund{value: secondaryIntent.reward.nativeAmount}(secondaryIntent, false);
        vm.stopPrank();

        // FlashFulfill original (solver does this, but we'll skip for this test)
        // Just warp past secondary deadline
        vm.warp(secondaryIntent.reward.deadline + 1);

        uint256 creatorBalanceBefore = creator.balance;

        // User calls refundBoth
        (bytes32 computedOriginalHash, , ) = portal.getIntentHash(originalIntent);
        (bytes32 computedSecondaryHash, , ) = portal.getIntentHash(secondaryIntent);

        vm.prank(user);
        vm.expectEmit(true, true, true, false);
        emit BothRefunded(computedOriginalHash, computedSecondaryHash, originalVault);

        localProver.refundBoth(originalIntent, secondaryIntent);

        // Verify: creator received both refunds (vault forwards immediately)
        assertEq(creator.balance, creatorBalanceBefore + REWARD_AMOUNT + (REWARD_AMOUNT / 2));
    }

    function test_refundBoth_IsPermissionless() public {
        // Test: refundBoth is permissionless (anyone can call)
        Intent memory originalIntent = _createIntent(address(localProver), REWARD_AMOUNT, 0);
        (bytes32 originalIntentHash, address originalVault) = _publishAndFundIntent(originalIntent);

        Intent memory secondaryIntent = _createIntent(address(secondaryProver), REWARD_AMOUNT / 2, 0);
        secondaryIntent.reward.creator = originalVault;
        secondaryIntent.destination = SECONDARY_CHAIN_ID;

        vm.startPrank(solver);
        vm.deal(solver, REWARD_AMOUNT);
        portal.publishAndFund{value: secondaryIntent.reward.nativeAmount}(secondaryIntent, false);
        vm.stopPrank();

        vm.warp(secondaryIntent.reward.deadline + 1);

        // Random address calls refundBoth
        address randomCaller = makeAddr("random");
        vm.prank(randomCaller);
        localProver.refundBoth(originalIntent, secondaryIntent);

        // Should succeed
    }

    // C2. Validation - Reverts
    function test_refundBoth_RevertsIfSecondaryCreatorIsNotLocalProver() public {
        // Test: Reverts if secondary creator is not LocalProver
        Intent memory originalIntent = _createIntent(address(localProver), REWARD_AMOUNT, 0);
        _publishAndFundIntent(originalIntent);

        Intent memory secondaryIntent = _createIntent(address(secondaryProver), REWARD_AMOUNT / 2, 0);
        // Creator is NOT LocalProver (it's creator by default)
        secondaryIntent.destination = SECONDARY_CHAIN_ID;

        vm.prank(user);
        vm.expectRevert(ILocalProver.InvalidSecondaryCreator.selector);
        localProver.refundBoth(originalIntent, secondaryIntent);
    }

    function test_refundBoth_RevertsIfSecondaryNotExpired() public {
        // Test: Reverts if secondary not expired (validated by Portal)
        Intent memory originalIntent = _createIntent(address(localProver), REWARD_AMOUNT, 0);
        (bytes32 originalIntentHash, address originalVault) = _publishAndFundIntent(originalIntent);

        Intent memory secondaryIntent = _createIntent(address(secondaryProver), REWARD_AMOUNT / 2, 0);
        secondaryIntent.reward.creator = originalVault;
        secondaryIntent.destination = SECONDARY_CHAIN_ID;

        // Publish secondary intent
        vm.deal(solver, REWARD_AMOUNT);
        vm.prank(solver);
        portal.publishAndFund{value: secondaryIntent.reward.nativeAmount}(secondaryIntent, false);

        // Don't warp time - secondary not expired

        vm.prank(user);
        vm.expectRevert(); // Portal reverts with InvalidStatusForRefund
        localProver.refundBoth(originalIntent, secondaryIntent);
    }

    function test_refundBoth_RevertsIfSecondaryAlreadyProven() public {
        // Test: Reverts if secondary already proven
        Intent memory originalIntent = _createIntent(address(localProver), REWARD_AMOUNT, 0);
        (bytes32 originalIntentHash, address originalVault) = _publishAndFundIntent(originalIntent);

        Intent memory secondaryIntent = _createIntent(address(secondaryProver), REWARD_AMOUNT / 2, 0);
        secondaryIntent.reward.creator = originalVault;
        secondaryIntent.destination = SECONDARY_CHAIN_ID;

        vm.startPrank(solver);
        vm.deal(solver, REWARD_AMOUNT);
        (bytes32 secondaryHash, ) = portal.publishAndFund{value: secondaryIntent.reward.nativeAmount}(
            secondaryIntent,
            false
        );
        vm.stopPrank();

        // Prove the secondary intent
        vm.startPrank(address(secondaryProver));
        bytes32[] memory hashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        hashes[0] = secondaryHash;
        claimants[0] = bytes32(uint256(uint160(solver)));
        bytes memory encodedProofs = _encodeProofs(hashes, claimants);
        secondaryProver.prove(solver, SECONDARY_CHAIN_ID, encodedProofs, "");
        vm.stopPrank();

        vm.warp(secondaryIntent.reward.deadline + 1);

        // Try to refund - Portal validates proof exists and reverts
        vm.prank(user);
        vm.expectRevert(); // Portal reverts with IntentNotClaimed
        localProver.refundBoth(originalIntent, secondaryIntent);
    }

    // C3. Security - Attack Prevention
    function test_refundBoth_RevertsWithFakeOriginalIntent() public {
        // Test: Attack scenario - attacker tries to steal secondary funds with fake original intent

        // Setup: Legitimate original and secondary intents
        Intent memory legitimateOriginal = _createIntent(address(localProver), REWARD_AMOUNT, 0);
        (bytes32 legitOriginalHash, address legitOriginalVault) = _publishAndFundIntent(legitimateOriginal);

        // Create secondary intent linked to legitimate original vault
        Intent memory legitimateSecondary = _createIntent(address(secondaryProver), REWARD_AMOUNT / 2, 0);
        legitimateSecondary.reward.creator = legitOriginalVault;  // Links to legitimate vault
        legitimateSecondary.destination = SECONDARY_CHAIN_ID;

        // Solver publishes and funds secondary intent
        vm.deal(solver, REWARD_AMOUNT);
        vm.prank(solver);
        portal.publishAndFund{value: legitimateSecondary.reward.nativeAmount}(legitimateSecondary, false);

        // Attacker creates fake original intent they control
        address attacker = makeAddr("attacker");
        Intent memory fakeOriginal = _createIntent(address(localProver), REWARD_AMOUNT, 0);
        fakeOriginal.reward.creator = attacker;  // Attacker controls this

        // Warp past secondary deadline
        vm.warp(legitimateSecondary.reward.deadline + 1);

        // Attacker tries to steal secondary funds by calling refundBoth with their fake original
        vm.prank(attacker);
        vm.expectRevert(ILocalProver.InvalidSecondaryCreator.selector);
        localProver.refundBoth(fakeOriginal, legitimateSecondary);

        // Attack prevented! ✅
        // The secondary creator (legitOriginalVault) doesn't match fake original vault address
    }

    // ============ Helper Functions ============

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

/**
 * @notice Helper contract that rejects ETH transfers
 * @dev Used to test native transfer failure scenarios
 */
contract RejectEth {
    // No receive() or fallback() - will reject all ETH transfers
}
