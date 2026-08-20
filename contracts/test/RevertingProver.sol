// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IProver} from "../interfaces/IProver.sol";

/**
 * @title RevertingProver
 * @notice Test prover whose every entry point reverts
 * @dev Verifies EcoProver skips misbehaving members instead of
 *      propagating their failure
 */
contract RevertingProver is IProver {
    error AlwaysReverts();

    function version() external pure returns (string memory) {
        return "0.0.0";
    }

    function getProofType() external pure returns (string memory) {
        return "reverting";
    }

    function provenIntents(bytes32) external pure returns (ProofData memory) {
        revert AlwaysReverts();
    }

    function challengeIntentProof(uint64, bytes32, bytes32) external pure {
        revert AlwaysReverts();
    }

    function prove(
        address,
        uint64,
        bytes calldata,
        bytes calldata
    ) external payable {
        revert AlwaysReverts();
    }
}
