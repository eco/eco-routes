// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Portal} from "../Portal.sol";
import {Intent, Route, Reward, TokenAmount, Call} from "../types/Intent.sol";
import {EVMDepositFactory} from "./EVMDepositFactory.sol";

/**
 * @title EVMDepositAddress
 * @notice Minimal proxy contract that constructs Intent structs for EVM destinations
 * @dev Each EVMDepositAddress is specific to one user's destination address
 *      Deployed via CREATE2 by EVMDepositFactory for deterministic addressing
 *      Uses standard Intent/Route/Reward structs instead of Borsh-encoded bytes
 */
contract EVMDepositAddress is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Storage ============

    /// @notice User's destination address identifier (used for CREATE2 salt)
    address public destinationAddress;

    /// @notice Recipient address on destination chain (where tokens are actually sent)
    address public recipient;

    /// @notice Depositor address on source chain (where refunds are sent if intent fails)
    address public depositor;

    /// @notice Initialization flag
    bool private initialized;

    // ============ Immutables ============

    /// @notice Reference to the factory that deployed this contract
    EVMDepositFactory private immutable FACTORY;

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
    error InvalidRecipient();
    error ZeroAmount();
    error InsufficientBalance(uint256 requested, uint256 available);
    error NoDepositorSet();

    // ============ Constructor ============

    /**
     * @notice Sets the factory reference (called by factory during deployment)
     */
    constructor() {
        FACTORY = EVMDepositFactory(msg.sender);
    }

    // ============ External Functions ============

    /**
     * @notice Initialize the deposit address (called once by factory after deployment)
     * @param _destinationAddress User's destination address (identifier for salt)
     * @param _recipient Address that will receive tokens on destination chain
     * @param _depositor Address to receive refunds if intent fails
     */
    function initialize(
        address _destinationAddress,
        address _recipient,
        address _depositor
    ) external {
        if (initialized) revert AlreadyInitialized();
        if (msg.sender != address(FACTORY)) revert OnlyFactory();
        if (_depositor == address(0)) revert InvalidDepositor();
        if (_recipient == address(0)) revert InvalidRecipient();

        destinationAddress = _destinationAddress;
        recipient = _recipient;
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
            address targetToken,
            address portal,
            address prover,
            address destPortal,
            uint64 deadlineDuration
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
            targetToken,
            destPortal,
            prover,
            amount,
            deadlineDuration
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
     * @notice Construct complete Intent struct for EVM destination
     * @param destChain Destination chain ID
     * @param sourceToken Source token address
     * @param targetToken Target token address on destination
     * @param destPortal Portal address on destination chain
     * @param prover Prover contract address
     * @param amount Amount of tokens to transfer
     * @param deadlineDuration Deadline duration in seconds
     * @return intent Complete Intent struct ready for publishing
     */
    function _constructIntent(
        uint64 destChain,
        address sourceToken,
        address targetToken,
        address destPortal,
        address prover,
        uint256 amount,
        uint64 deadlineDuration
    ) internal view returns (Intent memory intent) {
        // Construct Route
        Route memory route = _constructRoute(
            targetToken,
            destPortal,
            amount,
            deadlineDuration
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
     * @notice Construct Route struct with USDC transfer call
     * @param targetToken Token address on destination chain
     * @param destPortal Portal address on destination chain
     * @param amount Amount of tokens to transfer
     * @param deadlineDuration Deadline duration in seconds
     * @return route Route struct with transfer call to recipient
     */
    function _constructRoute(
        address targetToken,
        address destPortal,
        uint256 amount,
        uint64 deadlineDuration
    ) internal view returns (Route memory route) {
        // Generate unique salt
        bytes32 salt = keccak256(
            abi.encodePacked(address(this), destinationAddress, block.timestamp)
        );

        // Calculate deadline
        uint64 deadline = uint64(block.timestamp + deadlineDuration);

        // Construct token array
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: targetToken, amount: amount});

        // Construct USDC transfer call to recipient
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: targetToken,
            data: abi.encodeWithSignature(
                "transfer(address,uint256)",
                recipient,
                amount
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
            creator: address(this), // Deposit address is creator
            prover: prover,
            nativeAmount: 0,
            tokens: tokens
        });
    }
}
