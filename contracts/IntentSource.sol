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
import {Clones} from "./account/Clones.sol";

/**
 * @title IntentSource
 * @notice Abstract contract for managing cross-chain intents and their associated rewards on the source chain
 * @dev Base contract containing all core intent functionality for EVM chains. Rewards are rate+flat
 *      legs escrowed in a per-intent Account. Settlement supplies the proven `(claimant, fulfilled[])`
 *      preimage, which is checked against the prover's hash-only fact; the Account then consults the
 *      prover (as a view) for the per-leg amounts and pays the claimant, sweeping the residual to the
 *      keeper.
 */
abstract contract IntentSource is OriginSettler, IIntentSource {
    using SafeERC20 for IERC20;
    using AddressConverter for address;
    using AddressConverter for bytes32;
    using Clones for address;
    using Math for uint256;

    /// @dev CREATE2 prefix for deterministic address calculation (0xff for EVM, 0x41 for Tron)
    bytes1 private immutable CREATE2_PREFIX;

    /// @dev Implementation contract address for account cloning
    address private immutable ACCOUNT_IMPLEMENTATION;
    /// @dev Tracks the lifecycle status of each intent's rewards
    mapping(bytes32 => Status) private rewardStatuses;

    /**
     * @notice Initializes the IntentSource contract
     * @param accountImplementation Address of the account implementation used for cloning
     * @param create2Prefix CREATE2 prefix byte for the target chain (0xff for EVM, 0x41 for Tron)
     */
    constructor(address accountImplementation, bytes1 create2Prefix) {
        ACCOUNT_IMPLEMENTATION = accountImplementation;
        CREATE2_PREFIX = create2Prefix;
    }

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
                intent.destination,
                abi.encode(intent.route),
                intent.reward
            );
    }

    /**
     * @notice Calculates the hash of an intent and its components
     * @param destination Destination chain ID for the intent
     * @param route Encoded route data for the intent as bytes for cross-VM compatibility
     * @param reward Reward structure containing distribution details
     * @return intentHash Combined hash of route and reward
     * @return routeHash Hash of the route component
     * @return rewardHash Hash of the reward component
     */
    function getIntentHash(
        uint64 destination,
        bytes memory route,
        Reward memory reward
    )
        public
        pure
        returns (bytes32 intentHash, bytes32 routeHash, bytes32 rewardHash)
    {
        (intentHash, routeHash, rewardHash) = getIntentHash(
            destination,
            keccak256(route),
            reward
        );
    }

    /**
     * @notice Calculates intent hash from route hash and reward components
     * @param destination Destination chain ID for the intent
     * @param _routeHash Pre-computed hash of the route component
     * @param reward Reward structure containing distribution details
     * @return intentHash Combined hash of route and reward
     * @return routeHash Hash of the route component (passed through)
     * @return rewardHash Hash of the reward component
     */
    function getIntentHash(
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
        intentHash = keccak256(
            abi.encodePacked(destination, routeHash, rewardHash)
        );
    }

    /**
     * @notice Calculates the deterministic address of the intent account
     * @param intent Intent to calculate account address for
     * @return Address of the intent account
     */
    function intentAccountAddress(
        Intent calldata intent
    ) public view returns (address) {
        return
            intentAccountAddress(
                intent.destination,
                abi.encode(intent.route),
                intent.reward
            );
    }

    /**
     * @notice Calculates the deterministic address of the intent account
     * @param destination Destination chain ID for the intent
     * @param route Encoded route data for the intent as bytes
     * @param reward The reward structure containing distribution details
     * @return Address of the intent account
     */
    function intentAccountAddress(
        uint64 destination,
        bytes memory route,
        Reward calldata reward
    ) public view returns (address) {
        (bytes32 intentHash, , ) = getIntentHash(destination, route, reward);

        return _getAccount(intentHash);
    }

    /**
     * @notice Checks if an intent is completely funded
     * @param intent Intent to validate
     * @return True if intent is completely funded, false otherwise
     */
    function isIntentFunded(Intent calldata intent) public view returns (bool) {
        return
            isIntentFunded(
                intent.destination,
                abi.encode(intent.route),
                intent.reward
            );
    }

    /**
     * @notice Checks if an intent is fully funded using universal format
     * @param destination Destination chain ID for the intent
     * @param route Encoded route data for the intent as bytes
     * @param reward The reward structure containing distribution details
     * @return True if intent is completely funded, false otherwise
     */
    function isIntentFunded(
        uint64 destination,
        bytes memory route,
        Reward calldata reward
    ) public view returns (bool) {
        (bytes32 intentHash, , ) = getIntentHash(destination, route, reward);

        if (rewardStatuses[intentHash] == Status.Funded) {
            return true;
        }

        return
            _isRewardFunded(
                reward,
                _rewardTargets(reward.tokens),
                _getAccount(intentHash)
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
                intent.destination,
                abi.encode(intent.route),
                intent.reward
            );
    }

    /**
     * @notice Creates an intent without funding
     * @param destination Destination chain ID for the intent
     * @param route Encoded route data for the intent as bytes
     * @param reward The reward structure containing distribution details
     * @return intentHash Hash of the created intent
     * @return account Address of the created account
     */
    function publish(
        uint64 destination,
        bytes memory route,
        Reward memory reward
    ) public returns (bytes32 intentHash, address account) {
        // Validate reward legs on the source. The route is treated as opaque bytes (cross-VM
        // compatibility), so only the route-free checks run here (uniqueness + bound); `minTokens` ordering
        // is enforced at the destination fulfill.
        IntentLib.requireUniqueRewardTokens(reward.tokens);

        (intentHash, , ) = getIntentHash(destination, route, reward);
        account = _getAccount(intentHash);

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
                intent.destination,
                abi.encode(intent.route),
                intent.reward,
                allowPartial
            );
    }

    /**
     * @notice Creates and funds an intent in a single transaction
     * @param destination Destination chain ID for the intent
     * @param route Encoded route data for the intent as bytes
     * @param reward The reward structure containing distribution details
     * @param allowPartial Whether to allow partial funding
     * @return intentHash Hash of the created and funded intent
     * @return account Address of the created account
     */
    function publishAndFund(
        uint64 destination,
        bytes memory route,
        Reward calldata reward,
        bool allowPartial
    ) public payable returns (bytes32 intentHash, address account) {
        return
            _publishAndFund(
                destination,
                route,
                reward,
                allowPartial,
                msg.sender
            );
    }

    /**
     * @notice Funds an existing intent
     * @param destination Destination chain ID for the intent
     * @param routeHash Hash of the route component
     * @param reward Reward structure containing distribution details
     * @param allowPartial Whether to allow partial funding
     * @return intentHash Hash of the funded intent
     */
    function fund(
        uint64 destination,
        bytes32 routeHash,
        Reward calldata reward,
        bool allowPartial
    ) external payable returns (bytes32 intentHash) {
        (intentHash, , ) = getIntentHash(destination, routeHash, reward);

        _fundIntent(
            intentHash,
            _getAccount(intentHash),
            reward,
            _rewardTargets(reward.tokens),
            msg.sender,
            allowPartial
        );
        Refund.excessNative();
    }

    /**
     * @notice Funds an intent for a user with permit/allowance
     * @param destination Destination chain ID for the intent
     * @param routeHash Hash of the route component
     * @param reward Reward structure containing distribution details
     * @param allowPartial Whether to allow partial funding
     * @param funder Address to fund the intent from
     * @param permitContract Address of the permitContract instance
     * @return intentHash Hash of the funded intent
     */
    function fundFor(
        uint64 destination,
        bytes32 routeHash,
        Reward calldata reward,
        bool allowPartial,
        address funder,
        address permitContract
    ) external payable returns (bytes32 intentHash) {
        (intentHash, , ) = getIntentHash(destination, routeHash, reward);

        _fundIntentFor(
            reward,
            _rewardTargets(reward.tokens),
            intentHash,
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
        uint64 destination,
        bytes memory route,
        Reward calldata reward,
        bool allowPartial,
        address funder,
        address permitContract
    ) public payable returns (bytes32 intentHash, address account) {
        (intentHash, ) = publish(destination, route, reward);

        account = _fundIntentFor(
            reward,
            _rewardTargets(reward.tokens),
            intentHash,
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
     * @param destination Destination chain ID for the intent
     * @param routeHash Hash of the intent's route
     * @param reward Reward structure of the intent
     * @param claimant Cross-VM claimant identifier committed in the fulfillment
     * @param fulfilled Per-leg delivered amounts committed in the fulfillment (paired prefix)
     */
    function settle(
        uint64 destination,
        bytes32 routeHash,
        Reward calldata reward,
        bytes32 claimant,
        uint256[] calldata fulfilled
    ) public {
        (bytes32 intentHash, , bytes32 rewardHash) = getIntentHash(
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

        IAccount account = IAccount(_getOrDeployAccount(intentHash));
        account.withdraw(reward, claimantAddr, fulfilled);

        emit IntentWithdrawn(intentHash, claimantAddr);
    }

    /**
     * @notice Refunds rewards to the intent keeper
     * @param destination Destination chain ID for the intent
     * @param routeHash Hash of the intent's route
     * @param reward Reward structure of the intent
     */
    function refund(
        uint64 destination,
        bytes32 routeHash,
        Reward calldata reward
    ) external {
        (bytes32 intentHash, , ) = getIntentHash(
            destination,
            routeHash,
            reward
        );

        _refund(intentHash, destination, reward, reward.keeper);
    }

    /**
     * @notice Refunds rewards to a specified address (only callable by reward keeper)
     * @param destination Destination chain ID for the intent
     * @param routeHash Hash of the intent's route
     * @param reward Reward structure of the intent
     * @param refundee Address to receive the refunded rewards
     */
    function refundTo(
        uint64 destination,
        bytes32 routeHash,
        Reward calldata reward,
        address refundee
    ) external {
        if (msg.sender != reward.keeper) {
            revert NotKeeperCaller(msg.sender);
        }

        (bytes32 intentHash, , ) = getIntentHash(
            destination,
            routeHash,
            reward
        );

        _refund(intentHash, destination, reward, refundee);
    }

    /**
     * @notice Recover tokens that were sent to the intent account by mistake
     * @dev Must not be among the intent's rewards
     * @param destination Destination chain ID for the intent
     * @param routeHash Hash of the intent's route
     * @param reward Reward structure of the intent
     * @param token Token address for handling incorrect account transfers
     */
    function recoverToken(
        uint64 destination,
        bytes32 routeHash,
        Reward calldata reward,
        address token
    ) external {
        (bytes32 intentHash, , ) = getIntentHash(
            destination,
            routeHash,
            reward
        );

        _validateRecover(reward, token);

        IAccount account = IAccount(_getOrDeployAccount(intentHash));
        account.recover(reward.keeper, token);

        emit IntentTokenRecovered(intentHash, reward.keeper, token);
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
     * @param destination Destination chain ID for the intent
     * @param route Encoded route data for the intent as bytes
     * @param reward The reward structure containing distribution details
     * @param allowPartial Whether to accept partial funding
     * @param funder The address providing the funding
     * @return intentHash Hash of the created and funded intent
     * @return account Address of the created account
     */
    function _publishAndFund(
        uint64 destination,
        bytes memory route,
        Reward memory reward,
        bool allowPartial,
        address funder
    ) internal override returns (bytes32 intentHash, address account) {
        (intentHash, account) = publish(destination, route, reward);

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
     * @param allowPartial Whether to allow partial funding
     * @param funder Address providing the funding
     * @param permitContract Address of permit contract for token approvals
     * @return account Address of the funded account
     */
    function _fundIntentFor(
        Reward calldata reward,
        uint256[] memory targets,
        bytes32 intentHash,
        bool allowPartial,
        address funder,
        address permitContract
    ) internal onlyFundable(intentHash) returns (address account) {
        account = _getOrDeployAccount(intentHash);
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
     * @param destination Destination chain ID for the intent
     * @param reward Reward structure of the intent
     * @param refundee Address to receive the refunded rewards
     */
    function _refund(
        bytes32 intentHash,
        uint64 destination,
        Reward calldata reward,
        address refundee
    ) internal {
        _validateRefund(intentHash, destination, reward);
        rewardStatuses[intentHash] = Status.Refunded;

        IAccount account = IAccount(_getOrDeployAccount(intentHash));
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

    /**
     * @notice Gets existing account address or deploys new one if needed
     * @param intentHash Hash used as CREATE2 salt for deterministic addressing
     * @return Address of the account (existing or newly deployed)
     */
    function _getOrDeployAccount(bytes32 intentHash) internal returns (address) {
        address account = _getAccount(intentHash);

        return
            account.code.length > 0
                ? account
                : ACCOUNT_IMPLEMENTATION.clone(intentHash);
    }

    /**
     * @notice Calculates the deterministic account address without deployment
     * @param intentHash Hash used as CREATE2 salt for address calculation
     * @return Predicted address of the account
     */
    function _getAccount(bytes32 intentHash) internal view returns (address) {
        return ACCOUNT_IMPLEMENTATION.predict(intentHash, CREATE2_PREFIX);
    }
}
