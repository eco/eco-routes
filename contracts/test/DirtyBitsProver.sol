// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title DirtyBitsProver
 * @notice Test prover whose provenIntents() SUCCEEDS and returns exactly 64
 *         bytes (the correct ProofData shape) but with every bit set,
 *         including the upper 96 bits of the address word and the upper 192
 *         bits of the uint64 word
 * @dev Verifies AggregatorProver.provenIntents treats a code-bearing member
 *      returning a size-correct but bit-dirty payload as "no proof from this
 *      member" (skip, fall through) rather than reverting. Decoding this
 *      exact payload directly to (address, uint64) would revert in the
 *      CALLER's frame, outside any try/catch, because solc's ABI decoder
 *      strictly rejects non-zero padding bits — this contract exists to
 *      prove the uint256/uint256 decode plus range check avoids that.
 */
contract DirtyBitsProver {
    function provenIntents(bytes32) external pure returns (bytes32, bytes32) {
        bytes32 word = bytes32(type(uint256).max);
        assembly {
            mstore(0x00, word)
            mstore(0x20, word)
            return(0x00, 0x40)
        }
    }

    function challengeIntentProof(uint64, bytes32, bytes32) external pure {}
}
