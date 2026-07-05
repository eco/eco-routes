// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseTest} from "../BaseTest.sol";
import {IInbox} from "../../contracts/interfaces/IInbox.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {IPortal} from "../../contracts/interfaces/IPortal.sol";
import {LocalPolicy} from "../../contracts/prover/LocalPolicy.sol";
import {Intent, Route, Reward, RewardToken, TokenAmount, IntentLib} from "../../contracts/types/Intent.sol";
import {Call} from "../../contracts/interfaces/IRuntime.sol";

/**
 * @title SameChainAndGatesTest
 * @notice PR4 tests: reward-conservation postcondition, the source/destination chain gates, the
 *         same-chain first-class {IPortal-fulfillAndSettle}, the destination-side owner-cook
 *         ({Inbox-executeAsOwner}, cross-chain only), and the role-collision attack matrix.
 */
contract SameChainAndGatesTest is BaseTest {
    address internal solver;
    address internal attacker;

    // A same-chain-settling policy (its destination store IS the proof) so fulfillAndSettle can read the
    // just-recorded local fact in-tx.
    LocalPolicy internal localPolicy;

    uint64 internal constant FOREIGN_CHAIN = 2; // a source chain that is NOT this chain

    function setUp() public override {
        super.setUp();
        solver = makeAddr("solver");
        attacker = makeAddr("attacker");

        vm.prank(deployer);
        localPolicy = new LocalPolicy(address(portal));

        // Fund keeper + solver with both tokens and native.
        _mintAndApprove(keeper, MINT_AMOUNT * 10);
        _mintAndApprove(solver, MINT_AMOUNT * 10);
        _fundUserNative(keeper, 100 ether);
        _fundUserNative(solver, 100 ether);

        vm.startPrank(solver);
        tokenA.approve(address(portal), type(uint256).max);
        tokenB.approve(address(portal), type(uint256).max);
        vm.stopPrank();
    }

    // ─────────────────────────────── helpers ───────────────────────────────

    function _noopPayload() internal pure returns (bytes memory) {
        return abi.encode(new Call[](0));
    }

    function _transferPayload(
        address token,
        address to,
        uint256 amount
    ) internal pure returns (bytes memory) {
        Call[] memory c = new Call[](1);
        c[0] = Call({
            target: token,
            data: abi.encodeWithSignature(
                "transfer(address,uint256)",
                to,
                amount
            ),
            value: 0
        });
        return abi.encode(c);
    }

    /// @notice A same-chain intent whose reward is a single flat tokenA leg, no solver input, and whose
    ///         route runs `payload`.
    function _sameChainFlatIntent(
        address prover,
        uint256 flatReward,
        bytes memory payload
    ) internal view returns (Intent memory) {
        RewardToken[] memory legs = new RewardToken[](1);
        legs[0] = RewardToken({token: address(tokenA), rate: 0, flat: flatReward});

        return
            Intent({
                source: uint64(block.chainid),
                destination: uint64(block.chainid),
                route: Route({
                    salt: salt,
                    deadline: uint64(expiry),
                    portal: address(portal),
                    keeper: keeper,
                    runtime: address(multicallRuntime),
                    payload: payload,
                    minTokens: new TokenAmount[](0)
                }),
                reward: Reward({
                    deadline: uint64(expiry),
                    keeper: keeper,
                    prover: prover,
                    tokens: legs
                })
            });
    }

    function _fund(Intent memory _intent) internal {
        vm.prank(keeper);
        intentSource.publishAndFund(_intent, false);
    }

    // ───────────────────────── reward-conservation ─────────────────────────

    function test_conservation_maliciousRuntimeDrainingEscrowReverts() public {
        // Same-chain intent: ONE Account holds both the reward escrow and runs the runtime. A malicious
        // keeper-authored runtime that transfers the escrow token out during execution must make the whole
        // fulfill revert (solver self-DoS), never steal the escrow.
        uint256 rewardFlat = MINT_AMOUNT;
        Intent memory _intent = _sameChainFlatIntent(
            address(localPolicy),
            rewardFlat,
            _transferPayload(address(tokenA), attacker, rewardFlat) // drains the escrow
        );
        _fund(_intent);

        address account = intentSource.intentAccountAddress(_intent);
        assertEq(tokenA.balanceOf(account), rewardFlat); // escrow present

        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(
                IInbox.RewardEscrowTouched.selector,
                address(tokenA),
                0,
                rewardFlat
            )
        );
        portal.fulfill(
            _intent.source,
            _intent.destination,
            _intent.route,
            _intent.reward,
            bytes32(uint256(uint160(solver))),
            _noFulfilled(),
            address(localPolicy)
        );

        // Escrow untouched, attacker got nothing (whole tx reverted).
        assertEq(tokenA.balanceOf(account), rewardFlat);
        assertEq(tokenA.balanceOf(attacker), 0);
    }

    function test_conservation_honestRuntimeWithEscrowPresentPasses() public {
        // An honest no-op runtime leaves the escrow intact -> fulfill succeeds even though the shared
        // Account holds the reward escrow.
        uint256 rewardFlat = MINT_AMOUNT;
        Intent memory _intent = _sameChainFlatIntent(
            address(localPolicy),
            rewardFlat,
            _noopPayload()
        );
        _fund(_intent);
        address account = intentSource.intentAccountAddress(_intent);

        vm.prank(solver);
        portal.fulfill(
            _intent.source,
            _intent.destination,
            _intent.route,
            _intent.reward,
            bytes32(uint256(uint160(solver))),
            _noFulfilled(),
            address(localPolicy)
        );

        // Escrow still intact after fulfill (settle pays it out later).
        assertEq(tokenA.balanceOf(account), rewardFlat);
    }

    // ─────────────────────────── fulfillAndSettle ──────────────────────────

    function test_fulfillAndSettle_sameChain_paysRewardToClaimant() public {
        uint256 rewardFlat = MINT_AMOUNT;
        Intent memory _intent = _sameChainFlatIntent(
            address(localPolicy),
            rewardFlat,
            _noopPayload()
        );
        _fund(_intent);

        uint256 claimantBefore = tokenA.balanceOf(solver);

        vm.prank(solver);
        portal.fulfillAndSettle(
            _intent,
            _noFulfilled(),
            bytes32(uint256(uint160(solver)))
        );

        // Solver (claimant) received the flat reward atomically, no relay.
        assertEq(tokenA.balanceOf(solver), claimantBefore + rewardFlat);
        // Account drained (reward paid, no residual).
        address account = intentSource.intentAccountAddress(_intent);
        assertEq(tokenA.balanceOf(account), 0);
        // Terminal status.
        (bytes32 intentHash, , ) = intentSource.getIntentHash(_intent);
        assertEq(
            uint256(intentSource.getRewardStatus(intentHash)),
            uint256(IIntentSource.Status.Withdrawn)
        );
    }

    function test_fulfillAndSettle_solverSuppliesRouteCapital() public {
        // Realistic same-chain solve: the solver provides the route INPUT capital (tokenB via minTokens),
        // the runtime delivers it to a beneficiary, and the solver is paid the tokenA reward atomically.
        // Capital-EFFICIENT (one tx) but NOT zero-capital (the escrow is conserved, never used to fund the
        // route).
        address beneficiary = makeAddr("beneficiary");
        uint256 deliver = MINT_AMOUNT;
        uint256 rewardFlat = MINT_AMOUNT * 2;

        TokenAmount[] memory minTokensIn = new TokenAmount[](1);
        minTokensIn[0] = TokenAmount({token: address(tokenB), amount: deliver});
        RewardToken[] memory legs = new RewardToken[](1);
        legs[0] = RewardToken({token: address(tokenA), rate: 0, flat: rewardFlat});

        Intent memory _intent = Intent({
            source: uint64(block.chainid),
            destination: uint64(block.chainid),
            route: Route({
                salt: salt,
                deadline: uint64(expiry),
                portal: address(portal),
                keeper: keeper,
                runtime: address(multicallRuntime),
                payload: _transferPayload(address(tokenB), beneficiary, deliver),
                minTokens: minTokensIn
            }),
            reward: Reward({
                deadline: uint64(expiry),
                keeper: keeper,
                prover: address(localPolicy),
                tokens: legs
            })
        });
        _fund(_intent);

        uint256 beneficiaryBBefore = tokenB.balanceOf(beneficiary);
        uint256 solverABefore = tokenA.balanceOf(solver);
        uint256 solverBBefore = tokenB.balanceOf(solver);

        uint256[] memory provided = new uint256[](1);
        provided[0] = deliver;

        vm.prank(solver);
        portal.fulfillAndSettle(
            _intent,
            provided,
            bytes32(uint256(uint160(solver)))
        );

        // Beneficiary got the delivered tokenB; solver spent tokenB capital and received the tokenA reward.
        assertEq(tokenB.balanceOf(beneficiary), beneficiaryBBefore + deliver);
        assertEq(tokenB.balanceOf(solver), solverBBefore - deliver);
        assertEq(tokenA.balanceOf(solver), solverABefore + rewardFlat);
    }

    function test_fulfillAndSettle_revertsForCrossChainIntent() public {
        Intent memory _intent = _sameChainFlatIntent(
            address(localPolicy),
            MINT_AMOUNT,
            _noopPayload()
        );
        _intent.source = FOREIGN_CHAIN; // source != destination => not same-chain

        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPortal.NotSameChain.selector,
                FOREIGN_CHAIN,
                uint64(block.chainid),
                uint64(block.chainid)
            )
        );
        portal.fulfillAndSettle(
            _intent,
            _noFulfilled(),
            bytes32(uint256(uint160(solver)))
        );
    }

    // ─────────────────────────── source-chain gate ─────────────────────────

    function _crossChainIntent() internal view returns (Intent memory) {
        // A cross-chain intent whose SOURCE is foreign and whose DESTINATION is this chain.
        Intent memory _intent = _sameChainFlatIntent(
            address(prover),
            MINT_AMOUNT,
            _noopPayload()
        );
        _intent.source = FOREIGN_CHAIN;
        return _intent;
    }

    function test_gate_fund_revertsOnWrongSourceChain() public {
        Intent memory _intent = _crossChainIntent();
        (, bytes32 routeHash, ) = intentSource.getIntentHash(_intent);

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.WrongSourceChain.selector,
                uint64(block.chainid),
                FOREIGN_CHAIN
            )
        );
        intentSource.fund(
            _intent.source,
            _intent.destination,
            routeHash,
            _intent.reward,
            false
        );
    }

    function test_gate_publishAndFund_revertsOnWrongSourceChain() public {
        Intent memory _intent = _crossChainIntent();
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.WrongSourceChain.selector,
                uint64(block.chainid),
                FOREIGN_CHAIN
            )
        );
        intentSource.publishAndFund(_intent, false);
    }

    function test_gate_settle_revertsOnWrongSourceChain() public {
        Intent memory _intent = _crossChainIntent();
        (, bytes32 routeHash, ) = intentSource.getIntentHash(_intent);

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.WrongSourceChain.selector,
                uint64(block.chainid),
                FOREIGN_CHAIN
            )
        );
        intentSource.settle(
            _intent.source,
            _intent.destination,
            routeHash,
            _intent.reward,
            bytes32(uint256(uint160(claimant))),
            _noFulfilled()
        );
    }

    function test_gate_refund_revertsOnWrongSourceChain() public {
        Intent memory _intent = _crossChainIntent();
        (, bytes32 routeHash, ) = intentSource.getIntentHash(_intent);

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.WrongSourceChain.selector,
                uint64(block.chainid),
                FOREIGN_CHAIN
            )
        );
        intentSource.refund(
            _intent.source,
            _intent.destination,
            routeHash,
            _intent.reward
        );
    }

    function test_gate_recoverToken_revertsOnWrongSourceChain() public {
        Intent memory _intent = _crossChainIntent();
        (, bytes32 routeHash, ) = intentSource.getIntentHash(_intent);

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.WrongSourceChain.selector,
                uint64(block.chainid),
                FOREIGN_CHAIN
            )
        );
        intentSource.recoverToken(
            _intent.source,
            _intent.destination,
            routeHash,
            _intent.reward,
            address(tokenB)
        );
    }

    function test_gate_executeAsOwner_revertsOnWrongSourceChain() public {
        Intent memory _intent = _crossChainIntent();

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.WrongSourceChain.selector,
                uint64(block.chainid),
                FOREIGN_CHAIN
            )
        );
        intentSource.executeAsOwner(
            _intent,
            address(multicallRuntime),
            _noopPayload()
        );
    }

    // ──────────────────────── destination-chain gate ───────────────────────

    function test_gate_fulfill_revertsOnWrongDestinationChain() public {
        Intent memory _intent = _sameChainFlatIntent(
            address(prover),
            0,
            _noopPayload()
        );
        uint64 wrongDestination = uint64(block.chainid) + 1;

        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(
                IInbox.WrongDestinationChain.selector,
                uint64(block.chainid),
                wrongDestination
            )
        );
        portal.fulfill(
            _intent.source,
            wrongDestination,
            _intent.route,
            _intent.reward,
            bytes32(uint256(uint160(solver))),
            _noFulfilled(),
            address(prover)
        );
    }

    // ─────────────────── destination executeAsOwner (cross-chain) ───────────

    function test_executeAsOwner_dest_keeperRecoversStrayToken() public {
        // A cross-chain intent's DESTINATION account holds a stray (non-escrow) token. The destination
        // owner (route.keeper) cooks it out via the runtime. Cross-chain => the dest account is a distinct
        // address that never holds escrow, so an arbitrary runtime is safe here.
        Intent memory _intent = _crossChainIntent(); // source foreign, dest = this chain
        (bytes32 intentHash, , bytes32 rewardHash) = intentSource.getIntentHash(
            _intent
        );
        address destAccount = portal.accountAddress(
            intentHash,
            _intent.destination
        );

        // Force a stray token (tokenB) into the destination account.
        tokenB.mint(destAccount, MINT_AMOUNT);

        uint256 keeperBefore = tokenB.balanceOf(keeper);

        vm.prank(keeper);
        portal.executeAsOwner(
            _intent.source,
            _intent.route,
            rewardHash,
            address(multicallRuntime),
            _transferPayload(address(tokenB), keeper, MINT_AMOUNT)
        );

        assertEq(tokenB.balanceOf(keeper), keeperBefore + MINT_AMOUNT);
        assertEq(tokenB.balanceOf(destAccount), 0);
    }

    function test_executeAsOwner_dest_revertsForSameChain() public {
        // Same-chain intent: the block.chainid-keyed account is (or collapses with) the SOURCE escrow
        // account, so the reward-blind destination path is rejected — use the source executeAsOwner.
        Intent memory _intent = _sameChainFlatIntent(
            address(prover),
            MINT_AMOUNT,
            _noopPayload()
        );
        (, , bytes32 rewardHash) = intentSource.getIntentHash(_intent);

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                IInbox.SourceChainOwnerOnly.selector,
                uint64(block.chainid)
            )
        );
        portal.executeAsOwner(
            _intent.source, // == block.chainid (same-chain)
            _intent.route,
            rewardHash,
            address(multicallRuntime),
            _noopPayload()
        );
    }

    function test_executeAsOwner_dest_revertsForNonKeeper() public {
        Intent memory _intent = _crossChainIntent();
        (, , bytes32 rewardHash) = intentSource.getIntentHash(_intent);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IInbox.NotAccountKeeper.selector,
                attacker
            )
        );
        portal.executeAsOwner(
            _intent.source,
            _intent.route,
            rewardHash,
            address(multicallRuntime),
            _noopPayload()
        );
    }

    // ───────────────────── role-collision attack matrix ─────────────────────

    // (a) An A->B intent fulfilled on B: an attacker running a source-side op on B for that intent cannot
    //     reach the destination account's leftovers — the source op reverts on the WrongSourceChain gate
    //     (and would otherwise resolve the empty source-account address, never the destination account).
    function test_Qa_sourceOpOnDestChainCannotReachDestVault() public {
        Intent memory _intent = _crossChainIntent(); // source = A (foreign), destination = B (this chain)
        (bytes32 intentHash, bytes32 routeHash, ) = intentSource.getIntentHash(
            _intent
        );

        // The DESTINATION account (keyed by destination) is distinct from the source escrow account
        // (keyed by source).
        address destAccount = portal.accountAddress(
            intentHash,
            _intent.destination
        );
        address srcAccount = portal.accountAddress(intentHash, _intent.source);
        assertTrue(destAccount != srcAccount);

        // The attacker tries every source-side op on B for this intent -> all revert WrongSourceChain,
        // so none can operate on the destination account.
        bytes memory wrongSource = abi.encodeWithSelector(
            IIntentSource.WrongSourceChain.selector,
            uint64(block.chainid),
            FOREIGN_CHAIN
        );
        vm.startPrank(attacker);
        vm.expectRevert(wrongSource);
        intentSource.settle(
            _intent.source,
            _intent.destination,
            routeHash,
            _intent.reward,
            bytes32(uint256(uint160(attacker))),
            _noFulfilled()
        );
        vm.expectRevert(wrongSource);
        intentSource.refund(
            _intent.source,
            _intent.destination,
            routeHash,
            _intent.reward
        );
        vm.expectRevert(wrongSource);
        intentSource.recoverToken(
            _intent.source,
            _intent.destination,
            routeHash,
            _intent.reward,
            address(tokenB)
        );
        vm.stopPrank();
    }

    // (b) A fund-before-fulfill race on B does not let a later refund/settle drain destination funds: on B
    //     (the destination chain) you cannot even FUND a cross-chain intent (fund is source-gated), and a
    //     later refund is source-gated too.
    function test_Qb_fundThenRefundOnDestChainReverts() public {
        Intent memory _intent = _crossChainIntent();
        (, bytes32 routeHash, ) = intentSource.getIntentHash(_intent);

        bytes memory wrongSource = abi.encodeWithSelector(
            IIntentSource.WrongSourceChain.selector,
            uint64(block.chainid),
            FOREIGN_CHAIN
        );
        vm.startPrank(attacker);
        vm.expectRevert(wrongSource);
        intentSource.fund(
            _intent.source,
            _intent.destination,
            routeHash,
            _intent.reward,
            false
        );
        vm.expectRevert(wrongSource);
        intentSource.refund(
            _intent.source,
            _intent.destination,
            routeHash,
            _intent.reward
        );
        vm.stopPrank();
    }

    // (c) The honest same-chain B->B lifecycle (fund, then fulfillAndSettle) works end-to-end, including
    //     the reward-conservation postcondition on the shared account.
    function test_Qc_honestSameChainLifecycle() public {
        uint256 rewardFlat = MINT_AMOUNT;
        Intent memory _intent = _sameChainFlatIntent(
            address(localPolicy),
            rewardFlat,
            _noopPayload()
        );
        _fund(_intent);
        assertTrue(intentSource.isIntentFunded(_intent));

        uint256 before = tokenA.balanceOf(solver);
        vm.prank(solver);
        portal.fulfillAndSettle(
            _intent,
            _noFulfilled(),
            bytes32(uint256(uint160(solver)))
        );
        assertEq(tokenA.balanceOf(solver), before + rewardFlat);
    }

    // (d) The same route+reward opened from two different source chains has DIFFERENT intent hashes
    //     (source is in the hash) and DIFFERENT escrow account addresses, so a fulfillment for one can
    //     never double-claim the other.
    function test_Qd_sourceInHashSeparatesTwoOrigins() public view {
        Intent memory a = _crossChainIntent();
        a.source = 2;
        Intent memory b = _crossChainIntent();
        b.source = 3;

        (bytes32 hashA, , ) = intentSource.getIntentHash(a);
        (bytes32 hashB, , ) = intentSource.getIntentHash(b);
        assertTrue(hashA != hashB);

        // Escrow accounts (keyed by source) also differ.
        address accountA = portal.accountAddress(hashA, a.source);
        address accountB = portal.accountAddress(hashB, b.source);
        assertTrue(accountA != accountB);
    }
}
