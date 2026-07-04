/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Intent, Reward, RewardToken} from "../types/Intent.sol";

/**
 * @title IIntentSource
 * @notice Interface for managing cross-chain intents and their associated rewards on the source chain
 * @dev This contract works in conjunction with a portal contract on the destination chain
 *      and a prover contract for verification. It handles intent creation, funding,
 *      and reward distribution.
 */
interface IIntentSource {
    /// @notice Intent lifecycle status
    enum Status {
        Initial, /// @dev Intent created, may be partially funded but not fully funded
        Funded, /// @dev Intent has been fully funded with all required rewards
        Withdrawn, /// @dev Rewards have been withdrawn by claimant
        Refunded /// @dev Rewards have been refunded to keeper
    }

    /**
     * @notice Indicates an attempt to publish a duplicate intent
     * @param intentHash The hash of the pre-existing intent
     */
    error IntentAlreadyExists(bytes32 intentHash);

    /**
     * @notice Indicates a premature refund attempt before intent completion
     * @param intentHash The hash of the unclaimed intent
     */
    error IntentNotClaimed(bytes32 intentHash);

    /**
     * @notice Indicates mismatched array lengths in batch operations
     */
    error ArrayLengthMismatch();

    /**
     * @notice Indicates insufficient funds to complete the intent funding
     * @param intentHash The hash of the intent that couldn't be funded
     */
    error InsufficientFunds(bytes32 intentHash);

    /// @notice Thrown when intent status is invalid for funding operation
    error InvalidStatusForFunding(Status status);

    /// @notice Thrown when intent status is invalid for withdrawal operation
    error InvalidStatusForWithdrawal(Status status);

    /// @notice Thrown when attempting to recover an invalid token (zero address or reward token)
    error InvalidRecoverToken(address token);

    /// @notice Thrown when intent status is invalid for refund operation or deadline not reached
    error InvalidStatusForRefund(
        Status status,
        uint256 currentTime,
        uint256 deadline
    );

    /// @notice Thrown when claimant address is address zero or not a valid EVM address
    error InvalidClaimant();

    /// @notice Thrown when caller is not the reward keeper
    error NotKeeperCaller(address caller);

    /// @notice Thrown when {closeStream} is attempted while a proven-but-unsettled batch/slice exists
    /// @dev C2 anti-rug: {closeStream} is a terminal keeper sweep, so — like {refund}/{executeAsOwner} —
    ///      it must not drain escrow owed to a solver whose fulfillment is proven but not yet settled. The
    ///      keeper must let the pending batch(es) settle first (settlement is permissionless).
    /// @param intentHash The hash of the intent whose stream cannot yet be closed
    error PendingProofBlocksClose(bytes32 intentHash);

    /**
     * @notice A source-side operation was attempted on a chain whose id is not the intent's committed
     *         `source`
     * @dev Belt-and-braces on top of the Model C address separation: fund / settle / refund / recover /
     *      executeAsOwner all resolve the SOURCE (escrow) account keyed by `intent.source`, so they are
     *      only valid on the source chain (`intent.source == block.chainid`). This keeps a source-side op
     *      on the destination chain from ever reaching a cross-chain intent's destination account.
     * @param current The current chain id (block.chainid)
     * @param expected The intent's committed source chain id
     */
    error WrongSourceChain(uint64 current, uint64 expected);

    /**
     * @notice The supplied (claimant, fulfilled[]) preimage does not match the proven fulfillment hash
     * @param intentHash The hash of the intent being settled
     */
    error InvalidFulfillmentProof(bytes32 intentHash);

    /// @notice Thrown when {executeAsOwner} is called by someone other than the reward keeper
    /// @param caller The unauthorized caller
    error NotAccountOwner(address caller);

    /**
     * @notice Thrown when {executeAsOwner} is attempted while the Account holds a LIVE escrow
     * @dev Anti-rug: a Funded intent whose reward is still live (has legs and before the deadline) or
     *      that already carries a valid destination proof may be owed to a solver, so the keeper cannot
     *      cook their own Account out from under it.
     * @param intentHash The hash of the locked intent
     */
    error AccountLocked(bytes32 intentHash);

    /**
     * @notice Signals the creation of a new cross-chain intent
     * @param intentHash Unique identifier of the intent
     * @param destination Destination chain ID
     * @param route Encoded route data for the destination chain
     * @param keeper Intent originator address
     * @param prover Prover contract address
     * @param rewardDeadline Timestamp for reward claim eligibility
     * @param rewardTokens Reward legs (rate+flat); native folds in as a leg with token==address(0)
     */
    event IntentPublished(
        bytes32 indexed intentHash,
        uint64 destination,
        bytes route,
        address indexed keeper,
        address indexed prover,
        uint64 rewardDeadline,
        RewardToken[] rewardTokens
    );

    /**
     * @notice Signals funding of an intent
     * @param intentHash The hash of the funded intent
     * @param funder The address providing the funding
     * @param complete Whether the intent was completely funded (true) or partially funded (false)
     */
    event IntentFunded(bytes32 intentHash, address funder, bool complete);

    /**
     * @notice Signals successful reward withdrawal
     * @param intentHash The hash of the claimed intent
     * @param claimant The address receiving the rewards
     */
    event IntentWithdrawn(bytes32 intentHash, address indexed claimant);

    /**
     * @notice Signals successful reward refund
     * @param intentHash The hash of the refunded intent
     * @param refundee The address receiving the refund
     */
    event IntentRefunded(bytes32 intentHash, address indexed refundee);

    /**
     * @notice A keeper-committed reward/refund hook reverted (or its `hooks` data was malformed) and was
     *         caught, so the core settle/refund still completed
     * @dev Hook invocation is best-effort by design (CEI: the core reward payout / refund and the terminal
     *      status are committed BEFORE the hook runs). A reverting hook therefore cannot strand an
     *      already-paid solver or permanently lock a keeper's refund — it only forgoes the hook's own
     *      side effects. This event surfaces that a hook did not run to completion. The hook is
     *      keeper-committed (inside the reward hash) and so is self-harm for a hostile keeper.
     * @param intentHash The hash of the intent whose hook reverted
     * @param index Which hook slot reverted (0 = reward hook on settle, 1 = refund hook on refund)
     */
    event HookReverted(bytes32 indexed intentHash, uint256 index);

    /**
     * @notice Signals a streaming settle paid out one or more slices to their claimants
     * @param intentHash The hash of the streamed intent
     */
    event StreamSettled(bytes32 indexed intentHash);

    /**
     * @notice Signals the keeper closed a stream and reclaimed the remaining escrow
     * @param intentHash The hash of the streamed intent
     * @param keeper The keeper that received the remaining escrow
     */
    event StreamClosed(bytes32 indexed intentHash, address indexed keeper);

    /**
     * @notice Signals successful token recovery from an intent account
     * @dev Emitted when tokens that were accidentally sent to a account are recovered
     *      Only tokens not part of the intent's reward structure can be recovered
     * @param intentHash The hash of the intent whose account had tokens recovered
     * @param refundee The address receiving the recovered tokens (typically the intent keeper)
     * @param token The address of the token contract that was recovered
     */
    event IntentTokenRecovered(
        bytes32 intentHash,
        address indexed refundee,
        address indexed token
    );

    /**
     * @notice Retrieves the current reward claim status for an intent
     * @param intentHash The hash of the intent
     * @return status Current reward status
     */
    function getRewardStatus(
        bytes32 intentHash
    ) external view returns (Status status);

    /**
     * @notice Computes the hash components of an intent
     * @param intent The intent to hash
     * @return intentHash Combined hash of route and reward components
     * @return routeHash Hash of the route specifications
     * @return rewardHash Hash of the reward specifications
     */
    function getIntentHash(
        Intent memory intent
    )
        external
        pure
        returns (bytes32 intentHash, bytes32 routeHash, bytes32 rewardHash);

    /**
     * @notice Computes the hash components of an intent
     * @param source Origin chain ID for the intent
     * @param destination Destination chain ID for the intent
     * @param route Encoded route data for the intent as bytes
     * @param reward The reward structure containing distribution details
     * @return intentHash Combined hash of route and reward components
     * @return routeHash Hash of the route specifications
     * @return rewardHash Hash of the reward specifications
     */
    function getIntentHash(
        uint64 source,
        uint64 destination,
        bytes memory route,
        Reward memory reward
    )
        external
        pure
        returns (bytes32 intentHash, bytes32 routeHash, bytes32 rewardHash);

    /**
     * @notice Computes the deterministic (source/escrow) account address for an intent
     * @param intent The intent to calculate the account address for
     * @return Predicted account address (the source-side escrow account)
     */
    function intentAccountAddress(
        Intent calldata intent
    ) external view returns (address);

    /**
     * @notice Computes the deterministic (source/escrow) account address for an intent
     * @param source Origin chain ID for the intent
     * @param destination Destination chain ID for the intent
     * @param route Encoded route data for the intent as bytes
     * @param reward The reward structure containing distribution details
     * @return Predicted account address (the source-side escrow account)
     */
    function intentAccountAddress(
        uint64 source,
        uint64 destination,
        bytes memory route,
        Reward calldata reward
    ) external view returns (address);

    /**
     * @notice Checks if an intent's rewards are valid and fully funded
     * @param intent The intent to validate
     * @return True if the intent is properly funded
     */
    function isIntentFunded(
        Intent calldata intent
    ) external view returns (bool);

    /**
     * @notice Checks if an intent's rewards are valid and fully funded
     * @param source Origin chain ID for the intent
     * @param destination Destination chain ID for the intent
     * @param route Encoded route data for the intent as bytes
     * @param reward The reward structure containing distribution details
     * @return True if the intent is properly funded
     */
    function isIntentFunded(
        uint64 source,
        uint64 destination,
        bytes memory route,
        Reward calldata reward
    ) external view returns (bool);

    /**
     * @notice Creates a new cross-chain intent with associated rewards
     * @dev Intent must be proven on source chain before expiration for valid reward claims
     * @param intent The complete intent specification
     * @return intentHash Unique identifier of the created intent
     * @return account Address of the created account
     */
    function publish(
        Intent calldata intent
    ) external returns (bytes32 intentHash, address account);

    /**
     * @notice Creates a new cross-chain intent with associated rewards
     * @dev Intent must be proven on source chain before expiration for valid reward claims
     * @param source Origin chain ID for the intent
     * @param destination Destination chain ID for the intent
     * @param route Encoded route data for the intent as bytes
     * @param reward The reward structure containing distribution details
     * @return intentHash Unique identifier of the created intent
     * @return account Address of the created account
     */
    function publish(
        uint64 source,
        uint64 destination,
        bytes memory route,
        Reward memory reward
    ) external returns (bytes32 intentHash, address account);

    /**
     * @notice Creates and funds an intent in a single transaction
     * @param intent The complete intent specification
     * @param allowPartial Whether to allow partial funding
     * @return intentHash Unique identifier of the created and funded intent
     * @return account Address of the created account
     */
    function publishAndFund(
        Intent calldata intent,
        bool allowPartial
    ) external payable returns (bytes32 intentHash, address account);

    /**
     * @notice Creates and funds an intent in a single transaction
     * @param source Origin chain ID for the intent
     * @param destination Destination chain ID for the intent
     * @param route Encoded route data for the intent as bytes
     * @param reward The reward structure containing distribution details
     * @param allowPartial Whether to allow partial funding
     * @return intentHash Unique identifier of the created and funded intent
     * @return account Address of the created account
     */
    function publishAndFund(
        uint64 source,
        uint64 destination,
        bytes memory route,
        Reward memory reward,
        bool allowPartial
    ) external payable returns (bytes32 intentHash, address account);

    /**
     * @notice Funds an existing intent
     * @param source Origin chain ID for the intent
     * @param destination Destination chain ID for the intent
     * @param routeHash The hash of the intent's route component
     * @param reward The reward specification
     * @param allowPartial Whether to allow partial funding
     * @return intentHash The hash of the funded intent
     */
    function fund(
        uint64 source,
        uint64 destination,
        bytes32 routeHash,
        Reward calldata reward,
        bool allowPartial
    ) external payable returns (bytes32 intentHash);

    /**
     * @notice Funds an intent on behalf of another address using permit
     * @param source Origin chain ID for the intent
     * @param destination Destination chain ID for the intent
     * @param routeHash The hash of the intent's route component
     * @param reward The reward specification
     * @param allowPartial Whether to accept partial funding
     * @param fundingAddress The address providing the funding
     * @param permitContract The permit contract address for external token approvals
     * @return intentHash The hash of the funded intent
     */
    function fundFor(
        uint64 source,
        uint64 destination,
        bytes32 routeHash,
        Reward calldata reward,
        bool allowPartial,
        address fundingAddress,
        address permitContract
    ) external payable returns (bytes32 intentHash);

    /**
     * @notice Creates and funds an intent on behalf of another address
     * @param intent The complete intent specification
     * @param allowPartial Whether to accept partial funding
     * @param funder The address providing the funding
     * @param permitContract The permit contract for token approvals
     * @return intentHash The hash of the created and funded intent
     * @return account Address of the created account
     */
    function publishAndFundFor(
        Intent calldata intent,
        bool allowPartial,
        address funder,
        address permitContract
    ) external payable returns (bytes32 intentHash, address account);

    /**
     * @notice Creates and funds an intent on behalf of another address
     * @param source Origin chain ID for the intent
     * @param destination Destination chain ID for the intent
     * @param route Encoded route data for the intent as bytes
     * @param reward The reward structure containing distribution details
     * @param allowPartial Whether to accept partial funding
     * @param funder The address providing the funding
     * @param permitContract The permit contract for token approvals
     * @return intentHash The hash of the created and funded intent
     * @return account Address of the created account
     */
    function publishAndFundFor(
        uint64 source,
        uint64 destination,
        bytes memory route,
        Reward calldata reward,
        bool allowPartial,
        address funder,
        address permitContract
    ) external payable returns (bytes32 intentHash, address account);

    /**
     * @notice Settles rewards for a successfully fulfilled and proven intent
     * @dev The caller supplies the proven `(claimant, fulfilled[])` preimage, verified against the
     *      prover's hash-only fact before payout.
     * @param source Origin chain ID for the intent
     * @param destination Destination chain ID for the intent
     * @param routeHash The hash of the intent's route component
     * @param reward The reward specification
     * @param claimant Cross-VM claimant identifier committed in the fulfillment
     * @param fulfilled Per-leg delivered amounts committed in the fulfillment (paired prefix)
     */
    function settle(
        uint64 source,
        uint64 destination,
        bytes32 routeHash,
        Reward calldata reward,
        bytes32 claimant,
        uint256[] calldata fulfilled
    ) external;

    /**
     * @notice Returns rewards to the intent keeper
     * @param source Origin chain ID for the intent
     * @param destination Destination chain ID for the intent
     * @param routeHash The hash of the intent's route component
     * @param reward The reward specification
     */
    function refund(
        uint64 source,
        uint64 destination,
        bytes32 routeHash,
        Reward calldata reward
    ) external;

    /**
     * @notice Returns rewards to a specified address (only callable by reward keeper)
     * @param source Origin chain ID for the intent
     * @param destination Destination chain ID for the intent
     * @param routeHash The hash of the intent's route component
     * @param reward The reward specification
     * @param refundee Address to receive the refunded rewards
     */
    function refundTo(
        uint64 source,
        uint64 destination,
        bytes32 routeHash,
        Reward calldata reward,
        address refundee
    ) external;

    /**
     * @notice Recovers mistakenly transferred tokens from the intent (source/escrow) account
     * @dev Token must not be part of the intent's reward structure
     * @param source Origin chain ID for the intent
     * @param destination Destination chain ID for the intent
     * @param routeHash The hash of the intent's route component
     * @param reward The reward specification
     * @param token The address of the token to recover
     */
    function recoverToken(
        uint64 source,
        uint64 destination,
        bytes32 routeHash,
        Reward calldata reward,
        address token
    ) external;

    /**
     * @notice Owner-cook: the reward keeper runs an arbitrary runtime against their OWN (source/escrow)
     *         Account via delegatecall
     * @dev Only `intent.reward.keeper` may call, and only on the intent's SOURCE chain
     *      (`block.chainid == intent.source`). Guarded so it cannot drain escrow owed to a solver: a
     *      Funded intent whose reward is still live (has legs and before the deadline) or that carries a
     *      valid destination proof reverts {AccountLocked}. Used as the source-side stray-fund rescue.
     * @param intent The complete intent specification (identifies the Account + owner)
     * @param runtime The delegatecall target to run against the Account
     * @param payload The opaque program forwarded to `runtime`
     * @return The runtime's raw return data
     */
    function executeAsOwner(
        Intent calldata intent,
        address runtime,
        bytes calldata payload
    ) external payable returns (bytes memory);

    /**
     * @notice Settles one or more STREAMING batches, paying each slice's committed claimant its reward
     * @dev The streaming analogue of {settle}. Delegates verification + consumption to the
     *      {IStreamingPolicy}: it recomputes each supplied batch's commitment against the accumulated
     *      unsettled set (cross-chain) or the destination slice array (same-chain), REMOVES the matched
     *      entries (consume+delete), and returns the per-slice payouts. The (source/escrow) Account then
     *      pays each slice in full (reverting if under-funded, so a batch is never partially consumed —
     *      L1) WITHOUT sweeping the residual (it funds later slices). Permissionless: anyone may relay the
     *      preimages; the money always goes to the committed claimants. The intent stays `Funded` (the
     *      keeper reclaims the remainder via {closeStream}/{refund}).
     * @param source Origin chain ID for the intent
     * @param destination Destination chain ID for the intent
     * @param routeHash The hash of the intent's route component
     * @param reward The reward specification (must name a {IStreamingPolicy} at `reward.prover`)
     * @param batchData `abi.encode(IStreamingPolicy.StreamBatch[])` — the unsettled batches with their
     *        slice preimages (opaque to the Portal; decoded by the policy)
     */
    function settleStream(
        uint64 source,
        uint64 destination,
        bytes32 routeHash,
        Reward calldata reward,
        bytes calldata batchData
    ) external;

    /**
     * @notice Closes a stream and reclaims the remaining escrow to the keeper (terminal, keeper-only)
     * @dev C2 anti-rug: gated on {IStreamingPolicy-hasUnsettledFulfillment} being FALSE, so it can NEVER
     *      sweep escrow owed to a solver whose batch is proven-but-unsettled — the keeper must let those
     *      settle first (settlement is permissionless). Marks the stream closed on the policy, refunds the
     *      remaining escrow to the keeper, and terminates the intent.
     * @param source Origin chain ID for the intent
     * @param destination Destination chain ID for the intent
     * @param routeHash The hash of the intent's route component
     * @param reward The reward specification (must name a {IStreamingPolicy} at `reward.prover`)
     */
    function closeStream(
        uint64 source,
        uint64 destination,
        bytes32 routeHash,
        Reward calldata reward
    ) external;
}
