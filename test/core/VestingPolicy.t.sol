// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BaseTest} from "../BaseTest.sol";
import {VestingPolicy} from "../../contracts/prover/VestingPolicy.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {Intent, Route, Reward, RewardToken, TokenAmount, IntentLib, WAD} from "../../contracts/types/Intent.sol";
import {Call} from "../../contracts/interfaces/IRuntime.sol";

/**
 * @title VestingPolicyTest
 * @notice Linear-vesting schedule policy: partial-then-full release over the window (same-chain +
 *         cross-chain), atomic-settle blocked, and the L1 under-funded-recoverable property.
 */
contract VestingPolicyTest is BaseTest {
    VestingPolicy internal vesting;

    address internal recipient;
    address internal solver;
    address internal claimant1;

    uint64 internal constant FOREIGN = 2;
    uint256 internal constant DELIVER = 100;
    uint64 internal constant DURATION = 100;

    function setUp() public override {
        super.setUp();
        recipient = makeAddr("vestRecipient");
        solver = makeAddr("vestSolver");
        claimant1 = makeAddr("vestClaimant");

        bytes32[] memory relays = new bytes32[](1);
        relays[0] = bytes32(uint256(uint160(address(this))));
        vm.prank(deployer);
        vesting = new VestingPolicy(address(portal), relays);
    }

    // Reward: a 1:1 rate leg on tokenA paired with a minTokens floor of DELIVER tokenB (so a full vest
    // pays DELIVER tokenA). The schedule param (vestDuration) is carried in reward.hooks.
    function _vestIntent(
        uint64 source,
        uint64 destination
    ) internal view returns (Intent memory it) {
        Call[] memory c = new Call[](1);
        c[0] = Call({
            target: address(tokenB),
            data: abi.encodeWithSignature(
                "transfer(address,uint256)",
                recipient,
                DELIVER
            ),
            value: 0
        });

        TokenAmount[] memory mt = new TokenAmount[](1);
        mt[0] = TokenAmount({token: address(tokenB), amount: DELIVER});

        Route memory r = Route({
            salt: keccak256(abi.encodePacked("vest", source, destination)),
            deadline: uint64(expiry),
            portal: address(portal),
            keeper: keeper,
            runtime: address(multicallRuntime),
            payload: abi.encode(c),
            minTokens: mt
        });

        RewardToken[] memory rw = new RewardToken[](1);
        rw[0] = RewardToken({token: address(tokenA), rate: WAD, flat: 0});

        Reward memory rew = Reward({
            deadline: uint64(expiry),
            keeper: keeper,
            prover: address(vesting),
            tokens: rw,
            hooks: abi.encode(DURATION)
        });

        it = Intent({
            protocolVersion: PROTOCOL_VERSION,
            source: source,
            destination: destination,
            route: r,
            reward: rew
        });
    }

    function _publishAndBudget(
        Intent memory it,
        uint256 budget
    ) internal returns (bytes32 intentHash, address account) {
        vm.prank(keeper);
        (intentHash, account) = intentSource.publishAndFund(it, false);
        tokenA.mint(account, budget);
    }

    function _fulfill(Intent memory it) internal {
        tokenB.mint(solver, DELIVER);
        vm.startPrank(solver);
        tokenB.approve(address(portal), DELIVER);
        uint256[] memory provided = new uint256[](1);
        provided[0] = DELIVER;
        inbox.fulfill(
            it.protocolVersion,
            it.source,
            it.destination,
            it.route,
            it.reward,
            bytes32(uint256(uint160(claimant1))),
            provided,
            address(vesting)
        );
        vm.stopPrank();
    }

    function _batchData() internal view returns (bytes memory) {
        uint256[] memory f = new uint256[](1);
        f[0] = DELIVER;
        return abi.encode(bytes32(uint256(uint160(claimant1))), f);
    }

    function _settle(Intent memory it, bytes32 routeHash) internal {
        intentSource.settleStream(
            it.protocolVersion,
            it.source,
            it.destination,
            routeHash,
            it.reward,
            _batchData()
        );
    }

    // ---------------------------------------------------------------------
    // Same-chain: partial then full linear release over the window
    // ---------------------------------------------------------------------

    function test_sameChain_partialThenFull() public {
        Intent memory it = _vestIntent(CHAIN_ID, CHAIN_ID);
        (bytes32 intentHash, address account) = _publishAndBudget(it, DELIVER);
        bytes32 routeHash = keccak256(abi.encode(it.route));

        _fulfill(it);

        // First settle starts the vest clock (elapsed 0 -> pays nothing).
        uint256 t0 = block.timestamp;
        _settle(it, routeHash);
        assertEq(
            vesting.vestStart(intentHash),
            uint64(t0),
            "vest start recorded"
        );
        assertEq(tokenA.balanceOf(claimant1), 0, "nothing vested at t0");

        // Halfway through the window: 50% vested.
        vm.warp(t0 + DURATION / 2);
        _settle(it, routeHash);
        assertEq(tokenA.balanceOf(claimant1), DELIVER / 2, "half vested");

        // Fully vested: the remainder is released, nothing stranded.
        vm.warp(t0 + DURATION);
        _settle(it, routeHash);
        assertEq(tokenA.balanceOf(claimant1), DELIVER, "fully vested");
        assertEq(tokenA.balanceOf(account), 0, "account drained");

        // Intent stays Funded (re-settleable); a further settle pays nothing.
        assertEq(
            uint256(intentSource.getRewardStatus(intentHash)),
            uint256(IIntentSource.Status.Funded)
        );
        _settle(it, routeHash);
        assertEq(tokenA.balanceOf(claimant1), DELIVER, "no double-pay");
    }

    // ---------------------------------------------------------------------
    // Cross-chain: relay records the fact, settle draws the vested reward
    // ---------------------------------------------------------------------

    function test_crossChain_settle() public {
        Intent memory it = _vestIntent(CHAIN_ID, FOREIGN);
        (bytes32 intentHash, ) = _publishAndBudget(it, DELIVER);
        bytes32 routeHash = keccak256(abi.encode(it.route));

        uint256[] memory f = new uint256[](1);
        f[0] = DELIVER;
        bytes32 fh = IntentLib.fulfillmentHash(
            intentHash,
            bytes32(uint256(uint160(claimant1))),
            f
        );
        vesting.recordBatch(intentHash, FOREIGN, fh);

        uint256 t0 = block.timestamp;
        _settle(it, routeHash); // starts the clock
        vm.warp(t0 + DURATION);
        _settle(it, routeHash);
        assertEq(
            tokenA.balanceOf(claimant1),
            DELIVER,
            "cross-chain fully vested"
        );
    }

    // ---------------------------------------------------------------------
    // The one-shot atomic settle is BLOCKED for a schedule intent
    // ---------------------------------------------------------------------

    function test_atomicSettle_blocked() public {
        Intent memory it = _vestIntent(CHAIN_ID, CHAIN_ID);
        (bytes32 intentHash, ) = _publishAndBudget(it, DELIVER);
        bytes32 routeHash = keccak256(abi.encode(it.route));
        _fulfill(it);

        uint256[] memory f = new uint256[](1);
        f[0] = DELIVER;
        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.InvalidFulfillmentProof.selector,
                intentHash
            )
        );
        intentSource.settle(
            it.protocolVersion,
            CHAIN_ID,
            CHAIN_ID,
            routeHash,
            it.reward,
            bytes32(uint256(uint160(claimant1))),
            f
        );
    }

    // ---------------------------------------------------------------------
    // L1: under-funded release is balance-capped; the shortfall is recoverable after a top-up
    // ---------------------------------------------------------------------

    function test_L1_underfunded_recoverableAfterTopUp() public {
        Intent memory it = _vestIntent(CHAIN_ID, CHAIN_ID);
        // Fund only 40 of the 100 entitled.
        (bytes32 intentHash, address account) = _publishAndBudget(it, 40);
        bytes32 routeHash = keccak256(abi.encode(it.route));
        _fulfill(it);

        uint256 t0 = block.timestamp;
        _settle(it, routeHash); // start clock
        vm.warp(t0 + DURATION); // fully vested: entitled 100

        // Under-funded: pays the 40 present, ledger advances by PAID (40), not by entitled (100).
        _settle(it, routeHash);
        assertEq(tokenA.balanceOf(claimant1), 40, "capped at balance");
        assertEq(tokenA.balanceOf(account), 0, "account drained");
        assertEq(vesting.releasedSoFar(intentHash, 0), 40, "ledger = PAID");

        // Keeper tops up; the shortfall is now recoverable (nothing forfeited).
        tokenA.mint(account, 60);
        _settle(it, routeHash);
        assertEq(tokenA.balanceOf(claimant1), 100, "shortfall recovered");
        assertEq(
            vesting.releasedSoFar(intentHash, 0),
            100,
            "ledger = full entitled"
        );
    }
}
