// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../BaseTest.sol";
import {IPolicy} from "../../contracts/interfaces/IPolicy.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {IInbox} from "../../contracts/interfaces/IInbox.sol";
import {WAD, MAX_IN_TOKENS, MAX_REWARD_TOKENS} from "../../contracts/types/Intent.sol";

/**
 * @title RewardLegsTest
 * @notice Dedicated coverage for the v3 rate+flat reward legs, the SOLVER-INPUT floor (`minTokens`), the
 *         leftover handling, the fulfillment preimage, and leg canonicalization — the surfaces the reworked
 *         default-intent tests don't exercise (they all use rate:0 and a single trivial min-tokens leg).
 * @dev Input-floor model: the solver must PROVIDE at least `minTokens[j].amount` (it may provide more); the
 *      reward scales on the PROVIDED amount (`fulfilled[j] == providedAmounts[j]`). Delivery is the job of
 *      the committed `calls` (any beneficiary is inside the calls' calldata); any input the calls do not
 *      consume is moved to the intent's Account (leftover stays with the intent). There is no on-chain output
 *      measurement and no protocol-level recipient.
 */
contract RewardLegsTest is BaseTest {
    address internal recipient;
    address internal solver;

    function setUp() public override {
        super.setUp();
        recipient = makeAddr("recipient");
        solver = makeAddr("solver");
    }

    // Build an intent whose calls transfer `callsTransfer` tokenA to `recipient`, with a single min-tokens
    // floor of `minAmount` tokenA and a single paired reward leg {tokenA, rate, flat}. The solver decides
    // how much to actually provide at fulfill time (>= minAmount).
    function _rateIntent(
        uint256 minAmount,
        uint256 callsTransfer,
        uint256 rate,
        uint256 flat
    ) internal view returns (Intent memory _intent) {
        TokenAmount[] memory minTokensLegs = new TokenAmount[](1);
        minTokensLegs[0] = TokenAmount({token: address(tokenA), amount: minAmount});

        Call[] memory cs = new Call[](1);
        cs[0] = Call({
            target: address(tokenA),
            data: abi.encodeWithSignature(
                "transfer(address,uint256)",
                recipient,
                callsTransfer
            ),
            value: 0
        });

        Route memory r = Route({
            salt: bytes32(uint256(7)),
            deadline: uint64(block.timestamp + 1000),
            portal: address(portal),
            keeper: keeper,
            runtime: address(multicallRuntime),
            payload: abi.encode(cs),
            minTokens: minTokensLegs
        });

        RewardToken[] memory legs = new RewardToken[](1);
        legs[0] = RewardToken({token: address(tokenA), rate: rate, flat: flat});

        Reward memory rw = Reward({
            deadline: uint64(block.timestamp + 2000),
            keeper: keeper,
            prover: address(prover),
            tokens: legs,
            hooks: ""
        });

        _intent = Intent({
            source: uint64(block.chainid),
            destination: uint64(block.chainid),
            route: r,
            reward: rw
        });
    }

    // Fulfill `_intent` with the solver providing exactly `provided` tokenA of input.
    function _fulfillProviding(
        Intent memory _intent,
        uint256 provided
    ) internal returns (bytes32 intentHash) {
        intentHash = _hashIntent(_intent);
        tokenA.mint(solver, provided);
        uint256[] memory providedAmounts = new uint256[](1);
        providedAmounts[0] = provided;
        vm.startPrank(solver);
        tokenA.approve(address(portal), provided);
        portal.fulfill(
            _intent.source,
            _intent.destination,
            _intent.route,
            _intent.reward,
            bytes32(uint256(uint160(claimant))),
            providedAmounts,
            address(prover)
        );
        vm.stopPrank();
    }

    // ── previewRelease math ───────────────────────────────────────────────────

    function test_previewRelease_pairedRateAndFlat() public view {
        RewardToken[] memory legs = new RewardToken[](2);
        legs[0] = RewardToken({token: address(tokenA), rate: 2 * WAD, flat: 50});
        legs[1] = RewardToken({token: address(tokenB), rate: 0, flat: 7}); // extra flat-only leg

        Reward memory rw = Reward({
            deadline: uint64(expiry),
            keeper: keeper,
            prover: address(prover),
            tokens: legs,
            hooks: ""
        });

        uint256[] memory fulfilled = new uint256[](1);
        fulfilled[0] = 500; // paired to legs[0] (the amount the solver provided)

        uint256[] memory payNow = prover.previewRelease(rw, fulfilled);
        assertEq(payNow.length, 2);
        assertEq(payNow[0], 500 * 2 + 50); // provided*rate/WAD + flat
        assertEq(payNow[1], 7); // extra leg pays flat only
    }

    function test_previewRelease_fractionalRateRoundsDown() public view {
        RewardToken[] memory legs = new RewardToken[](1);
        legs[0] = RewardToken({token: address(tokenA), rate: WAD / 3, flat: 0});
        Reward memory rw = Reward({
            deadline: uint64(expiry),
            keeper: keeper,
            prover: address(prover),
            tokens: legs,
            hooks: ""
        });
        uint256[] memory fulfilled = new uint256[](1);
        fulfilled[0] = 10;
        uint256[] memory payNow = prover.previewRelease(rw, fulfilled);
        // 10 * (WAD/3) / WAD = 3 (rounds down, never favors the claimant over escrow)
        assertEq(payNow[0], 3);
    }

    // ── settle pays the rate+flat reward, capped at escrow ─────────────────────

    function test_settle_paysRateReward_whenFullyFunded() public {
        // owed = 500*1.5 + 50 = 800; over-fund the account to 900 so it is not capped.
        Intent memory _intent = _rateIntent(500, 500, (3 * WAD) / 2, 50);
        address account = intentSource.intentAccountAddress(_intent);
        tokenA.mint(account, 900);

        bytes32 intentHash = _fulfillProviding(_intent, 500);
        // The fulfill recorded into the prover's DESTINATION store; surface the source-side fact.
        uint256[] memory fulfilled = new uint256[](1);
        fulfilled[0] = 500;
        prover.addProvenFulfillment(
            intentHash,
            bytes32(uint256(uint160(claimant))),
            fulfilled,
            uint64(block.chainid)
        );

        uint256 claimantBefore = tokenA.balanceOf(claimant);
        uint256 keeperBefore = tokenA.balanceOf(keeper);

        intentSource.settle(
            _intent.source,
            uint64(block.chainid),
            keccak256(abi.encode(_intent.route)),
            _intent.reward,
            bytes32(uint256(uint160(claimant))),
            fulfilled
        );

        assertEq(tokenA.balanceOf(claimant), claimantBefore + 800); // rate*provided + flat
        assertEq(tokenA.balanceOf(keeper), keeperBefore + 100); // residual swept to keeper
        assertEq(tokenA.balanceOf(account), 0);
    }

    function test_settle_capsRewardAtAccountBalance() public {
        // owed = 800 but the account holds only 300 -> pays 300, no residual.
        Intent memory _intent = _rateIntent(500, 500, (3 * WAD) / 2, 50);
        address account = intentSource.intentAccountAddress(_intent);
        tokenA.mint(account, 300);

        bytes32 intentHash = _fulfillProviding(_intent, 500);
        uint256[] memory fulfilled = new uint256[](1);
        fulfilled[0] = 500;
        prover.addProvenFulfillment(
            intentHash,
            bytes32(uint256(uint160(claimant))),
            fulfilled,
            uint64(block.chainid)
        );

        uint256 claimantBefore = tokenA.balanceOf(claimant);

        intentSource.settle(
            _intent.source,
            uint64(block.chainid),
            keccak256(abi.encode(_intent.route)),
            _intent.reward,
            bytes32(uint256(uint160(claimant))),
            fulfilled
        );

        assertEq(tokenA.balanceOf(claimant), claimantBefore + 300); // capped at escrow
        assertEq(tokenA.balanceOf(account), 0);
    }

    // ── input floor: records provided input, scales reward on it, sweeps leftover ──

    function test_fulfill_recordsProvidedInput() public {
        Intent memory _intent = _rateIntent(500, 500, WAD, 0);
        uint256 recipientBefore = tokenA.balanceOf(recipient);
        bytes32 intentHash = _fulfillProviding(_intent, 500);

        // Calls delivered the full 500 to the recipient; nothing left to sweep.
        assertEq(tokenA.balanceOf(recipient), recipientBefore + 500);

        uint256[] memory fulfilled = new uint256[](1);
        fulfilled[0] = 500; // fulfilled == provided input
        assertEq(
            prover.destFulfillment(intentHash),
            IntentLib.fulfillmentHash(
                intentHash,
                bytes32(uint256(uint160(claimant))),
                fulfilled
            )
        );
    }

    function test_fulfill_providingMoreThanFloor_leftoverToAccount() public {
        // minTokens floor 500; the calls consume 500; solver provides 600 -> 100 unconsumed stays with
        // the intent (moved to the intent's Account, NOT to any protocol-level recipient).
        Intent memory _intent = _rateIntent(500, 500, WAD, 0);
        address account = intentSource.intentAccountAddress(_intent);
        uint256 recipientBefore = tokenA.balanceOf(recipient);
        uint256 accountBefore = tokenA.balanceOf(account);
        bytes32 intentHash = _fulfillProviding(_intent, 600);

        // Delivery is the calls' job: the recipient (inside the call's calldata) gets exactly the 500 the
        // calls transfer. The 100 unconsumed input is NOT delivered to the recipient.
        assertEq(tokenA.balanceOf(recipient), recipientBefore + 500);
        // The unconsumed 100 lands in the intent's Account, where the keeper can retrieve it later.
        assertEq(tokenA.balanceOf(account), accountBefore + 100);

        // fulfilled records the FULL provided input; the reward scales on 600, not on the 500 floor.
        uint256[] memory fulfilled = new uint256[](1);
        fulfilled[0] = 600;
        assertEq(
            prover.destFulfillment(intentHash),
            IntentLib.fulfillmentHash(
                intentHash,
                bytes32(uint256(uint160(claimant))),
                fulfilled
            )
        );
    }

    function test_fulfill_revertsOnInsufficientTokens() public {
        // Provide only 400 but the min-tokens floor is 500.
        Intent memory _intent = _rateIntent(500, 500, WAD, 0);
        tokenA.mint(solver, 400);
        uint256[] memory providedAmounts = new uint256[](1);
        providedAmounts[0] = 400;
        vm.startPrank(solver);
        tokenA.approve(address(portal), 400);
        vm.expectRevert(
            abi.encodeWithSelector(
                IInbox.InsufficientTokens.selector,
                address(tokenA),
                400,
                500
            )
        );
        portal.fulfill(
            _intent.source,
            _intent.destination,
            _intent.route,
            _intent.reward,
            bytes32(uint256(uint160(claimant))),
            providedAmounts,
            address(prover)
        );
        vm.stopPrank();
    }

    function test_fulfill_revertsOnProvidedAmountsLengthMismatch() public {
        // One min-tokens leg, but an empty providedAmounts array.
        Intent memory _intent = _rateIntent(500, 500, WAD, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IInbox.ProvidedAmountsLengthMismatch.selector,
                0,
                1
            )
        );
        vm.prank(solver);
        portal.fulfill(
            _intent.source,
            _intent.destination,
            _intent.route,
            _intent.reward,
            bytes32(uint256(uint160(claimant))),
            new uint256[](0),
            address(prover)
        );
    }

    // ── fulfillment preimage ────────────────────────────────────────────────────

    function test_settle_revertsOnPreimageMismatch() public {
        Intent memory _intent = _rateIntent(500, 500, WAD, 0);
        address account = intentSource.intentAccountAddress(_intent);
        tokenA.mint(account, 500);
        bytes32 intentHash = _fulfillProviding(_intent, 500);

        uint256[] memory proven = new uint256[](1);
        proven[0] = 500;
        prover.addProvenFulfillment(
            intentHash,
            bytes32(uint256(uint160(claimant))),
            proven,
            uint64(block.chainid)
        );

        // Settle with a WRONG fulfilled preimage (400 != proven 500).
        uint256[] memory wrong = new uint256[](1);
        wrong[0] = 400;
        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.InvalidFulfillmentProof.selector,
                intentHash
            )
        );
        intentSource.settle(
            _intent.source,
            uint64(block.chainid),
            keccak256(abi.encode(_intent.route)),
            _intent.reward,
            bytes32(uint256(uint160(claimant))),
            wrong
        );
    }

    // ── canonicalization reverts ────────────────────────────────────────────────

    function test_publish_revertsOnDuplicateRewardToken() public {
        RewardToken[] memory legs = new RewardToken[](2);
        legs[0] = RewardToken({token: address(tokenA), rate: 0, flat: 100});
        legs[1] = RewardToken({token: address(tokenA), rate: 0, flat: 200});
        Reward memory rw = Reward({
            deadline: uint64(expiry),
            keeper: keeper,
            prover: address(prover),
            tokens: legs,
            hooks: ""
        });
        Intent memory _intent = Intent({
            source: uint64(block.chainid),
            destination: uint64(block.chainid),
            route: route,
            reward: rw
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                IntentLib.RewardTokensNotUnique.selector,
                address(tokenA)
            )
        );
        vm.prank(keeper);
        intentSource.publish(_intent);
    }

    function test_publish_revertsOnTooManyRewardTokens() public {
        uint256 n = MAX_REWARD_TOKENS + 1;
        RewardToken[] memory legs = new RewardToken[](n);
        for (uint256 i = 0; i < n; ++i) {
            // distinct non-zero token addresses
            legs[i] = RewardToken({
                token: address(uint160(1000 + i)),
                rate: 0,
                flat: 1
            });
        }
        Reward memory rw = Reward({
            deadline: uint64(expiry),
            keeper: keeper,
            prover: address(prover),
            tokens: legs,
            hooks: ""
        });
        Intent memory _intent = Intent({
            source: uint64(block.chainid),
            destination: uint64(block.chainid),
            route: route,
            reward: rw
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                IntentLib.TooManyRewardTokens.selector,
                n,
                MAX_REWARD_TOKENS
            )
        );
        vm.prank(keeper);
        intentSource.publish(_intent);
    }

    function test_fulfill_revertsOnUnsortedMinTokens() public {
        // minTokens with a descending (non-strictly-ascending) token order.
        address hi = address(uint160(2000));
        address lo = address(uint160(1000));
        TokenAmount[] memory mi = new TokenAmount[](2);
        mi[0] = TokenAmount({token: hi, amount: 1});
        mi[1] = TokenAmount({token: lo, amount: 1});

        Route memory r = Route({
            salt: bytes32(uint256(9)),
            deadline: uint64(block.timestamp + 1000),
            portal: address(portal),
            keeper: keeper,
            runtime: address(multicallRuntime),
            payload: abi.encode(new Call[](0)),
            minTokens: mi
        });
        RewardToken[] memory legs = new RewardToken[](2);
        legs[0] = RewardToken({token: hi, rate: 0, flat: 0});
        legs[1] = RewardToken({token: lo, rate: 0, flat: 0});
        Reward memory rw = Reward({
            deadline: uint64(block.timestamp + 2000),
            keeper: keeper,
            prover: address(prover),
            tokens: legs,
            hooks: ""
        });
        Intent memory _intent = Intent({
            source: uint64(block.chainid),
            destination: uint64(block.chainid),
            route: r,
            reward: rw
        });

        vm.expectRevert(
            abi.encodeWithSelector(IntentLib.MinTokensNotSorted.selector, hi, lo)
        );
        portal.fulfill(
            _intent.source,
            _intent.destination,
            r,
            rw,
            bytes32(uint256(uint160(claimant))),
            new uint256[](2),
            address(prover)
        );
    }

    function test_fulfill_revertsOnTooManyMinTokens() public {
        uint256 n = MAX_IN_TOKENS + 1;
        TokenAmount[] memory mi = new TokenAmount[](n);
        for (uint256 i = 0; i < n; ++i) {
            mi[i] = TokenAmount({token: address(uint160(1000 + i)), amount: 1});
        }
        Route memory r = Route({
            salt: bytes32(uint256(11)),
            deadline: uint64(block.timestamp + 1000),
            portal: address(portal),
            keeper: keeper,
            runtime: address(multicallRuntime),
            payload: abi.encode(new Call[](0)),
            minTokens: mi
        });
        Reward memory rw = Reward({
            deadline: uint64(block.timestamp + 2000),
            keeper: keeper,
            prover: address(prover),
            tokens: new RewardToken[](0),
            hooks: ""
        });
        Intent memory _intent = Intent({
            source: uint64(block.chainid),
            destination: uint64(block.chainid),
            route: r,
            reward: rw
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                IntentLib.TooManyInTokens.selector,
                n,
                MAX_IN_TOKENS
            )
        );
        portal.fulfill(
            _intent.source,
            _intent.destination,
            r,
            rw,
            bytes32(uint256(uint160(claimant))),
            new uint256[](n),
            address(prover)
        );
    }
}
