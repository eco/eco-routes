/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPolicy} from "./interfaces/IPolicy.sol";
import {IIntentSource} from "./interfaces/IIntentSource.sol";
import {IAccount} from "./interfaces/IAccount.sol";
import {IPermit} from "./interfaces/IPermit.sol";

import {Intent, Reward, RewardToken, IntentLib} from "./types/Intent.sol";
import {AddressConverter} from "./libs/AddressConverter.sol";
import {Refund} from "./libs/Refund.sol";

import {OriginSettler} from "./ERC7683/OriginSettler.sol";
import {AccountDeployer} from "./account/AccountDeployer.sol";

/**
 * @title IntentSource
 * @notice Abstract contract for managing cross-chain intents and their associated rewards on the source chain
 * @dev Base contract containing all core intent functionality for EVM chains. Rewards are rate+flat
 *      legs escrowed in a per-intent Account. Settlement supplies the proven `(claimant, fulfilled[])`
 *      preimage, which is checked against the prover's hash-only fact; the Account then consults the
 *      prover (as a view) for the per-leg amounts and pays the claimant, sweeping the residual to the
 *      keeper. The source-side escrow Account is chain-parameterized by `intent.source` (Model C), so it
 *      is address-separated from the destination execution Account for a cross-chain intent.
 */
abstract contract IntentSource is AccountDeployer, OriginSettler, IIntentSource {
    using SafeERC20 for IERC20;
    using AddressConverter for address;
    using AddressConverter for bytes32;
    using Math for uint256;

    /// @dev Tracks the lifecycle status of each intent's rewards
    mapping(bytes32 => Status) private rewardStatuses;

    /**
     * @notice Ensures intent can be funded based on its current status
     * @param intentHash Hash of the intent to validate for funding eligibility
     */
    modifier onlyFundable(bytes32 intentHash) {
        Status status = rewardStatuses[intentHash];

        if (status == Status.Withdrawn || status == Status.Refunded) {
            revert InvalidStatusForFunding(status);
        }

        if (status == Status.Funded) {
            return;
        }

        _;
    }

    /**
     * @notice Restricts a source-side operation to the intent's committed source chain
     * @dev Every source-side op resolves the SOURCE (escrow) account keyed by `intent.source`, so it is
     *      only valid when `block.chainid == source`. Belt-and-braces on top of the Model C address
     *      separation: even though a cross-chain intent's source account is a different address than its
     *      destination account, this gate makes a source-side op on the wrong chain fail loudly
     *      ({WrongSourceChain}) instead of silently operating on an empty source-account address.
     * @param source The intent's committed source chain id
     */
    modifier onlySourceChain(uint64 source) {
        if (block.chainid != source) {
            revert WrongSourceChain(uint64(block.chainid), source);
        }
        _;
    }

    /**
     * @notice Retrieves reward status for a given intent hash
     * @param intentHash Hash of the intent to query
     * @return status Current status of the intent
     */
    function getRewardStatus(
        bytes32 intentHash
    ) public view returns (Status status) {
        return rewardStatuses[intentHash];
    }

    /**
     * @notice Calculates the hash of an intent and its components
     * @param intent The intent to hash
     * @return intentHash Combined hash of route and reward
     * @return routeHash Hash of the route component
     * @return rewardHash Hash of the reward component
     */
    function getIntentHash(
        Intent memory intent
    )
        public
        pure
        returns (bytes32 intentHash, bytes32 routeHash, bytes32 rewardHash)
    {
        return
            getIntentHash(
                intent.source,
                intent.destination,
                abi.encode(intent.route),
                intent.reward
            );
    }

    /**
     * @notice Calculates the hash of an intent and its components
     * @param source Origin chain ID for the intent
     * @param destination Destination chain ID for the intent
     * @param route Encoded route data for the intent as bytes for cross-VM compatibility
     * @param reward Reward structure containing distribution details
     * @return intentHash Combined hash of route and reward
     * @return routeHash Hash of the route component
     * @return rewardHash Hash of the reward component
     */
    function getIntentHash(
        uint64 source,
        uint64 destination,
        bytes memory route,
        Reward memory reward
    )
        public
        pure
        returns (bytes32 intentHash, bytes32 routeHash, bytes32 rewardHash)
    {
        (intentHash, routeHash, rewardHash) = getIntentHash(
            source,
            destination,
            keccak256(route),
            reward
        );
    }

    /**
     * @notice Calculates intent hash from route hash and reward components
     * @param source Origin chain ID for the intent
     * @param destination Destination chain ID for the intent
     * @param _routeHash Pre-computed hash of the route component
     * @param reward Reward structure containing distribution details
     * @return intentHash Combined hash of route and reward
     * @return routeHash Hash of the route component (passed through)
     * @return rewardHash Hash of the reward component
     */
    function getIntentHash(
        uint64 source,
        uint64 destination,
        bytes32 _routeHash,
        Reward memory reward
    )
        public
        pure
        returns (bytes32 intentHash, bytes32 routeHash, bytes32 rewardHash)
    {
        routeHash = _routeHash;
        rewardHash = keccak256(abi.encode(reward));
        intentHash = IntentLib.hashIntent(
            source,
            destination,
            routeHash,
            rewardHash
        );
    }

    /**
     * @notice Calculates the deterministic address of the intent account
     * @param intent Intent to calculate account address for
     * @return Address of the intent (source/escrow) account
     */
    function intentAccountAddress(
        Intent calldata intent
    ) public view returns (address) {
        return
            intentAccountAddress(
                intent.source,
                intent.destination,
                abi.encode(intent.route),
                intent.reward
            );
    }

    /**
     * @notice Calculates the deterministic address of the intent's SOURCE (escrow) account
     * @dev The source-side account salt uses `intent.source` as the role chain id (Model C). Source-side
     *      operations (fund/settle/refund/recover/executeAsOwner) all resolve to this address.
     * @param source Origin chain ID for the intent
     * @param destination Destination chain ID for the intent
     * @param route Encoded route data for the intent as bytes
     * @param reward The reward structure containing distribution details
     * @return Address of the source-side escrow account
     */
    function intentAccountAddress(
        uint64 source,
        uint64 destination,
        bytes memory route,
        Reward calldata reward
    ) public view returns (address) {
        (bytes32 intentHash, , ) = getIntentHash(
            source,
            destination,
            route,
            reward
        );

        return accountAddress(intentHash, source);
    }

    /**
     * @notice Checks if an intent is completely funded
     * @param intent Intent to validate
     * @return True if intent is completely funded, false otherwise
     */
    function isIntentFunded(Intent calldata intent) public view returns (bool) {
        return
            isIntentFunded(
                intent.source,
                intent.destination,
                abi.encode(intent.route),
                intent.reward
            );
    }

    /**
     * @notice Checks if an intent is fully funded using universal format
     * @param source Origin chain ID for the intent
     * @param destination Destination chain ID for the intent
     * @param route Encoded route data for the intent as bytes
     * @param reward The reward structure containing distribution details
     * @return True if intent is completely funded, false otherwise
     */
    function isIntentFunded(
        uint64 source,
        uint64 destination,
        bytes memory route,
        Reward calldata reward
    ) public view returns (bool) {
        (bytes32 intentHash, , ) = getIntentHash(
            source,
            destination,
            route,
            reward
        );

        if (rewardStatuses[intentHash] == Status.Funded) {
            return true;
        }

        return
            _isRewardFunded(
                reward,
                _rewardTargets(reward.tokens),
                accountAddress(intentHash, source)
            );
    }

    /**
     * @notice Creates an intent without funding
     * @param intent The complete intent struct to be published
     * @return intentHash Hash of the created intent
     * @return account Address of the created account
     */
    function publish(
        Intent calldata intent
    ) public returns (bytes32 intentHash, address account) {
        return
            publish(
                intent.source,
                intent.destination,
                abi.encode(intent.route),
                intent.reward
            );
    }

    /**
     * @notice Creates an intent without funding
     * @param source Origin chain ID for the intent
     * @param destination Destination chain ID for the intent
     * @param route Encoded route data for the intent as bytes
     * @param reward The reward structure containing distribution details
     * @return intentHash Hash of the created intent
     * @return account Address of the created (source/escrow) account
     */
    function publish(
        uint64 source,
        uint64 destination,
        bytes memory route,
        Reward memory reward
    ) public returns (bytes32 intentHash, address account) {
        // Validate reward legs on the source. The route is treated as opaque bytes (cross-VM
        // compatibility), so only the route-free checks run here (uniqueness + bound); `minTokens` ordering
        // is enforced at the destination fulfill.
        IntentLib.requireUniqueRewardTokens(reward.tokens);

        (intentHash, , ) = getIntentHash(source, destination, route, reward);
        account = accountAddress(intentHash, source);

        _validatePublish(intentHash);
        _emitIntentPublished(intentHash, destination, route, reward);
    }

    /**
     * @notice Creates and funds an intent in a single transaction
     * @param intent The complete intent struct to be published and funded
     * @param allowPartial Whether to allow partial funding
     * @return intentHash Hash of the created and funded intent
     * @return account Address of the created account
     */
    function publishAndFund(
        Intent calldata intent,
        bool allowPartial
    ) public payable returns (bytes32 intentHash, address account) {
        return
            publishAndFund(
                intent.source,
                intent.destination,
                abi.encode(intent.route),
                intent.reward,
                allowPartial
            );
    }

    /**
     * @notice Creates and funds an intent in a single transaction
     * @param source Origin chain ID for the intent
     * @param destination Destination chain ID for the intent
     * @param route Encoded route data for the intent as bytes
     * @param reward The reward structure containing distribution details
     * @param allowPartial Whether to allow partial funding
     * @return intentHash Hash of the created and funded intent
     * @return account Address of the created account
     */
    function publishAndFund(
        uint64 source,
        uint64 destination,
        bytes memory route,
        Reward calldata reward,
        bool allowPartial
    )
        public
        payable
        onlySourceChain(source)
        returns (bytes32 intentHash, address account)
    {
        return
            _publishAndFund(
                source,
                destination,
                route,
                reward,
                allowPartial,
                msg.sender
            );
    }

    /**
     * @notice Funds an existing intent
     * @param source Origin chain ID for the intent
     * @param destination Destination chain ID for the intent
     * @param routeHash Hash of the route component
     * @param reward Reward structure containing distribution details
     * @param allowPartial Whether to allow partial funding
     * @return intentHash Hash of the funded intent
     */
    function fund(
        uint64 source,
        uint64 destination,
        bytes32 routeHash,
        Reward calldata reward,
        bool allowPartial
    ) external payable onlySourceChain(source) returns (bytes32 intentHash) {
        (intentHash, , ) = getIntentHash(
            source,
            destination,
            routeHash,
            reward
        );

        _fundIntent(
            intentHash,
            accountAddress(intentHash, source),
            reward,
            _rewardTargets(reward.tokens),
            msg.sender,
            allowPartial
        );
        Refund.excessNative();
    }

    /**
     * @notice Funds an intent for a user with permit/allowance
     * @param source Origin chain ID for the intent
     * @param destination Destination chain ID for the intent
     * @param routeHash Hash of the route component
     * @param reward Reward structure containing distribution details
     * @param allowPartial Whether to allow partial funding
     * @param funder Address to fund the intent from
     * @param permitContract Address of the permitContract instance
     * @return intentHash Hash of the funded intent
     */
    function fundFor(
        uint64 source,
        uint64 destination,
        bytes32 routeHash,
        Reward calldata reward,
        bool allowPartial,
        address funder,
        address permitContract
    ) external payable onlySourceChain(source) returns (bytes32 intentHash) {
        (intentHash, , ) = getIntentHash(
            source,
            destination,
            routeHash,
            reward
        );

        _fundIntentFor(
            reward,
            _rewardTargets(reward.tokens),
            intentHash,
            source,
            allowPartial,
            funder,
            permitContract
        );
    }

    /**
     * @notice Creates and funds an intent using permit/allowance
     * @param intent The complete intent struct
     * @param allowPartial Whether to allow partial funding
     * @param funder Address to fund the intent from
     * @param permitContract Address of the permitContract instance
     * @return intentHash Hash of the created and funded intent
     * @return account Address of the created account
     */
    function publishAndFundFor(
        Intent calldata intent,
        bool allowPartial,
        address funder,
        address permitContract
    ) public payable returns (bytes32 intentHash, address account) {
        return
            publishAndFundFor(
                intent.source,
                intent.destination,
                abi.encode(intent.route),
                intent.reward,
                allowPartial,
                funder,
                permitContract
            );
    }

    /**
     * @notice Creates and funds an intent on behalf of another address using universal format
     * @param source Origin chain ID for the intent
     * @param destination Destination chain ID for the intent
     * @param route Encoded route data for the intent as bytes
     * @param reward The reward structure containing distribution details
     * @param allowPartial Whether to accept partial funding
     * @param funder The address providing the funding
     * @param permitContract The permit contract for token approvals
     * @return intentHash Hash of the created and funded intent
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
    )
        public
        payable
        onlySourceChain(source)
        returns (bytes32 intentHash, address account)
    {
        (intentHash, ) = publish(source, destination, route, reward);

        account = _fundIntentFor(
            reward,
            _rewardTargets(reward.tokens),
            intentHash,
            source,
            allowPartial,
            funder,
            permitContract
        );
    }

    /**
     * @notice Settles rewards for a proven intent to its claimant
     * @dev Reads the prover's hash-only fact, verifies the supplied `(claimant, fulfilled[])` preimage
     *      against it, then pays the owed reward (Account consults the prover's {IPolicy-previewRelease})
     *      to the claimant and sweeps the residual to the keeper. Keeps the wrong-destination
     *      {IPolicy-challengeIntentProof} escape hatch.
     * @param source Origin chain ID for the intent
     * @param destination Destination chain ID for the intent
     * @param routeHash Hash of the intent's route
     * @param reward Reward structure of the intent
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
    ) public onlySourceChain(source) {
        _settle(source, destination, routeHash, reward, claimant, fulfilled);
    }

    /**
     * @notice Internal settle: verifies the proven `(claimant, fulfilled[])` preimage and pays the reward
     * @dev Shared by the two-step {settle} (source chain) and the same-chain one-tx
     *      {IPortal-fulfillAndSettle}. The source-chain gate lives on the public entry points; this
     *      internal assumes the caller has established that the SOURCE (escrow) account is on this chain.
     * @param source Origin chain ID for the intent (selects the source/escrow account)
     * @param destination Destination chain ID for the intent
     * @param routeHash Hash of the intent's route
     * @param reward Reward structure of the intent
     * @param claimant Cross-VM claimant identifier committed in the fulfillment
     * @param fulfilled Per-leg delivered amounts committed in the fulfillment (paired prefix)
     */
    function _settle(
        uint64 source,
        uint64 destination,
        bytes32 routeHash,
        Reward calldata reward,
        bytes32 claimant,
        uint256[] memory fulfilled
    ) internal {
        (bytes32 intentHash, , bytes32 rewardHash) = getIntentHash(
            source,
            destination,
            routeHash,
            reward
        );

        IPolicy.ProofData memory proof = IPolicy(reward.prover).provenIntents(
            intentHash
        );

        // If the intent has been proven on a different chain, challenge the proof and stop.
        if (
            proof.destination != destination &&
            proof.fulfillmentHash != bytes32(0)
        ) {
            IPolicy(reward.prover).challengeIntentProof(
                source,
                destination,
                routeHash,
                rewardHash
            );

            return;
        }

        // Verify the supplied preimage against the proven hash-only fact.
        bytes32 fulfillmentHash = IntentLib.fulfillmentHash(
            intentHash,
            claimant,
            fulfilled
        );
        if (fulfillmentHash != proof.fulfillmentHash) {
            revert InvalidFulfillmentProof(intentHash);
        }

        // The claimant must be a valid EVM address to receive the payout on this chain.
        if (!claimant.isValidAddress()) {
            revert InvalidClaimant();
        }
        address claimantAddr = claimant.toAddress();

        _validateWithdraw(intentHash, claimantAddr);
        rewardStatuses[intentHash] = Status.Withdrawn;

        // Source-side op: pay out of the SOURCE (escrow) account.
        IAccount account = IAccount(_getOrDeployAccount(intentHash, source));
        account.withdraw(reward, claimantAddr, fulfilled);

        emit IntentWithdrawn(intentHash, claimantAddr);
    }

    /**
     * @notice Refunds rewards to the intent keeper
     * @param source Origin chain ID for the intent
     * @param destination Destination chain ID for the intent
     * @param routeHash Hash of the intent's route
     * @param reward Reward structure of the intent
     */
    function refund(
        uint64 source,
        uint64 destination,
        bytes32 routeHash,
        Reward calldata reward
    ) external onlySourceChain(source) {
        (bytes32 intentHash, , ) = getIntentHash(
            source,
            destination,
            routeHash,
            reward
        );

        _refund(intentHash, source, destination, reward, reward.keeper);
    }

    /**
     * @notice Refunds rewards to a specified address (only callable by reward keeper)
     * @param source Origin chain ID for the intent
     * @param destination Destination chain ID for the intent
     * @param routeHash Hash of the intent's route
     * @param reward Reward structure of the intent
     * @param refundee Address to receive the refunded rewards
     */
    function refundTo(
        uint64 source,
        uint64 destination,
        bytes32 routeHash,
        Reward calldata reward,
        address refundee
    ) external onlySourceChain(source) {
        if (msg.sender != reward.keeper) {
            revert NotKeeperCaller(msg.sender);
        }

        (bytes32 intentHash, , ) = getIntentHash(
            source,
            destination,
            routeHash,
            reward
        );

        _refund(intentHash, source, destination, reward, refundee);
    }

    /**
     * @notice Recover tokens that were sent to the intent account by mistake
     * @dev Must not be among the intent's rewards
     * @param source Origin chain ID for the intent
     * @param destination Destination chain ID for the intent
     * @param routeHash Hash of the intent's route
     * @param reward Reward structure of the intent
     * @param token Token address for handling incorrect account transfers
     */
    function recoverToken(
        uint64 source,
        uint64 destination,
        bytes32 routeHash,
        Reward calldata reward,
        address token
    ) external onlySourceChain(source) {
        (bytes32 intentHash, , ) = getIntentHash(
            source,
            destination,
            routeHash,
            reward
        );

        _validateRecover(reward, token);

        // Source-side op: recover from the SOURCE (escrow) account.
        IAccount account = IAccount(_getOrDeployAccount(intentHash, source));
        account.recover(reward.keeper, token);

        emit IntentTokenRecovered(intentHash, reward.keeper, token);
    }

    /**
     * @notice Owner-cook: the reward keeper runs an arbitrary runtime against their own SOURCE (escrow)
     *         Account via delegatecall.
     * @dev Only `intent.reward.keeper` may call, and only on the intent's SOURCE chain
     *      (`block.chainid == intent.source`) — the escrow Account lives there. The Account is derived
     *      from the source role chain id, so this operates on the escrow account (the keeper's own funds),
     *      NOT the destination execution account (that has its own {Inbox-executeAsOwner} gated by
     *      `route.keeper`). Anti-rug ESCROW/PROOF LOCK: while a reward is still LIVE — it has reward legs
     *      AND is before the reward deadline — or it already carries a valid destination proof (a solver
     *      may be owed the escrow), the cook reverts {AccountLocked}, in EVERY non-terminal status
     *      (Initial or Funded) — not just Funded: `fund`/`fundFor` are permissionless and need no prior
     *      `publish`, so an `Initial` intent can still be funded later, and an arbitrary runtime run while
     *      Initial could otherwise plant a persistent side effect (e.g. a token approval) that survives
     *      independently of the account's balance and is exercisable once real escrow lands. It is
     *      permitted in: Withdrawn / Refunded (escrow gone, and terminal — `onlyFundable` makes funding
     *      structurally impossible again), or any status once the escrow is truly free (past the deadline
     *      with no live legs and no valid proof, or an empty-reward intent that owes no solver). The
     *      delegatecall bubbles the runtime's raw return/revert verbatim. Used as the source-side
     *      stray-fund rescue and consumed by the deposit self-service flows (which use empty-reward
     *      intents, so they are unaffected — never locked regardless of status).
     * @param intent The complete intent specification (identifies the Account + owner)
     * @param runtime The delegatecall target to run against the Account
     * @param payload The opaque program forwarded to `runtime`
     * @return The runtime's raw return data
     */
    function executeAsOwner(
        Intent calldata intent,
        address runtime,
        bytes calldata payload
    )
        external
        payable
        onlySourceChain(intent.source)
        returns (bytes memory)
    {
        if (msg.sender != intent.reward.keeper) {
            revert NotAccountOwner(msg.sender);
        }

        (bytes32 intentHash, , ) = getIntentHash(intent);

        Status status = rewardStatuses[intentHash];
        // The lock is evaluated for every NON-TERMINAL status (Initial AND Funded), not just Funded.
        // `fund`/`fundFor` are permissionless and require no prior `publish` (main's long-standing
        // "hash-triple identity" design), so an `Initial` intent can be funded by ANYONE at ANY time —
        // gating the lock on `Funded` alone let a keeper run an arbitrary runtime on the escrow Account
        // WHILE it was still Initial and use it to plant a PERSISTENT side effect (e.g. an ERC20 `approve`
        // to themselves) that survives independently of the account's balance. That approval is later
        // exercisable via a plain `transferFrom` at any point after real reward escrow lands — completely
        // bypassing this lock, which only ever gated a fresh `executeAsOwner` call, never a pre-planted
        // allowance. Terminal states (Withdrawn/Refunded) are the only ones where funding is structurally
        // impossible again (`onlyFundable` rejects them), so they remain unconditionally unlocked.
        if (status != Status.Withdrawn && status != Status.Refunded) {
            bool hasRewardLegs = intent.reward.tokens.length != 0;
            bool beforeDeadline = block.timestamp < intent.reward.deadline;
            IPolicy.ProofData memory proof = IPolicy(intent.reward.prover)
                .provenIntents(intentHash);
            bool provenForThisDest = proof.fulfillmentHash != bytes32(0) &&
                proof.destination == intent.destination;
            // Locked while a real reward escrow is (or could still become) live (has legs AND before the
            // deadline), or whenever a valid destination proof exists (a solver may be owed — never rug an
            // honored fulfillment). An empty-reward intent (deposit / owner-cook) has no legs, so this is
            // never locked for it, regardless of status.
            if ((hasRewardLegs && beforeDeadline) || provenForThisDest) {
                revert AccountLocked(intentHash);
            }
        }

        // Operate on the SOURCE (escrow) account — the keeper's own funds.
        address account = _getOrDeployAccount(intentHash, intent.source);
        return IAccount(account).execute{value: msg.value}(runtime, payload);
    }

    /**
     * @notice Separate function to emit the IntentPublished event
     * @param intentHash Hash of the intent
     * @param destination Destination chain ID
     * @param route Encoded route data
     * @param reward Reward specification
     */
    function _emitIntentPublished(
        bytes32 intentHash,
        uint64 destination,
        bytes memory route,
        Reward memory reward
    ) internal {
        emit IntentPublished(
            intentHash,
            destination,
            route,
            reward.keeper,
            reward.prover,
            reward.deadline,
            reward.tokens
        );
    }

    /**
     * @notice Core OriginSettler implementation for atomic intent creation and funding
     * @param source Origin chain ID for the intent
     * @param destination Destination chain ID for the intent
     * @param route Encoded route data for the intent as bytes
     * @param reward The reward structure containing distribution details
     * @param allowPartial Whether to accept partial funding
     * @param funder The address providing the funding
     * @return intentHash Hash of the created and funded intent
     * @return account Address of the created account
     */
    function _publishAndFund(
        uint64 source,
        uint64 destination,
        bytes memory route,
        Reward memory reward,
        bool allowPartial,
        address funder
    ) internal override returns (bytes32 intentHash, address account) {
        (intentHash, account) = publish(source, destination, route, reward);

        _fundIntent(
            intentHash,
            account,
            reward,
            _rewardTargets(reward.tokens),
            funder,
            allowPartial
        );
        Refund.excessNative();
    }

    /**
     * @notice Handles the funding of an intent - OriginSettler implementation
     * @param intentHash Hash of the intent
     * @param account Address of the intent's account
     * @param reward Reward structure to fund
     * @param targets Per-leg escrow targets, index-aligned with `reward.tokens`
     * @param funder Address providing the funds
     * @param allowPartial Whether to allow partial funding
     */
    function _fundIntent(
        bytes32 intentHash,
        address account,
        Reward memory reward,
        uint256[] memory targets,
        address funder,
        bool allowPartial
    ) internal onlyFundable(intentHash) {
        // Reject a duplicate reward-token leg regardless of entry point. `publish` already checks this,
        // but `fund`/`fundFor` can escrow an intent directly without a prior `publish` call — without this
        // check here too, a duplicate leg would silently underpay the claimant (the settle-side per-leg
        // residual sweep pays only the first matching leg and sweeps the rest to the keeper).
        IntentLib.requireUniqueRewardTokens(reward.tokens);

        bool fullyFunded = true;

        uint256 rewardsLength = reward.tokens.length;
        for (uint256 i; i < rewardsLength; ++i) {
            address token = reward.tokens[i].token;

            if (token == address(0)) {
                fullyFunded = fullyFunded && _fundNative(account, targets[i]);
            } else {
                fullyFunded =
                    fullyFunded &&
                    _fundToken(account, funder, IERC20(token), targets[i]);
            }
        }

        if (!allowPartial && !fullyFunded) {
            revert InsufficientFunds(intentHash);
        }

        if (fullyFunded) {
            rewardStatuses[intentHash] = Status.Funded;
        }

        emit IntentFunded(intentHash, funder, fullyFunded);
    }

    /**
     * @notice Funds account with native tokens (ETH)
     * @param account Address of the account to fund
     * @param rewardAmount Required native token amount
     * @return funded True if account has sufficient native balance after funding attempt
     */
    function _fundNative(
        address account,
        uint256 rewardAmount
    ) internal returns (bool funded) {
        uint256 balance = account.balance;

        if (balance >= rewardAmount) {
            return true;
        }

        uint256 remaining = rewardAmount - balance;
        uint256 transferAmount = remaining.min(msg.value);

        if (transferAmount > 0) {
            payable(account).transfer(transferAmount);
        }

        return transferAmount >= remaining;
    }

    /**
     * @notice Funds account with ERC20 tokens
     * @param account Address of the account to fund
     * @param token ERC20 token contract to transfer
     * @param rewardAmount Required token amount
     * @return funded True if account has sufficient token balance after funding attempt
     */
    function _fundToken(
        address account,
        address funder,
        IERC20 token,
        uint256 rewardAmount
    ) internal returns (bool funded) {
        uint256 balance = token.balanceOf(account);

        if (balance >= rewardAmount) {
            return true;
        }

        uint256 remaining = rewardAmount - balance;
        uint256 transferAmount = remaining
            .min(token.allowance(funder, address(this)))
            .min(token.balanceOf(funder));

        if (transferAmount > 0) {
            token.safeTransferFrom(funder, account, transferAmount);
        }

        return balance + transferAmount >= rewardAmount;
    }

    /**
     * @notice Funds an intent using a permit contract for gasless approvals
     * @param reward Reward structure containing funding requirements
     * @param targets Per-leg escrow targets, index-aligned with `reward.tokens`
     * @param intentHash Hash of the intent to fund
     * @param source Origin chain ID for the intent (selects the source/escrow account)
     * @param allowPartial Whether to allow partial funding
     * @param funder Address providing the funding
     * @param permitContract Address of permit contract for token approvals
     * @return account Address of the funded account
     */
    function _fundIntentFor(
        Reward calldata reward,
        uint256[] memory targets,
        bytes32 intentHash,
        uint64 source,
        bool allowPartial,
        address funder,
        address permitContract
    ) internal onlyFundable(intentHash) returns (address account) {
        account = _getOrDeployAccount(intentHash, source);
        bool fullyFunded = IAccount(account).fundFor{value: msg.value}(
            reward,
            targets,
            funder,
            IPermit(permitContract)
        );

        if (!allowPartial && !fullyFunded) {
            revert InsufficientFunds(intentHash);
        }

        if (fullyFunded) {
            rewardStatuses[intentHash] = Status.Funded;
        }

        emit IntentFunded(intentHash, funder, fullyFunded);
    }

    /**
     * @notice Validates that an intent's account holds sufficient rewards for each leg's target
     * @param reward Reward to validate
     * @param targets Per-leg escrow targets, index-aligned with `reward.tokens`
     * @param account Address of the intent's account
     * @return True if account has sufficient funds, false otherwise
     */
    function _isRewardFunded(
        Reward calldata reward,
        uint256[] memory targets,
        address account
    ) internal view returns (bool) {
        uint256 rewardsLength = reward.tokens.length;

        for (uint256 i = 0; i < rewardsLength; ++i) {
            address token = reward.tokens[i].token;
            uint256 balance = token == address(0)
                ? account.balance
                : IERC20(token).balanceOf(account);

            if (balance < targets[i]) return false;
        }

        return true;
    }

    /**
     * @notice Validates and publishes a new intent
     * @param intentHash Hash of the intent
     */
    function _validatePublish(bytes32 intentHash) internal view {
        Status status = rewardStatuses[intentHash];

        if (status == Status.Withdrawn || status == Status.Refunded) {
            revert IntentAlreadyExists(intentHash);
        }
    }

    /**
     * @notice Validates that an intent can be refunded
     * @dev Hash-only anti-lock semantics: BEFORE the reward deadline, a fulfilled intent (valid proof)
     *      must be settled, not refunded ({IntentNotClaimed}); an unfulfilled intent is not yet
     *      refundable ({InvalidStatusForRefund}). AFTER the deadline, the reward is always refundable if
     *      not already settled — the deadline is the definitive settlement window. This differs from v2,
     *      where a proven intent could never be refunded: in the hash-only model the source cannot
     *      introspect the committed claimant, so the anti-griefing guarantee (a bad-claimant fulfillment
     *      cannot permanently lock the keeper's funds) is preserved by the deadline instead.
     * @param intentHash Hash of the intent to validate
     * @param destination Expected destination chain ID
     * @param reward Reward structure containing prover information
     */
    function _validateRefund(
        bytes32 intentHash,
        uint64 destination,
        Reward calldata reward
    ) internal view {
        Status status = rewardStatuses[intentHash];

        // After the deadline the reward is always refundable — this is the anti-lock guarantee: in the
        // hash-only model the source cannot introspect the committed claimant, so a bad-claimant
        // fulfillment cannot permanently lock the keeper's funds (the deadline is the definitive
        // settlement window). A terminal (Withdrawn/Refunded) intent simply drains an already-empty
        // account, so repeated refund / dust recovery stays reachable (v2 parity).
        if (block.timestamp >= reward.deadline) {
            return;
        }

        // Before the deadline: a fulfilled-but-unsettled intent must be settled, not refunded.
        IPolicy.ProofData memory proof = IPolicy(reward.prover).provenIntents(
            intentHash
        );
        bool hasValidProof = proof.destination == destination &&
            proof.fulfillmentHash != bytes32(0);

        if (hasValidProof) {
            if (status == Status.Initial || status == Status.Funded) {
                revert IntentNotClaimed(intentHash);
            }
            // Already settled: allow (drains any residual/dust to the refundee).
            return;
        }

        revert InvalidStatusForRefund(status, block.timestamp, reward.deadline);
    }

    /**
     * @notice Validates that account can be withdrawn from and claimant is valid
     * @param intentHash Hash of the intent
     * @param claimant Address that will receive the withdrawn rewards
     */
    function _validateWithdraw(
        bytes32 intentHash,
        address claimant
    ) internal view {
        Status status = rewardStatuses[intentHash];

        if (status != Status.Initial && status != Status.Funded) {
            revert InvalidStatusForWithdrawal(status);
        }

        if (claimant == address(0)) {
            revert InvalidClaimant();
        }
    }

    /**
     * @notice Validates that token can be recovered (not zero address and not a reward token)
     * @param reward Reward structure containing token list
     * @param token Address of the token to recover
     */
    function _validateRecover(
        Reward calldata reward,
        address token
    ) internal pure {
        if (token == address(0)) {
            revert InvalidRecoverToken(token);
        }

        uint256 rewardsLength = reward.tokens.length;
        for (uint256 i; i < rewardsLength; ++i) {
            if (reward.tokens[i].token == token) {
                revert InvalidRecoverToken(token);
            }
        }
    }

    /**
     * @notice Internal function to refund rewards to a specified address
     * @param intentHash Hash of the intent to refund
     * @param source Origin chain ID for the intent (selects the source/escrow account)
     * @param destination Destination chain ID for the intent
     * @param reward Reward structure of the intent
     * @param refundee Address to receive the refunded rewards
     */
    function _refund(
        bytes32 intentHash,
        uint64 source,
        uint64 destination,
        Reward calldata reward,
        address refundee
    ) internal {
        _validateRefund(intentHash, destination, reward);
        rewardStatuses[intentHash] = Status.Refunded;

        // Source-side op: refund from the SOURCE (escrow) account.
        IAccount account = IAccount(_getOrDeployAccount(intentHash, source));
        account.refund(reward, refundee);

        emit IntentRefunded(intentHash, refundee);
    }

    /**
     * @notice Computes the per-leg escrow targets from the reward legs
     * @dev Each leg's escrow target is its `flat` — the guaranteed floor reward. The source treats the
     *      route as opaque bytes (cross-VM), so it cannot fold in the rate-scaled `minTokens` minimum; the
     *      `rate` term is paid at settle only out of account balance in excess of the flats, always capped
     *      at balance (money-safety). A fixed same-asset reward is `{token, rate: 0, flat: amount}`
     *      (v2 parity). Guaranteeing a rate payout requires over-funding — refined when the per-intent
     *      escrow budget (Pod) arrives in a later stage.
     * @param rewardTokens The reward legs
     * @return targets Per-leg escrow targets (each leg's `flat`), index-aligned with `rewardTokens`
     */
    function _rewardTargets(
        RewardToken[] memory rewardTokens
    ) internal pure returns (uint256[] memory targets) {
        uint256 len = rewardTokens.length;
        targets = new uint256[](len);
        for (uint256 j = 0; j < len; ++j) {
            targets[j] = rewardTokens[j].flat;
        }
    }
}
