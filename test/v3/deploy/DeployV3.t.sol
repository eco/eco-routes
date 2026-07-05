// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {DeployV3} from "../../../scripts/DeployV3.s.sol";

import {ICreate3Deployer} from "../../../contracts/tools/ICreate3Deployer.sol";
import {AddressConverter} from "../../../contracts/libs/AddressConverter.sol";

import {Portal} from "../../../contracts/Portal.sol";
import {PortalProxy} from "../../../contracts/PortalProxy.sol";
import {ERC7683Implementation} from "../../../contracts/ERC7683/ERC7683Implementation.sol";
// Aliased: forge-std's StdCheats defines a `struct Account` that shadows this import in Test contracts.
import {Account as EcoAccount} from "../../../contracts/account/Account.sol";
import {MulticallRuntime} from "../../../contracts/runtime/MulticallRuntime.sol";
import {HyperPolicy} from "../../../contracts/prover/HyperPolicy.sol";
import {VestingPolicy} from "../../../contracts/prover/VestingPolicy.sol";

import {MockLayerZeroEndpoint} from "../../../contracts/test/MockLayerZeroEndpoint.sol";
import {TestMailbox} from "../../../contracts/test/TestMailbox.sol";
import {TestMetaRouter} from "../../../contracts/test/TestMetaRouter.sol";
import {TestCCIPRouter} from "../../../contracts/test/TestCCIPRouter.sol";

/**
 * @title DeployV3Test
 * @notice In-VM proof that {DeployV3.deploy} brings up the Eco Routes v3 set deterministically, and — the
 *         C1-critical property — that each transport policy stores its self-reference peer RIGHT-aligned so
 *         EVM<->EVM proofs authenticate.
 */
contract DeployV3Test is Test {
    using AddressConverter for address;

    address internal constant SINGLETON_FACTORY =
        0xce0042B868300000d44A59004Da54A005ffdcf9f;
    address internal constant CREATE3_DEPLOYER =
        0xC6BAd1EbAF366288dA6FB5689119eDd695a66814;

    bytes32 internal constant SALT = keccak256("ECO_ROUTES_V3_TEST_SALT");

    bytes32 internal constant HYPER_PEER = bytes32(uint256(0xA11CE));
    bytes32 internal constant META_PEER = bytes32(uint256(0xB0B));
    bytes32 internal constant LZ_PEER = bytes32(uint256(0xCA11));
    bytes32 internal constant CCIP_PEER = bytes32(uint256(0xE55E));

    DeployV3 internal script;
    MockLayerZeroEndpoint internal lz;
    TestMailbox internal mailbox;
    TestMetaRouter internal meta;
    TestCCIPRouter internal ccip;
    address internal poly = address(0xD00D); // PolymerPolicy ctor only stores it

    function setUp() public {
        vm.warp(1_000_000);

        // Etch the SingletonFactory at its canonical address; the script bootstraps the CREATE3 deployer.
        vm.etch(
            SINGLETON_FACTORY,
            vm.getDeployedCode(
                "contracts/tools/SingletonFactory.sol:SingletonFactory"
            )
        );

        lz = new MockLayerZeroEndpoint(); // LZ policy makes a live setDelegate call
        mailbox = new TestMailbox(address(0));
        meta = new TestMetaRouter(address(0));
        ccip = new TestCCIPRouter(address(0));

        script = new DeployV3();
    }

    function _cfg() internal view returns (DeployV3.Config memory c) {
        c.salt = SALT;
        c.deployer = address(script); // in-VM CREATE3 msg.sender is the script
        c.isTron = false;
        c.mailbox = address(mailbox);
        c.router = address(meta);
        c.lzEndpoint = address(lz);
        c.lzDelegate = address(script);
        c.ccipRouter = address(ccip);
        c.polymerCrossL2Prover = poly;
        c.hyperCrossVm = _one(HYPER_PEER);
        c.metaCrossVm = _one(META_PEER);
        c.lzCrossVm = _one(LZ_PEER);
        c.ccipCrossVm = _one(CCIP_PEER);
        c.polymerCrossVm = new bytes32[](0);
        c.deployLocalPolicy = true;
        c.deploySchedulePolicies = true;
        c.scheduleRelays = _one(bytes32(uint256(0xF00D)));
    }

    function _one(bytes32 v) internal pure returns (bytes32[] memory a) {
        a = new bytes32[](1);
        a[0] = v;
    }

    function _contractSalt(
        bytes32 root,
        string memory name
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(root, keccak256(abi.encodePacked(name))));
    }

    // (a) EXISTENCE ---------------------------------------------------------

    function test_a_everyContractDeployed() public {
        DeployV3.Deployment memory dep = script.deploy(_cfg());

        assertGt(CREATE3_DEPLOYER.code.length, 0, "create3 deployer bootstrapped");
        assertGt(dep.portal.code.length, 0, "portal");
        assertGt(dep.runtime.code.length, 0, "runtime");
        assertGt(dep.localPolicy.code.length, 0, "localPolicy");
        assertGt(dep.hyperPolicy.code.length, 0, "hyperPolicy");
        assertGt(dep.metaPolicy.code.length, 0, "metaPolicy");
        assertGt(dep.layerZeroPolicy.code.length, 0, "layerZeroPolicy");
        assertGt(dep.ccipPolicy.code.length, 0, "ccipPolicy");
        assertGt(dep.polymerPolicy.code.length, 0, "polymerPolicy");
        assertGt(dep.streamingPolicy.code.length, 0, "streamingPolicy");
        assertGt(dep.vestingPolicy.code.length, 0, "vestingPolicy");
        assertGt(dep.milestonePolicy.code.length, 0, "milestonePolicy");
        assertGt(dep.dutchDecayPolicy.code.length, 0, "dutchDecayPolicy");
    }

    function test_a_zeroEndpointBridgeSkipped() public {
        DeployV3.Config memory c = _cfg();
        c.mailbox = address(0);
        c.ccipRouter = address(0);
        c.salt = keccak256("SKIP_SALT");

        DeployV3.Deployment memory dep = script.deploy(c);

        assertEq(dep.hyperPolicy, address(0), "hyper skipped");
        assertEq(dep.ccipPolicy, address(0), "ccip skipped");
        assertGt(dep.layerZeroPolicy.code.length, 0, "lz still deployed");
        assertGt(dep.metaPolicy.code.length, 0, "meta still deployed");
    }

    // (b) DETERMINISM -------------------------------------------------------

    function test_b_create2AddressesReDerivable() public {
        DeployV3.Deployment memory dep = script.deploy(_cfg());

        // The PERMANENT Portal is the PortalProxy, deployed at SALT with the deployer as owner.
        assertEq(
            dep.portal,
            _predictCreate2(
                abi.encodePacked(
                    type(PortalProxy).creationCode,
                    abi.encode(address(script)) // cfg.deployer = owner
                ),
                SALT
            ),
            "portal proxy CREATE2"
        );
        // The shared Account implementation is bound to the proxy and deployed at a derived salt.
        address accountImpl = _predictCreate2(
            abi.encodePacked(
                type(EcoAccount).creationCode,
                abi.encode(dep.portal)
            ),
            _contractSalt(SALT, "ACCOUNT_IMPLEMENTATION")
        );
        // The ERC-7683 adapter (PR10) is deployed at a derived salt with no constructor args.
        address erc7683Impl = _predictCreate2(
            type(ERC7683Implementation).creationCode,
            _contractSalt(SALT, "ERC7683_IMPLEMENTATION")
        );
        assertEq(
            dep.erc7683Implementation,
            erc7683Impl,
            "erc7683 implementation CREATE2"
        );
        // The version-1 Portal implementation references the shared Account implementation AND the ERC-7683
        // adapter (its fallback target).
        assertEq(
            dep.portalImplementation,
            _predictCreate2(
                abi.encodePacked(
                    type(Portal).creationCode,
                    abi.encode(accountImpl, erc7683Impl)
                ),
                _contractSalt(SALT, "PORTAL_IMPLEMENTATION_V1")
            ),
            "portal implementation CREATE2"
        );
        assertEq(
            dep.runtime,
            _predictCreate2(
                type(MulticallRuntime).creationCode,
                _contractSalt(SALT, "MULTICALL_RUNTIME")
            ),
            "runtime CREATE2"
        );
    }

    function test_b_create3AddressesReDerivable() public {
        DeployV3.Deployment memory dep = script.deploy(_cfg());
        ICreate3Deployer c3 = ICreate3Deployer(CREATE3_DEPLOYER);

        assertEq(
            dep.hyperPolicy,
            c3.deployedAddress(
                bytes(""),
                address(script),
                _contractSalt(SALT, "HYPER_POLICY")
            ),
            "hyper CREATE3"
        );
        assertEq(
            dep.vestingPolicy,
            c3.deployedAddress(
                bytes(""),
                address(script),
                _contractSalt(SALT, "VESTING_POLICY")
            ),
            "vesting CREATE3"
        );
    }

    function test_b_reDeployIsIdempotent() public {
        DeployV3.Deployment memory a = script.deploy(_cfg());
        DeployV3.Deployment memory b = script.deploy(_cfg());

        assertEq(a.portal, b.portal, "portal stable");
        assertEq(a.hyperPolicy, b.hyperPolicy, "hyper stable");
        assertEq(a.vestingPolicy, b.vestingPolicy, "vesting stable");
    }

    // (c) C1 — self-reference RIGHT-aligned ---------------------------------

    function test_c1_selfReferenceIsRightAligned() public {
        DeployV3.Deployment memory dep = script.deploy(_cfg());

        _assertRightAlignedSelf(dep.hyperPolicy, HYPER_PEER, dep.portal);
        _assertRightAlignedSelf(dep.metaPolicy, META_PEER, dep.portal);
        _assertRightAlignedSelf(dep.layerZeroPolicy, LZ_PEER, dep.portal);
        _assertRightAlignedSelf(dep.ccipPolicy, CCIP_PEER, dep.portal);
    }

    /**
     * @dev The self-peer MUST be RIGHT-aligned (AddressConverter.toBytes32) — the form every transport
     *      delivers the cross-chain sender in. The LEFT-aligned bytes32(bytes20(self)) form would make the
     *      immutable whitelist `==` never match, rejecting every EVM<->EVM proof (funds lock). Assert the
     *      canonical form is stored and authenticates, and that the left-aligned form does NOT.
     */
    function _assertRightAlignedSelf(
        address policy,
        bytes32 crossVmPeer,
        address portal
    ) internal view {
        HyperPolicy p = HyperPolicy(policy); // any transport shares the Whitelist/PORTAL surface
        assertEq(p.PORTAL(), portal, "PORTAL == portal");

        bytes32 selfRight = policy.toBytes32(); // bytes32(uint256(uint160(policy)))
        bytes32 selfLeft = bytes32(bytes20(policy)); // the C1 regression form

        bytes32[] memory wl = p.getWhitelist();
        assertEq(wl.length, 2, "whitelist = self + 1 cross-VM");
        assertEq(wl[0], selfRight, "peer[0] == right-aligned self");
        assertEq(wl[1], crossVmPeer, "peer[1] == cross-VM peer");

        assertTrue(p.isWhitelisted(selfRight), "right-aligned self authenticates");
        assertTrue(p.isWhitelisted(crossVmPeer), "cross-VM peer authenticates");
        assertFalse(
            p.isWhitelisted(selfLeft),
            "left-aligned self must NOT authenticate (C1)"
        );
    }

    // (d) wiring spot checks ------------------------------------------------

    function test_d_schedulePortalWiring() public {
        DeployV3.Deployment memory dep = script.deploy(_cfg());
        assertEq(
            VestingPolicy(dep.vestingPolicy).PORTAL(),
            dep.portal,
            "vesting PORTAL == portal"
        );
    }

    // helpers ---------------------------------------------------------------

    function _predictCreate2(
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
                                SINGLETON_FACTORY,
                                salt,
                                keccak256(bytecode)
                            )
                        )
                    )
                )
            );
    }
}
