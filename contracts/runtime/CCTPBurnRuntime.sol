// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Minimal CCTP v2 TokenMessenger surface used by {CCTPBurnRuntime}.
 * @dev Mirrors the `depositForBurn` selector the one-shot deposit templates encode by hand
 *      (`depositForBurn(uint256,uint32,bytes32,address,bytes32,uint256,uint32)`).
 */
interface ITokenMessengerV2 {
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;
}

/**
 * @title CCTPBurnRuntime
 * @notice BALANCE-READING v3 runtime for a STANDING CCTP-burn flash pool: the payload commits CONFIG
 *         ONLY (`abi.encode(token, messenger, destinationDomain, mintRecipient, maxFeeBps)`), never an
 *         amount. Delegatecalled in the per-intent {Account}'s context, it burns the Account's ENTIRE
 *         balance of `token` via CCTP, minting to the fixed `mintRecipient` (the destination pool Account).
 *
 * @dev STATELESS singleton reached exclusively via `delegatecall` from the Account (mirrors
 *      {MulticallRuntime}): the Account forwards `Route.payload` verbatim as calldata, so this contract's
 *      {fallback} decodes it and acts as the Account (`address(this) == Account`, balances/approvals are
 *      the Account's). It holds NO storage of its own, so one deployed instance is safe to share across
 *      every Account / slice.
 *
 *      Why a balance-reading runtime (not {MulticallRuntime}): under the standing-pool full-pool-advance
 *      flash model each slice's burn amount varies with the current pool, so it CANNOT be baked into the
 *      hash-committed payload. The amount `x` is read LIVE (`balanceOf(this)`); the CCTP `maxFee` is
 *      derived from it (`ceil(x * maxFeeBps / FEE_DENOMINATOR)`). This is safe BY CONSTRUCTION: the flash
 *      policy's full-pool advance empties the Account before the Inbox stages exactly the slice `x` back,
 *      so the only balance this runtime can see or burn is that slice.
 *
 *      `forceApprove` is used because a fully-consumed CCTP burn leaves the allowance at 0, and a stray
 *      non-zero -> non-zero approve would revert on USDC.
 */
contract CCTPBurnRuntime {
    using SafeERC20 for IERC20;

    /// @notice Denominator for `maxFeeBps` (100_000 => 1 unit == 0.001%). Matches the deposit templates.
    uint256 internal constant FEE_DENOMINATOR = 100_000;

    /**
     * @notice Burn the Account's whole balance of the configured token via CCTP.
     * @dev Reached via `delegatecall` from the Account with `Route.payload` as calldata:
     *      `abi.encode(address token, address messenger, uint32 destinationDomain, bytes32 mintRecipient,
     *      uint256 maxFeeBps)`. `mintRecipient` is the fixed destination pool Account (config, not an
     *      amount).
     */
    fallback() external payable {
        (
            address token,
            address messenger,
            uint32 destinationDomain,
            bytes32 mintRecipient,
            uint256 maxFeeBps
        ) = abi.decode(
                msg.data,
                (address, address, uint32, bytes32, uint256)
            );

        uint256 x = IERC20(token).balanceOf(address(this));

        // CCTP fast-deposit fee, rounded UP so the user never overpays and the burn is never rejected for
        // an under-quoted fee. A deployer-supplied `maxFeeBps < FEE_DENOMINATOR` keeps `maxFee <= x`
        // (equality only at the pathological boundary of a near-100% fee on a near-dust slice, itself
        // blocked by the `MIN_SLICE_1` floor in StreamingFlashPolicy before this runtime runs).
        uint256 maxFee = (x * maxFeeBps + FEE_DENOMINATOR - 1) / FEE_DENOMINATOR;

        IERC20(token).forceApprove(messenger, x);
        ITokenMessengerV2(messenger).depositForBurn(
            x,
            destinationDomain,
            mintRecipient,
            token,
            bytes32(0), // destinationCaller: anyone may complete the mint
            maxFee,
            0 // minFinalityThreshold: fast finality
        );
    }

    /// @notice Accept native (never used by CCTP; present for delegatecall-context symmetry).
    receive() external payable {}
}
