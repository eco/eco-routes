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

    /// @dev Immutable storage for whitelisted addresses (up to 20)
    address private immutable _whitelist1;
    address private immutable _whitelist2;
    address private immutable _whitelist3;
    address private immutable _whitelist4;
    address private immutable _whitelist5;
    address private immutable _whitelist6;
    address private immutable _whitelist7;
    address private immutable _whitelist8;
    address private immutable _whitelist9;
    address private immutable _whitelist10;
    address private immutable _whitelist11;
    address private immutable _whitelist12;
    address private immutable _whitelist13;
    address private immutable _whitelist14;
    address private immutable _whitelist15;
    address private immutable _whitelist16;
    address private immutable _whitelist17;
    address private immutable _whitelist18;
    address private immutable _whitelist19;
    address private immutable _whitelist20;
    
    /// @dev Number of addresses actually in the whitelist
    uint256 private immutable _whitelistSize;

    /**
     * @notice Initializes the whitelist with a set of addresses
     * @param addresses Array of addresses to whitelist
     */
    constructor(address[] memory addresses) {
        require(addresses.length <= MAX_WHITELIST_SIZE, "Too many addresses for whitelist");
        
        // Store whitelist size
        _whitelistSize = addresses.length;
        
        // Initialize all addresses to zero address
        _whitelist1 = addresses.length > 0 ? addresses[0] : address(0);
        _whitelist2 = addresses.length > 1 ? addresses[1] : address(0);
        _whitelist3 = addresses.length > 2 ? addresses[2] : address(0);
        _whitelist4 = addresses.length > 3 ? addresses[3] : address(0);
        _whitelist5 = addresses.length > 4 ? addresses[4] : address(0);
        _whitelist6 = addresses.length > 5 ? addresses[5] : address(0);
        _whitelist7 = addresses.length > 6 ? addresses[6] : address(0);
        _whitelist8 = addresses.length > 7 ? addresses[7] : address(0);
        _whitelist9 = addresses.length > 8 ? addresses[8] : address(0);
        _whitelist10 = addresses.length > 9 ? addresses[9] : address(0);
        _whitelist11 = addresses.length > 10 ? addresses[10] : address(0);
        _whitelist12 = addresses.length > 11 ? addresses[11] : address(0);
        _whitelist13 = addresses.length > 12 ? addresses[12] : address(0);
        _whitelist14 = addresses.length > 13 ? addresses[13] : address(0);
        _whitelist15 = addresses.length > 14 ? addresses[14] : address(0);
        _whitelist16 = addresses.length > 15 ? addresses[15] : address(0);
        _whitelist17 = addresses.length > 16 ? addresses[16] : address(0);
        _whitelist18 = addresses.length > 17 ? addresses[17] : address(0);
        _whitelist19 = addresses.length > 18 ? addresses[18] : address(0);
        _whitelist20 = addresses.length > 19 ? addresses[19] : address(0);
    }

    /**
     * @notice Checks if an address is whitelisted
     * @param addr Address to check
     * @return True if the address is whitelisted, false otherwise
     */
    function isWhitelisted(address addr) public view returns (bool) {
        // Short circuit check for empty whitelist
        if (_whitelistSize == 0) return false;
        
        // Short circuit check for zero address
        if (addr == address(0)) return false;
        
        // Check against each stored address
        // Exit early when we hit an empty address slot
        address slot;
        
        slot = _whitelist1;
        if (slot == address(0)) return false;
        if (slot == addr) return true;
        if (_whitelistSize <= 1) return false;
        
        slot = _whitelist2;
        if (slot == address(0)) return false;
        if (slot == addr) return true;
        if (_whitelistSize <= 2) return false;
        
        slot = _whitelist3;
        if (slot == address(0)) return false;
        if (slot == addr) return true;
        if (_whitelistSize <= 3) return false;
        
        slot = _whitelist4;
        if (slot == address(0)) return false;
        if (slot == addr) return true;
        if (_whitelistSize <= 4) return false;
        
        slot = _whitelist5;
        if (slot == address(0)) return false;
        if (slot == addr) return true;
        if (_whitelistSize <= 5) return false;
        
        slot = _whitelist6;
        if (slot == address(0)) return false;
        if (slot == addr) return true;
        if (_whitelistSize <= 6) return false;
        
        slot = _whitelist7;
        if (slot == address(0)) return false;
        if (slot == addr) return true;
        if (_whitelistSize <= 7) return false;
        
        slot = _whitelist8;
        if (slot == address(0)) return false;
        if (slot == addr) return true;
        if (_whitelistSize <= 8) return false;
        
        slot = _whitelist9;
        if (slot == address(0)) return false;
        if (slot == addr) return true;
        if (_whitelistSize <= 9) return false;
        
        slot = _whitelist10;
        if (slot == address(0)) return false;
        if (slot == addr) return true;
        if (_whitelistSize <= 10) return false;
        
        slot = _whitelist11;
        if (slot == address(0)) return false;
        if (slot == addr) return true;
        if (_whitelistSize <= 11) return false;
        
        slot = _whitelist12;
        if (slot == address(0)) return false;
        if (slot == addr) return true;
        if (_whitelistSize <= 12) return false;
        
        slot = _whitelist13;
        if (slot == address(0)) return false;
        if (slot == addr) return true;
        if (_whitelistSize <= 13) return false;
        
        slot = _whitelist14;
        if (slot == address(0)) return false;
        if (slot == addr) return true;
        if (_whitelistSize <= 14) return false;
        
        slot = _whitelist15;
        if (slot == address(0)) return false;
        if (slot == addr) return true;
        if (_whitelistSize <= 15) return false;
        
        slot = _whitelist16;
        if (slot == address(0)) return false;
        if (slot == addr) return true;
        if (_whitelistSize <= 16) return false;
        
        slot = _whitelist17;
        if (slot == address(0)) return false;
        if (slot == addr) return true;
        if (_whitelistSize <= 17) return false;
        
        slot = _whitelist18;
        if (slot == address(0)) return false;
        if (slot == addr) return true;
        if (_whitelistSize <= 18) return false;
        
        slot = _whitelist19;
        if (slot == address(0)) return false;
        if (slot == addr) return true;
        if (_whitelistSize <= 19) return false;
        
        slot = _whitelist20;
        if (slot == address(0)) return false;
        return slot == addr;
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
        address[] memory whitelist = new address[](_whitelistSize);
        
        if (_whitelistSize > 0) whitelist[0] = _whitelist1;
        if (_whitelistSize > 1) whitelist[1] = _whitelist2;
        if (_whitelistSize > 2) whitelist[2] = _whitelist3;
        if (_whitelistSize > 3) whitelist[3] = _whitelist4;
        if (_whitelistSize > 4) whitelist[4] = _whitelist5;
        if (_whitelistSize > 5) whitelist[5] = _whitelist6;
        if (_whitelistSize > 6) whitelist[6] = _whitelist7;
        if (_whitelistSize > 7) whitelist[7] = _whitelist8;
        if (_whitelistSize > 8) whitelist[8] = _whitelist9;
        if (_whitelistSize > 9) whitelist[9] = _whitelist10;
        if (_whitelistSize > 10) whitelist[10] = _whitelist11;
        if (_whitelistSize > 11) whitelist[11] = _whitelist12;
        if (_whitelistSize > 12) whitelist[12] = _whitelist13;
        if (_whitelistSize > 13) whitelist[13] = _whitelist14;
        if (_whitelistSize > 14) whitelist[14] = _whitelist15;
        if (_whitelistSize > 15) whitelist[15] = _whitelist16;
        if (_whitelistSize > 16) whitelist[16] = _whitelist17;
        if (_whitelistSize > 17) whitelist[17] = _whitelist18;
        if (_whitelistSize > 18) whitelist[18] = _whitelist19;
        if (_whitelistSize > 19) whitelist[19] = _whitelist20;
        
        return whitelist;
    }
    
    /**
     * @notice Returns the number of whitelisted addresses
     * @return Number of addresses in the whitelist
     */
    function getWhitelistSize() public view returns (uint256) {
        return _whitelistSize;
    }
}