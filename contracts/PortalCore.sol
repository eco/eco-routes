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
     * @notice The ERC-7683 adapter implementation this Portal falls back to.
     * @dev Immutable, set at construction (2nd ctor arg alongside the Account clone template). The
     *      ERC-7683 entry points ({open}/{openFor}/{resolve}/{resolveFor}/{fill}, plus the EIP-712
     *      helpers {domainSeparatorV4}/{GASLESS_CROSSCHAIN_ORDER_TYPEHASH}) are NO LONGER real functions on
     *      this lean Portal implementation — they live on {ERC7683Implementation}. A call for one of those
     *      selectors misses Solidity's generated dispatcher and hits {fallback}, which `delegatecall`s it
     *      here. Because this Portal is itself only ever reached via `delegatecall` from the {PortalProxy},
     *      this is a SECOND nested delegatecall: `address(this)` stays the proxy and `msg.sender` stays the
     *      original caller through both hops, so the adapter operates on the proxy's storage and identity.
     *      This is the deliberate extra hop the ERC-7683 (lower-priority) path pays so the core Portal
     *      reclaims the Settlers' bytecode.
     */
    address private immutable ERC7683_IMPLEMENTATION;

    /**
     * @notice Wires the ERC-7683 adapter implementation.
     * @param erc7683Implementation The {ERC7683Implementation} this Portal delegates the ERC-7683 surface
     *        to via {fallback}. A SINGLE shared instance serves every Portal version (it holds no
     *        version-specific or account-derivation state — it resolves + delegatecalls the pinned
     *        implementation for each call).
     */
    constructor(address erc7683Implementation) {
        ERC7683_IMPLEMENTATION = erc7683Implementation;
    }

    /**
     * @notice Delegates any selector this lean Portal does not implement to the ERC-7683 adapter.
     * @dev Only the detached ERC-7683 surface reaches here (every real Portal function is matched by
     *      Solidity's own dispatcher first). Mirrors {PortalProxy._delegate}: copy calldata, `delegatecall`
     *      the adapter, bubble the raw return/revert verbatim. `assembly ("memory-safe")` is REQUIRED — the
     *      via-IR pipeline otherwise drops the memory guard for this function and the inherited {_fulfill}'s
     *      stack allocation overflows (stack-too-deep) at compile time.
     */
    fallback() external payable {
        address impl = ERC7683_IMPLEMENTATION;
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }

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
