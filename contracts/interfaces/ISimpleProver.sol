// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISemver} from "./ISemver.sol";

interface ISimpleProver is ISemver {
    // The types of proof that provers can be
    enum ProofType {
        Storage,
        Hyperlane
    }

    // returns the proof type of the prover
    function getProofType() external pure returns (ProofType);
}
