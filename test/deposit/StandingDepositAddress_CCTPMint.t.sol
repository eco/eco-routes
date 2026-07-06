// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "../BaseTest.sol";
import {StreamingFlashPolicy} from "../../contracts/prover/StreamingFlashPolicy.sol";
import {IStreamingFlashPolicy} from "../../contracts/interfaces/IStreamingFlashPolicy.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {CCTPBurnRuntime} from "../../contracts/runtime/CCTPBurnRuntime.sol";
import {GatewayDepositRuntime} from "../../contracts/runtime/GatewayDepositRuntime.sol";
import {StandingDepositAddress_CCTPMint} from "../../contracts/deposit/StandingDepositAddress_CCTPMint.sol";
import {StandingDepositFactory_CCTPMint_Arc} from "../../contracts/deposit/StandingDepositFactory_CCTPMint_Arc.sol";
import {StandingDepositFactory_CCTPMint_GatewayERC20} from "../../contracts/deposit/StandingDepositFactory_CCTPMint_GatewayERC20.sol";
import {StandingDepositAddress} from "../../contracts/deposit/StandingDepositAddress.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";
import {Intent, WAD} from "../../contracts/types/Intent.sol";

// ---------------------------------------------------------------------------
// Mocks + delegatecall harness
// ---------------------------------------------------------------------------

/// @notice Mock CCTP v2 TokenMessenger: pulls the burn amount (so the Account is drained) + records args.
contract MockTokenMessengerV2 {
    uint256 public lastAmount;
    uint32 public lastDomain;
    bytes32 public lastMintRecipient;
    address public lastBurnToken;
    uint256 public lastMaxFee;
    uint256 public burnCount;

    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32,
        uint256 maxFee,
        uint32
    ) external {
        IERC20(burnToken).transferFrom(msg.sender, address(this), amount);
        lastAmount = amount;
        lastDomain = destinationDomain;
        lastMintRecipient = mintRecipient;
        lastBurnToken = burnToken;
        lastMaxFee = maxFee;
        burnCount += 1;
    }
}

/// @notice Mock Gateway: pulls the deposit (Account drained) + records the credited recipient/amount.
contract MockGatewayPull {
    address public lastToken;
    address public lastRecipient;
    uint256 public lastAmount;
    uint256 public depositCount;

    function depositFor(address token, address recipient, uint256 amount) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        lastToken = token;
        lastRecipient = recipient;
        lastAmount = amount;
        depositCount += 1;
    }
}

/// @notice Minimal delegatecall harness (stands in for an {Account}) for balance-reading runtime units.
contract RuntimeHarness {
    function run(address runtime, bytes calldata payload) external payable {
        (bool ok, bytes memory ret) = runtime.delegatecall(payload);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    receive() external payable {}
}

/**
 * @title StandingDepositAddress_CCTPMintTest
 * @notice PR12 standing CCTP + Gateway deposit migration: the two balance-reading runtimes as delegatecall
 *         units, intent-1 CCTP-burn flash pool (direct mode, zero solver capital), intent-2 Gateway flash
 *         pool on a simulated Arc, the fee-as-rate model, standing-hash stability, closeStream/reopen epoch
 *         rotation, and poison protection — with money conservation on every lifecycle test.
 */
contract StandingDepositAddress_CCTPMintTest is BaseTest {
    StreamingFlashPolicy internal flash;
    GatewayDepositRuntime internal gatewayRuntime;
    CCTPBurnRuntime internal cctpRuntime; // standalone (for unit)
    MockTokenMessengerV2 internal messenger;
    MockGatewayPull internal gateway;

    address internal user; // destination recipient
    address internal solver; // flash claimant

    uint256 internal constant FLOOR = 100;
    uint32 internal constant DEST_DOMAIN = 6;
    uint256 internal constant MAX_FEE_BPS = 13; // 1.3 bps
    uint256 internal constant FEE_DENOMINATOR = 100_000;

    function setUp() public override {
        super.setUp();
        user = makeAddr("cctpUser");
        solver = makeAddr("cctpSolver");

        vm.startPrank(deployer);
        flash = new StreamingFlashPolicy(address(portal));
        gatewayRuntime = new GatewayDepositRuntime();
        cctpRuntime = new CCTPBurnRuntime();
        vm.stopPrank();

        messenger = new MockTokenMessengerV2();
        gateway = new MockGatewayPull();
    }

    // -----------------------------------------------------------------------
    // Factory helpers (source token == tokenA; destination "arcUsdc" == tokenB)
    // -----------------------------------------------------------------------

    function _arcFactory()
        internal
        returns (StandingDepositFactory_CCTPMint_Arc f)
    {
        f = new StandingDepositFactory_CCTPMint_Arc(
            address(tokenA), // source USDC
            address(portal),
            PROTOCOL_VERSION,
            address(flash),
            address(gatewayRuntime),
            CHAIN_ID, // arcChainId == block.chainid (simulated Arc)
            DEST_DOMAIN,
            address(messenger),
            address(tokenB), // arcUsdc (6-dec ERC20)
            address(gateway),
            FLOOR,
            FLOOR,
            MAX_FEE_BPS
        );
    }

    function _gwFactory(
        uint256 protocolFeeBps
    ) internal returns (StandingDepositFactory_CCTPMint_GatewayERC20 f) {
        f = new StandingDepositFactory_CCTPMint_GatewayERC20(
            address(tokenA),
            address(portal),
            PROTOCOL_VERSION,
            address(flash),
            address(gatewayRuntime),
            CHAIN_ID,
            DEST_DOMAIN,
            address(messenger),
            address(tokenB),
            address(gateway),
            FLOOR,
            FLOOR,
            MAX_FEE_BPS,
            protocolFeeBps
        );
    }

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _sliceIntent1(
        StandingDepositAddress_CCTPMint clone,
        address claimant
    ) internal {
        (Intent memory i1, ) = clone.getStandingIntents();
        vm.prank(solver);
        flash.flashSlice(PROTOCOL_VERSION, i1.route, i1.reward, _b32(claimant), "");
    }

    function _sliceIntent2(
        StandingDepositAddress_CCTPMint clone,
        address claimant
    ) internal {
        (, Intent memory i2) = clone.getStandingIntents();
        vm.prank(solver);
        flash.flashSlice(PROTOCOL_VERSION, i2.route, i2.reward, _b32(claimant), "");
    }

    // -----------------------------------------------------------------------
    // Runtime units
    // -----------------------------------------------------------------------

    function test_cctpBurnRuntime_unit_readsBalance_burnsAndDrains() public {
        RuntimeHarness harness = new RuntimeHarness();
        uint256 x = 1_000_000;
        tokenA.mint(address(harness), x);

        bytes32 mintRecipient = keccak256("account2");
        harness.run(
            address(cctpRuntime),
            abi.encode(
                address(tokenA),
                address(messenger),
                DEST_DOMAIN,
                mintRecipient,
                MAX_FEE_BPS
            )
        );

        uint256 expectedMaxFee = (x * MAX_FEE_BPS + FEE_DENOMINATOR - 1) /
            FEE_DENOMINATOR;
        assertEq(messenger.lastAmount(), x, "burned whole balance");
        assertEq(messenger.lastMaxFee(), expectedMaxFee, "maxFee = ceil(x*bps)");
        assertEq(messenger.lastMintRecipient(), mintRecipient, "mintRecipient");
        assertEq(messenger.lastDomain(), DEST_DOMAIN);
        assertEq(tokenA.balanceOf(address(harness)), 0, "Account drained");
        assertEq(tokenA.balanceOf(address(messenger)), x);
    }

    function test_gatewayDepositRuntime_unit_readsBalance_depositsAndDrains()
        public
    {
        RuntimeHarness harness = new RuntimeHarness();
        uint256 x = 500;
        tokenB.mint(address(harness), x);

        harness.run(
            address(gatewayRuntime),
            abi.encode(address(tokenB), address(gateway), user)
        );

        assertEq(gateway.lastToken(), address(tokenB));
        assertEq(gateway.lastRecipient(), user, "user credited");
        assertEq(gateway.lastAmount(), x);
        assertEq(tokenB.balanceOf(address(harness)), 0, "Account drained");
        assertEq(tokenB.balanceOf(address(gateway)), x);
    }

    // -----------------------------------------------------------------------
    // Intent 1: CCTP-burn flash pool (direct mode, zero solver capital)
    // -----------------------------------------------------------------------

    function test_intent1_flashSlice_directMode_burnsToAccount2_zeroCapital()
        public
    {
        StandingDepositFactory_CCTPMint_Arc f = _arcFactory();
        StandingDepositAddress_CCTPMint clone = StandingDepositAddress_CCTPMint(
            f.deploy(user, keeper)
        );
        (address account1, address account2) = clone.openStreams();

        // Deposit D into the clone, then sweep it into the source pool by direct transfer.
        uint256 D = 1000;
        tokenA.mint(address(clone), D);
        assertEq(tokenA.balanceOf(solver), 0, "solver fronts ZERO capital");
        clone.sweep();
        assertEq(tokenA.balanceOf(account1), D, "pool funded by sweep");
        assertEq(tokenA.balanceOf(address(clone)), 0, "clone swept clean");

        // Conservation participants for tokenA (source leg).
        address[] memory p = new address[](6);
        p[0] = account1;
        p[1] = address(flash);
        p[2] = solver;
        p[3] = address(clone);
        p[4] = keeper;
        p[5] = address(messenger);
        uint256 sum = _sum(tokenA, p);

        _sliceIntent1(clone, solver);

        // Arc rate1 == WAD => slice == pool, margin 0; the whole pool is burned via CCTP to account2.
        assertEq(messenger.lastAmount(), D, "whole pool burned");
        assertEq(messenger.lastMintRecipient(), _b32(account2), "mint to account2");
        assertEq(tokenA.balanceOf(account1), 0, "pool advanced + consumed");
        assertEq(tokenA.balanceOf(solver), 0, "solver still fronted ZERO");
        assertEq(tokenA.balanceOf(address(flash)), 0, "nothing strands in policy");
        assertEq(_sum(tokenA, p), sum, "tokenA conserved");

        (bytes32 ih1, ) = _hashes(clone);
        assertEq(
            uint256(intentSource.getRewardStatus(ih1)),
            uint256(IIntentSource.Status.Funded),
            "pool stays Funded"
        );
    }

    // -----------------------------------------------------------------------
    // Intent 2: Gateway flash pool on a simulated Arc (source==dest==ARC)
    // -----------------------------------------------------------------------

    function test_intent2_flashSlice_gatewayCredited_marginZeroAtWad() public {
        StandingDepositFactory_CCTPMint_Arc f = _arcFactory();
        StandingDepositAddress_CCTPMint clone = StandingDepositAddress_CCTPMint(
            f.deploy(user, keeper)
        );
        (, address account2) = clone.openStreams();

        // Simulate the CCTP mint landing at account2 (6-dec arcUsdc == tokenB).
        uint256 minted = 990;
        tokenB.mint(account2, minted);

        address claimant2 = makeAddr("arcOperator");
        address[] memory p = new address[](5);
        p[0] = account2;
        p[1] = address(flash);
        p[2] = claimant2;
        p[3] = address(gateway);
        p[4] = user;
        uint256 sum = _sum(tokenB, p);

        _sliceIntent2(clone, claimant2);

        assertEq(gateway.lastRecipient(), user, "gateway credits the user");
        assertEq(gateway.lastAmount(), minted, "full CCTP mint deposited");
        assertEq(tokenB.balanceOf(account2), 0, "account2 drained");
        assertEq(tokenB.balanceOf(claimant2), 0, "margin 0 at rate2==WAD");
        assertEq(_sum(tokenB, p), sum, "tokenB conserved");
    }

    // -----------------------------------------------------------------------
    // GatewayERC20 fee-as-rate: proportional margin, zero-fee reproduction, dust floor
    // -----------------------------------------------------------------------

    function test_gatewayERC20_feeAsRate_proportionalMargin() public {
        // 1% protocol fee (1000 / 100000).
        StandingDepositFactory_CCTPMint_GatewayERC20 f = _gwFactory(1000);
        assertGt(f.RATE_1(), WAD, "fee => rate1 > WAD");
        assertEq(f.RATE_2(), WAD);

        // Deposit 1000 -> slice 990, margin 10 (1%).
        _runGwSlice(f, makeAddr("u1"), makeAddr("s1"), 1000, 990, 10);
        // Deposit 500 -> slice 495, margin 5 (1%).
        _runGwSlice(f, makeAddr("u2"), makeAddr("s2"), 500, 495, 5);
    }

    function test_gatewayERC20_zeroFee_reproducesNoSpread() public {
        StandingDepositFactory_CCTPMint_GatewayERC20 f = _gwFactory(0);
        assertEq(f.RATE_1(), WAD, "0 bps => rate1 == WAD");
        // Deposit 1000 -> slice 1000, margin 0.
        _runGwSlice(f, makeAddr("z1"), makeAddr("zs1"), 1000, 1000, 0);
    }

    function test_gatewayERC20_subFloorPool_revertsSliceBelowFloor() public {
        StandingDepositFactory_CCTPMint_GatewayERC20 f = _gwFactory(0);
        StandingDepositAddress_CCTPMint clone = StandingDepositAddress_CCTPMint(
            f.deploy(makeAddr("dustUser"), keeper)
        );
        clone.openStreams();
        // Pool below the MIN_SLICE_1 floor (rate1 == WAD => slice == pool).
        tokenA.mint(address(clone), FLOOR - 1);
        clone.sweep();

        (Intent memory i1, ) = clone.getStandingIntents();
        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStreamingFlashPolicy.SliceBelowFloor.selector,
                0,
                FLOOR - 1,
                FLOOR
            )
        );
        flash.flashSlice(PROTOCOL_VERSION, i1.route, i1.reward, _b32(solver), "");
    }

    function _runGwSlice(
        StandingDepositFactory_CCTPMint_GatewayERC20 f,
        address u,
        address s,
        uint256 deposit,
        uint256 expectedSlice,
        uint256 expectedMargin
    ) internal {
        StandingDepositAddress_CCTPMint clone = StandingDepositAddress_CCTPMint(
            f.deploy(u, keeper)
        );
        (address account1, ) = clone.openStreams();
        tokenA.mint(address(clone), deposit);
        clone.sweep();

        uint256 msgBefore = tokenA.balanceOf(address(messenger));
        (Intent memory i1, ) = clone.getStandingIntents();
        vm.prank(solver);
        flash.flashSlice(PROTOCOL_VERSION, i1.route, i1.reward, _b32(s), "");

        assertEq(
            tokenA.balanceOf(address(messenger)) - msgBefore,
            expectedSlice,
            "slice burned == floor(pool*WAD/rate1)"
        );
        assertEq(tokenA.balanceOf(s), expectedMargin, "margin == protocol fee");
        assertEq(tokenA.balanceOf(account1), 0, "pool consumed");
    }

    // -----------------------------------------------------------------------
    // Standing-hash stability: two deposits in the same block => SAME hash/accounts
    // -----------------------------------------------------------------------

    function test_standingHash_stable_noTimestampDependence() public {
        StandingDepositFactory_CCTPMint_Arc f = _arcFactory();
        StandingDepositAddress_CCTPMint clone = StandingDepositAddress_CCTPMint(
            f.deploy(user, keeper)
        );
        clone.openStreams();

        (bytes32 ih1a, bytes32 ih2a) = _hashes(clone);
        (address a1a, address a2a) = clone.getAccounts();

        // Warp time; a second "deposit" must resolve to the SAME hashes/accounts (no timestamp in salt).
        vm.warp(block.timestamp + 5000);
        (bytes32 ih1b, bytes32 ih2b) = _hashes(clone);
        (address a1b, address a2b) = clone.getAccounts();

        assertEq(ih1a, ih1b, "ih1 stable across time");
        assertEq(ih2a, ih2b, "ih2 stable across time");
        assertEq(a1a, a1b, "account1 stable");
        assertEq(a2a, a2b, "account2 stable");
    }

    // -----------------------------------------------------------------------
    // closeStream keeper exit + epoch rotation
    // -----------------------------------------------------------------------

    function test_closeStream_bothIntents_thenReopen_rotatesEpoch() public {
        StandingDepositFactory_CCTPMint_Arc f = _arcFactory();
        StandingDepositAddress_CCTPMint clone = StandingDepositAddress_CCTPMint(
            f.deploy(user, keeper)
        );
        (address account1, address account2) = clone.openStreams();

        // Fund the source pool + simulate an Arc mint left in account2.
        tokenA.mint(address(clone), 1000);
        clone.sweep();
        tokenB.mint(account2, 300);

        (Intent memory i1, Intent memory i2) = clone.getStandingIntents();
        bytes32 rh1 = keccak256(abi.encode(i1.route));
        bytes32 rh2 = keccak256(abi.encode(i2.route));
        (bytes32 ih1, ) = _hashes(clone);

        // reopen before close reverts (source pool intent1 not Refunded).
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                StandingDepositAddress.EpochNotClosed.selector,
                ih1
            )
        );
        clone.reopen();

        // Keeper closes intent1 (source) -> refunds un-sliced pool to keeper.
        vm.prank(keeper);
        intentSource.closeStream(PROTOCOL_VERSION, CHAIN_ID, CHAIN_ID, rh1, i1.reward);
        assertEq(tokenA.balanceOf(keeper), 1000, "source pool refunded");
        assertEq(tokenA.balanceOf(account1), 0);

        // Keeper closes intent2 (destination/Arc pool) -> refunds arcUsdc dust to keeper.
        vm.prank(keeper);
        intentSource.closeStream(PROTOCOL_VERSION, CHAIN_ID, CHAIN_ID, rh2, i2.reward);
        assertEq(tokenB.balanceOf(keeper), 300, "arc dust refunded");
        assertEq(tokenB.balanceOf(account2), 0);

        // Old hashes are now terminal (Refunded).
        assertEq(
            uint256(intentSource.getRewardStatus(ih1)),
            uint256(IIntentSource.Status.Refunded)
        );

        // Non-keeper reopen reverts.
        vm.prank(otherPerson);
        vm.expectRevert(StandingDepositAddress.NotKeeper.selector);
        clone.reopen();

        // Keeper reopen bumps the epoch and republishes under a NEW hash.
        vm.prank(keeper);
        clone.reopen();
        assertEq(clone.epoch(), 1, "epoch bumped");
        (bytes32 ih1b, ) = _hashes(clone);
        assertTrue(ih1b != ih1, "new epoch => new hash");
        assertEq(
            uint256(intentSource.getRewardStatus(ih1b)),
            uint256(IIntentSource.Status.Funded),
            "new pool funded"
        );

        // Re-publishing the OLD (Refunded) intent1 hash is rejected.
        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.IntentAlreadyExists.selector,
                ih1
            )
        );
        intentSource.publish(
            i1.protocolVersion,
            i1.source,
            i1.destination,
            abi.encode(i1.route),
            i1.reward
        );
    }

    // -----------------------------------------------------------------------
    // Poison protection: plain fulfill naming the flash policy reverts NotFlashSession
    // -----------------------------------------------------------------------

    function test_plainFulfill_reverts_notFlashSession() public {
        StandingDepositFactory_CCTPMint_Arc f = _arcFactory();
        StandingDepositAddress_CCTPMint clone = StandingDepositAddress_CCTPMint(
            f.deploy(user, keeper)
        );
        clone.openStreams();
        (bytes32 ih1, ) = _hashes(clone);
        (Intent memory i1, ) = clone.getStandingIntents();

        uint256[] memory provided = new uint256[](1);
        provided[0] = FLOOR;
        tokenA.mint(otherPerson, FLOOR);
        vm.startPrank(otherPerson);
        tokenA.approve(address(portal), FLOOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStreamingFlashPolicy.NotFlashSession.selector,
                ih1
            )
        );
        inbox.fulfill(
            PROTOCOL_VERSION,
            CHAIN_ID,
            CHAIN_ID,
            i1.route,
            i1.reward,
            _b32(otherPerson),
            provided,
            address(flash)
        );
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _hashes(
        StandingDepositAddress_CCTPMint clone
    ) internal view returns (bytes32 ih1, bytes32 ih2) {
        (Intent memory i1, Intent memory i2) = clone.getStandingIntents();
        ih1 = _hashIntent(i1);
        ih2 = _hashIntent(i2);
    }

    function _sum(
        TestERC20 t,
        address[] memory who
    ) internal view returns (uint256 s) {
        for (uint256 i; i < who.length; ++i) {
            s += t.balanceOf(who[i]);
        }
    }
}
