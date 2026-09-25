// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title ShortDynamicProver
 * @notice Test prover whose provenIntents() returns a single 32-byte `bytes`
 *         value, which ABI-encodes to exactly 96 bytes: offset head 0x20,
 *         length 0x20, then the data word (here 1)
 * @dev Verifies AggregatorProver.provenIntents does not surface the offset
 *      head as a fabricated claimant address(0x20) with destination 32 and
 *      outcome Fulfilled.
 */
contract ShortDynamicProver {
    function provenIntents(bytes32) external pure returns (bytes memory) {
        return abi.encodePacked(uint256(1));
    }

    function challengeIntentProof(uint64, bytes32, bytes32) external pure {}
}
