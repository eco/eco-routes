// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {WAD} from "../types/Intent.sol";
import {StandingDepositFactory_CCTPMint} from "./StandingDepositFactory_CCTPMint.sol";

/**
 * @title StandingDepositFactory_CCTPMint_Arc
 * @notice STANDING CCTP + Gateway deposit factory for Arc. Arc historically had ZERO protocol fee, so both
 *         reward-leg rates default to `WAD` (net-zero solver economics; the operator runs the draw-down as
 *         a gas-paid service and the user receives the full CCTP net).
 * @dev Arc's CCTP TokenMessenger mints the 6-decimal `arcUsdc` ERC20 (NOT native), so intent 2's pool /
 *      input legs are that ERC20 — there is NO 1e12 native scaling (deleted from the one-shot template).
 *      This makes Arc structurally identical to the GatewayERC20 family, hence the shared template/base.
 */
contract StandingDepositFactory_CCTPMint_Arc is StandingDepositFactory_CCTPMint {
    /**
     * @param sourceToken Source USDC (ERC20) on the source chain.
     * @param portal Portal (PortalProxy) address.
     * @param protocolVersion Registered protocol version the intents are pinned to.
     * @param streamingFlashPolicy {StreamingFlashPolicy} address (same on source and Arc via CREATE3).
     * @param gatewayDepositRuntime {GatewayDepositRuntime} address on Arc (config; deployed by the script).
     * @param arcChainId Arc chain id (intent 2's source == destination).
     * @param destinationDomain CCTP destination domain for Arc.
     * @param cctpTokenMessenger CCTP TokenMessengerV2 on the source chain.
     * @param arcUsdc 6-decimal arcUsdc ERC20 on Arc (the CCTP mint token).
     * @param gateway Gateway contract on Arc.
     * @param minSlice1 Source-pool dust floor.
     * @param minSlice2 Destination-pool dust floor.
     * @param maxFeeBps CCTP fast-deposit fee cap (denominator FEE_DENOMINATOR).
     */
    constructor(
        address sourceToken,
        address portal,
        uint32 protocolVersion,
        address streamingFlashPolicy,
        address gatewayDepositRuntime,
        uint64 arcChainId,
        uint32 destinationDomain,
        address cctpTokenMessenger,
        address arcUsdc,
        address gateway,
        uint256 minSlice1,
        uint256 minSlice2,
        uint256 maxFeeBps
    )
        StandingDepositFactory_CCTPMint(
            CCTPConfig({
                sourceToken: sourceToken,
                portal: portal,
                protocolVersion: protocolVersion,
                streamingFlashPolicy: streamingFlashPolicy,
                gatewayDepositRuntime: gatewayDepositRuntime,
                destinationChainId: arcChainId,
                destinationDomain: destinationDomain,
                cctpTokenMessenger: cctpTokenMessenger,
                destUsdc: arcUsdc,
                gateway: gateway,
                rate1: WAD, // zero protocol spread (Arc parity)
                rate2: WAD, // user receives the full CCTP net
                minSlice1: minSlice1,
                minSlice2: minSlice2,
                maxFeeBps: maxFeeBps
            })
        )
    {}
}
