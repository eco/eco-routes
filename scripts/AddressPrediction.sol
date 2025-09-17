// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ICreate3Deployer} from "../contracts/tools/ICreate3Deployer.sol";
import {ICreateX} from "../contracts/tools/ICreateX.sol";

/**
 * @title AddressPrediction
 * @notice Library for predicting contract addresses using CREATE2/CREATE3 across different chains
 * @dev Supports both standard Create3Deployer and CreateX deployment systems
 */
library AddressPrediction {
    // Chain constants
    uint256 constant TRON_MAINNET_CHAIN_ID = 728126428;
    uint256 constant TRON_SHASTA_CHAIN_ID = 2494104990;
    uint256 constant TRON_NILE_CHAIN_ID = 3448148188;
    uint256 constant WORLD_CHAIN_ID = 480;
    uint256 constant PLASMA_CHAIN_ID = 9745;

    // Factory addresses
    address constant CREATE2_FACTORY =
        0xce0042B868300000d44A59004Da54A005ffdcf9f;
    address constant CREATE3_DEPLOYER =
        0xC6BAd1EbAF366288dA6FB5689119eDd695a66814;
    address constant CREATEX_CONTRACT =
        0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

    /**
     * @notice Generate a salt for a specific contract name
     * @param rootSalt The base salt
     * @param contractName The name of the contract
     * @return The generated salt
     */
    function getContractSalt(
        bytes32 rootSalt,
        string memory contractName
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(rootSalt, keccak256(abi.encodePacked(contractName)))
            );
    }

    /**
     * @notice Determine if a chain uses CreateX for deployment
     * @param chainId The chain ID to check
     * @return True if the chain uses CreateX
     */
    function useCreateXForChainID(
        uint256 chainId
    ) internal pure returns (bool) {
        return chainId == WORLD_CHAIN_ID || chainId == PLASMA_CHAIN_ID;
    }

    /**
     * @notice Check if a chain is a Tron chain
     * @param chainId The chain ID to check
     * @return True if the chain is Tron
     */
    function isTronChain(uint256 chainId) internal pure returns (bool) {
        return
            chainId == TRON_MAINNET_CHAIN_ID ||
            chainId == TRON_SHASTA_CHAIN_ID ||
            chainId == TRON_NILE_CHAIN_ID;
    }

    /**
     * @notice Predict CREATE3 address for any chain
     * @param chainId The chain ID
     * @param salt The salt for deployment
     * @param deployer The deployer address
     * @return The predicted address
     */
    function predictCreate3Address(
        uint256 chainId,
        bytes32 salt,
        address deployer
    ) internal pure returns (address) {
        if (useCreateXForChainID(chainId)) {
            return computeCreateXCreate3Address(salt, deployer);
        } else {
            return computeCreate3DeployerAddress(salt, deployer);
        }
    }

    /**
     * @notice Compute CREATE3 address using CreateX
     * @param salt The salt
     * @param deployer The deployer address
     * @return The predicted address
     */
    function computeCreateXCreate3Address(
        bytes32 salt,
        address deployer
    ) internal pure returns (address) {
        // CreateX uses a guarded salt that includes the deployer
        bytes32 guardedSalt = keccak256(abi.encodePacked(deployer, salt));

        // First, compute the proxy address using CREATE2
        bytes memory proxyBytecode = getCreate3ProxyBytecode();
        address proxy = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            CREATEX_CONTRACT,
                            guardedSalt,
                            keccak256(proxyBytecode)
                        )
                    )
                )
            )
        );

        // Then compute the final address (deployed via proxy with CREATE and nonce 1)
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                bytes1(0xd6),
                                bytes1(0x94),
                                proxy,
                                bytes1(0x01)
                            )
                        )
                    )
                )
            );
    }

    /**
     * @notice Compute CREATE3 address using standard Create3Deployer
     * @param salt The salt
     * @param deployer The deployer address
     * @return The predicted address
     */
    function computeCreate3DeployerAddress(
        bytes32 salt,
        address deployer
    ) internal pure returns (address) {
        // Create outer salt
        bytes32 outerSalt = keccak256(abi.encodePacked(deployer, salt));

        // First, compute the proxy address
        bytes memory proxyBytecode = getCreate3ProxyBytecode();
        address proxy = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            CREATE3_DEPLOYER,
                            outerSalt,
                            keccak256(proxyBytecode)
                        )
                    )
                )
            )
        );

        // Then compute the final address (deployed via proxy with CREATE and nonce 1)
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                bytes1(0xd6),
                                bytes1(0x94),
                                proxy,
                                bytes1(0x01)
                            )
                        )
                    )
                )
            );
    }

    /**
     * @notice Predict CREATE2 address with standard prefix
     * @param bytecode The contract bytecode
     * @param salt The salt
     * @param factory The factory address
     * @return The predicted address
     */
    function predictCreate2Address(
        bytes memory bytecode,
        bytes32 salt,
        address factory
    ) internal pure returns (address) {
        return
            predictCreate2AddressWithPrefix(
                bytecode,
                salt,
                factory,
                bytes1(0xff)
            );
    }

    /**
     * @notice Predict CREATE2 address with custom prefix (for Tron support)
     * @param bytecode The contract bytecode
     * @param salt The salt
     * @param factory The factory address
     * @param prefix The prefix byte
     * @return The predicted address
     */
    function predictCreate2AddressWithPrefix(
        bytes memory bytecode,
        bytes32 salt,
        address factory,
        bytes1 prefix
    ) internal pure returns (address) {
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                prefix,
                                factory,
                                salt,
                                keccak256(bytecode)
                            )
                        )
                    )
                )
            );
    }

    /**
     * @notice Predict CREATE2 address for any chain (with chain-specific handling)
     * @param chainId The chain ID
     * @param bytecode The contract bytecode
     * @param salt The salt
     * @return The predicted address
     */
    function predictCreate2AddressForChain(
        uint256 chainId,
        bytes memory bytecode,
        bytes32 salt
    ) internal pure returns (address) {
        if (useCreateXForChainID(chainId)) {
            // Use CreateX for World Chain and Plasma
            bytes32 processedSalt = keccak256(abi.encode(salt));
            bytes32 initCodeHash = keccak256(bytecode);

            // This is a simplified version - actual CreateX logic may be more complex
            return
                address(
                    uint160(
                        uint256(
                            keccak256(
                                abi.encodePacked(
                                    bytes1(0xff),
                                    CREATEX_CONTRACT,
                                    processedSalt,
                                    initCodeHash
                                )
                            )
                        )
                    )
                );
        } else if (isTronChain(chainId)) {
            // Use custom prefix for Tron chains
            return
                predictCreate2AddressWithPrefix(
                    bytecode,
                    salt,
                    CREATE2_FACTORY,
                    bytes1(0x41)
                );
        } else {
            // Use standard CREATE2 for other chains
            return predictCreate2Address(bytecode, salt, CREATE2_FACTORY);
        }
    }

    /**
     * @notice Get the standard CREATE3 proxy bytecode
     * @return The proxy bytecode
     */
    function getCreate3ProxyBytecode() internal pure returns (bytes memory) {
        // This is the standard CREATE3 proxy bytecode used by both systems
        return hex"67363d3d37363d34f03d5260086018f3";
    }

    /**
     * @notice Get the CREATE3 deployer bytecode
     * @return The deployer bytecode
     */
    function getCreate3DeployerBytecode() internal pure returns (bytes memory) {
        // This is the bytecode for the CREATE3 deployer contract
        return
            hex"60a060405234801561001057600080fd5b5060405161002060208201610044565b601f1982820381018352601f90910116604052805160209190910120608052610051565b6101a080610ccf83390190565b608051610c5c610073600039600081816103d701526105410152610c5c6000f3fe6080604052600436106100345760003560e01c80634af63f0214610039578063c2b1041c14610075578063cf4d643214610095575b600080fd5b61004c6100473660046108b7565b6100a8565b60405173ffffffffffffffffffffffffffffffffffffffff909116815260200160405180910390f35b34801561008157600080fd5b5061004c6100903660046108fc565b61018c565b61004c6100a336600461096f565b6101e5565b6040805133602082015290810182905260009081906060016040516020818303038152906040528051906020012090506100e28482610372565b9150341561010a5761010a73ffffffffffffffffffffffffffffffffffffffff83163461048b565b61011484826104d5565b9150823373ffffffffffffffffffffffffffffffffffffffff168373ffffffffffffffffffffffffffffffffffffffff167fd579261046780ec80c4dae1bc57abdb62c58df8af1531e63b4e8bcc08bcf46ec878051906020012060405161017d91815260200190565b60405180910390a45092915050565b6040805173ffffffffffffffffffffffffffffffffffffffff8416602082015290810182905260009081906060016040516020818303038152906040528051906020012090506101dc8582610372565b95945050505050565b60408051336020820152908101849052600090819060600160405160208183030381529060405280519060200120905061021f8682610372565b915034156102475761024773ffffffffffffffffffffffffffffffffffffffff83163461048b565b61025186826104d5565b9150843373ffffffffffffffffffffffffffffffffffffffff168373ffffffffffffffffffffffffffffffffffffffff167fd579261046780ec80c4dae1bc57abdb62c58df8af1531e63b4e8bcc08bcf46ec89805190602001206040516102ba91815260200190565b60405180910390a460008273ffffffffffffffffffffffffffffffffffffffff1685856040516102eb929190610a0a565b6000604051808303816000865af19150503d8060008114610328576040519150601f19603f3d011682016040523d82523d6000602084013e61032d565b606091505b5050905080610368576040517f139c636700000000000000000000000000000000000000000000000000000000815260040160405180910390fd5b5050949350505050565b604080517fff000000000000000000000000000000000000000000000000000000000000006020808301919091527fffffffffffffffffffffffffffffffffffffffff00000000000000000000000030606090811b82166021850152603584018690527f0000000000000000000000000000000000000000000000000000000000000000605580860191909152855180860390910181526075850186528051908401207fd6940000000000000000000000000000000000000000000000000000000000006095860152901b1660978301527f010000000000000000000000000000000000000000000000000000000000000060ab8301528251808303608c01815260ac90920190925280519101206000905b9392505050565b600080600080600085875af19050806104d0576040517ff4b3b1bc00000000000000000000000000000000000000000000000000000000815260040160405180910390fd5b505050565b60006104848383604080517fff000000000000000000000000000000000000000000000000000000000000006020808301919091527fffffffffffffffffffffffffffffffffffffffff00000000000000000000000030606090811b82166021850152603584018690527f0000000000000000000000000000000000000000000000000000000000000000605580860191909152855180860390910181526075850186528051908401207fd6940000000000000000000000000000000000000000000000000000000000006095860152901b1660978301527f010000000000000000000000000000000000000000000000000000000000000060ab8301528251808303608c01815260ac90920190925280519101208251600003610625576040517f21744a5900000000000000000000000000000000000000000000000000000000815260040160405180910390fd5b6106448173ffffffffffffffffffffffffffffffffffffffff16610783565b1561067b576040517fa6ef0ba100000000000000000000000000000000000000000000000000000000815260040160405180910390fd5b60008260405161068a906107d0565b8190604051809103906000f59050801580156106aa573d6000803e3d6000fd5b50905073ffffffffffffffffffffffffffffffffffffffff81166106fa576040517fb4f5411100000000000000000000000000000000000000000000000000000000815260040160405180910390fd5b6040517e77436000000000000000000000000000000000000000000000000000000000815273ffffffffffffffffffffffffffffffffffffffff821690627743609061074a908790600401610a1a565b600060405180830381600087803b15801561076457600080fd5b505af1158015610778573d6000803e3d6000fd5b505050505092915050565b600073ffffffffffffffffffffffffffffffffffffffff82163f801580159061048457507fc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470141592915050565b6101a080610a8783390190565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052604160045260246000fd5b600082601f83011261081d57600080fd5b813567ffffffffffffffff80821115610838576108386107dd565b604051601f83017fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0908116603f0116810190828211818310171561087e5761087e6107dd565b8160405283815286602085880101111561089757600080fd5b836020870160208301376000602085830101528094505050505092915050565b600080604083850312156108ca57600080fd5b823567ffffffffffffffff8111156108e157600080fd5b6108ed8582860161080c565b95602094909401359450505050565b60008060006060848603121561091157600080fd5b833567ffffffffffffffff81111561092857600080fd5b6109348682870161080c565b935050602084013573ffffffffffffffffffffffffffffffffffffffff8116811461095e57600080fd5b929592945050506040919091013590565b6000806000806060858703121561098557600080fd5b843567ffffffffffffffff8082111561099d57600080fd5b6109a98883890161080c565b95506020870135945060408701359150808211156109c657600080fd5b818701915087601f8301126109da57600080fd5b8135818111156109e957600080fd5b8860208285010111156109fb57600080fd5b95989497505060200194505050565b8183823760009101908152919050565b600060208083528351808285015260005b81811015610a4757858101830151858201604001528201610a2b565b5060006040828601015260407fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0601f830116850101925050509291505056fe608060405234801561001057600080fd5b50610180806100206000396000f3fe60806040526004361061001d5760003560e01c806277436014610022575b600080fd5b61003561003036600461007b565b610037565b005b8051602082016000f061004957600080fd5b50565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052604160045260246000fd5b60006020828403121561008d57600080fd5b813567ffffffffffffffff808211156100a557600080fd5b818401915084601f8301126100b957600080fd5b8135818111156100cb576100cb61004c565b604051601f82017fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0908116603f011681019083821181831017156101115761011161004c565b8160405282815287602084870101111561012a57600080fd5b82602086016020830137600092810160200192909252509594505050505056fea2646970667358221220a30aa0b079a504f6336b7e339659f909f468dcfe513766d3086e1efce2657d5164736f6c63430008130033a26469706673582212203a8a2818751a76f13bac296ad23080c23254ec57b82f46e2953af00c5cc5ecb464736f6c63430008130033608060405234801561001057600080fd5b50610180806100206000396000f3fe60806040526004361061001d5760003560e01c806277436014610022575b600080fd5b61003561003036600461007b565b610037565b005b8051602082016000f061004957600080fd5b50565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052604160045260246000fd5b60006020828403121561008d57600080fd5b813567ffffffffffffffff808211156100a557600080fd5b818401915084601f8301126100b957600080fd5b8135818111156100cb576100cb61004c565b604051601f82017fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0908116603f011681019083821181831017156101115761011161004c565b8160405282815287602084870101111561012a57600080fd5b82602086016020830137600092810160200192909252509594505050505056fea2646970667358221220a30aa0b079a504f6336b7e339659f909f468dcfe513766d3086e1efce2657d5164736f6c63430008130033";
    }
}
