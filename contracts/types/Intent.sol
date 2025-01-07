/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

struct Call {
    address target;
    bytes data;
    uint256 value;
}

struct TokenAmount {
    address token;
    uint256 amount;
}

struct Route {
    // nonce provided by the creator
    bytes32 nonce;
    // ID of chain where the intent was created
    uint256 source;
    // ID of chain where we want instructions executed
    uint256 destination;
    // The inbox contract on the destination chain will be the msg.sender
    address inbox;
    // instructions
    Call[] calls;
}

struct Reward {
    // creator of the intent
    address creator;
    // address of the prover this intent will be checked against
    address prover;
    // intent expiry timestamp
    uint256 expiryTime;
    // native tokens offered as reward
    uint256 nativeValue;
    // addresses and amounts of reward tokens
    TokenAmount[] tokens;
}

struct Intent {
    Route route;
    Reward reward;
}
