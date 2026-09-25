// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title MockDomainProverEmptyDynamic
 * @notice Stand-in exposing a well-formed `chainIdByDomain` but whose
 *         `provenIntents` returns a single EMPTY DYNAMIC value
 * @dev Pins the gap a range-check-only shape probe leaves open. An empty
 *      `bytes` ABI-encodes to exactly 64 bytes — offset head 0x20, then length
 *      0x00 — which passes a range check (0x20 >> 160 == 0, and 0 >> 64 == 0).
 *      AggregatorProver.provenIntents skips that payload at RUNTIME, which
 *      means such a member is skipped for every intentHash, forever.
 *      Membership is immutable, so deploy time is the last point it can be
 *      caught: the probe requires exactly 96 bytes of zero words.
 */
contract MockDomainProverEmptyDynamic {
    function chainIdByDomain(uint64) external pure returns (uint64) {
        return 0;
    }

    function provenIntents(bytes32) external pure returns (bytes memory) {
        return "";
    }
}
