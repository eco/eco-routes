// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../../scripts/Deploy.s.sol";
import {Portal} from "../../contracts/Portal.sol";
import {TestMailbox} from "../../contracts/test/TestMailbox.sol";

/// @dev Harness exposing Deploy's prover deploy steps, which stamp the deployed
///      address into ctx rather than returning it
contract DeployProverReuseHarness is Deploy {
    function emptyContext()
        external
        pure
        returns (DeploymentContext memory ctx)
    {
        return ctx;
    }

    function create3DeployerBytecode() external pure returns (bytes memory) {
        return CREATE3_DEPLOYER_BYTECODE;
    }

    function create3DeployerAddress() external pure returns (address) {
        return address(create3Deployer);
    }

    function predictedAddress(bytes32 salt) external view returns (address) {
        return create3Deployer.deployedAddress("", address(this), salt);
    }

    function exposedDeployHyperProver(
        DeploymentContext memory ctx
    ) external returns (address) {
        deployHyperProver(ctx);
        return ctx.hyperProver;
    }

    function exposedDeployMetaProver(
        DeploymentContext memory ctx
    ) external returns (address) {
        deployMetaProver(ctx);
        return ctx.metaProver;
    }

    function exposedDeployLayerZeroProver(
        DeploymentContext memory ctx
    ) external returns (address) {
        deployLayerZeroProver(ctx);
        return ctx.layerZeroProver;
    }

    function exposedDeployPolymerProver(
        DeploymentContext memory ctx
    ) external returns (address) {
        deployPolymerProver(ctx);
        return ctx.polymerProver;
    }
}

/// @dev Stands in for a prover a previous release left at the CREATE3 address:
///      bound to `portal`, and returning either the current three-word
///      ProofData or the pre-cancellation two-word one
contract StaleProver {
    address public immutable PORTAL;
    bool internal immutable LEGACY_SHAPE;

    constructor(address portal, bool legacyShape) {
        PORTAL = portal;
        LEGACY_SHAPE = legacyShape;
    }

    function provenIntents(bytes32) external view returns (bytes32) {
        bool legacy = LEGACY_SHAPE;
        assembly {
            mstore(0x00, 0)
            mstore(0x20, 0)
            mstore(0x40, 0)
            return(0x00, add(64, mul(iszero(legacy), 32)))
        }
    }
}

/// @dev A run with an unchanged SALT lands every prover on the previous
///      release's CREATE3 address; the script must refuse to reuse one that
///      is bound to another Portal or returns the old ProofData, while a
///      same-release re-run still passes
contract DeployProverReuseTest is Test {
    DeployProverReuseHarness internal harness;
    Portal internal portal;
    address internal otherPortal = address(uint160(0xBEEF));

    string internal constant STALE_PORTAL =
        " already deployed at this salt is bound to a different Portal; deploy this release at a new SALT";
    string internal constant STALE_SHAPE =
        " already deployed at this salt does not return the current ProofData; deploy this release at a new SALT";

    function setUp() public {
        harness = new DeployProverReuseHarness();
        portal = new Portal(address(0));

        bytes memory create3 = harness.create3DeployerBytecode();
        address tmp;
        assembly {
            tmp := create(0, add(create3, 0x20), mload(create3))
        }
        vm.etch(harness.create3DeployerAddress(), tmp.code);
    }

    function _ctx() internal returns (Deploy.DeploymentContext memory ctx) {
        ctx = harness.emptyContext();
        ctx.deployer = address(harness);
        ctx.portal = address(portal);
        ctx.mailbox = address(new TestMailbox(address(0)));
        ctx.hyperProverSalt = keccak256("hyper");
        ctx.metaProverSalt = keccak256("meta");
        ctx.layerZeroProverSalt = keccak256("layerzero");
        ctx.polymerProverSalt = keccak256("polymer");
    }

    function _plant(bytes32 salt, address boundPortal, bool legacy) internal {
        StaleProver stale = new StaleProver(boundPortal, legacy);
        vm.etch(harness.predictedAddress(salt), address(stale).code);
    }

    function test_hyperProverRerunWithSameContextSucceeds() public {
        Deploy.DeploymentContext memory ctx = _ctx();

        address first = harness.exposedDeployHyperProver(ctx);
        address second = harness.exposedDeployHyperProver(ctx);

        assertEq(first, second);
        assertTrue(first.code.length > 0);
    }

    function test_hyperProverBoundToAnotherPortalReverts() public {
        Deploy.DeploymentContext memory ctx = _ctx();
        harness.exposedDeployHyperProver(ctx);

        ctx.portal = otherPortal;
        vm.expectRevert(bytes(string.concat("HyperProver", STALE_PORTAL)));
        harness.exposedDeployHyperProver(ctx);
    }

    function test_hyperProverWithOldProofShapeReverts() public {
        Deploy.DeploymentContext memory ctx = _ctx();
        _plant(ctx.hyperProverSalt, address(portal), true);

        vm.expectRevert(bytes(string.concat("HyperProver", STALE_SHAPE)));
        harness.exposedDeployHyperProver(ctx);
    }

    function test_metaProverStaleReuseReverts() public {
        Deploy.DeploymentContext memory ctx = _ctx();
        _plant(ctx.metaProverSalt, otherPortal, false);

        vm.expectRevert(bytes(string.concat("MetaProver", STALE_PORTAL)));
        harness.exposedDeployMetaProver(ctx);

        _plant(ctx.metaProverSalt, address(portal), true);
        vm.expectRevert(bytes(string.concat("MetaProver", STALE_SHAPE)));
        harness.exposedDeployMetaProver(ctx);

        _plant(ctx.metaProverSalt, address(portal), false);
        harness.exposedDeployMetaProver(ctx);
    }

    function test_layerZeroProverStaleReuseReverts() public {
        Deploy.DeploymentContext memory ctx = _ctx();
        _plant(ctx.layerZeroProverSalt, otherPortal, false);

        vm.expectRevert(bytes(string.concat("LayerZeroProver", STALE_PORTAL)));
        harness.exposedDeployLayerZeroProver(ctx);

        _plant(ctx.layerZeroProverSalt, address(portal), true);
        vm.expectRevert(bytes(string.concat("LayerZeroProver", STALE_SHAPE)));
        harness.exposedDeployLayerZeroProver(ctx);

        _plant(ctx.layerZeroProverSalt, address(portal), false);
        harness.exposedDeployLayerZeroProver(ctx);
    }

    function test_polymerProverStaleReuseReverts() public {
        Deploy.DeploymentContext memory ctx = _ctx();
        ctx.polymerSolanaProver = keccak256("solana program id");
        _plant(ctx.polymerProverSalt, otherPortal, false);

        vm.expectRevert(bytes(string.concat("PolymerProver", STALE_PORTAL)));
        harness.exposedDeployPolymerProver(ctx);

        _plant(ctx.polymerProverSalt, address(portal), true);
        vm.expectRevert(bytes(string.concat("PolymerProver", STALE_SHAPE)));
        harness.exposedDeployPolymerProver(ctx);
    }

    function test_proverWithoutPortalGetterReverts() public {
        Deploy.DeploymentContext memory ctx = _ctx();
        vm.etch(harness.predictedAddress(ctx.hyperProverSalt), hex"00");

        vm.expectRevert(bytes(string.concat("HyperProver", STALE_PORTAL)));
        harness.exposedDeployHyperProver(ctx);
    }
}
