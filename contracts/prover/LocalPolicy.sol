// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Semver} from "../libs/Semver.sol";
import {ILocalPolicy} from "../interfaces/ILocalPolicy.sol";
import {IPortal} from "../interfaces/IPortal.sol";
import {AddressConverter} from "../libs/AddressConverter.sol";
import {RewardMath} from "../libs/RewardMath.sol";
import {Intent, Route, Reward, RewardToken, TokenAmount, IntentLib} from "../types/Intent.sol";

/**
 * @title LocalPolicy
 * @notice Prover implementation for same-chain intent fulfillment with flash-fulfill capability
 * @dev Same-chain fulfillment recorded via {recordFulfillment} IS the proof — {provenIntents}
 *      synthesizes the source-side fact from the destination store. In the v3 hash-only model the store
 *      holds the `fulfillmentHash` (never the claimant); the claimant + delivered amounts are supplied
 *      as the preimage at settle. {flashFulfill} bundles a same-chain fulfill + settle into one tx.
 *
 *      NOTE (PR2 scope): unlike v2, {flashFulfill} no longer flash-loans the reward to fund the route —
 *      the reward now scales on the solver-provided `fulfilled[]` and settlement is gated on the
 *      fulfillment preimage, so the withdraw-before-fulfill flow is impossible. The solver provides the
 *      route capital (exactly the `minTokens` floor); the reward is settled to the claimant after execution.
 *      The no-upfront-capital flow is deferred to the "same-chain first-class" stage.
 */
contract LocalPolicy is ILocalPolicy, Semver, ReentrancyGuard {
    using AddressConverter for bytes32;
    using SafeERC20 for IERC20;

    /**
     * @notice Address of the Portal contract (IntentSource + Inbox functionality)
     */
    IPortal private immutable _PORTAL;

    uint64 private immutable _CHAIN_ID;

    /**
     * @notice DESTINATION fulfillment store: intent hash to the recorded fulfillment commitment
     * @dev Written by {recordFulfillment} (only the Portal). For same-chain intents this IS the proof.
     */
    mapping(bytes32 => bytes32) private _destFulfillment;

    constructor(address portal) {
        _PORTAL = IPortal(portal);

        if (block.chainid > type(uint64).max) {
            revert ChainIdTooLarge(block.chainid);
        }

        _CHAIN_ID = uint64(block.chainid);
    }

    /**
     * @notice Records a same-chain fulfillment for an intent
     * @dev Only the Portal may call this. Enforces a one-shot gate ({IntentAlreadyFulfilled}). Stores
     *      the hash-only fulfillment commitment; the `destination` argument is implied by {_CHAIN_ID}.
     * @param intentHash Hash of the fulfilled intent
     * @param fulfillmentHash Commitment to the proven `(intentHash, claimant, fulfilled[])` tuple
     */
    function recordFulfillment(
        bytes32 intentHash,
        uint64 /* destination */,
        bytes32 fulfillmentHash
    ) external {
        if (msg.sender != address(_PORTAL)) {
            revert NotPortal(msg.sender);
        }
        if (_destFulfillment[intentHash] != bytes32(0)) {
            revert IntentAlreadyFulfilled(intentHash);
        }
        _destFulfillment[intentHash] = fulfillmentHash;
    }

    /**
     * @notice Fetches a ProofData from this prover's own destination fulfillment store
     * @dev For same-chain intents the fulfillment recorded via {recordFulfillment} IS the proof. Returns
     *      the hash-only fact `{_CHAIN_ID, fulfillmentHash}` when recorded, else the zero fact. Claimant
     *      validity is checked at settle against the supplied preimage (there is no claimant to inspect
     *      here in the hash-only model).
     * @param intentHash the hash of the intent whose proof data is being queried
     * @return ProofData struct containing the destination chain ID and the fulfillment commitment
     */
    function provenIntents(
        bytes32 intentHash
    ) public view returns (ProofData memory) {
        bytes32 recorded = _destFulfillment[intentHash];
        if (recorded == bytes32(0)) {
            return ProofData(0, bytes32(0));
        }
        return ProofData(_CHAIN_ID, recorded);
    }

    /**
     * @notice Get the destination fulfillment commitment recorded for an intent on this chain
     * @param intentHash The intent hash to query
     * @return The recorded fulfillmentHash, or zero if unfulfilled
     */
    function destFulfillment(
        bytes32 intentHash
    ) external view returns (bytes32) {
        return _destFulfillment[intentHash];
    }

    /**
     * @notice The atomic rate+flat reward curve (pure view consulted by the Account at settle)
     * @param reward The reward specification
     * @param fulfilled The core-verified per-leg delivered amounts (paired prefix)
     * @return payNow Per-leg uncapped reward amount, index-aligned with `reward.tokens`
     */
    function previewRelease(
        Reward calldata reward,
        uint256[] calldata fulfilled
    ) external pure returns (uint256[] memory payNow) {
        uint256 legCount = reward.tokens.length;
        uint256 fulfilledLen = fulfilled.length;
        payNow = new uint256[](legCount);
        for (uint256 j; j < legCount; ++j) {
            RewardToken calldata leg = reward.tokens[j];
            if (j < fulfilledLen) {
                payNow[j] = RewardMath.reward(fulfilled[j], leg.rate, leg.flat);
            } else {
                payNow[j] = leg.flat;
            }
        }
    }

    function getProofType() external pure returns (string memory) {
        return "Same chain";
    }

    /**
     * @notice Initiates proving of intents on the same chain
     * @dev No-op for same-chain proving since proofs are created immediately upon fulfillment.
     */
    function prove(
        address /* sender */,
        uint64 /* sourceChainId */,
        bytes32[] calldata /* intentHashes */,
        bytes calldata /* data */
    ) external payable {
        // solhint-disable-previous-line no-empty-blocks
        // Intentionally empty: same-chain proving needs no dispatch. Must not revert (fulfillAndProve).
    }

    /**
     * @notice Challenges an intent proof (not applicable for same-chain intents)
     */
    function challengeIntentProof(
        uint64 /* source */,
        uint64 /* destination */,
        bytes32 /* routeHash */,
        bytes32 /* rewardHash */
    ) external pure {
        // solhint-disable-previous-line no-empty-blocks
        // Intentionally empty: same-chain intents cannot be challenged.
    }

    /**
     * @notice Atomically fulfills a same-chain intent and settles the reward to the claimant
     * @dev Fulfill-then-settle (PR2): provides exactly the `minTokens` input floor for each leg — pulls the
     *      ERC20 legs from the caller and approves the Portal, forwards the native leg as value — then
     *      executes the route via the Portal (which enforces the input floor and records the hash-only
     *      fact) and settles: the Account pays the claimant the owed reward and sweeps the residual to the
     *      keeper. `fulfilled[] == providedAmounts == the minTokens amounts`, so the settle preimage matches
     *      the recorded fulfillmentHash.
     *
     *      Same-chain: `source == destination == _CHAIN_ID`, so the source-escrow Account and the
     *      destination-execution Account collapse to ONE Account (Model C same-chain collapse).
     *
     *      WARNING: permissionless and front-runnable — standard MEV behavior in intent systems.
     * @param route Route information for the intent
     * @param reward Reward details for the intent
     * @param claimant Address of the claimant eligible for rewards
     * @return results The runtime's raw return data from the fulfill execution
     */
    function flashFulfill(
        Route calldata route,
        Reward calldata reward,
        bytes32 claimant
    ) external payable nonReentrant returns (bytes memory results) {
        if (claimant == bytes32(0)) revert InvalidClaimant();
        if (claimant == bytes32(uint256(uint160(address(this)))))
            revert InvalidClaimant();
        if (reward.prover != address(this)) revert InvalidProver();

        bytes32 routeHash = keccak256(abi.encode(route));
        bytes32 rewardHash = keccak256(abi.encode(reward));
        bytes32 intentHash = IntentLib.hashIntent(
            _CHAIN_ID,
            _CHAIN_ID,
            routeHash,
            rewardHash
        );

        // Provide exactly the input floor for each leg. Pull the ERC20 legs from the caller and approve
        // the Portal to pull them onto the Account; the native leg is forwarded from msg.value.
        uint256 inLen = route.minTokens.length;
        uint256[] memory providedAmounts = new uint256[](inLen);
        for (uint256 j = 0; j < inLen; ++j) {
            uint256 amount = route.minTokens[j].amount;
            providedAmounts[j] = amount;
            address token = route.minTokens[j].token;
            if (token != address(0)) {
                IERC20 t = IERC20(token);
                t.safeTransferFrom(msg.sender, address(this), amount);
                t.safeIncreaseAllowance(address(_PORTAL), amount);
            }
        }

        results = _PORTAL.fulfill{value: msg.value}(
            _CHAIN_ID,
            intentHash,
            route,
            rewardHash,
            claimant,
            providedAmounts,
            address(this)
        );

        // Settle: pays the claimant the owed reward from the account, sweeps residual to the keeper.
        // `providedAmounts` is the committed `fulfilled[]`, so the preimage matches the recorded fact.
        _PORTAL.settle(
            _CHAIN_ID,
            _CHAIN_ID,
            routeHash,
            reward,
            claimant,
            providedAmounts
        );

        emit FlashFulfilled(intentHash, claimant, 0);
    }

    /**
     * @notice Allows contract to receive native tokens
     */
    receive() external payable {}
}
