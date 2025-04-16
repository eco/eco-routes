/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseProver} from "../prover/BaseProver.sol";

contract TestProver is BaseProver {
    function version() external pure returns (string memory) {
        return "1.8.14-e2c12e7";
    }

    function addProvenIntent(bytes32 _hash, address _claimant) public {
        provenIntents[_hash] = _claimant;
    }

    function getProofType() external pure override returns (string memory) {
        return "storage";
    }
}
