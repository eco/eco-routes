// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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
 */
contract LocalProver is ILocalProver, Semver {
    using SafeCast for uint256;
    using AddressConverter for bytes32;
    using SafeERC20 for IERC20;

    /**
     * @notice Address of the Portal contract (IntentSource + Inbox functionality)
     * @dev Immutable to prevent unauthorized changes
     */
    IPortal private immutable _PORTAL;

    uint64 private immutable _CHAIN_ID;

    constructor(address portal) {
        _PORTAL = IPortal(portal);

        if (block.chainid > type(uint64).max) {
            revert ChainIdTooLarge(block.chainid);
        }

        _CHAIN_ID = uint64(block.chainid);
    }

    /**
     * @notice Fetches a ProofData from the Portal's claimants mapping
     * @dev For same-chain intents, proofs are created immediately upon fulfillment
     * @param intentHash the hash of the intent whose proof data is being queried
     * @return ProofData struct containing the destination chain ID and claimant address
     */
    function provenIntents(
        bytes32 intentHash
    ) public view returns (ProofData memory) {
        // Read from Portal's claimants mapping
        // Note: Must cast to Inbox to access public claimants mapping
        bytes32 claimant = Inbox(address(_PORTAL)).claimants(intentHash);

        if (claimant == bytes32(0)) {
            return ProofData(address(0), 0);
        }

        return ProofData(claimant.toAddress(), _CHAIN_ID);
    }

    function getProofType() external pure returns (string memory) {
        return "Same chain";
    }

    /**
     * @notice Initiates proving of intents on the same chain
     * @dev This function is a no-op for same-chain proving since proofs are created immediately upon fulfillment
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
    ) external payable returns (bytes[] memory results) {
        // CHECKS
        if (claimant == bytes32(0)) revert InvalidClaimant();

        // Verify intent hash matches
        bytes32 routeHash = keccak256(abi.encode(route));
        bytes32 rewardHash = keccak256(abi.encode(reward));
        bytes32 computedIntentHash = keccak256(
            abi.encodePacked(_CHAIN_ID, routeHash, rewardHash)
        );
        if (computedIntentHash != intentHash) revert InvalidIntentHash();

        // EFFECTS - Record initial balance before withdrawal
        uint256 balanceBefore = address(this).balance;

        // INTERACTIONS - Withdraw to LocalProver
        _PORTAL.withdraw(_CHAIN_ID, routeHash, reward);

        // Calculate withdrawn amount
        uint256 withdrawnNative = address(this).balance - balanceBefore;

        // Determine native amount for fulfill (use msg.value if provided, else use withdrawn)
        uint256 fulfillNativeAmount = msg.value > 0 ? msg.value : withdrawnNative;

        // Call fulfill with claimant
        results = _PORTAL.fulfill{value: fulfillNativeAmount}(
            intentHash,
            route,
            rewardHash,
            claimant
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
     * @param originalIntent Complete original intent struct
     * @param secondaryIntent Complete secondary intent struct
     */
    function refundBoth(
        Intent calldata originalIntent,
        Intent calldata secondaryIntent
    ) external {
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
