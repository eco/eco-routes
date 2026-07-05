// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {IPolicy} from "../interfaces/IPolicy.sol";
import {Semver} from "../libs/Semver.sol";
import {Whitelist} from "../libs/Whitelist.sol";
import {AddressConverter} from "../libs/AddressConverter.sol";
import {IntentLib} from "../types/Intent.sol";

/**
 * @title ScheduledPolicy
 * @notice Shared fact machinery for the three SCHEDULE settlement policies (Vesting, Milestone,
 *         DutchDecay). A schedule policy records a SINGLE hash-only fulfillment fact (like the atomic
 *         policies) and then releases the reward on its own SCHEDULE, so the fact is re-read rather than
 *         consumed. This base owns everything the schedule is agnostic to: the single-fulfillment stores,
 *         the same-chain / cross-chain fact resolution, the wrong-destination scrub and the cross-chain
 *         relay whitelist. The per-policy SCHEDULE (decay curve / vest window / milestone tranches) lives
 *         in the concrete subclasses.
 * @dev Standalone (NOT a {BasePolicy} subclass) so the same-chain fact can be synthesized from the
 *      destination store AND {previewRelease} can be a `view` (a schedule reads `block.timestamp`);
 *      {BasePolicy} fixes `previewRelease` as `pure`, which an override cannot relax. Two fact stores,
 *      exactly like the atomic model:
 *        - SAME-CHAIN: {recordFulfillment} (only the Portal) writes the one-shot `_destFulfillment`; the
 *          fact is synthesized with `destination == CHAIN_ID`.
 *        - CROSS-CHAIN: a whitelisted relay pushes the fact via a subclass entry into `_crossProven`
 *          (first-writer-wins). Dispatch is EVENT-IS-PROOF: {prove} emits {ScheduledProofDispatched} and
 *          a relay picks it up and records it on the source chain (a concrete bridge subclass could
 *          override {prove} to push over a mailbox, mirroring {StreamingPolicy}).
 *      {_recordedFact} resolves cross-chain first, else same-chain — so a schedule policy settles on
 *      either topology through one path.
 */
abstract contract ScheduledPolicy is IPolicy, Whitelist, Semver, ERC165 {
    using AddressConverter for address;

    /// @notice The local Portal/Inbox (the only caller allowed to record fulfillments).
    address public immutable PORTAL;

    /// @notice Local chain id (the destination id stamped on same-chain facts).
    uint64 public immutable CHAIN_ID;

    /// @notice SAME-CHAIN fulfillment store: intent hash -> the recorded `fulfillmentHash` (one-shot).
    /// @dev Written by {recordFulfillment}; a schedule intent is a SINGLE fulfillment (a second reverts).
    mapping(bytes32 => bytes32) internal _destFulfillment;

    /// @notice CROSS-CHAIN fulfillment store: intent hash -> the relay-pushed fact (first-writer-wins).
    mapping(bytes32 => ProofData) internal _crossProven;

    /// @notice Emitted by {prove} so an off-chain relay can record the fact on the source chain.
    /// @param intentHash The fulfilled intent.
    /// @param destination The fulfilling chain id (this chain).
    /// @param fulfillmentHash The recorded fulfillment commitment.
    event ScheduledProofDispatched(
        bytes32 indexed intentHash,
        uint64 destination,
        bytes32 fulfillmentHash
    );

    /**
     * @notice Wires the Portal and the whitelisted cross-chain relays.
     * @param portal The local Portal/Inbox.
     * @param relays Relays authorized to push cross-chain facts (as bytes32, cross-VM).
     */
    constructor(address portal, bytes32[] memory relays) Whitelist(relays) {
        if (portal == address(0)) revert ZeroPortal();
        PORTAL = portal;
        if (block.chainid > type(uint64).max) {
            revert ChainIdTooLarge(block.chainid);
        }
        CHAIN_ID = uint64(block.chainid);
    }

    /**
     * @inheritdoc IPolicy
     * @dev One-shot destination record (a schedule intent is a SINGLE fulfillment re-settled over time,
     *      NOT a re-fulfillable stream). Only the Portal may call. The `destination` is implied by
     *      {CHAIN_ID}.
     */
    function recordFulfillment(
        bytes32 intentHash,
        uint64 /* destination */,
        bytes32 fulfillmentHash
    ) external virtual {
        if (msg.sender != PORTAL) revert NotPortal(msg.sender);
        if (_destFulfillment[intentHash] != bytes32(0)) {
            revert IntentAlreadyFulfilled(intentHash);
        }
        _destFulfillment[intentHash] = fulfillmentHash;
    }

    /**
     * @inheritdoc IPolicy
     * @dev EVENT-IS-PROOF dispatch: for each intent emit its destination fact so a relay can record it on
     *      the source chain. Reverts {IntentNotFulfilled} for an unfulfilled intent. Any `msg.value` (a
     *      bridge fee for a concrete subclass) is refunded to `sender`. Must not revert on the happy path
     *      so {IInbox-fulfillAndProve} works.
     */
    function prove(
        address sender,
        uint64 /* sourceChainDomainID */,
        bytes32[] calldata intentHashes,
        bytes calldata /* data */
    ) external payable virtual {
        uint256 n = intentHashes.length;
        for (uint256 i; i < n; ++i) {
            bytes32 ih = intentHashes[i];
            bytes32 fh = _destFulfillment[ih];
            if (fh == bytes32(0)) revert IntentNotFulfilled(ih);
            emit ScheduledProofDispatched(ih, CHAIN_ID, fh);
        }
        if (msg.value > 0) {
            payable(sender).transfer(msg.value);
        }
    }

    /**
     * @inheritdoc IPolicy
     * @dev Wrong-destination scrub on the cross-chain store: if the accumulated fact was recorded for a
     *      chain other than the intent commits to, drop it (it can never legitimately settle). The
     *      same-chain synthesized fact (destination == {CHAIN_ID}) is never challengeable.
     */
    function challengeIntentProof(
        uint32 protocolVersion,
        uint64 source,
        uint64 destination,
        bytes32 routeHash,
        bytes32 rewardHash
    ) external {
        bytes32 intentHash = IntentLib.hashIntent(
            protocolVersion,
            source,
            destination,
            routeHash,
            rewardHash
        );
        ProofData memory x = _crossProven[intentHash];
        if (x.fulfillmentHash != bytes32(0) && x.destination != destination) {
            delete _crossProven[intentHash];
            emit IntentProofInvalidated(intentHash);
        }
    }

    /**
     * @notice The destination fulfillment commitment recorded same-chain for an intent (indexer view).
     */
    function destFulfillment(
        bytes32 intentHash
    ) external view returns (bytes32) {
        return _destFulfillment[intentHash];
    }

    /// @inheritdoc ERC165
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IPolicy).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    // ---------------------------------------------------------------------
    // Internal fact helpers (shared by the concrete schedule policies)
    // ---------------------------------------------------------------------

    /**
     * @notice Records a cross-chain fulfillment fact from a whitelisted relay (first-writer-wins).
     * @dev The two concrete relay entry points ({DutchDecayPolicy-recordProof} /
     *      {IStreamingPolicy-recordBatch}) funnel here. A zero `fulfillmentHash` is ignored; a
     *      re-delivery is skipped (first-writer-wins) so it can never overwrite a recorded fact.
     * @param intentHash The fulfilled intent.
     * @param destination The fulfilling chain id.
     * @param fulfillmentHash The fulfillment commitment bridged from the destination.
     */
    function _recordCrossProof(
        bytes32 intentHash,
        uint64 destination,
        bytes32 fulfillmentHash
    ) internal {
        validateWhitelisted(msg.sender.toBytes32());
        if (fulfillmentHash == bytes32(0)) return;
        if (_crossProven[intentHash].fulfillmentHash != bytes32(0)) {
            emit IntentAlreadyProven(intentHash);
            return;
        }
        _crossProven[intentHash] = ProofData({
            destination: destination,
            fulfillmentHash: fulfillmentHash
        });
        emit IntentProven(intentHash, destination, fulfillmentHash);
    }

    /**
     * @notice The RAW recorded fulfillment fact for an intent (cross-chain first, else same-chain synth).
     * @dev The cross-chain fact carries its own destination; a same-chain fact is synthesized with
     *      destination == {CHAIN_ID}. Returns the zero fact when neither store holds one. This is the
     *      hash the settle preimage is verified against — subclasses may TAG the value they expose via
     *      {IPolicy-provenIntents} (to block the generic single-shot settle) while still verifying against
     *      this raw hash.
     * @param intentHash The intent to resolve.
     * @return destination The fulfilling chain id (or 0 if unfulfilled).
     * @return fulfillmentHash The raw fulfillment commitment (or zero if unfulfilled).
     */
    function _recordedFact(
        bytes32 intentHash
    ) internal view returns (uint64 destination, bytes32 fulfillmentHash) {
        ProofData memory x = _crossProven[intentHash];
        if (x.fulfillmentHash != bytes32(0)) {
            return (x.destination, x.fulfillmentHash);
        }
        bytes32 d = _destFulfillment[intentHash];
        if (d != bytes32(0)) {
            return (CHAIN_ID, d);
        }
        return (0, bytes32(0));
    }
}
