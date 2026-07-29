// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title MockERC1271Wallet
 * @notice Minimal ERC-1271 smart contract wallet used in tests.
 * @dev Returns the ERC-1271 magic value (0x1626ba7e) when `signature` is a
 *      valid ECDSA signature over `hash` produced by the stored `owner`,
 *      and a non-magic value otherwise. This mirrors how a real contract
 *      wallet (e.g. a single-owner Safe) would validate a signature.
 */
contract MockERC1271Wallet {
    using ECDSA for bytes32;

    /// @notice ERC-1271 magic value returned for a valid signature
    bytes4 internal constant MAGIC_VALUE = 0x1626ba7e;

    /// @notice Sentinel value returned for an invalid signature
    bytes4 internal constant INVALID_VALUE = 0xffffffff;

    /// @notice The EOA authorized to sign on behalf of this wallet
    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }

    /**
     * @notice ERC-1271 signature validation
     * @param hash The digest that was signed
     * @param signature The signature to validate
     * @return magicValue 0x1626ba7e when valid, 0xffffffff otherwise
     */
    function isValidSignature(
        bytes32 hash,
        bytes calldata signature
    ) external view returns (bytes4 magicValue) {
        (address recovered, ECDSA.RecoverError err, ) = hash.tryRecover(
            signature
        );
        if (err == ECDSA.RecoverError.NoError && recovered == owner) {
            return MAGIC_VALUE;
        }
        return INVALID_VALUE;
    }
}
