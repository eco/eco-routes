// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../../scripts/Deploy.s.sol";
import {Portal} from "../../contracts/Portal.sol";
import {PolymerProver} from "../../contracts/prover/PolymerProver.sol";

/// @dev Harness exposing Deploy's PolymerProver bytecode seam and the
///      required-chain-id env reader to tests
contract DeployPolymerProverArgsHarness is Deploy {
    function emptyContext()
        external
        pure
        returns (DeploymentContext memory ctx)
    {
        return ctx;
    }

    function exposedPolymerProverBytecode(
        DeploymentContext memory ctx,
        bytes32[] memory provers
    ) external pure returns (bytes memory) {
        return polymerProverBytecode(ctx, provers);
    }

    function exposedPolymerProverConstructorArgs(
        DeploymentContext memory ctx,
        bytes32[] memory provers
    ) external pure returns (bytes memory) {
        return polymerProverConstructorArgs(ctx, provers);
    }

    function exposedRequiredChainIdEnv(
        string memory name,
        uint256 max
    ) external view returns (uint256) {
        return _requiredChainIdEnv(name, max);
    }
}

/// @dev Deploy.s.sol hand-encodes PolymerProver's constructor args, so the
///      compiler never checks arity or order against the constructor (main once
///      shipped a wrong-arity encode undetected). These tests drive the script's
///      own encode through a raw CREATE and read every immutable back, so a
///      dropped, added or reordered argument fails here because the script
///      drifted, not a duplicate of it.
contract DeployPolymerProverArgsTest is Test {
    DeployPolymerProverArgsHarness internal harness;
    Portal internal portal;

    // Mutually distinguishable values, so a width-compatible reorder is caught.
    address internal constant CROSS_L2_PROVER = address(uint160(0xC0C0));
    uint256 internal constant MAX_LOG_DATA_SIZE = 4096;
    uint32 internal constant POLYMER_SOLANA_CHAIN_ID = 7;
    uint64 internal constant SOLANA_CHAIN_ID = 1399811150;

    // Unique names: vm.setEnv mutates the real process environment, so these
    // must not collide with anything another test (or .env) could set.
    string internal constant ENV_UNSET = "PAR670_TEST_UNSET_CHAIN_ID";
    string internal constant ENV_OVER = "PAR670_TEST_OVER_RANGE_CHAIN_ID";
    string internal constant ENV_VALID = "PAR670_TEST_VALID_CHAIN_ID";

    function setUp() public {
        harness = new DeployPolymerProverArgsHarness();
        portal = new Portal(address(0));
    }

    function _ctx()
        internal
        view
        returns (Deploy.DeploymentContext memory ctx)
    {
        ctx = harness.emptyContext();
        ctx.portal = address(portal);
        ctx.polymerCrossL2ProverV2 = CROSS_L2_PROVER;
        ctx.polymerMaxLogDataSize = MAX_LOG_DATA_SIZE;
        ctx.polymerSolanaChainId = POLYMER_SOLANA_CHAIN_ID;
        ctx.solanaChainId = SOLANA_CHAIN_ID;
    }

    function _provers() internal pure returns (bytes32[] memory provers) {
        provers = new bytes32[](2);
        provers[0] = bytes32(uint256(uint160(address(0xA11CE))));
        provers[1] = keccak256("solana program id");
    }

    function _create(bytes memory bytecode) internal returns (address addr) {
        assembly {
            addr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
    }

    function test_polymerProverBytecodeDeploysWithScriptArgs() public {
        bytes32[] memory provers = _provers();
        bytes memory bytecode = harness.exposedPolymerProverBytecode(
            _ctx(),
            provers
        );

        address deployed = _create(bytecode);
        assertTrue(deployed != address(0), "create failed: args mis-encoded");

        PolymerProver prover = PolymerProver(payable(deployed));
        assertEq(prover.PORTAL(), address(portal));
        assertEq(address(prover.CROSS_L2_PROVER_V2()), CROSS_L2_PROVER);
        assertEq(prover.MAX_LOG_DATA_SIZE(), MAX_LOG_DATA_SIZE);
        assertEq(prover.SOLANA_POLYMER_CHAIN_ID(), POLYMER_SOLANA_CHAIN_ID);
        assertEq(prover.SOLANA_CHAIN_ID(), SOLANA_CHAIN_ID);
        assertEq(prover.getWhitelistSize(), 2);
        assertTrue(prover.isWhitelisted(provers[0]));
        assertTrue(prover.isWhitelisted(provers[1]));
    }

    function test_verificationArgsMatchDeployBlobTail() public view {
        bytes32[] memory provers = _provers();
        bytes memory args = harness.exposedPolymerProverConstructorArgs(
            _ctx(),
            provers
        );
        bytes memory bytecode = harness.exposedPolymerProverBytecode(
            _ctx(),
            provers
        );

        // The Etherscan payload is exactly the tail of the deployed blob.
        bytes memory creation = type(PolymerProver).creationCode;
        assertEq(bytecode.length, creation.length + args.length);
        bytes memory tail = new bytes(args.length);
        for (uint256 i = 0; i < tail.length; i++) {
            tail[i] = bytecode[creation.length + i];
        }
        assertEq(keccak256(tail), keccak256(args));
    }

    function test_requiredChainIdEnvRevertsWhenUnset() public {
        vm.expectRevert(
            bytes(
                "PAR670_TEST_UNSET_CHAIN_ID is required when POLYMER_CROSS_L2_PROVER_V2 is set"
            )
        );
        harness.exposedRequiredChainIdEnv(ENV_UNSET, type(uint64).max);
    }

    function test_requiredChainIdEnvRevertsWhenOverRange() public {
        // 2^32: fits uint64 but not uint32, and the old inline uint32 cast
        // would have wrapped it to 0 (or a nonzero id for other values).
        vm.setEnv(ENV_OVER, "4294967296");
        vm.expectRevert(bytes("PAR670_TEST_OVER_RANGE_CHAIN_ID out of range"));
        harness.exposedRequiredChainIdEnv(ENV_OVER, type(uint32).max);
    }

    function test_requiredChainIdEnvReturnsValidValue() public {
        vm.setEnv(ENV_VALID, "1399811150");
        assertEq(
            harness.exposedRequiredChainIdEnv(ENV_VALID, type(uint64).max),
            1399811150
        );
    }
}
