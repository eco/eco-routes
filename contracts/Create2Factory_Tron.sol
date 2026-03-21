// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title Create2Factory_Tron
 * @notice Minimal CREATE2 factory for deterministic deployment testing on Tron
 */
contract Create2Factory_Tron {
    event Deployed(address indexed addr, bytes32 indexed salt);

    /**
     * @notice Deploy a contract using CREATE2
     * @param bytecode The init code of the contract to deploy
     * @param salt Deployment salt
     * @return addr The deployed contract address
     */
    function deploy(bytes memory bytecode, bytes32 salt) external returns (address addr) {
        assembly {
            addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        require(addr != address(0), "Create2Factory: deployment failed");
        emit Deployed(addr, salt);
    }

    /**
     * @notice Predict a CREATE2 address using the standard EVM formula (0xff prefix)
     * @param bytecodeHash keccak256 of the init code
     * @param salt Deployment salt
     * @return Predicted address
     */
    function computeAddress(bytes32 bytecodeHash, bytes32 salt) external view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0x41),
            address(this),
            salt,
            bytecodeHash
        )))));
    }
}
