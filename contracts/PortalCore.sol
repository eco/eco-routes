/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Semver} from "./libs/Semver.sol";

import {IntentSource} from "./IntentSource.sol";
import {Inbox} from "./Inbox.sol";
import {IPortal} from "./interfaces/IPortal.sol";
import {Intent} from "./types/Intent.sol";
import {Refund} from "./libs/Refund.sol";

/**
 * @title PortalCore
 * @notice Combined-half base for the Portal: everything that needs BOTH the source-side {IntentSource}
 *         and the destination-side {Inbox} in one contract.
 * @dev {Portal} and {PortalTron} inherit this and supply only the {AccountDeployer} constructor args (the
 *      Account clone template + CREATE2 prefix). The one cross-cutting primitive here is the same-chain
 *      {fulfillAndSettle}: fulfilling names its policy (destination half) AND settling reads the reward
 *      status (source half), which only the combined contract can do. Keeping it in a shared base means
 *      {Portal} and {PortalTron} do not duplicate the logic.
 */
abstract contract PortalCore is IntentSource, Inbox, Semver {
    /**
     * @notice Atomically fulfills and settles a SAME-CHAIN intent in one transaction
     * @dev See {IPortal-fulfillAndSettle}. Requires `intent.source == intent.destination ==
     *      block.chainid`. Because source == destination the escrow Account and the execution Account are
     *      ONE (Model C same-chain collapse), so the reward-conservation postcondition inside {_fulfill}
     *      protects the escrow from the keeper-committed runtime, and the settle then pays the reward out
     *      of that same Account. The solver supplies the route input capital (this is NOT the v2
     *      zero-capital flash: reward-conservation forbids the runtime from consuming the escrow to fund
     *      the route), and receives the reward atomically after delivery.
     * @param intent The complete same-chain intent
     * @param providedAmounts Per-leg input the solver provides, index-aligned with `intent.route.minTokens`
     * @param claimant Address that receives the reward (as a cross-VM identifier)
     * @return The runtime's raw return data
     */
    function fulfillAndSettle(
        Intent calldata intent,
        uint256[] calldata providedAmounts,
        bytes32 claimant
    ) external payable returns (bytes memory) {
        uint64 chainId = uint64(block.chainid);
        if (intent.source != chainId || intent.destination != chainId) {
            revert IPortal.NotSameChain(
                intent.source,
                intent.destination,
                chainId
            );
        }

        // Fulfill: execute the runtime in the shared Account, enforce reward-conservation, and record the
        // fulfillment into the keeper-committed prover. For a same-chain intent this recorded fact IS the
        // proof the settle reads below (no relay, no cross-chain round-trip).
        (bytes memory result, uint256[] memory fulfilled, ) = _fulfill(
            intent.protocolVersion,
            intent.source,
            intent.destination,
            intent.route,
            intent.reward,
            claimant,
            providedAmounts,
            intent.reward.prover
        );

        // Settle atomically from the SAME Account, using the just-recorded local fulfillment fact. The
        // `(claimant, fulfilled)` preimage is known in-tx, so it re-derives the fulfillmentHash the fulfill
        // recorded and pays out without a cross-chain hash round-trip.
        bytes32 routeHash = keccak256(abi.encode(intent.route));
        _settle(
            intent.protocolVersion,
            intent.source,
            intent.destination,
            routeHash,
            intent.reward,
            claimant,
            fulfilled
        );

        // Refund any excess native.
        Refund.excessNative();

        return result;
    }
}
