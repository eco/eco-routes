// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Semver} from "../libs/Semver.sol";
import {ISameChainFlashPolicy} from "../interfaces/ISameChainFlashPolicy.sol";
import {IFlashSolver} from "../interfaces/IFlashSolver.sol";
import {IPortal} from "../interfaces/IPortal.sol";
import {AddressConverter} from "../libs/AddressConverter.sol";
import {RewardMath} from "../libs/RewardMath.sol";
import {Route, Reward, RewardToken, IntentLib} from "../types/Intent.sol";

/**
 * @title SameChainFlashPolicy
 * @notice ONE-SHOT zero-capital same-chain flash policy — v2's {LocalProver-flashFulfill}
 *         withdraw-before-fulfill flow restored with v3 primitives, as a standalone policy (no core
 *         changes).
 * @dev v3 keeps the committed policy as the settlement oracle: {IIntentSource-settle} trusts
 *      `IPolicy(reward.prover).provenIntents` and the Account trusts {IPolicy-previewRelease}. This policy
 *      therefore authorizes the escrow release BEFORE the fulfill within its own atomic session:
 *
 *        1. SESSION OPEN — pin the intent hash and a synthetic SESSION FACT committing THIS POLICY as
 *           claimant over the exact `minTokens` floors.
 *        2. ADVANCE — call the generic `settle` with `(claimant = this, fulfilled = floors)`;
 *           {provenIntents} serves the session fact (only while no real fact exists), the preimage check
 *           passes, and the Account pays this policy the owed reward (rate*floors+flat, balance-capped)
 *           and sweeps the residual to the keeper. Status flips to `Withdrawn`, so no path can release
 *           the escrow again — mid-session or ever.
 *        3. FUND + FULFILL — the advance funds the route inputs (directly, or via the caller's
 *           {IFlashSolver} swap callback), then the real `fulfill` runs with the REAL claimant. The
 *           reward-conservation snapshot is ~0 (the escrow was already released under protocol control),
 *           and {recordFulfillment} accepts ONLY the session's expected real-claimant fact.
 *        4. MARGIN — every remaining reward-leg balance (and native) is forwarded to the claimant: the
 *           solver's profit is the protocol-enforced reward spread. SESSION CLOSE.
 *
 *      Any misalignment anywhere reverts the WHOLE transaction (the session unwinds with it).
 *
 *      Outside a session this policy behaves exactly like {LocalPolicy} (one-shot record store, fact IS
 *      the proof, standard curve), so plain fulfill-then-settle also works against it.
 *
 *      GRIEFING (documented residuals, no theft):
 *        - A pre-recorded real fact BLOCKS flash for that hash ({IntentAlreadyFulfilled}). Recording one
 *          requires an actual `fulfill` — full input capital + route execution — so this is at worst a
 *          competing (honest) fulfillment, settleable with its own preimage; a DoS of the flash path only.
 *        - A fulfillment committed to THIS POLICY as claimant strands its settle payout here; stranded
 *          balances become the next flash caller's bonus margin (v2 parity). It can never lock the
 *          keeper: past `reward.deadline` the reward is always refundable (hash-only anti-lock).
 *        - Native margin is forwarded best-effort (v2 parity): a claimant that rejects native leaves it
 *          here for the next flash caller.
 */
contract SameChainFlashPolicy is
    ISameChainFlashPolicy,
    Semver,
    ReentrancyGuard
{
    using AddressConverter for bytes32;
    using SafeERC20 for IERC20;

    /**
     * @notice Address of the Portal (the permanent {PortalProxy}) this policy settles through.
     */
    IPortal private immutable _PORTAL;

    uint64 private immutable _CHAIN_ID;

    /**
     * @notice Sentinel for "no flash session in progress".
     * @dev Non-zero so the session slot flips non-zero -> non-zero (cheaper than zero -> non-zero, v2
     *      parity). Unreachable as a real intent hash (keccak preimage).
     */
    bytes32 private constant _NO_SESSION = bytes32(uint256(1));

    /**
     * @notice DESTINATION fulfillment store: intent hash to the recorded fulfillment commitment.
     * @dev Written by {recordFulfillment} (only the Portal). For same-chain intents this IS the proof.
     */
    mapping(bytes32 => bytes32) private _destFulfillment;

    /// @notice The intent hash currently being flash-fulfilled ({_NO_SESSION} when idle).
    bytes32 private _sessionIntentHash;

    /// @notice The synthetic session fact (THIS POLICY as claimant over the planned floors) served to
    ///         `settle` via {provenIntents} during the session.
    bytes32 private _sessionFact;

    /// @notice The expected REAL fact (the real claimant over the planned floors) — the only record
    ///         {recordFulfillment} accepts during the session.
    bytes32 private _sessionExpectedFact;

    constructor(address portal) {
        if (portal == address(0)) {
            revert ZeroPortal();
        }
        _PORTAL = IPortal(portal);

        if (block.chainid > type(uint64).max) {
            revert ChainIdTooLarge(block.chainid);
        }
        _CHAIN_ID = uint64(block.chainid);

        _sessionIntentHash = _NO_SESSION;
    }

    /**
     * @notice Records a same-chain fulfillment for an intent.
     * @dev Only the Portal may call. Enforces the one-shot gate ({IntentAlreadyFulfilled}). DURING a flash
     *      session the record is STRICT: only the session intent's expected real-claimant fact is accepted
     *      ({UnexpectedSessionFulfillment} otherwise) — any interleaved fulfill (another intent, another
     *      claimant, other amounts) reverts the whole flash transaction. Outside a session this is exactly
     *      {LocalPolicy-recordFulfillment}.
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
        if (
            _sessionIntentHash != _NO_SESSION &&
            (intentHash != _sessionIntentHash ||
                fulfillmentHash != _sessionExpectedFact)
        ) {
            revert UnexpectedSessionFulfillment(intentHash);
        }
        _destFulfillment[intentHash] = fulfillmentHash;
    }

    /**
     * @notice Fetches a ProofData from this policy's own destination fulfillment store.
     * @dev PRECEDENCE (the flash-session core):
     *        1. a REAL stored fact always wins;
     *        2. else, DURING an open flash session for exactly this hash, the synthetic session fact
     *           (this policy as claimant over the planned floors) — this is what lets the in-session
     *           `settle` release the advance to the policy;
     *        3. else the zero fact.
     *      The session fact is only ever observable inside the policy's own atomic {flashFulfill}
     *      transaction (the session opens and closes within it, `nonReentrant`), so no external caller can
     *      settle against it.
     * @param intentHash the hash of the intent whose proof data is being queried
     * @return ProofData struct containing the destination chain ID and the fulfillment commitment
     */
    function provenIntents(
        bytes32 intentHash
    ) public view returns (ProofData memory) {
        bytes32 recorded = _destFulfillment[intentHash];
        if (recorded != bytes32(0)) {
            return ProofData(_CHAIN_ID, recorded);
        }
        if (_sessionIntentHash == intentHash) {
            return ProofData(_CHAIN_ID, _sessionFact);
        }
        return ProofData(0, bytes32(0));
    }

    /**
     * @notice Get the destination fulfillment commitment recorded for an intent on this chain.
     * @param intentHash The intent hash to query
     * @return The recorded fulfillmentHash, or zero if unfulfilled
     */
    function destFulfillment(
        bytes32 intentHash
    ) external view returns (bytes32) {
        return _destFulfillment[intentHash];
    }

    /**
     * @notice The atomic rate+flat reward curve (pure view consulted by the Account at settle).
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
        return "Same chain flash";
    }

    /**
     * @notice Initiates proving of intents on the same chain.
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
     * @notice Challenges an intent proof (not applicable for same-chain intents).
     */
    function challengeIntentProof(
        uint32 /* protocolVersion */,
        uint64 /* source */,
        uint64 /* destination */,
        bytes32 /* routeHash */,
        bytes32 /* rewardHash */
    ) external pure {
        // solhint-disable-previous-line no-empty-blocks
        // Intentionally empty: same-chain intents cannot be challenged.
    }

    /// @inheritdoc ISameChainFlashPolicy
    function flashFulfill(
        uint32 protocolVersion,
        Route calldata route,
        Reward calldata reward,
        bytes32 claimant,
        bytes calldata solverData
    ) external payable nonReentrant returns (bytes memory results) {
        bytes32 thisAsBytes32 = bytes32(uint256(uint160(address(this))));
        if (
            claimant == bytes32(0) ||
            claimant == thisAsBytes32 ||
            !claimant.isValidAddress()
        ) {
            revert InvalidClaimant();
        }
        if (reward.prover != address(this)) {
            revert InvalidProver();
        }

        bytes32 routeHash = keccak256(abi.encode(route));
        bytes32 intentHash = IntentLib.hashIntent(
            protocolVersion,
            _CHAIN_ID,
            _CHAIN_ID,
            routeHash,
            keccak256(abi.encode(reward))
        );

        // A pre-recorded real fact blocks flash: the escrow already answers to that fulfillment's
        // preimage (a competing fulfill or a griefing-DoS — never theft; see the contract note).
        if (_destFulfillment[intentHash] != bytes32(0)) {
            revert IntentAlreadyFulfilled(intentHash);
        }

        // One-shot intents commit EXACT amounts: the planned fulfilled[] is the minTokens floors.
        uint256 inLen = route.minTokens.length;
        uint256[] memory planned = new uint256[](inLen);
        for (uint256 j; j < inLen; ++j) {
            planned[j] = route.minTokens[j].amount;
        }

        // ---- SESSION OPEN --------------------------------------------------------------------------
        _sessionIntentHash = intentHash;
        _sessionFact = IntentLib.fulfillmentHash(
            intentHash,
            thisAsBytes32,
            planned
        );
        _sessionExpectedFact = IntentLib.fulfillmentHash(
            intentHash,
            claimant,
            planned
        );

        // ---- ADVANCE: settle the escrow to THIS policy (session self-vouching) ----------------------
        // Measures the per-leg received deltas so swap mode hands the solver exactly this advance.
        uint256 rewardLen = reward.tokens.length;
        uint256[] memory received = new uint256[](rewardLen);
        for (uint256 i; i < rewardLen; ++i) {
            received[i] = _balanceOfSelf(reward.tokens[i].token);
        }
        _PORTAL.settle(
            protocolVersion,
            _CHAIN_ID,
            _CHAIN_ID,
            routeHash,
            reward,
            thisAsBytes32,
            planned
        );
        for (uint256 i; i < rewardLen; ++i) {
            received[i] = _balanceOfSelf(reward.tokens[i].token) - received[i];
        }

        // ---- FUND + FULFILL (real claimant; conservation snapshot is ~0) ----------------------------
        uint256 nativeNeeded = _stageInputs(
            route,
            reward,
            intentHash,
            received,
            planned,
            solverData
        );
        results = _PORTAL.fulfill{value: nativeNeeded}(
            protocolVersion,
            _CHAIN_ID,
            _CHAIN_ID,
            route,
            reward,
            claimant,
            planned,
            address(this)
        );

        // ALIGNMENT: the recorded fact must be exactly the expected real-claimant fact
        // ({recordFulfillment} already enforced it; belt-and-braces).
        if (_destFulfillment[intentHash] != _sessionExpectedFact) {
            revert MisalignedFulfillment(intentHash);
        }

        // ---- MARGIN: forward all remaining reward-leg balances + native to the claimant -------------
        uint256 nativeMargin = _forwardMargin(reward, claimant.toAddress());

        // ---- SESSION CLOSE ---------------------------------------------------------------------------
        _sessionIntentHash = _NO_SESSION;
        _sessionFact = bytes32(0);
        _sessionExpectedFact = bytes32(0);

        emit FlashFulfilled(intentHash, claimant, nativeMargin);
    }

    /**
     * @notice Funds the route inputs out of the advance (direct mode) or via the caller's swap callback.
     * @dev Swap mode (`solverData` non-empty): hand the received advance to the caller, invoke
     *      {IFlashSolver-onFlashAdvance}, then pull the exact ERC20 input legs back (the solver approved
     *      this policy during the callback). Direct mode: the advance held here funds the inputs (the
     *      same-token / deposit case). Either way the Portal is approved for the ERC20 legs and the
     *      native leg amount is returned to be forwarded as value.
     * @param route The route (its `minTokens` are the input legs)
     * @param reward The reward (its `tokens` shape the advance)
     * @param intentHash The session intent hash (passed to the callback)
     * @param advance Per-leg advance amounts received at settle, index-aligned with `reward.tokens`
     * @param inputAmounts Per-leg input amounts to stage, index-aligned with `route.minTokens`
     * @param solverData Empty for direct mode; otherwise forwarded to the caller's callback
     * @return nativeNeeded The native input-leg amount to forward into the fulfill
     */
    function _stageInputs(
        Route calldata route,
        Reward calldata reward,
        bytes32 intentHash,
        uint256[] memory advance,
        uint256[] memory inputAmounts,
        bytes calldata solverData
    ) private returns (uint256 nativeNeeded) {
        bool swapMode = solverData.length != 0;

        if (swapMode) {
            uint256 rewardLen = reward.tokens.length;
            for (uint256 i; i < rewardLen; ++i) {
                uint256 amount = advance[i];
                if (amount == 0) {
                    continue;
                }
                address token = reward.tokens[i].token;
                if (token == address(0)) {
                    (bool ok, ) = msg.sender.call{value: amount}("");
                    if (!ok) {
                        revert NativeTransferFailed();
                    }
                } else {
                    _transferToken(IERC20(token), msg.sender, amount);
                }
            }
            IFlashSolver(msg.sender).onFlashAdvance(
                intentHash,
                advance,
                solverData
            );
        }

        uint256 inLen = route.minTokens.length;
        for (uint256 j; j < inLen; ++j) {
            address token = route.minTokens[j].token;
            uint256 amount = inputAmounts[j];
            if (token == address(0)) {
                // At most one native leg (minTokens are strictly ascending; address(0) sorts first).
                nativeNeeded = amount;
                continue;
            }
            if (amount == 0) {
                continue;
            }
            if (swapMode) {
                // Pull the repayment the solver approved during the callback; reverts (unwinding the
                // whole flash, advance included) if the solver failed to repay.
                IERC20(token).safeTransferFrom(
                    msg.sender,
                    address(this),
                    amount
                );
            }
            IERC20(token).safeIncreaseAllowance(address(_PORTAL), amount);
        }
    }

    /**
     * @notice Forwards the margin — every remaining reward-leg ERC20 balance plus the full native balance
     *         — to the claimant.
     * @dev Native is best-effort (v2 parity): if the claimant rejects it, it stays here and becomes the
     *      next flash caller's bonus margin. ERC20 margins use {_transferToken} (virtual for a future
     *      Tron subclass).
     * @param reward The reward whose token legs define the margin columns
     * @param claimantAddr The margin recipient
     * @return nativeMargin The native amount forwarded (attempted)
     */
    function _forwardMargin(
        Reward calldata reward,
        address claimantAddr
    ) private returns (uint256 nativeMargin) {
        uint256 rewardLen = reward.tokens.length;
        for (uint256 i; i < rewardLen; ++i) {
            address token = reward.tokens[i].token;
            if (token == address(0)) {
                continue;
            }
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance > 0) {
                _transferToken(IERC20(token), claimantAddr, balance);
            }
        }

        nativeMargin = address(this).balance;
        if (nativeMargin > 0) {
            // Best-effort (v2 parity) — failure leaves the native here for the next flash caller.
            // solhint-disable-next-line avoid-low-level-calls
            claimantAddr.call{value: nativeMargin}("");
        }
    }

    /**
     * @notice Reads this policy's own balance of `token`; `address(0)` denotes native.
     */
    function _balanceOfSelf(address token) private view returns (uint256) {
        return
            token == address(0)
                ? address(this).balance
                : IERC20(token).balanceOf(address(this));
    }

    /**
     * @notice Transfers ERC20 tokens out of the policy.
     * @dev Virtual so subclasses can override for non-standard tokens (e.g. Tron USDT).
     * @param token ERC20 token to transfer
     * @param to Recipient address
     * @param amount Amount to transfer
     */
    function _transferToken(
        IERC20 token,
        address to,
        uint256 amount
    ) internal virtual {
        token.safeTransfer(to, amount);
    }

    /**
     * @notice Allows the policy to receive native tokens (the settle advance, solver native repayment).
     */
    receive() external payable {}
}
