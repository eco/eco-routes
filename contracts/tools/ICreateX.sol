// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

/**
 * @title ICreateX Interface
 * @notice Interface for CreateX contract functionality
 * @dev This interface provides the essential functions needed from CreateX
 */
interface ICreateX {
    /**
     * @dev Deploys a new contract via calling the `CREATE2` opcode and using the salt value `salt`,
     * the creation bytecode `initCode`, and `msg.value` as inputs.
     * @param salt The 32-byte random value used to create the contract address.
     * @param initCode The creation bytecode.
     * @return newContract The 20-byte address where the contract was deployed.
     */
    function deployCreate2(
        bytes32 salt,
        bytes memory initCode
    ) external payable returns (address newContract);

    /**
     * @dev Deploys a new contract via employing the `CREATE3` pattern (i.e. without an initcode
     * factor) and using the salt value `salt`, the creation bytecode `initCode`, and `msg.value`
     * as inputs.
     * @param salt The 32-byte random value used to create the proxy contract address.
     * @param initCode The creation bytecode.
     * @return newContract The 20-byte address where the contract was deployed.
     */
    function deployCreate3(
        bytes32 salt,
        bytes memory initCode
    ) external payable returns (address newContract);

    /**
     * @dev Returns the address where a contract will be stored if deployed via `deployer` using
     * the `CREATE2` pattern. This function accounts for salt processing done by CreateX.
     * The deployer in this case is the address of the CreateX contract itself.
     * @param salt The 32-byte random value used to create the contract address.
     * @param initCodeHash The keccak256 hash of the creation bytecode.
     * @return computedAddress The 20-byte address where a contract will be stored.
     */
    function computeCreate2Address(
        bytes32 salt,
        bytes32 initCodeHash
    ) external view returns (address computedAddress);

    /**
     * @dev Returns the address where a contract will be stored if deployed via `deployer` using
     * the `CREATE2` pattern. This function accounts for salt processing done by CreateX.
     * @param salt The 32-byte random value used to create the contract address.
     * @param initCodeHash The keccak256 hash of the creation bytecode.
     * @param deployer The 20-byte deployer address.
     * @return computedAddress The 20-byte address where a contract will be stored.
     */
    function computeCreate2Address(
        bytes32 salt,
        bytes32 initCodeHash,
        address deployer
    ) external view returns (address computedAddress);

    /**
     * @dev Returns the address where a contract will be stored if deployed via `deployer` using
     * the `CREATE3` pattern (i.e. without an initcode factor). Any change in the `salt` value will
     * result in a new destination address.
     * @param salt The 32-byte random value used to create the proxy contract address.
     * @param deployer The 20-byte deployer address.
     * @return computedAddress The 20-byte address where a contract will be stored.
     */
    function computeCreate3Address(
        bytes32 salt,
        address deployer
    ) external view returns (address computedAddress);
}
