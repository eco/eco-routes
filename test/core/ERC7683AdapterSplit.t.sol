// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../BaseTest.sol";
import {ERC7683Implementation} from "../../contracts/ERC7683/ERC7683Implementation.sol";
import {IDestinationSettler} from "../../contracts/interfaces/ERC7683/IDestinationSettler.sol";
import {OnchainCrossChainOrder, OrderData, Output, ORDER_DATA_TYPEHASH} from "../../contracts/types/ERC7683.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";

/**
 * @title ERC7683AdapterSplitTest
 * @notice Proves the PR10 split is behaviourally transparent: the ERC-7683 surface, now reached via the
 *         TWO-hop path (proxy -> lean Portal -> {PortalCore-fallback} -> {ERC7683Implementation} ->
 *         delegatecall the pinned implementation), shares ONE consistent view of the proxy's storage and
 *         escrow with the direct one-hop core path — AND that `msg.sender` is preserved end-to-end so a
 *         solver's OWN tokens are pulled on the fill path (the bug the naive self-CALL design would have
 *         introduced).
 * @dev The default {BaseTest} intent is same-chain (source == destination == CHAIN_ID), so `open()` (which
 *      commits source == block.chainid) and the direct core calls derive the SAME intent hash.
 */
contract ERC7683AdapterSplitTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _mintAndApprove(keeper, MINT_AMOUNT); // keeper approves the PROXY (default core funding path)
    }

    /// @dev Builds the ERC-7683 on-chain order that maps to the default same-chain intent.
    function _order() internal view returns (OnchainCrossChainOrder memory) {
        OrderData memory od = OrderData({
            protocolVersion: PROTOCOL_VERSION,
            destination: CHAIN_ID,
            route: abi.encode(route),
            reward: reward,
            routePortal: bytes32(uint256(uint160(address(portal)))),
            routeDeadline: uint64(expiry),
            maxSpent: new Output[](0)
        });
        return
            OnchainCrossChainOrder({
                fillDeadline: uint32(expiry),
                orderDataType: ORDER_DATA_TYPEHASH,
                orderData: abi.encode(od)
            });
    }

    // -----------------------------------------------------------------------------------------------
    // Cross-boundary storage/escrow sharing
    // -----------------------------------------------------------------------------------------------

    /// @notice ERC-7683 `open()` (2-hop) WRITES funded state that the direct core `getRewardStatus`/escrow
    ///         (1-hop) READS — proving both paths see the same proxy storage + the same per-intent Account.
    function test_open2hop_write_coreRead_funded() public {
        bytes32 intentHash = _hashIntent(intent);
        address account = intentSource.intentAccountAddress(intent);

        assertTrue(
            intentSource.getRewardStatus(intentHash) ==
                IIntentSource.Status.Initial
        );

        vm.prank(keeper);
        ERC7683Implementation(address(portal)).open(_order());

        // Core (1-hop) read sees what the 7683 (2-hop) path wrote.
        assertTrue(
            intentSource.getRewardStatus(intentHash) ==
                IIntentSource.Status.Funded
        );
        // Escrow landed at the SAME core-derived Account.
        assertEq(tokenA.balanceOf(account), MINT_AMOUNT);
        assertEq(tokenB.balanceOf(account), MINT_AMOUNT * 2);
    }

    /// @notice The direct core path (1-hop) WRITES terminal (Refunded) state that the ERC-7683 `open()`
    ///         (2-hop) READS — a second open reverts {IntentAlreadyExists}, proving the shared view.
    function test_coreWrite_open2hop_readsTerminalStatus() public {
        _publishAndFund(intent, false); // core, 1-hop -> Funded
        bytes32 intentHash = _hashIntent(intent);

        _timeTravel(expiry + 1); // past the reward deadline so the refund is allowed
        intentSource.refund(
            PROTOCOL_VERSION,
            CHAIN_ID,
            CHAIN_ID,
            keccak256(abi.encode(route)),
            reward
        );
        assertTrue(
            intentSource.getRewardStatus(intentHash) ==
                IIntentSource.Status.Refunded
        );

        // The 2-hop open reads the same Refunded status and refuses to re-create the intent.
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.IntentAlreadyExists.selector,
                intentHash
            )
        );
        ERC7683Implementation(address(portal)).open(_order());
    }

    /// @notice Full round trip: fund via ERC-7683 `open()` (2-hop), settle via the direct core path
    ///         (1-hop). The core settle pays the claimant out of the escrow the 7683 path funded.
    function test_open2hop_fund_coreSettle_roundtrip() public {
        bytes32 intentHash = _hashIntent(intent);

        vm.prank(keeper);
        ERC7683Implementation(address(portal)).open(_order()); // 2-hop fund

        _addProof(intentHash, CHAIN_ID, claimant); // record a proven same-chain fulfillment

        uint256 claimantBefore = tokenA.balanceOf(claimant);
        _settle(CHAIN_ID, CHAIN_ID, keccak256(abi.encode(route)), reward, claimant); // 1-hop settle

        assertTrue(
            intentSource.getRewardStatus(intentHash) ==
                IIntentSource.Status.Withdrawn
        );
        assertEq(tokenA.balanceOf(claimant), claimantBefore + MINT_AMOUNT);
    }

    // -----------------------------------------------------------------------------------------------
    // msg.sender preservation on the fill path (the reason a plain self-CALL would be WRONG)
    // -----------------------------------------------------------------------------------------------

    /// @notice A distinct solver that calls `fill()` through the 2-hop ERC-7683 path has ITS OWN tokens
    ///         pulled (via {Inbox._fulfill}'s `safeTransferFrom(msg.sender, ...)`), NOT the proxy's.
    /// @dev If the adapter used a plain self-CALL (resetting `msg.sender` to the proxy) instead of a
    ///      `delegatecall`, the ERC20 pull would target the proxy — which holds no balance and grants no
    ///      allowance — and revert. This test proves the delegatecall preserves `msg.sender`: the solver's
    ///      balance drops, the proxy's stays zero, and the call does NOT revert.
    function test_fill2hop_pullsSolverOwnTokens_notProxy() public {
        address solver = makeAddr("erc7683Solver");

        // The solver has its own input and approves the PROXY (the transferFrom is executed by the Portal,
        // i.e. address(this) == proxy, so the allowance is granted to the proxy). The proxy itself holds
        // NOTHING and grants NOTHING — if the pull were wrongly targeted at the proxy it would revert.
        vm.startPrank(solver);
        tokenA.mint(solver, MINT_AMOUNT);
        tokenA.approve(address(portal), MINT_AMOUNT);
        vm.stopPrank();

        assertEq(tokenA.balanceOf(address(portal)), 0, "proxy holds no input");

        bytes memory originData = abi.encode(
            PROTOCOL_VERSION,
            CHAIN_ID, // source (same-chain default)
            abi.encode(route),
            reward
        );
        bytes memory fillerData = abi.encode(
            address(prover),
            CHAIN_ID, // sourceChainDomainID (unused by TestPolicy)
            bytes32(uint256(uint160(solver))), // claimant
            _defaultFulfilled(), // providedAmounts == [MINT_AMOUNT]
            bytes("") // prover data
        );

        uint256 solverBefore = tokenA.balanceOf(solver);
        uint256 keeperBefore = tokenA.balanceOf(keeper);

        // fill() through the proxy: proxy -> Portal -> fallback -> ERC7683Implementation.fill ->
        // fulfillAndProve override -> delegatecall Inbox.fulfillAndProve. msg.sender stays `solver`.
        vm.prank(solver);
        ERC7683Implementation(address(portal)).fill(
            keccak256("orderId"),
            originData,
            fillerData
        );

        // The solver's OWN tokens were pulled (not the proxy's, which never held or approved anything).
        assertEq(
            tokenA.balanceOf(solver),
            solverBefore - MINT_AMOUNT,
            "solver's own input was pulled"
        );
        assertEq(
            tokenA.balanceOf(address(portal)),
            0,
            "proxy never held solver input"
        );
        // The keeper-committed runtime ran in the Account and delivered the input to the keeper.
        assertEq(
            tokenA.balanceOf(keeper),
            keeperBefore + MINT_AMOUNT,
            "runtime executed inside the Account"
        );
    }
}
