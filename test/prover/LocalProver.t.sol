// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {LocalPolicy} from "../../contracts/prover/LocalPolicy.sol";
import {Portal} from "../../contracts/Portal.sol";
import {TestPolicy} from "../../contracts/test/TestPolicy.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";
import {IPolicy} from "../../contracts/interfaces/IPolicy.sol";
import {ILocalPolicy} from "../../contracts/interfaces/ILocalPolicy.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {Intent, Route, Reward, RewardToken, TokenAmount, IntentLib} from "../../contracts/types/Intent.sol";
import {Call} from "../../contracts/interfaces/IRuntime.sol";
import {MulticallRuntime} from "../../contracts/runtime/MulticallRuntime.sol";

contract LocalProverTest is Test {
    LocalPolicy internal localProver;
    Portal internal portal;
    TestPolicy internal secondaryProver;
    TestERC20 internal token;
    MulticallRuntime internal multicallRuntime;

    address internal keeper;
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
        keeper = makeAddr("keeper");
        solver = makeAddr("solver");
        user = makeAddr("user");

        // Set CHAIN_ID to current chain
        CHAIN_ID = uint64(block.chainid);

        // Deploy contracts
        portal = new Portal();
        localProver = new LocalPolicy(address(portal));
        secondaryProver = new TestPolicy(address(portal));
        token = new TestERC20("Test Token", "TEST");
        multicallRuntime = new MulticallRuntime();

        // Fund accounts
        vm.deal(keeper, INITIAL_BALANCE);
        vm.deal(solver, INITIAL_BALANCE);
        vm.deal(user, INITIAL_BALANCE);

        // Mint tokens
        token.mint(keeper, TOKEN_AMOUNT * 10);
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
            keeper: keeper,
            runtime: address(multicallRuntime),
            payload: abi.encode(calls),
            minTokens: routeTokens
        });

        // Reward legs: an optional ERC20 leg then an optional native (address(0)) leg (both flat).
        uint256 legCount = (tokenReward > 0 ? 1 : 0) + (nativeReward > 0 ? 1 : 0);
        RewardToken[] memory rewardTokens = new RewardToken[](legCount);
        uint256 idx = 0;
        if (tokenReward > 0) {
            rewardTokens[idx++] = RewardToken({
                token: address(token),
                rate: 0,
                flat: tokenReward
            });
        }
        if (nativeReward > 0) {
            rewardTokens[idx] = RewardToken({
                token: address(0),
                rate: 0,
                flat: nativeReward
            });
        }

        Reward memory reward = Reward({
            deadline: uint64(block.timestamp + 2000),
            keeper: keeper,
            prover: proverAddress,
            tokens: rewardTokens,
            hooks: ""
        });

        return
            Intent({
                source: CHAIN_ID,
                destination: CHAIN_ID,
                route: route,
                reward: reward
            });
    }

    function _publishAndFundIntent(
        Intent memory _intent
    ) internal returns (bytes32 intentHash, address account) {
        vm.startPrank(keeper);

        // Approve token legs (flat) and total the native (address(0)) legs to fund with value.
        uint256 nativeValue = 0;
        for (uint256 i = 0; i < _intent.reward.tokens.length; ++i) {
            if (_intent.reward.tokens[i].token == address(0)) {
                nativeValue += _intent.reward.tokens[i].flat;
            } else {
                token.approve(address(portal), _intent.reward.tokens[i].flat);
            }
        }

        // Publish and fund
        (intentHash, account) = portal.publishAndFund{value: nativeValue}(
            _intent,
            false
        );

        vm.stopPrank();
    }

    // ============ A. Core IPolicy Interface Tests ============

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
            _intent.source,
            _intent.destination,
            _intent.route,
            _intent.reward,
            bytes32(uint256(uint160(solver))),
            new uint256[](0),
            address(localProver)
        );
        vm.stopPrank();

        // Should record the hash-only fulfillment fact for the solver on this chain
        IPolicy.ProofData memory proof = localProver.provenIntents(intentHash);
        assertEq(
            proof.fulfillmentHash,
            IntentLib.fulfillmentHash(
                intentHash,
                bytes32(uint256(uint160(solver))),
                new uint256[](0)
            )
        );
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
        IPolicy.ProofData memory proof = localProver.provenIntents(intentHash);
        assertEq(proof.fulfillmentHash, bytes32(0));
        assertEq(proof.destination, 0);
    }

    // A2. prove()
    function test_prove_IsNoOp() public {
        // Test: prove() is a no-op (doesn't revert)
        localProver.prove{value: 0}(address(0), 0, new bytes32[](0), "");
        // Should not revert
    }

    // A3. challengeIntentProof()
    function test_challengeIntentProof_IsNoOp() public {
        // Test: challengeIntentProof() is a no-op (doesn't revert)
        localProver.challengeIntentProof(0, 0, bytes32(0), bytes32(0));
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
        vm.expectRevert(ILocalPolicy.InvalidClaimant.selector);
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
            _intent.source,
            _intent.destination,
            _intent.route,
            _intent.reward,
            bytes32(uint256(uint160(solver))),
            new uint256[](0),
            address(localProver)
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
        // Test: Succeeds even when the claimant rejects ETH. In v3 the settle sweeps the un-received
        // native reward to the keeper (funds conserved, not stranded).
        RejectEth rejecter = new RejectEth();

        Intent memory _intent = _createIntent(
            address(localProver),
            REWARD_AMOUNT,
            0
        );
        _publishAndFundIntent(_intent);

        bytes32 rejecterClaimant = bytes32(uint256(uint160(address(rejecter))));

        uint256 keeperBefore = keeper.balance;

        // Should succeed even though rejecter doesn't accept ETH transfers
        vm.prank(solver);
        localProver.flashFulfill(
            _intent.route,
            _intent.reward,
            rejecterClaimant
        );

        // The rejecter received nothing; the native reward swept to the keeper; nothing stuck anywhere.
        assertEq(address(rejecter).balance, 0);
        assertEq(keeper.balance, keeperBefore + REWARD_AMOUNT);
        assertEq(address(localProver).balance, 0);
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

        RewardToken[] memory rewardTokens = new RewardToken[](1);
        rewardTokens[0] = RewardToken({
            token: address(token),
            rate: 0,
            flat: TOKEN_AMOUNT
        });

        Call[] memory calls = new Call[](0);

        Route memory route = Route({
            salt: bytes32(uint256(1)),
            deadline: uint64(block.timestamp + 1000),
            portal: address(portal),
            keeper: keeper,
            runtime: address(multicallRuntime),
            payload: abi.encode(calls),
            minTokens: routeTokens
        });

        Reward memory reward = Reward({
            deadline: uint64(block.timestamp + 2000),
            keeper: keeper,
            prover: address(localProver),
            tokens: rewardTokens,
            hooks: ""
        });

        Intent memory _intent = Intent({
            source: CHAIN_ID,
            destination: CHAIN_ID,
            route: route,
            reward: reward
        });

        _publishAndFundIntent(_intent);

        bytes32 claimantBytes = bytes32(uint256(uint160(solver)));

        uint256 keeperBalanceBefore = token.balanceOf(keeper);

        // The solver now supplies the route capital (v3 flashFulfill fulfills then settles).
        vm.prank(solver);
        token.approve(address(localProver), TOKEN_AMOUNT);

        vm.prank(solver);
        localProver.flashFulfill(_intent.route, _intent.reward, claimantBytes);

        // The route has no calls, so the provided TOKEN_AMOUNT is unconsumed and the Portal moves it to
        // the intent's Account (leftover stays with the intent); the executor ends drained. flashFulfill
        // then settles: the account pays the claimant its flat reward (TOKEN_AMOUNT) and sweeps the residual
        // (the unconsumed TOKEN_AMOUNT) to the keeper, so the keeper nets +TOKEN_AMOUNT.
        assertEq(token.balanceOf(portal.intentAccountAddress(_intent)), 0);
        assertEq(
            token.balanceOf(keeper),
            keeperBalanceBefore + TOKEN_AMOUNT
        );
    }

    function test_flashFulfill_SucceedsWithTokensAndNativeReward() public {
        // Test: flashFulfill correctly transfers both tokens and remaining native to claimant
        // Create intent with route tokens AND reward native amount
        TokenAmount[] memory routeTokens = new TokenAmount[](1);
        routeTokens[0] = TokenAmount({
            token: address(token),
            amount: TOKEN_AMOUNT
        });

        RewardToken[] memory rewardTokens = new RewardToken[](2);
        rewardTokens[0] = RewardToken({
            token: address(token),
            rate: 0,
            flat: TOKEN_AMOUNT
        });
        rewardTokens[1] = RewardToken({
            token: address(0),
            rate: 0,
            flat: REWARD_AMOUNT // Native reward for solver
        });

        Call[] memory calls = new Call[](0);

        Route memory route = Route({
            salt: bytes32(uint256(2)),
            deadline: uint64(block.timestamp + 1000),
            portal: address(portal),
            keeper: keeper,
            runtime: address(multicallRuntime),
            payload: abi.encode(calls),
            minTokens: routeTokens
        });

        Reward memory reward = Reward({
            deadline: uint64(block.timestamp + 2000),
            keeper: keeper,
            prover: address(localProver),
            tokens: rewardTokens,
            hooks: ""
        });

        Intent memory _intent = Intent({
            source: CHAIN_ID,
            destination: CHAIN_ID,
            route: route,
            reward: reward
        });

        _publishAndFundIntent(_intent);

        bytes32 claimantBytes = bytes32(uint256(uint160(solver)));

        // Record solver's balance before flashFulfill
        uint256 solverBalanceBefore = solver.balance;
        uint256 keeperTokenBefore = token.balanceOf(keeper);

        // Solver supplies the route capital.
        vm.prank(solver);
        token.approve(address(localProver), TOKEN_AMOUNT);

        // FlashFulfill should succeed
        vm.prank(solver);
        localProver.flashFulfill(_intent.route, _intent.reward, claimantBytes);

        // The route has no calls, so the provided token input is unconsumed and moved to the intent's
        // Account; settle then pays the claimant its flat token reward and sweeps the residual (the
        // unconsumed TOKEN_AMOUNT) to the keeper. The executor ends drained.
        assertEq(token.balanceOf(portal.intentAccountAddress(_intent)), 0);
        assertEq(token.balanceOf(keeper), keeperTokenBefore + TOKEN_AMOUNT);

        // Verify native reward transferred to solver (claimant)
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

        RewardToken[] memory rewardTokens = new RewardToken[](1);
        rewardTokens[0] = RewardToken({
            token: address(token),
            rate: 0,
            flat: rewardTokenAmount
        });

        Call[] memory calls = new Call[](0);

        Route memory route = Route({
            salt: bytes32(uint256(4)),
            deadline: uint64(block.timestamp + 1000),
            portal: address(portal),
            keeper: keeper,
            runtime: address(multicallRuntime),
            payload: abi.encode(calls),
            minTokens: routeTokens
        });

        Reward memory reward = Reward({
            deadline: uint64(block.timestamp + 2000),
            keeper: keeper,
            prover: address(localProver),
            tokens: rewardTokens,
            hooks: ""
        });

        Intent memory _intent = Intent({
            source: CHAIN_ID,
            destination: CHAIN_ID,
            route: route,
            reward: reward
        });

        _publishAndFundIntent(_intent);

        bytes32 claimantBytes = bytes32(uint256(uint160(solver)));

        // Record solver's token balance before
        uint256 solverTokenBalanceBefore = token.balanceOf(solver);
        uint256 keeperTokenBefore = token.balanceOf(keeper);

        // Solver supplies the route capital (routeTokenAmount).
        vm.prank(solver);
        token.approve(address(localProver), routeTokenAmount);

        // FlashFulfill should succeed
        vm.prank(solver);
        localProver.flashFulfill(_intent.route, _intent.reward, claimantBytes);

        // The route has no calls, so the provided route input (500) is unconsumed and moved to the
        // intent's Account; settle then pays the claimant its flat reward (1000) and sweeps the residual
        // (the unconsumed 500) to the keeper. The executor ends drained.
        assertEq(token.balanceOf(portal.intentAccountAddress(_intent)), 0);
        assertEq(token.balanceOf(keeper), keeperTokenBefore + routeTokenAmount);

        // Verify the solver nets the reward remainder (reward 1000 - provided 500 = +500)
        assertEq(
            token.balanceOf(solver),
            solverTokenBalanceBefore + (rewardTokenAmount - routeTokenAmount)
        );
    }

    // ============ C. Griefing Attack Tests ============

    function test_griefing_LocalProverSentinel_AllowsRefundAfterDeadline()
        public
    {
        // Test: Attacker calls Portal.fulfill with LocalPolicy as claimant (Vector 1)
        // Should not permanently brick the intent - refund should work after deadline

        Intent memory _intent = _createIntent(
            address(localProver),
            REWARD_AMOUNT,
            0
        );
        (bytes32 intentHash, ) = _publishAndFundIntent(_intent);

        // Attacker fulfills with LocalPolicy as claimant (griefing)
        address attacker = makeAddr("attacker");
        vm.startPrank(attacker);
        vm.deal(attacker, REWARD_AMOUNT);
        bytes32 localProverAsBytes32 = bytes32(
            uint256(uint160(address(localProver)))
        );
        portal.fulfill{value: REWARD_AMOUNT}(
            _intent.source,
            _intent.destination,
            _intent.route,
            _intent.reward,
            localProverAsBytes32,
            new uint256[](0),
            address(localProver)
        );
        vm.stopPrank();

        // v3 hash-only: the fulfillment IS recorded (no claimant-sentinel scrub). What prevents a
        // griefer from permanently locking the keeper's funds is the anti-lock refund after the
        // deadline, not a zeroed proof.
        IPolicy.ProofData memory proof = localProver.provenIntents(intentHash);
        assertTrue(proof.fulfillmentHash != bytes32(0));
        assertEq(proof.destination, CHAIN_ID);

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

        // Refund should succeed (anti-lock)
        uint256 keeperBalanceBefore = keeper.balance;
        vm.prank(user);
        portal.refund(
            _intent.source,
            _intent.destination,
            keccak256(abi.encode(_intent.route)),
            _intent.reward
        );

        // Keeper should receive refund
        assertEq(keeper.balance, keeperBalanceBefore + REWARD_AMOUNT);
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
            _intent.source,
            _intent.destination,
            _intent.route,
            _intent.reward,
            nonEVMBytes32,
            new uint256[](0),
            address(localProver)
        );
        vm.stopPrank();

        // v3 hash-only: the fulfillment IS recorded (a non-EVM claimant is committed inside the hash;
        // no scrub). Settlement to that claimant would fail (invalid EVM address), so the anti-lock
        // refund after the deadline is what keeps the keeper's funds recoverable.
        IPolicy.ProofData memory proof = localProver.provenIntents(intentHash);
        assertTrue(proof.fulfillmentHash != bytes32(0));
        assertEq(proof.destination, CHAIN_ID);

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

        // Refund should succeed (anti-lock)
        uint256 keeperBalanceBefore = keeper.balance;
        vm.prank(user);
        portal.refund(
            _intent.source,
            _intent.destination,
            keccak256(abi.encode(_intent.route)),
            _intent.reward
        );

        // Keeper should receive refund
        assertEq(keeper.balance, keeperBalanceBefore + REWARD_AMOUNT);
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

        // Attacker fulfills with LocalPolicy as claimant (griefing)
        address attacker = makeAddr("attacker");
        vm.startPrank(attacker);
        vm.deal(attacker, REWARD_AMOUNT);
        bytes32 localProverAsBytes32 = bytes32(
            uint256(uint160(address(localProver)))
        );
        portal.fulfill{value: REWARD_AMOUNT}(
            _intent.source,
            _intent.destination,
            _intent.route,
            _intent.reward,
            localProverAsBytes32,
            new uint256[](0),
            address(localProver)
        );
        vm.stopPrank();

        // Try to refund before deadline - should fail
        vm.prank(user);
        vm.expectRevert(); // Portal reverts with InvalidStatusForRefund
        portal.refund(
            _intent.source,
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

        // Attacker fulfills with LocalPolicy as claimant (griefing)
        address attacker = makeAddr("attacker");
        vm.startPrank(attacker);
        vm.deal(attacker, REWARD_AMOUNT);
        bytes32 localProverAsBytes32 = bytes32(
            uint256(uint160(address(localProver)))
        );
        portal.fulfill{value: REWARD_AMOUNT}(
            _intent.source,
            _intent.destination,
            _intent.route,
            _intent.reward,
            localProverAsBytes32,
            new uint256[](0),
            address(localProver)
        );
        vm.stopPrank();

        // Warp past deadline
        vm.warp(_intent.reward.deadline + 1);

        // Refund should succeed
        uint256 keeperNativeBalanceBefore = keeper.balance;
        uint256 keeperTokenBalanceBefore = token.balanceOf(keeper);

        vm.prank(user);
        portal.refund(
            _intent.source,
            _intent.destination,
            keccak256(abi.encode(_intent.route)),
            _intent.reward
        );

        // Keeper should receive both native and token refund
        assertEq(keeper.balance, keeperNativeBalanceBefore + REWARD_AMOUNT);
        assertEq(
            token.balanceOf(keeper),
            keeperTokenBalanceBefore + TOKEN_AMOUNT
        );
    }

    function test_flashFulfill_RevertsWithLocalProverAsClaimant() public {
        // Test that flashFulfill reverts when claimant is set to LocalPolicy address
        // This prevents fund stranding attacks where funds would be stuck in LocalPolicy

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
        vm.expectRevert(ILocalPolicy.InvalidClaimant.selector);
        localProver.flashFulfill(
            intent.route,
            intent.reward,
            localProverAsClaimant // Should revert - LocalPolicy cannot be claimant
        );
        vm.stopPrank();
    }

    function test_flashFulfill_RevertsWithWrongProver() public {
        // Test that flashFulfill reverts when intent uses a different prover
        // flashFulfill is LocalPolicy-specific and should only work with LocalPolicy intents

        Intent memory intent = _createIntent(
            address(secondaryProver),
            REWARD_AMOUNT,
            0
        );
        _publishAndFundIntent(intent);

        bytes32 claimantBytes = bytes32(uint256(uint160(solver)));

        vm.startPrank(solver);
        vm.expectRevert(ILocalPolicy.InvalidProver.selector);
        localProver.flashFulfill(
            intent.route,
            intent.reward,
            claimantBytes // Should revert - intent uses secondaryProver, not localProver
        );
        vm.stopPrank();
    }

    function test_flashFulfill_RevertsWithDuplicateMinTokensLegs() public {
        // TODO(minTokens): v2 verified that duplicate tokens in route.tokens[] accumulated approvals
        // correctly (safeIncreaseAllowance). Under the v3 input-floor model `route.minTokens` MUST be
        // STRICTLY ASCENDING by token address (which also dedupes it), so listing the same token twice is
        // no longer legal — it is rejected at fulfill by IntentLib.requireStrictlyAscending. The
        // accumulation behavior no longer exists, so this now asserts the rejection instead.

        // Two min-tokens legs for the same token => non-ascending => rejected.
        TokenAmount[] memory minTokensList = new TokenAmount[](2);
        minTokensList[0] = TokenAmount({
            token: address(token),
            amount: 300 // First occurrence: 300 tokens
        });
        minTokensList[1] = TokenAmount({
            token: address(token),
            amount: 700 // Duplicate token (total would be 1000)
        });

        // Reward contains enough tokens to cover the route
        RewardToken[] memory rewardTokens = new RewardToken[](1);
        rewardTokens[0] = RewardToken({
            token: address(token),
            rate: 0,
            flat: TOKEN_AMOUNT // 1000 tokens total
        });

        Call[] memory calls = new Call[](0);

        Route memory route = Route({
            salt: bytes32(uint256(1)),
            deadline: uint64(block.timestamp + 1000),
            portal: address(portal),
            keeper: keeper,
            runtime: address(multicallRuntime),
            payload: abi.encode(calls),
            minTokens: minTokensList // Duplicate (non-ascending) min-tokens legs here
        });

        Reward memory reward = Reward({
            deadline: uint64(block.timestamp + 2000),
            keeper: keeper,
            prover: address(localProver),
            tokens: rewardTokens,
            hooks: ""
        });

        Intent memory _intent = Intent({
            source: CHAIN_ID,
            destination: CHAIN_ID,
            route: route,
            reward: reward
        });

        _publishAndFundIntent(_intent);

        bytes32 claimantBytes = bytes32(uint256(uint160(solver)));

        // Approve the full total so the per-leg pulls succeed and we reach the ordering check inside
        // Portal.fulfill (the revert must come from the min-tokens ordering rule, not an allowance shortfall).
        vm.prank(solver);
        token.approve(address(localProver), TOKEN_AMOUNT);

        // The duplicate (non-ascending) min-tokens legs are rejected at fulfill.
        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(
                IntentLib.MinTokensNotSorted.selector,
                address(token),
                address(token)
            )
        );
        localProver.flashFulfill(_intent.route, _intent.reward, claimantBytes);
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
