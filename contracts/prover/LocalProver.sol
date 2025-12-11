// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Inbox} from "../Inbox.sol";
import {Semver} from "../libs/Semver.sol";
import {IProver} from "../interfaces/IProver.sol";
import {IIntentSource} from "../interfaces/IIntentSource.sol";
import {AddressConverter} from "../libs/AddressConverter.sol";
import {Intent, Route, Reward, TokenAmount} from "../types/Intent.sol";

/**
 * @title LocalProver
 * @notice Prover implementation for same-chain intent fulfillment with flash-fulfill capability
 * @dev Handles proving of intents that are fulfilled on the same chain where they were created.
 *      Supports atomic flash-fulfill with conditional rewards based on secondary intent completion.
 */
contract LocalProver is IProver, Semver {
    using SafeCast for uint256;
    using AddressConverter for bytes32;
    using SafeERC20 for IERC20;

    /**
     * @notice Address of the Portal contract (IntentSource + Inbox functionality)
     * @dev Immutable to prevent unauthorized changes
     */
    IIntentSource private immutable _PORTAL;

    uint64 private immutable _CHAIN_ID;

    /**
     * @notice Escrow data for flash-fulfilled intents
     * @dev Tracks funds held pending secondary intent completion
     */
    struct EscrowData {
        address claimant;              // Solver eligible for rewards
        uint256 nativeAmount;          // Escrowed native tokens
        TokenAmount[] tokens;          // Escrowed ERC20 tokens
        bytes32 secondaryIntentHash;   // Dependent intent that must complete
        address secondaryProver;       // Prover for the secondary intent (crosschain)
        uint64 secondaryDeadline;      // Secondary intent deadline (for refund timing)
        bool released;                 // Whether escrow has been released
    }

    /**
     * @notice Escrow storage for conditional reward release
     * @dev Maps original intent hash to escrow data. Existence of escrow also marks intent as flash-fulfilled.
     */
    mapping(bytes32 => EscrowData) internal _escrowedRewards;

    /**
     * @notice Gets escrow data for a given intent hash
     * @dev Public getter for escrow data (needed because struct has dynamic array)
     * @param intentHash Hash of the intent
     * @return Escrow data struct
     */
    function getEscrow(bytes32 intentHash) external view returns (EscrowData memory) {
        return _escrowedRewards[intentHash];
    }

    /**
     * @notice Emitted when an intent is flash-fulfilled
     * @param intentHash Hash of the original intent
     * @param claimant Address eligible to claim rewards
     * @param secondaryIntentHash Hash of the dependent secondary intent
     */
    event FlashFulfilled(
        bytes32 indexed intentHash,
        bytes32 indexed claimant,
        bytes32 indexed secondaryIntentHash
    );

    /**
     * @notice Emitted when escrow is released to claimant
     * @param intentHash Hash of the original intent
     * @param claimant Address receiving the escrow
     * @param nativeAmount Amount of native tokens released
     */
    event EscrowReleased(
        bytes32 indexed intentHash,
        address indexed claimant,
        uint256 nativeAmount
    );

    /**
     * @notice Emitted when escrow is refunded to original vault
     * @param intentHash Hash of the original intent
     * @param originalVault Address of the original vault receiving refund
     * @param nativeAmount Amount of native tokens refunded
     */
    event EscrowRefunded(
        bytes32 indexed intentHash,
        address indexed originalVault,
        uint256 nativeAmount
    );

    constructor(address portal) {
        _PORTAL = IIntentSource(portal);

        if (block.chainid > type(uint64).max) {
            revert ChainIdTooLarge(block.chainid);
        }

        _CHAIN_ID = uint64(block.chainid);
    }

    /**
     * @notice Fetches a ProofData from the provenIntents mapping
     * @dev For flash-fulfilled intents (with escrow), returns LocalProver as claimant.
     *      For normal intents, reads from Portal's claimants mapping.
     * @param intentHash the hash of the intent whose proof data is being queried
     * @return ProofData struct containing the destination chain ID and claimant address
     */
    function provenIntents(
        bytes32 intentHash
    ) public view returns (ProofData memory) {
        // Check if this is a flash-fulfilled intent (escrow exists)
        // If so, return LocalProver as claimant for withdrawal purposes
        if (_escrowedRewards[intentHash].claimant != address(0)) {
            return ProofData(address(this), _CHAIN_ID);
        }

        // Normal intent - read from Portal's claimants
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
     * @notice Atomically fulfills an intent and escrows rewards pending secondary intent completion
     * @dev Withdraws funds from vault, executes fulfill, stores excess in escrow.
     *      Uses checks-effects-interactions pattern for security.
     *      NOTE: Portal will have creator as claimant (for double-fulfill prevention),
     *            but actual solver is tracked in escrowData.
     * @param intentHash Hash of the intent to flash-fulfill
     * @param intent Complete intent struct
     * @param claimant Address of the solver eligible for rewards (stored in escrow)
     * @param secondaryIntentHash Hash of the dependent secondary intent
     * @param secondaryProver Prover address for the secondary intent
     * @param secondaryDeadline Deadline of the secondary intent (for refund timing)
     * @return results Results from the fulfill execution
     */
    function flashFulfill(
        bytes32 intentHash,
        Intent calldata intent,
        bytes32 claimant,
        bytes32 secondaryIntentHash,
        address secondaryProver,
        uint64 secondaryDeadline
    ) external payable returns (bytes[] memory results) {
        // CHECKS
        require(secondaryIntentHash != bytes32(0), "Invalid secondary intent hash");
        require(secondaryProver != address(0), "Invalid secondary prover");
        require(_escrowedRewards[intentHash].claimant == address(0), "Already flash-fulfilled");

        // EFFECTS - Create escrow first (marks as flash-fulfilled for withdrawal)
        _escrowedRewards[intentHash] = EscrowData({
            claimant: address(uint160(uint256(claimant))),
            nativeAmount: 0,  // Updated after fulfill
            tokens: new TokenAmount[](0),  // Updated after fulfill
            secondaryIntentHash: secondaryIntentHash,
            secondaryProver: secondaryProver,
            secondaryDeadline: secondaryDeadline,
            released: false
        });

        // INTERACTIONS - Withdraw to LocalProver
        // provenIntents() now sees escrow exists, returns address(this)
        _PORTAL.withdraw(
            intent.destination,
            keccak256(abi.encode(intent.route)),
            intent.reward
        );

        // Approve tokens for fulfill execution
        uint256 tokensLength = intent.reward.tokens.length;
        for (uint256 i = 0; i < tokensLength; ++i) {
            IERC20(intent.reward.tokens[i].token).safeIncreaseAllowance(
                address(_PORTAL),
                intent.reward.tokens[i].amount
            );
        }

        // Call fulfill with creator as claimant (prevents double-fulfill in Portal)
        results = Inbox(address(_PORTAL)).fulfill{value: intent.reward.nativeAmount}(
            intentHash,
            intent.route,
            keccak256(abi.encode(intent.reward)),
            bytes32(uint256(uint160(intent.reward.creator)))
        );

        // EFFECTS - Update escrow with actual remaining amounts
        EscrowData storage escrow = _escrowedRewards[intentHash];
        escrow.nativeAmount = address(this).balance;
        escrow.tokens = _getRemainingTokenBalances(intent.reward.tokens);

        emit FlashFulfilled(intentHash, claimant, secondaryIntentHash);

        return results;
    }

    /**
     * @notice Releases escrowed funds to solver when secondary intent is proven
     * @dev Permissionless - anyone can trigger if conditions are met.
     *      Uses checks-effects-interactions pattern to prevent reentrancy.
     * @param intentHash Hash of the original intent
     */
    function releaseEscrow(bytes32 intentHash) external {
        EscrowData storage escrow = _escrowedRewards[intentHash];

        // CHECKS
        require(escrow.claimant != address(0), "No escrow found");
        require(!escrow.released, "Already released");

        // Verify secondary intent is proven (check crosschain prover)
        ProofData memory secondaryProof = IProver(escrow.secondaryProver).provenIntents(
            escrow.secondaryIntentHash
        );
        require(secondaryProof.claimant != address(0), "Secondary intent not proven");

        // EFFECTS - Mark as released BEFORE transfers
        escrow.released = true;
        address claimant = escrow.claimant;
        uint256 nativeAmount = escrow.nativeAmount;

        // INTERACTIONS - Transfer to claimant
        _transferEscrow(escrow, claimant);

        emit EscrowReleased(intentHash, claimant, nativeAmount);
    }

    /**
     * @notice Refunds escrowed funds to original vault when secondary intent expires unproven
     * @dev Permissionless - anyone can trigger if conditions are met.
     *      Uses checks-effects-interactions pattern to prevent reentrancy.
     *      Refunds secondary vault first, adds to escrow, then transfers all to original vault.
     * @param originalIntentHash Hash of the original intent
     * @param originalIntent Complete original intent struct
     * @param secondaryIntent Complete secondary intent struct
     */
    function refundEscrow(
        bytes32 originalIntentHash,
        Intent calldata originalIntent,
        Intent calldata secondaryIntent
    ) external {
        EscrowData storage escrow = _escrowedRewards[originalIntentHash];

        // CHECKS
        require(escrow.claimant != address(0), "No escrow found");
        require(!escrow.released, "Already released");
        require(block.timestamp > escrow.secondaryDeadline, "Secondary intent not expired");

        // Verify secondary intent is NOT proven (check crosschain prover)
        ProofData memory secondaryProof = IProver(escrow.secondaryProver).provenIntents(
            escrow.secondaryIntentHash
        );
        require(secondaryProof.claimant == address(0), "Secondary intent already proven");

        // EFFECTS - Mark as released BEFORE external calls
        escrow.released = true;

        // INTERACTIONS - Refund secondary vault to LocalProver if not already refunded
        bytes32 secondaryIntentHash = escrow.secondaryIntentHash;
        (bytes32 computedHash, bytes32 routeHash, ) = _PORTAL.getIntentHash(secondaryIntent);
        require(computedHash == secondaryIntentHash, "Secondary intent hash mismatch");

        // Check if secondary vault still has funds (i.e., not yet refunded)
        address secondaryVault = _PORTAL.intentVaultAddress(secondaryIntent);
        uint256 tokensLength = secondaryIntent.reward.tokens.length;
        bool vaultHasFunds = secondaryVault.balance > 0;

        if (!vaultHasFunds && tokensLength > 0) {
            // Check token balances
            for (uint256 i = 0; i < tokensLength; ++i) {
                if (IERC20(secondaryIntent.reward.tokens[i].token).balanceOf(secondaryVault) > 0) {
                    vaultHasFunds = true;
                    break;
                }
            }
        }

        // Only refund if vault still has funds
        if (vaultHasFunds) {
            _PORTAL.refund(
                secondaryIntent.destination,
                routeHash,
                secondaryIntent.reward
            );

            // EFFECTS - Add refunded amounts to escrow
            escrow.nativeAmount += secondaryIntent.reward.nativeAmount;
            for (uint256 i = 0; i < tokensLength; ++i) {
                _addToEscrowTokens(escrow, secondaryIntent.reward.tokens[i]);
            }
        }
        // If already refunded, just skip and transfer existing escrow

        // Compute original vault address and transfer everything
        address originalVault = _PORTAL.intentVaultAddress(originalIntent);
        uint256 totalNative = escrow.nativeAmount;

        // INTERACTIONS - Transfer all funds to original vault
        _transferEscrow(escrow, originalVault);

        emit EscrowRefunded(originalIntentHash, originalVault, totalNative);
    }

    /**
     * @notice Transfers escrowed tokens and native funds to recipient
     * @dev Internal helper for releasing/refunding escrow
     * @param escrow Storage reference to escrow data
     * @param recipient Address to receive the funds
     */
    function _transferEscrow(
        EscrowData storage escrow,
        address recipient
    ) internal {
        // Transfer ERC20 tokens
        uint256 tokensLength = escrow.tokens.length;
        for (uint256 i = 0; i < tokensLength; ++i) {
            uint256 amount = escrow.tokens[i].amount;
            if (amount > 0) {
                IERC20(escrow.tokens[i].token).safeTransfer(recipient, amount);
            }
        }

        // Transfer native tokens
        uint256 nativeAmount = escrow.nativeAmount;
        if (nativeAmount > 0) {
            (bool success, ) = recipient.call{value: nativeAmount}("");
            require(success, "Native transfer failed");
        }
    }

    /**
     * @notice Adds a token amount to escrow, merging with existing entry if present
     * @dev Internal helper for refundEscrow when adding refunded tokens
     * @param escrow Storage reference to escrow data
     * @param newToken Token amount to add
     */
    function _addToEscrowTokens(
        EscrowData storage escrow,
        TokenAmount memory newToken
    ) internal {
        // Check if token already exists in escrow
        uint256 tokensLength = escrow.tokens.length;
        for (uint256 i = 0; i < tokensLength; ++i) {
            if (escrow.tokens[i].token == newToken.token) {
                escrow.tokens[i].amount += newToken.amount;
                return;
            }
        }
        // Token not found, add new entry
        escrow.tokens.push(newToken);
    }

    /**
     * @notice Gets current token balances remaining in LocalProver
     * @dev Internal helper for flashFulfill to capture excess after fulfill
     * @param rewardTokens Array of tokens from the reward
     * @return remaining Array of current token balances
     */
    function _getRemainingTokenBalances(
        TokenAmount[] memory rewardTokens
    ) internal view returns (TokenAmount[] memory remaining) {
        uint256 length = rewardTokens.length;
        remaining = new TokenAmount[](length);

        for (uint256 i = 0; i < length; ++i) {
            remaining[i] = TokenAmount({
                token: rewardTokens[i].token,
                amount: IERC20(rewardTokens[i].token).balanceOf(address(this))
            });
        }

        return remaining;
    }

    // Allow contract to receive native tokens
    receive() external payable {}
}
