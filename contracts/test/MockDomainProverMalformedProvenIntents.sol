// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title MockDomainProverMalformedProvenIntents
 * @notice Minimal stand-in exposing `chainIdByDomain` (so it passes the
 *         bridge-attestation probe) but a malformed `provenIntents` that
 *         returns the wrong shape (32 bytes instead of the 64-byte ProofData
 *         encoding)
 * @dev Used to test Deploy.validateEcoProverMembers' provenIntents shape
 *      probe in isolation from the chainIdByDomain probe it sits behind.
 */
contract MockDomainProverMalformedProvenIntents {
    function chainIdByDomain(uint64) external pure returns (uint64) {
        return 0;
    }

    function provenIntents(bytes32) external pure returns (bytes32) {
        return bytes32(uint256(1));
    }
}
