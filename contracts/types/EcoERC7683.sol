/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TokenAmount, Call} from "./UniversalIntent.sol";

/**
 * @title EcoERC7683
 * @dev ERC7683 orderData subtypes designed for Eco Protocol
 */

/**
 * @notice Route structure for EIP-7683 compatibility
 * @param salt Unique identifier for the route
 * @param source Source chain ID
 * @param destination Destination chain ID
 * @param inbox Address of the inbox contract on destination chain
 * @param tokens Array of tokens required for the route
 * @param calls Array of calls to execute
 */
struct Route {
    bytes32 salt;
    bytes32 portal;
    TokenAmount[] tokens;
    Call[] calls;
}

/**
 * @notice contains everything which, when combined with other aspects of GaslessCrossChainOrder
 * is sufficient to publish an intent via Eco Protocol
 * @dev the orderData field of GaslessCrossChainOrder should be decoded as GaslessCrosschainOrderData\
 * @param route the route data
 * @param creator the address of the intent creator
 * @param prover the address of the prover contract this intent will be proven against
 * @param nativeValue the amount of native token offered as a reward
 * @param tokens the addresses and amounts of reward tokens
 */
struct OnchainCrosschainOrderData {
    uint64 destination;
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
 * @param inbox the inbox contract on the destination chain that will fulfill the intent
 * @param calls the call instructions to be called during intent fulfillment
 * @param prover the address of the prover contract this intent will be proven against
 * @param nativeValue the amount of native token offered as a reward
 * @param tokens the addresses and amounts of reward tokens
 */

struct GaslessCrosschainOrderData {
    uint256 destination;
    bytes32 portal;
    TokenAmount[] routeTokens;
    Call[] calls;
    bytes32 prover;
    uint256 nativeValue;
    TokenAmount[] rewardTokens;
}

//EIP712 typehashes
bytes32 constant ONCHAIN_CROSSCHAIN_ORDER_DATA_TYPEHASH = keccak256(
    "OnchainCrosschainOrderData(uint64 destination,Route route,bytes32 creator,bytes32 prover,uint256 nativeValue,TokenAmount[] rewardTokens)Route(bytes32 salt,bytes32 portal,TokenAmount[] tokens,Call[] calls)TokenAmount(bytes32 token,uint256 amount)Call(bytes32 target,bytes data,uint256 value)"
);
bytes32 constant GASLESS_CROSSCHAIN_ORDER_DATA_TYPEHASH = keccak256(
    "GaslessCrosschainOrderData(uint256 destination,bytes32 portal,TokenAmount[] routeTokens,Call[] calls,bytes32 prover,uint256 nativeValue,TokenAmount[] rewardTokens)TokenAmount(bytes32 token,uint256 amount)Call(bytes32 target,bytes data,uint256 value)"
);
