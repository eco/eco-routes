// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title MalformedProver
 * @notice Test prover whose provenIntents() SUCCEEDS but returns the wrong
 *         returndata shape (32 bytes instead of the 64-byte ProofData ABI
 *         encoding)
 * @dev Verifies AggregatorProver.provenIntents treats a code-bearing member
 *      returning success with insufficient returndata as "no proof from this
 *      member" (skip, fall through) rather than reverting. A plain interface
 *      call decoding directly into ProofData would revert on this returndata
 *      in the CALLER's frame, outside any try/catch — this contract exists to
 *      prove the low-level staticcall + explicit length check avoids that.
 */
contract MalformedProver {
    function provenIntents(bytes32) external pure returns (bytes32) {
        return bytes32(uint256(1));
    }

    function challengeIntentProof(uint64, bytes32, bytes32) external pure {}
}
