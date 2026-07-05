// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BaseTest} from "../BaseTest.sol";
import {MilestonePolicy} from "../../contracts/prover/MilestonePolicy.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {Intent, Route, Reward, RewardToken, TokenAmount, IntentLib, WAD} from "../../contracts/types/Intent.sol";
import {Call} from "../../contracts/interfaces/IRuntime.sol";

/**
 * @title MilestonePolicyTest
 * @notice Milestone-gated schedule policy: tranche unlocks driven by a bound attestor (same-chain +
 *         cross-chain), attestor auth, and the L1 under-funded-recoverable property.
 */
contract MilestonePolicyTest is BaseTest {
    MilestonePolicy internal milestone;

    address internal recipient;
    address internal solver;
    address internal claimant1;
    address internal attestor;

    uint64 internal constant FOREIGN = 2;
    uint256 internal constant DELIVER = 100;

    function setUp() public override {
        super.setUp();
        recipient = makeAddr("mileRecipient");
        solver = makeAddr("mileSolver");
        claimant1 = makeAddr("mileClaimant");
        attestor = makeAddr("mileAttestor");

        bytes32[] memory relays = new bytes32[](1);
        relays[0] = bytes32(uint256(uint160(address(this))));
        vm.prank(deployer);
        milestone = new MilestonePolicy(address(portal), relays);
    }

    // Two equal tranches (50/50); attestor + tranche schedule carried in reward.hooks.
    function _mileIntent(
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
            salt: keccak256(abi.encodePacked("mile", source, destination)),
            deadline: uint64(expiry),
            portal: address(portal),
            keeper: keeper,
            runtime: address(multicallRuntime),
            payload: abi.encode(c),
            minTokens: mt
        });

        RewardToken[] memory rw = new RewardToken[](1);
        rw[0] = RewardToken({token: address(tokenA), rate: WAD, flat: 0});

        uint16[] memory tranches = new uint16[](2);
        tranches[0] = 5000;
        tranches[1] = 5000;

        Reward memory rew = Reward({
            deadline: uint64(expiry),
            keeper: keeper,
            prover: address(milestone),
            tokens: rw,
            hooks: abi.encode(attestor, tranches)
        });

        it = Intent({
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
            it.source,
            it.destination,
            it.route,
            it.reward,
            bytes32(uint256(uint160(claimant1))),
            provided,
            address(milestone)
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
            it.source,
            it.destination,
            routeHash,
            it.reward,
            _batchData()
        );
    }

    // ---------------------------------------------------------------------
    // Same-chain: bind attestor, then draw each tranche as milestones are reached
    // ---------------------------------------------------------------------

    function test_sameChain_trancheUnlocks() public {
        Intent memory it = _mileIntent(CHAIN_ID, CHAIN_ID);
        (bytes32 intentHash, address account) = _publishAndBudget(it, DELIVER);
        bytes32 routeHash = keccak256(abi.encode(it.route));
        _fulfill(it);

        // First settle binds the attestor and pays nothing (reached == 0).
        _settle(it, routeHash);
        assertEq(milestone.attestorOf(intentHash), attestor, "attestor bound");
        assertEq(tokenA.balanceOf(claimant1), 0, "no tranche reached yet");

        // Milestone 0 -> first tranche (50%).
        vm.prank(attestor);
        milestone.markMilestone(intentHash, 0);
        _settle(it, routeHash);
        assertEq(
            tokenA.balanceOf(claimant1),
            DELIVER / 2,
            "tranche 0 released"
        );

        // Milestone 1 -> remainder (100%).
        vm.prank(attestor);
        milestone.markMilestone(intentHash, 1);
        _settle(it, routeHash);
        assertEq(tokenA.balanceOf(claimant1), DELIVER, "tranche 1 released");
        assertEq(tokenA.balanceOf(account), 0, "account drained");
    }

    // ---------------------------------------------------------------------
    // Attestor authorization + sequential signalling
    // ---------------------------------------------------------------------

    function test_markMilestone_auth() public {
        Intent memory it = _mileIntent(CHAIN_ID, CHAIN_ID);
        (bytes32 intentHash, ) = _publishAndBudget(it, DELIVER);
        bytes32 routeHash = keccak256(abi.encode(it.route));
        _fulfill(it);

        // Before binding (no settle yet), even the real attestor cannot signal.
        vm.prank(attestor);
        vm.expectRevert(
            abi.encodeWithSelector(
                MilestonePolicy.AttestorNotBound.selector,
                intentHash
            )
        );
        milestone.markMilestone(intentHash, 0);

        _settle(it, routeHash); // binds attestor

        // A non-attestor cannot signal.
        vm.prank(otherPerson);
        vm.expectRevert(
            abi.encodeWithSelector(
                MilestonePolicy.NotAttestor.selector,
                intentHash,
                otherPerson
            )
        );
        milestone.markMilestone(intentHash, 0);

        // Milestones must be sequential (index 1 before 0 reverts).
        vm.prank(attestor);
        vm.expectRevert(
            abi.encodeWithSelector(
                MilestonePolicy.NonSequentialMilestone.selector,
                intentHash,
                0,
                1
            )
        );
        milestone.markMilestone(intentHash, 1);
    }

    // ---------------------------------------------------------------------
    // Cross-chain: relay records the fact, milestones drive the draws
    // ---------------------------------------------------------------------

    function test_crossChain_trancheUnlocks() public {
        Intent memory it = _mileIntent(CHAIN_ID, FOREIGN);
        (bytes32 intentHash, ) = _publishAndBudget(it, DELIVER);
        bytes32 routeHash = keccak256(abi.encode(it.route));

        uint256[] memory f = new uint256[](1);
        f[0] = DELIVER;
        bytes32 fh = IntentLib.fulfillmentHash(
            intentHash,
            bytes32(uint256(uint160(claimant1))),
            f
        );
        milestone.recordBatch(intentHash, FOREIGN, fh);

        _settle(it, routeHash); // bind attestor
        vm.prank(attestor);
        milestone.markMilestone(intentHash, 0);
        vm.prank(attestor);
        milestone.markMilestone(intentHash, 1);
        _settle(it, routeHash);
        assertEq(
            tokenA.balanceOf(claimant1),
            DELIVER,
            "cross-chain both tranches"
        );
    }

    // ---------------------------------------------------------------------
    // L1: an under-funded tranche is balance-capped; the shortfall is recoverable after a top-up
    // ---------------------------------------------------------------------

    function test_L1_underfunded_recoverableAfterTopUp() public {
        Intent memory it = _mileIntent(CHAIN_ID, CHAIN_ID);
        // Fund only 30 of the 100 entitled.
        (bytes32 intentHash, address account) = _publishAndBudget(it, 30);
        bytes32 routeHash = keccak256(abi.encode(it.route));
        _fulfill(it);

        _settle(it, routeHash); // bind attestor
        vm.prank(attestor);
        milestone.markMilestone(intentHash, 0); // unlock 50

        // Tranche 0 unlocks 50 but only 30 is present: pays 30, ledger advances by PAID (30).
        _settle(it, routeHash);
        assertEq(tokenA.balanceOf(claimant1), 30, "capped at balance");
        assertEq(milestone.releasedSoFar(intentHash, 0), 30, "ledger = PAID");

        // Reach the last milestone and top the account up: the whole shortfall is recoverable.
        vm.prank(attestor);
        milestone.markMilestone(intentHash, 1); // unlock 100 cumulative
        tokenA.mint(account, 70);
        _settle(it, routeHash);
        assertEq(tokenA.balanceOf(claimant1), 100, "shortfall recovered");
        assertEq(
            milestone.releasedSoFar(intentHash, 0),
            100,
            "ledger = full entitled"
        );
    }
}
