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

    function setUp() public {
        creator = makeAddr("creator");
        solver = makeAddr("solver");
        user = makeAddr("user");

        // Set CHAIN_ID to current chain
        CHAIN_ID = uint64(block.chainid);

        // Deploy contracts
        portal = new Portal(address(0));
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
            rewardTokens[0] = TokenAmount({
                token: address(token),
                amount: tokenReward
            });
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
        (intentHash, vault) = portal.publishAndFund{
            value: _intent.reward.nativeAmount
        }(_intent, false);

        vm.stopPrank();
    }

    // ============ A. Core IProver Interface Tests ============

    // A1. provenIntents()
    function test_provenIntents_ReturnsClaimantFromPortalForFulfilledIntent()
        public
    {
        // Test: Returns claimant from Portal for fulfilled intent
        Intent memory _intent = _createIntent(
            address(localProver),
            REWARD_AMOUNT,
            0
        );
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
        Intent memory _intent = _createIntent(
            address(localProver),
            REWARD_AMOUNT,
            0
        );
        (bytes32 intentHash, ) = _publishAndFundIntent(_intent);

        // Don't fulfill it
        IProver.ProofData memory proof = localProver.provenIntents(intentHash);
        assertEq(proof.claimant, address(0));
        assertEq(proof.destination, 0);
    }

    // A2. prove()
    function test_prove_ZeroValueZeroSenderDoesNotRevert() public {
        // Zero value and zero sender both hit the early returns; prove() must
        // not revert. (The name was previously "IsNoOp", but prove() is no
        // longer a pure no-op -- it refunds forwarded value; see the tests below.)
        localProver.prove{value: 0}(address(0), 0, "", "");
    }

    /// @notice A direct prove() carrying value but a zero `sender` cannot refund,
    ///         so it emits ProveRefundFailed rather than silently swallowing the
    ///         ETH. Unreachable via Inbox.prove (sender is msg.sender there), but
    ///         reachable by a direct caller.
    function test_prove_ZeroSenderWithValueEmitsRefundFailed() public {
        uint256 sent = 1 ether;
        vm.deal(address(this), sent);

        vm.expectEmit(true, false, false, true, address(localProver));
        emit ILocalProver.ProveRefundFailed(address(0), sent);

        localProver.prove{value: sent}(address(0), CHAIN_ID, "", "");

        assertEq(
            address(localProver).balance,
            sent,
            "zero-sender value should be retained and signalled, not burned"
        );
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
        Intent memory _intent = _createIntent(
            address(localProver),
            REWARD_AMOUNT,
            0
        );
        _publishAndFundIntent(_intent);

        vm.prank(solver);
        vm.expectRevert(ILocalProver.InvalidClaimant.selector);
        localProver.flashFulfill(_intent.route, _intent.reward, bytes32(0));
    }

    function test_flashFulfill_RevertsIfIntentAlreadyFulfilled() public {
        // Test: Reverts if intent already fulfilled
        Intent memory _intent = _createIntent(
            address(localProver),
            REWARD_AMOUNT,
            0
        );
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
            _intent.route,
            _intent.reward,
            bytes32(uint256(uint160(solver)))
        );
        vm.stopPrank();
    }

    function test_flashFulfill_RevertsIfIntentExpired() public {
        // Test: Reverts if intent expired
        Intent memory _intent = _createIntent(
            address(localProver),
            REWARD_AMOUNT,
            0
        );
        _publishAndFundIntent(_intent);

        // Warp past deadline
        vm.warp(_intent.route.deadline + 1);

        vm.prank(solver);
        vm.expectRevert();
        localProver.flashFulfill(
            _intent.route,
            _intent.reward,
            bytes32(uint256(uint160(solver)))
        );
    }

    function test_flashFulfill_SucceedsEvenIfClaimantRejectsETH() public {
        // Test: Succeeds even when claimant rejects ETH (ETH remains in LocalProver)
        // Deploy a contract that rejects ETH transfers
        RejectEth rejecter = new RejectEth();

        Intent memory _intent = _createIntent(
            address(localProver),
            REWARD_AMOUNT,
            0
        );
        _publishAndFundIntent(_intent);

        bytes32 rejecterClaimant = bytes32(uint256(uint160(address(rejecter))));

        // Should succeed even though rejecter doesn't accept ETH transfers
        vm.prank(solver);
        localProver.flashFulfill(
            _intent.route,
            _intent.reward,
            rejecterClaimant
        );

        // Verify the ETH remains in LocalProver (claimant rejected it)
        assertEq(address(rejecter).balance, 0);
        assertEq(address(localProver).balance, REWARD_AMOUNT);
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

        _publishAndFundIntent(_intent);

        bytes32 claimantBytes = bytes32(uint256(uint160(solver)));

        // FlashFulfill should succeed
        vm.prank(solver);
        localProver.flashFulfill(_intent.route, _intent.reward, claimantBytes);

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
            nativeAmount: REWARD_AMOUNT, // Native reward for solver
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
        localProver.flashFulfill(_intent.route, _intent.reward, claimantBytes);

        // Verify tokens transferred to executor
        assertEq(token.balanceOf(address(portal.executor())), TOKEN_AMOUNT);

        // Verify native transferred to solver (claimant)
        assertEq(solver.balance, solverBalanceBefore + REWARD_AMOUNT);
    }

    function test_flashFulfill_TransfersRewardTokensToSolver() public {
        // Test: Solver receives ERC20 reward tokens, not just native
        // Route uses 500 tokens for execution, reward has 1000 tokens
        // Solver should get the 500 token remainder
        uint256 routeTokenAmount = 500;
        uint256 rewardTokenAmount = 1000;

        TokenAmount[] memory routeTokens = new TokenAmount[](1);
        routeTokens[0] = TokenAmount({
            token: address(token),
            amount: routeTokenAmount
        });

        TokenAmount[] memory rewardTokens = new TokenAmount[](1);
        rewardTokens[0] = TokenAmount({
            token: address(token),
            amount: rewardTokenAmount
        });

        Call[] memory calls = new Call[](0);

        Route memory route = Route({
            salt: bytes32(uint256(4)),
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

        _publishAndFundIntent(_intent);

        bytes32 claimantBytes = bytes32(uint256(uint160(solver)));

        // Record solver's token balance before
        uint256 solverTokenBalanceBefore = token.balanceOf(solver);

        // FlashFulfill should succeed
        vm.prank(solver);
        localProver.flashFulfill(_intent.route, _intent.reward, claimantBytes);

        // Verify route tokens (500) transferred to executor
        assertEq(token.balanceOf(address(portal.executor())), routeTokenAmount);

        // Verify reward tokens (500 remainder) transferred to solver
        assertEq(
            token.balanceOf(solver),
            solverTokenBalanceBefore + (rewardTokenAmount - routeTokenAmount)
        );
    }

    // ============ C. Griefing Attack Tests ============

    function test_griefing_LocalProverSentinel_AllowsRefundAfterDeadline()
        public
    {
        // Test: Attacker calls Portal.fulfill with LocalProver as claimant (Vector 1)
        // Should not permanently brick the intent - refund should work after deadline

        Intent memory _intent = _createIntent(
            address(localProver),
            REWARD_AMOUNT,
            0
        );
        (bytes32 intentHash, ) = _publishAndFundIntent(_intent);

        // Attacker fulfills with LocalProver as claimant (griefing)
        address attacker = makeAddr("attacker");
        vm.startPrank(attacker);
        vm.deal(attacker, REWARD_AMOUNT);
        bytes32 localProverAsBytes32 = bytes32(
            uint256(uint160(address(localProver)))
        );
        portal.fulfill{value: REWARD_AMOUNT}(
            intentHash,
            _intent.route,
            keccak256(abi.encode(_intent.reward)),
            localProverAsBytes32
        );
        vm.stopPrank();

        // provenIntents should return address(0) (not revert)
        IProver.ProofData memory proof = localProver.provenIntents(intentHash);
        assertEq(proof.claimant, address(0));
        assertEq(proof.destination, 0);

        // Honest solver cannot flashFulfill (already fulfilled)
        vm.startPrank(solver);
        vm.expectRevert(); // Portal reverts with IntentAlreadyFulfilled
        localProver.flashFulfill(
            _intent.route,
            _intent.reward,
            bytes32(uint256(uint160(solver)))
        );
        vm.stopPrank();

        // Warp past deadline
        vm.warp(_intent.reward.deadline + 1);

        // Refund should succeed
        uint256 creatorBalanceBefore = creator.balance;
        vm.prank(user);
        portal.refund(
            _intent.destination,
            keccak256(abi.encode(_intent.route)),
            _intent.reward
        );

        // Creator should receive refund
        assertEq(creator.balance, creatorBalanceBefore + REWARD_AMOUNT);
    }

    function test_griefing_NonEVMBytes32_AllowsRefundAfterDeadline() public {
        // Test: Attacker calls Portal.fulfill with non-EVM bytes32 (Vector 2)
        // E.g., a Solana address with non-zero top 12 bytes
        // Should not permanently brick the intent - refund should work after deadline

        Intent memory _intent = _createIntent(
            address(localProver),
            REWARD_AMOUNT,
            0
        );
        (bytes32 intentHash, ) = _publishAndFundIntent(_intent);

        // Attacker fulfills with non-EVM bytes32 (griefing)
        // Top 12 bytes are non-zero (invalid EVM address)
        address attacker = makeAddr("attacker");
        vm.startPrank(attacker);
        vm.deal(attacker, REWARD_AMOUNT);
        bytes32 nonEVMBytes32 = bytes32(uint256(type(uint256).max)); // All 1s
        portal.fulfill{value: REWARD_AMOUNT}(
            intentHash,
            _intent.route,
            keccak256(abi.encode(_intent.reward)),
            nonEVMBytes32
        );
        vm.stopPrank();

        // provenIntents should return address(0) (not revert)
        IProver.ProofData memory proof = localProver.provenIntents(intentHash);
        assertEq(proof.claimant, address(0));
        assertEq(proof.destination, 0);

        // Honest solver cannot flashFulfill (already fulfilled)
        vm.startPrank(solver);
        vm.expectRevert(); // Portal reverts with IntentAlreadyFulfilled
        localProver.flashFulfill(
            _intent.route,
            _intent.reward,
            bytes32(uint256(uint160(solver)))
        );
        vm.stopPrank();

        // Warp past deadline
        vm.warp(_intent.reward.deadline + 1);

        // Refund should succeed
        uint256 creatorBalanceBefore = creator.balance;
        vm.prank(user);
        portal.refund(
            _intent.destination,
            keccak256(abi.encode(_intent.route)),
            _intent.reward
        );

        // Creator should receive refund
        assertEq(creator.balance, creatorBalanceBefore + REWARD_AMOUNT);
    }

    function test_griefing_LocalProverSentinel_BlocksRefundBeforeDeadline()
        public
    {
        // Test: Even with griefing, refund should not work before deadline

        Intent memory _intent = _createIntent(
            address(localProver),
            REWARD_AMOUNT,
            0
        );
        (bytes32 intentHash, ) = _publishAndFundIntent(_intent);

        // Attacker fulfills with LocalProver as claimant (griefing)
        address attacker = makeAddr("attacker");
        vm.startPrank(attacker);
        vm.deal(attacker, REWARD_AMOUNT);
        bytes32 localProverAsBytes32 = bytes32(
            uint256(uint160(address(localProver)))
        );
        portal.fulfill{value: REWARD_AMOUNT}(
            intentHash,
            _intent.route,
            keccak256(abi.encode(_intent.reward)),
            localProverAsBytes32
        );
        vm.stopPrank();

        // Try to refund before deadline - should fail
        vm.prank(user);
        vm.expectRevert(); // Portal reverts with InvalidStatusForRefund
        portal.refund(
            _intent.destination,
            keccak256(abi.encode(_intent.route)),
            _intent.reward
        );
    }

    function test_griefing_WithTokenReward_AllowsRefundAfterDeadline() public {
        // Test: Griefing with token rewards - refund should recover both native and tokens

        Intent memory _intent = _createIntent(
            address(localProver),
            REWARD_AMOUNT,
            TOKEN_AMOUNT
        );
        (bytes32 intentHash, ) = _publishAndFundIntent(_intent);

        // Attacker fulfills with LocalProver as claimant (griefing)
        address attacker = makeAddr("attacker");
        vm.startPrank(attacker);
        vm.deal(attacker, REWARD_AMOUNT);
        bytes32 localProverAsBytes32 = bytes32(
            uint256(uint160(address(localProver)))
        );
        portal.fulfill{value: REWARD_AMOUNT}(
            intentHash,
            _intent.route,
            keccak256(abi.encode(_intent.reward)),
            localProverAsBytes32
        );
        vm.stopPrank();

        // Warp past deadline
        vm.warp(_intent.reward.deadline + 1);

        // Refund should succeed
        uint256 creatorNativeBalanceBefore = creator.balance;
        uint256 creatorTokenBalanceBefore = token.balanceOf(creator);

        vm.prank(user);
        portal.refund(
            _intent.destination,
            keccak256(abi.encode(_intent.route)),
            _intent.reward
        );

        // Creator should receive both native and token refund
        assertEq(creator.balance, creatorNativeBalanceBefore + REWARD_AMOUNT);
        assertEq(
            token.balanceOf(creator),
            creatorTokenBalanceBefore + TOKEN_AMOUNT
        );
    }

    function test_flashFulfill_RevertsWithLocalProverAsClaimant() public {
        // Test that flashFulfill reverts when claimant is set to LocalProver address
        // This prevents fund stranding attacks where funds would be stuck in LocalProver

        Intent memory intent = _createIntent(
            address(localProver),
            REWARD_AMOUNT,
            0
        );
        _publishAndFundIntent(intent);

        address attacker = makeAddr("attacker");
        bytes32 localProverAsClaimant = bytes32(
            uint256(uint160(address(localProver)))
        );

        vm.startPrank(attacker);
        vm.expectRevert(ILocalProver.InvalidClaimant.selector);
        localProver.flashFulfill(
            intent.route,
            intent.reward,
            localProverAsClaimant // Should revert - LocalProver cannot be claimant
        );
        vm.stopPrank();
    }

    function test_flashFulfill_RevertsWithWrongProver() public {
        // Test that flashFulfill reverts when intent uses a different prover
        // flashFulfill is LocalProver-specific and should only work with LocalProver intents

        Intent memory intent = _createIntent(
            address(secondaryProver),
            REWARD_AMOUNT,
            0
        );
        _publishAndFundIntent(intent);

        bytes32 claimantBytes = bytes32(uint256(uint160(solver)));

        vm.startPrank(solver);
        vm.expectRevert(ILocalProver.InvalidProver.selector);
        localProver.flashFulfill(
            intent.route,
            intent.reward,
            claimantBytes // Should revert - intent uses secondaryProver, not localProver
        );
        vm.stopPrank();
    }

    function test_flashFulfill_SucceedsWithDuplicateRouteTokens() public {
        // Test: flashFulfill correctly handles duplicate tokens in route.tokens[]
        // This verifies that safeIncreaseAllowance accumulates approvals correctly

        // Create route with same token appearing twice
        TokenAmount[] memory routeTokens = new TokenAmount[](2);
        routeTokens[0] = TokenAmount({
            token: address(token),
            amount: 300 // First occurrence: 300 tokens
        });
        routeTokens[1] = TokenAmount({
            token: address(token),
            amount: 700 // Second occurrence: 700 tokens (total: 1000)
        });

        // Reward contains enough tokens to cover the route
        TokenAmount[] memory rewardTokens = new TokenAmount[](1);
        rewardTokens[0] = TokenAmount({
            token: address(token),
            amount: TOKEN_AMOUNT // 1000 tokens total
        });

        Call[] memory calls = new Call[](0);

        Route memory route = Route({
            salt: bytes32(uint256(1)),
            deadline: uint64(block.timestamp + 1000),
            portal: address(portal),
            nativeAmount: 0,
            tokens: routeTokens, // Duplicate tokens here
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

        _publishAndFundIntent(_intent);

        bytes32 claimantBytes = bytes32(uint256(uint160(solver)));

        uint256 solverBalanceBefore = token.balanceOf(solver);

        // FlashFulfill should succeed with duplicate tokens
        vm.prank(solver);
        localProver.flashFulfill(_intent.route, _intent.reward, claimantBytes);

        // Verify all tokens (300 + 700 = 1000) transferred to executor
        assertEq(token.balanceOf(address(portal.executor())), TOKEN_AMOUNT);

        // Solver should receive no tokens since all were consumed by route
        assertEq(token.balanceOf(solver), solverBalanceBefore);
    }

    // ============ PAR-403: prove() must not retain forwarded native ============

    /**
     * @notice Overpaid ETH routed through Inbox.prove must return to the payer.
     * @dev Inbox.prove forwards `address(this).balance` to the prover. LocalProver.prove
     *      is payable with an empty body, so before the fix the excess silently stuck in
     *      LocalProver instead of returning to the solver who paid it.
     */
    function test_prove_RefundsOverpaidNativeToSender() public {
        Intent memory _intent = _createIntent(
            address(localProver),
            REWARD_AMOUNT,
            0
        );
        (bytes32 intentHash, ) = _publishAndFundIntent(_intent);

        uint256 overpay = 1 ether;
        uint256 solverBalanceBefore = solver.balance;

        vm.prank(solver);
        portal.fulfillAndProve{value: overpay}(
            intentHash,
            _intent.route,
            keccak256(abi.encode(_intent.reward)),
            bytes32(uint256(uint160(solver))),
            address(localProver),
            CHAIN_ID,
            ""
        );

        // route.nativeAmount is 0, so the entire overpayment is excess
        assertEq(
            address(localProver).balance,
            0,
            "LocalProver retained the solver's overpayment"
        );
        assertEq(
            address(portal).balance,
            0,
            "Portal retained the solver's overpayment"
        );
        assertEq(
            solver.balance,
            solverBalanceBefore,
            "solver was not made whole"
        );
    }

    /**
     * @notice ETH forwarded to prove() must not be handed to an unrelated third party.
     * @dev flashFulfill pays out `address(this).balance`, so any balance LocalProver
     *      retains from a previous prove() call is paid to the *next* flashFulfill
     *      caller's claimant -- a different intent, a different party.
     */
    function test_prove_OverpaidNativeIsNotPaidToNextFlashFulfillClaimant()
        public
    {
        // --- Intent A: fulfilled via fulfillAndProve with an overpayment ---
        Intent memory intentA = _createIntent(
            address(localProver),
            REWARD_AMOUNT,
            0
        );
        (bytes32 intentHashA, ) = _publishAndFundIntent(intentA);

        uint256 overpay = 3 ether;

        vm.prank(solver);
        portal.fulfillAndProve{value: overpay}(
            intentHashA,
            intentA.route,
            keccak256(abi.encode(intentA.reward)),
            bytes32(uint256(uint160(solver))),
            address(localProver),
            CHAIN_ID,
            ""
        );

        // --- Intent B: an unrelated intent, flash-fulfilled by an unrelated party ---
        Intent memory intentB = _createIntent(
            address(localProver),
            REWARD_AMOUNT,
            0
        );
        intentB.route.salt = bytes32(uint256(2));
        _publishAndFundIntent(intentB);

        address attacker = makeAddr("attacker");
        uint256 attackerBalanceBefore = attacker.balance;

        // Linchpin of the repro: flashFulfill forwards `address(this).balance`
        // into fulfill and pays the remainder to the claimant, so it inherits
        // anything stranded here. The fix refunded intent A's overpayment during
        // its prove(), leaving nothing to sweep. On unfixed code this is the
        // 3-ether overpay, and the delta assertion below would catch the attacker
        // inheriting it -- so the leak is pinned from both ends.
        assertEq(
            address(localProver).balance,
            0,
            "intent A's overpayment remained stranded in LocalProver"
        );

        vm.prank(attacker);
        localProver.flashFulfill(
            intentB.route,
            intentB.reward,
            bytes32(uint256(uint160(attacker)))
        );

        // The attacker is entitled to intent B's reward and nothing more
        assertEq(
            attacker.balance - attackerBalanceBefore,
            REWARD_AMOUNT,
            "unrelated flashFulfill caller inherited the solver's overpayment"
        );
    }

    /**
     * @notice A refund recipient that rejects ETH must not be able to brick proving.
     * @dev Guards the choice of refund primitive: a reverting send (e.g. `.transfer`)
     *      would make fulfillAndProve unusable for contract solvers without a payable
     *      receive. The ETH stays in LocalProver in that case, which is no worse than
     *      the pre-fix behaviour, but the transaction must still succeed.
     *
     *      This is a regression guard rather than a bug reproduction: it also passes
     *      against unfixed main, where the empty prove() body silently retains the ETH.
     */
    function test_prove_DoesNotRevertWhenRefundRecipientRejectsETH() public {
        RejectingProveCaller caller = new RejectingProveCaller();

        Intent memory _intent = _createIntent(
            address(localProver),
            REWARD_AMOUNT,
            0
        );
        (bytes32 intentHash, ) = _publishAndFundIntent(_intent);

        // Fulfill first so prove() passes the IntentNotFulfilled check
        vm.prank(solver);
        portal.fulfill(
            intentHash,
            _intent.route,
            keccak256(abi.encode(_intent.reward)),
            bytes32(uint256(uint160(solver)))
        );

        bytes32[] memory intentHashes = new bytes32[](1);
        intentHashes[0] = intentHash;

        uint256 sent = 1 ether;
        vm.deal(address(this), sent);

        // The swallowed failure is only observable via the event, so assert it
        // fires with the rejecting recipient and the retained amount.
        vm.expectEmit(true, false, false, true, address(localProver));
        emit ILocalProver.ProveRefundFailed(address(caller), sent);

        // Must not revert even though the caller cannot receive the refund
        caller.callProve{value: sent}(
            portal,
            address(localProver),
            CHAIN_ID,
            intentHashes
        );

        // Refund failed silently; the ETH is retained rather than burned or reverted
        assertEq(
            address(caller).balance,
            0,
            "refund unexpectedly landed on the rejecting caller"
        );
        assertEq(
            address(localProver).balance,
            sent,
            "ETH was burned instead of retained"
        );
    }

    /**
     * @notice A griefing recipient must not be able to revert prove() by burning gas.
     * @dev The blocking invariant: an unbounded refund call lets the recipient consume
     *      ~63/64 of the gas, leaving too little for the ProveRefundFailed emit, which
     *      then OOGs and reverts. The bounded stipend caps the recipient so the emit
     *      always fits. Calling prove() with a constrained gas budget makes this
     *      concrete: it succeeds here, and fails if the `gas:` cap is removed.
     */
    function test_prove_GasBurningRecipientDoesNotRevertProve() public {
        GasBurningRefundRecipient burner = new GasBurningRefundRecipient();

        uint256 sent = 1 ether;
        vm.deal(address(this), sent);

        vm.expectEmit(true, false, false, true, address(localProver));
        emit ILocalProver.ProveRefundFailed(address(burner), sent);

        // Constrained budget. Empirically prove() needs ~35k with the stipend
        // in place, but an unbounded call reverts at any budget below ~110k
        // (the 63/64 drain starves the emit). 80k sits between: it passes with
        // the cap and fails without it.
        (bool ok, ) = address(localProver).call{value: sent, gas: 80000}(
            abi.encodeCall(
                LocalProver.prove,
                (address(burner), CHAIN_ID, "", "")
            )
        );

        assertTrue(ok, "prove() reverted: gas cap did not protect the emit");
        assertEq(
            address(localProver).balance,
            sent,
            "value should be retained when the refund cannot be delivered"
        );
    }

    /**
     * @notice prove() must only ever return the value it was sent, never pre-existing balance.
     * @dev LocalProver can legitimately hold ETH (e.g. a claimant that rejected a
     *      flashFulfill payout). A refund keyed off `address(this).balance` instead of
     *      `msg.value` would let anyone drain it with a dust-valued prove() call.
     *
     *      This is a design guard, not a bug reproduction: on unfixed main it fails as
     *      `999999999999999999 != 1000000000000000000` -- the dust caller is down the
     *      1 wei it sent, never up a drained balance -- so the bug it guards against was
     *      never actually present, unlike the two overpayment-leak repros above.
     */
    function test_prove_DoesNotDrainPreExistingBalance() public {
        // Strand ETH in LocalProver via a claimant that rejects the payout
        RejectEth rejecter = new RejectEth();
        Intent memory strandedIntent = _createIntent(
            address(localProver),
            REWARD_AMOUNT,
            0
        );
        _publishAndFundIntent(strandedIntent);

        vm.prank(solver);
        localProver.flashFulfill(
            strandedIntent.route,
            strandedIntent.reward,
            bytes32(uint256(uint160(address(rejecter))))
        );
        assertEq(address(localProver).balance, REWARD_AMOUNT);

        // A direct dust-valued prove() must return only the dust
        address attacker = makeAddr("attacker2");
        vm.deal(attacker, 1 ether);
        uint256 attackerBalanceBefore = attacker.balance;

        vm.prank(attacker);
        localProver.prove{value: 1 wei}(attacker, CHAIN_ID, "", "");

        assertEq(
            attacker.balance,
            attackerBalanceBefore,
            "attacker extracted pre-existing LocalProver balance"
        );
        assertEq(
            address(localProver).balance,
            REWARD_AMOUNT,
            "pre-existing balance was drained"
        );
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

/**
 * @notice Helper whose receive() burns far more gas than the refund stipend.
 * @dev Under an unbounded refund call this recipient would consume ~63/64 of
 *      prove()'s gas (EIP-150), starving the trailing ProveRefundFailed emit and
 *      reverting the whole call. The bounded stipend must keep the emit
 *      affordable, so it is the regression guard for that invariant.
 */
contract GasBurningRefundRecipient {
    receive() external payable {
        // Burn well past any plausible forwarded gas so the refund call always
        // fails on out-of-gas rather than succeeding.
        for (uint256 i = 0; i < 200000; ++i) {
            assembly {
                mstore(0x0, i)
            }
        }
    }
}

/**
 * @notice Helper contract that calls Portal.prove but cannot receive ETH
 * @dev Used to verify a failed refund does not revert the proving transaction
 */
contract RejectingProveCaller {
    function callProve(
        Portal portal,
        address prover,
        uint64 sourceChainDomainID,
        bytes32[] memory intentHashes
    ) external payable {
        portal.prove{value: msg.value}(
            prover,
            sourceChainDomainID,
            intentHashes,
            ""
        );
    }
    // No receive() or fallback() - will reject the refund
}
