/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseProver} from "../prover/BaseProver.sol";
import {IProver} from "../interfaces/IProver.sol";
import {MinimalRoute, Route} from "../types/Intent.sol";

contract TestProver is BaseProver {
    struct ArgsCheck {
        address sender;
        uint256 sourceChainID;
        bytes data;
        uint256 value;
    }

    ArgsCheck public args;
    MinimalRoute[] public argMinimalRoutes;
    bytes32[] public argRewardHashes;
    address[] public argClaimants;

    constructor(address _inbox) BaseProver(_inbox) {}

    function version() external pure returns (string memory) {
        return "1.8.14-e2c12e7";
    }

    function addProvenIntent(bytes32 _hash, address _claimant) public {
        provenIntents[_hash] = _claimant;
    }

    function getProofType() external pure override returns (string memory) {
        return "storage";
    }

    function prove(
        address _sender,
        uint256 _sourceChainID,
        MinimalRoute[] calldata _minimalRoutes,
        bytes32[] calldata _rewardHashes,
        address[] calldata _claimants,
        bytes calldata _data
    ) external payable override {
        args = ArgsCheck({
            sender: _sender,
            sourceChainID: _sourceChainID,
            data: _data,
            value: msg.value
        });
        argMinimalRoutes = _minimalRoutes;
        argRewardHashes = _rewardHashes;
        argClaimants = _claimants;
    }
}
