// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title Endian
 * @notice Library for converting between big-endian and little-endian byte order
 * @dev Used for cross-chain compatibility with systems like Solana that use little-endian (Borsh encoding)
 */
library Endian {
    /**
     * @notice Convert uint64 to little-endian bytes8
     * @param value The uint64 value to convert
     * @return result Little-endian bytes8 representation
     */
    function toLittleEndian64(uint64 value) internal pure returns (bytes8 result) {
        // Reverse byte order: convert big-endian to little-endian
        uint64 reversed = 0;
        reversed |= (value & 0xFF) << 56;
        reversed |= ((value >> 8) & 0xFF) << 48;
        reversed |= ((value >> 16) & 0xFF) << 40;
        reversed |= ((value >> 24) & 0xFF) << 32;
        reversed |= ((value >> 32) & 0xFF) << 24;
        reversed |= ((value >> 40) & 0xFF) << 16;
        reversed |= ((value >> 48) & 0xFF) << 8;
        reversed |= ((value >> 56) & 0xFF);
        return bytes8(reversed);
    }

    /**
     * @notice Convert uint32 to little-endian bytes4
     * @param value The uint32 value to convert
     * @return result Little-endian bytes4 representation
     */
    function toLittleEndian32(uint32 value) internal pure returns (bytes4 result) {
        // Reverse byte order: convert big-endian to little-endian
        uint32 reversed = 0;
        reversed |= (value & 0xFF) << 24;
        reversed |= ((value >> 8) & 0xFF) << 16;
        reversed |= ((value >> 16) & 0xFF) << 8;
        reversed |= ((value >> 24) & 0xFF);
        return bytes4(reversed);
    }
}
