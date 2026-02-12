// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Endian} from "../../contracts/libs/Endian.sol";

contract EndianTest is Test {
    // ============ toLittleEndian64 Tests ============

    function test_toLittleEndian64_zero() public pure {
        uint64 value = 0;
        bytes8 result = Endian.toLittleEndian64(value);
        assertEq(result, bytes8(0));
    }

    function test_toLittleEndian64_one() public pure {
        uint64 value = 1;
        bytes8 result = Endian.toLittleEndian64(value);
        // Big-endian: 0x0000000000000001
        // Little-endian: 0x0100000000000000
        assertEq(result, bytes8(0x0100000000000000));
    }

    function test_toLittleEndian64_maxUint64() public pure {
        uint64 value = type(uint64).max; // 0xFFFFFFFFFFFFFFFF
        bytes8 result = Endian.toLittleEndian64(value);
        // All bytes are 0xFF, so reversed is also 0xFFFFFFFFFFFFFFFF
        assertEq(result, bytes8(0xFFFFFFFFFFFFFFFF));
    }

    function test_toLittleEndian64_specificPattern() public pure {
        // Test a value where byte order matters: 0x0102030405060708
        uint64 value = 0x0102030405060708;
        bytes8 result = Endian.toLittleEndian64(value);
        // Little-endian reversal: 0x0807060504030201
        assertEq(result, bytes8(0x0807060504030201));
    }

    function test_toLittleEndian64_deadlineExample() public pure {
        // Example: 7 days in seconds = 604800 = 0x93A80
        uint64 value = 604800;
        bytes8 result = Endian.toLittleEndian64(value);
        // Big-endian: 0x000000000009_3A80
        // Little-endian: 0x803A090000000000
        assertEq(result, bytes8(0x803A090000000000));
    }

    function test_toLittleEndian64_timestamp() public pure {
        // Example: simple value 0x1122334455667788
        // This makes it easy to verify byte reversal
        uint64 value = 0x1122334455667788;
        bytes8 result = Endian.toLittleEndian64(value);
        // Little-endian (bytes reversed): 0x8877665544332211
        assertEq(result, bytes8(0x8877665544332211));
    }

    function test_toLittleEndian64_eachByteDifferent() public pure {
        // Value where each byte is unique to verify proper reversal
        uint64 value = 0x0123456789ABCDEF;
        bytes8 result = Endian.toLittleEndian64(value);
        // Little-endian: 0xEFCDAB8967452301
        assertEq(result, bytes8(0xEFCDAB8967452301));
    }

    // ============ toLittleEndian32 Tests ============

    function test_toLittleEndian32_zero() public pure {
        uint32 value = 0;
        bytes4 result = Endian.toLittleEndian32(value);
        assertEq(result, bytes4(0));
    }

    function test_toLittleEndian32_one() public pure {
        uint32 value = 1;
        bytes4 result = Endian.toLittleEndian32(value);
        // Big-endian: 0x00000001
        // Little-endian: 0x01000000
        assertEq(result, bytes4(0x01000000));
    }

    function test_toLittleEndian32_maxUint32() public pure {
        uint32 value = type(uint32).max; // 0xFFFFFFFF
        bytes4 result = Endian.toLittleEndian32(value);
        // All bytes are 0xFF, so reversed is also 0xFFFFFFFF
        assertEq(result, bytes4(0xFFFFFFFF));
    }

    function test_toLittleEndian32_specificPattern() public pure {
        // Test a value where byte order matters: 0x01020304
        uint32 value = 0x01020304;
        bytes4 result = Endian.toLittleEndian32(value);
        // Little-endian reversal: 0x04030201
        assertEq(result, bytes4(0x04030201));
    }

    function test_toLittleEndian32_arrayLength() public pure {
        // Example: tokens array length = 1
        uint32 value = 1;
        bytes4 result = Endian.toLittleEndian32(value);
        assertEq(result, bytes4(0x01000000));
    }

    function test_toLittleEndian32_largeCount() public pure {
        // Example: array length = 1000 = 0x3E8
        uint32 value = 1000;
        bytes4 result = Endian.toLittleEndian32(value);
        // Big-endian: 0x000003E8
        // Little-endian: 0xE8030000
        assertEq(result, bytes4(0xE8030000));
    }

    function test_toLittleEndian32_eachByteDifferent() public pure {
        // Value where each byte is unique to verify proper reversal
        uint32 value = 0x12345678;
        bytes4 result = Endian.toLittleEndian32(value);
        // Little-endian: 0x78563412
        assertEq(result, bytes4(0x78563412));
    }

    // ============ Fuzz Tests ============

    function testFuzz_toLittleEndian64_reversible(uint64 value) public pure {
        // Convert to little-endian
        bytes8 littleEndian = Endian.toLittleEndian64(value);

        // Reverse it back manually to verify correctness
        // In bytes8, index [0] is the most significant (leftmost) byte
        // We need to reverse the byte order back
        uint64 reversed = 0;
        reversed |= uint64(uint8(littleEndian[7])) << 56;
        reversed |= uint64(uint8(littleEndian[6])) << 48;
        reversed |= uint64(uint8(littleEndian[5])) << 40;
        reversed |= uint64(uint8(littleEndian[4])) << 32;
        reversed |= uint64(uint8(littleEndian[3])) << 24;
        reversed |= uint64(uint8(littleEndian[2])) << 16;
        reversed |= uint64(uint8(littleEndian[1])) << 8;
        reversed |= uint64(uint8(littleEndian[0]));

        // Should get back original value
        assertEq(reversed, value);
    }

    function testFuzz_toLittleEndian32_reversible(uint32 value) public pure {
        // Convert to little-endian
        bytes4 littleEndian = Endian.toLittleEndian32(value);

        // Reverse it back manually to verify correctness
        // In bytes4, index [0] is the most significant (leftmost) byte
        // We need to reverse the byte order back
        uint32 reversed = 0;
        reversed |= uint32(uint8(littleEndian[3])) << 24;
        reversed |= uint32(uint8(littleEndian[2])) << 16;
        reversed |= uint32(uint8(littleEndian[1])) << 8;
        reversed |= uint32(uint8(littleEndian[0]));

        // Should get back original value
        assertEq(reversed, value);
    }

    // ============ Byte-level Verification Tests ============

    function test_toLittleEndian64_byteOrder() public pure {
        // Test that bytes are actually reversed
        // Input: 0x0102030405060708
        // Each byte position should be reversed
        uint64 value = 0x0102030405060708;
        bytes8 result = Endian.toLittleEndian64(value);

        // Verify each byte individually
        assertEq(uint8(result[0]), 0x08); // Last byte becomes first
        assertEq(uint8(result[1]), 0x07);
        assertEq(uint8(result[2]), 0x06);
        assertEq(uint8(result[3]), 0x05);
        assertEq(uint8(result[4]), 0x04);
        assertEq(uint8(result[5]), 0x03);
        assertEq(uint8(result[6]), 0x02);
        assertEq(uint8(result[7]), 0x01); // First byte becomes last
    }

    function test_toLittleEndian32_byteOrder() public pure {
        // Test that bytes are actually reversed
        // Input: 0x01020304
        uint32 value = 0x01020304;
        bytes4 result = Endian.toLittleEndian32(value);

        // Verify each byte individually
        assertEq(uint8(result[0]), 0x04); // Last byte becomes first
        assertEq(uint8(result[1]), 0x03);
        assertEq(uint8(result[2]), 0x02);
        assertEq(uint8(result[3]), 0x01); // First byte becomes last
    }

    // ============ Integration with abi.encodePacked ============

    function test_toLittleEndian64_inEncodePacked() public pure {
        // Verify it works correctly when used in abi.encodePacked
        uint64 value = 604800; // 7 days
        bytes memory packed = abi.encodePacked(
            Endian.toLittleEndian64(value)
        );

        assertEq(packed.length, 8);
        assertEq(packed, hex"803A090000000000");
    }

    function test_toLittleEndian32_inEncodePacked() public pure {
        // Verify it works correctly when used in abi.encodePacked
        uint32 value = 1; // Array length
        bytes memory packed = abi.encodePacked(
            Endian.toLittleEndian32(value)
        );

        assertEq(packed.length, 4);
        assertEq(packed, hex"01000000");
    }

    function test_borshFormatSimulation() public pure {
        // Simulate a simple Borsh encoding similar to DepositAddress
        uint64 deadline = 604800;
        uint64 nativeAmount = 0;
        uint32 tokensLength = 1;
        uint64 tokenAmount = 1000000; // 1 million tokens
        uint32 callsLength = 0;

        bytes memory borshLike = abi.encodePacked(
            Endian.toLittleEndian64(deadline),
            Endian.toLittleEndian64(nativeAmount),
            Endian.toLittleEndian32(tokensLength),
            Endian.toLittleEndian64(tokenAmount),
            Endian.toLittleEndian32(callsLength)
        );

        // Verify total length: 8 + 8 + 4 + 8 + 4 = 32 bytes
        assertEq(borshLike.length, 32);

        // Verify deadline is little-endian
        assertEq(
            bytes8(borshLike),
            Endian.toLittleEndian64(deadline)
        );
    }
}
