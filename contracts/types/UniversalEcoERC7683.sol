/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TokenAmount, Route, Call} from "./UniversalIntent.sol";

/**
 * @title UniversalEcoERC7683
 * @dev Cross-chain compatible ERC7683 orderData subtypes designed for Eco Protocol
 */

/**
 * @notice contains everything which, when combined with other aspects of GaslessCrossChainOrder
 * is sufficient to publish an intent via Eco Protocol
 * @dev the orderData field of GaslessCrossChainOrder should be decoded as OnchainCrosschainOrderData
 * @param route the route data
 * @param creator the identifier of the intent creator (bytes32 for cross-chain compatibility)
 * @param prover the identifier of the prover contract this intent will be proven against (bytes32 for cross-chain compatibility)
 * @param nativeValue the amount of native token offered as a reward
 * @param tokens the identifiers and amounts of reward tokens
 */
struct OnchainCrosschainOrderData {
    Route route;
    bytes32 creator;
    bytes32 prover;
    uint256 nativeValue;
    TokenAmount[] rewardTokens;
}
/**
 * @notice contains everything which, when combined with other aspects of GaslessCrossChainOrder
 * is sufficient to publish an intent via Eco Protocol
 * @dev the orderData field of GaslessCrossChainOrder should be decoded as GaslessCrosschainOrderData
 * @param destination the ID of the chain where the intent was created
 * @param inbox the identifier of the inbox contract on the destination chain that will fulfill the intent (bytes32 for cross-chain compatibility)
 * @param calls the call instructions to be called during intent fulfillment
 * @param prover the identifier of the prover contract this intent will be proven against (bytes32 for cross-chain compatibility)
 * @param nativeValue the amount of native token offered as a reward
 * @param tokens the identifiers and amounts of reward tokens
 */
struct GaslessCrosschainOrderData {
    uint256 destination;
    bytes32 inbox;
    TokenAmount[] routeTokens;
    Call[] calls;
    bytes32 prover;
    uint256 nativeValue;
    TokenAmount[] rewardTokens;
}

//EIP712 typehashes
bytes32 constant UNIVERSAL_ONCHAIN_CROSSCHAIN_ORDER_DATA_TYPEHASH = keccak256(
    "OnchainCrosschainOrderData(Route route,bytes32 creator,bytes32 prover,uint256 nativeValue,TokenAmount[] rewardTokens)Route(bytes32 salt,uint256 source,uint256 destination,bytes32 inbox,TokenAmount[] tokens,Call[] calls)TokenAmount(bytes32 token,uint256 amount)Call(bytes32 target,bytes data,uint256 value)"
);
bytes32 constant UNIVERSAL_GASLESS_CROSSCHAIN_ORDER_DATA_TYPEHASH = keccak256(
    "GaslessCrosschainOrderData(uint256 destination,bytes32 inbox,TokenAmount[] routeTokens,Call[] calls,bytes32 prover,uint256 nativeValue,TokenAmount[] rewardTokens)TokenAmount(bytes32 token,uint256 amount)Call(bytes32 target,bytes data,uint256 value)"
);