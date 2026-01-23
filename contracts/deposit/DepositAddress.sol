// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Portal} from "../Portal.sol";
import {Reward, TokenAmount} from "../types/Intent.sol";
import {DepositFactory} from "./DepositFactory.sol";

/**
 * @title DepositAddress
 * @notice Minimal proxy contract that encodes routes and creates cross-chain intents
 * @dev Each DepositAddress is specific to one user's destination address
 *      Deployed via CREATE2 by DepositFactory for deterministic addressing
 */
contract DepositAddress is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Storage ============

    /// @notice User's destination address on target chain (where tokens are sent)
    bytes32 public destinationAddress;

    /// @notice Depositor address on source chain (where refunds are sent if intent fails)
    address public depositor;

    /// @notice Initialization flag
    bool private initialized;

    // ============ Immutables ============

    /// @notice Reference to the factory that deployed this contract
    DepositFactory private immutable FACTORY;

    // ============ Events ============

    /**
     * @notice Emitted when an intent is created
     * @param intentHash Hash of the created intent
     * @param amount Amount of tokens in the intent
     * @param caller Address that triggered the intent creation
     */
    event IntentCreated(
        bytes32 indexed intentHash,
        uint256 amount,
        address indexed caller
    );

    /**
     * @notice Emitted when an intent is refunded
     * @param routeHash Hash of the route that was refunded
     * @param refundee Address that received the refund
     */
    event IntentRefunded(bytes32 indexed routeHash, address indexed refundee);

    // ============ Errors ============

    error AlreadyInitialized();
    error NotInitialized();
    error OnlyFactory();
    error InvalidDepositor();
    error ZeroAmount();
    error InsufficientBalance(uint256 requested, uint256 available);
    error NoDepositorSet();

    // ============ Constructor ============

    /**
     * @notice Sets the factory reference (called by factory during deployment)
     */
    constructor() {
        FACTORY = DepositFactory(msg.sender);
    }

    // ============ External Functions ============

    /**
     * @notice Initialize the deposit address (called once by factory after deployment)
     * @param _destinationAddress User's destination address (bytes32 for cross-VM compatibility)
     * @param _depositor Address to receive refunds if intent fails
     */
    function initialize(
        bytes32 _destinationAddress,
        address _depositor
    ) external {
        if (initialized) revert AlreadyInitialized();
        if (msg.sender != address(FACTORY)) revert OnlyFactory();
        if (_depositor == address(0)) revert InvalidDepositor();

        destinationAddress = _destinationAddress;
        depositor = _depositor;
        initialized = true;
    }

    /**
     * @notice Create a cross-chain intent for deposited tokens
     * @dev Encodes route bytes for Solana, constructs reward, and calls Portal.publishAndFund()
     * @param amount Amount of tokens to bridge
     * @return intentHash Hash of the created intent
     */
    function createIntent(
        uint256 amount
    ) external nonReentrant returns (bytes32 intentHash) {
        if (!initialized) revert NotInitialized();
        if (amount == 0) revert ZeroAmount();

        // Get configuration from factory
        (
            uint64 destChain,
            address sourceToken,
            bytes32 targetToken,
            address portal,
            address prover,
            bytes32 destPortal,
            uint64 deadlineDuration
        ) = FACTORY.getConfiguration();

        // Check balance
        uint256 balance = IERC20(sourceToken).balanceOf(address(this));
        if (balance < amount) {
            revert InsufficientBalance(amount, balance);
        }

        // Encode route bytes for Solana (Borsh format)
        bytes memory routeBytes = _encodeRoute(
            amount,
            targetToken,
            destPortal,
            deadlineDuration
        );

        // Construct Reward
        Reward memory reward = Reward({
            deadline: uint64(block.timestamp + deadlineDuration),
            creator: address(this), // Deposit address is creator
            prover: prover,
            nativeAmount: 0,
            tokens: new TokenAmount[](1)
        });
        reward.tokens[0] = TokenAmount({token: sourceToken, amount: amount});

        // Approve Portal to spend tokens
        IERC20(sourceToken).approve(portal, amount);

        // Call Portal.publishAndFund
        Portal portalContract = Portal(portal);
        address vault;
        (intentHash, vault) = portalContract.publishAndFund(
            destChain,
            routeBytes,
            reward,
            false // allowPartial = false
        );

        emit IntentCreated(intentHash, amount, msg.sender);

        return intentHash;
    }

    /**
     * @notice Permissionless refund function for failed intents
     * @dev Anyone can call this to refund tokens to the depositor if intent wasn't fulfilled
     * @param routeHash Hash of the route (from createIntent)
     * @param reward Reward struct (from createIntent)
     */
    function refund(
        bytes32 routeHash,
        Reward calldata reward
    ) external nonReentrant {
        if (!initialized) revert NotInitialized();
        if (depositor == address(0)) revert NoDepositorSet();

        // Get configuration from factory
        (uint64 destChain, , , address portal, , , ) = FACTORY
            .getConfiguration();

        // Call Portal.refundTo (Portal checks that msg.sender == reward.creator)
        Portal(portal).refundTo(destChain, routeHash, reward, depositor);

        emit IntentRefunded(routeHash, depositor);
    }

    // ============ Internal Functions ============

    /**
     * @notice Encode route bytes for Solana using Borsh format
     * @dev Matches Solana's Route struct:
     *      - salt: Bytes32 (32 bytes)
     *      - deadline: u64 (8 bytes)
     *      - portal: Bytes32 (32 bytes)
     *      - native_amount: u64 (8 bytes)
     *      - tokens: Vec<TokenAmount> (4 bytes length + elements)
     *      - calls: Vec<Call> (4 bytes length + elements)
     * @param amount Amount of tokens to transfer
     * @param targetToken Token address on destination chain
     * @param destPortal Portal address on destination chain
     * @param deadlineDuration Deadline duration in seconds
     * @return routeBytes Encoded route bytes
     */
    function _encodeRoute(
        uint256 amount,
        bytes32 targetToken,
        bytes32 destPortal,
        uint64 deadlineDuration
    ) internal view returns (bytes memory) {
        // Generate unique salt
        bytes32 salt = keccak256(
            abi.encodePacked(address(this), destinationAddress, block.timestamp)
        );

        // Calculate deadline
        uint64 deadline = uint64(block.timestamp + deadlineDuration);

        // Encode route matching Solana's Borsh format
        // Note: Solana uses little-endian for multi-byte integers
        // TODO: Verify with Solana team if byte order conversion is needed
        bytes memory routeBytes = abi.encodePacked(
            salt, // 32 bytes
            deadline, // 8 bytes (may need little-endian conversion)
            destPortal, // 32 bytes
            uint64(0), // native_amount = 0 (8 bytes)
            uint32(1), // tokens.length = 1 (4 bytes)
            targetToken, // tokens[0].token (32 bytes)
            uint64(amount), // tokens[0].amount (8 bytes, may need little-endian conversion)
            uint32(0) // calls.length = 0 (4 bytes)
        );

        return routeBytes;
    }
}
