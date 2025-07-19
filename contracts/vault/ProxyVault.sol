/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Reward} from "../types/Intent.sol";

import {IVault} from "../interfaces/IVault.sol";

/**
 * @title VaultProxy
 * @notice Proxy contract for the Vault to handle cross-chain deposits
 * @dev This contract is used to receive deposits from Axelar and forward them to the Vault
 */
contract ProxyVault is IVault {
    address public immutable implementation;
    bytes32 public immutable intentHash;

    constructor(
        address _implementation,
        bytes32 _intentHash,
        uint64 destination,
        bytes32 routeHash,
        Reward memory reward
    ) {
        implementation = _implementation;
        intentHash = _intentHash;

        // Delegate call to the implementation contract to execute the operation
        _delegateCall(
            _implementation,
            _intentHash,
            destination,
            routeHash,
            reward
        );
    }

    /**
     * @notice Executes the operate function on the Vault implementation
     * @dev This function is used if self-destruct is deprecated by a chain
     * @param destination The destination chain ID
     * @param routeHash The hash of the route to execute
     * @param reward The reward structure containing details for the operation
     */
    function operate(
        bytes32 _intentHash,
        uint64 destination,
        bytes32 routeHash,
        Reward memory reward
    ) public payable {
        require(
            intentHash == _intentHash,
            InvalidIntentHash(intentHash, _intentHash)
        );

        _delegateCall(
            implementation,
            _intentHash,
            destination,
            routeHash,
            reward
        );
    }

    function _delegateCall(
        address _implementation,
        bytes32 _intentHash,
        uint64 destination,
        bytes32 routeHash,
        Reward memory reward
    ) internal {
        (bool success, ) = _implementation.delegatecall(
            abi.encodeWithSelector(
                this.operate.selector,
                _intentHash,
                destination,
                routeHash,
                reward
            )
        );

        // revert with the original data
        if (!success) {
            assembly {
                let ptr := mload(0x40)
                let size := returndatasize()
                returndatacopy(ptr, 0, size)
                revert(ptr, size)
            }
        }
    }

    // @notice Fallback function to receive Ether
    receive() external payable {}
}
