// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BaseTest} from "../BaseTest.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SameChainFlashPolicy} from "../../contracts/prover/SameChainFlashPolicy.sol";
import {ISameChainFlashPolicy} from "../../contracts/interfaces/ISameChainFlashPolicy.sol";
import {IFlashSolver} from "../../contracts/interfaces/IFlashSolver.sol";
import {IPolicy} from "../../contracts/interfaces/IPolicy.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";
import {Intent, Route, Reward, RewardToken, TokenAmount, IntentLib, WAD} from "../../contracts/types/Intent.sol";
import {Call} from "../../contracts/interfaces/IRuntime.sol";

/**
 * @title FlashCallAttacker
 * @notice Mid-route attack harness: the committed payload CALLs {attack}, which fires a pre-armed
 *         low-level call (a re-enter, a mid-session settle, ...) and REQUIRES it to fail with the
 *         expected error selector. If the armed call unexpectedly SUCCEEDS the whole flash reverts, so a
 *         passing flash + `blocked() == true` proves the attack was attempted mid-session and rejected.
 * @dev Reached by a plain CALL from the MulticallRuntime (delegatecalled in the Account), so its own
 *      storage persists when the outer flash succeeds.
 */
contract FlashCallAttacker {
    address public target;
    bytes public data;
    bytes4 public expectedSelector;
    bool public attacked;
    bool public blocked;

    function arm(
        address _target,
        bytes calldata _data,
        bytes4 _selector
    ) external {
        target = _target;
        data = _data;
        expectedSelector = _selector;
        attacked = false;
        blocked = false;
    }

    function attack() external {
        attacked = true;
        (bool ok, bytes memory ret) = target.call(data);
        if (ok) {
            revert("attack unexpectedly succeeded");
        }
        bytes4 got;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            got := mload(add(ret, 0x20))
        }
        require(got == expectedSelector, "unexpected inner revert reason");
        blocked = true;
    }
}

/**
 * @title MockSwapSolver
 * @notice IFlashSolver swap venue: receives the reward advance mid-session and "swaps" it by approving
 *         the calling policy for the route's input leg out of its own liquidity.
 */
contract MockSwapSolver is IFlashSolver {
    SameChainFlashPolicy internal immutable POLICY;
    TestERC20 internal immutable INPUT_TOKEN;
    uint256 internal immutable INPUT_AMOUNT;
    bool public advanceReceived;

    constructor(
        SameChainFlashPolicy policy,
        TestERC20 inputToken,
        uint256 inputAmount
    ) {
        POLICY = policy;
        INPUT_TOKEN = inputToken;
        INPUT_AMOUNT = inputAmount;
    }

    function run(
        uint32 protocolVersion,
        Route calldata route,
        Reward calldata reward,
        bytes32 claimant
    ) external returns (bytes memory) {
        // Non-empty solverData selects swap mode (the advance is handed to THIS contract).
        return
            POLICY.flashFulfill(
                protocolVersion,
                route,
                reward,
                claimant,
                abi.encode(true)
            );
    }

    function onFlashAdvance(
        bytes32,
        uint256[] calldata,
        bytes calldata
    ) external {
        advanceReceived = true;
        // "Swap": make the input leg pullable by the calling policy out of this venue's liquidity.
        INPUT_TOKEN.approve(msg.sender, INPUT_AMOUNT);
    }
}

/**
 * @title DeadbeatSolver
 * @notice IFlashSolver that takes the advance and never repays the inputs — the whole flash must unwind.
 */
contract DeadbeatSolver is IFlashSolver {
    SameChainFlashPolicy internal immutable POLICY;

    constructor(SameChainFlashPolicy policy) {
        POLICY = policy;
    }

    function run(
        uint32 protocolVersion,
        Route calldata route,
        Reward calldata reward,
        bytes32 claimant
    ) external {
        POLICY.flashFulfill(protocolVersion, route, reward, claimant, hex"01");
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
 * @title SameChainFlashTest
 * @notice PR11 one-shot zero-capital flash: v2's withdraw-before-fulfill restored as a standalone v3
 *         policy (session self-vouching through provenIntents). Lifecycle + adversarial coverage; every
 *         lifecycle test asserts money conservation across all participants.
 */
contract SameChainFlashTest is BaseTest {
    SameChainFlashPolicy internal flash;
    FlashCallAttacker internal attacker;

    address internal recipient;
    address internal solver;
    address internal flashClaimant;

    uint256 internal constant INPUT = 1000;
    uint256 internal constant RATE = 1.2e18; // 20% reward spread
    uint256 internal constant OWED = 1200; // INPUT * RATE / WAD
    uint256 internal constant ESCROW = 1250; // OWED + 50 keeper residual

    function setUp() public override {
        super.setUp();
        recipient = makeAddr("flashRecipient");
        solver = makeAddr("flashSolver");
        flashClaimant = makeAddr("flashClaimant");

        vm.prank(deployer);
        flash = new SameChainFlashPolicy(address(portal));
        attacker = new FlashCallAttacker();
    }

    // ---------------------------------------------------------------------
    // Fixtures
    // ---------------------------------------------------------------------

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    /// @notice The exact minTokens floors — the one-shot flash's pinned `fulfilled[]`.
    function _planned() internal pure returns (uint256[] memory f) {
        f = new uint256[](1);
        f[0] = INPUT;
    }

    /// @notice The default delivery payload: transfer the staged input to `recipient`.
    function _deliverCalls() internal view returns (Call[] memory c) {
        c = new Call[](1);
        c[0] = Call({
            target: address(tokenA),
            data: abi.encodeWithSignature(
                "transfer(address,uint256)",
                recipient,
                INPUT
            ),
            value: 0
        });
    }

    /// @notice Same-chain flash intent: input INPUT tokenA, reward leg `rewardTok` at RATE (rate-only).
    function _flashIntent(
        address rewardTok,
        Call[] memory c,
        bytes32 salt_
    ) internal view returns (Intent memory it) {
        TokenAmount[] memory mo = new TokenAmount[](1);
        mo[0] = TokenAmount({token: address(tokenA), amount: INPUT});

        Route memory r = Route({
            salt: salt_,
            deadline: uint64(expiry),
            portal: address(portal),
            keeper: keeper,
            runtime: address(multicallRuntime),
            payload: abi.encode(c),
            minTokens: mo
        });

        RewardToken[] memory rw = new RewardToken[](1);
        rw[0] = RewardToken({token: rewardTok, rate: RATE, flat: 0});

        Reward memory rew = Reward({
            deadline: uint64(expiry),
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

    /// @notice Publishes/funds the intent (rate legs escrow-target 0 => Funded) and over-funds the
    ///         account with the actual escrow budget (rate legs are not pre-funded, PR6 convention).
    function _publishAndEscrow(
        Intent memory it,
        TestERC20 escrowToken,
        uint256 escrow
    ) internal returns (bytes32 intentHash, address account) {
        vm.prank(keeper);
        (intentHash, account) = intentSource.publishAndFund(it, false);
        escrowToken.mint(account, escrow);
    }

    /// @notice Every money-holding participant of a flash (used for the conservation assertion).
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
    // Lifecycle (a): zero-capital direct flash, end to end
    // ---------------------------------------------------------------------

    function test_flashFulfill_zeroCapital_endToEnd() public {
        Intent memory it = _flashIntent(
            address(tokenA),
            _deliverCalls(),
            keccak256("direct")
        );
        (bytes32 ih, address account) = _publishAndEscrow(it, tokenA, ESCROW);

        address[] memory p = _participants(account, solver);
        uint256 sumBefore = _sumBalances(tokenA, p);
        assertEq(tokenA.balanceOf(solver), 0, "solver fronts ZERO capital");

        vm.prank(solver);
        flash.flashFulfill(
            PROTOCOL_VERSION,
            it.route,
            it.reward,
            _b32(flashClaimant),
            ""
        );

        // Route delivered out of the advance; claimant nets exactly the spread; keeper the residual.
        assertEq(tokenA.balanceOf(recipient), INPUT, "route delivered");
        assertEq(
            tokenA.balanceOf(flashClaimant),
            OWED - INPUT,
            "claimant nets exactly the reward spread"
        );
        assertEq(
            tokenA.balanceOf(keeper),
            ESCROW - OWED,
            "keeper swept the residual"
        );
        assertEq(tokenA.balanceOf(solver), 0, "solver still fronts nothing");
        assertEq(
            tokenA.balanceOf(address(flash)),
            0,
            "nothing strands in the policy"
        );
        assertEq(tokenA.balanceOf(account), 0, "escrow fully released");

        // Terminal status + the REAL-claimant fact recorded and served as the proof.
        assertEq(
            uint256(intentSource.getRewardStatus(ih)),
            uint256(IIntentSource.Status.Withdrawn)
        );
        bytes32 expectedFact = IntentLib.fulfillmentHash(
            ih,
            _b32(flashClaimant),
            _planned()
        );
        assertEq(flash.destFulfillment(ih), expectedFact, "real fact recorded");
        IPolicy.ProofData memory proof = flash.provenIntents(ih);
        assertEq(proof.destination, CHAIN_ID);
        assertEq(proof.fulfillmentHash, expectedFact);

        // Money conservation: no token created or destroyed across all participants.
        assertEq(_sumBalances(tokenA, p), sumBefore, "tokenA conserved");
    }

    // ---------------------------------------------------------------------
    // Lifecycle (b): swap-callback flash (reward token != input token)
    // ---------------------------------------------------------------------

    function test_flashFulfill_swapCallback_endToEnd() public {
        // Reward leg is tokenB; the venue swaps the tokenB advance into the tokenA input.
        Intent memory it = _flashIntent(
            address(tokenB),
            _deliverCalls(),
            keccak256("swap")
        );
        (bytes32 ih, address account) = _publishAndEscrow(it, tokenB, OWED);

        MockSwapSolver venue = new MockSwapSolver(flash, tokenA, INPUT);
        tokenA.mint(address(venue), INPUT); // the venue's own liquidity, not the solver's capital

        address[] memory p = _participants(account, address(venue));
        uint256 sumA = _sumBalances(tokenA, p);
        uint256 sumB = _sumBalances(tokenB, p);

        venue.run(PROTOCOL_VERSION, it.route, it.reward, _b32(flashClaimant));

        assertTrue(venue.advanceReceived(), "swap callback ran");
        assertEq(
            tokenA.balanceOf(recipient),
            INPUT,
            "route delivered from the swap"
        );
        assertEq(
            tokenB.balanceOf(address(venue)),
            OWED,
            "venue keeps the advance (its swap proceeds / margin)"
        );
        assertEq(
            tokenA.balanceOf(address(venue)),
            0,
            "venue liquidity consumed"
        );
        assertEq(tokenB.balanceOf(address(flash)), 0);
        assertEq(tokenB.balanceOf(account), 0);

        assertEq(
            uint256(intentSource.getRewardStatus(ih)),
            uint256(IIntentSource.Status.Withdrawn)
        );
        assertEq(
            flash.destFulfillment(ih),
            IntentLib.fulfillmentHash(ih, _b32(flashClaimant), _planned())
        );

        // Money conservation per token across all participants.
        assertEq(_sumBalances(tokenA, p), sumA, "tokenA conserved");
        assertEq(_sumBalances(tokenB, p), sumB, "tokenB conserved");
    }

    // ---------------------------------------------------------------------
    // Adversarial: the session fact is invisible outside the session
    // ---------------------------------------------------------------------

    function test_sessionFact_invisibleOutsideSession_settleReverts() public {
        Intent memory it = _flashIntent(
            address(tokenA),
            _deliverCalls(),
            keccak256("invisible")
        );
        (bytes32 ih, ) = _publishAndEscrow(it, tokenA, ESCROW);
        bytes32 routeHash = keccak256(abi.encode(it.route));

        // BEFORE any flash: zero fact; the would-be session preimage (policy as claimant over the
        // floors) verifies against nothing.
        IPolicy.ProofData memory proof = flash.provenIntents(ih);
        assertEq(proof.destination, 0);
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
            _b32(address(flash)),
            _planned()
        );

        vm.prank(solver);
        flash.flashFulfill(
            PROTOCOL_VERSION,
            it.route,
            it.reward,
            _b32(flashClaimant),
            ""
        );

        // AFTER the flash: the session (policy-claimant) preimage no longer matches the REAL fact...
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
            _b32(address(flash)),
            _planned()
        );

        // ...and even the REAL preimage cannot release anything twice (status is terminal).
        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.InvalidStatusForWithdrawal.selector,
                IIntentSource.Status.Withdrawn
            )
        );
        intentSource.settle(
            PROTOCOL_VERSION,
            CHAIN_ID,
            CHAIN_ID,
            routeHash,
            it.reward,
            _b32(flashClaimant),
            _planned()
        );
    }

    // ---------------------------------------------------------------------
    // Adversarial: a pre-recorded REAL fact blocks flash (griefing-DoS only, never theft)
    // ---------------------------------------------------------------------

    function test_preRecordedRealFact_blocksFlash_dosOnly() public {
        Intent memory it = _flashIntent(
            address(tokenA),
            _deliverCalls(),
            keccak256("preRecorded")
        );
        (bytes32 ih, ) = _publishAndEscrow(it, tokenA, ESCROW);
        bytes32 routeHash = keccak256(abi.encode(it.route));

        // A capitalized solver fulfills first through the plain path, naming otherPerson.
        tokenA.mint(otherPerson, INPUT);
        vm.startPrank(otherPerson);
        tokenA.approve(address(portal), INPUT);
        inbox.fulfill(
            PROTOCOL_VERSION,
            CHAIN_ID,
            CHAIN_ID,
            it.route,
            it.reward,
            _b32(otherPerson),
            _planned(),
            address(flash)
        );
        vm.stopPrank();

        // Flash is now blocked for this hash — a DoS of the flash path only.
        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(IPolicy.IntentAlreadyFulfilled.selector, ih)
        );
        flash.flashFulfill(
            PROTOCOL_VERSION,
            it.route,
            it.reward,
            _b32(flashClaimant),
            ""
        );

        // Nothing is stolen: the competing (real) fulfillment settles with its own preimage.
        intentSource.settle(
            PROTOCOL_VERSION,
            CHAIN_ID,
            CHAIN_ID,
            routeHash,
            it.reward,
            _b32(otherPerson),
            _planned()
        );
        assertEq(
            tokenA.balanceOf(otherPerson),
            OWED,
            "honest fulfiller settled its own fact"
        );
    }

    // ---------------------------------------------------------------------
    // Adversarial: re-entering flashFulfill from the committed runtime is blocked
    // ---------------------------------------------------------------------

    function test_reentrantFlashFulfill_blocked() public {
        Call[] memory c = new Call[](2);
        c[0] = Call({
            target: address(attacker),
            data: abi.encodeCall(FlashCallAttacker.attack, ()),
            value: 0
        });
        c[1] = _deliverCalls()[0];

        Intent memory it = _flashIntent(
            address(tokenA),
            c,
            keccak256("reenter")
        );
        (bytes32 ih, ) = _publishAndEscrow(it, tokenA, ESCROW);

        attacker.arm(
            address(flash),
            abi.encodeCall(
                ISameChainFlashPolicy.flashFulfill,
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

        vm.prank(solver);
        flash.flashFulfill(
            PROTOCOL_VERSION,
            it.route,
            it.reward,
            _b32(flashClaimant),
            ""
        );

        assertTrue(attacker.attacked(), "re-enter was attempted mid-route");
        assertTrue(attacker.blocked(), "nonReentrant rejected the re-enter");
        assertEq(tokenA.balanceOf(recipient), INPUT, "single delivery only");
        assertEq(
            uint256(intentSource.getRewardStatus(ih)),
            uint256(IIntentSource.Status.Withdrawn)
        );
    }

    // ---------------------------------------------------------------------
    // Adversarial: a malicious runtime calling Portal.settle MID-session cannot double-release
    // ---------------------------------------------------------------------

    function test_midSessionSettle_cannotDoubleRelease() public {
        Call[] memory c = new Call[](2);
        c[0] = Call({
            target: address(attacker),
            data: abi.encodeCall(FlashCallAttacker.attack, ()),
            value: 0
        });
        c[1] = _deliverCalls()[0];

        Intent memory it = _flashIntent(
            address(tokenA),
            c,
            keccak256("midSettle")
        );
        (, address account) = _publishAndEscrow(it, tokenA, ESCROW);
        bytes32 routeHash = keccak256(abi.encode(it.route));

        // Mid-session the session fact IS visible to settle — but the status is already Withdrawn
        // (the advance flipped it), so the double-release dies on the status machine.
        attacker.arm(
            address(portal),
            abi.encodeCall(
                IIntentSource.settle,
                (
                    PROTOCOL_VERSION,
                    CHAIN_ID,
                    CHAIN_ID,
                    routeHash,
                    it.reward,
                    _b32(address(flash)),
                    _planned()
                )
            ),
            IIntentSource.InvalidStatusForWithdrawal.selector
        );

        address[] memory p = _participants(account, solver);
        uint256 sumBefore = _sumBalances(tokenA, p);

        vm.prank(solver);
        flash.flashFulfill(
            PROTOCOL_VERSION,
            it.route,
            it.reward,
            _b32(flashClaimant),
            ""
        );

        assertTrue(attacker.attacked(), "mid-session settle was attempted");
        assertTrue(
            attacker.blocked(),
            "double-release blocked by Withdrawn status"
        );
        // Exactly one release happened.
        assertEq(tokenA.balanceOf(flashClaimant), OWED - INPUT);
        assertEq(tokenA.balanceOf(keeper), ESCROW - OWED);
        assertEq(_sumBalances(tokenA, p), sumBefore, "tokenA conserved");
    }

    // ---------------------------------------------------------------------
    // Adversarial: a callback solver that fails to repay unwinds the WHOLE flash
    // ---------------------------------------------------------------------

    function test_callbackFailsToRepay_wholeFlashUnwinds() public {
        Intent memory it = _flashIntent(
            address(tokenB),
            _deliverCalls(),
            keccak256("deadbeat")
        );
        (bytes32 ih, address account) = _publishAndEscrow(it, tokenB, OWED);

        DeadbeatSolver deadbeat = new DeadbeatSolver(flash);

        vm.expectRevert(); // the input pull (safeTransferFrom) fails without the solver's approval
        deadbeat.run(
            PROTOCOL_VERSION,
            it.route,
            it.reward,
            _b32(flashClaimant)
        );

        // The advance unwound with the flash: escrow untouched, status live, no fact, idle session.
        assertEq(tokenB.balanceOf(account), OWED, "escrow untouched");
        assertEq(tokenB.balanceOf(address(deadbeat)), 0, "no advance kept");
        assertEq(
            uint256(intentSource.getRewardStatus(ih)),
            uint256(IIntentSource.Status.Funded)
        );
        assertEq(flash.destFulfillment(ih), bytes32(0), "no fact recorded");
        IPolicy.ProofData memory proof = flash.provenIntents(ih);
        assertEq(proof.fulfillmentHash, bytes32(0), "session unwound");
    }

    // ---------------------------------------------------------------------
    // Guards: claimant / prover validation
    // ---------------------------------------------------------------------

    function test_flashFulfill_inputGuards() public {
        Intent memory it = _flashIntent(
            address(tokenA),
            _deliverCalls(),
            keccak256("guards")
        );
        _publishAndEscrow(it, tokenA, ESCROW);

        // Zero claimant.
        vm.expectRevert(ISameChainFlashPolicy.InvalidClaimant.selector);
        flash.flashFulfill(
            PROTOCOL_VERSION,
            it.route,
            it.reward,
            bytes32(0),
            ""
        );

        // The policy itself as claimant.
        vm.expectRevert(ISameChainFlashPolicy.InvalidClaimant.selector);
        flash.flashFulfill(
            PROTOCOL_VERSION,
            it.route,
            it.reward,
            _b32(address(flash)),
            ""
        );

        // Non-EVM claimant (dirty upper bytes).
        vm.expectRevert(ISameChainFlashPolicy.InvalidClaimant.selector);
        flash.flashFulfill(
            PROTOCOL_VERSION,
            it.route,
            it.reward,
            bytes32(uint256(1) << 200),
            ""
        );

        // Reward naming a different prover.
        Intent memory other = _flashIntent(
            address(tokenA),
            _deliverCalls(),
            keccak256("otherProver")
        );
        other.reward.prover = address(prover);
        vm.expectRevert(ISameChainFlashPolicy.InvalidProver.selector);
        flash.flashFulfill(
            PROTOCOL_VERSION,
            other.route,
            other.reward,
            _b32(flashClaimant),
            ""
        );
    }
}
