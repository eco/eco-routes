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
     * @return Little-endian bytes8 representation
     * @dev Uses divide-and-conquer approach for efficiency:
     *      1. Swap adjacent bytes (8 -> 4 pairs)
     *      2. Swap adjacent 16-bit pairs (4 -> 2 pairs)
     *      3. Swap 32-bit halves (2 -> 1)
     *      This approach uses 3 operations instead of 8, saving ~30-40% gas
     */
    function toLittleEndian64(uint64 value) internal pure returns (bytes8) {
        // Step 1: Swap adjacent bytes
        // 0x0102030405060708 -> 0x0201040306050807
        value = ((value & 0xFF00FF00FF00FF00) >> 8) | ((value & 0x00FF00FF00FF00FF) << 8);

        // Step 2: Swap adjacent 16-bit pairs
        // 0x0201040306050807 -> 0x0403020108070605
        value = ((value & 0xFFFF0000FFFF0000) >> 16) | ((value & 0x0000FFFF0000FFFF) << 16);

        // Step 3: Swap 32-bit halves
        // 0x0403020108070605 -> 0x0807060504030201
        value = (value >> 32) | (value << 32);

        return bytes8(value);
    }

    /**
     * @notice Convert uint32 to little-endian bytes4
     * @param value The uint32 value to convert
     * @return Little-endian bytes4 representation
     * @dev Uses divide-and-conquer approach for efficiency:
     *      1. Swap adjacent bytes (4 -> 2 pairs)
     *      2. Swap 16-bit halves (2 -> 1)
     *      This approach uses 2 operations instead of 4, saving ~30-40% gas
     */
    function toLittleEndian32(uint32 value) internal pure returns (bytes4) {
        // Step 1: Swap adjacent bytes
        // 0x01020304 -> 0x02010403
        value = ((value & 0xFF00FF00) >> 8) | ((value & 0x00FF00FF) << 8);

        // Step 2: Swap 16-bit halves
        // 0x02010403 -> 0x04030201
        value = (value >> 16) | (value << 16);

        return bytes4(value);
    }
}
