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

    function exposedPolymerProverWhitelist(
        DeploymentContext memory ctx
    ) external pure returns (bytes32[] memory) {
        return polymerProverWhitelist(ctx);
    }

    function exposedValidatePolymerProverMatchesContext(
        DeploymentContext memory ctx
    ) external view {
        _validatePolymerProverMatchesContext(ctx);
    }

    function exposedParseBytes32List(
        string memory csv,
        string memory varName
    ) external pure returns (bytes32[] memory) {
        return _parseBytes32List(csv, varName);
    }

    function defaultPolymerMaxLogDataSize() external pure returns (uint256) {
        return DEFAULT_POLYMER_MAX_LOG_DATA_SIZE;
    }

    function maxWhitelistSize() external pure returns (uint256) {
        return MAX_WHITELIST_SIZE;
    }

    function create3DeployerBytecode() external pure returns (bytes memory) {
        return CREATE3_DEPLOYER_BYTECODE;
    }

    function create3DeployerAddress() external pure returns (address) {
        return address(create3Deployer);
    }

    function exposedGetContractSalt(
        bytes32 rootSalt,
        string memory contractName
    ) external pure returns (bytes32) {
        return getContractSalt(rootSalt, contractName);
    }

    /// @dev deployPolymerProver stamps ctx.polymerProver rather than returning
    ///      it, so hand the stamped address back to the test.
    function exposedDeployPolymerProver(
        DeploymentContext memory ctx
    ) external returns (address) {
        deployPolymerProver(ctx);
        return ctx.polymerProver;
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
    bytes32 internal constant EVM_PROVER =
        bytes32(uint256(uint160(address(0xA11CE))));
    bytes32 internal constant SOLANA_PROGRAM_ID =
        keccak256("solana program id");

    // Unique names: vm.setEnv mutates the real process environment, so these
    // must not collide with anything another test (or .env) could set.
    string internal constant ENV_UNSET = "PAR670_TEST_UNSET_CHAIN_ID";
    string internal constant ENV_EMPTY = "PAR670_TEST_EMPTY_CHAIN_ID";
    string internal constant ENV_ZERO = "PAR670_TEST_ZERO_CHAIN_ID";
    string internal constant ENV_OVER = "PAR670_TEST_OVER_RANGE_CHAIN_ID";
    string internal constant ENV_MAX = "PAR670_TEST_MAX_CHAIN_ID";
    string internal constant ENV_VALID = "PAR670_TEST_VALID_CHAIN_ID";

    function setUp() public {
        harness = new DeployPolymerProverArgsHarness();
        portal = new Portal(address(0));
    }

    /// @dev The context run() would build: one EVM cross-VM prover configured,
    ///      the Solana program key in its own field. polymerProverWhitelist(ctx)
    ///      therefore equals _provers().
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
        ctx.polymerCrossVmProvers = new bytes32[](1);
        ctx.polymerCrossVmProvers[0] = EVM_PROVER;
        ctx.polymerSolanaProver = SOLANA_PROGRAM_ID;
    }

    function _provers() internal pure returns (bytes32[] memory provers) {
        provers = new bytes32[](2);
        provers[0] = EVM_PROVER;
        provers[1] = SOLANA_PROGRAM_ID;
    }

    /// @dev Deploys the reference instance through the script's own seams (the
    ///      whitelist assembly and the bytecode blob) and stamps ctx.polymerProver
    ///      the way deployWithCreate3 does, so the rerun guard sees a live
    ///      contract built from exactly this context.
    function _deployedCtx()
        internal
        returns (Deploy.DeploymentContext memory ctx)
    {
        ctx = _ctx();
        ctx.polymerProver = _create(
            harness.exposedPolymerProverBytecode(
                ctx,
                harness.exposedPolymerProverWhitelist(ctx)
            )
        );
        assertTrue(ctx.polymerProver != address(0), "create failed");
    }

    function _create(bytes memory bytecode) internal returns (address addr) {
        assembly {
            addr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
    }

    /// @dev `create3Deployer` is a hard-coded constant with no code in a bare forge
    ///      test. Deploy the real Create3Deployer bytecode once and etch its runtime
    ///      code at that address: the runtime derives CREATE3 addresses from
    ///      address(this) at call time, so the etched copy behaves like the real one.
    function _installCreate3Deployer() internal {
        address tmp = _create(harness.create3DeployerBytecode());
        assertTrue(tmp != address(0), "Create3Deployer create failed");
        vm.etch(harness.create3DeployerAddress(), tmp.code);
    }

    /// @dev The context deployPolymerProver needs on top of _ctx(): the CREATE3
    ///      sender must be the harness (Create3Deployer.deploy salts on msg.sender
    ///      while deployedAddress takes it explicitly, and deployWithCreate3
    ///      requires the two to agree) and the salt run() would derive.
    function _deployCtx()
        internal
        view
        returns (Deploy.DeploymentContext memory ctx)
    {
        ctx = _ctx();
        ctx.deployer = address(harness);
        ctx.salt = keccak256("PAR670 deploy test salt");
        ctx.polymerProverSalt = harness.exposedGetContractSalt(
            ctx.salt,
            "POLYMER_PROVER"
        );
    }

    function _distinctProvers(
        uint256 n
    ) internal pure returns (bytes32[] memory provers) {
        provers = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            provers[i] = keccak256(abi.encode("evm prover", i));
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

    // ------------- WHITELIST ASSEMBLY -------------

    function test_polymerProverWhitelistAppendsSolanaProgramId() public view {
        bytes32[] memory whitelist = harness.exposedPolymerProverWhitelist(
            _ctx()
        );
        assertEq(whitelist.length, 2);
        assertEq(whitelist[0], EVM_PROVER);
        assertEq(whitelist[1], SOLANA_PROGRAM_ID);
    }

    function test_polymerProverWhitelistDedupesSolanaProgramId() public view {
        // Whitelist caps at 20 slots: an operator who also pasted the program
        // key into POLYMER_CROSS_VM_PROVERS must not burn a slot on it twice.
        Deploy.DeploymentContext memory ctx = _ctx();
        ctx.polymerCrossVmProvers = new bytes32[](2);
        ctx.polymerCrossVmProvers[0] = SOLANA_PROGRAM_ID;
        ctx.polymerCrossVmProvers[1] = EVM_PROVER;

        bytes32[] memory whitelist = harness.exposedPolymerProverWhitelist(ctx);
        assertEq(whitelist.length, 2);
        uint256 occurrences;
        for (uint256 i = 0; i < whitelist.length; i++) {
            if (whitelist[i] == SOLANA_PROGRAM_ID) occurrences++;
        }
        assertEq(occurrences, 1);
    }

    // Whitelist's constructor caps at 20 slots; polymerProverWhitelist mirrors the
    // cap so it fails by name before broadcast instead of as a bare CREATE3 revert.

    function test_polymerProverWhitelistRevertsWhenAppendWouldExceedCap()
        public
    {
        Deploy.DeploymentContext memory ctx = _ctx();
        ctx.polymerCrossVmProvers = _distinctProvers(
            harness.maxWhitelistSize()
        );
        vm.expectRevert(
            bytes(
                "POLYMER_CROSS_VM_PROVERS + POLYMER_SOLANA_PROVER exceed the 20-slot whitelist"
            )
        );
        harness.exposedPolymerProverWhitelist(ctx);
    }

    function test_polymerProverWhitelistRevertsWhenConfiguredAloneExceedsCap()
        public
    {
        // The dedupe path: the program ID is already in the list, so nothing is
        // appended, yet 21 configured entries still overflow the constructor.
        Deploy.DeploymentContext memory ctx = _ctx();
        ctx.polymerCrossVmProvers = _distinctProvers(
            harness.maxWhitelistSize() + 1
        );
        ctx.polymerCrossVmProvers[3] = SOLANA_PROGRAM_ID;
        vm.expectRevert(
            bytes("POLYMER_CROSS_VM_PROVERS exceeds the 20-slot whitelist")
        );
        harness.exposedPolymerProverWhitelist(ctx);
    }

    function test_polymerProverWhitelistAcceptsExactlyTwenty() public view {
        uint256 cap = harness.maxWhitelistSize();

        // 19 distinct plus the appended program ID
        Deploy.DeploymentContext memory ctx = _ctx();
        ctx.polymerCrossVmProvers = _distinctProvers(cap - 1);
        assertEq(harness.exposedPolymerProverWhitelist(ctx).length, cap);

        // 20 configured, one of which IS the program ID (nothing appended)
        ctx.polymerCrossVmProvers = _distinctProvers(cap);
        ctx.polymerCrossVmProvers[cap - 1] = SOLANA_PROGRAM_ID;
        assertEq(harness.exposedPolymerProverWhitelist(ctx).length, cap);
    }

    function test_polymerProverWhitelistRevertsWithoutSolanaProgramId() public {
        Deploy.DeploymentContext memory ctx = _ctx();
        ctx.polymerSolanaProver = bytes32(0);
        vm.expectRevert(
            bytes(
                "POLYMER_SOLANA_PROVER is required when POLYMER_CROSS_L2_PROVER_V2 is set"
            )
        );
        harness.exposedPolymerProverWhitelist(ctx);
    }

    function test_deployedFromScriptArgsWhitelistsSolanaProgramId() public {
        PolymerProver prover = PolymerProver(
            payable(_deployedCtx().polymerProver)
        );
        assertTrue(prover.isWhitelisted(SOLANA_PROGRAM_ID));
        assertTrue(prover.isWhitelisted(EVM_PROVER));
        assertFalse(prover.isWhitelisted(keccak256("not whitelisted")));
    }

    /// @dev POLYMER_CROSS_VM_PROVERS is parsed by the same explicit parser as
    ///      AGGREGATOR_PROVER_MEMBERS (not vm.envBytes32 behind a try/catch), so
    ///      the likeliest paste mistake — a base58 Solana key — reverts naming
    ///      the variable instead of silently yielding an empty whitelist.
    function test_parseBytes32ListRejectsBase58KeyByVariableName() public {
        vm.expectRevert(
            bytes(
                "POLYMER_CROSS_VM_PROVERS: malformed element at index 1: 'EcotL2wbUqtRAjnf1p6aa842dM4fc8ZX6JhygibtBreo' (expected a 20-byte address or 32-byte bytes32)"
            )
        );
        harness.exposedParseBytes32List(
            string.concat(
                vm.toString(address(0xA11CE)),
                ",EcotL2wbUqtRAjnf1p6aa842dM4fc8ZX6JhygibtBreo"
            ),
            "POLYMER_CROSS_VM_PROVERS"
        );
    }

    function test_parseBytes32ListAcceptsAddressAndBytes32Forms() public view {
        bytes32[] memory parsed = harness.exposedParseBytes32List(
            string.concat(
                vm.toString(address(0xA11CE)),
                ",",
                vm.toString(SOLANA_PROGRAM_ID)
            ),
            "POLYMER_CROSS_VM_PROVERS"
        );
        assertEq(parsed.length, 2);
        assertEq(parsed[0], EVM_PROVER);
        assertEq(parsed[1], SOLANA_PROGRAM_ID);
    }

    // ------------- MAX LOG DATA SIZE DEFAULT -------------

    /// @dev Pins the shipped default and states it in the unit operators reason
    ///      about: encodedProofs is 8 + 64*n bytes for an n-intent Inbox.prove batch,
    ///      so 2048 admits 31 intents and rejects 32.
    function test_defaultMaxLogDataSizeIs2048ForThirtyOneIntents() public {
        uint256 defaultSize = harness.defaultPolymerMaxLogDataSize();
        assertEq(defaultSize, 2048);
        assertTrue(8 + 64 * 31 <= defaultSize, "31 intents must fit");
        assertTrue(8 + 64 * 32 > defaultSize, "32 intents must not fit");

        Deploy.DeploymentContext memory ctx = _ctx();
        ctx.polymerMaxLogDataSize = defaultSize;
        PolymerProver prover = PolymerProver(
            payable(
                _create(
                    harness.exposedPolymerProverBytecode(
                        ctx,
                        harness.exposedPolymerProverWhitelist(ctx)
                    )
                )
            )
        );
        assertEq(prover.MAX_LOG_DATA_SIZE(), 2048);
    }

    // ------------- RERUN GUARD -------------

    /// @dev The guard's call site, not the validator: `deployed` is
    ///      deployWithCreate3's pre-existence flag, so the guard must run on the
    ///      rerun that lands on an occupied address. With the polarity inverted
    ///      (`if (!deployed)`) this rerun would return the stale address silently.
    function test_deployPolymerProverRerunWithChangedContextReverts() public {
        _installCreate3Deployer();
        Deploy.DeploymentContext memory ctx = _deployCtx();

        address first = harness.exposedDeployPolymerProver(ctx);
        assertTrue(first.code.length > 0, "first deploy did not land");
        assertEq(
            PolymerProver(payable(first)).SOLANA_CHAIN_ID(),
            SOLANA_CHAIN_ID
        );

        ctx.solanaChainId = SOLANA_CHAIN_ID + 1;
        vm.expectRevert(
            bytes(
                "PolymerProver already deployed at this salt with a different SOLANA_CHAIN_ID"
            )
        );
        harness.exposedDeployPolymerProver(ctx);
    }

    /// @dev The idempotent rerun the guard must allow: same context twice lands on
    ///      the same address and neither call reverts.
    function test_deployPolymerProverRerunWithSameContextSucceeds() public {
        _installCreate3Deployer();
        Deploy.DeploymentContext memory ctx = _deployCtx();

        address first = harness.exposedDeployPolymerProver(ctx);
        address second = harness.exposedDeployPolymerProver(ctx);
        assertEq(first, second);
        assertTrue(first.code.length > 0);
    }

    function test_rerunGuardAcceptsMatchingContext() public {
        harness.exposedValidatePolymerProverMatchesContext(_deployedCtx());
    }

    function test_rerunGuardRevertsOnPreSolanaProver() public {
        // Any contract without a SOLANA_CHAIN_ID getter stands in for a
        // PolymerProver deployed before the Solana upgrade.
        Deploy.DeploymentContext memory ctx = _deployedCtx();
        ctx.polymerProver = address(portal);
        vm.expectRevert(
            bytes(
                "live PolymerProver predates the Solana upgrade; deploy at a new SALT"
            )
        );
        harness.exposedValidatePolymerProverMatchesContext(ctx);
    }

    function test_rerunGuardRevertsOnPortalMismatch() public {
        Deploy.DeploymentContext memory ctx = _deployedCtx();
        ctx.portal = address(uint160(0xBEEF));
        vm.expectRevert(
            bytes(
                "PolymerProver already deployed at this salt with a different PORTAL"
            )
        );
        harness.exposedValidatePolymerProverMatchesContext(ctx);
    }

    function test_rerunGuardRevertsOnCrossL2ProverMismatch() public {
        Deploy.DeploymentContext memory ctx = _deployedCtx();
        ctx.polymerCrossL2ProverV2 = address(uint160(0xC0C1));
        vm.expectRevert(
            bytes(
                "PolymerProver already deployed at this salt with a different POLYMER_CROSS_L2_PROVER_V2"
            )
        );
        harness.exposedValidatePolymerProverMatchesContext(ctx);
    }

    function test_rerunGuardRevertsOnMaxLogDataSizeMismatch() public {
        Deploy.DeploymentContext memory ctx = _deployedCtx();
        ctx.polymerMaxLogDataSize = MAX_LOG_DATA_SIZE + 1;
        vm.expectRevert(
            bytes(
                "PolymerProver already deployed at this salt with a different POLYMER_MAX_LOG_DATA_SIZE"
            )
        );
        harness.exposedValidatePolymerProverMatchesContext(ctx);
    }

    function test_rerunGuardRevertsOnPolymerSolanaChainIdMismatch() public {
        Deploy.DeploymentContext memory ctx = _deployedCtx();
        ctx.polymerSolanaChainId = POLYMER_SOLANA_CHAIN_ID + 1;
        vm.expectRevert(
            bytes(
                "PolymerProver already deployed at this salt with a different POLYMER_SOLANA_CHAIN_ID"
            )
        );
        harness.exposedValidatePolymerProverMatchesContext(ctx);
    }

    function test_rerunGuardRevertsOnSolanaChainIdMismatch() public {
        Deploy.DeploymentContext memory ctx = _deployedCtx();
        ctx.solanaChainId = SOLANA_CHAIN_ID + 1;
        vm.expectRevert(
            bytes(
                "PolymerProver already deployed at this salt with a different SOLANA_CHAIN_ID"
            )
        );
        harness.exposedValidatePolymerProverMatchesContext(ctx);
    }

    function test_rerunGuardRevertsWhenLiveWhitelistLacksSolanaProver() public {
        // The rerun that actually happens: the program ID is only known once
        // the SVM side has deployed, so the operator adds it on a second run
        // and lands on the address deployed without it.
        Deploy.DeploymentContext memory ctx = _deployedCtx();
        ctx.polymerSolanaProver = keccak256("solana program id 2");
        vm.expectRevert(
            bytes(
                "PolymerProver already deployed at this salt without POLYMER_SOLANA_PROVER in its whitelist; redeploy at a new SALT"
            )
        );
        harness.exposedValidatePolymerProverMatchesContext(ctx);
    }

    function test_rerunGuardRevertsOnCrossVmProversMismatch() public {
        // Membership alone would pass (the program ID is still whitelisted);
        // only the ordered hash catches a changed EVM prover list.
        Deploy.DeploymentContext memory ctx = _deployedCtx();
        ctx.polymerCrossVmProvers = new bytes32[](2);
        ctx.polymerCrossVmProvers[0] = EVM_PROVER;
        ctx.polymerCrossVmProvers[1] = bytes32(
            uint256(uint160(address(0xB0B)))
        );
        vm.expectRevert(
            bytes(
                "PolymerProver already deployed at this salt with a different POLYMER_CROSS_VM_PROVERS whitelist; redeploy at a new SALT"
            )
        );
        harness.exposedValidatePolymerProverMatchesContext(ctx);
    }

    function test_rerunGuardRevertsOnReorderedWhitelist() public {
        // Deliberately order-sensitive: isWhitelisted cannot tell [A,B] from
        // [B,A], so the hash compare is what pins the conservative direction.
        Deploy.DeploymentContext memory ctx = _deployedCtx();
        ctx.polymerCrossVmProvers = new bytes32[](2);
        ctx.polymerCrossVmProvers[0] = SOLANA_PROGRAM_ID;
        ctx.polymerCrossVmProvers[1] = EVM_PROVER;
        vm.expectRevert(
            bytes(
                "PolymerProver already deployed at this salt with a different POLYMER_CROSS_VM_PROVERS whitelist; redeploy at a new SALT"
            )
        );
        harness.exposedValidatePolymerProverMatchesContext(ctx);
    }

    // ------------- REQUIRED CHAIN ID ENV -------------

    function test_requiredChainIdEnvRevertsWhenUnset() public {
        vm.expectRevert(
            bytes(
                "PAR670_TEST_UNSET_CHAIN_ID is required and must be non-zero when POLYMER_CROSS_L2_PROVER_V2 is set"
            )
        );
        harness.exposedRequiredChainIdEnv(ENV_UNSET, type(uint64).max);
    }

    function test_requiredChainIdEnvRevertsWhenEmpty() public {
        // `.env.example` ships these keys empty; vm.envOr treats an empty value
        // as unset and returns the 0 default, so the guard must still fire.
        vm.setEnv(ENV_EMPTY, "");
        vm.expectRevert(
            bytes(
                "PAR670_TEST_EMPTY_CHAIN_ID is required and must be non-zero when POLYMER_CROSS_L2_PROVER_V2 is set"
            )
        );
        harness.exposedRequiredChainIdEnv(ENV_EMPTY, type(uint32).max);
    }

    function test_requiredChainIdEnvRevertsWhenExplicitlyZero() public {
        vm.setEnv(ENV_ZERO, "0");
        vm.expectRevert(
            bytes(
                "PAR670_TEST_ZERO_CHAIN_ID is required and must be non-zero when POLYMER_CROSS_L2_PROVER_V2 is set"
            )
        );
        harness.exposedRequiredChainIdEnv(ENV_ZERO, type(uint32).max);
    }

    function test_requiredChainIdEnvRevertsWhenOverRange() public {
        // 2^32: fits uint64 but not uint32, and the old inline uint32 cast
        // would have wrapped it to 0 (or a nonzero id for other values).
        vm.setEnv(ENV_OVER, "4294967296");
        vm.expectRevert(bytes("PAR670_TEST_OVER_RANGE_CHAIN_ID out of range"));
        harness.exposedRequiredChainIdEnv(ENV_OVER, type(uint32).max);
    }

    function test_requiredChainIdEnvAcceptsMax() public {
        // Pins `raw <= max`: an off-by-one to `<` would reject the legitimate
        // maximum chain id, and no other test probes the boundary.
        vm.setEnv(ENV_MAX, vm.toString(uint256(type(uint32).max)));
        assertEq(
            harness.exposedRequiredChainIdEnv(ENV_MAX, type(uint32).max),
            type(uint32).max
        );
    }

    function test_requiredChainIdEnvReturnsValidValue() public {
        vm.setEnv(ENV_VALID, "1399811150");
        assertEq(
            harness.exposedRequiredChainIdEnv(ENV_VALID, type(uint64).max),
            1399811150
        );
    }
}
