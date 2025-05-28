// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title Whitelist
 * @notice Abstract contract providing immutable whitelist functionality
 * @dev Uses immutable arrays to store up to 20 whitelisted addresses
 *
 * This contract provides a gas-efficient, immutable approach to whitelisting:
 * - The whitelist is configured ONCE at construction time
 * - After deployment, the whitelist CANNOT be modified (addresses cannot be added or removed)
 * - Maximum of 20 addresses can be whitelisted
 * - Uses immutable slots for each whitelisted address (lower gas cost than storage)
 * - Optimized for early exit when checking whitelist membership
 */
abstract contract Whitelist {
    /**
     * @notice Error thrown when an address is not whitelisted
     * @param addr The address that was not found in the whitelist
     */
    error AddressNotWhitelisted(address addr);

    /// @dev Maximum number of addresses that can be whitelisted
    uint256 private constant MAX_WHITELIST_SIZE = 20;

    /// @dev Number of addresses actually in the whitelist
    uint256 private immutable WHITELIST_SIZE;

    /// @dev Immutable storage for whitelisted addresses (up to 20)
    address private immutable ADDRESS_1;
    address private immutable ADDRESS_2;
    address private immutable ADDRESS_3;
    address private immutable ADDRESS_4;
    address private immutable ADDRESS_5;
    address private immutable ADDRESS_6;
    address private immutable ADDRESS_7;
    address private immutable ADDRESS_8;
    address private immutable ADDRESS_9;
    address private immutable ADDRESS_10;
    address private immutable ADDRESS_11;
    address private immutable ADDRESS_12;
    address private immutable ADDRESS_13;
    address private immutable ADDRESS_14;
    address private immutable ADDRESS_15;
    address private immutable ADDRESS_16;
    address private immutable ADDRESS_17;
    address private immutable ADDRESS_18;
    address private immutable ADDRESS_19;
    address private immutable ADDRESS_20;

    /**
     * @notice Initializes the whitelist with a set of addresses
     * @param addresses Array of addresses to whitelist
     */
    constructor(address[] memory addresses) {
        require(addresses.length <= MAX_WHITELIST_SIZE);

        // Store whitelist size
        WHITELIST_SIZE = addresses.length;

        // Initialize all addresses to zero address
        ADDRESS_1 = addresses.length > 0 ? addresses[0] : address(0);
        ADDRESS_2 = addresses.length > 1 ? addresses[1] : address(0);
        ADDRESS_3 = addresses.length > 2 ? addresses[2] : address(0);
        ADDRESS_4 = addresses.length > 3 ? addresses[3] : address(0);
        ADDRESS_5 = addresses.length > 4 ? addresses[4] : address(0);
        ADDRESS_6 = addresses.length > 5 ? addresses[5] : address(0);
        ADDRESS_7 = addresses.length > 6 ? addresses[6] : address(0);
        ADDRESS_8 = addresses.length > 7 ? addresses[7] : address(0);
        ADDRESS_9 = addresses.length > 8 ? addresses[8] : address(0);
        ADDRESS_10 = addresses.length > 9 ? addresses[9] : address(0);
        ADDRESS_11 = addresses.length > 10 ? addresses[10] : address(0);
        ADDRESS_12 = addresses.length > 11 ? addresses[11] : address(0);
        ADDRESS_13 = addresses.length > 12 ? addresses[12] : address(0);
        ADDRESS_14 = addresses.length > 13 ? addresses[13] : address(0);
        ADDRESS_15 = addresses.length > 14 ? addresses[14] : address(0);
        ADDRESS_16 = addresses.length > 15 ? addresses[15] : address(0);
        ADDRESS_17 = addresses.length > 16 ? addresses[16] : address(0);
        ADDRESS_18 = addresses.length > 17 ? addresses[17] : address(0);
        ADDRESS_19 = addresses.length > 18 ? addresses[18] : address(0);
        ADDRESS_20 = addresses.length > 19 ? addresses[19] : address(0);
    }

    /**
     * @notice Checks if an address is whitelisted
     * @param addr Address to check
     * @return True if the address is whitelisted, false otherwise
     */
    function isWhitelisted(address addr) public view returns (bool) {
        // Short circuit check for empty whitelist
        if (WHITELIST_SIZE == 0) return false;

        // Short circuit check for zero address
        if (addr == address(0)) return false;

        if (ADDRESS_1 == addr) return true;
        if (WHITELIST_SIZE <= 1) return false;

        if (ADDRESS_2 == addr) return true;
        if (WHITELIST_SIZE <= 2) return false;

        if (ADDRESS_3 == addr) return true;
        if (WHITELIST_SIZE <= 3) return false;

        if (ADDRESS_4 == addr) return true;
        if (WHITELIST_SIZE <= 4) return false;

        if (ADDRESS_5 == addr) return true;
        if (WHITELIST_SIZE <= 5) return false;

        if (ADDRESS_6 == addr) return true;
        if (WHITELIST_SIZE <= 6) return false;

        if (ADDRESS_7 == addr) return true;
        if (WHITELIST_SIZE <= 7) return false;

        if (ADDRESS_8 == addr) return true;
        if (WHITELIST_SIZE <= 8) return false;

        if (ADDRESS_9 == addr) return true;
        if (WHITELIST_SIZE <= 9) return false;

        if (ADDRESS_10 == addr) return true;
        if (WHITELIST_SIZE <= 10) return false;

        if (ADDRESS_11 == addr) return true;
        if (WHITELIST_SIZE <= 11) return false;

        if (ADDRESS_12 == addr) return true;
        if (WHITELIST_SIZE <= 12) return false;

        if (ADDRESS_13 == addr) return true;
        if (WHITELIST_SIZE <= 13) return false;

        if (ADDRESS_14 == addr) return true;
        if (WHITELIST_SIZE <= 14) return false;

        if (ADDRESS_15 == addr) return true;
        if (WHITELIST_SIZE <= 15) return false;

        if (ADDRESS_16 == addr) return true;
        if (WHITELIST_SIZE <= 16) return false;

        if (ADDRESS_17 == addr) return true;
        if (WHITELIST_SIZE <= 17) return false;

        if (ADDRESS_18 == addr) return true;
        if (WHITELIST_SIZE <= 18) return false;

        if (ADDRESS_19 == addr) return true;
        if (WHITELIST_SIZE <= 19) return false;

        return ADDRESS_20 == addr;
    }

    /**
     * @notice Validates that an address is whitelisted, reverting if not
     * @param addr Address to validate
     */
    function validateWhitelisted(address addr) internal view {
        if (!isWhitelisted(addr)) {
            revert AddressNotWhitelisted(addr);
        }
    }

    /**
     * @notice Returns the list of whitelisted addresses
     * @return whitelist Array of whitelisted addresses
     */
    function getWhitelist() public view returns (address[] memory) {
        address[] memory whitelist = new address[](WHITELIST_SIZE);

        if (WHITELIST_SIZE > 0) whitelist[0] = ADDRESS_1;
        if (WHITELIST_SIZE > 1) whitelist[1] = ADDRESS_2;
        if (WHITELIST_SIZE > 2) whitelist[2] = ADDRESS_3;
        if (WHITELIST_SIZE > 3) whitelist[3] = ADDRESS_4;
        if (WHITELIST_SIZE > 4) whitelist[4] = ADDRESS_5;
        if (WHITELIST_SIZE > 5) whitelist[5] = ADDRESS_6;
        if (WHITELIST_SIZE > 6) whitelist[6] = ADDRESS_7;
        if (WHITELIST_SIZE > 7) whitelist[7] = ADDRESS_8;
        if (WHITELIST_SIZE > 8) whitelist[8] = ADDRESS_9;
        if (WHITELIST_SIZE > 9) whitelist[9] = ADDRESS_10;
        if (WHITELIST_SIZE > 10) whitelist[10] = ADDRESS_11;
        if (WHITELIST_SIZE > 11) whitelist[11] = ADDRESS_12;
        if (WHITELIST_SIZE > 12) whitelist[12] = ADDRESS_13;
        if (WHITELIST_SIZE > 13) whitelist[13] = ADDRESS_14;
        if (WHITELIST_SIZE > 14) whitelist[14] = ADDRESS_15;
        if (WHITELIST_SIZE > 15) whitelist[15] = ADDRESS_16;
        if (WHITELIST_SIZE > 16) whitelist[16] = ADDRESS_17;
        if (WHITELIST_SIZE > 17) whitelist[17] = ADDRESS_18;
        if (WHITELIST_SIZE > 18) whitelist[18] = ADDRESS_19;
        if (WHITELIST_SIZE > 19) whitelist[19] = ADDRESS_20;

        return whitelist;
    }

    /**
     * @notice Returns the number of whitelisted addresses
     * @return Number of addresses in the whitelist
     */
    function getWhitelistSize() public view returns (uint256) {
        return WHITELIST_SIZE;
    }
}
