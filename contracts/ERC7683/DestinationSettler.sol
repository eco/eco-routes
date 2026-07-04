/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDestinationSettler} from "../interfaces/ERC7683/IDestinationSettler.sol";
import {Route, Reward} from "../types/Intent.sol";

/**
 * @title DestinationSettler
 * @notice Abstract contract implementing ERC-7683 destination chain settlement for Eco Protocol
 * @dev Handles intent fulfillment on destination chains through the ERC-7683 standard interface
 */
abstract contract DestinationSettler is IDestinationSettler {
    /**
     * @notice Fills a single leg of a particular order on the destination chain
     * @dev originData is of type OnchainCrossChainOrder
     * @dev fillerData is encoded bytes consisting of the prover, source chain, claimant, the per-leg
     *      `providedAmounts` the solver supplies (index-aligned with `route.minTokens`), and any additional
     *      data required for the chosen prover
     * @param orderId Unique identifier for the order being filled
     * @param originData Data emitted on the origin chain to parameterize the fill, equivalent to the originData field from the fillInstruction of the ResolvedCrossChainOrder. An encoded Intent struct.
     * @param fillerData Data provided by the filler to inform the fill or express their preferences
     */
    function fill(
        bytes32 orderId,
        bytes calldata originData,
        bytes calldata fillerData
    ) external payable {
        // originData carries the origin-emitted intent data: the committed `source` chain id (Model C —
        // hashed into the intent), the encoded route, and the full reward (needed for the reward-leg
        // authentication + conservation snapshot at fulfill). The `destination` is this chain
        // (block.chainid) — the fill happens on the destination chain.
        (uint64 source, bytes memory encodedRoute, Reward memory reward) = abi
            .decode(originData, (uint64, bytes, Reward));

        emit OrderFilled(orderId, msg.sender);

        // fillerData is the filler's routing preference: the prover, the bridge transport domain id for
        // the proof, the claimant, and any prover-specific data.
        (
            address prover,
            uint64 sourceChainDomainID,
            bytes32 claimant,
            uint256[] memory providedAmounts,
            bytes memory proverData
        ) = abi.decode(
                fillerData,
                (address, uint64, bytes32, uint256[], bytes)
            );

        fulfillAndProve(
            source,
            uint64(block.chainid),
            abi.decode(encodedRoute, (Route)),
            reward,
            claimant,
            providedAmounts,
            prover,
            sourceChainDomainID,
            proverData
        );
    }

    /**
     * @notice Fulfills an intent and initiates proving in one transaction
     * @dev Abstract function to be implemented by concrete settlement contracts
     * @param source The origin chain ID committed in the intent hash (Model C)
     * @param destination The destination chain ID committed in the intent hash (must equal block.chainid)
     * @param route The route information for the intent
     * @param reward The reward details (legs authenticated by the derived intent hash)
     * @param claimant Cross-VM compatible claimant identifier
     * @param providedAmounts Per-leg input the solver provides, index-aligned with `route.minTokens`
     * @param prover Address of prover on the destination chain
     * @param sourceChainDomainID The bridge transport domain id used to route the proof back to source
     * @param data Additional data for message formatting
     * @return The runtime's raw return data
     */
    function fulfillAndProve(
        uint64 source,
        uint64 destination,
        Route memory route,
        Reward memory reward,
        bytes32 claimant,
        uint256[] memory providedAmounts,
        address prover,
        uint64 sourceChainDomainID,
        bytes memory data
    ) public payable virtual returns (bytes memory);
}
