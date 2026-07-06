// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {WAD} from "../types/Intent.sol";
import {StandingDepositFactory_CCTPMint} from "./StandingDepositFactory_CCTPMint.sol";

/**
 * @title StandingDepositFactory_CCTPMint_GatewayERC20
 * @notice STANDING CCTP + Gateway deposit factory for ERC20 destinations. The one-shot template's fixed
 *         absolute FLAT_FEE becomes a PROPORTIONAL per-slice reward-leg rate spread (the flash model cannot
 *         express a per-deposit flat, and payload fees are forbidden).
 * @dev `RATE_1 = WAD * FEE_DENOMINATOR / (FEE_DENOMINATOR - protocolFeeBps)` (>= WAD), so the per-slice
 *      margin `pool * (1 - WAD/RATE_1) ≈ pool * protocolFeeBps/FEE_DENOMINATOR` is the protocol fee taken
 *      as solver margin. `protocolFeeBps == 0` reproduces the pre-feature zero-fee behavior (`RATE_1 ==
 *      WAD`). The old `AmountBelowFlatFee` guard is replaced by the pool's `MIN_SLICE_1` dust floor
 *      (`SliceBelowFloor`). `RATE_2 == WAD` (user receives the full CCTP net).
 */
contract StandingDepositFactory_CCTPMint_GatewayERC20 is
    StandingDepositFactory_CCTPMint
{
    /// @notice `protocolFeeBps >= FEE_DENOMINATOR` would divide by zero / invert the rate.
    error ProtocolFeeBpsTooLarge(uint256 protocolFeeBps);

    /**
     * @param sourceToken Source USDC (ERC20) on the source chain.
     * @param portal Portal (PortalProxy) address.
     * @param protocolVersion Registered protocol version the intents are pinned to.
     * @param streamingFlashPolicy {StreamingFlashPolicy} address (same on both chains via CREATE3).
     * @param gatewayDepositRuntime {GatewayDepositRuntime} address on the destination (config).
     * @param destinationChainId Destination chain id (intent 2's source == destination).
     * @param destinationDomain CCTP destination domain.
     * @param cctpTokenMessenger CCTP TokenMessengerV2 on the source chain.
     * @param destinationUsdc USDC ERC20 on the destination chain.
     * @param gateway Gateway contract on the destination chain.
     * @param minSlice1 Source-pool dust floor.
     * @param minSlice2 Destination-pool dust floor.
     * @param maxFeeBps CCTP fast-deposit fee cap (denominator FEE_DENOMINATOR).
     * @param protocolFeeBps Eco protocol fee in the same denominator (0 == no fee); becomes the RATE_1
     *        spread.
     */
    constructor(
        address sourceToken,
        address portal,
        uint32 protocolVersion,
        address streamingFlashPolicy,
        address gatewayDepositRuntime,
        uint64 destinationChainId,
        uint32 destinationDomain,
        address cctpTokenMessenger,
        address destinationUsdc,
        address gateway,
        uint256 minSlice1,
        uint256 minSlice2,
        uint256 maxFeeBps,
        uint256 protocolFeeBps
    )
        StandingDepositFactory_CCTPMint(
            _cfg(
                sourceToken,
                portal,
                protocolVersion,
                streamingFlashPolicy,
                gatewayDepositRuntime,
                destinationChainId,
                destinationDomain,
                cctpTokenMessenger,
                destinationUsdc,
                gateway,
                minSlice1,
                minSlice2,
                maxFeeBps,
                protocolFeeBps
            )
        )
    {}

    /**
     * @notice Builds the base config, converting the proportional protocol fee (bps) into RATE_1.
     * @dev A free function-style helper (internal pure) keeps the derivation off the initializer list.
     *      Reverts {ProtocolFeeBpsTooLarge} before the (unreachable) division by zero.
     */
    function _cfg(
        address sourceToken,
        address portal,
        uint32 protocolVersion,
        address streamingFlashPolicy,
        address gatewayDepositRuntime,
        uint64 destinationChainId,
        uint32 destinationDomain,
        address cctpTokenMessenger,
        address destinationUsdc,
        address gateway,
        uint256 minSlice1,
        uint256 minSlice2,
        uint256 maxFeeBps,
        uint256 protocolFeeBps
    ) internal pure returns (CCTPConfig memory) {
        if (protocolFeeBps >= FEE_DENOMINATOR) {
            revert ProtocolFeeBpsTooLarge(protocolFeeBps);
        }
        uint256 rate1 = (WAD * FEE_DENOMINATOR) /
            (FEE_DENOMINATOR - protocolFeeBps);
        return
            CCTPConfig({
                sourceToken: sourceToken,
                portal: portal,
                protocolVersion: protocolVersion,
                streamingFlashPolicy: streamingFlashPolicy,
                gatewayDepositRuntime: gatewayDepositRuntime,
                destinationChainId: destinationChainId,
                destinationDomain: destinationDomain,
                cctpTokenMessenger: cctpTokenMessenger,
                destUsdc: destinationUsdc,
                gateway: gateway,
                rate1: rate1,
                rate2: WAD,
                minSlice1: minSlice1,
                minSlice2: minSlice2,
                maxFeeBps: maxFeeBps
            });
    }
}
