// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IFlashSolver
 * @notice Callback surface a solver implements to receive a flash advance mid-session.
 * @dev The flash policies ({SameChainFlashPolicy-flashFulfill} / {StreamingFlashPolicy-flashSlice})
 *      release the intent's reward escrow to themselves FIRST (session self-vouching), then — when the
 *      caller supplied non-empty `solverData` — forward the advance to the calling solver and invoke this
 *      callback so the solver can convert it (swap, unwrap, bridge exit, ...) into the route's input legs.
 *
 *      REPAYMENT CONTRACT: before returning, the solver must make the route inputs pullable by the policy:
 *        - ERC20 input legs: approve the CALLING POLICY (`msg.sender` inside this callback) for at least
 *          the required input amount of each `route.minTokens` token — the policy pulls them via
 *          `safeTransferFrom` right after the callback returns.
 *        - a native input leg: transfer the required native amount to the policy (it has `receive()`).
 *      If the inputs cannot be pulled/funded the WHOLE flash transaction reverts — the escrow advance
 *      unwinds with it, so a failed repayment can never cost the intent anything.
 * @custom:security The callback runs inside the policy's `nonReentrant` session: re-entering the flash
 *      entry point reverts, and the already-consumed session advance cannot be released twice.
 */
interface IFlashSolver {
    /**
     * @notice Receives the flash advance and prepares the route inputs for repayment.
     * @param intentHash Hash of the intent being flash-fulfilled.
     * @param amounts Advance amounts just transferred to the solver, index-aligned with `reward.tokens`
     *        (native folds in as the `address(0)` leg).
     * @param solverData Opaque data the solver passed into the flash entry point, forwarded verbatim.
     */
    function onFlashAdvance(
        bytes32 intentHash,
        uint256[] calldata amounts,
        bytes calldata solverData
    ) external;
}
