pragma solidity ^0.8.0;

// Forge
import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

// Tools
import {SingletonFactory} from "../contracts/tools/SingletonFactory.sol";
import {ICreate3Deployer} from "../contracts/tools/ICreate3Deployer.sol";

// Protocol
import {Inbox} from "../contracts/Inbox.sol";
import {IntentSource} from "../contracts/IntentSource.sol";
import {HyperProver} from "../contracts/prover/HyperProver.sol";
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

    // Create3Deployer
    ICreate3Deployer constant create3Deployer =
        ICreate3Deployer(0xC6BAd1EbAF366288dA6FB5689119eDd695a66814);

    // Define a struct to consolidate deployment data and avoid stack too deep errors
    struct DeploymentContext {
        bytes32 salt;
        address mailbox;
        address router;
        string deployFilePath;
        address deployer;
        bytes32 intentSourceSalt;
        bytes32 inboxSalt;
        bytes32 hyperProverSalt;
        bytes32 metaProverSalt;
        address intentSource;
        address inbox;
        address hyperProver;
        address metaProver;
        bytes inboxConstructorArgs;
        bytes hyperProverConstructorArgs;
        bytes metaProverConstructorArgs;
    }

    function run() external {
        // Initialize the deployment context struct with environment variables
        DeploymentContext memory ctx;
        ctx.salt = vm.envBytes32("SALT");
        ctx.mailbox = vm.envOr("MAILBOX_CONTRACT", address(0));
        ctx.router = vm.envOr("ROUTER_CONTRACT", address(0));
        ctx.deployFilePath = vm.envString("DEPLOY_FILE");
        ctx.deployer = vm.rememberKey(vm.envUint("PRIVATE_KEY"));
        bool hasMailbox = ctx.mailbox != address(0);
        bool hasRouter = ctx.router != address(0);
        // Compute salts for each contract
        ctx.intentSourceSalt = getContractSalt(ctx.salt, "INTENT_SOURCE");
        ctx.inboxSalt = getContractSalt(ctx.salt, "INBOX");
        if (hasMailbox) {
            ctx.hyperProverSalt = getContractSalt(ctx.salt, "HYPER_PROVER");
        }

        if (hasRouter) {
            ctx.metaProverSalt = getContractSalt(ctx.salt, "META_PROVER");
        }

        vm.startBroadcast();

        // Deploy deployer if it hasn't been deployed
        deployCreate3Deployer();

        // Deploy IntentSource
        deployIntentSource(ctx);

        // Deploy Inbox
        deployInbox(ctx);

        // Deploy HyperProver
        if (hasMailbox) {
            deployHyperProver(ctx);
        }

        // Deploy MetaProver
        if (hasRouter) {
            deployMetaProver(ctx);
        }

        vm.stopBroadcast();

        // Write deployment results to file
        writeDeploymentData(ctx);
    }

    // Separate function to handle writing deployment data to file
    function writeDeploymentData(DeploymentContext memory ctx) internal {
        uint num = 2;
        bool hasMailbox = ctx.mailbox != address(0);
        bool hasRouter = ctx.router != address(0);
        num = hasMailbox ? num + 1 : num;
        num = hasRouter ? num + 1 : num;
        VerificationData[] memory contracts = new VerificationData[](num);
        uint count = 0;
        contracts[count++] = VerificationData({
            contractAddress: ctx.intentSource,
            contractPath: "contracts/IntentSource.sol:IntentSource",
            constructorArgs: new bytes(0),
            chainId: block.chainid
        });

        contracts[count++] = VerificationData({
            contractAddress: ctx.inbox,
            contractPath: "contracts/Inbox.sol:Inbox",
            constructorArgs: ctx.inboxConstructorArgs,
            chainId: block.chainid
        });

        if (hasMailbox) {
            contracts[count++] = VerificationData({
                contractAddress: ctx.hyperProver,
                contractPath: "contracts/prover/HyperProver.sol:HyperProver",
                constructorArgs: ctx.hyperProverConstructorArgs,
                chainId: block.chainid
            });
        }
        if (hasRouter) {
            contracts[count++] = VerificationData({
                contractAddress: ctx.metaProver,
                contractPath: "contracts/prover/MetaProver.sol:MetaProver",
                constructorArgs: ctx.metaProverConstructorArgs,
                chainId: block.chainid
            });
        }

        writeDeployFile(ctx.deployFilePath, contracts);
    }

    function deployIntentSource(
        DeploymentContext memory ctx
    ) internal returns (address intentSource) {
        (ctx.intentSource) = deployWithCreate2(
            type(IntentSource).creationCode,
            ctx.intentSourceSalt
        );
        console.log("IntentSource :", ctx.intentSource);
    }

    function deployInbox(
        DeploymentContext memory ctx
    ) internal returns (address inbox) {
        (ctx.inbox) = deployWithCreate2(
            type(Inbox).creationCode,
            ctx.inboxSalt
        );

        console.log("Inbox :", ctx.inbox);
    }

    function deployHyperProver(
        DeploymentContext memory ctx
    ) internal returns (address hyperProver) {
        address hyperProverPreviewAddr = create3Deployer.deployedAddress(
            bytes(""), // Bytecode isn't used to determine the deployed address
            ctx.deployer,
            ctx.hyperProverSalt
        );

        // Initialize provers array properly with inbox address
        address[] memory provers = new address[](1);
        provers[0] = hyperProverPreviewAddr;

        ctx.hyperProverConstructorArgs = abi.encode(
            ctx.mailbox,
            ctx.inbox,
            provers
        );

        bytes memory hyperProverBytecode = abi.encodePacked(
            type(HyperProver).creationCode,
            ctx.hyperProverConstructorArgs
        );

        bool deployed;
        (ctx.hyperProver, deployed) = deployWithCreate3(
            hyperProverBytecode,
            ctx.deployer,
            ctx.hyperProverSalt
        );

        console.log("HyperProver :", ctx.hyperProver);
    }

    function deployMetaProver(
        DeploymentContext memory ctx
    ) internal returns (address metaProver) {
        address metaProverPreviewAddr = create3Deployer.deployedAddress(
            bytes(""), // Bytecode isn't used to determine the deployed address
            ctx.deployer,
            ctx.metaProverSalt
        );

        // Initialize provers array properly with inbox address
        address[] memory provers = new address[](1);
        provers[0] = metaProverPreviewAddr;

        ctx.metaProverConstructorArgs = abi.encode(
            ctx.router,
            ctx.inbox,
            provers
        );

        bytes memory metaProverBytecode = abi.encodePacked(
            type(MetaProver).creationCode,
            ctx.metaProverConstructorArgs
        );

        bool deployed;
        (ctx.metaProver, deployed) = deployWithCreate3(
            metaProverBytecode,
            ctx.deployer,
            ctx.metaProverSalt
        );

        console.log("MetaProver :", ctx.metaProver);
    }

    function isDeployed(address _addr) internal view returns (bool) {
        return _addr.code.length > 0;
    }

    function getContractSalt(
        bytes32 rootSalt,
        string memory contractName
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(rootSalt, keccak256(abi.encodePacked(contractName)))
            );
    }

    function deployWithCreate2(
        bytes memory bytecode,
        bytes32 salt
    ) internal returns (address deployedContract) {
        // Calculate the contract address that will be deployed
        deployedContract = predictCreate2Address(bytecode, salt);

        // Check if contract is already deployed
        if (isDeployed(deployedContract)) {
            console.log(
                "Contract already deployed at address:",
                deployedContract
            );
            return deployedContract;
        }

        // Deploy the contract if not already deployed
        address justDeployedAddr = create2Factory.deploy(bytecode, salt);
        require(
            deployedContract == justDeployedAddr,
            "Expected address does not match the deployed address"
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

    function deployWithCreate3(
        bytes memory bytecode,
        address sender,
        bytes32 salt
    ) internal returns (address deployedContract, bool deployed) {
        deployedContract = create3Deployer.deployedAddress(
            bytecode,
            sender,
            salt
        );

        deployed = isDeployed(deployedContract);

        if (!deployed) {
            address justDeployedAddr = create3Deployer.deploy(bytecode, salt);
            require(
                deployedContract == justDeployedAddr,
                "Expected address does not match the deployed address"
            );
            require(
                isDeployed(deployedContract),
                "Contract did not get deployed"
            );
        } else {
            console.log(
                "Contract already deployed at address:",
                deployedContract
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
}
