// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BaseTest} from "../BaseTest.sol";
import {StreamingPolicy} from "../../contracts/prover/StreamingPolicy.sol";
import {IStreamingPolicy} from "../../contracts/interfaces/IStreamingPolicy.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {IAccount} from "../../contracts/interfaces/IAccount.sol";
import {Intent, Route, Reward, RewardToken, TokenAmount, IntentLib, WAD} from "../../contracts/types/Intent.sol";
import {Call} from "../../contracts/interfaces/IRuntime.sol";

/**
 * @title StreamingTest
 * @notice End-to-end coverage of the lean streaming model (PR6): re-fulfillable destination record,
 *         batch-hash dispatch + delete, content-addressed source accumulation, preimage settle with
 *         consume+delete, closeStream anti-rug (C2), duplicate-batch no-wedge (M1), no-stranding (H1),
 *         and under-funded recoverability (L1).
 */
contract StreamingTest is BaseTest {
    StreamingPolicy internal stream;

    address internal recipient;
    address internal solver;
    address internal claimant1;
    address internal claimant2;

    uint64 internal constant FOREIGN = 2;
    uint256 internal constant DELIVER = 100;
    uint256 internal constant BUDGET = 1000;

    function setUp() public override {
        super.setUp();
        recipient = makeAddr("streamRecipient");
        solver = makeAddr("streamSolver");
        claimant1 = makeAddr("claimant1");
        claimant2 = makeAddr("claimant2");

        // The StreamingPolicy trusts the Portal (records + consumes + closes) and whitelists this test
        // contract as the cross-chain relay (so it can push bridged batches via recordBatch).
        bytes32[] memory relays = new bytes32[](1);
        relays[0] = bytes32(uint256(uint160(address(this))));
        vm.prank(deployer);
        stream = new StreamingPolicy(address(portal), relays);
    }

    // ---------------------------------------------------------------------
    // Intent construction: solver provides DELIVER tokenB as input, the committed multicall runtime
    // delivers it to `recipient`; reward is a 1:1 rate leg on tokenA (each slice pays
    // `fulfilled * WAD / WAD == fulfilled` tokenA). The tokenA budget is over-funded directly into the
    // account (rate legs are not pre-funded).
    // ---------------------------------------------------------------------

    function _streamIntent(
        uint64 source,
        uint64 destination
    ) internal view returns (Intent memory _intent) {
        TokenAmount[] memory mo = new TokenAmount[](1);
        mo[0] = TokenAmount({token: address(tokenB), amount: DELIVER});

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

        Route memory r = Route({
            salt: keccak256(abi.encodePacked("stream", source, destination)),
            deadline: uint64(expiry),
            portal: address(portal),
            keeper: keeper,
            runtime: address(multicallRuntime),
            payload: abi.encode(c),
            minTokens: mo
        });

        RewardToken[] memory rw = new RewardToken[](1);
        rw[0] = RewardToken({token: address(tokenA), rate: WAD, flat: 0});

        Reward memory rew = Reward({
            deadline: uint64(expiry),
            keeper: keeper,
            prover: address(stream),
            tokens: rw,
            hooks: ""
        });

        _intent = Intent({
            protocolVersion: PROTOCOL_VERSION,
            source: source,
            destination: destination,
            route: r,
            reward: rew
        });
    }

    /// @notice Publishes/funds a streaming intent (rate leg funds 0) and over-funds the account budget.
    function _publishAndBudget(
        Intent memory _intent,
        uint256 budget
    ) internal returns (bytes32 intentHash, address account) {
        vm.prank(keeper);
        (intentHash, account) = intentSource.publishAndFund(_intent, false);
        tokenA.mint(account, budget);
    }

    /// @notice Same-chain fulfill of one slice by `who` naming `claimant`. Returns the measured fulfilled.
    function _fulfillSlice(
        Intent memory _intent,
        address who,
        address slotClaimant
    ) internal returns (uint256[] memory fulfilled) {
        tokenB.mint(who, DELIVER);
        vm.startPrank(who);
        tokenB.approve(address(portal), DELIVER);
        uint256[] memory provided = new uint256[](1);
        provided[0] = DELIVER;
        inbox.fulfill(
            _intent.protocolVersion,
            _intent.source,
            _intent.destination,
            _intent.route,
            _intent.reward,
            bytes32(uint256(uint160(slotClaimant))),
            provided,
            address(stream)
        );
        vm.stopPrank();
        fulfilled = provided;
    }

    function _slice(
        address slotClaimant,
        uint256 amount
    ) internal pure returns (IStreamingPolicy.StreamSlice memory s) {
        uint256[] memory f = new uint256[](1);
        f[0] = amount;
        s = IStreamingPolicy.StreamSlice({
            claimant: bytes32(uint256(uint160(slotClaimant))),
            fulfilled: f
        });
    }

    function _oneBatch(
        uint256 nonce,
        IStreamingPolicy.StreamSlice[] memory slices
    ) internal pure returns (bytes memory) {
        IStreamingPolicy.StreamBatch[]
            memory batches = new IStreamingPolicy.StreamBatch[](1);
        batches[0] = IStreamingPolicy.StreamBatch({nonce: nonce, slices: slices});
        return abi.encode(batches);
    }

    // ---------------------------------------------------------------------
    // SAME-CHAIN streaming end-to-end (multi-slice)
    // ---------------------------------------------------------------------

    function test_sameChain_multiSlice_settlesAllSlices() public {
        Intent memory it = _streamIntent(CHAIN_ID, CHAIN_ID);
        (bytes32 intentHash, address account) = _publishAndBudget(it, BUDGET);
        bytes32 routeHash = keccak256(abi.encode(it.route));

        // Two slices fulfilled by two different solvers to two different claimants.
        _fulfillSlice(it, solver, claimant1);
        _fulfillSlice(it, otherPerson, claimant2);

        // The destination store now holds both slice hashes (re-fulfillable: the 2nd fulfill did not
        // revert).
        assertEq(stream.destSlices(intentHash).length, 2);

        // Settle both slices in one call (same-chain: consumed directly from _destHashes).
        IStreamingPolicy.StreamSlice[]
            memory slices = new IStreamingPolicy.StreamSlice[](2);
        slices[0] = _slice(claimant1, DELIVER);
        slices[1] = _slice(claimant2, DELIVER);

        intentSource.settleStream(
            it.protocolVersion,
            CHAIN_ID,
            CHAIN_ID,
            routeHash,
            it.reward,
            _oneBatch(0, slices)
        );

        assertEq(tokenA.balanceOf(claimant1), DELIVER, "claimant1 paid");
        assertEq(tokenA.balanceOf(claimant2), DELIVER, "claimant2 paid");
        // Store consumed; no residual sweep (budget stays for future slices).
        assertEq(stream.destSlices(intentHash).length, 0, "slices consumed");
        assertEq(tokenA.balanceOf(account), BUDGET - 2 * DELIVER, "residual kept");
        // Re-fulfillable: the intent stays Funded.
        assertEq(
            uint256(intentSource.getRewardStatus(intentHash)),
            uint256(IIntentSource.Status.Funded)
        );
    }

    // ---------------------------------------------------------------------
    // CROSS-CHAIN streaming end-to-end: dest batch -> dispatch -> source accumulate -> settle
    // ---------------------------------------------------------------------

    /// @notice Builds the batchHash exactly as StreamingPolicy.prove would, for the given slices/nonce.
    function _batchHash(
        bytes32 intentHash,
        uint256 nonce,
        IStreamingPolicy.StreamSlice[] memory slices
    ) internal pure returns (bytes32) {
        bytes32[] memory sh = new bytes32[](slices.length);
        for (uint256 i; i < slices.length; ++i) {
            sh[i] = IntentLib.fulfillmentHash(
                intentHash,
                slices[i].claimant,
                slices[i].fulfilled
            );
        }
        return keccak256(abi.encode(intentHash, nonce, sh));
    }

    function test_crossChain_batch_accumulate_settle() public {
        Intent memory it = _streamIntent(CHAIN_ID, FOREIGN);
        (bytes32 intentHash, address account) = _publishAndBudget(it, BUDGET);
        bytes32 routeHash = keccak256(abi.encode(it.route));

        // Simulate the destination batch (fulfilled on FOREIGN): two slices, dispatched as batch nonce 0.
        IStreamingPolicy.StreamSlice[]
            memory slices = new IStreamingPolicy.StreamSlice[](2);
        slices[0] = _slice(claimant1, DELIVER);
        slices[1] = _slice(claimant2, DELIVER);
        bytes32 bh = _batchHash(intentHash, 0, slices);

        // Relay pushes the bridged batch onto the source policy.
        stream.recordBatch(intentHash, FOREIGN, bh);
        assertEq(stream.srcBatches(intentHash).length, 1);

        // Settle the batch: pays both claimants from the SOURCE account.
        intentSource.settleStream(
            it.protocolVersion,
            CHAIN_ID,
            FOREIGN,
            routeHash,
            it.reward,
            _oneBatch(0, slices)
        );

        assertEq(tokenA.balanceOf(claimant1), DELIVER);
        assertEq(tokenA.balanceOf(claimant2), DELIVER);
        assertEq(stream.srcBatches(intentHash).length, 0, "batch consumed");
        assertEq(tokenA.balanceOf(account), BUDGET - 2 * DELIVER);
    }

    // ---------------------------------------------------------------------
    // DESTINATION prove: hashes + deletes _destHashes; monotonic nonce
    // ---------------------------------------------------------------------

    function test_prove_hashesAndDeletesDestStore_monotonicNonce() public {
        // A standalone StreamingPolicy where THIS test acts as the Portal (records) and dispatcher.
        StreamingPolicy dst = new StreamingPolicy(
            address(this),
            new bytes32[](0)
        );
        bytes32 ih = keccak256("some-intent");

        bytes32 sh0 = keccak256("slice0");
        bytes32 sh1 = keccak256("slice1");
        dst.recordFulfillment(ih, FOREIGN, sh0);
        dst.recordFulfillment(ih, FOREIGN, sh1);
        assertEq(dst.destSlices(ih).length, 2);
        assertEq(dst.destBatchNonce(ih), 0);

        bytes32[] memory ihs = new bytes32[](1);
        ihs[0] = ih;
        dst.prove(address(this), 0, ihs, "");

        // Store consumed (deleted); nonce advanced.
        assertEq(dst.destSlices(ih).length, 0, "dest store deleted after prove");
        assertEq(dst.destBatchNonce(ih), 1, "nonce advanced");

        // A fresh fulfill after prove starts a new (empty) batch and the next prove uses nonce 1.
        dst.recordFulfillment(ih, FOREIGN, keccak256("slice2"));
        dst.prove(address(this), 0, ihs, "");
        assertEq(dst.destBatchNonce(ih), 2);
    }

    // ---------------------------------------------------------------------
    // M1: duplicate batch delivery is deduped and never wedges
    // ---------------------------------------------------------------------

    function test_M1_duplicateBatchDelivery_noWedge() public {
        Intent memory it = _streamIntent(CHAIN_ID, FOREIGN);
        (bytes32 intentHash, ) = _publishAndBudget(it, BUDGET);
        bytes32 routeHash = keccak256(abi.encode(it.route));

        IStreamingPolicy.StreamSlice[]
            memory slices = new IStreamingPolicy.StreamSlice[](1);
        slices[0] = _slice(claimant1, DELIVER);
        bytes32 bh = _batchHash(intentHash, 0, slices);

        // Relay delivers the SAME batch twice — the duplicate is skipped.
        stream.recordBatch(intentHash, FOREIGN, bh);
        stream.recordBatch(intentHash, FOREIGN, bh);
        assertEq(stream.srcBatches(intentHash).length, 1, "dedup: one batch");

        // Settle it once; re-delivery afterwards stays deduped (batchSeen permanent) so nothing wedges.
        intentSource.settleStream(
            it.protocolVersion,
            CHAIN_ID,
            FOREIGN,
            routeHash,
            it.reward,
            _oneBatch(0, slices)
        );
        assertEq(tokenA.balanceOf(claimant1), DELIVER);
        assertEq(stream.srcBatches(intentHash).length, 0);

        stream.recordBatch(intentHash, FOREIGN, bh); // re-delivery of settled batch
        assertEq(
            stream.srcBatches(intentHash).length,
            0,
            "settled batch not re-added"
        );
    }

    // ---------------------------------------------------------------------
    // H1: content-addressed batches settle in ANY order with no stranding
    // ---------------------------------------------------------------------

    function test_H1_multiBatch_outOfOrderSettle_noStranding() public {
        Intent memory it = _streamIntent(CHAIN_ID, FOREIGN);
        (bytes32 intentHash, ) = _publishAndBudget(it, BUDGET);
        bytes32 routeHash = keccak256(abi.encode(it.route));

        IStreamingPolicy.StreamSlice[]
            memory s0 = new IStreamingPolicy.StreamSlice[](1);
        s0[0] = _slice(claimant1, DELIVER);
        IStreamingPolicy.StreamSlice[]
            memory s1 = new IStreamingPolicy.StreamSlice[](1);
        s1[0] = _slice(claimant2, DELIVER);

        bytes32 b0 = _batchHash(intentHash, 0, s0);
        bytes32 b1 = _batchHash(intentHash, 1, s1);
        stream.recordBatch(intentHash, FOREIGN, b0);
        stream.recordBatch(intentHash, FOREIGN, b1);
        assertEq(stream.srcBatches(intentHash).length, 2);

        // Settle the SECOND batch first (content-addressed, no FIFO): removes b1 by value, b0 remains.
        intentSource.settleStream(
            it.protocolVersion,
            CHAIN_ID,
            FOREIGN,
            routeHash,
            it.reward,
            _oneBatch(1, s1)
        );
        assertEq(tokenA.balanceOf(claimant2), DELIVER);
        assertEq(stream.srcBatches(intentHash).length, 1, "b0 not stranded");

        // Then settle the first batch.
        intentSource.settleStream(
            it.protocolVersion,
            CHAIN_ID,
            FOREIGN,
            routeHash,
            it.reward,
            _oneBatch(0, s0)
        );
        assertEq(tokenA.balanceOf(claimant1), DELIVER);
        assertEq(stream.srcBatches(intentHash).length, 0);
    }

    // ---------------------------------------------------------------------
    // C2: closeStream cannot rug a proven-but-unsettled batch
    // ---------------------------------------------------------------------

    function test_C2_closeStream_blockedWhileBatchUnsettled_thenAllowed() public {
        Intent memory it = _streamIntent(CHAIN_ID, FOREIGN);
        (bytes32 intentHash, address account) = _publishAndBudget(it, BUDGET);
        bytes32 routeHash = keccak256(abi.encode(it.route));

        IStreamingPolicy.StreamSlice[]
            memory slices = new IStreamingPolicy.StreamSlice[](1);
        slices[0] = _slice(claimant1, DELIVER);
        bytes32 bh = _batchHash(intentHash, 0, slices);
        stream.recordBatch(intentHash, FOREIGN, bh);

        // Keeper's close is BLOCKED while a proven batch is unsettled (anti-rug).
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.PendingProofBlocksClose.selector,
                intentHash
            )
        );
        intentSource.closeStream(it.protocolVersion, CHAIN_ID, FOREIGN, routeHash, it.reward);

        // The batch is settled to the solver's claimant first.
        intentSource.settleStream(
            it.protocolVersion,
            CHAIN_ID,
            FOREIGN,
            routeHash,
            it.reward,
            _oneBatch(0, slices)
        );
        assertEq(tokenA.balanceOf(claimant1), DELIVER);

        // Now the keeper can close and reclaim the remainder.
        uint256 keeperBefore = tokenA.balanceOf(keeper);
        vm.prank(keeper);
        intentSource.closeStream(it.protocolVersion, CHAIN_ID, FOREIGN, routeHash, it.reward);
        assertEq(
            tokenA.balanceOf(keeper),
            keeperBefore + (BUDGET - DELIVER),
            "keeper reclaims remainder"
        );
        assertEq(tokenA.balanceOf(account), 0);
        assertTrue(stream.closed(intentHash), "marked closed");
    }

    function test_C2_closeStream_onlyKeeper() public {
        Intent memory it = _streamIntent(CHAIN_ID, FOREIGN);
        _publishAndBudget(it, BUDGET);
        bytes32 routeHash = keccak256(abi.encode(it.route));

        vm.prank(otherPerson);
        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.NotKeeperCaller.selector,
                otherPerson
            )
        );
        intentSource.closeStream(it.protocolVersion, CHAIN_ID, FOREIGN, routeHash, it.reward);
    }

    // ---------------------------------------------------------------------
    // L1: under-funded settle reverts (atomic); shortfall recoverable after top-up
    // ---------------------------------------------------------------------

    function test_L1_underfunded_reverts_thenRecoverableAfterTopUp() public {
        Intent memory it = _streamIntent(CHAIN_ID, FOREIGN);
        // Budget only covers ONE slice; the batch has TWO.
        (bytes32 intentHash, address account) = _publishAndBudget(it, DELIVER);
        bytes32 routeHash = keccak256(abi.encode(it.route));

        IStreamingPolicy.StreamSlice[]
            memory slices = new IStreamingPolicy.StreamSlice[](2);
        slices[0] = _slice(claimant1, DELIVER);
        slices[1] = _slice(claimant2, DELIVER);
        bytes32 bh = _batchHash(intentHash, 0, slices);
        stream.recordBatch(intentHash, FOREIGN, bh);

        // Under-funded: the second slice can't be paid -> whole settle reverts, batch NOT consumed.
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccount.StreamSlicePayoutExceedsBalance.selector,
                address(tokenA),
                DELIVER,
                0
            )
        );
        intentSource.settleStream(
            it.protocolVersion,
            CHAIN_ID,
            FOREIGN,
            routeHash,
            it.reward,
            _oneBatch(0, slices)
        );
        assertEq(stream.srcBatches(intentHash).length, 1, "batch preserved");
        assertEq(tokenA.balanceOf(claimant1), 0, "nothing paid (atomic)");

        // Keeper tops up; the same batch now settles fully -> shortfall recovered, not forfeited.
        tokenA.mint(account, DELIVER);
        intentSource.settleStream(
            it.protocolVersion,
            CHAIN_ID,
            FOREIGN,
            routeHash,
            it.reward,
            _oneBatch(0, slices)
        );
        assertEq(tokenA.balanceOf(claimant1), DELIVER);
        assertEq(tokenA.balanceOf(claimant2), DELIVER);
        assertEq(stream.srcBatches(intentHash).length, 0);
    }

    // ---------------------------------------------------------------------
    // Wrong preimage / unknown batch reverts
    // ---------------------------------------------------------------------

    function test_settleStream_unknownBatch_reverts() public {
        Intent memory it = _streamIntent(CHAIN_ID, FOREIGN);
        (bytes32 intentHash, ) = _publishAndBudget(it, BUDGET);
        bytes32 routeHash = keccak256(abi.encode(it.route));

        IStreamingPolicy.StreamSlice[]
            memory real = new IStreamingPolicy.StreamSlice[](1);
        real[0] = _slice(claimant1, DELIVER);
        stream.recordBatch(intentHash, FOREIGN, _batchHash(intentHash, 0, real));

        // A settle whose slices/nonce do not reproduce a recorded batch reverts.
        IStreamingPolicy.StreamSlice[]
            memory wrong = new IStreamingPolicy.StreamSlice[](1);
        wrong[0] = _slice(claimant2, DELIVER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStreamingPolicy.UnknownBatch.selector,
                intentHash
            )
        );
        intentSource.settleStream(
            it.protocolVersion,
            CHAIN_ID,
            FOREIGN,
            routeHash,
            it.reward,
            _oneBatch(0, wrong)
        );
    }

    function test_recordBatch_onlyWhitelistedRelay() public {
        bytes32 ih = keccak256("x");
        vm.prank(otherPerson);
        vm.expectRevert();
        stream.recordBatch(ih, FOREIGN, keccak256("b"));
    }
}
