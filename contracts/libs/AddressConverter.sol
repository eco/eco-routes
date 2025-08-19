// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title AddressConverter
 * @notice Library for converting between address and bytes32 types
 */
library AddressConverter {
    /**
     * @notice Convert an address to bytes32
     * @param _addr The address to convert
     * @return The address as bytes32
     */
    function toBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    /**
     * @notice Convert bytes32 to an address
     * @param _bytes The bytes32 to convert
     * @return The bytes32 as an address
     */
    function toAddress(bytes32 _bytes) internal pure returns (address) {
        return address(uint160(uint256(_bytes)));
    }
}