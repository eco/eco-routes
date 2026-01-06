// Source: contracts/deploy/Create3Deployer.sol

pragma solidity ^0.8.0;

// SPDX-License-Identifier: MIT

// File contracts/deploy/CreateDeploy.sol

/**
 * @title CreateDeploy Contract
 * @notice This contract deploys new contracts using the `CREATE` opcode and is used as part of
 * the `CREATE3` deployment method.
 */
contract CreateDeploy {
    /**
     * @dev Deploys a new contract with the specified bytecode using the `CREATE` opcode.
     * @param bytecode The bytecode of the contract to be deployed
     */
    // slither-disable-next-line locked-ether
    function deploy(bytes memory bytecode) external payable {
        assembly {
            if iszero(create(0, add(bytecode, 32), mload(bytecode))) {
                revert(0, 0)
            }
        }
    }
}

// File contracts/deploy/Create3Address.sol

/**
 * @title Create3Address contract
 * @notice This contract can be used to predict the deterministic deployment address of a contract deployed with the `CREATE3` technique.
 */
contract Create3Address {
    /// @dev bytecode hash of the CreateDeploy helper contract
    bytes32 internal immutable createDeployBytecodeHash;

    constructor() {
        createDeployBytecodeHash = keccak256(type(CreateDeploy).creationCode);
    }

    /**
     * @notice Compute the deployed address that will result from the `CREATE3` method.
     * @param deploySalt A salt to influence the contract address
     * @return deployed The deterministic contract address if it was deployed
     */
    function _create3Address(bytes32 deploySalt) internal view returns (address deployed) {
        address deployer = address(
            uint160(uint256(keccak256(abi.encodePacked(hex'ff', address(this), deploySalt, createDeployBytecodeHash))))
        );

        deployed = address(uint160(uint256(keccak256(abi.encodePacked(hex'd6_94', deployer, hex'01')))));
    }
}

// File contracts/interfaces/IDeploy.sol

/**
 * @title IDeploy Interface
 * @notice This interface defines the errors for a contract that is responsible for deploying new contracts.
 */
interface IDeploy {
    error EmptyBytecode();
    error AlreadyDeployed();
    error DeployFailed();
}

// File contracts/libs/ContractAddress.sol

library ContractAddress {
    function isContract(address contractAddress) internal view returns (bool) {
        bytes32 existingCodeHash = contractAddress.codehash;

        // https://eips.ethereum.org/EIPS/eip-1052
        // keccak256('') == 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
        return
            existingCodeHash != bytes32(0) &&
            existingCodeHash != 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
    }
}

// File contracts/deploy/Create3.sol

/**
 * @title Create3 contract
 * @notice This contract can be used to deploy a contract with a deterministic address that depends only on
 * the deployer address and deployment salt, not the contract bytecode and constructor parameters.
 */
contract Create3 is Create3Address, IDeploy {
    using ContractAddress for address;

    /**
     * @notice Deploys a new contract using the `CREATE3` method.
     * @dev This function first deploys the CreateDeploy contract using
     * the `CREATE2` opcode and then utilizes the CreateDeploy to deploy the
     * new contract with the `CREATE` opcode.
     * @param bytecode The bytecode of the contract to be deployed
     * @param deploySalt A salt to influence the contract address
     * @return deployed The address of the deployed contract
     */
    function _create3(bytes memory bytecode, bytes32 deploySalt) internal returns (address deployed) {
        deployed = _create3Address(deploySalt);

        if (bytecode.length == 0) revert EmptyBytecode();
        if (deployed.isContract()) revert AlreadyDeployed();

        // Deploy using create2
        CreateDeploy create = new CreateDeploy{ salt: deploySalt }();

        if (address(create) == address(0)) revert DeployFailed();

        // Deploy using create
        create.deploy(bytecode);
    }
}

// File contracts/interfaces/IDeployer.sol

/**
 * @title IDeployer Interface
 * @notice This interface defines the contract responsible for deploying and optionally initializing new contracts
 *  via a specified deployment method.
 */
interface IDeployer is IDeploy {
    error DeployInitFailed();

    event Deployed(address indexed deployedAddress, address indexed sender, bytes32 indexed salt, bytes32 bytecodeHash);

    /**
     * @notice Deploys a contract using a deployment method defined by derived contracts.
     * @param bytecode The bytecode of the contract to be deployed
     * @param salt A salt to influence the contract address
     * @return deployedAddress_ The address of the deployed contract
     */
    function deploy(bytes memory bytecode, bytes32 salt) external payable returns (address deployedAddress_);

    /**
     * @notice Deploys a contract using a deployment method defined by derived contracts and initializes it.
     * @param bytecode The bytecode of the contract to be deployed
     * @param salt A salt to influence the contract address
     * @param init Init data used to initialize the deployed contract
     * @return deployedAddress_ The address of the deployed contract
     */
    function deployAndInit(
        bytes memory bytecode,
        bytes32 salt,
        bytes calldata init
    ) external payable returns (address deployedAddress_);

    /**
     * @notice Returns the address where a contract will be stored if deployed via {deploy} or {deployAndInit} by `sender`.
     * @param bytecode The bytecode of the contract
     * @param sender The address that will deploy the contract
     * @param salt The salt that will be used to influence the contract address
     * @return deployedAddress_ The address that the contract will be deployed to
     */
    function deployedAddress(
        bytes calldata bytecode,
        address sender,
        bytes32 salt
    ) external view returns (address deployedAddress_);
}

// File contracts/libs/SafeNativeTransfer.sol

error NativeTransferFailed();

/*
 * @title SafeNativeTransfer
 * @dev This library is used for performing safe native value transfers in Solidity by utilizing inline assembly.
 */
library SafeNativeTransfer {
    /*
     * @notice Perform a native transfer to a given address.
     * @param receiver The recipient address to which the amount will be sent.
     * @param amount The amount of native value to send.
     * @throws NativeTransferFailed error if transfer is not successful.
     */
    function safeNativeTransfer(address receiver, uint256 amount) internal {
        bool success;

        assembly {
            success := call(gas(), receiver, amount, 0, 0, 0, 0)
        }

        if (!success) revert NativeTransferFailed();
    }
}

// File contracts/deploy/Deployer.sol

/**
 * @title Deployer Contract
 * @notice This contract is responsible for deploying and initializing new contracts using
 * a deployment method, such as `CREATE2` or `CREATE3`.
 */
abstract contract Deployer is IDeployer {
    using SafeNativeTransfer for address;

    /**
     * @notice Deploys a contract using a deployment method defined by derived contracts.
     * @dev The address where the contract will be deployed can be known in
     * advance via {deployedAddress}.
     *
     * The bytecode for a contract can be obtained from Solidity with
     * `type(contractName).creationCode`.
     *
     * Requirements:
     *
     * - `bytecode` must not be empty.
     * - `salt` must have not been used for `bytecode` already by the same `msg.sender`.
     *
     * @param bytecode The bytecode of the contract to be deployed
     * @param salt A salt to influence the contract address
     * @return deployedAddress_ The address of the deployed contract
     */
    // slither-disable-next-line locked-ether
    function deploy(bytes memory bytecode, bytes32 salt) external payable returns (address deployedAddress_) {
        bytes32 deploySalt = keccak256(abi.encode(msg.sender, salt));
        deployedAddress_ = _deployedAddress(bytecode, deploySalt);

        if (msg.value > 0) {
            // slither-disable-next-line unused-return
            deployedAddress_.safeNativeTransfer(msg.value);
        }

        deployedAddress_ = _deploy(bytecode, deploySalt);

        emit Deployed(deployedAddress_, msg.sender, salt, keccak256(bytecode));
    }

    /**
     * @notice Deploys a contract using a deployment method defined by derived contracts and initializes it.
     * @dev The address where the contract will be deployed can be known in advance
     * via {deployedAddress}.
     *
     * The bytecode for a contract can be obtained from Solidity with
     * `type(contractName).creationCode`.
     *
     * Requirements:
     *
     * - `bytecode` must not be empty.
     * - `salt` must have not been used for `bytecode` already by the same `msg.sender`.
     * - `init` is used to initialize the deployed contract as an option to not have the
     *    constructor args affect the address derived by `CREATE2`.
     *
     * @param bytecode The bytecode of the contract to be deployed
     * @param salt A salt to influence the contract address
     * @param init Init data used to initialize the deployed contract
     * @return deployedAddress_ The address of the deployed contract
     */
    // slither-disable-next-line locked-ether
    function deployAndInit(
        bytes memory bytecode,
        bytes32 salt,
        bytes calldata init
    ) external payable returns (address deployedAddress_) {
        bytes32 deploySalt = keccak256(abi.encode(msg.sender, salt));
        deployedAddress_ = _deployedAddress(bytecode, deploySalt);

        if (msg.value > 0) {
            // slither-disable-next-line unused-return
            deployedAddress_.safeNativeTransfer(msg.value);
        }

        deployedAddress_ = _deploy(bytecode, deploySalt);

        emit Deployed(deployedAddress_, msg.sender, salt, keccak256(bytecode));

        (bool success, ) = deployedAddress_.call(init);
        if (!success) revert DeployInitFailed();
    }

    /**
     * @notice Returns the address where a contract will be stored if deployed via {deploy} or {deployAndInit} by `sender`.
     * @dev Any change in the `bytecode` (except for `CREATE3`), `sender`, or `salt` will result in a new deployed address.
     * @param bytecode The bytecode of the contract to be deployed
     * @param sender The address that will deploy the contract via the deployment method
     * @param salt The salt that will be used to influence the contract address
     * @return deployedAddress_ The address that the contract will be deployed to
     */
    function deployedAddress(
        bytes memory bytecode,
        address sender,
        bytes32 salt
    ) public view returns (address) {
        bytes32 deploySalt = keccak256(abi.encode(sender, salt));
        return _deployedAddress(bytecode, deploySalt);
    }

    function _deploy(bytes memory bytecode, bytes32 deploySalt) internal virtual returns (address);

    function _deployedAddress(bytes memory bytecode, bytes32 deploySalt) internal view virtual returns (address);
}

// File contracts/deploy/Create3Deployer.sol

/**
 * @title Create3Deployer Contract
 * @notice This contract is responsible for deploying and initializing new contracts using the `CREATE3` method
 * which computes the deployed contract address based on the deployer address and deployment salt.
 */
contract Create3Deployer is Create3, Deployer {
    function _deploy(bytes memory bytecode, bytes32 deploySalt) internal override returns (address) {
        return _create3(bytecode, deploySalt);
    }

    function _deployedAddress(
        bytes memory, /* bytecode */
        bytes32 deploySalt
    ) internal view override returns (address) {
        return _create3Address(deploySalt);
    }
}
