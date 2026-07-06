// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BaseTest} from "../BaseTest.sol";
import {StreamingPolicy} from "../../contracts/prover/StreamingPolicy.sol";
import {IStreamingPolicy} from "../../contracts/interfaces/IStreamingPolicy.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {IAccount} from "../../contracts/interfaces/IAccount.sol";
import {StandingDepositAddress_USDCTransfer_Solana} from "../../contracts/deposit/StandingDepositAddress_USDCTransfer_Solana.sol";
import {StandingDepositFactory_USDCTransfer_Solana} from "../../contracts/deposit/StandingDepositFactory_USDCTransfer_Solana.sol";
import {StandingDepositAddress} from "../../contracts/deposit/StandingDepositAddress.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";
import {Reward, IntentLib, WAD} from "../../contracts/types/Intent.sol";

/**
 * @title StandingDepositAddress_USDCTransfer_SolanaTest
 * @notice PR12 standing cross-chain streaming deposit for USDC -> Solana: deterministic standing publish,
 *         direct-transfer pool growth, settle via a simulated whitelisted relay (recordBatch) + StreamBatch
 *         preimage paying `fulfilled * rate / WAD`, L1 under-funded recoverability, keeper closeStream, and
 *         salt-epoch reopen — with money conservation.
 */
contract StandingDepositAddress_USDCTransfer_SolanaTest is BaseTest {
    StreamingPolicy internal stream;
    StandingDepositFactory_USDCTransfer_Solana internal factory;

    uint64 internal constant SOLANA = 1399811149;
    uint256 internal constant REWARD_RATE = 1.001e18; // 10 bps spread
    bytes32 internal constant DEST_TOKEN = bytes32(uint256(0xABCD));
    bytes32 internal constant DEST_PORTAL = bytes32(uint256(0xBEEF));
    bytes32 internal constant PORTAL_PDA = bytes32(uint256(0xCAFE));
    bytes32 internal constant EXECUTOR_ATA = bytes32(uint256(0xF00D));

    bytes32 internal userATA; // Solana recipient ATA
    address internal solverClaimant; // solver's EVM payout address

    function setUp() public override {
        super.setUp();
        userATA = keccak256("userATA");
        solverClaimant = makeAddr("solanaSolver");

        // StreamingPolicy trusting the Portal, whitelisting THIS test as the cross-chain relay.
        bytes32[] memory relays = new bytes32[](1);
        relays[0] = bytes32(uint256(uint160(address(this))));
        vm.prank(deployer);
        stream = new StreamingPolicy(address(portal), relays);

        factory = new StandingDepositFactory_USDCTransfer_Solana(
            address(tokenA),
            DEST_TOKEN,
            address(portal),
            address(stream),
            DEST_PORTAL,
            PORTAL_PDA,
            EXECUTOR_ATA,
            PROTOCOL_VERSION,
            REWARD_RATE
        );
    }

    function _clone()
        internal
        returns (StandingDepositAddress_USDCTransfer_Solana c)
    {
        c = StandingDepositAddress_USDCTransfer_Solana(
            factory.deploy(userATA, keeper)
        );
    }

    function _ih(
        StandingDepositAddress_USDCTransfer_Solana c
    ) internal view returns (bytes32) {
        (
            uint32 pv,
            uint64 source,
            uint64 destination,
            bytes32 routeHash,
            Reward memory reward
        ) = c.getStandingIntent();
        return
            IntentLib.hashIntent(
                pv,
                source,
                destination,
                routeHash,
                keccak256(abi.encode(reward))
            );
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

    // -----------------------------------------------------------------------
    // Standing publish deterministic + timestamp-independent + config threading
    // -----------------------------------------------------------------------

    function test_openStream_deterministic_timestampIndependent() public {
        StandingDepositAddress_USDCTransfer_Solana c = _clone();

        (bytes32 ihA, address poolA) = c.openStream();
        (
            uint32 pv,
            uint64 source,
            uint64 destination,
            ,
            Reward memory reward
        ) = c.getStandingIntent();
        assertEq(pv, PROTOCOL_VERSION, "protocolVersion threaded");
        assertEq(source, CHAIN_ID);
        assertEq(destination, SOLANA);
        assertEq(reward.deadline, type(uint64).max, "deadline max");
        assertEq(reward.prover, address(stream));
        assertEq(reward.tokens.length, 1);
        assertEq(reward.tokens[0].token, address(tokenA));
        assertEq(reward.tokens[0].rate, REWARD_RATE);
        assertEq(reward.tokens[0].flat, 0, "pure rate leg");

        // Warp; a second call must return the SAME hash + pool (no block.timestamp in the route salt).
        vm.warp(block.timestamp + 9999);
        (bytes32 ihB, address poolB) = c.openStream();
        assertEq(ihA, ihB, "intentHash stable across time");
        assertEq(poolA, poolB, "pool stable across time");
        assertEq(
            uint256(intentSource.getRewardStatus(ihA)),
            uint256(IIntentSource.Status.Funded),
            "funded with zero pull (rate-only leg)"
        );
    }

    // -----------------------------------------------------------------------
    // Deposit = direct transfer grows the pool; fund() is a no-op once Funded
    // -----------------------------------------------------------------------

    function test_deposit_directTransfer_growsPool() public {
        StandingDepositAddress_USDCTransfer_Solana c = _clone();
        (bytes32 ih, address pool) = c.openStream();

        // Deposit via the clone + sweep, and via a direct transfer straight to the pool.
        tokenA.mint(address(c), 3000);
        c.sweep();
        assertEq(tokenA.balanceOf(pool), 3000);
        tokenA.mint(pool, 2000); // direct transfer top-up
        assertEq(tokenA.balanceOf(pool), 5000, "pool accumulates");

        // A big deposit (> uint64.max) is fine — no per-deposit u64 AmountTooLarge guard anymore.
        uint256 huge = uint256(type(uint64).max) + 1;
        tokenA.mint(address(c), huge);
        c.sweep();
        assertEq(tokenA.balanceOf(pool), 5000 + huge, "no u64 cap on deposits");

        assertEq(
            uint256(intentSource.getRewardStatus(ih)),
            uint256(IIntentSource.Status.Funded)
        );
    }

    // -----------------------------------------------------------------------
    // Cross-chain settle via simulated relay + preimage
    // -----------------------------------------------------------------------

    function test_settle_crossChain_paysRateSpread_conserved() public {
        StandingDepositAddress_USDCTransfer_Solana c = _clone();
        (bytes32 ih, address pool) = c.openStream();
        (, , , bytes32 routeHash, Reward memory reward) = c.getStandingIntent();

        tokenA.mint(pool, 5000);

        uint256 f = 1000;
        uint256 payout = (f * REWARD_RATE) / WAD; // 1001
        IStreamingPolicy.StreamSlice[]
            memory slices = new IStreamingPolicy.StreamSlice[](1);
        slices[0] = _slice(solverClaimant, f);

        // Relay bridges the Solana-proven batch commitment.
        stream.recordBatch(ih, SOLANA, _batchHash(ih, 0, slices));
        assertEq(stream.srcBatches(ih).length, 1);

        // Mismatched preimage reverts.
        IStreamingPolicy.StreamSlice[]
            memory wrong = new IStreamingPolicy.StreamSlice[](1);
        wrong[0] = _slice(solverClaimant, f + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IStreamingPolicy.UnknownBatch.selector, ih)
        );
        intentSource.settleStream(
            PROTOCOL_VERSION,
            CHAIN_ID,
            SOLANA,
            routeHash,
            reward,
            _oneBatch(0, wrong)
        );

        uint256 poolBefore = tokenA.balanceOf(pool);
        intentSource.settleStream(
            PROTOCOL_VERSION,
            CHAIN_ID,
            SOLANA,
            routeHash,
            reward,
            _oneBatch(0, slices)
        );

        assertEq(tokenA.balanceOf(solverClaimant), payout, "paid f*rate/WAD");
        assertEq(tokenA.balanceOf(pool), poolBefore - payout, "residual kept");
        assertEq(stream.srcBatches(ih).length, 0, "batch consumed");
        assertEq(
            uint256(intentSource.getRewardStatus(ih)),
            uint256(IIntentSource.Status.Funded),
            "stays Funded (re-fulfillable)"
        );
        // Conservation: pool + claimant unchanged in aggregate.
        assertEq(
            tokenA.balanceOf(pool) + tokenA.balanceOf(solverClaimant),
            5000,
            "tokenA conserved"
        );
    }

    // -----------------------------------------------------------------------
    // L1: over-large batch reverts, then settles after a top-up (recoverable)
    // -----------------------------------------------------------------------

    function test_settle_overLargeBatch_revertsThenSettlesAfterTopUp() public {
        StandingDepositAddress_USDCTransfer_Solana c = _clone();
        (bytes32 ih, address pool) = c.openStream();
        (, , , bytes32 routeHash, Reward memory reward) = c.getStandingIntent();

        tokenA.mint(pool, 1500);

        uint256 f = 1000;
        uint256 payout = (f * REWARD_RATE) / WAD; // 1001
        IStreamingPolicy.StreamSlice[]
            memory slices = new IStreamingPolicy.StreamSlice[](2);
        slices[0] = _slice(solverClaimant, f);
        slices[1] = _slice(makeAddr("solver2"), f);
        stream.recordBatch(ih, SOLANA, _batchHash(ih, 0, slices));

        // Second slice can't be paid from the remaining 499 -> whole settle reverts, batch preserved.
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccount.StreamSlicePayoutExceedsBalance.selector,
                address(tokenA),
                payout,
                1500 - payout
            )
        );
        intentSource.settleStream(
            PROTOCOL_VERSION,
            CHAIN_ID,
            SOLANA,
            routeHash,
            reward,
            _oneBatch(0, slices)
        );
        assertEq(stream.srcBatches(ih).length, 1, "batch preserved");
        assertEq(tokenA.balanceOf(solverClaimant), 0, "nothing paid (atomic)");

        // Top up; the same batch now settles fully.
        tokenA.mint(pool, 1000);
        intentSource.settleStream(
            PROTOCOL_VERSION,
            CHAIN_ID,
            SOLANA,
            routeHash,
            reward,
            _oneBatch(0, slices)
        );
        assertEq(tokenA.balanceOf(solverClaimant), payout);
        assertEq(tokenA.balanceOf(makeAddr("solver2")), payout);
        assertEq(stream.srcBatches(ih).length, 0);
    }

    // -----------------------------------------------------------------------
    // closeStream keeper exit; blocked while a batch is unsettled (C2)
    // -----------------------------------------------------------------------

    function test_closeStream_keeperExit_blockedWhileUnsettled() public {
        StandingDepositAddress_USDCTransfer_Solana c = _clone();
        (bytes32 ih, address pool) = c.openStream();
        (, , , bytes32 routeHash, Reward memory reward) = c.getStandingIntent();
        tokenA.mint(pool, 5000);

        IStreamingPolicy.StreamSlice[]
            memory slices = new IStreamingPolicy.StreamSlice[](1);
        slices[0] = _slice(solverClaimant, 1000);
        stream.recordBatch(ih, SOLANA, _batchHash(ih, 0, slices));

        // Blocked while unsettled (C2 anti-rug).
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.PendingProofBlocksClose.selector,
                ih
            )
        );
        intentSource.closeStream(PROTOCOL_VERSION, CHAIN_ID, SOLANA, routeHash, reward);

        // Settle, then close: keeper reclaims the remainder.
        intentSource.settleStream(
            PROTOCOL_VERSION,
            CHAIN_ID,
            SOLANA,
            routeHash,
            reward,
            _oneBatch(0, slices)
        );
        uint256 remainder = tokenA.balanceOf(pool);
        vm.prank(keeper);
        intentSource.closeStream(PROTOCOL_VERSION, CHAIN_ID, SOLANA, routeHash, reward);
        assertEq(tokenA.balanceOf(keeper), remainder, "keeper reclaims remainder");
        assertEq(tokenA.balanceOf(pool), 0);
        assertTrue(stream.closed(ih));
        assertEq(
            uint256(intentSource.getRewardStatus(ih)),
            uint256(IIntentSource.Status.Refunded)
        );
    }

    // -----------------------------------------------------------------------
    // Salt-epoch reopen
    // -----------------------------------------------------------------------

    function test_reopen_epochRotation() public {
        StandingDepositAddress_USDCTransfer_Solana c = _clone();
        (bytes32 ih0, address pool0) = c.openStream();
        (, , , bytes32 routeHash, Reward memory reward) = c.getStandingIntent();
        tokenA.mint(pool0, 1000);

        // reopen before close reverts.
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                StandingDepositAddress.EpochNotClosed.selector,
                ih0
            )
        );
        c.reopen();

        // non-keeper reopen reverts.
        vm.prank(otherPerson);
        vm.expectRevert(StandingDepositAddress.NotKeeper.selector);
        c.reopen();

        // Close the current epoch's stream.
        vm.prank(keeper);
        intentSource.closeStream(PROTOCOL_VERSION, CHAIN_ID, SOLANA, routeHash, reward);
        assertEq(
            uint256(intentSource.getRewardStatus(ih0)),
            uint256(IIntentSource.Status.Refunded)
        );

        // Re-publishing the old (Refunded) hash is rejected.
        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.IntentAlreadyExists.selector,
                ih0
            )
        );
        c.openStream();

        // reopen bumps the epoch and republishes under a NEW hash + pool.
        vm.prank(keeper);
        c.reopen();
        assertEq(c.epoch(), 1);
        bytes32 ih1 = _ih(c);
        assertTrue(ih1 != ih0, "new epoch => new hash");
        assertEq(
            uint256(intentSource.getRewardStatus(ih1)),
            uint256(IIntentSource.Status.Funded),
            "new pool funded"
        );

        // The new pool is a fresh address (per-epoch) and accepts deposits.
        address pool1 = c.poolAccount();
        assertTrue(pool1 != pool0, "new epoch => new pool address");
        tokenA.mint(pool1, 2000);
        assertEq(tokenA.balanceOf(pool1), 2000, "new pool accepts deposits");
    }
}
