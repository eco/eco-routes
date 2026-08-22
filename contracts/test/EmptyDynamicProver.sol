// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title EmptyDynamicProver
 * @notice Test prover whose provenIntents() SUCCEEDS and returns a single
 *         empty dynamic value, which ABI-encodes to exactly 64 bytes: an
 *         offset head 0x20 followed by a length word 0x00 — the same size as
 *         the correct ProofData shape
 * @dev Verifies AggregatorProver.provenIntents treats this payload as "no proof from
 *      this member" (skip, fall through) rather than surfacing the ABI OFFSET
 *      WORD as a fabricated claimant. Unlike DirtyBitsProver/MalformedProver,
 *      which hand-craft their returndata with inline assembly, this contract
 *      returns a genuine `bytes memory` value so solc itself produces the
 *      encoding, exercising the real payload shape rather than a simulated
 *      one.
 */
contract EmptyDynamicProver {
    function provenIntents(bytes32) external pure returns (bytes memory) {
        return "";
    }

    function challengeIntentProof(uint64, bytes32, bytes32) external pure {}
}
