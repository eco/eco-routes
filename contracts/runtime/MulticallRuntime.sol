/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRuntime, Call} from "../interfaces/IRuntime.sol";

/**
 * @title MulticallRuntime
 * @notice Default v3 runtime: executes a keeper-authored batch of arbitrary calls.
 * @dev This is the v2 `Executor` behavior repackaged as a pluggable runtime. It is meant to be reached
 *      exclusively via `delegatecall` from the per-intent {Account}: the Account forwards `Route.payload`
 *      verbatim, and this contract decodes it as `abi.encode(Call[])` and runs each call.
 *
 *      Because every invocation is a `delegatecall`, all execution happens in the *Account's* context:
 *        - `address(this)` is the Account, so `value:` and token approvals draw on the Account's own
 *          balances (the solver-supplied inputs the Inbox staged onto it, plus any escrow on a
 *          same-chain intent);
 *        - this contract holds NO storage of its own and writes none, so a single deployed instance is
 *          safe to share across every Account / intent.
 *
 *      Safety:
 *        - EOA guard (restored from the v2 `Executor`): a call whose `target` has no code while
 *          `data.length > 0` reverts {CallToEOA}. This is the solver-phishing protection main's
 *          `Executor` carried; a delegatecall runtime that dropped it could be tricked into treating an
 *          EOA's returned "success" (an empty-code call always succeeds) as a real interaction.
 *        - Reverts bubble verbatim inside {CallReverted} (the whole fulfillment reverts on any failed
 *          call); failures are never swallowed (atomicity is load-bearing).
 *        - This runtime enforces no postcondition of its own. Delivery is the payload's job (the core is
 *          unopinionated — there is no protocol-level output floor), and any solver input the payload
 *          does not consume simply stays in the Account for `route.keeper` to retrieve later.
 */
contract MulticallRuntime is IRuntime {
    /**
     * @notice A call in the batch reverted.
     * @param index Zero-based index of the failing call within the decoded `Call[]`.
     * @param target The call target that reverted.
     * @param data The raw revert data returned by `target`.
     */
    error CallReverted(uint256 index, address target, bytes data);

    /**
     * @notice Attempted a call carrying calldata to an address with no code (potential EOA phishing).
     * @param target The code-less target the call was aimed at.
     */
    error CallToEOA(address target);

    /**
     * @notice Decode `payload` as `Call[]` and execute each call in order from the caller's context.
     * @dev Intended to be invoked via `delegatecall` from the {Account}; under `delegatecall`
     *      `address(this)`, balances and storage resolve to the Account. The payload is
     *      `abi.encode(Call[] calls)`.
     * @param payload ABI-encoded `Call[]` to execute.
     * @return results The return data of each call, index-aligned with the decoded `Call[]`.
     */
    function multicall(
        bytes calldata payload
    ) external payable returns (bytes[] memory results) {
        return _run(abi.decode(payload, (Call[])));
    }

    /**
     * @notice Fallback entry used when the Account forwards an opaque `payload` verbatim.
     * @dev The Account's `execute`/`fallback` forward raw calldata (`Route.payload`) without a selector
     *      that matches {multicall}. To make this runtime a drop-in delegate target for that raw
     *      forwarding, the fallback treats the entire forwarded calldata as the `abi.encode(Call[])`
     *      payload and runs it, bubbling any revert. Reached only via `delegatecall` from an Account.
     */
    fallback() external payable {
        _run(abi.decode(msg.data, (Call[])));
    }

    /// @notice Accept native token (e.g. WETH unwraps, native swap proceeds) when delegated into.
    receive() external payable {}

    /**
     * @notice Execute each call in order, guarding against EOA-phishing and bubbling reverts.
     * @param calls The decoded batch of calls to execute.
     * @return results The return data of each call, index-aligned with `calls`.
     */
    function _run(
        Call[] memory calls
    ) internal returns (bytes[] memory results) {
        uint256 length = calls.length;
        results = new bytes[](length);

        for (uint256 i = 0; i < length; ++i) {
            Call memory call = calls[i];

            // EOA guard: a call carrying calldata to a code-less address is rejected (an empty-code
            // call always "succeeds", which could be misread as a real interaction).
            if (call.target.code.length == 0 && call.data.length > 0) {
                revert CallToEOA(call.target);
            }

            (bool success, bytes memory ret) = call.target.call{
                value: call.value
            }(call.data);
            if (!success) {
                revert CallReverted(i, call.target, ret);
            }
            results[i] = ret;
        }
    }
}
