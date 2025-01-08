/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IProver {
    function provenIntents(bytes32 _identifier) external returns (address);
}
