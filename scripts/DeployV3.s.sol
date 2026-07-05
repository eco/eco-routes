// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Forge
import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

// Deterministic-deploy infra
import {SingletonFactory} from "../contracts/tools/SingletonFactory.sol";
import {ICreate3Deployer} from "../contracts/tools/ICreate3Deployer.sol";

// Address encoding (the C1-critical helper: RIGHT-aligned bytes32)
import {AddressConverter} from "../contracts/libs/AddressConverter.sol";

// Core (no ctor args => CREATE2, identical address on every chain)
import {Portal} from "../contracts/Portal.sol";
import {PortalTron} from "../contracts/tron/PortalTron.sol";
import {PortalProxy} from "../contracts/PortalProxy.sol";
import {ERC7683Implementation} from "../contracts/ERC7683/ERC7683Implementation.sol";
// Aliased: forge-std's StdCheats defines a `struct Account` that shadows this import in Script-derived
// contracts.
import {Account as EcoAccount} from "../contracts/account/Account.sol";
import {AccountTron} from "../contracts/tron/AccountTron.sol";
import {MulticallRuntime} from "../contracts/runtime/MulticallRuntime.sol";

// Same-chain settlement (portal-only ctor)
import {LocalPolicy} from "../contracts/prover/LocalPolicy.sol";
import {LocalPolicyTron} from "../contracts/tron/LocalPolicyTron.sol";

// Transport+settlement policies (chain-specific ctor args => CREATE3; self-referencing peer whitelist)
import {HyperPolicy} from "../contracts/prover/HyperPolicy.sol";
import {MetaPolicy} from "../contracts/prover/MetaPolicy.sol";
import {LayerZeroPolicy} from "../contracts/prover/LayerZeroPolicy.sol";
import {CCIPPolicy} from "../contracts/prover/CCIPPolicy.sol";
import {PolymerPolicy} from "../contracts/prover/PolymerPolicy.sol";

// Schedule / streaming settlement policies (portal + off-chain relayer whitelist)
import {StreamingPolicy} from "../contracts/prover/StreamingPolicy.sol";
import {VestingPolicy} from "../contracts/prover/VestingPolicy.sol";
import {MilestonePolicy} from "../contracts/prover/MilestonePolicy.sol";
import {DutchDecayPolicy} from "../contracts/prover/DutchDecayPolicy.sol";

/**
 * @title DeployV3
 * @notice Deterministic, env-driven Foundry deployer for the Eco Routes v3 contract set.
 *
 * @dev Deterministic-address strategy (why addresses line up on every chain):
 *
 *   - Portal / PortalTron + MulticallRuntime take NO constructor args, so their creation bytecode is
 *     fixed and CREATE2 (via the EIP-2470 SingletonFactory at {SINGLETON_FACTORY}) yields an IDENTICAL
 *     address on every EVM chain for a given salt (TVM uses the 0x41 CREATE2 prefix, so its family
 *     differs from the EVM family by construction).
 *   - Every policy takes chain-specific constructor args (bridge endpoints, peer lists). Their addresses
 *     must STILL match across chains, so they deploy via CREATE3 (canonical ICreate3Deployer at
 *     {CREATE3_DEPLOYER}). A CREATE3 address is a pure function of (deployer, salt) — INDEPENDENT of
 *     bytecode and ctor args — so the same (deployer, per-contract salt) resolves to the same address on
 *     every chain despite differing endpoints. A transport policy predicts its OWN CREATE3 address first
 *     and stores it as peer[0] of its immutable whitelist (its peer on every other chain == its own
 *     address here).
 *
 *   C1 (critical): a transport policy's self-reference in its peer whitelist MUST be stored RIGHT-aligned
 *   as `AddressConverter.toBytes32(self) == bytes32(uint256(uint160(self)))` — the exact form every
 *   transport delivers the cross-chain sender in (see {MessageBridgePolicy._handleCrossChainMessage}).
 *   The LEFT-aligned `bytes32(bytes20(self))` form silently makes the immutable `==` never match, so
 *   every EVM<->EVM proof is rejected and solver funds lock. This script uses ONLY the right-aligned
 *   form; {test/v3/deploy/DeployV3.t.sol} asserts it and rejects the left-aligned regression.
 *
 *   Per-contract salt: `keccak256(abi.encode(SALT, keccak256(bytes(name))))` (the v2 getContractSalt
 *   rule). The Portal uses the bare SALT.
 *
 *   Deployer identity: a CREATE3 address depends on the msg.sender of the deployer's `deploy` call. Under
 *   `vm.startBroadcast` that is the deployer EOA, so the SAME deployer key + SALT must be used on every
 *   chain for the addresses to line up.
 */
contract DeployV3 is Script {
    using AddressConverter for address;

    // --- Canonical deterministic-deploy infra -------------------------------

    SingletonFactory internal constant CREATE2_SINGLETON =
        SingletonFactory(0xce0042B868300000d44A59004Da54A005ffdcf9f);
    ICreate3Deployer internal constant CREATE3_DEPLOYER_C =
        ICreate3Deployer(0xC6BAd1EbAF366288dA6FB5689119eDd695a66814);

    // CREATE3 deployer creation code (bootstrapped via the SingletonFactory when absent).
    bytes internal constant CREATE3_DEPLOYER_BYTECODE =
        hex"60a060405234801561001057600080fd5b5060405161002060208201610044565b601f1982820381018352601f90910116604052805160209190910120608052610051565b6101a080610ccf83390190565b608051610c5c610073600039600081816103d701526105410152610c5c6000f3fe6080604052600436106100345760003560e01c80634af63f0214610039578063c2b1041c14610075578063cf4d643214610095575b600080fd5b61004c6100473660046108b7565b6100a8565b60405173ffffffffffffffffffffffffffffffffffffffff909116815260200160405180910390f35b34801561008157600080fd5b5061004c6100903660046108fc565b61018c565b61004c6100a336600461096f565b6101e5565b6040805133602082015290810182905260009081906060016040516020818303038152906040528051906020012090506100e28482610372565b9150341561010a5761010a73ffffffffffffffffffffffffffffffffffffffff83163461048b565b61011484826104d5565b9150823373ffffffffffffffffffffffffffffffffffffffff168373ffffffffffffffffffffffffffffffffffffffff167fd579261046780ec80c4dae1bc57abdb62c58df8af1531e63b4e8bcc08bcf46ec878051906020012060405161017d91815260200190565b60405180910390a45092915050565b6040805173ffffffffffffffffffffffffffffffffffffffff8416602082015290810182905260009081906060016040516020818303038152906040528051906020012090506101dc8582610372565b95945050505050565b60408051336020820152908101849052600090819060600160405160208183030381529060405280519060200120905061021f8682610372565b915034156102475761024773ffffffffffffffffffffffffffffffffffffffff83163461048b565b61025186826104d5565b9150843373ffffffffffffffffffffffffffffffffffffffff168373ffffffffffffffffffffffffffffffffffffffff167fd579261046780ec80c4dae1bc57abdb62c58df8af1531e63b4e8bcc08bcf46ec89805190602001206040516102ba91815260200190565b60405180910390a460008273ffffffffffffffffffffffffffffffffffffffff1685856040516102eb929190610a0a565b6000604051808303816000865af19150503d8060008114610328576040519150601f19603f3d011682016040523d82523d6000602084013e61032d565b606091505b5050905080610368576040517f139c636700000000000000000000000000000000000000000000000000000000815260040160405180910390fd5b5050949350505050565b604080517fff000000000000000000000000000000000000000000000000000000000000006020808301919091527fffffffffffffffffffffffffffffffffffffffff00000000000000000000000030606090811b82166021850152603584018690527f0000000000000000000000000000000000000000000000000000000000000000605580860191909152855180860390910181526075850186528051908401207fd6940000000000000000000000000000000000000000000000000000000000006095860152901b1660978301527f010000000000000000000000000000000000000000000000000000000000000060ab8301528251808303608c01815260ac90920190925280519101206000905b9392505050565b600080600080600085875af19050806104d0576040517ff4b3b1bc00000000000000000000000000000000000000000000000000000000815260040160405180910390fd5b505050565b60006104848383604080517fff000000000000000000000000000000000000000000000000000000000000006020808301919091527fffffffffffffffffffffffffffffffffffffffff00000000000000000000000030606090811b82166021850152603584018690527f0000000000000000000000000000000000000000000000000000000000000000605580860191909152855180860390910181526075850186528051908401207fd6940000000000000000000000000000000000000000000000000000000000006095860152901b1660978301527f010000000000000000000000000000000000000000000000000000000000000060ab8301528251808303608c01815260ac90920190925280519101208251600003610625576040517f21744a5900000000000000000000000000000000000000000000000000000000815260040160405180910390fd5b6106448173ffffffffffffffffffffffffffffffffffffffff16610783565b1561067b576040517fa6ef0ba100000000000000000000000000000000000000000000000000000000815260040160405180910390fd5b60008260405161068a906107d0565b8190604051809103906000f59050801580156106aa573d6000803e3d6000fd5b50905073ffffffffffffffffffffffffffffffffffffffff81166106fa576040517fb4f5411100000000000000000000000000000000000000000000000000000000815260040160405180910390fd5b6040517e77436000000000000000000000000000000000000000000000000000000000815273ffffffffffffffffffffffffffffffffffffffff821690627743609061074a908790600401610a1a565b600060405180830381600087803b15801561076457600080fd5b505af1158015610778573d6000803e3d6000fd5b505050505092915050565b600073ffffffffffffffffffffffffffffffffffffffff82163f801580159061048457507fc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470141592915050565b6101a080610a8783390190565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052604160045260246000fd5b600082601f83011261081d57600080fd5b813567ffffffffffffffff80821115610838576108386107dd565b604051601f83017fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0908116603f0116810190828211818310171561087e5761087e6107dd565b8160405283815286602085880101111561089757600080fd5b836020870160208301376000602085830101528094505050505092915050565b600080604083850312156108ca57600080fd5b823567ffffffffffffffff8111156108e157600080fd5b6108ed8582860161080c565b95602094909401359450505050565b60008060006060848603121561091157600080fd5b833567ffffffffffffffff81111561092857600080fd5b6109348682870161080c565b935050602084013573ffffffffffffffffffffffffffffffffffffffff8116811461095e57600080fd5b929592945050506040919091013590565b6000806000806060858703121561098557600080fd5b843567ffffffffffffffff8082111561099d57600080fd5b6109a98883890161080c565b95506020870135945060408701359150808211156109c657600080fd5b818701915087601f8301126109da57600080fd5b8135818111156109e957600080fd5b8860208285010111156109fb57600080fd5b95989497505060200194505050565b8183823760009101908152919050565b600060208083528351808285015260005b81811015610a4757858101830151858201604001528201610a2b565b5060006040828601015260407fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0601f830116850101925050509291505056fe608060405234801561001057600080fd5b50610180806100206000396000f3fe60806040526004361061001d5760003560e01c806277436014610022575b600080fd5b61003561003036600461007b565b610037565b005b8051602082016000f061004957600080fd5b50565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052604160045260246000fd5b60006020828403121561008d57600080fd5b813567ffffffffffffffff808211156100a557600080fd5b818401915084601f8301126100b957600080fd5b8135818111156100cb576100cb61004c565b604051601f82017fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0908116603f011681019083821181831017156101115761011161004c565b8160405282815287602084870101111561012a57600080fd5b82602086016020830137600092810160200192909252509594505050505056fea2646970667358221220a30aa0b079a504f6336b7e339659f909f468dcfe513766d3086e1efce2657d5164736f6c63430008130033a26469706673582212203a8a2818751a76f13bac296ad23080c23254ec57b82f46e2953af00c5cc5ecb464736f6c63430008130033608060405234801561001057600080fd5b50610180806100206000396000f3fe60806040526004361061001d5760003560e01c806277436014610022575b600080fd5b61003561003036600461007b565b610037565b005b8051602082016000f061004957600080fd5b50565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052604160045260246000fd5b60006020828403121561008d57600080fd5b813567ffffffffffffffff808211156100a557600080fd5b818401915084601f8301126100b957600080fd5b8135818111156100cb576100cb61004c565b604051601f82017fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0908116603f011681019083821181831017156101115761011161004c565b8160405282815287602084870101111561012a57600080fd5b82602086016020830137600092810160200192909252509594505050505056fea2646970667358221220a30aa0b079a504f6336b7e339659f909f468dcfe513766d3086e1efce2657d5164736f6c63430008130033";

    uint256 internal constant DEFAULT_MIN_GAS_LIMIT = 200_000;
    uint256 internal constant DEFAULT_POLYMER_MAX_LOG_DATA_SIZE = 8_192;

    uint256 internal constant TRON_MAINNET_CHAIN_ID = 728126428;
    uint256 internal constant TRON_SHASTA_CHAIN_ID = 2494104990;
    uint256 internal constant TRON_NILE_CHAIN_ID = 3448148188;

    // --- Config / output structs -------------------------------------------

    struct Config {
        bytes32 salt; // root CREATE2/CREATE3 salt (identical across chains)
        address deployer; // CREATE3 sender (== broadcasting EOA)
        bool isTron; // use PortalTron/AccountTron/LocalPolicyTron + 0x41 CREATE2 prefix
        // transport endpoints (zero => that transport policy is skipped)
        address mailbox; // Hyperlane
        address router; // Metalayer
        address lzEndpoint; // LayerZero v2
        address lzDelegate; // LayerZero delegate (defaults to deployer)
        address ccipRouter; // Chainlink CCIP
        address polymerCrossL2Prover; // Polymer CrossL2ProverV2
        uint256 polymerMaxLogDataSize; // Polymer log guard (defaults to 8192)
        uint256 minGasLimit; // Meta/LZ/CCIP min gas (defaults to 200000)
        // non-EVM peer policy addresses (bytes32), appended after the EVM self-reference
        bytes32[] hyperCrossVm;
        bytes32[] metaCrossVm;
        bytes32[] lzCrossVm;
        bytes32[] ccipCrossVm;
        bytes32[] polymerCrossVm;
        // schedule/streaming settlement policies
        bool deploySchedulePolicies;
        bytes32[] scheduleRelays; // authorized off-chain relayer addrs (bytes32, right-aligned)
        // same-chain settlement policy
        bool deployLocalPolicy;
    }

    struct Deployment {
        address portal; // the permanent PortalProxy (what everything references as "the Portal")
        address portalImplementation; // the versioned implementation registered as version 1
        address erc7683Implementation; // the ERC-7683 adapter the Portal falls back to (PR10)
        address runtime;
        address localPolicy;
        address hyperPolicy;
        address metaPolicy;
        address layerZeroPolicy;
        address ccipPolicy;
        address polymerPolicy;
        address streamingPolicy;
        address vestingPolicy;
        address milestonePolicy;
        address dutchDecayPolicy;
    }

    // --- Entry points -------------------------------------------------------

    function run() external returns (Deployment memory dep) {
        Config memory cfg = _readConfig(false);
        vm.startBroadcast(cfg.deployer);
        dep = deploy(cfg);
        vm.stopBroadcast();
        _writeDeployFile(cfg, dep);
    }

    function runTron() external returns (Deployment memory dep) {
        Config memory cfg = _readConfig(true);
        vm.startBroadcast(cfg.deployer);
        dep = deploy(cfg);
        vm.stopBroadcast();
        _writeDeployFile(cfg, dep);
    }

    /**
     * @notice Deploy + wire the full v3 set for one chain. Env-free so a test can drive it with a struct.
     * @dev Idempotent: re-running with the same (salt, deployer) returns the same addresses (already-deployed
     *      contracts are detected and skipped).
     */
    function deploy(Config memory cfg) public returns (Deployment memory dep) {
        _ensureCreate3Deployer(cfg.isTron);

        // 1. Core: a permanent PortalProxy in front of a versioned implementation (PR9).
        //    - The PortalProxy is the PERMANENT, stable "Portal" address that every intent, account, and
        //      downstream policy anchors to. Deployed at `cfg.salt` (the canonical address) with the
        //      deployer as protocol owner. Deployed FIRST because both the shared Account implementation
        //      (bound to the proxy as its authorized caller) and the Portal implementation reference it.
        //    - The Account implementation is SHARED across all Portal versions and bound to the proxy, so
        //      every version derives the same per-intent Account addresses (address-stability invariant).
        //    - The Portal implementation (Portal / PortalTron) carries ALL the logic; it references the
        //      shared Account implementation as its clone template. Deployed at a derived salt.
        dep.portal = _deployCreate2(
            abi.encodePacked(
                type(PortalProxy).creationCode,
                abi.encode(cfg.deployer) // initialOwner = deployer (protocol owner)
            ),
            cfg.salt,
            cfg.isTron
        );
        console.log("PortalProxy (permanent Portal):", dep.portal);

        address accountImplementation = _deployCreate2(
            abi.encodePacked(
                cfg.isTron
                    ? type(AccountTron).creationCode
                    : type(EcoAccount).creationCode,
                abi.encode(dep.portal) // Account.portal = the proxy (its authorized caller)
            ),
            _contractSalt(cfg.salt, "ACCOUNT_IMPLEMENTATION"),
            cfg.isTron
        );
        console.log("Account implementation (shared):", accountImplementation);

        // ERC-7683 adapter (PR10): the open/openFor/resolve/resolveFor/fill surface lives OUTSIDE the lean
        // Portal implementation, which delegatecalls it via {PortalCore-fallback}. It takes NO constructor
        // args (it holds no version/account state — it resolves + delegatecalls the pinned implementation
        // per call), and a SINGLE instance serves BOTH the EVM and TRON Portal (no TRON-specific variant).
        dep.erc7683Implementation = _deployCreate2(
            type(ERC7683Implementation).creationCode,
            _contractSalt(cfg.salt, "ERC7683_IMPLEMENTATION"),
            cfg.isTron
        );
        console.log("ERC7683 implementation:", dep.erc7683Implementation);

        dep.portalImplementation = _deployCreate2(
            abi.encodePacked(
                cfg.isTron
                    ? type(PortalTron).creationCode
                    : type(Portal).creationCode,
                abi.encode(
                    accountImplementation, // shared Account clone template
                    dep.erc7683Implementation // ERC-7683 adapter for the fallback
                )
            ),
            _contractSalt(cfg.salt, "PORTAL_IMPLEMENTATION_V1"),
            cfg.isTron
        );
        console.log("Portal implementation (v1):", dep.portalImplementation);

        // Bootstrap version 1 -> implementation (owner-only; broadcasting as the deployer/owner).
        // Idempotent on re-run: re-registration would revert VersionAlreadyRegistered, so skip if set.
        (address registered, ) = PortalProxy(payable(dep.portal)).versions(1);
        if (registered == address(0)) {
            PortalProxy(payable(dep.portal)).registerVersion(
                1,
                dep.portalImplementation
            );
        }

        dep.runtime = _deployCreate2(
            type(MulticallRuntime).creationCode,
            _contractSalt(cfg.salt, "MULTICALL_RUNTIME"),
            cfg.isTron
        );
        console.log("MulticallRuntime:", dep.runtime);

        // 2. Same-chain settlement (portal-only ctor, CREATE3).
        if (cfg.deployLocalPolicy) {
            bytes memory code = cfg.isTron
                ? abi.encodePacked(
                    type(LocalPolicyTron).creationCode,
                    abi.encode(dep.portal)
                )
                : abi.encodePacked(
                    type(LocalPolicy).creationCode,
                    abi.encode(dep.portal)
                );
            dep.localPolicy = _deployCreate3(
                code,
                cfg.deployer,
                _contractSalt(cfg.salt, "LOCAL_POLICY")
            );
            console.log("LocalPolicy:", dep.localPolicy);
        }

        // 3. Transport policies (CREATE3, self-referencing right-aligned whitelist).
        _deployTransports(cfg, dep);

        // 4. Schedule / streaming settlement policies (CREATE3, off-chain relayer whitelist).
        if (cfg.deploySchedulePolicies) {
            _deploySchedulePolicies(cfg, dep);
        }
    }

    // --- Transport policies -------------------------------------------------

    function _deployTransports(
        Config memory cfg,
        Deployment memory dep
    ) internal {
        uint256 minGas = cfg.minGasLimit == 0
            ? DEFAULT_MIN_GAS_LIMIT
            : cfg.minGasLimit;

        if (cfg.mailbox != address(0)) {
            bytes32 salt = _contractSalt(cfg.salt, "HYPER_POLICY");
            bytes32[] memory provers = _selfPlusPeers(salt, cfg.deployer, cfg.hyperCrossVm);
            bytes memory code = abi.encodePacked(
                type(HyperPolicy).creationCode,
                abi.encode(cfg.mailbox, dep.portal, provers)
            );
            dep.hyperPolicy = _deployCreate3(code, cfg.deployer, salt);
            console.log("HyperPolicy:", dep.hyperPolicy);
        }

        if (cfg.router != address(0)) {
            bytes32 salt = _contractSalt(cfg.salt, "META_POLICY");
            bytes32[] memory provers = _selfPlusPeers(salt, cfg.deployer, cfg.metaCrossVm);
            bytes memory code = abi.encodePacked(
                type(MetaPolicy).creationCode,
                abi.encode(cfg.router, dep.portal, provers, minGas)
            );
            dep.metaPolicy = _deployCreate3(code, cfg.deployer, salt);
            console.log("MetaPolicy:", dep.metaPolicy);
        }

        if (cfg.lzEndpoint != address(0)) {
            bytes32 salt = _contractSalt(cfg.salt, "LAYERZERO_POLICY");
            bytes32[] memory provers = _selfPlusPeers(salt, cfg.deployer, cfg.lzCrossVm);
            address delegate = cfg.lzDelegate == address(0)
                ? cfg.deployer
                : cfg.lzDelegate;
            bytes memory code = abi.encodePacked(
                type(LayerZeroPolicy).creationCode,
                abi.encode(cfg.lzEndpoint, delegate, dep.portal, provers, minGas)
            );
            dep.layerZeroPolicy = _deployCreate3(code, cfg.deployer, salt);
            console.log("LayerZeroPolicy:", dep.layerZeroPolicy);
        }

        if (cfg.ccipRouter != address(0)) {
            bytes32 salt = _contractSalt(cfg.salt, "CCIP_POLICY");
            bytes32[] memory provers = _selfPlusPeers(salt, cfg.deployer, cfg.ccipCrossVm);
            bytes memory code = abi.encodePacked(
                type(CCIPPolicy).creationCode,
                abi.encode(cfg.ccipRouter, dep.portal, provers, minGas)
            );
            dep.ccipPolicy = _deployCreate3(code, cfg.deployer, salt);
            console.log("CCIPPolicy:", dep.ccipPolicy);
        }

        if (cfg.polymerCrossL2Prover != address(0)) {
            bytes32 salt = _contractSalt(cfg.salt, "POLYMER_POLICY");
            // Polymer's proof is source-emitted-event based; its whitelist authenticates the ORIGIN
            // policy address on the source chain. Following the production pattern its peer list is the
            // configured cross-VM peers only (no self-reference).
            uint256 maxLog = cfg.polymerMaxLogDataSize == 0
                ? DEFAULT_POLYMER_MAX_LOG_DATA_SIZE
                : cfg.polymerMaxLogDataSize;
            bytes memory code = abi.encodePacked(
                type(PolymerPolicy).creationCode,
                abi.encode(
                    dep.portal,
                    cfg.polymerCrossL2Prover,
                    maxLog,
                    cfg.polymerCrossVm
                )
            );
            dep.polymerPolicy = _deployCreate3(code, cfg.deployer, salt);
            console.log("PolymerPolicy:", dep.polymerPolicy);
        }
    }

    /**
     * @dev Build a transport policy's immutable peer whitelist: its OWN CREATE3 address (predicted from
     *      salt+deployer) RIGHT-aligned as peer[0], then the configured non-EVM peers. Right-alignment via
     *      {AddressConverter.toBytes32} is the C1-critical form — see the contract-level note.
     */
    function _selfPlusPeers(
        bytes32 salt,
        address deployer,
        bytes32[] memory crossVm
    ) internal view returns (bytes32[] memory provers) {
        address self = CREATE3_DEPLOYER_C.deployedAddress(bytes(""), deployer, salt);
        provers = new bytes32[](1 + crossVm.length);
        provers[0] = self.toBytes32(); // RIGHT-aligned self-reference (C1)
        for (uint256 i; i < crossVm.length; ++i) {
            provers[i + 1] = crossVm[i];
        }
    }

    // --- Schedule / streaming policies -------------------------------------

    function _deploySchedulePolicies(
        Config memory cfg,
        Deployment memory dep
    ) internal {
        dep.streamingPolicy = _deployCreate3(
            abi.encodePacked(
                type(StreamingPolicy).creationCode,
                abi.encode(dep.portal, cfg.scheduleRelays)
            ),
            cfg.deployer,
            _contractSalt(cfg.salt, "STREAMING_POLICY")
        );
        console.log("StreamingPolicy:", dep.streamingPolicy);

        dep.vestingPolicy = _deployCreate3(
            abi.encodePacked(
                type(VestingPolicy).creationCode,
                abi.encode(dep.portal, cfg.scheduleRelays)
            ),
            cfg.deployer,
            _contractSalt(cfg.salt, "VESTING_POLICY")
        );
        console.log("VestingPolicy:", dep.vestingPolicy);

        dep.milestonePolicy = _deployCreate3(
            abi.encodePacked(
                type(MilestonePolicy).creationCode,
                abi.encode(dep.portal, cfg.scheduleRelays)
            ),
            cfg.deployer,
            _contractSalt(cfg.salt, "MILESTONE_POLICY")
        );
        console.log("MilestonePolicy:", dep.milestonePolicy);

        dep.dutchDecayPolicy = _deployCreate3(
            abi.encodePacked(
                type(DutchDecayPolicy).creationCode,
                abi.encode(dep.portal, cfg.scheduleRelays)
            ),
            cfg.deployer,
            _contractSalt(cfg.salt, "DUTCH_DECAY_POLICY")
        );
        console.log("DutchDecayPolicy:", dep.dutchDecayPolicy);
    }

    // --- Deterministic-deploy primitives -----------------------------------

    function _contractSalt(
        bytes32 rootSalt,
        string memory name
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(rootSalt, keccak256(abi.encodePacked(name))));
    }

    function _ensureCreate3Deployer(bool isTron) internal {
        if (address(CREATE3_DEPLOYER_C).code.length == 0) {
            address deployed = _deployCreate2(
                CREATE3_DEPLOYER_BYTECODE,
                bytes32(0),
                isTron
            );
            require(
                deployed == address(CREATE3_DEPLOYER_C),
                "unexpected CREATE3 deployer address"
            );
            console.log("Bootstrapped CREATE3 deployer:", deployed);
        }
    }

    function _deployCreate2(
        bytes memory bytecode,
        bytes32 salt,
        bool isTron
    ) internal returns (address addr) {
        addr = _predictCreate2(bytecode, salt, isTron);
        if (addr.code.length > 0) {
            return addr;
        }
        address justDeployed = CREATE2_SINGLETON.deploy(bytecode, salt);
        require(addr == justDeployed, "CREATE2 address mismatch");
        require(addr.code.length > 0, "CREATE2 deploy failed");
    }

    function _predictCreate2(
        bytes memory bytecode,
        bytes32 salt,
        bool isTron
    ) internal pure returns (address) {
        bytes1 prefix = isTron ? bytes1(0x41) : bytes1(0xff);
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                prefix,
                                address(CREATE2_SINGLETON),
                                salt,
                                keccak256(bytecode)
                            )
                        )
                    )
                )
            );
    }

    function _deployCreate3(
        bytes memory bytecode,
        address sender,
        bytes32 salt
    ) internal returns (address addr) {
        addr = CREATE3_DEPLOYER_C.deployedAddress(bytecode, sender, salt);
        if (addr.code.length > 0) {
            return addr;
        }
        address justDeployed = CREATE3_DEPLOYER_C.deploy(bytecode, salt);
        require(addr == justDeployed, "CREATE3 address mismatch");
        require(addr.code.length > 0, "CREATE3 deploy failed");
    }

    // --- Env / output -------------------------------------------------------

    function _readConfig(bool isTron) internal returns (Config memory cfg) {
        cfg.isTron = isTron;
        cfg.salt = vm.envBytes32("SALT");
        cfg.deployer = vm.rememberKey(
            vm.envOr("DEPLOYER_PRIVATE_KEY", vm.envUint("PRIVATE_KEY"))
        );
        cfg.mailbox = vm.envOr("MAILBOX_CONTRACT", address(0));
        cfg.router = vm.envOr("ROUTER_CONTRACT", address(0));
        cfg.lzEndpoint = vm.envOr("LAYERZERO_ENDPOINT", address(0));
        cfg.lzDelegate = vm.envOr("LAYERZERO_DELEGATE", cfg.deployer);
        cfg.ccipRouter = vm.envOr("CCIP_ROUTER", address(0));
        cfg.polymerCrossL2Prover = vm.envOr(
            "POLYMER_CROSS_L2_PROVER_V2",
            address(0)
        );
        cfg.polymerMaxLogDataSize = vm.envOr(
            "POLYMER_MAX_LOG_DATA_SIZE",
            DEFAULT_POLYMER_MAX_LOG_DATA_SIZE
        );
        cfg.minGasLimit = vm.envOr("MIN_GAS_LIMIT", DEFAULT_MIN_GAS_LIMIT);
        cfg.hyperCrossVm = _envPeers("HYPER_CROSS_VM_PROVERS");
        cfg.metaCrossVm = _envPeers("META_CROSS_VM_PROVERS");
        cfg.lzCrossVm = _envPeers("LAYERZERO_CROSS_VM_PROVERS");
        cfg.ccipCrossVm = _envPeers("CCIP_CROSS_VM_PROVERS");
        cfg.polymerCrossVm = _envPeers("POLYMER_CROSS_VM_PROVERS");
        cfg.deployLocalPolicy = vm.envOr("DEPLOY_LOCAL_POLICY", true);
        cfg.deploySchedulePolicies = vm.envOr(
            "DEPLOY_SCHEDULE_POLICIES",
            false
        );
        cfg.scheduleRelays = _envPeers("SCHEDULE_RELAYS");
    }

    function _envPeers(
        string memory name
    ) internal view returns (bytes32[] memory list) {
        try vm.envBytes32(name, ",") returns (bytes32[] memory v) {
            list = v;
        } catch {
            list = new bytes32[](0);
        }
    }

    function _writeDeployFile(Config memory cfg, Deployment memory dep) internal {
        string memory path = vm.envOr("DEPLOY_FILE", string(""));
        if (bytes(path).length == 0) {
            return;
        }
        _writeLine(path, dep.portal, "Portal");
        _writeLine(path, dep.portalImplementation, "PortalImplementation");
        _writeLine(path, dep.erc7683Implementation, "ERC7683Implementation");
        _writeLine(path, dep.runtime, "MulticallRuntime");
        _writeLine(path, dep.localPolicy, "LocalPolicy");
        _writeLine(path, dep.hyperPolicy, "HyperPolicy");
        _writeLine(path, dep.metaPolicy, "MetaPolicy");
        _writeLine(path, dep.layerZeroPolicy, "LayerZeroPolicy");
        _writeLine(path, dep.ccipPolicy, "CCIPPolicy");
        _writeLine(path, dep.polymerPolicy, "PolymerPolicy");
        _writeLine(path, dep.streamingPolicy, "StreamingPolicy");
        _writeLine(path, dep.vestingPolicy, "VestingPolicy");
        _writeLine(path, dep.milestonePolicy, "MilestonePolicy");
        _writeLine(path, dep.dutchDecayPolicy, "DutchDecayPolicy");
    }

    function _writeLine(
        string memory path,
        address addr,
        string memory name
    ) internal {
        if (addr == address(0)) {
            return;
        }
        vm.writeLine(
            path,
            string(
                abi.encodePacked(
                    vm.toString(block.chainid),
                    ",",
                    vm.toString(addr),
                    ",",
                    name
                )
            )
        );
    }
}
