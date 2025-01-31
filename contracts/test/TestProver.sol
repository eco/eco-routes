/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../prover/BaseProver.sol";

contract TestProver is BaseProver {
    function version() external pure returns (string memory) {
        return "1.5.23-e80e631";
    }

    function addProvenIntent(bytes32 _hash, address _claimant) public {
        provenIntents[_hash] = _claimant;
    }

    function getProofType() external pure override returns (ProofType) {
        return ProofType.Storage;
    }
}
