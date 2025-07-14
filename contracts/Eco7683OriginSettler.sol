/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IOriginSettler} from "./interfaces/ERC7683/IOriginSettler.sol";
import {IUniversalIntentSource} from "./interfaces/IUniversalIntentSource.sol";

import {Intent, Route, Reward, TokenAmount, Call} from "./types/UniversalIntent.sol";
import {OnchainCrossChainOrder, ResolvedCrossChainOrder, GaslessCrossChainOrder, Output, FillInstruction} from "./types/ERC7683.sol";
import {OrderData, ORDER_DATA_TYPEHASH} from "./types/EcoERC7683.sol";
import {AddressConverter} from "./libs/AddressConverter.sol";
import {Semver} from "./libs/Semver.sol";

/**
 * @title Eco7683OriginSettler
 * @notice Entry point to Eco Protocol via EIP-7683
 * @dev functionality is somewhat limited compared to interacting with Eco Protocol directly
 */
contract Eco7683OriginSettler is IOriginSettler, Semver, EIP712 {
    using ECDSA for bytes32;
    using SafeERC20 for IERC20;
    using AddressConverter for bytes32;

    /// @notice typehash for gasless crosschain order
    bytes32 public GASLESS_CROSSCHAIN_ORDER_TYPEHASH =
        keccak256(
            "GaslessCrossChainOrder(address originSettler,address user,uint256 nonce,uint256 originChainId,uint32 openDeadline,uint32 fillDeadline,bytes32 orderDataType,bytes32 orderDataHash)"
        );

    /// @notice address of Portal contract where intents are actually published
    IUniversalIntentSource public immutable INTENT_SOURCE;

    /**
     * @notice Initializes the Eco7683OriginSettler
     * @param name the name of the contract for EIP712
     * @param version the version of the contract for EIP712
     * @param intentSource the address of the Portal contract (implements IUniversalIntentSource)
     */
    constructor(
        string memory name,
        string memory version,
        address intentSource
    ) EIP712(name, version) {
        INTENT_SOURCE = IUniversalIntentSource(intentSource);
    }

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

        Intent memory intent = Intent(
            orderData.destination,
            orderData.route,
            orderData.reward
        );

        bytes32 orderId = _openIntent(intent, orderData.routeHash, msg.sender);

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
     * @param originFillerData filler data for the origin chain (vestigial, not used)
     */
    function openFor(
        GaslessCrossChainOrder calldata order,
        bytes calldata signature,
        bytes calldata originFillerData
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

        Intent memory intent = Intent(
            orderData.destination,
            orderData.route,
            orderData.reward
        );

        if (order.originChainId != block.chainid) {
            revert OriginChainIDMismatch();
        }

        bytes32 orderId = _openIntent(intent, orderData.routeHash, order.user);

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

    /// @notice helper method for signature verification
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

    /// @notice helper method that actually opens the intent
    function _openIntent(
        Intent memory intent,
        bytes32 routeHash,
        address user
    ) internal returns (bytes32 intentHash) {
        if (!INTENT_SOURCE.isIntentFunded(intent)) {
            address vault = INTENT_SOURCE.intentVaultAddress(intent, routeHash);
            uint256 rewardsLength = intent.reward.tokens.length;

            if (intent.reward.nativeValue > 0) {
                if (msg.value < intent.reward.nativeValue) {
                    revert InsufficientNativeReward();
                }

                payable(vault).transfer(intent.reward.nativeValue);
            }

            for (uint256 i = 0; i < rewardsLength; ++i) {
                address token = intent.reward.tokens[i].token.toAddress();
                uint256 amount = intent.reward.tokens[i].amount;

                IERC20(token).safeTransferFrom(user, vault, amount);
            }
        }

        payable(msg.sender).transfer(address(this).balance);

        // Use the provided routeHash for the publish function
        (intentHash, ) = INTENT_SOURCE.publish(intent, routeHash);
        return intentHash;
    }

    function _resolve(
        uint32 openDeadline,
        OrderData memory orderData
    ) public view returns (ResolvedCrossChainOrder memory) {
        // Extract destination from order data
        uint256 routeTokenCount = orderData.route.tokens.length;

        Output[] memory maxSpent = new Output[](routeTokenCount);

        for (uint256 i = 0; i < routeTokenCount; ++i) {
            TokenAmount memory approval = orderData.route.tokens[i];

            maxSpent[i] = Output(
                approval.token, // Already bytes32 in universal types
                approval.amount,
                bytes32(uint256(uint160(address(0)))), //filler is not known
                orderData.destination
            );
        }

        uint256 rewardTokenCount = orderData.reward.tokens.length;

        Output[] memory minReceived = new Output[](
            rewardTokenCount + (orderData.reward.nativeValue > 0 ? 1 : 0)
        );

        for (uint256 i = 0; i < rewardTokenCount; ++i) {
            minReceived[i] = Output(
                orderData.reward.tokens[i].token, // Already bytes32 in universal types
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

        bytes32 rewardHash = keccak256(abi.encode(orderData.reward));
        bytes32 intentHash = keccak256(
            abi.encodePacked(
                orderData.destination,
                orderData.routeHash,
                rewardHash
            )
        );

        FillInstruction[] memory fillInstructions = new FillInstruction[](1);
        fillInstructions[0] = FillInstruction(
            orderData.destination,
            orderData.route.portal,
            abi.encode(orderData.route, rewardHash)
        );

        return
            ResolvedCrossChainOrder(
                orderData.reward.creator.toAddress(),
                block.chainid,
                openDeadline,
                uint32(orderData.route.deadline),
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
}
