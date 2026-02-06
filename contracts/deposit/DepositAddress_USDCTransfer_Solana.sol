// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Portal} from "../Portal.sol";
import {Reward, TokenAmount} from "../types/Intent.sol";
import {DepositFactory_USDCTransfer_Solana} from "./DepositFactory_USDCTransfer_Solana.sol";
import {Endian} from "../libs/Endian.sol";

/**
 * @title DepositAddress_USDCTransfer_Solana
 * @notice Minimal proxy contract that encodes routes and creates cross-chain intents for USDC transfers to Solana
 * @dev Each DepositAddress is specific to one user's destination address
 *      Deployed via CREATE2 by DepositFactory_USDCTransfer_Solana for deterministic addressing
 */
contract DepositAddress_USDCTransfer_Solana is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Solana SPL Token Program ID (hex encoding of TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA)
    bytes32 public constant SPL_TOKEN_PROGRAM_ID = 0x06ddf6e1d765a193d9cbe146ceeb79ac1cb485ed5f5b37913a8cf5857eff00a9;

    /// @notice Solana Associated Token Account Program ID (hex encoding of ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL)
    bytes32 public constant ATA_PROGRAM_ID = 0x8c97258f4e2489f1bb3d1029148e0d830b5a1399daff1084048e7bd8dbe9f859;

    /// @notice Token decimals for USDC and similar tokens on Solana
    uint8 public constant TOKEN_DECIMALS = 6;

    // ============ Storage ============

    /// @notice Recipient's Associated Token Account (ATA) on Solana where tokens will be sent
    /// @dev For Solana, this is computed off-chain as: deriveAddress([ownerPubkey, TOKEN_PROGRAM_ID, mintPubkey], ATA_PROGRAM_ID)
    bytes32 public destinationAddress;

    /// @notice Depositor address on source chain (where refunds are sent if intent fails)
    address public depositor;

    /// @notice Initialization flag
    bool private initialized;

    // ============ Immutables ============

    /// @notice Reference to the factory that deployed this contract
    DepositFactory_USDCTransfer_Solana private immutable FACTORY;

    // ============ Errors ============

    error AlreadyInitialized();
    error NotInitialized();
    error OnlyFactory();
    error InvalidDepositor();
    error InvalidDestinationAddress();
    error ZeroAmount();
    error AmountTooLarge(uint256 amount, uint256 maxAmount);

    // ============ Constructor ============

    /**
     * @notice Sets the factory reference (called by factory during deployment)
     */
    constructor() {
        FACTORY = DepositFactory_USDCTransfer_Solana(msg.sender);
    }

    // ============ External Functions ============

    /**
     * @notice Initialize the deposit address (called once by factory after deployment)
     * @param _destinationAddress Recipient's Associated Token Account (ATA) on Solana where tokens will be sent
     * @param _depositor Address to receive refunds if intent fails
     */
    function initialize(
        bytes32 _destinationAddress,
        address _depositor
    ) external {
        if (initialized) revert AlreadyInitialized();
        if (msg.sender != address(FACTORY)) revert OnlyFactory();
        if (_destinationAddress == bytes32(0)) revert InvalidDestinationAddress();
        if (_depositor == address(0)) revert InvalidDepositor();

        destinationAddress = _destinationAddress;
        depositor = _depositor;
        initialized = true;
    }

    /**
     * @notice Create a cross-chain intent for deposited tokens
     * @dev Encodes route bytes for Solana, constructs reward, and calls Portal.publishAndFund()
     *      Amount must fit in uint64 due to Solana's u64 token amount limitation.
     *      This works for 6-decimal tokens (USDC, USDT) but restricts 18-decimal tokens.
     * @param amount Amount of tokens to bridge (must be <= type(uint64).max)
     * @return intentHash Hash of the created intent
     */
    function createIntent(
        uint256 amount
    ) external nonReentrant returns (bytes32 intentHash) {
        if (!initialized) revert NotInitialized();
        if (amount == 0) revert ZeroAmount();
        if (amount > type(uint64).max) {
            revert AmountTooLarge(amount, type(uint64).max);
        }

        // Get configuration from factory
        (
            uint64 destChain,
            address sourceToken,
            bytes32 destinationToken,
            address portal,
            address prover,
            bytes32 destPortal,
            bytes32 portalPDA,
            uint64 deadlineDuration,
            bytes32 executorATA
        ) = FACTORY.getConfiguration();

        // Encode route bytes for Solana (Borsh format)
        bytes memory routeBytes = _encodeRoute(
            amount,
            destinationToken,
            destPortal,
            portalPDA,
            deadlineDuration,
            executorATA
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
     *        - Each Call: target (32 bytes) + data (CalldataWithAccounts)
     * @param amount Amount of tokens to transfer
     * @param destinationToken Token mint address on destination chain
     * @param destPortal Portal program ID on destination chain
     * @param portalPDA Portal's PDA vault authority (owns Executor ATA)
     * @param deadlineDuration Deadline duration in seconds
     * @param executorATA Executor's Associated Token Account (source)
     * @return routeBytes Encoded route bytes
     */
    function _encodeRoute(
        uint256 amount,
        bytes32 destinationToken,
        bytes32 destPortal,
        bytes32 portalPDA,
        uint64 deadlineDuration,
        bytes32 executorATA
    ) internal view returns (bytes memory) {
        // Generate unique salt
        bytes32 salt = keccak256(
            abi.encodePacked(address(this), destinationAddress, block.timestamp)
        );

        // Calculate deadline
        uint64 deadline = uint64(block.timestamp + deadlineDuration);

        // Build SPL Token transfer_checked instruction data
        // Discriminator (0x0c) + Amount (u64 LE) + Decimals (u8)
        bytes memory instructionData = abi.encodePacked(
            bytes1(0x0c), // transfer_checked discriminator
            // USDC has 6 decimals on both EVM and SVM chains, so amounts fit in uint64
            Endian.toLittleEndian64(uint64(amount)), // amount (little-endian)
            TOKEN_DECIMALS // decimals = 6
        );

        // Build CalldataWithAccounts structure
        // 1. Calldata.data (Vec<u8>)
        // 2. account_count (u8)
        // 3. accounts (Vec<SerializableAccountMeta>)
        bytes memory calldataWithAccounts = abi.encodePacked(
            // Calldata.data (Vec<u8>)
            Endian.toLittleEndian32(uint32(instructionData.length)), // data length = 10
            instructionData, // 10 bytes: 0x0c + 8-byte amount + 1-byte decimals

            // account_count (u8)
            bytes1(0x04), // 4 accounts

            // accounts (Vec<SerializableAccountMeta>)
            Endian.toLittleEndian32(4), // accounts.length = 4

            // accounts[0]: Executor ATA (source token account) - writable, not signer
            executorATA, // 32 bytes
            bytes1(0x00), // is_signer = false
            bytes1(0x01), // is_writable = true

            // accounts[1]: Token mint - read-only, not signer
            destinationToken, // 32 bytes
            bytes1(0x00), // is_signer = false
            bytes1(0x00), // is_writable = false

            // accounts[2]: Recipient ATA (destination token account) - writable, not signer
            destinationAddress, // 32 bytes - Recipient's ATA on Solana
            bytes1(0x00), // is_signer = false
            bytes1(0x01), // is_writable = true

            // accounts[3]: Executor authority (Portal PDA) - read-only, not signer
            portalPDA, // 32 bytes (Portal's PDA vault authority)
            bytes1(0x00), // is_signer = false
            bytes1(0x00) // is_writable = false
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
            // Call struct (Borsh encoding): target, data
            SPL_TOKEN_PROGRAM_ID, // calls[0].target (32 bytes) - SPL Token Program
            Endian.toLittleEndian32(uint32(calldataWithAccounts.length)), // calls[0].data.length (4 bytes, little-endian)
            calldataWithAccounts // calls[0].data (CalldataWithAccounts structure)
        );

        return routeBytes;
    }
}
