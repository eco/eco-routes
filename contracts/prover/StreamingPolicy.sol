// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {IPolicy} from "../interfaces/IPolicy.sol";
import {IStreamingPolicy} from "../interfaces/IStreamingPolicy.sol";
import {Semver} from "../libs/Semver.sol";
import {Whitelist} from "../libs/Whitelist.sol";
import {AddressConverter} from "../libs/AddressConverter.sol";
import {RewardMath} from "../libs/RewardMath.sol";
import {Reward, RewardToken, IntentLib} from "../types/Intent.sol";

/**
 * @title StreamingPolicy
 * @notice The STREAMING settlement policy — a standing intent fulfilled in successive SLICES that draw
 *         down a replenishable reward escrow (PR6, the lean batch-hash + preimage model). A streaming
 *         intent simply names this policy at `reward.prover`; the atomic policies stay one-shot.
 * @dev Standalone (like {LocalPolicy}) — NOT a {BasePolicy} subclass — because re-fulfillability changes
 *      the STORAGE SHAPE, not a flag. All streaming logic lives HERE (a separate contract with ~18 KB of
 *      headroom); the Portal only wires two thin entry points ({IntentSource-settleStream}/{closeStream}).
 *
 *      LIFECYCLE (lean, content-addressed):
 *        DEST fulfill  — {recordFulfillment} APPENDS the slice's `fulfillmentHash` to `_destHashes` and
 *                        emits {StreamSliceFulfilled}. Re-fulfillable: a second fulfill never reverts.
 *        DISPATCH      — {prove} hashes the whole `_destHashes` array into ONE
 *                        `batchHash = keccak256(abi.encode(intentHash, batchNonce, sliceHashes))`, emits
 *                        it, and DELETES `_destHashes` (storage consumed; the monotonic `batchNonce`
 *                        makes every batch globally unique). The dispatch is event-is-proof (Polymer
 *                        style) — a relay picks up {StreamBatchProven} and calls {recordBatch} on the
 *                        source chain (a concrete bridge subclass can override to push over a mailbox).
 *        SOURCE receipt— {recordBatch} (whitelisted relay) APPENDS the bridged `batchHash` to
 *                        `_srcBatches` and dedups a re-delivered one (M1).
 *        SETTLE        — {consumeStreamClaims} takes the slice preimages, recomputes each `batchHash`
 *                        (cross-chain) or slice hash (same-chain), REMOVES the matched entry by VALUE
 *                        (swap-pop; NO FIFO), and returns the per-slice payouts. Content-addressing +
 *                        remove-by-value structurally avoid H1 (no head to strand) and M1 (no head to
 *                        wedge). The Portal's Account pays the payouts in full or reverts, so an
 *                        under-funded batch is never partially consumed (L1: recoverable after top-up).
 *        CLOSE         — the keeper's {closeStream} is gated on {hasUnsettledFulfillment} (C2): it can
 *                        never sweep escrow owed to a solver with a proven-but-unsettled batch.
 */
contract StreamingPolicy is IStreamingPolicy, Whitelist, Semver, ERC165 {
    using AddressConverter for address;
    using AddressConverter for bytes32;

    /// @notice Identifies this policy's settlement mechanism.
    string public constant PROOF_TYPE = "Streaming";

    /// @notice The local Portal (the only caller allowed to record fulfillments / consume / close).
    address public immutable PORTAL;

    /// @notice Local chain id (the destination id stamped on same-chain facts).
    uint64 public immutable CHAIN_ID;

    /// @notice DESTINATION unproven slice array: intent hash -> ordered slice `fulfillmentHash`es.
    /// @dev Appended by {recordFulfillment}; DELETED by {prove} (consumed into a batch). Also the
    ///      same-chain settle store (consumed by {consumeStreamClaims} when no bridged batches exist).
    mapping(bytes32 => bytes32[]) internal _destHashes;

    /// @notice DESTINATION monotonic batch nonce per intent, folded into `batchHash` so every dispatched
    ///         batch is globally unique (identical slice content across two prove cycles never collides,
    ///         so the source dedup never false-positives).
    mapping(bytes32 => uint256) public destBatchNonce;

    /// @notice SOURCE accumulated unsettled batch commitments (content-addressed; NO FIFO ordering).
    mapping(bytes32 => bytes32[]) internal _srcBatches;

    /// @notice SOURCE dedup guard: intent hash -> batch hash -> already accumulated (M1). Permanent, so a
    ///         re-delivered batch (or one already settled and removed) is never re-appended.
    mapping(bytes32 => mapping(bytes32 => bool)) public batchSeen;

    /// @notice SOURCE fulfilling chain id recorded for an intent's bridged batches (challenge/refund gate).
    mapping(bytes32 => uint64) public srcDestination;

    /// @notice Whether the one-time `flat` reward has already been charged for an intent (anti-dust).
    mapping(bytes32 => bool) public flatCharged;

    /// @notice Whether the keeper has CLOSED the stream (terminal record; set via {markClosed}).
    mapping(bytes32 => bool) public closed;

    /**
     * @notice Wires the Portal and the whitelisted cross-chain relays.
     * @param portal The local Portal/Inbox (records fulfillments, consumes claims, closes streams).
     * @param relays Relays authorized to push bridged batches via {recordBatch} (as bytes32, cross-VM).
     */
    constructor(
        address portal,
        bytes32[] memory relays
    ) Whitelist(relays) {
        if (portal == address(0)) revert ZeroPortal();
        PORTAL = portal;
        if (block.chainid > type(uint64).max) {
            revert ChainIdTooLarge(block.chainid);
        }
        CHAIN_ID = uint64(block.chainid);
    }

    /// @inheritdoc IPolicy
    function getProofType() external pure returns (string memory) {
        return PROOF_TYPE;
    }

    // ---------------------------------------------------------------------
    // DESTINATION — re-fulfillable record + batch dispatch
    // ---------------------------------------------------------------------

    /**
     * @inheritdoc IPolicy
     * @dev STREAMING override of the one-slot atomic record: APPENDS the slice's `fulfillmentHash` to the
     *      per-intent array so a second fulfill NEVER reverts (that is the streaming property). Only the
     *      Portal may call. The `destination` argument is implied by {CHAIN_ID}. Emits the slice's array
     *      index (`seq`) + hash so an off-chain indexer can reconstruct the batch grouping.
     */
    function recordFulfillment(
        bytes32 intentHash,
        uint64 /* destination */,
        bytes32 fulfillmentHash
    ) external {
        if (msg.sender != PORTAL) revert NotPortal(msg.sender);
        uint256 seq = _destHashes[intentHash].length;
        _destHashes[intentHash].push(fulfillmentHash);
        emit StreamSliceFulfilled(intentHash, seq, fulfillmentHash);
    }

    /**
     * @inheritdoc IPolicy
     * @dev DISPATCH: for each intent, hash the whole accumulated `_destHashes` array into ONE `batchHash`
     *      (with the monotonic `destBatchNonce`), emit {StreamBatchProven}, and DELETE `_destHashes`
     *      (storage consumed — a later fulfill starts a fresh batch). Reverts {IntentNotFulfilled} for an
     *      intent with no unproven slices. Event-is-proof: a relay reads the event and calls {recordBatch}
     *      on the source chain; any `msg.value` (a bridge fee for subclasses) is refunded to `sender`.
     */
    function prove(
        address sender,
        uint64 /* sourceChainDomainID */,
        bytes32[] calldata intentHashes,
        bytes calldata /* data */
    ) external payable {
        uint256 size = intentHashes.length;
        for (uint256 i; i < size; ++i) {
            bytes32 ih = intentHashes[i];
            bytes32[] storage arr = _destHashes[ih];
            uint256 n = arr.length;
            if (n == 0) revert IntentNotFulfilled(ih);

            bytes32[] memory sliceHashes = new bytes32[](n);
            for (uint256 s; s < n; ++s) {
                sliceHashes[s] = arr[s];
            }

            uint256 nonce = destBatchNonce[ih]++;
            bytes32 batchHash = keccak256(
                abi.encode(ih, nonce, sliceHashes)
            );
            delete _destHashes[ih];

            emit StreamBatchProven(ih, nonce, batchHash, sliceHashes);
        }

        if (msg.value > 0) {
            payable(sender).transfer(msg.value);
        }
    }

    // ---------------------------------------------------------------------
    // SOURCE — accumulate bridged batches (dedup)
    // ---------------------------------------------------------------------

    /// @inheritdoc IStreamingPolicy
    function recordBatch(
        bytes32 intentHash,
        uint64 destination,
        bytes32 batchHash
    ) external {
        validateWhitelisted(msg.sender.toBytes32());
        if (batchHash == bytes32(0)) return;
        // M1 dedup: a re-delivered (or already-settled-and-removed) batch is skipped, never re-appended,
        // so a duplicate can never wedge settlement.
        if (batchSeen[intentHash][batchHash]) {
            emit IntentAlreadyProven(intentHash);
            return;
        }
        batchSeen[intentHash][batchHash] = true;
        _srcBatches[intentHash].push(batchHash);
        srcDestination[intentHash] = destination;
        emit StreamBatchAccumulated(intentHash, destination, batchHash);
    }

    // ---------------------------------------------------------------------
    // SETTLE — verify + consume + compute payouts
    // ---------------------------------------------------------------------

    /// @inheritdoc IStreamingPolicy
    function consumeStreamClaims(
        bytes32 intentHash,
        Reward calldata reward,
        bytes calldata batchData
    ) external returns (bytes memory payoutData) {
        if (msg.sender != PORTAL) revert NotAuthorized(msg.sender);

        // Decode the deeply-nested batches HERE (not in the Portal, which would unroll ~2 KB of bytecode).
        StreamBatch[] memory batches = abi.decode(batchData, (StreamBatch[]));

        uint256 nb = batches.length;
        uint256 total;
        for (uint256 b; b < nb; ++b) {
            total += batches[b].slices.length;
        }
        if (total == 0) revert NothingToSettle();

        address[] memory claimants = new address[](total);
        uint256[][] memory payouts = new uint256[][](total);

        // CROSS-CHAIN when bridged batches were accumulated; else SAME-CHAIN (consume the local
        // destination slices directly).
        bool crossChain = _srcBatches[intentHash].length != 0;

        // `flat` is charged at most once per intent (anti-dust); only the first slice of the first settle
        // that ever pays out carries it.
        bool chargeFlat = !flatCharged[intentHash];

        uint256 k;
        for (uint256 b; b < nb; ++b) {
            StreamSlice[] memory slices = batches[b].slices;
            uint256 ns = slices.length;
            bytes32[] memory sliceHashes = new bytes32[](ns);

            for (uint256 s; s < ns; ++s) {
                StreamSlice memory slice = slices[s];
                sliceHashes[s] = IntentLib.fulfillmentHash(
                    intentHash,
                    slice.claimant,
                    slice.fulfilled
                );
                claimants[k] = slice.claimant.toAddress();
                payouts[k] = _slicePayout(reward, slice.fulfilled, chargeFlat);
                chargeFlat = false;
                ++k;
            }

            if (crossChain) {
                bytes32 batchHash = keccak256(
                    abi.encode(intentHash, batches[b].nonce, sliceHashes)
                );
                _removeBatch(intentHash, batchHash);
            } else {
                _removeSlices(intentHash, sliceHashes);
            }
        }

        if (!flatCharged[intentHash]) {
            flatCharged[intentHash] = true;
        }

        payoutData = abi.encode(claimants, payouts);
    }

    // ---------------------------------------------------------------------
    // Views + close
    // ---------------------------------------------------------------------

    /// @inheritdoc IStreamingPolicy
    function hasUnsettledFulfillment(
        bytes32 intentHash
    ) external view returns (bool) {
        return
            _srcBatches[intentHash].length != 0 ||
            _destHashes[intentHash].length != 0;
    }

    /// @inheritdoc IStreamingPolicy
    function markClosed(bytes32 intentHash) external {
        if (msg.sender != PORTAL) revert NotAuthorized(msg.sender);
        closed[intentHash] = true;
        emit StreamMarkedClosed(intentHash);
    }

    /**
     * @inheritdoc IPolicy
     * @dev Returns a NON-ZERO fact whenever a proven-but-unsettled batch/slice exists (so the source
     *      {IntentSource-_validateRefund} gate blocks a pre-deadline refund of an owed stream). The
     *      `fulfillmentHash` returned is a BATCH commitment, NOT a single slice's hash, so the generic
     *      {IntentSource-settle} preimage check fails on a streaming intent — streaming must settle via
     *      {IntentSource-settleStream}.
     */
    function provenIntents(
        bytes32 intentHash
    ) external view returns (ProofData memory) {
        bytes32[] storage src = _srcBatches[intentHash];
        uint256 n = src.length;
        if (n != 0) {
            return
                ProofData({
                    destination: srcDestination[intentHash],
                    fulfillmentHash: src[n - 1]
                });
        }
        bytes32[] storage dst = _destHashes[intentHash];
        uint256 m = dst.length;
        if (m != 0) {
            return
                ProofData({destination: CHAIN_ID, fulfillmentHash: dst[m - 1]});
        }
        return ProofData({destination: 0, fulfillmentHash: bytes32(0)});
    }

    /**
     * @inheritdoc IPolicy
     * @dev Wrong-destination scrub: if the intent's accumulated bridged batches were recorded for a chain
     *      other than the intent commits to, drop them all (they can never legitimately settle).
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
        if (
            _srcBatches[intentHash].length != 0 &&
            srcDestination[intentHash] != destination
        ) {
            delete _srcBatches[intentHash];
            emit IntentProofInvalidated(intentHash);
        }
    }

    /**
     * @inheritdoc IPolicy
     * @dev The atomic single-slice curve, provided to satisfy {IPolicy}. Streaming never routes through
     *      the generic Account `withdraw`/`previewRelease` path (it uses {consumeStreamClaims} +
     *      `withdrawStream`); this is a harmless view for interface completeness.
     */
    function previewRelease(
        Reward calldata reward,
        uint256[] calldata fulfilled
    ) external pure returns (uint256[] memory payNow) {
        return _slicePayout(reward, fulfilled, true);
    }

    /// @notice The unproven destination slice hashes for an intent (indexer/test view).
    function destSlices(
        bytes32 intentHash
    ) external view returns (bytes32[] memory) {
        return _destHashes[intentHash];
    }

    /// @notice The unsettled accumulated source batch hashes for an intent (indexer/test view).
    function srcBatches(
        bytes32 intentHash
    ) external view returns (bytes32[] memory) {
        return _srcBatches[intentHash];
    }

    /// @inheritdoc ERC165
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IPolicy).interfaceId ||
            interfaceId == type(IStreamingPolicy).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /**
     * @notice One slice's per-leg uncapped payout (rate + one-time flat).
     * @dev PAIRED legs (`j < fulfilled.length`): `fulfilled[j]*rate/WAD` (+ `leg.flat` if `chargeFlat`).
     *      EXTRA flat-only legs: `leg.flat` if `chargeFlat`, else 0. Index-aligned with `reward.tokens`.
     */
    function _slicePayout(
        Reward calldata reward,
        uint256[] memory fulfilled,
        bool chargeFlat
    ) internal pure returns (uint256[] memory payNow) {
        uint256 legCount = reward.tokens.length;
        uint256 fulfilledLen = fulfilled.length;
        payNow = new uint256[](legCount);
        for (uint256 j; j < legCount; ++j) {
            RewardToken calldata leg = reward.tokens[j];
            if (j < fulfilledLen) {
                payNow[j] = RewardMath.reward(
                    fulfilled[j],
                    leg.rate,
                    chargeFlat ? leg.flat : 0
                );
            } else {
                payNow[j] = chargeFlat ? leg.flat : 0;
            }
        }
    }

    /// @notice Removes a settled batch by value (swap-pop). Reverts {UnknownBatch} if absent.
    function _removeBatch(bytes32 intentHash, bytes32 batchHash) internal {
        bytes32[] storage arr = _srcBatches[intentHash];
        uint256 n = arr.length;
        for (uint256 i; i < n; ++i) {
            if (arr[i] == batchHash) {
                arr[i] = arr[n - 1];
                arr.pop();
                return;
            }
        }
        revert UnknownBatch(intentHash);
    }

    /// @notice Removes each same-chain slice by value (swap-pop). Reverts {UnknownSlice} if any absent.
    function _removeSlices(
        bytes32 intentHash,
        bytes32[] memory sliceHashes
    ) internal {
        bytes32[] storage arr = _destHashes[intentHash];
        uint256 ns = sliceHashes.length;
        for (uint256 s; s < ns; ++s) {
            bytes32 target = sliceHashes[s];
            uint256 n = arr.length;
            bool found;
            for (uint256 i; i < n; ++i) {
                if (arr[i] == target) {
                    arr[i] = arr[n - 1];
                    arr.pop();
                    found = true;
                    break;
                }
            }
            if (!found) revert UnknownSlice(intentHash);
        }
    }
}
