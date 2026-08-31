/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IntentChainer} from "../../contracts/chain/IntentChainer.sol";
import {Portal} from "../../contracts/Portal.sol";
import {DepositFactory_USDCTransfer_Solana} from "../../contracts/deposit/DepositFactory_USDCTransfer_Solana.sol";
import {DepositAddress_USDCTransfer_Solana} from "../../contracts/deposit/DepositAddress_USDCTransfer_Solana.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {Reward, TokenAmount} from "../../contracts/types/Intent.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";
import {TestProver} from "../../contracts/test/TestProver.sol";

/**
 * @title IntentChainerBorshTest
 * @notice Proves the segment mechanism reproduces a REAL Solana route, byte for byte.
 * @dev The reference is not a fixture written by hand -- it is the production Borsh encoder in
 *      {DepositAddress_USDCTransfer_Solana}, captured off the `IntentPublished` event. The test takes the
 *      route that encoder emits for one amount, cuts it into literal segments at the two u64 amount
 *      positions, hands those segments to the {IntentChainer} together with a DIFFERENT amount, and requires
 *      the bytes it publishes to equal what the encoder itself produces for that second amount.
 *
 *      That is the non-circular form of the check: the segments come from route A, the expectation comes
 *      from route B, and they can only agree if the chainer writes a little-endian u64 into both positions
 *      correctly while preserving every other byte -- salt, portal, vector lengths, the SPL discriminator,
 *      and all four account metas -- untouched.
 */
contract IntentChainerBorshTest is Test {
    Portal internal portal;
    TestProver internal prover;
    TestERC20 internal usdc;
    DepositFactory_USDCTransfer_Solana internal factory;
    DepositAddress_USDCTransfer_Solana internal depositAddress;
    IntentChainer internal chainer;

    /// @dev Byte offsets of the two u64 amounts in the Solana route, asserted (not assumed) by the tests.
    uint256 internal constant TOKENS_AMOUNT_OFFSET = 116;
    uint256 internal constant SPL_AMOUNT_OFFSET = 169;

    uint256 internal constant AMOUNT_A = 1_000_000; // 1 USDC
    uint256 internal constant AMOUNT_B = 2_500_000; // 2.5 USDC

    bytes32 internal constant DESTINATION_TOKEN = bytes32(uint256(0x5678));
    bytes32 internal constant DESTINATION_PORTAL = bytes32(uint256(0xDEF0));
    bytes32 internal constant PORTAL_PDA = bytes32(uint256(0xABCD));
    bytes32 internal constant EXECUTOR_ATA = bytes32(uint256(0xEFAB));
    bytes32 internal constant RECIPIENT_ATA = bytes32(uint256(0x5555));
    uint64 internal constant DEADLINE_DURATION = 7 days;
    uint256 internal constant WAD = 1e18;

    address internal depositor;
    address internal creator;

    function setUp() public {
        depositor = makeAddr("depositor");
        creator = makeAddr("creator");

        usdc = new TestERC20("USD Coin", "USDC");
        portal = new Portal(address(0));
        prover = new TestProver(address(portal));

        factory = new DepositFactory_USDCTransfer_Solana(
            address(usdc),
            DESTINATION_TOKEN,
            address(portal),
            address(prover),
            DESTINATION_PORTAL,
            PORTAL_PDA,
            DEADLINE_DURATION,
            EXECUTOR_ATA
        );
        depositAddress = DepositAddress_USDCTransfer_Solana(
            factory.deploy(RECIPIENT_ATA, depositor)
        );

        chainer = new IntentChainer();
    }

    // ============ Layout ============

    /**
     * @notice The two amount positions are where the design says they are.
     * @dev Guards the segment offsets this whole approach depends on: if the encoder's shape ever changes,
     *      this fails with a readable message instead of the reproduction test failing opaquely.
     */
    function test_solanaRoute_carriesTheAmountAtBothKnownOffsets() public {
        bytes memory route = _captureDepositRoute(AMOUNT_A);

        assertEq(
            _readU64LE(route, TOKENS_AMOUNT_OFFSET),
            AMOUNT_A,
            "route.tokens[0].amount is not at offset 116"
        );
        assertEq(
            _readU64LE(route, SPL_AMOUNT_OFFSET),
            AMOUNT_A,
            "SPL transfer_checked amount is not at offset 169"
        );
    }

    // ============ Reproduction ============

    /**
     * @notice Segments cut from route A, replayed with amount B, equal route B from the real encoder.
     */
    function test_chain_reproducesProductionBorshRouteForADifferentAmount()
        public
    {
        bytes memory routeA = _captureDepositRoute(AMOUNT_A);
        bytes memory routeB = _captureDepositRoute(AMOUNT_B);

        assertEq(
            routeA.length,
            routeB.length,
            "reference routes differ in more than the amount"
        );

        IntentChainer.Order memory order = _orderFromReference(routeA);
        usdc.mint(address(chainer), AMOUNT_B);

        bytes memory produced = _captureChainerRoute(order);

        assertEq(
            produced,
            routeB,
            "chainer did not reproduce the production Borsh route"
        );
    }

    /**
     * @notice An amount that will not fit Solana's u64 is rejected rather than silently wrapped.
     * @dev The dangerous case this closes: a truncated amount publishes a well-formed, fillable intent that
     *      pays out a fraction of what was escrowed.
     */
    function test_chain_rejectsAmountThatOverflowsSolanaU64() public {
        bytes memory routeA = _captureDepositRoute(AMOUNT_A);
        IntentChainer.Order memory order = _orderFromReference(routeA);

        uint256 tooBig = uint256(type(uint64).max) + 1;
        usdc.mint(address(chainer), tooBig);

        vm.expectRevert(
            abi.encodeWithSelector(
                IntentChainer.AmountExceedsSlotWidth.selector,
                tooBig,
                uint8(8)
            )
        );
        chainer.chain(order);
    }

    /**
     * @notice The solver's spread lands in the route while the reward keeps the full measured amount.
     * @dev 2_500_000 * 0.96 == 2_400_000 exactly, so the reproduction stays byte-exact.
     */
    function test_chain_spreadSplitsRewardFromDestinationObligation() public {
        uint256 expectedOut = 2_400_000;

        bytes memory routeA = _captureDepositRoute(AMOUNT_A);
        bytes memory expected = _captureDepositRoute(expectedOut);

        IntentChainer.Order memory order = _orderFromReference(routeA);
        order.scale = 0.96e18;
        usdc.mint(address(chainer), AMOUNT_B);

        bytes memory produced = _captureChainerRoute(order);

        assertEq(
            produced,
            expected,
            "route must carry the scaled amount at both slots"
        );
        assertEq(
            _readU64LE(produced, TOKENS_AMOUNT_OFFSET),
            expectedOut,
            "destination obligation is net of the spread"
        );
    }

    // ============ Fixtures ============

    /// @notice Build a chainer order whose segments are route `referenceRoute` cut at the two amount positions.
    function _orderFromReference(
        bytes memory referenceRoute
    ) internal view returns (IntentChainer.Order memory) {
        bytes[] memory segments = new bytes[](3);
        segments[0] = _slice(referenceRoute, 0, TOKENS_AMOUNT_OFFSET);
        segments[1] = _slice(
            referenceRoute,
            TOKENS_AMOUNT_OFFSET + 8,
            SPL_AMOUNT_OFFSET - (TOKENS_AMOUNT_OFFSET + 8)
        );
        segments[2] = _slice(
            referenceRoute,
            SPL_AMOUNT_OFFSET + 8,
            referenceRoute.length - (SPL_AMOUNT_OFFSET + 8)
        );

        IntentChainer.Slot[] memory slots = new IntentChainer.Slot[](2);
        slots[0] = IntentChainer.Slot({width: 8, littleEndian: true});
        slots[1] = IntentChainer.Slot({width: 8, littleEndian: true});

        TokenAmount[] memory rewardTokens = new TokenAmount[](1);
        rewardTokens[0] = TokenAmount({token: address(usdc), amount: 0});

        (uint64 destinationChain, , , , , , , , ) = factory.getConfiguration();

        return
            IntentChainer.Order({
                portal: address(portal),
                token: address(usdc),
                destination: destinationChain,
                segments: segments,
                slots: slots,
                reward: Reward({
                    deadline: uint64(block.timestamp + DEADLINE_DURATION),
                    creator: creator,
                    prover: address(prover),
                    nativeAmount: 0,
                    tokens: rewardTokens
                }),
                scale: WAD,
                minAmountIn: 0
            });
    }

    /// @notice Route bytes the production encoder emits for `amount`.
    function _captureDepositRoute(
        uint256 amount
    ) internal returns (bytes memory) {
        usdc.mint(address(depositAddress), amount);

        vm.recordLogs();
        depositAddress.createIntent();

        return _routeFromLogs(vm.getRecordedLogs());
    }

    /// @notice Route bytes the chainer publishes for `order`.
    function _captureChainerRoute(
        IntentChainer.Order memory order
    ) internal returns (bytes memory) {
        vm.recordLogs();
        chainer.chain(order);

        return _routeFromLogs(vm.getRecordedLogs());
    }

    /// @notice Pull the `route` field out of the first IntentPublished log.
    function _routeFromLogs(
        Vm.Log[] memory logs
    ) internal pure returns (bytes memory route) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] != IIntentSource.IntentPublished.selector) {
                continue;
            }

            (, route, , , ) = abi.decode(
                logs[i].data,
                (uint64, bytes, uint64, uint256, TokenAmount[])
            );
            return route;
        }

        revert("IntentPublished not emitted");
    }

    function _readU64LE(
        bytes memory blob,
        uint256 offset
    ) internal pure returns (uint256 value) {
        for (uint256 i = 0; i < 8; ++i) {
            value |= uint256(uint8(blob[offset + i])) << (8 * i);
        }
    }

    function _slice(
        bytes memory blob,
        uint256 start,
        uint256 length
    ) internal pure returns (bytes memory out) {
        out = new bytes(length);
        for (uint256 i = 0; i < length; ++i) {
            out[i] = blob[start + i];
        }
    }
}
