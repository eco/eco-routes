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
            // Otherwise return LocalProver (shouldn't happen but handle gracefully)
            return ProofData(address(this), _CHAIN_ID);
        }

        // Case 2: Intent fulfilled via normal Portal.fulfill (not flashFulfill)
        if (portalClaimant != bytes32(0)) {
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
     * @dev Withdraws funds from vault, executes fulfill, transfers excess to claimant.
     *      Uses checks-effects-interactions pattern for security.
     *      Protected against reentrancy attacks via nonReentrant modifier.
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

        // Record initial balance before withdrawal
        uint256 balanceBefore = address(this).balance;

        // INTERACTIONS - Withdraw to LocalProver
        _PORTAL.withdraw(_CHAIN_ID, routeHash, reward);

        // Calculate withdrawn amount
        uint256 withdrawnNative = address(this).balance - balanceBefore;

        // Determine native amount for fulfill (use msg.value if provided, else use withdrawn)
        uint256 fulfillNativeAmount = msg.value > 0 ? msg.value : withdrawnNative;

        // Call fulfill with LocalProver as Portal claimant
        // This enables withdrawal before fulfill (Portal checks claimants mapping)
        bytes32 localProverAsClaimant = bytes32(uint256(uint160(address(this))));
        results = _PORTAL.fulfill{value: fulfillNativeAmount}(
            intentHash,
            route,
            rewardHash,
            localProverAsClaimant
        );

        // EFFECTS - Transfer remaining funds to claimant
        uint256 remainingNative = address(this).balance;
        address claimantAddress = claimant.toAddress();

        // Transfer remaining native
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
     *      Secondary intent must have LocalProver as creator for this to work.
     *      Protected against reentrancy attacks via nonReentrant modifier.
     * @param originalIntent Complete original intent struct
     * @param secondaryIntent Complete secondary intent struct
     */
    function refundBoth(
        Intent calldata originalIntent,
        Intent calldata secondaryIntent
    ) external nonReentrant {
        // CHECKS
        // Verify secondary intent creator is LocalProver
        if (secondaryIntent.reward.creator != address(this)) {
            revert InvalidSecondaryCreator();
        }

        // Verify secondary intent expired
        if (block.timestamp <= secondaryIntent.reward.deadline) {
            revert("Secondary intent not expired");
        }

        // Verify secondary intent not proven
        (bytes32 secondaryHash, bytes32 secondaryRouteHash, ) = _PORTAL.getIntentHash(secondaryIntent);
        ProofData memory proof = IProver(secondaryIntent.reward.prover).provenIntents(secondaryHash);
        if (proof.claimant != address(0)) {
            revert("Secondary intent already proven");
        }

        // INTERACTIONS
        // Compute original vault address
        address originalVault = _PORTAL.intentVaultAddress(originalIntent);

        // Refund secondary to original vault
        _PORTAL.refundTo(
            secondaryIntent.destination,
            secondaryRouteHash,
            secondaryIntent.reward,
            originalVault
        );

        // Refund original (goes to creator/vault)
        bytes32 originalRouteHash = keccak256(abi.encode(originalIntent.route));
        _PORTAL.refund(
            originalIntent.destination,
            originalRouteHash,
            originalIntent.reward
        );

        (bytes32 originalHash, , ) = _PORTAL.getIntentHash(originalIntent);
        emit BothRefunded(originalHash, secondaryHash, originalVault);
    }

    // Allow contract to receive native tokens
    receive() external payable {}
}
