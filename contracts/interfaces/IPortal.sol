// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IIntentSource} from "./IIntentSource.sol";
import {IInbox} from "./IInbox.sol";
import {Intent} from "../types/Intent.sol";

/**
 * @title IPortal
 * @notice Interface for the unified Portal contract following the new specification
 * @dev Combines source chain operations (publish, fund, refund, withdraw) and
 *      destination chain operations (fulfill, prove) in a single interface
 */
interface IPortal is IIntentSource, IInbox {
    /**
     * @notice A `fulfillAndSettle` was attempted on an intent that is not same-chain (source ==
     *         destination == block.chainid)
     * @param source The intent's committed source chain id
     * @param destination The intent's committed destination chain id
     * @param current The current chain id (block.chainid)
     */
    error NotSameChain(uint64 source, uint64 destination, uint64 current);

    /**
     * @notice Atomically fulfills and settles a SAME-CHAIN intent in one transaction
     * @dev Requires `intent.source == intent.destination == block.chainid`. Runs the fulfill (stage the
     *      solver's provided input onto the shared Account, execute the runtime, enforce reward-conservation,
     *      record the fulfillment into `intent.reward.prover`) and then settles the reward to `claimant`
     *      from the SAME Account, reading the just-recorded local fulfillment fact — no relay, no
     *      cross-chain hash round-trip. The solver supplies the route input capital (NOT zero-capital: the
     *      reward escrow is protected by reward-conservation and can never fund the route) and receives the
     *      reward atomically after delivery.
     * @param intent The complete same-chain intent
     * @param providedAmounts Per-leg input the solver provides, index-aligned with `intent.route.minTokens`
     * @param claimant Address that receives the reward (as a cross-VM identifier)
     * @return The runtime's raw return data
     */
    function fulfillAndSettle(
        Intent calldata intent,
        uint256[] calldata providedAmounts,
        bytes32 claimant
    ) external payable returns (bytes memory);
}
