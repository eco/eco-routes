// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BaseTest} from "../BaseTest.sol";
import {FlashCallAttacker} from "./SameChainFlash.t.sol";
import {StreamingFlashPolicy} from "../../contracts/prover/StreamingFlashPolicy.sol";
import {IStreamingFlashPolicy} from "../../contracts/interfaces/IStreamingFlashPolicy.sol";
import {IStreamingPolicy} from "../../contracts/interfaces/IStreamingPolicy.sol";
import {IFlashSolver} from "../../contracts/interfaces/IFlashSolver.sol";
import {IPolicy} from "../../contracts/interfaces/IPolicy.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {IInbox} from "../../contracts/interfaces/IInbox.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";
import {Intent, Route, Reward, RewardToken, TokenAmount, IntentLib, WAD} from "../../contracts/types/Intent.sol";
import {Call} from "../../contracts/interfaces/IRuntime.sol";

/**
 * @title SweepRuntime
 * @notice BALANCE-READING runtime: the payload commits CONFIG ONLY — `abi.encode(token, recipient)`,
 *         no amounts. Delegatecalled in the Account's context, it delivers the Account's ENTIRE balance
 *         of `token` to `recipient` — exactly the runtime shape a standing flash pool needs (each slice's
 *         amount varies with the pool, so it cannot be committed in the payload).
 */
contract SweepRuntime {
    fallback() external payable {
        (address token, address to) = abi.decode(msg.data, (address, address));
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).transfer(to, bal);
        }
    }

    receive() external payable {}
}

/**
 * @title DeadbeatStreamSolver
 * @notice IFlashSolver that takes the full-pool advance and never repays the slice — the whole
 *         flashSlice must unwind, pool untouched.
 */
contract DeadbeatStreamSolver is IFlashSolver {
    StreamingFlashPolicy internal immutable POLICY;

    constructor(StreamingFlashPolicy policy) {
        POLICY = policy;
    }

    function run(
        uint32 protocolVersion,
        Route calldata route,
        Reward calldata reward,
        bytes32 claimant
    ) external {
        POLICY.flashSlice(protocolVersion, route, reward, claimant, hex"01");
    }

    function onFlashAdvance(
        bytes32,
        uint256[] calldata,
        bytes calldata
    ) external {
        // Deliberately no approval / no repayment.
    }
}

/**
 * @title StreamingFlashTest
 * @notice PR11 standing-pool zero-capital flash: full-pool advance per slice via a session-scoped
 *         consumeStreamClaims, rate-derived slice staged back, margin = pool - slice, pool re-fulfillable
 *         (status stays Funded), closeStream as the keeper exit. Lifecycle + adversarial coverage; every
 *         lifecycle test asserts money conservation across all participants.
 */
contract StreamingFlashTest is BaseTest {
    StreamingFlashPolicy internal flash;
    SweepRuntime internal sweepRuntime;
    FlashCallAttacker internal attacker;

    address internal recipient;
    address internal solver;
    address internal flashClaimant;

    uint256 internal constant FLOOR = 100; // minTokens dust guard
    uint256 internal constant RATE = 1.25e18; // 25% spread: slice = pool * WAD / rate
    uint256 internal constant POOL1 = 1000; // slice 800, margin 200
    uint256 internal constant POOL2 = 500; // slice 400, margin 100
    uint256 internal constant POOL3 = 250; // slice 200, margin 50

    function setUp() public override {
        super.setUp();
        recipient = makeAddr("poolRecipient");
        solver = makeAddr("poolSolver");
        flashClaimant = makeAddr("poolClaimant");

        vm.prank(deployer);
        flash = new StreamingFlashPolicy(address(portal));
        sweepRuntime = new SweepRuntime();
        attacker = new FlashCallAttacker();
    }

    // ---------------------------------------------------------------------
    // Fixtures
    // ---------------------------------------------------------------------

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _amounts(uint256 x) internal pure returns (uint256[] memory f) {
        f = new uint256[](1);
        f[0] = x;
    }

    /// @notice Standing-pool intent: paired tokenA legs (input floor FLOOR / pure rate `rate_`), the
    ///         balance-reading SweepRuntime as the committed runtime, effectively-infinite deadlines.
    function _poolIntent(
        uint256 rate_,
        bytes32 salt_
    ) internal view returns (Intent memory it) {
        it = _poolIntentWith(
            rate_,
            address(sweepRuntime),
            abi.encode(address(tokenA), recipient),
            salt_
        );
    }

    function _poolIntentWith(
        uint256 rate_,
        address runtime_,
        bytes memory payload_,
        bytes32 salt_
    ) internal view returns (Intent memory it) {
        TokenAmount[] memory mo = new TokenAmount[](1);
        mo[0] = TokenAmount({token: address(tokenA), amount: FLOOR});

        Route memory r = Route({
            salt: salt_,
            deadline: type(uint64).max,
            portal: address(portal),
            keeper: keeper,
            runtime: runtime_,
            payload: payload_,
            minTokens: mo
        });

        RewardToken[] memory rw = new RewardToken[](1);
        rw[0] = RewardToken({token: address(tokenA), rate: rate_, flat: 0});

        Reward memory rew = Reward({
            deadline: type(uint64).max, // standing pool: closeStream is the sole exit
            keeper: keeper,
            prover: address(flash),
            tokens: rw,
            hooks: ""
        });

        it = Intent({
            protocolVersion: PROTOCOL_VERSION,
            source: CHAIN_ID,
            destination: CHAIN_ID,
            route: r,
            reward: rew
        });
    }

    /// @notice Publishes/funds the pool intent (rate legs escrow-target 0 => Funded) and pours the pool
    ///         into the escrow Account by DIRECT TRANSFER (the standing pool's funding/top-up mechanism).
    function _publishAndPool(
        Intent memory it,
        uint256 pool
    ) internal returns (bytes32 intentHash, address account) {
        vm.prank(keeper);
        (intentHash, account) = intentSource.publishAndFund(it, false);
        if (pool > 0) {
            tokenA.mint(account, pool);
        }
    }

    function _flashSlice(Intent memory it) internal {
        vm.prank(solver);
        flash.flashSlice(
            PROTOCOL_VERSION,
            it.route,
            it.reward,
            _b32(flashClaimant),
            ""
        );
    }

    /// @notice Every money-holding participant of a slice (used for the conservation assertion).
    function _participants(
        address account,
        address solverParty
    ) internal view returns (address[] memory p) {
        p = new address[](6);
        p[0] = account;
        p[1] = address(flash);
        p[2] = solverParty;
        p[3] = flashClaimant;
        p[4] = keeper;
        p[5] = recipient;
    }

    function _sumBalances(
        TestERC20 t,
        address[] memory who
    ) internal view returns (uint256 s) {
        for (uint256 i; i < who.length; ++i) {
            s += t.balanceOf(who[i]);
        }
    }

    // ---------------------------------------------------------------------
    // Lifecycle (c): multi-slice pool at VARIABLE pool sizes with direct-transfer top-ups
    // ---------------------------------------------------------------------

    function test_flashSlice_lifecycle_variablePools_topUps() public {
        Intent memory it = _poolIntent(RATE, keccak256("pool"));
        (bytes32 ih, address account) = _publishAndPool(it, POOL1);

        address[] memory p = _participants(account, solver);

        // ---- Slice 1: pool 1000 -> slice 800, margin 200 -----------------------------------------
        uint256 sum = _sumBalances(tokenA, p);
        assertEq(tokenA.balanceOf(solver), 0, "solver fronts ZERO capital");
        _flashSlice(it);
        assertEq(tokenA.balanceOf(recipient), 800, "slice delivered");
        assertEq(tokenA.balanceOf(flashClaimant), 200, "margin = pool - slice");
        assertEq(tokenA.balanceOf(account), 0, "full pool advanced + consumed");
        assertEq(
            tokenA.balanceOf(address(flash)),
            0,
            "nothing strands in the policy"
        );
        assertEq(tokenA.balanceOf(solver), 0);
        assertEq(_sumBalances(tokenA, p), sum, "tokenA conserved (slice 1)");
        assertEq(flash.sliceCount(ih), 1);
        assertEq(
            uint256(intentSource.getRewardStatus(ih)),
            uint256(IIntentSource.Status.Funded),
            "pool stays Funded (re-fulfillable)"
        );

        // Outside the session everything is inert: zero fact, nothing unsettled.
        IPolicy.ProofData memory proof = flash.provenIntents(ih);
        assertEq(proof.destination, 0);
        assertEq(proof.fulfillmentHash, bytes32(0));
        assertFalse(flash.hasUnsettledFulfillment(ih));

        // ---- Top-up (direct transfer), slice 2 at a DIFFERENT pool size: 500 -> 400 / 100 --------
        tokenA.mint(account, POOL2);
        sum = _sumBalances(tokenA, p);
        _flashSlice(it);
        assertEq(tokenA.balanceOf(recipient), 800 + 400);
        assertEq(tokenA.balanceOf(flashClaimant), 200 + 100);
        assertEq(tokenA.balanceOf(account), 0);
        assertEq(_sumBalances(tokenA, p), sum, "tokenA conserved (slice 2)");
        assertEq(flash.sliceCount(ih), 2);

        // ---- Top-up again, slice 3: 250 -> 200 / 50 ----------------------------------------------
        tokenA.mint(account, POOL3);
        sum = _sumBalances(tokenA, p);
        _flashSlice(it);
        assertEq(tokenA.balanceOf(recipient), 800 + 400 + 200);
        assertEq(tokenA.balanceOf(flashClaimant), 200 + 100 + 50);
        assertEq(_sumBalances(tokenA, p), sum, "tokenA conserved (slice 3)");
        assertEq(flash.sliceCount(ih), 3);
        assertEq(
            uint256(intentSource.getRewardStatus(ih)),
            uint256(IIntentSource.Status.Funded)
        );
    }

    // ---------------------------------------------------------------------
    // Lifecycle (d): closeStream between slices is the keeper exit; slicing after close reverts
    // ---------------------------------------------------------------------

    function test_closeStream_betweenSlices_keeperExit_thenSliceReverts()
        public
    {
        Intent memory it = _poolIntent(RATE, keccak256("close"));
        (bytes32 ih, address account) = _publishAndPool(it, POOL1);
        bytes32 routeHash = keccak256(abi.encode(it.route));

        _flashSlice(it);
        tokenA.mint(account, POOL2); // pool refilled between slices

        // hasUnsettledFulfillment is always false (slices are consumed at birth), so the keeper's
        // closeStream is available at any point between slices and returns the pool (the reward legs
        // ARE the pool tokens, so Account.refund sweeps them).
        assertFalse(flash.hasUnsettledFulfillment(ih));
        vm.prank(keeper);
        intentSource.closeStream(
            PROTOCOL_VERSION,
            CHAIN_ID,
            CHAIN_ID,
            routeHash,
            it.reward
        );
        assertEq(
            tokenA.balanceOf(keeper),
            POOL2,
            "pool returned to the keeper"
        );
        assertEq(tokenA.balanceOf(account), 0);
        assertTrue(flash.closed(ih), "markClosed honored");
        assertEq(
            uint256(intentSource.getRewardStatus(ih)),
            uint256(IIntentSource.Status.Refunded)
        );

        // Closed is terminal for the flash path: even a re-funded account cannot be sliced.
        tokenA.mint(account, POOL1);
        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStreamingFlashPolicy.StreamClosed.selector,
                ih
            )
        );
        flash.flashSlice(
            PROTOCOL_VERSION,
            it.route,
            it.reward,
            _b32(flashClaimant),
            ""
        );
    }

    // ---------------------------------------------------------------------
    // Adversarial: provenIntents is always the zero fact — generic settle can never match
    // ---------------------------------------------------------------------

    function test_genericSettle_neverMatches_beforeAndAfterSlice() public {
        Intent memory it = _poolIntent(RATE, keccak256("settleNever"));
        (bytes32 ih, ) = _publishAndPool(it, POOL1);
        bytes32 routeHash = keccak256(abi.encode(it.route));

        // BEFORE any slice.
        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.InvalidFulfillmentProof.selector,
                ih
            )
        );
        intentSource.settle(
            PROTOCOL_VERSION,
            CHAIN_ID,
            CHAIN_ID,
            routeHash,
            it.reward,
            _b32(flashClaimant),
            _amounts(FLOOR)
        );

        _flashSlice(it); // slice 800 to flashClaimant

        // AFTER a slice: even the EXACT slice preimage matches nothing (zero fact, consumed at birth).
        IPolicy.ProofData memory proof = flash.provenIntents(ih);
        assertEq(proof.fulfillmentHash, bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.InvalidFulfillmentProof.selector,
                ih
            )
        );
        intentSource.settle(
            PROTOCOL_VERSION,
            CHAIN_ID,
            CHAIN_ID,
            routeHash,
            it.reward,
            _b32(flashClaimant),
            _amounts(800)
        );
    }

    // ---------------------------------------------------------------------
    // Adversarial: plain Inbox.fulfill against a pool intent unwinds whole
    // ---------------------------------------------------------------------

    function test_plainFulfill_poolIntent_reverts() public {
        // (1) Empty pool: execution passes conservation trivially, so the revert comes from the
        //     session gate at recordFulfillment — flashSlice is the ONLY fulfillment path.
        Intent memory it = _poolIntent(RATE, keccak256("plainEmpty"));
        (bytes32 ih, address account) = _publishAndPool(it, 0);

        tokenA.mint(otherPerson, FLOOR);
        vm.startPrank(otherPerson);
        tokenA.approve(address(portal), FLOOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStreamingFlashPolicy.NotFlashSession.selector,
                ih
            )
        );
        inbox.fulfill(
            PROTOCOL_VERSION,
            CHAIN_ID,
            CHAIN_ID,
            it.route,
            it.reward,
            _b32(otherPerson),
            _amounts(FLOOR),
            address(flash)
        );
        vm.stopPrank();
        assertEq(flash.sliceCount(ih), 0, "nothing recorded");

        // (2) Funded pool: the balance-reading runtime would consume the escrow, so the plain fulfill
        //     dies even earlier — on reward-conservation. Either way it unwinds whole; pool untouched.
        tokenA.mint(account, POOL1);
        vm.startPrank(otherPerson);
        tokenA.approve(address(portal), FLOOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                IInbox.RewardEscrowTouched.selector,
                address(tokenA),
                0,
                POOL1
            )
        );
        inbox.fulfill(
            PROTOCOL_VERSION,
            CHAIN_ID,
            CHAIN_ID,
            it.route,
            it.reward,
            _b32(otherPerson),
            _amounts(FLOOR),
            address(flash)
        );
        vm.stopPrank();
        assertEq(tokenA.balanceOf(account), POOL1, "pool untouched");
    }

    // ---------------------------------------------------------------------
    // Adversarial: re-entering flashSlice from the committed runtime is blocked
    // ---------------------------------------------------------------------

    function test_reentrantFlashSlice_blocked() public {
        // MulticallRuntime payload: poke the attacker, then deliver the (known, single-slice) amount.
        Call[] memory c = new Call[](2);
        c[0] = Call({
            target: address(attacker),
            data: abi.encodeCall(FlashCallAttacker.attack, ()),
            value: 0
        });
        c[1] = Call({
            target: address(tokenA),
            data: abi.encodeWithSignature(
                "transfer(address,uint256)",
                recipient,
                uint256(800)
            ),
            value: 0
        });
        Intent memory it = _poolIntentWith(
            RATE,
            address(multicallRuntime),
            abi.encode(c),
            keccak256("reenterSlice")
        );
        (bytes32 ih, ) = _publishAndPool(it, POOL1);

        attacker.arm(
            address(flash),
            abi.encodeCall(
                IStreamingFlashPolicy.flashSlice,
                (
                    PROTOCOL_VERSION,
                    it.route,
                    it.reward,
                    _b32(flashClaimant),
                    bytes("")
                )
            ),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector
        );

        _flashSlice(it);

        assertTrue(attacker.attacked(), "re-enter was attempted mid-route");
        assertTrue(attacker.blocked(), "nonReentrant rejected the re-enter");
        assertEq(tokenA.balanceOf(recipient), 800, "single slice only");
        assertEq(flash.sliceCount(ih), 1);
    }

    // ---------------------------------------------------------------------
    // Adversarial: a malicious runtime calling Portal.settleStream MID-session cannot double-release
    // ---------------------------------------------------------------------

    function test_midSessionSettleStream_cannotDoubleRelease() public {
        Call[] memory c = new Call[](2);
        c[0] = Call({
            target: address(attacker),
            data: abi.encodeCall(FlashCallAttacker.attack, ()),
            value: 0
        });
        c[1] = Call({
            target: address(tokenA),
            data: abi.encodeWithSignature(
                "transfer(address,uint256)",
                recipient,
                uint256(800)
            ),
            value: 0
        });
        Intent memory it = _poolIntentWith(
            RATE,
            address(multicallRuntime),
            abi.encode(c),
            keccak256("midStream")
        );
        (bytes32 ih, address account) = _publishAndPool(it, POOL1);
        bytes32 routeHash = keccak256(abi.encode(it.route));

        // The session advance is consume-ONCE: a second settleStream inside the same session dies in
        // consumeStreamClaims.
        attacker.arm(
            address(portal),
            abi.encodeCall(
                IIntentSource.settleStream,
                (
                    PROTOCOL_VERSION,
                    CHAIN_ID,
                    CHAIN_ID,
                    routeHash,
                    it.reward,
                    bytes("")
                )
            ),
            IStreamingFlashPolicy.AdvanceAlreadyConsumed.selector
        );

        address[] memory p = _participants(account, solver);
        uint256 sumBefore = _sumBalances(tokenA, p);

        _flashSlice(it);

        assertTrue(
            attacker.attacked(),
            "mid-session settleStream was attempted"
        );
        assertTrue(attacker.blocked(), "double-release blocked (consume-once)");
        // Exactly one advance was released.
        assertEq(tokenA.balanceOf(recipient), 800);
        assertEq(tokenA.balanceOf(flashClaimant), 200);
        assertEq(_sumBalances(tokenA, p), sumBefore, "tokenA conserved");
        assertEq(flash.sliceCount(ih), 1);
    }

    // ---------------------------------------------------------------------
    // Adversarial: consumeStreamClaims is Portal-only AND session-only
    // ---------------------------------------------------------------------

    function test_consumeStreamClaims_nonPortal_and_outsideSession_revert()
        public
    {
        Intent memory it = _poolIntent(RATE, keccak256("consumeGates"));
        (bytes32 ih, ) = _publishAndPool(it, POOL1);
        bytes32 routeHash = keccak256(abi.encode(it.route));

        // Non-Portal caller.
        vm.expectRevert(
            abi.encodeWithSelector(
                IStreamingPolicy.NotAuthorized.selector,
                address(this)
            )
        );
        flash.consumeStreamClaims(ih, it.reward, "");

        // Via the Portal, but with no open session: a generic settleStream can never move money.
        vm.expectRevert(
            abi.encodeWithSelector(
                IStreamingFlashPolicy.NotFlashSession.selector,
                ih
            )
        );
        intentSource.settleStream(
            PROTOCOL_VERSION,
            CHAIN_ID,
            CHAIN_ID,
            routeHash,
            it.reward,
            ""
        );
    }

    // ---------------------------------------------------------------------
    // Adversarial: empty / under-floor pool slices revert (dust guard)
    // ---------------------------------------------------------------------

    function test_flashSlice_emptyOrUnderFloorPool_reverts() public {
        Intent memory it = _poolIntent(RATE, keccak256("dust"));
        (, address account) = _publishAndPool(it, 0);

        // Empty pool: slice 0 < FLOOR.
        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStreamingFlashPolicy.SliceBelowFloor.selector,
                0,
                0,
                FLOOR
            )
        );
        flash.flashSlice(
            PROTOCOL_VERSION,
            it.route,
            it.reward,
            _b32(flashClaimant),
            ""
        );

        // Dust pool: 124 * WAD / 1.25e18 = 99 (rounded down) < FLOOR 100.
        tokenA.mint(account, 124);
        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStreamingFlashPolicy.SliceBelowFloor.selector,
                0,
                99,
                FLOOR
            )
        );
        flash.flashSlice(
            PROTOCOL_VERSION,
            it.route,
            it.reward,
            _b32(flashClaimant),
            ""
        );
    }

    // ---------------------------------------------------------------------
    // Adversarial: rounding — the slice rounds DOWN, so the margin can never go negative
    // ---------------------------------------------------------------------

    function test_rounding_sliceRoundsDown_marginNeverNegative() public {
        // rate 3.0: slice = floor(1000 / 3) = 333; 333 * 3 = 999 <= 1000, margin 667.
        Intent memory it = _poolIntent(3e18, keccak256("rounding"));
        (bytes32 ih, address account) = _publishAndPool(it, POOL1);

        address[] memory p = _participants(account, solver);
        uint256 sumBefore = _sumBalances(tokenA, p);

        _flashSlice(it);

        assertEq(tokenA.balanceOf(recipient), 333, "slice rounded down");
        assertEq(
            tokenA.balanceOf(flashClaimant),
            667,
            "margin = pool - slice >= 0"
        );
        assertEq(tokenA.balanceOf(account), 0);
        assertEq(tokenA.balanceOf(address(flash)), 0);
        assertEq(_sumBalances(tokenA, p), sumBefore, "tokenA conserved");
        assertEq(flash.sliceCount(ih), 1);
    }

    // ---------------------------------------------------------------------
    // Adversarial: a callback solver that fails to repay unwinds the WHOLE slice, pool untouched
    // ---------------------------------------------------------------------

    function test_callbackFailsToRepay_wholeSliceUnwinds_poolUntouched()
        public
    {
        Intent memory it = _poolIntent(RATE, keccak256("deadbeatPool"));
        (bytes32 ih, address account) = _publishAndPool(it, POOL1);

        DeadbeatStreamSolver deadbeat = new DeadbeatStreamSolver(flash);

        vm.expectRevert(); // the slice pull (safeTransferFrom) fails without the solver's approval
        deadbeat.run(
            PROTOCOL_VERSION,
            it.route,
            it.reward,
            _b32(flashClaimant)
        );

        // The full-pool advance unwound with the slice.
        assertEq(tokenA.balanceOf(account), POOL1, "pool untouched");
        assertEq(tokenA.balanceOf(address(deadbeat)), 0, "no advance kept");
        assertEq(flash.sliceCount(ih), 0);
        assertEq(
            uint256(intentSource.getRewardStatus(ih)),
            uint256(IIntentSource.Status.Funded)
        );

        // The session unwound too: a normal slice still works afterwards.
        _flashSlice(it);
        assertEq(tokenA.balanceOf(recipient), 800);
        assertEq(flash.sliceCount(ih), 1);
    }

    // ---------------------------------------------------------------------
    // Guards: pool-leg validation + policy-surface authorization
    // ---------------------------------------------------------------------

    function test_poolLegValidation_reverts() public {
        // A flat leg cannot be expressed under the full-pool advance.
        Intent memory it = _poolIntent(RATE, keccak256("flatLeg"));
        it.reward.tokens[0].flat = 5;
        vm.expectRevert(
            abi.encodeWithSelector(
                IStreamingFlashPolicy.FlatLegUnsupported.selector,
                0
            )
        );
        flash.flashSlice(
            PROTOCOL_VERSION,
            it.route,
            it.reward,
            _b32(flashClaimant),
            ""
        );

        // A zero-rate leg cannot be converted into a slice.
        Intent memory it2 = _poolIntent(RATE, keccak256("zeroRate"));
        it2.reward.tokens[0].rate = 0;
        vm.expectRevert(
            abi.encodeWithSelector(
                IStreamingFlashPolicy.ZeroRateLeg.selector,
                0
            )
        );
        flash.flashSlice(
            PROTOCOL_VERSION,
            it2.route,
            it2.reward,
            _b32(flashClaimant),
            ""
        );

        // An unpaired (extra) reward leg would leak to the claimant as pure margin.
        Intent memory it3 = _poolIntent(RATE, keccak256("unpaired"));
        RewardToken[] memory two = new RewardToken[](2);
        two[0] = it3.reward.tokens[0];
        two[1] = RewardToken({token: address(tokenB), rate: RATE, flat: 0});
        it3.reward.tokens = two;
        vm.expectRevert(
            abi.encodeWithSelector(
                IStreamingFlashPolicy.UnpairedLegs.selector,
                2,
                1
            )
        );
        flash.flashSlice(
            PROTOCOL_VERSION,
            it3.route,
            it3.reward,
            _b32(flashClaimant),
            ""
        );
    }

    function test_policySurface_authorization() public {
        bytes32 ih = keccak256("someIntent");

        // markClosed is Portal-only.
        vm.expectRevert(
            abi.encodeWithSelector(
                IStreamingPolicy.NotAuthorized.selector,
                address(this)
            )
        );
        flash.markClosed(ih);

        // recordBatch always reverts (no cross-chain relays for a flash pool).
        vm.expectRevert(
            abi.encodeWithSelector(
                IStreamingPolicy.NotAuthorized.selector,
                address(this)
            )
        );
        flash.recordBatch(ih, 2, keccak256("batch"));

        // recordFulfillment outside a session reverts even for the Portal.
        vm.prank(address(portal));
        vm.expectRevert(
            abi.encodeWithSelector(
                IStreamingFlashPolicy.NotFlashSession.selector,
                ih
            )
        );
        flash.recordFulfillment(ih, CHAIN_ID, keccak256("fact"));
    }
}
