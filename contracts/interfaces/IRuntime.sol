/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @notice A single low-level contract call.
 * @dev Used to build the {MulticallRuntime} payload (an `abi.encode(Call[])`). The runtime is invoked
 *      via `delegatecall` from the per-intent {Account}, so each call executes from the Account's context:
 *      `address(this)`, balances, approvals and `msg.sender` (for the inner call) all resolve to the
 *      Account that holds this intent's funds.
 * @param target Contract (or account) to call.
 * @param data ABI-encoded calldata for `target`.
 * @param value Native token value (wei) to forward with the call.
 */
struct Call {
    address target;
    bytes data;
    uint256 value;
}

/**
 * @title IRuntime
 * @notice Marker interface for v3 execution runtimes.
 * @dev A runtime is a piece of logic that the per-intent {Account} reaches via `delegatecall`. It is
 *      never called through this interface's ABI directly — the Account forwards the raw `Route.payload`
 *      verbatim, and the runtime decodes it however it likes (the default {MulticallRuntime} decodes it
 *      as `abi.encode(Call[])`). This interface exists only to give a stable type/name to "the thing an
 *      Account delegatecalls"; it intentionally declares no functions so that arbitrary runtimes (e.g. a
 *      Sauce router, a multicall) can satisfy it without a fixed selector.
 *
 *      Because runtimes run under `delegatecall`, they MUST be stateless (touch no HIGH storage slots of
 *      the Account) and MUST guard any fund movement themselves; `Route.runtime` is committed in the
 *      `routeHash` (hence the `intentHash`), so the intent commits to the exact runtime code that will
 *      run against the Account holding its funds.
 */
// solhint-disable-next-line no-empty-blocks
interface IRuntime {

}
