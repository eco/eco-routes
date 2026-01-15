// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Inbox} from "../Inbox.sol";
import {Semver} from "../libs/Semver.sol";
import {IProver} from "../interfaces/IProver.sol";
import {ILocalProver} from "../interfaces/ILocalProver.sol";
import {IPortal} from "../interfaces/IPortal.sol";
import {AddressConverter} from "../libs/AddressConverter.sol";
import {Intent, Route, Reward, TokenAmount} from "../types/Intent.sol";

/**
 * @title LocalProver
 * @notice Prover implementation for same-chain intent fulfillment with flash-fulfill capability
 * @dev Handles proving of intents that are fulfilled on the same chain where they were created.
 *      Flash-fulfill withdraws from vault, executes fulfill, and immediately pays solver.
 *      Uses ReentrancyGuard to prevent cross-intent reentrancy attacks.
 */
contract LocalProver is ILocalProver, Semver, ReentrancyGuard {
    using SafeCast for uint256;
    using AddressConverter for bytes32;
    using SafeERC20 for IERC20;

    /**
     * @notice Address of the Portal contract (IntentSource + Inbox functionality)
     * @dev Immutable to prevent unauthorized changes
     */
    IPortal private immutable _PORTAL;

    uint64 private immutable _CHAIN_ID;

    /**
     * @notice Maps intent hashes to their actual claimant addresses
     * @dev Used when LocalProver is the Portal claimant to track the real solver
     */
    mapping(bytes32 => address) private _actualClaimants;

    constructor(address portal) {
        _PORTAL = IPortal(portal);

        if (block.chainid > type(uint64).max) {
            revert ChainIdTooLarge(block.chainid);
        }

        _CHAIN_ID = uint64(block.chainid);
    }

    /**
     * @notice Fetches a ProofData from the Portal's claimants mapping
     * @dev For same-chain intents, proofs are created immediately upon fulfillment.
     *      During flashFulfill, returns LocalProver as claimant to enable withdrawal.
     *      After fulfill, returns actual solver from _actualClaimants mapping.
     *
     *      Griefing protection: If Portal.claimants is set but _actualClaimants is not,
     *      or if Portal.claimants contains an invalid EVM address, returns address(0)
     *      to treat the intent as unfulfilled and allow refunds after deadline.
     * @param intentHash the hash of the intent whose proof data is being queried
     * @return ProofData struct containing the destination chain ID and claimant address
     */
    function provenIntents(
        bytes32 intentHash
    ) public view returns (ProofData memory) {
        // Check Portal's claimants mapping first
        // Note: Must cast to Inbox to access public claimants mapping
        bytes32 portalClaimant = Inbox(address(_PORTAL)).claimants(intentHash);

        // Case 1: Intent fulfilled via flashFulfill (Portal claimant is LocalProver)
        bytes32 localProverAsBytes32 = bytes32(uint256(uint160(address(this))));
        if (portalClaimant == localProverAsBytes32) {
            // Return actual solver if we have one stored
            address storedClaimant = _actualClaimants[intentHash];
            if (storedClaimant != address(0)) {
                return ProofData(storedClaimant, _CHAIN_ID);
            }
            // Someone called Portal.fulfill with LocalProver as claimant without going through flashFulfill
            // This is griefing - treat intent as unfulfilled to allow refunds
            return ProofData(address(0), 0);
        }

        // Case 2: Intent fulfilled via normal Portal.fulfill (not flashFulfill)
        if (portalClaimant != bytes32(0)) {
            // Validate before converting - protects against non-EVM bytes32 griefing
            if (!AddressConverter.isValidAddress(portalClaimant)) {
                // Invalid EVM address - treat as unfulfilled to allow refunds
                return ProofData(address(0), 0);
            }
            return ProofData(portalClaimant.toAddress(), _CHAIN_ID);
        }

        // Case 3: Intent not yet fulfilled, but flashFulfill in progress
        // Check if we have an actual claimant stored (means flashFulfill called)
        address actualClaimant = _actualClaimants[intentHash];
        if (actualClaimant != address(0)) {
            // Return LocalProver so withdrawal succeeds (funds come to LocalProver)
            return ProofData(address(this), _CHAIN_ID);
        }

        // Case 4: Intent not fulfilled at all
        return ProofData(address(0), 0);
    }

    function getProofType() external pure returns (string memory) {
        return "Same chain";
    }

    /**
     * @notice Initiates proving of intents on the same chain
     * @dev This function is a no-op for same-chain proving since proofs are created immediately upon fulfillment.
     *      WARNING: This function is payable for compatibility but does not use ETH. Any ETH sent to this
     *      function will remain in the contract and be distributed to the next flashFulfill caller as part
     *      of their reward. Do not send ETH to this function.
     */
    function prove(
        address /* sender */,
        uint64 /* sourceChainId */,
        bytes calldata /* encodedProofs */,
        bytes calldata /* data */
    ) external payable {
        // solhint-disable-line no-empty-blocks
        // this function is intentionally left empty as no proof is required
        // for same-chain proving
        // should not revert lest it be called with fulfillandprove
    }

    /**
     * @notice Challenges an intent proof (not applicable for same-chain intents)
     * @dev This function is a no-op for same-chain intents as they cannot be challenged
     */
    function challengeIntentProof(
        uint64 /* destination */,
        bytes32 /* routeHash */,
        bytes32 /* rewardHash */
    ) external pure {
        // solhint-disable-line no-empty-blocks
        // Intentionally left empty as same-chain intents cannot be challenged
        // This is a no-op similar to the prove function above
    }

    /**
     * @notice Atomically fulfills an intent and pays claimant with remaining funds
     * @dev Withdraws reward from vault, executes fulfill, transfers remaining funds to claimant.
     *      Uses checks-effects-interactions pattern for security.
     *      Protected against reentrancy attacks via nonReentrant modifier.
     *
     *      Flow:
     *      1. Withdraws reward.tokens + reward.nativeAmount from vault to LocalProver
     *      2. Approves Portal to spend route.tokens
     *      3. Calls fulfill which transfers route.tokens to executor for execution
     *      4. Transfers all remaining token balances (reward.tokens - route.tokens) to claimant
     *      5. Transfers all remaining native ETH to claimant
     *
     *      Claimant receives:
     *      - All ERC20 tokens in reward.tokens (minus any consumed by route.tokens)
     *      - All native ETH from reward.nativeAmount (minus any consumed by route.nativeAmount)
     *      - Plus any msg.value sent by caller (typically 0)
     *
     *      WARNING: This function is permissionless and subject to front-running. Any solver can call this
     *      function for any intent and specify themselves as the claimant. Solvers should use private
     *      transaction pools (e.g., Flashbots) or coordinate off-chain with intent creators to mitigate
     *      front-running risks. This is standard MEV behavior in intent-based systems.
     *
     * @param intentHash Hash of the intent to flash-fulfill
     * @param route Route information for the intent
     * @param reward Reward details for the intent
     * @param claimant Address of the claimant eligible for rewards (gets immediate payout)
     * @return results Results from the fulfill execution
     */
    function flashFulfill(
        bytes32 intentHash,
        Route calldata route,
        Reward calldata reward,
        bytes32 claimant
    ) external payable nonReentrant returns (bytes[] memory results) {
        // CHECKS
        if (claimant == bytes32(0)) revert InvalidClaimant();

        // Verify intent hash matches
        bytes32 routeHash = keccak256(abi.encode(route));
        bytes32 rewardHash = keccak256(abi.encode(reward));
        bytes32 computedIntentHash = keccak256(
            abi.encodePacked(_CHAIN_ID, routeHash, rewardHash)
        );
        if (computedIntentHash != intentHash) revert InvalidIntentHash();

        // EFFECTS - Store actual claimant before fulfill
        // This allows withdrawal to succeed (LocalProver becomes Portal claimant)
        // while tracking the real solver address
        _actualClaimants[intentHash] = claimant.toAddress();

        // INTERACTIONS - Withdraw to LocalProver
        _PORTAL.withdraw(_CHAIN_ID, routeHash, reward);

        // Approve Portal to spend route tokens
        uint256 tokensLength = route.tokens.length;
        for (uint256 i = 0; i < tokensLength; ++i) {
            IERC20(route.tokens[i].token).approve(
                address(_PORTAL),
                route.tokens[i].amount
            );
        }

        // Call fulfill with LocalProver as Portal claimant
        // Use entire contract balance for fulfill (includes msg.value + any existing balance)
        // This enables withdrawal before fulfill (Portal checks claimants mapping)
        bytes32 localProverAsClaimant = bytes32(uint256(uint160(address(this))));
        results = _PORTAL.fulfill{value: address(this).balance}(
            intentHash,
            route,
            rewardHash,
            localProverAsClaimant
        );

        // EFFECTS - Transfer remaining funds to claimant
        address claimantAddress = claimant.toAddress();

        // Transfer reward tokens to claimant
        uint256 rewardTokensLength = reward.tokens.length;
        for (uint256 i = 0; i < rewardTokensLength; ++i) {
            IERC20 rewardToken = IERC20(reward.tokens[i].token);
            uint256 balance = rewardToken.balanceOf(address(this));
            if (balance > 0) {
                rewardToken.safeTransfer(claimantAddress, balance);
            }
        }

        // Transfer remaining native
        uint256 remainingNative = address(this).balance;
        if (remainingNative > 0) {
            (bool success, ) = claimantAddress.call{value: remainingNative}("");
            if (!success) revert NativeTransferFailed();
        }

        emit FlashFulfilled(intentHash, claimant, remainingNative);

        return results;
    }

    /**
     * @notice Refunds both original and secondary intents in a single transaction
     * @dev Permissionless - anyone can trigger if conditions are met.
     *      Secondary intent must have originalVault as creator for this to work.
     *      The originalVault address is computed via Portal.intentVaultAddress(originalIntent).
     *      This ensures refunds flow: SecondaryVault → OriginalVault → User.
     *      Protected against reentrancy attacks via nonReentrant modifier.
     * @param originalIntent Complete original intent struct
     * @param secondaryIntent Complete secondary intent struct (with reward.creator = originalVault)
     */
    function refundBoth(
        Intent calldata originalIntent,
        Intent calldata secondaryIntent
    ) external nonReentrant {
        // CHECKS
        // Compute original vault address
        address originalVault = _PORTAL.intentVaultAddress(originalIntent);

        // Verify secondary intent creator is original vault (validates linkage)
        if (secondaryIntent.reward.creator != originalVault) {
            revert InvalidSecondaryCreator();
        }

        // INTERACTIONS
        // Calculate secondary intent hashes locally
        bytes32 secondaryRouteHash = keccak256(abi.encode(secondaryIntent.route));
        bytes32 secondaryRewardHash = keccak256(abi.encode(secondaryIntent.reward));
        bytes32 secondaryHash = keccak256(
            abi.encodePacked(secondaryIntent.destination, secondaryRouteHash, secondaryRewardHash)
        );

        // Refund secondary to original vault (automatic via creator field)
        // Note: Portal.refund validates expiry and proof status internally
        _PORTAL.refund(
            secondaryIntent.destination,
            secondaryRouteHash,
            secondaryIntent.reward
        );

        // Calculate original intent hashes locally
        bytes32 originalRouteHash = keccak256(abi.encode(originalIntent.route));
        bytes32 originalRewardHash = keccak256(abi.encode(originalIntent.reward));
        bytes32 originalHash = keccak256(
            abi.encodePacked(originalIntent.destination, originalRouteHash, originalRewardHash)
        );

        // Refund original (goes to creator/vault)
        _PORTAL.refund(
            originalIntent.destination,
            originalRouteHash,
            originalIntent.reward
        );

        emit BothRefunded(originalHash, secondaryHash, originalVault);
    }

    /**
     * @notice Allows contract to receive native tokens
     * @dev Required for vault withdrawals that include native rewards
     */
    receive() external payable {}
}
