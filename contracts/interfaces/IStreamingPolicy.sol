// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPolicy} from "./IPolicy.sol";
import {Reward} from "../types/Intent.sol";

/**
 * @title IStreamingPolicy
 * @notice Settlement-policy surface for STREAMING intents — a standing intent fulfilled in successive
 *         SLICES that draw down a replenishable reward escrow, rather than the one-shot atomic settle.
 * @dev The lean streaming model (PR6). Re-fulfillability is the POLICY's STORAGE SHAPE, not a core flag:
 *
 *      DESTINATION — {IPolicy-recordFulfillment} is overridden to APPEND each slice's `fulfillmentHash`
 *      to a per-intent array instead of the one-slot atomic store, so a second fulfill never reverts.
 *
 *      CROSS-CHAIN DISPATCH — {IPolicy-prove} hashes the whole accumulated slice array into ONE
 *      `batchHash = keccak256(abi.encode(intentHash, batchNonce, sliceHashes))` (the monotonic
 *      `batchNonce` makes every batch globally unique), sends `batchHash` cross-chain, and DELETES the
 *      destination array (storage consumed — a later fulfill starts a fresh batch).
 *
 *      SOURCE RECEIPT — {recordBatch} APPENDS the bridged `batchHash` to a per-intent array
 *      (content-addressed, NO FIFO ordering) and dedups a re-delivered `batchHash` (M1: never wedge).
 *
 *      SETTLE — {consumeStreamClaims} takes the slice PREIMAGES for the unsettled batches, verifies each
 *      recomputed `batchHash` against the stored set (or, same-chain, each slice hash against the
 *      destination array), REMOVES the settled batch (consume+delete), and returns the per-slice payouts
 *      (rate+flat, `flat` charged once). Because batches are content-addressed and removed by value there
 *      is no FIFO head to strand (H1) or wedge (M1).
 */
interface IStreamingPolicy is IPolicy {
    /**
     * @notice One fulfilled slice's settle preimage.
     * @param claimant Cross-VM claimant identifier committed at fulfillment (EVM address in low 20 bytes).
     * @param fulfilled Per-leg delivered amounts committed at fulfillment (paired prefix).
     */
    struct StreamSlice {
        bytes32 claimant;
        uint256[] fulfilled;
    }

    /**
     * @notice One proven batch's settle preimage: its `batchNonce` plus every slice it grouped.
     * @dev Cross-chain: the policy recomputes `batchHash = keccak256(abi.encode(intentHash, nonce,
     *      sliceHashes))` and matches it against the accumulated unsettled set. Same-chain (no bridge, no
     *      batch): `nonce` is ignored and each slice hash is matched against the destination array.
     * @param nonce The batch nonce assigned at {IPolicy-prove} time (ignored for the same-chain path).
     * @param slices The slice preimages that made up this batch.
     */
    struct StreamBatch {
        uint256 nonce;
        StreamSlice[] slices;
    }

    /// @notice A supplied batch does not match any unsettled batch recorded for the intent.
    /// @param intentHash The intent being settled.
    error UnknownBatch(bytes32 intentHash);

    /// @notice A supplied same-chain slice does not match any unsettled destination slice for the intent.
    /// @param intentHash The intent being settled.
    error UnknownSlice(bytes32 intentHash);

    /// @notice {recordBatch}/{markClosed}/{consumeStreamClaims} caller is not authorized.
    /// @param caller The unauthorized caller.
    error NotAuthorized(address caller);

    /// @notice A streaming settle supplied no batches/slices to consume.
    error NothingToSettle();

    /// @notice Emitted on each destination fulfillment slice (re-fulfillable append).
    /// @param intentHash The streamed intent.
    /// @param seq The slice's index within the current (unproven) destination batch.
    /// @param fulfillmentHash The slice commitment `keccak256(abi.encode(intentHash, claimant, fulfilled))`.
    event StreamSliceFulfilled(
        bytes32 indexed intentHash,
        uint256 seq,
        bytes32 fulfillmentHash
    );

    /// @notice Emitted when a destination batch is hashed and dispatched cross-chain (destination array
    ///         consumed).
    /// @param intentHash The streamed intent.
    /// @param batchNonce The monotonic nonce folded into `batchHash`.
    /// @param batchHash The dispatched batch commitment.
    /// @param sliceHashes The slice hashes the batch grouped (so off-chain can reconstruct the preimages).
    event StreamBatchProven(
        bytes32 indexed intentHash,
        uint256 batchNonce,
        bytes32 batchHash,
        bytes32[] sliceHashes
    );

    /// @notice Emitted when a bridged batch is accumulated on the source chain.
    /// @param intentHash The streamed intent.
    /// @param destination The fulfilling chain id the batch was proven on.
    /// @param batchHash The accumulated batch commitment.
    event StreamBatchAccumulated(
        bytes32 indexed intentHash,
        uint64 destination,
        bytes32 batchHash
    );

    /// @notice Emitted when the keeper closes a stream (terminal).
    /// @param intentHash The streamed intent.
    event StreamMarkedClosed(bytes32 indexed intentHash);

    /**
     * @notice Accumulates a bridged batch commitment on the source chain (the cross-chain receipt).
     * @dev Only a whitelisted relay may call. Dedups a re-delivered `(intentHash, batchHash)` (M1) so a
     *      duplicate can never wedge settlement; otherwise appends `batchHash` to the intent's unsettled
     *      set. A zero `batchHash` is ignored.
     * @param intentHash The streamed intent.
     * @param destination The fulfilling chain id the batch was proven on.
     * @param batchHash The batch commitment from the destination {IPolicy-prove}.
     */
    function recordBatch(
        bytes32 intentHash,
        uint64 destination,
        bytes32 batchHash
    ) external;

    /**
     * @notice Verifies and CONSUMES the supplied unsettled batches, returning the per-slice payouts.
     * @dev Only the Portal may call (it is a settlement effect that mutates the unsettled set + the
     *      `flatCharged` ledger). The batches + the payouts cross the Portal as OPAQUE `bytes` so the
     *      Portal never ABI-decodes the deeply-nested {StreamBatch}[] type (that unrolls into ~2 KB of
     *      Portal bytecode); the decode/encode happens HERE (in the policy, which has headroom). For each
     *      decoded batch it recomputes the `batchHash` (cross-chain) or each slice hash (same-chain),
     *      verifies membership in the unsettled store, REMOVES it (consume+delete), and accumulates the
     *      slice payouts. Reverts {UnknownBatch}/{UnknownSlice} if a batch/slice is not recorded (or
     *      already settled). The returned payouts are UNCAPPED (rate+flat, `flat` charged at most once per
     *      intent); the Account pays them in full or reverts, so an under-funded batch is never partially
     *      consumed (the whole settle rolls back and stays recoverable after a top-up — L1).
     * @param intentHash The streamed intent.
     * @param reward The reward spec (defines the per-leg rate/flat curve).
     * @param batchData `abi.encode(StreamBatch[])` — the unsettled batches with their slice preimages.
     * @return payoutData `abi.encode(address[] claimants, uint256[][] payouts)` — the per-slice EVM
     *         claimant + per-leg uncapped payout, forwarded verbatim by the Portal to the Account.
     */
    function consumeStreamClaims(
        bytes32 intentHash,
        Reward calldata reward,
        bytes calldata batchData
    ) external returns (bytes memory payoutData);

    /**
     * @notice Whether a proven-but-unsettled fulfillment exists for `intentHash` (the {closeStream}
     *         anti-rug signal — C2).
     * @dev True while any bridged batch is unsettled on the source, OR any destination slice is
     *      unsettled same-chain. The keeper's terminal {closeStream} sweep is gated on this being FALSE
     *      so it can never rug a solver owed for a proven-but-unsettled batch.
     * @param intentHash The streamed intent.
     * @return True iff a solver is still owed for a proven-but-unsettled batch/slice.
     */
    function hasUnsettledFulfillment(
        bytes32 intentHash
    ) external view returns (bool);

    /**
     * @notice Marks a stream CLOSED (terminal). Only the Portal (via {closeStream}) may call.
     * @param intentHash The streamed intent.
     */
    function markClosed(bytes32 intentHash) external;
}
