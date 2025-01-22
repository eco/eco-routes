// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Semver, ISemver} from "../libs/Semver.sol";

interface IProver is ISemver {
    // The types of proof that provers can be
    enum ProofType {
        Storage,
        Hyperlane,
        Metalayer
    }

    // returns the proof type of the prover
    function getProofType() external pure returns (ProofType);
}
