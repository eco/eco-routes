pragma solidity ^0.8.0;

// Forge
import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

// Tools
import {SingletonFactory} from "../contracts/tools/SingletonFactory.sol";
import {ICreate3Deployer} from "../contracts/tools/ICreate3Deployer.sol";
import {ICreateX} from "../contracts/tools/ICreateX.sol";

// Protocol
import {Portal} from "../contracts/Portal.sol";
import {HyperProver} from "../contracts/prover/HyperProver.sol";
import {PolymerProver} from "../contracts/prover/PolymerProver.sol";
import {MetaProver} from "../contracts/prover/MetaProver.sol";

contract Deploy is Script {
    bytes constant CREATE3_DEPLOYER_BYTECODE =
        hex"60a060405234801561001057600080fd5b5060405161002060208201610044565b601f1982820381018352601f90910116604052805160209190910120608052610051565b6101a080610ccf83390190565b608051610c5c610073600039600081816103d701526105410152610c5c6000f3fe6080604052600436106100345760003560e01c80634af63f0214610039578063c2b1041c14610075578063cf4d643214610095575b600080fd5b61004c6100473660046108b7565b6100a8565b60405173ffffffffffffffffffffffffffffffffffffffff909116815260200160405180910390f35b34801561008157600080fd5b5061004c6100903660046108fc565b61018c565b61004c6100a336600461096f565b6101e5565b6040805133602082015290810182905260009081906060016040516020818303038152906040528051906020012090506100e28482610372565b9150341561010a5761010a73ffffffffffffffffffffffffffffffffffffffff83163461048b565b61011484826104d5565b9150823373ffffffffffffffffffffffffffffffffffffffff168373ffffffffffffffffffffffffffffffffffffffff167fd579261046780ec80c4dae1bc57abdb62c58df8af1531e63b4e8bcc08bcf46ec878051906020012060405161017d91815260200190565b60405180910390a45092915050565b6040805173ffffffffffffffffffffffffffffffffffffffff8416602082015290810182905260009081906060016040516020818303038152906040528051906020012090506101dc8582610372565b95945050505050565b60408051336020820152908101849052600090819060600160405160208183030381529060405280519060200120905061021f8682610372565b915034156102475761024773ffffffffffffffffffffffffffffffffffffffff83163461048b565b61025186826104d5565b9150843373ffffffffffffffffffffffffffffffffffffffff168373ffffffffffffffffffffffffffffffffffffffff167fd579261046780ec80c4dae1bc57abdb62c58df8af1531e63b4e8bcc08bcf46ec89805190602001206040516102ba91815260200190565b60405180910390a460008273ffffffffffffffffffffffffffffffffffffffff1685856040516102eb929190610a0a565b6000604051808303816000865af19150503d8060008114610328576040519150601f19603f3d011682016040523d82523d6000602084013e61032d565b606091505b5050905080610368576040517f139c636700000000000000000000000000000000000000000000000000000000815260040160405180910390fd5b5050949350505050565b604080517fff000000000000000000000000000000000000000000000000000000000000006020808301919091527fffffffffffffffffffffffffffffffffffffffff00000000000000000000000030606090811b82166021850152603584018690527f0000000000000000000000000000000000000000000000000000000000000000605580860191909152855180860390910181526075850186528051908401207fd6940000000000000000000000000000000000000000000000000000000000006095860152901b1660978301527f010000000000000000000000000000000000000000000000000000000000000060ab8301528251808303608c01815260ac90920190925280519101206000905b9392505050565b600080600080600085875af19050806104d0576040517ff4b3b1bc00000000000000000000000000000000000000000000000000000000815260040160405180910390fd5b505050565b60006104848383604080517fff000000000000000000000000000000000000000000000000000000000000006020808301919091527fffffffffffffffffffffffffffffffffffffffff00000000000000000000000030606090811b82166021850152603584018690527f0000000000000000000000000000000000000000000000000000000000000000605580860191909152855180860390910181526075850186528051908401207fd6940000000000000000000000000000000000000000000000000000000000006095860152901b1660978301527f010000000000000000000000000000000000000000000000000000000000000060ab8301528251808303608c01815260ac90920190925280519101208251600003610625576040517f21744a5900000000000000000000000000000000000000000000000000000000815260040160405180910390fd5b6106448173ffffffffffffffffffffffffffffffffffffffff16610783565b1561067b576040517fa6ef0ba100000000000000000000000000000000000000000000000000000000815260040160405180910390fd5b60008260405161068a906107d0565b8190604051809103906000f59050801580156106aa573d6000803e3d6000fd5b50905073ffffffffffffffffffffffffffffffffffffffff81166106fa576040517fb4f5411100000000000000000000000000000000000000000000000000000000815260040160405180910390fd5b6040517e77436000000000000000000000000000000000000000000000000000000000815273ffffffffffffffffffffffffffffffffffffffff821690627743609061074a908790600401610a1a565b600060405180830381600087803b15801561076457600080fd5b505af1158015610778573d6000803e3d6000fd5b505050505092915050565b600073ffffffffffffffffffffffffffffffffffffffff82163f801580159061048457507fc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470141592915050565b6101a080610a8783390190565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052604160045260246000fd5b600082601f83011261081d57600080fd5b813567ffffffffffffffff80821115610838576108386107dd565b604051601f83017fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0908116603f0116810190828211818310171561087e5761087e6107dd565b8160405283815286602085880101111561089757600080fd5b836020870160208301376000602085830101528094505050505092915050565b600080604083850312156108ca57600080fd5b823567ffffffffffffffff8111156108e157600080fd5b6108ed8582860161080c565b95602094909401359450505050565b60008060006060848603121561091157600080fd5b833567ffffffffffffffff81111561092857600080fd5b6109348682870161080c565b935050602084013573ffffffffffffffffffffffffffffffffffffffff8116811461095e57600080fd5b929592945050506040919091013590565b6000806000806060858703121561098557600080fd5b843567ffffffffffffffff8082111561099d57600080fd5b6109a98883890161080c565b95506020870135945060408701359150808211156109c657600080fd5b818701915087601f8301126109da57600080fd5b8135818111156109e957600080fd5b8860208285010111156109fb57600080fd5b95989497505060200194505050565b8183823760009101908152919050565b600060208083528351808285015260005b81811015610a4757858101830151858201604001528201610a2b565b5060006040828601015260407fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0601f830116850101925050509291505056fe608060405234801561001057600080fd5b50610180806100206000396000f3fe60806040526004361061001d5760003560e01c806277436014610022575b600080fd5b61003561003036600461007b565b610037565b005b8051602082016000f061004957600080fd5b50565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052604160045260246000fd5b60006020828403121561008d57600080fd5b813567ffffffffffffffff808211156100a557600080fd5b818401915084601f8301126100b957600080fd5b8135818111156100cb576100cb61004c565b604051601f82017fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0908116603f011681019083821181831017156101115761011161004c565b8160405282815287602084870101111561012a57600080fd5b82602086016020830137600092810160200192909252509594505050505056fea2646970667358221220a30aa0b079a504f6336b7e339659f909f468dcfe513766d3086e1efce2657d5164736f6c63430008130033a26469706673582212203a8a2818751a76f13bac296ad23080c23254ec57b82f46e2953af00c5cc5ecb464736f6c63430008130033608060405234801561001057600080fd5b50610180806100206000396000f3fe60806040526004361061001d5760003560e01c806277436014610022575b600080fd5b61003561003036600461007b565b610037565b005b8051602082016000f061004957600080fd5b50565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052604160045260246000fd5b60006020828403121561008d57600080fd5b813567ffffffffffffffff808211156100a557600080fd5b818401915084601f8301126100b957600080fd5b8135818111156100cb576100cb61004c565b604051601f82017fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0908116603f011681019083821181831017156101115761011161004c565b8160405282815287602084870101111561012a57600080fd5b82602086016020830137600092810160200192909252509594505050505056fea2646970667358221220a30aa0b079a504f6336b7e339659f909f468dcfe513766d3086e1efce2657d5164736f6c63430008130033";

    struct VerificationData {
        address contractAddress;
        string contractPath;
        bytes constructorArgs;
        uint256 chainId;
    }

    SingletonFactory constant create2Factory =
        SingletonFactory(0xce0042B868300000d44A59004Da54A005ffdcf9f);

    // CreateX contract for World Chain (480)
    ICreateX constant createXContract =
        ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    // Create3Deployer
    ICreate3Deployer constant create3Deployer =
        ICreate3Deployer(0xC6BAd1EbAF366288dA6FB5689119eDd695a66814);

    // Define a struct to consolidate deployment data and avoid stack too deep errors
    struct DeploymentContext {
        bytes32 salt;
        //hyperprover
        address mailbox;
        //polymerprover
        address polymerL2ProverV2;
        address router;
        string deployFilePath;
        address deployer;
        //contract salts
        bytes32 portalSalt;
        bytes32 hyperProverSalt;
        bytes32 polymerProverSalt;
        //contracts to deploy to evm
        address portal;
        address hyperProver;
        address polymerProver;
        //already deployed by caldera
        address metaProver;
        //hyperprover args for other evms
        address hyperProverCreateXAddress;
        address hyperProver2470Address;
        //hyperprover tron provers
        bytes32[] hyperSolanaProvers;
        //polymerprover args for other evms
        address polymerProverCreateXAddress;
        address polymerProver2470Address;
        //polymer tron provers
        bytes32[] polymerTronProvers;
        //prover contracts arguments
        bytes hyperProverConstructorArgs;
        bytes polymerProverConstructorArgs;
    }

    function run() external {
        // Initialize the deployment context struct with environment variables
        DeploymentContext memory ctx;
        ctx.salt = vm.envBytes32("SALT");
        // Salts must be unique to protocol for createx deploys
        ctx.hyperProverSalt = vm.envBytes32("HYPER_PROVER_SALT");
        ctx.polymerProverSalt = vm.envBytes32("POLYMER_PROVER_SALT");
        ctx.portalSalt = getContractSalt(ctx.salt, "PORTAL");
        ctx.mailbox = vm.envOr("MAILBOX_CONTRACT", address(0));
        ctx.polymerL2ProverV2 = vm.envOr(
            "POLYMER_CROSS_L2_PROVER_CONTRACT",
            address(0)
        );
        bool metaProver = vm.envOr("META_PROVER", false);
        ctx.deployFilePath = vm.envString("DEPLOY_FILE");
        ctx.deployer = vm.rememberKey(vm.envUint("PRIVATE_KEY"));
        ctx.hyperProverCreateXAddress = vm.envOr(
            "HYPERPROVER_CREATEX_ADDRESS",
            address(0)
        );
        ctx.hyperProver2470Address = vm.envOr(
            "HYPERPROVER_2470_ADDRESS",
            address(0)
        );
        ctx.polymerProverCreateXAddress = vm.envOr(
            "POLYMER_PROVER_CREATEX_ADDRESS",
            address(0)
        );
        ctx.polymerProver2470Address = vm.envOr(
            "POLYMER_PROVER_2470_ADDRESS",
            address(0)
        );
        bool hasMailbox = ctx.mailbox != address(0);
        bool hasPolymerL2ProverV2 = ctx.polymerL2ProverV2 != address(0);
        ctx.hyperSolanaProvers = vm.envOr(
            "HYPER_SOLANA_PROVERS",
            ",",
            new bytes32[](0)
        );
        ctx.polymerTronProvers = vm.envOr(
            "POLYMER_TRON_PROVERS",
            ",",
            new bytes32[](0)
        );

        // Validate environment variables
        validateDeploymentContext(ctx, hasMailbox, hasPolymerL2ProverV2);

        vm.startBroadcast();

        // Deploy deployer if it hasn't been deployed
        deployCreate3Deployer();

        // Deploy Portal
        deployPortal(ctx);

        // Deploy HyperProver
        if (hasMailbox) {
            console.log("Deploying HyperProver with Create3...");
            deployHyperProver(ctx);
        }

        // Deploy PolymerProver
        if (hasPolymerL2ProverV2) {
            console.log("Deploying PolymerProver with Create3...");
            deployPolymerProver(ctx);
        }

        // Deploy MetaProver or use hardcoded address
        if (metaProver) {
            ctx.metaProver = 0x3d529eFAEDb3B999A404c1B8543441aE616cB914;
            console.log("MetaProver (hardcoded) :", ctx.metaProver);
        }

        vm.stopBroadcast();

        // Write deployment results to file
        writeDeploymentData(ctx);
    }

    // Separate function to handle writing deployment data to file
    function writeDeploymentData(DeploymentContext memory ctx) internal {
        uint num = 1;
        bool hasHyperProver = ctx.mailbox != address(0);
        bool hasPolymerProver = ctx.polymerL2ProverV2 != address(0);
        bool hasMetaProver = ctx.metaProver != address(0);
        num = hasHyperProver ? num + 1 : num;
        num = hasPolymerProver ? num + 1 : num;
        num = hasMetaProver ? num + 1 : num;
        VerificationData[] memory contracts = new VerificationData[](num);
        uint count = 0;
        contracts[count++] = VerificationData({
            contractAddress: ctx.portal,
            contractPath: "contracts/Portal.sol:Portal",
            constructorArgs: new bytes(0),
            chainId: block.chainid
        });

        if (hasHyperProver) {
            contracts[count++] = VerificationData({
                contractAddress: ctx.hyperProver,
                contractPath: "contracts/prover/HyperProver.sol:HyperProver",
                constructorArgs: ctx.hyperProverConstructorArgs,
                chainId: block.chainid
            });
        }

        if (hasPolymerProver) {
            contracts[count++] = VerificationData({
                contractAddress: ctx.polymerProver,
                contractPath: "contracts/prover/PolymerProver.sol:PolymerProver",
                constructorArgs: ctx.polymerProverConstructorArgs,
                chainId: block.chainid
            });
        }

        if (hasMetaProver) {
            contracts[count++] = VerificationData({
                contractAddress: ctx.metaProver,
                contractPath: "contracts/prover/MetaProver.sol:MetaProver",
                constructorArgs: new bytes(0),
                chainId: block.chainid
            });
        }

        writeDeployFile(ctx.deployFilePath, contracts);
    }

    function deployPortal(
        DeploymentContext memory ctx
    ) internal returns (address portal) {
        (ctx.portal) = deployWithCreate2(
            type(Portal).creationCode,
            ctx.portalSalt
        );
        console.log("Portal :", ctx.portal);
    }

    function deployWithCreate3(
        bytes memory bytecode,
        bytes32 salt,
        address createXAddress,
        address factory2470Address,
        string memory contractName
    ) internal returns (address deployedAddress) {
        address expectedAddress;
        if (useCreateXForChainID()) {
            expectedAddress = createXAddress;
        } else {
            expectedAddress = factory2470Address;
        }

        bool deployed = isDeployed(expectedAddress);

        if (!deployed) {
            if (useCreateXForChainID()) {
                deployedAddress = createXContract.deployCreate3(salt, bytecode);
            } else {
                deployedAddress = create3Deployer.deploy(bytecode, salt);
            }

            require(
                deployedAddress == expectedAddress,
                string.concat(
                    "Expected address does not match deployed address. Expected: ",
                    vm.toString(expectedAddress),
                    " Got: ",
                    vm.toString(deployedAddress)
                )
            );
            require(
                isDeployed(deployedAddress),
                "Contract did not get deployed"
            );
        } else {
            deployedAddress = expectedAddress;
            console.log(
                string.concat(contractName, " already deployed at:"),
                deployedAddress
            );
        }

        console.log(string.concat(contractName, " :"), deployedAddress);
        return deployedAddress;
    }

    function deployHyperProverWithCreate3(
        bytes memory bytecode,
        DeploymentContext memory ctx
    ) internal returns (address deployedAddress) {
        return
            deployWithCreate3(
                bytecode,
                ctx.hyperProverSalt,
                ctx.hyperProverCreateXAddress,
                ctx.hyperProver2470Address,
                "HyperProver"
            );
    }

    function deployPolymerProverWithCreate3(
        bytes memory bytecode,
        DeploymentContext memory ctx
    ) internal returns (address deployedAddress) {
        return
            deployWithCreate3(
                bytecode,
                ctx.polymerProverSalt,
                ctx.polymerProverCreateXAddress,
                ctx.polymerProver2470Address,
                "PolymerProver"
            );
    }

    function buildProversArray(
        address createXAddress,
        address factory2470Address,
        bytes32[] memory additionalProvers
    ) internal pure returns (bytes32[] memory provers) {
        uint evmProvers = 2;
        uint totalProvers = evmProvers + additionalProvers.length;
        provers = new bytes32[](totalProvers);
        provers[0] = bytes32(uint256(uint160(factory2470Address)));
        provers[1] = bytes32(uint256(uint160(createXAddress)));

        for (uint i = 0; i < additionalProvers.length; i++) {
            provers[evmProvers + i] = additionalProvers[i];
        }
    }

    function convertAddressesToBytes32(
        address[] memory addresses
    ) internal pure returns (bytes32[] memory) {
        bytes32[] memory converted = new bytes32[](addresses.length);
        for (uint i = 0; i < addresses.length; i++) {
            converted[i] = bytes32(uint256(uint160(addresses[i])));
        }
        return converted;
    }

    function deployHyperProver(DeploymentContext memory ctx) internal {
        console.log(
            "Deploying contracts... ",
            vm.toString(ctx.hyperProverCreateXAddress)
        );
        console.log(
            "Hyperprover 2470 address: ",
            vm.toString(ctx.hyperProver2470Address)
        );
        logBytes32Array("Hyperprover Solana provers", ctx.hyperSolanaProvers);

        bytes32[] memory proverBytes32 = buildProversArray(
            ctx.hyperProverCreateXAddress,
            ctx.hyperProver2470Address,
            ctx.hyperSolanaProvers
        );

        ctx.hyperProverConstructorArgs = abi.encode(
            ctx.mailbox,
            ctx.portal,
            proverBytes32
        );

        bytes memory hyperProverBytecode = abi.encodePacked(
            type(HyperProver).creationCode,
            ctx.hyperProverConstructorArgs
        );

        ctx.hyperProver = deployHyperProverWithCreate3(
            hyperProverBytecode,
            ctx
        );
    }

    function deployPolymerProver(DeploymentContext memory ctx) internal {
        console.log(
            "Deploying contracts... ",
            vm.toString(ctx.polymerProverCreateXAddress)
        );
        console.log(
            "PolymerProver 2470 address: ",
            vm.toString(ctx.polymerProver2470Address)
        );
        logBytes32Array("PolymerProver Tron provers", ctx.polymerTronProvers);

        bytes32[] memory proverBytes32 = buildProversArray(
            ctx.polymerProverCreateXAddress,
            ctx.polymerProver2470Address,
            ctx.polymerTronProvers
        );

        ctx.polymerProverConstructorArgs = abi.encode(
            ctx.portal,
            ctx.polymerL2ProverV2,
            32 * 1024, // MAX_LOG_DATA_SIZE - using the guard value from PolymerProver
            proverBytes32
        );

        bytes memory polymerProverBytecode = abi.encodePacked(
            type(PolymerProver).creationCode,
            ctx.polymerProverConstructorArgs
        );

        ctx.polymerProver = deployPolymerProverWithCreate3(
            polymerProverBytecode,
            ctx
        );
    }

    function isDeployed(address _addr) internal view returns (bool) {
        return _addr.code.length > 0;
    }

    function useCreateXForChainID() internal view returns (bool) {
        return block.chainid == 480; // World Chain
    }

    function getContractSalt(
        bytes32 rootSalt,
        string memory contractName
    ) internal pure returns (bytes32) {
        // Hash the contract name with the last 11 bytes of the root salt
        bytes32 contractHash = keccak256(abi.encodePacked(contractName));
        return keccak256(abi.encode(rootSalt, contractHash));
    }

    function deployWithCreate2(
        bytes memory bytecode,
        bytes32 salt
    ) internal returns (address deployedContract) {
        // Calculate the predicted contract address based on deployment system
        if (useCreateXForChainID()) {
            deployedContract = createXContract.computeCreate2Address(
                keccak256(abi.encode(salt)),
                keccak256(bytecode)
            );
            console.log("Predicted CreateX create2 address:", deployedContract);
        } else {
            deployedContract = predictCreate2Address(bytecode, salt);
            console.log("Predicted 2470 create2 address:", deployedContract);
        }

        // Check if contract is already deployed
        if (isDeployed(deployedContract)) {
            console.log(
                "Contract already deployed create2 at address:",
                deployedContract
            );
            return deployedContract;
        }

        // Deploy the contract using the appropriate system
        address justDeployedAddr;

        if (useCreateXForChainID()) {
            console.log(
                "Using CreateX for chain ID:",
                block.chainid,
                " for deployWithCreate2"
            );
            justDeployedAddr = createXContract.deployCreate2(salt, bytecode);
            console.log("Deployed CreateX create2 address:", justDeployedAddr);
        } else {
            justDeployedAddr = create2Factory.deploy(bytecode, salt);
            console.log("Deployed 2470 create2 address:", justDeployedAddr);
        }

        // Validate deployment
        require(
            deployedContract == justDeployedAddr,
            string.concat(
                "Expected address does not match the deployed address, create2. Expected: ",
                vm.toString(deployedContract),
                " Got: ",
                vm.toString(justDeployedAddr)
            )
        );
        require(isDeployed(deployedContract), "Contract did not get deployed");

        return deployedContract;
    }

    function predictCreate2Address(
        bytes memory bytecode,
        bytes32 salt
    ) internal pure returns (address) {
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                bytes1(0xff),
                                address(create2Factory),
                                salt,
                                keccak256(bytecode)
                            )
                        )
                    )
                )
            );
    }

    function deployCreate3Deployer() internal {
        // Don't deploy Create3Deployer if we're using CreateX for this chain
        if (useCreateXForChainID()) {
            console.log(
                "Skipping Create3Deployer deployment - using CreateX for chain ID:",
                block.chainid
            );
            require(
                isDeployed(address(createXContract)),
                "CreateX contract not deployed at expected address"
            );
            console.log(
                "Verified CreateX contract exists at:",
                address(createXContract)
            );
            return;
        }

        if (!isDeployed(address(create3Deployer))) {
            address deployedCreate3Deployer = deployWithCreate2(
                CREATE3_DEPLOYER_BYTECODE,
                bytes32(0)
            );
            require(
                deployedCreate3Deployer == address(create3Deployer),
                "Unexpected deployer"
            );
            console.log(
                "Deployed Create3Deployer : ",
                address(create3Deployer)
            );
        } else {
            console.log(
                "Create3Deployer already deployed at address:",
                address(create3Deployer)
            );
        }
    }

    function writeDeployFile(
        string memory filePath,
        VerificationData[] memory contracts
    ) internal {
        for (uint256 i = 0; i < contracts.length; i++) {
            vm.writeLine(
                filePath,
                string(
                    abi.encodePacked(
                        vm.toString(contracts[i].chainId),
                        ",",
                        vm.toString(contracts[i].contractAddress),
                        ",",
                        contracts[i].contractPath,
                        ",",
                        vm.toString(contracts[i].constructorArgs)
                    )
                )
            );
        }
    }

    function validateDeploymentContext(
        DeploymentContext memory ctx,
        bool hasMailbox,
        bool hasPolymerL2ProverV2
    ) internal view {
        // Validate required environment variables
        require(ctx.salt != bytes32(0), "SALT must be provided");
        require(
            bytes(ctx.deployFilePath).length > 0,
            "DEPLOY_FILE must be provided"
        );

        // Validate HyperProver deployment context
        if (hasMailbox) {
            require(
                ctx.hyperProverSalt != bytes32(0),
                "HYPER_PROVER_SALT required for HyperProver deployment"
            );
            require(
                ctx.hyperProverCreateXAddress != address(0) ||
                    ctx.hyperProver2470Address != address(0),
                "Either HYPERPROVER_CREATEX_ADDRESS or HYPERPROVER_2470_ADDRESS must be provided"
            );
            console.log("HyperProver validation passed");
        }

        // Validate PolymerProver deployment context
        if (hasPolymerL2ProverV2) {
            require(
                ctx.polymerProverSalt != bytes32(0),
                "POLYMER_PROVER_SALT required for PolymerProver deployment"
            );
            require(
                ctx.polymerProverCreateXAddress != address(0) ||
                    ctx.polymerProver2470Address != address(0),
                "Either POLYMER_PROVER_CREATEX_ADDRESS or POLYMER_PROVER_2470_ADDRESS must be provided"
            );
            console.log("PolymerProver validation passed");
        }

        // Log prover array sizes for debugging
        if (ctx.hyperSolanaProvers.length > 0) {
            console.log(
                "Found",
                ctx.hyperSolanaProvers.length,
                "Solana HyperProver addresses"
            );
        }
        if (ctx.polymerTronProvers.length > 0) {
            console.log(
                "Found",
                ctx.polymerTronProvers.length,
                "Tron PolymerProver addresses"
            );
        }

        // Warn about large arrays that might cause gas issues
        if (ctx.hyperSolanaProvers.length > 10) {
            console.log(
                "WARNING: Large number of Solana provers may cause gas issues:",
                ctx.hyperSolanaProvers.length
            );
        }
        if (ctx.polymerTronProvers.length > 10) {
            console.log(
                "WARNING: Large number of Tron provers may cause gas issues:",
                ctx.polymerTronProvers.length
            );
        }

        console.log("Deployment context validation completed");
    }

    function logBytes32Array(
        string memory label,
        bytes32[] memory array
    ) internal view {
        console.log(label, "count:", array.length);
        for (uint i = 0; i < array.length && i < 5; i++) {
            console.log("  [", i, "]:", vm.toString(array[i]));
        }
        if (array.length > 5) {
            console.log("  ... and", array.length - 5, "more");
        }
    }
}
