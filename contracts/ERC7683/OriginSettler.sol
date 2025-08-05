/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IOriginSettler} from "../interfaces/ERC7683/IOriginSettler.sol";
import {IIntentSource} from "../interfaces/IIntentSource.sol";

import {Intent, Route, Reward, TokenAmount, Call} from "../types/Intent.sol";
import {OnchainCrossChainOrder, ResolvedCrossChainOrder, GaslessCrossChainOrder, Output, FillInstruction, OrderData, ORDER_DATA_TYPEHASH} from "../types/ERC7683.sol";
import {AddressConverter} from "../libs/AddressConverter.sol";

/**
 * @title Eco7683OriginSettler
 * @notice Entry point to Eco Protocol via EIP-7683
 * @dev functionality is somewhat limited compared to interacting with Eco Protocol directly
 */
abstract contract OriginSettler is IOriginSettler, EIP712 {
    using ECDSA for bytes32;
    using SafeERC20 for IERC20;
    using AddressConverter for bytes32;

    /// @notice typehash for gasless crosschain order
    bytes32 public GASLESS_CROSSCHAIN_ORDER_TYPEHASH =
        keccak256(
            "GaslessCrossChainOrder(address originSettler,address user,uint256 nonce,uint256 originChainId,uint32 openDeadline,uint32 fillDeadline,bytes32 orderDataType,bytes32 orderDataHash)"
        );

    /**
     * @notice Initializes the Eco7683OriginSettler
     */
    constructor() EIP712("EcoPortal", "1") {}

    /**
     * @notice Opens an Eco intent directly on chain
     * @dev to be called by the user
     * @dev assumes user has erc20 funds approved for the intent, and includes any reward native token in msg.value
     * @dev transfers the reward tokens at time of open
     * @param order the OnchainCrossChainOrder that will be opened as an eco intent
     */
    function open(
        OnchainCrossChainOrder calldata order
    ) external payable override {
        if (order.orderDataType != ORDER_DATA_TYPEHASH) {
            revert TypeSignatureMismatch();
        }

        // Decode components individually to avoid Solidity's nested struct decoding issues
        OrderData memory orderData = abi.decode(order.orderData, (OrderData));

        bytes32 orderId = _openIntent(
            orderData.destination,
            orderData.route,
            orderData.reward,
            msg.sender
        );

        emit Open(orderId, _resolve(order.fillDeadline, orderData));
    }

    /**
     * @notice Opens an Eco intent on behalf of a user
     * @notice This method is made payable in the event that the caller of this method (a solver) wants to open
     * an intent that has native token as a reward. In this case, the solver would need to send the native
     * token as part of the transaction. How the intent's creator pays the solver is not covered by this method.
     * @dev to be called by the intent's solver
     * @dev assumes user has erc20 funds approved for the intent, and includes any reward native token in msg.value
     * @dev transfers the reward tokens at time of open
     * @param order the GaslessCrossChainOrder that will be opened as an eco intent
     * @param signature the signature of the user authorizing the intent to be opened
     * param originFillerData filler data for the origin chain (vestigial, not used)
     */
    function openFor(
        GaslessCrossChainOrder calldata order,
        bytes calldata signature,
        bytes calldata /* originFillerData */
    ) external payable override {
        if (block.timestamp > order.openDeadline) {
            revert OpenDeadlinePassed();
        }
        if (!_verifyOpenFor(order, signature)) {
            revert BadSignature();
        }

        if (order.orderDataType != ORDER_DATA_TYPEHASH) {
            revert TypeSignatureMismatch();
        }

        OrderData memory orderData = abi.decode(order.orderData, (OrderData));

        if (order.originChainId != block.chainid) {
            revert OriginChainIDMismatch();
        }

        bytes32 orderId = _openIntent(
            orderData.destination,
            orderData.route,
            orderData.reward,
            order.user
        );

        emit Open(orderId, _resolve(order.openDeadline, orderData));
    }

    /**
     * @notice resolves an OnchainCrossChainOrder to a ResolvedCrossChainOrder
     * @param order the OnchainCrossChainOrder to be resolved
     */
    function resolve(
        OnchainCrossChainOrder calldata order
    ) public view returns (ResolvedCrossChainOrder memory) {
        OrderData memory orderData = abi.decode(order.orderData, (OrderData));

        return _resolve(order.fillDeadline, orderData);
    }

    /**
     * @notice resolves GaslessCrossChainOrder to a ResolvedCrossChainOrder
     * @param order the GaslessCrossChainOrder to be resolved
     * param originFillerData filler data for the origin chain (not used)
     */
    function resolveFor(
        GaslessCrossChainOrder calldata order,
        bytes calldata // originFillerData keeping it for purpose of interface
    ) public view returns (ResolvedCrossChainOrder memory) {
        OrderData memory orderData = abi.decode(order.orderData, (OrderData));

        return _resolve(order.openDeadline, orderData);
    }

    /**
     * @notice Helper method for signature verification
     * @dev Verifies that the gasless order was properly signed by the user
     * @param order The gasless cross-chain order to verify
     * @param signature The user's signature
     * @return True if the signature is valid, false otherwise
     */
    function _verifyOpenFor(
        GaslessCrossChainOrder calldata order,
        bytes calldata signature
    ) internal view returns (bool) {
        if (order.originSettler != address(this)) {
            return false;
        }

        bytes32 structHash = keccak256(
            abi.encode(
                GASLESS_CROSSCHAIN_ORDER_TYPEHASH,
                order.originSettler,
                order.user,
                order.nonce,
                order.originChainId,
                order.openDeadline,
                order.fillDeadline,
                order.orderDataType,
                keccak256(order.orderData)
            )
        );
        bytes32 hash = _hashTypedDataV4(structHash);
        address signer = hash.recover(signature);

        return signer == order.user;
    }

    /**
     * @notice Helper method that actually opens the intent
     * @dev Handles funding transfer and intent publication
     * @param destination Destination chain ID
     * @param route Encoded route data
     * @param reward Reward structure
     * @param user Address of the user opening the intent
     * @return intentHash The hash of the opened intent
     */
    function _openIntent(
        uint64 destination,
        bytes memory route,
        Reward memory reward,
        address user
    ) internal returns (bytes32 intentHash) {
        if (!this.isIntentFunded(destination, route, reward)) {
            address vault = this.intentVaultAddress(destination, route, reward);
            uint256 rewardsLength = reward.tokens.length;

            if (reward.nativeValue > 0) {
                if (msg.value < reward.nativeValue) {
                    revert InsufficientNativeRewardAmount();
                }

                payable(vault).transfer(reward.nativeValue);
            }

            for (uint256 i = 0; i < rewardsLength; ++i) {
                address token = reward.tokens[i].token;
                uint256 amount = reward.tokens[i].amount;

                IERC20(token).safeTransferFrom(user, vault, amount);
            }
        }

        payable(msg.sender).transfer(address(this).balance);

        // Publish the intent using universal format
        (intentHash, ) = this.publish(destination, route, reward);
        return intentHash;
    }

    /**
     * @notice Resolves order data into a standardized cross-chain order format
     * @dev Converts Eco-specific order data into ERC-7683 format
     * @param openDeadline The deadline for opening the order
     * @param orderData The Eco-specific order data
     * @return ResolvedCrossChainOrder in ERC-7683 format
     */
    function _resolve(
        uint32 openDeadline,
        OrderData memory orderData
    ) public view returns (ResolvedCrossChainOrder memory) {
        // Decode the route bytes to extract token information
        Route memory route = abi.decode(orderData.route, (Route));
        uint256 routeTokenCount = route.tokens.length;

        // Create maxSpent array with tokens from the route
        Output[] memory maxSpent = new Output[](routeTokenCount);

        for (uint256 i = 0; i < routeTokenCount; ++i) {
            maxSpent[i] = Output(
                bytes32(uint256(uint160(route.tokens[i].token))), // Convert address to bytes32
                route.tokens[i].amount,
                bytes32(uint256(uint160(address(0)))), // recipient is zero address
                uint256(orderData.destination) // chainId is the destination
            );
        }

        uint256 rewardTokenCount = orderData.reward.tokens.length;

        Output[] memory minReceived = new Output[](
            rewardTokenCount + (orderData.reward.nativeValue > 0 ? 1 : 0)
        );

        for (uint256 i = 0; i < rewardTokenCount; ++i) {
            minReceived[i] = Output(
                bytes32(uint256(uint160(orderData.reward.tokens[i].token))), // Convert address to bytes32
                orderData.reward.tokens[i].amount,
                bytes32(uint256(uint160(address(0)))), //filler is not known
                uint256(orderData.destination)
            );
        }

        if (orderData.reward.nativeValue > 0) {
            minReceived[rewardTokenCount] = Output(
                bytes32(uint256(uint160(address(0)))),
                orderData.reward.nativeValue,
                bytes32(uint256(uint160(address(0)))),
                uint256(orderData.destination)
            );
        }

        bytes32 routeHash = keccak256(orderData.route);
        bytes32 rewardHash = keccak256(abi.encode(orderData.reward));
        bytes32 intentHash = keccak256(
            abi.encodePacked(orderData.destination, routeHash, rewardHash)
        );

        // Construct the Intent struct for proper encoding in originData
        Route memory routeStruct = abi.decode(orderData.route, (Route));
        Intent memory intent = Intent(
            orderData.destination,
            routeStruct,
            orderData.reward
        );

        FillInstruction[] memory fillInstructions = new FillInstruction[](1);
        fillInstructions[0] = FillInstruction(
            orderData.destination,
            orderData.portal,
            abi.encode(intent)
        );

        return
            ResolvedCrossChainOrder(
                orderData.reward.creator,
                block.chainid,
                openDeadline,
                uint32(orderData.deadline),
                intentHash,
                maxSpent,
                minReceived,
                fillInstructions
            );
    }

    /// @notice EIP712 domain separator
    function domainSeparatorV4() public view returns (bytes32) {
        return domainSeparatorV4();
    }

    /**
     * @notice Computes the deterministic vault address for an intent
     * @param destination Destination chain ID for the intent
     * @param route Encoded route data for the intent as bytes
     * @param reward The reward structure containing distribution details
     * @return Predicted vault address
     */
    function intentVaultAddress(
        uint64 destination,
        bytes memory route,
        Reward calldata reward
    ) public view virtual returns (address);

    /**
     * @notice Creates a new cross-chain intent with associated rewards
     * @dev Intent must be proven on source chain before expiration for valid reward claims
     * @param destination Destination chain ID for the intent
     * @param route Encoded route data for the intent as bytes
     * @param reward The reward structure containing distribution details
     * @return intentHash Unique identifier of the created intent
     * @return vault Address of the created vault
     */
    function publish(
        uint64 destination,
        bytes memory route,
        Reward calldata reward
    ) public virtual returns (bytes32 intentHash, address vault);

    /**
     * @notice Checks if an intent's rewards are valid and fully funded
     * @param destination Destination chain ID for the intent
     * @param route Encoded route data for the intent as bytes
     * @param reward The reward structure containing distribution details
     * @return True if the intent is properly funded
     */
    function isIntentFunded(
        uint64 destination,
        bytes memory route,
        Reward calldata reward
    ) public view virtual returns (bool);
}
