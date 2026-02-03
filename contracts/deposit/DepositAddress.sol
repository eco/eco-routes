// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Portal} from "../Portal.sol";
import {Reward, TokenAmount} from "../types/Intent.sol";
import {DepositFactory} from "./DepositFactory.sol";
import {Endian} from "../libs/Endian.sol";

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

    // ============ Errors ============

    error AlreadyInitialized();
    error NotInitialized();
    error OnlyFactory();
    error InvalidDepositor();
    error ZeroAmount();
    error InsufficientBalance(uint256 requested, uint256 available);

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
            bytes32 destinationToken,
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
            destinationToken,
            destPortal,
            deadlineDuration
        );

        // Construct Reward
        Reward memory reward = Reward({
            deadline: uint64(block.timestamp + deadlineDuration),
            creator: depositor, // Depositor receives refunds through normal intent flow
            prover: prover,
            nativeAmount: 0,
            tokens: new TokenAmount[](1)
        });
        reward.tokens[0] = TokenAmount({token: sourceToken, amount: amount});

        // Approve Portal to spend tokens
        IERC20(sourceToken).approve(portal, amount);

        // Call Portal.publishAndFund
        Portal portalContract = Portal(portal);
        (intentHash,) = portalContract.publishAndFund(
            destChain,
            routeBytes,
            reward,
            false // allowPartial = false
        );

        emit IntentCreated(intentHash, amount, msg.sender);

        return intentHash;
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
     *        - Each TokenAmount: token (32 bytes) + amount (8 bytes u64)
     *      - calls: Vec<Call> (4 bytes length + elements)
     *        - Each Call: target (32 bytes) + data length (4 bytes u32) + data (variable) + value (8 bytes u64)
     * @param amount Amount of tokens to transfer
     * @param destinationToken Token address on destination chain
     * @param destPortal Portal address on destination chain
     * @param deadlineDuration Deadline duration in seconds
     * @return routeBytes Encoded route bytes
     */
    function _encodeRoute(
        uint256 amount,
        bytes32 destinationToken,
        bytes32 destPortal,
        uint64 deadlineDuration
    ) internal view returns (bytes memory) {
        // Generate unique salt
        bytes32 salt = keccak256(
            abi.encodePacked(address(this), destinationAddress, block.timestamp)
        );

        // Calculate deadline
        uint64 deadline = uint64(block.timestamp + deadlineDuration);

        // Encode transfer instruction data (destination + amount)
        bytes memory transferData = abi.encodePacked(
            destinationAddress, // 32 bytes - recipient address
            Endian.toLittleEndian64(uint64(amount)) // 8 bytes - transfer amount (little-endian)
        );

        // Encode route matching Solana's Borsh format
        // Note: Solana uses little-endian for multi-byte integers
        bytes memory routeBytes = abi.encodePacked(
            salt, // 32 bytes
            Endian.toLittleEndian64(deadline), // 8 bytes (little-endian)
            destPortal, // 32 bytes
            Endian.toLittleEndian64(0), // native_amount = 0 (8 bytes, little-endian)
            Endian.toLittleEndian32(1), // tokens.length = 1 (4 bytes, little-endian)
            destinationToken, // tokens[0].token (32 bytes)
            Endian.toLittleEndian64(uint64(amount)), // tokens[0].amount (8 bytes, little-endian)
            Endian.toLittleEndian32(1), // calls.length = 1 (4 bytes, little-endian)
            // Call struct (Borsh encoding): target, data, value
            destinationToken, // calls[0].target (32 bytes) - token to transfer
            Endian.toLittleEndian32(uint32(transferData.length)), // calls[0].data.length (4 bytes, little-endian)
            transferData, // calls[0].data (40 bytes: 32-byte address + 8-byte amount)
            Endian.toLittleEndian64(0) // calls[0].value (8 bytes, little-endian) - no native tokens
        );

        return routeBytes;
    }
}
