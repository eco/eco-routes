/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseProver} from "./BaseProver.sol";

abstract contract MessageBridgeProver is BaseProver {
    mapping(address => bool) public proverWhitelist;

    function initiateProving(
        uint256 _sourceChainId,
        bytes32[] calldata _intentHashes,
        address[] calldata _claimants,
        address _sourceChainProver,
        bytes calldata _data
    ) external payable virtual;

    function fetchFee(
        uint256 _sourceChainId,
        bytes32[] calldata _intentHashes,
        address[] calldata _claimants,
        address _sourceChainProver,
        bytes calldata _data
    ) external view virtual returns (uint256);
}
