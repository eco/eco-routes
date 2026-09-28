// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title MockDomainProverShortDynamic
 * @notice Stand-in exposing a well-formed `chainIdByDomain` but whose
 *         `provenIntents` returns a single 32-byte `bytes` value
 * @dev That value ABI-encodes to exactly 96 bytes (offset head 0x20, length
 *      0x20, then the data word 1), so it clears the length gate and every
 *      word fits its field's range. Only the strict all-zero check in
 *      Deploy._tryProvenIntentsShape rejects it; AggregatorProver would skip
 *      such a member for every intentHash, forever.
 */
contract MockDomainProverShortDynamic {
    function chainIdByDomain(uint64) external pure returns (uint64) {
        return 0;
    }

    function provenIntents(bytes32) external pure returns (bytes memory) {
        return abi.encodePacked(uint256(1));
    }
}
