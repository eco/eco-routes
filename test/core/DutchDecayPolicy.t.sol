// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BaseTest} from "../BaseTest.sol";
import {DutchDecayPolicy} from "../../contracts/prover/DutchDecayPolicy.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {Intent, Route, Reward, RewardToken, TokenAmount, IntentLib, WAD} from "../../contracts/types/Intent.sol";
import {Call} from "../../contracts/interfaces/IRuntime.sol";

/**
 * @title DutchDecayPolicyTest
 * @notice Dutch-auction schedule policy: the reward decays with settle time (peak/mid/floor), the
 *         residual sweeps to the keeper, the release is single-shot/terminal, and it works cross-chain.
 */
contract DutchDecayPolicyTest is BaseTest {
    DutchDecayPolicy internal dutch;

    address internal recipient;
    address internal solver;
    address internal claimant1;

    uint64 internal constant FOREIGN = 2;
    uint256 internal constant DELIVER = 100;
    uint256 internal constant START_MUL = 2e18; // 2x at the auction start
    uint256 internal constant END_MUL = 1e18; // 1x at the auction end
    uint64 internal constant WINDOW = 100;
    uint64 internal auctionStart;

    function setUp() public override {
        super.setUp();
        recipient = makeAddr("dutchRecipient");
        solver = makeAddr("dutchSolver");
        claimant1 = makeAddr("dutchClaimant");
        auctionStart = uint64(block.timestamp);

        bytes32[] memory relays = new bytes32[](1);
        relays[0] = bytes32(uint256(uint160(address(this))));
        vm.prank(deployer);
        dutch = new DutchDecayPolicy(address(portal), relays);
    }

    function _dutchIntent(
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
            salt: keccak256(abi.encodePacked("dutch", source, destination)),
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
            prover: address(dutch),
            tokens: rw,
            hooks: abi.encode(START_MUL, END_MUL, auctionStart, WINDOW)
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
            address(dutch)
        );
        vm.stopPrank();
    }

    function _settle(Intent memory it, bytes32 routeHash) internal {
        uint256[] memory f = new uint256[](1);
        f[0] = DELIVER;
        intentSource.settle(
            it.source,
            it.destination,
            routeHash,
            it.reward,
            bytes32(uint256(uint160(claimant1))),
            f
        );
    }

    // ---------------------------------------------------------------------
    // Decay: earlier settle pays more; the residual sweeps to the keeper
    // ---------------------------------------------------------------------

    function test_peakAtStart_paysFullMultiplier() public {
        Intent memory it = _dutchIntent(CHAIN_ID, CHAIN_ID);
        (, address account) = _publishAndBudget(it, 2 * DELIVER);
        bytes32 routeHash = keccak256(abi.encode(it.route));
        _fulfill(it);

        // Settle at the auction start: 2x -> pays 200, no residual.
        _settle(it, routeHash);
        assertEq(tokenA.balanceOf(claimant1), 2 * DELIVER, "peak multiplier");
        assertEq(tokenA.balanceOf(account), 0, "no residual at peak");
    }

    function test_midAuction_decaysAndSweepsResidual() public {
        Intent memory it = _dutchIntent(CHAIN_ID, CHAIN_ID);
        _publishAndBudget(it, 2 * DELIVER);
        bytes32 routeHash = keccak256(abi.encode(it.route));
        _fulfill(it);

        uint256 keeperBefore = tokenA.balanceOf(keeper);
        // Halfway: mul = 1.5x -> pays 150, residual 50 swept to the keeper.
        vm.warp(auctionStart + WINDOW / 2);
        _settle(it, routeHash);
        assertEq(tokenA.balanceOf(claimant1), 150, "1.5x at midpoint");
        assertEq(
            tokenA.balanceOf(keeper),
            keeperBefore + 50,
            "residual swept to keeper"
        );
    }

    function test_afterWindow_floorMultiplier() public {
        Intent memory it = _dutchIntent(CHAIN_ID, CHAIN_ID);
        _publishAndBudget(it, 2 * DELIVER);
        bytes32 routeHash = keccak256(abi.encode(it.route));
        _fulfill(it);

        uint256 keeperBefore = tokenA.balanceOf(keeper);
        // At/after the window end: mul = 1x -> pays 100, residual 100 to the keeper.
        vm.warp(auctionStart + WINDOW);
        _settle(it, routeHash);
        assertEq(tokenA.balanceOf(claimant1), DELIVER, "floor multiplier");
        assertEq(
            tokenA.balanceOf(keeper),
            keeperBefore + DELIVER,
            "residual to keeper"
        );
    }

    // ---------------------------------------------------------------------
    // Single-shot: a second settle reverts (terminal status)
    // ---------------------------------------------------------------------

    function test_singleRelease_secondSettleReverts() public {
        Intent memory it = _dutchIntent(CHAIN_ID, CHAIN_ID);
        _publishAndBudget(it, 2 * DELIVER);
        bytes32 routeHash = keccak256(abi.encode(it.route));
        _fulfill(it);

        _settle(it, routeHash);
        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.InvalidStatusForWithdrawal.selector,
                IIntentSource.Status.Withdrawn
            )
        );
        _settle(it, routeHash);
    }

    // ---------------------------------------------------------------------
    // Cross-chain: relay records the fact, atomic settle pays the decayed reward
    // ---------------------------------------------------------------------

    function test_crossChain_settle() public {
        Intent memory it = _dutchIntent(CHAIN_ID, FOREIGN);
        (bytes32 intentHash, ) = _publishAndBudget(it, 2 * DELIVER);
        bytes32 routeHash = keccak256(abi.encode(it.route));

        uint256[] memory f = new uint256[](1);
        f[0] = DELIVER;
        bytes32 fh = IntentLib.fulfillmentHash(
            intentHash,
            bytes32(uint256(uint160(claimant1))),
            f
        );
        dutch.recordProof(intentHash, FOREIGN, fh);

        _settle(it, routeHash); // at auction start -> 2x
        assertEq(tokenA.balanceOf(claimant1), 2 * DELIVER, "cross-chain peak");
    }
}
