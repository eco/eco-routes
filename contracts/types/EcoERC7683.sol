/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Route, Reward} from "./UniversalIntent.sol";

/**
 * @title EcoERC7683
 * @dev ERC7683 orderData subtypes designed for Eco Protocol
 */

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
struct OrderData {
    uint64 destination;
    bytes32 portal;
    uint64 deadline;
    bytes route;
    Reward reward;
}

// EIP712 type hash
bytes32 constant ORDER_DATA_TYPEHASH = keccak256(
    "OrderData(uint64 destination,bytes32 portal,uint64 deadline,bytes route,Reward reward)Reward(uint64 deadline,bytes32 creator,bytes32 prover,uint256 nativeValue,TokenAmount[] tokens)TokenAmount(bytes32 token,uint256 amount)"
);
