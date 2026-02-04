// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Portal} from "../Portal.sol";
import {Intent, Route, Reward, TokenAmount, Call} from "../types/Intent.sol";
import {DepositFactory_CCTPMint_Arc} from "./DepositFactory_CCTPMint_Arc.sol";

/**
 * @title DepositAddress_CCTPMint_Arc
 * @notice Minimal proxy contract that constructs Intent structs for CCTP minting on Arc
 * @dev Each DepositAddress is specific to one user's destination address
 *      Deployed via CREATE2 by DepositFactory_CCTPMint_Arc for deterministic addressing
 *      Uses standard Intent/Route/Reward structs instead of Borsh-encoded bytes
 */
contract DepositAddress_CCTPMint_Arc is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Storage ============

    /// @notice User's destination address on target chain (used for CREATE2 salt and token recipient)
    address public destinationAddress;

    /// @notice Depositor address on source chain (where refunds are sent if intent fails)
    address public depositor;

    /// @notice Initialization flag
    bool private initialized;

    // ============ Immutables ============

    /// @notice Reference to the factory that deployed this contract
    DepositFactory_CCTPMint_Arc private immutable FACTORY;

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
        FACTORY = DepositFactory_CCTPMint_Arc(msg.sender);
    }

    // ============ External Functions ============

    /**
     * @notice Initialize the deposit address (called once by factory after deployment)
     * @param _destinationAddress User's destination address (used for salt and token recipient)
     * @param _depositor Address to receive refunds if intent fails
     */
    function initialize(
        address _destinationAddress,
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
     * @dev Constructs Intent struct with Route and Reward, calls Portal.publishAndFund()
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
            address destinationToken,
            address portal,
            address prover,
            address destPortal,
            uint64 deadlineDuration,
            uint32 destinationDomain
        ) = FACTORY.getConfiguration();

        // Check balance
        uint256 balance = IERC20(sourceToken).balanceOf(address(this));
        if (balance < amount) {
            revert InsufficientBalance(amount, balance);
        }

        // Construct Intent struct
        Intent memory intent = _constructIntent(
            destChain,
            sourceToken,
            destinationToken,
            destPortal,
            prover,
            amount,
            deadlineDuration,
            destinationDomain
        );

        // Approve Portal to spend tokens
        IERC20(sourceToken).approve(portal, amount);

        // Call Portal.publishAndFund with Intent struct
        Portal portalContract = Portal(portal);
        address vault;
        (intentHash, vault) = portalContract.publishAndFund(
            intent,
            false // allowPartial = false
        );

        emit IntentCreated(intentHash, amount, msg.sender);

        return intentHash;
    }

    // ============ Internal Functions ============

    /**
     * @notice Construct complete Intent struct for EVM destination
     * @param destChain Destination chain ID
     * @param sourceToken Source token address
     * @param destinationToken Destination token address on destination chain
     * @param destPortal Portal address on destination chain
     * @param prover Prover contract address
     * @param amount Amount of tokens to transfer
     * @param deadlineDuration Deadline duration in seconds
     * @return intent Complete Intent struct ready for publishing
     */
    function _constructIntent(
        uint64 destChain,
        address sourceToken,
        address destinationToken,
        address destPortal,
        address prover,
        uint256 amount,
        uint64 deadlineDuration,
        uint32 destinationDomain
    ) internal view returns (Intent memory intent) {
        // Construct Route
        Route memory route = _constructRoute(
            destinationToken,
            destPortal,
            amount,
            deadlineDuration,
            destinationDomain,
            sourceToken
        );

        // Construct Reward
        Reward memory reward = _constructReward(
            sourceToken,
            prover,
            amount,
            deadlineDuration
        );

        // Combine into Intent
        intent = Intent({destination: destChain, route: route, reward: reward});
    }

    /**
     * @notice Construct Route struct with CCTP depositForBurn call
     * @param destinationToken Token address on destination chain
     * @param destPortal Portal address on destination chain
     * @param amount Amount of tokens to burn and mint
     * @param deadlineDuration Deadline duration in seconds
     * @param destinationDomain CCTP destination domain ID
     * @param sourceToken Source token to burn
     * @return route Route struct with CCTP depositForBurn call
     */
    function _constructRoute(
        address destinationToken,
        address destPortal,
        uint256 amount,
        uint64 deadlineDuration,
        uint32 destinationDomain,
        address sourceToken
    ) internal view returns (Route memory route) {
        // Generate unique salt
        bytes32 salt = keccak256(
            abi.encodePacked(address(this), destinationAddress, block.timestamp)
        );

        // Calculate deadline
        uint64 deadline = uint64(block.timestamp + deadlineDuration);

        // Construct token array (for destination chain)
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: destinationToken, amount: amount});

        // Convert destinationAddress to bytes32 for CCTP mintRecipient
        bytes32 mintRecipient = bytes32(uint256(uint160(destinationAddress)));

        // CCTP TokenMessengerV2 address
        address cctpTokenMessenger = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;

        // Construct CCTP depositForBurn call
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: cctpTokenMessenger,
            data: abi.encodeWithSignature(
                "depositForBurn(uint256,uint32,bytes32,address)",
                amount,
                destinationDomain,
                mintRecipient,
                sourceToken
            ),
            value: 0
        });

        // Construct route
        route = Route({
            salt: salt,
            deadline: deadline,
            portal: destPortal,
            nativeAmount: 0,
            tokens: tokens,
            calls: calls
        });
    }

    /**
     * @notice Construct Reward struct for the intent
     * @param sourceToken Source token address
     * @param prover Prover contract address
     * @param amount Amount of tokens as reward
     * @param deadlineDuration Deadline duration in seconds
     * @return reward Reward struct with escrowed source tokens
     */
    function _constructReward(
        address sourceToken,
        address prover,
        uint256 amount,
        uint64 deadlineDuration
    ) internal view returns (Reward memory reward) {
        // Calculate deadline
        uint64 deadline = uint64(block.timestamp + deadlineDuration);

        // Construct reward token array
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: sourceToken, amount: amount});

        // Construct reward
        reward = Reward({
            deadline: deadline,
            creator: depositor, // Depositor is creator (matches Solana implementation)
            prover: prover,
            nativeAmount: 0,
            tokens: tokens
        });
    }
}
