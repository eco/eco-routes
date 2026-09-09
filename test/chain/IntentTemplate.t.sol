// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IntentTemplate as T} from "../../contracts/chain/IntentTemplate.sol";
import {SolanaVault} from "../../contracts/chain/SolanaVault.sol";
import {Vault} from "../../contracts/vault/Vault.sol";
import {VaultTron} from "../../contracts/vault/VaultTron.sol";
import {Proxy} from "../../contracts/vault/Proxy.sol";
import {Reward, TokenAmount} from "../../contracts/types/Intent.sol";
import {TemplateFixtures as F} from "./TemplateFixtures.sol";

contract TemplateHarness {
    function render(
        T.Program calldata p,
        uint256 amountIn,
        uint256 amountOut
    ) external view returns (bytes memory) {
        return T.render(p, amountIn, amountOut);
    }
    function evm(
        bytes32 hash,
        T.EvmConfig calldata config
    ) external pure returns (bytes32) {
        return T.deriveEvm(hash, config);
    }
    function svm(
        bytes32 hash,
        T.SolanaConfig calldata config
    ) external view returns (bytes32, bytes32, uint8, uint8) {
        return
            SolanaVault.derive(
                hash,
                config.portalProgramId,
                config.tokenProgramId,
                config.mint
            );
    }
    function onCurve(bytes32 point) external view returns (bool) {
        return SolanaVault.isOnCurve(point);
    }
}

contract IntentTemplateTest is Test {
    TemplateHarness internal h;
    T.EvmConfig internal evmConfig;
    bytes32 internal constant HASH = keccak256("downstream intent");
    address internal constant STANDARD =
        0xEC000064576f9C95a8623Bc0eff3db6d296ea6df;
    address internal constant WORLD =
        0x95b1EB197B1F9c9035450A7D12722E397DE8F9eb;

    function setUp() public {
        h = new TemplateHarness();
        address implementation = address(new Vault());
        evmConfig = T.EvmConfig(
            STANDARD,
            0xff,
            implementation,
            keccak256(
                bytes.concat(
                    type(Proxy).creationCode,
                    abi.encode(implementation)
                )
            )
        );
    }

    function test_evmIndependentCreate2() public view {
        assertEq(
            h.evm(HASH, evmConfig),
            bytes32(
                uint256(
                    uint160(
                        vm.computeCreate2Address(
                            HASH,
                            evmConfig.initCodeHash,
                            STANDARD
                        )
                    )
                )
            )
        );
    }
    function test_worldchainUsesDifferentPortal() public view {
        T.EvmConfig memory config = evmConfig;
        config.portal = WORLD;
        bytes32 expected = bytes32(
            uint256(
                uint160(
                    vm.computeCreate2Address(HASH, config.initCodeHash, WORLD)
                )
            )
        );
        assertEq(h.evm(HASH, config), expected);
        assertNotEq(expected, h.evm(HASH, evmConfig));
    }
    function test_tronUsesBothPrefixAndVaultTron() public {
        T.EvmConfig memory config = evmConfig;
        config.prefix = 0x41;
        config.implementation = address(new VaultTron());
        config.initCodeHash = keccak256(
            bytes.concat(
                type(Proxy).creationCode,
                abi.encode(config.implementation)
            )
        );
        // Independent byte concatenation, not the renderer or its helper. TRON hashes 0x41 + 20-byte deployer.
        bytes memory preimage = bytes.concat(
            hex"41",
            bytes20(config.portal),
            HASH,
            config.initCodeHash
        );
        bytes32 expected = bytes32(
            uint256(keccak256(preimage)) & type(uint160).max
        );
        assertEq(h.evm(HASH, config), expected);
        config.prefix = 0xff;
        assertNotEq(h.evm(HASH, config), expected);
        config.prefix = 0x41;
        config.implementation = evmConfig.implementation;
        config.initCodeHash = evmConfig.initCodeHash;
        assertNotEq(h.evm(HASH, config), expected);
    }
    function test_initCodeHashIsRemoteNotLocal() public view {
        T.EvmConfig memory config = evmConfig;
        config.initCodeHash = keccak256("different remote Proxy bytecode");
        assertEq(
            h.evm(HASH, config),
            bytes32(
                uint256(
                    uint160(
                        vm.computeCreate2Address(
                            HASH,
                            config.initCodeHash,
                            config.portal
                        )
                    )
                )
            )
        );
    }
    function test_amountMissingSourceAndScaleRejected() public {
        T.Program memory p = _program();
        p.route.items[1].config = abi.encode(
            T.AmountConfig(T.AmountSource.Invalid, 1e18, 32, false)
        );
        vm.expectRevert(T.InvalidAmountSource.selector);
        h.render(p, 1, 1);
        p.route.items[1].config = abi.encode(
            T.AmountConfig(T.AmountSource.Output, 0, 32, false)
        );
        vm.expectRevert(T.InvalidAmountScale.selector);
        h.render(p, 1, 1);
    }
    function test_tooManyItemsRejected() public {
        T.Program memory p = _program();
        p.route.items = new T.Item[](9);
        vm.expectRevert(abi.encodeWithSelector(T.TooManyItems.selector, 9));
        h.render(p, 1, 1);
    }
    function test_nestedRewardShapeRejected() public {
        T.Program memory p = _program();
        p.vaults[0].reward.segments = new bytes[](0);
        vm.expectRevert(
            abi.encodeWithSelector(T.SegmentCountMismatch.selector, 0, 1)
        );
        h.render(p, 1, 1);
    }
    function test_missingPortal() public {
        T.EvmConfig memory c = evmConfig;
        c.portal = address(0);
        vm.expectRevert(T.MissingPortal.selector);
        h.evm(HASH, c);
    }
    function test_missingPrefix() public {
        T.EvmConfig memory c = evmConfig;
        c.prefix = 0;
        vm.expectRevert(T.MissingPrefix.selector);
        h.evm(HASH, c);
    }
    function test_missingImplementation() public {
        T.EvmConfig memory c = evmConfig;
        c.implementation = address(0);
        vm.expectRevert(T.MissingImplementation.selector);
        h.evm(HASH, c);
    }
    function test_missingInitCodeHash() public {
        T.EvmConfig memory c = evmConfig;
        c.initCodeHash = 0;
        vm.expectRevert(T.MissingInitCodeHash.selector);
        h.evm(HASH, c);
    }

    function test_nestedVaultAndAmountRenderInsideOut() public view {
        T.Program memory p = _program();
        uint256 amount = 123456;
        bytes32 expectedHash = keccak256(
            abi.encodePacked(
                uint64(8453),
                keccak256(abi.encode(amount)),
                keccak256(abi.encode(_reward(amount)))
            )
        );
        bytes32 expected = bytes32(
            uint256(
                uint160(
                    vm.computeCreate2Address(
                        expectedHash,
                        evmConfig.initCodeHash,
                        STANDARD
                    )
                )
            )
        );
        assertEq(
            h.render(p, amount + 7, amount),
            bytes.concat(hex"aabb", expected, abi.encode(amount), hex"cc")
        );
        assertNotEq(
            h.render(p, amount + 7, amount),
            h.render(p, amount + 8, amount + 1)
        );
    }
    function test_nestedVaultCanReferenceEarlierVault() public view {
        T.Program memory p = _program();
        T.Vault[] memory nodes = new T.Vault[](2);
        nodes[0] = p.vaults[0];
        T.Program memory other = _program();
        nodes[1] = other.vaults[0];
        nodes[1].route = _literal(hex"55");
        nodes[1].route.segments = new bytes[](2);
        nodes[1].route.items = new T.Item[](1);
        nodes[1].route.items[0] = _ref(0);
        p.vaults = nodes;
        p.route = _literal(hex"");
        p.route.segments = new bytes[](2);
        p.route.items = new T.Item[](1);
        p.route.items[0] = _ref(1);
        bytes32 firstHash = keccak256(
            abi.encodePacked(
                uint64(8453),
                keccak256(abi.encode(uint256(42))),
                keccak256(abi.encode(_reward(42)))
            )
        );
        bytes32 first = bytes32(
            uint256(
                uint160(
                    vm.computeCreate2Address(
                        firstHash,
                        evmConfig.initCodeHash,
                        STANDARD
                    )
                )
            )
        );
        bytes32 secondHash = keccak256(
            abi.encodePacked(
                uint64(8453),
                keccak256(abi.encode(first)),
                keccak256(abi.encode(_reward(42)))
            )
        );
        bytes32 second = bytes32(
            uint256(
                uint160(
                    vm.computeCreate2Address(
                        secondHash,
                        evmConfig.initCodeHash,
                        STANDARD
                    )
                )
            )
        );
        assertEq(h.render(p, 42, 42), abi.encode(second));
    }
    function test_selfReferenceRejected() public {
        T.Program memory p = _program();
        p.vaults[0].route.items[0] = _ref(0);
        vm.expectRevert(
            abi.encodeWithSelector(T.InvalidVaultReference.selector, 0, 0)
        );
        h.render(p, 1, 1);
    }
    function test_forwardReferenceRejected() public {
        T.Program memory p = _program();
        p.vaults[0].route.items[0] = _ref(1);
        vm.expectRevert(
            abi.encodeWithSelector(T.InvalidVaultReference.selector, 1, 0)
        );
        h.render(p, 1, 1);
    }
    function test_missingReferenceRejected() public {
        T.Program memory p = _program();
        p.route.items[0] = _ref(1);
        vm.expectRevert(
            abi.encodeWithSelector(T.InvalidVaultReference.selector, 1, 1)
        );
        h.render(p, 1, 1);
    }
    function test_missingVaultKindRejected() public {
        T.Program memory p = _program();
        p.vaults[0].derivation.kind = T.VaultKind.Invalid;
        vm.expectRevert(T.InvalidVaultKind.selector);
        h.render(p, 1, 1);
    }
    function test_missingItemKindRejected() public {
        T.Program memory p = _program();
        p.route.items[0].kind = T.ItemKind.Invalid;
        vm.expectRevert(T.InvalidItemKind.selector);
        h.render(p, 1, 1);
    }
    function test_missingConfigRejected() public {
        T.Program memory p = _program();
        p.vaults[0].derivation.config = hex"";
        vm.expectRevert(T.InvalidConfigEncoding.selector);
        h.render(p, 1, 1);
    }
    function test_trailingConfigRejected() public {
        T.Program memory p = _program();
        p.vaults[0].derivation.config = bytes.concat(
            p.vaults[0].derivation.config,
            hex"00"
        );
        vm.expectRevert(T.InvalidConfigEncoding.selector);
        h.render(p, 1, 1);
    }
    function test_dirtyEvmAddressEncodingRejected() public {
        T.Program memory p = _program();
        p.vaults[0].derivation.config[0] = 0x01;
        vm.expectRevert();
        h.render(p, 1, 1);
    }
    function test_amountSourceScaleAndEndian() public view {
        T.Program memory p;
        p.route.segments = new bytes[](2);
        p.route.items = new T.Item[](1);
        p.route.items[0] = T.Item(
            T.ItemKind.Amount,
            abi.encode(T.AmountConfig(T.AmountSource.Input, 0.5e18, 8, true))
        );
        assertEq(h.render(p, 515, 99), hex"0201000000000000"); // ceil(515 / 2) = 258
    }
    function test_tooManyVaultsRejected() public {
        T.Program memory p = _program();
        p.vaults = new T.Vault[](9);
        vm.expectRevert(abi.encodeWithSelector(T.TooManyVaults.selector, 9));
        h.render(p, 1, 1);
    }
    function test_aggregateByteBudgetRejected() public {
        T.Program memory p = _program();
        p.vaults[0].route = _literal(new bytes(20000));
        p.vaults[0].reward = _literal(new bytes(20000));
        vm.expectRevert(T.TemplateTooLarge.selector);
        h.render(p, 1, 1);
    }
    function test_configAndKindAreInOrderPreimage() public view {
        T.Program memory p = _program();
        bytes32 before = keccak256(abi.encode(p));
        p.vaults[0].derivation.config = abi.encode(
            T.EvmConfig(
                WORLD,
                0xff,
                evmConfig.implementation,
                evmConfig.initCodeHash
            )
        );
        assertNotEq(before, keccak256(abi.encode(p)));
        before = keccak256(abi.encode(p));
        p.vaults[0].derivation.kind = T.VaultKind.SolanaAta;
        assertNotEq(before, keccak256(abi.encode(p)));
    }
    function testFuzz_amountOnlyMatchesIndependentEncoding(
        uint64 amount
    ) public view {
        T.Program memory p;
        p.route.segments = new bytes[](2);
        p.route.items = new T.Item[](1);
        p.route.items[0] = F.amount(32, false);
        assertEq(h.render(p, 0, amount), abi.encode(uint256(amount)));
    }

    function _program() internal view returns (T.Program memory p) {
        p.vaults = new T.Vault[](1);
        p.vaults[0].destination = 8453;
        p.vaults[0].route.segments = new bytes[](2);
        p.vaults[0].route.items = new T.Item[](1);
        p.vaults[0].route.items[0] = F.amount(32, false);
        // Reward's only amount is its last ABI word. Prefix is independently encoded using real Reward.
        bytes memory reward = abi.encode(_reward(0));
        bytes memory prefix = new bytes(reward.length - 32);
        for (uint256 i; i < prefix.length; ++i) prefix[i] = reward[i];
        p.vaults[0].reward.segments = new bytes[](2);
        p.vaults[0].reward.segments[0] = prefix;
        p.vaults[0].reward.items = new T.Item[](1);
        p.vaults[0].reward.items[0] = F.amount(32, false);
        p.vaults[0].derivation = T.VaultDerivation(
            T.VaultKind.EvmCreate2,
            abi.encode(evmConfig)
        );
        p.route.segments = new bytes[](3);
        p.route.segments[0] = hex"aabb";
        p.route.segments[2] = hex"cc";
        p.route.items = new T.Item[](2);
        p.route.items[0] = _ref(0);
        p.route.items[1] = F.amount(32, false);
    }
    function _reward(uint256 amount) internal pure returns (Reward memory r) {
        r.deadline = 2000000000;
        r.creator = address(0x123);
        r.prover = address(0x456);
        r.tokens = new TokenAmount[](1);
        r.tokens[0] = TokenAmount(address(0x789), amount);
    }
    function _ref(uint256 index) internal pure returns (T.Item memory) {
        return T.Item(T.ItemKind.Vault, abi.encode(index));
    }
    function _literal(
        bytes memory value
    ) internal pure returns (T.Template memory t) {
        t.segments = new bytes[](1);
        t.segments[0] = value;
    }
}

contract SolanaVaultTest is Test {
    TemplateHarness internal h;
    T.SolanaConfig internal config;
    string internal fixture;
    bytes32 internal constant GOLDEN_HASH =
        0x657cfbe2261fb6d4304823599e43f3b5be763e4f52490258b9b7f0dbf2f62047;

    function setUp() public {
        h = new TemplateHarness();
        fixture = vm.readFile("test/chain/testdata/solana-vault-vectors.json");
        config = T.SolanaConfig(
            vm.parseJsonBytes32(fixture, ".portal"),
            vm.parseJsonBytes32(fixture, ".tokenProgram"),
            vm.parseJsonBytes32(fixture, ".mint")
        );
    }
    function test_svmPortalGoldenAndIndependentAta() public view {
        _check(".golden");
    }
    function test_sdkCorpusBothNestedDerivations() public view {
        for (uint256 i; i < 128; ++i)
            _check(string.concat(".vectors[", vm.toString(i), "]"));
    }
    function test_sdkCurveMembershipCorpus() public view {
        for (uint256 i; i < 128; ++i) {
            string memory key = string.concat(".curve[", vm.toString(i), "]");
            assertEq(
                h.onCurve(
                    vm.parseJsonBytes32(fixture, string.concat(key, ".point"))
                ),
                vm.parseJsonBool(fixture, string.concat(key, ".onCurve"))
            );
        }
    }
    function test_nonCanonicalOffCurveBumpNeverSelected() public view {
        bytes32 other = sha256(
            abi.encodePacked(
                "vault",
                GOLDEN_HASH,
                bytes1(0xfe),
                config.portalProgramId,
                "ProgramDerivedAddress"
            )
        );
        assertFalse(h.onCurve(other));
        (bytes32 canonical, , uint8 bump, ) = h.svm(GOLDEN_HASH, config);
        assertEq(bump, 255);
        assertNotEq(canonical, other);
    }
    function test_missingPortalProgram() public {
        T.SolanaConfig memory c = config;
        c.portalProgramId = 0;
        vm.expectRevert(SolanaVault.MissingProgramId.selector);
        h.svm(GOLDEN_HASH, c);
    }
    function test_missingTokenProgram() public {
        T.SolanaConfig memory c = config;
        c.tokenProgramId = 0;
        vm.expectRevert(SolanaVault.MissingTokenProgramId.selector);
        h.svm(GOLDEN_HASH, c);
    }
    function test_missingMint() public {
        T.SolanaConfig memory c = config;
        c.mint = 0;
        vm.expectRevert(SolanaVault.MissingMint.selector);
        h.svm(GOLDEN_HASH, c);
    }
    function test_truncatedShaReturnFailsClosed() public {
        vm.mockCall(address(2), bytes(""), bytes(hex"00"));
        vm.expectRevert(
            abi.encodeWithSelector(
                SolanaVault.PrecompileFailed.selector,
                address(2)
            )
        );
        h.svm(GOLDEN_HASH, config);
    }
    function test_truncatedModexpReturnFailsClosed() public {
        vm.mockCall(address(5), bytes(""), bytes(hex"00"));
        vm.expectRevert(
            abi.encodeWithSelector(
                SolanaVault.PrecompileFailed.selector,
                address(5)
            )
        );
        h.svm(GOLDEN_HASH, config);
    }
    function test_lastAllowedBump224IsIncluded() public {
        // Force the first 31 candidates onto the curve, leaving bump 224 to use real SHA-256.
        // This hash's bump-224 digest is independently checked with the membership predicate below.
        bytes32 hash = keccak256("last bump boundary");
        bytes32 candidate = sha256(
            abi.encodePacked(
                "vault",
                hash,
                bytes1(0xe0),
                config.portalProgramId,
                "ProgramDerivedAddress"
            )
        );
        // Select a deterministic test preimage with an off-curve bump-224 candidate.
        while (h.onCurve(candidate)) {
            hash = keccak256(abi.encode(hash));
            candidate = sha256(
                abi.encodePacked(
                    "vault",
                    hash,
                    bytes1(0xe0),
                    config.portalProgramId,
                    "ProgramDerivedAddress"
                )
            );
        }
        for (uint256 bump = 255; bump > 224; --bump) {
            vm.mockCall(
                address(2),
                abi.encodePacked(
                    "vault",
                    hash,
                    bytes1(uint8(bump)),
                    config.portalProgramId,
                    "ProgramDerivedAddress"
                ),
                abi.encode(bytes32(0))
            );
        }
        (bytes32 vault, , uint8 actual, ) = h.svm(hash, config);
        assertEq(vault, candidate);
        assertEq(actual, 224);
    }
    function test_ataSearchExhaustionFailsClosed() public {
        (bytes32 vault, , , ) = h.svm(GOLDEN_HASH, config);
        // Match only the ATA's 96-byte seed prefix; the vault search still succeeds normally.
        vm.mockCall(
            address(2),
            abi.encodePacked(vault, config.tokenProgramId, config.mint),
            abi.encode(bytes32(0))
        );
        vm.expectRevert(SolanaVault.PdaSearchExhausted.selector);
        h.svm(GOLDEN_HASH, config);
    }
    function test_gasCanonicalGoldenDerivation() public view {
        uint256 before = gasleft();
        h.svm(GOLDEN_HASH, config);
        assertLt(
            before - gasleft(),
            100000,
            "derivation only, excluding JSON fixture parsing"
        );
    }
    function test_searchExhaustionFailsClosed() public {
        // Force every candidate to encoded y=0, which is on curve. No fallback address is returned.
        vm.mockCall(address(2), bytes(""), abi.encode(bytes32(0)));
        vm.expectRevert(SolanaVault.PdaSearchExhausted.selector);
        h.svm(GOLDEN_HASH, config);
    }
    function test_dalekZeroXSignAndReducedY() public view {
        assertTrue(
            h.onCurve(
                bytes32(
                    hex"0100000000000000000000000000000000000000000000000000000000000000"
                )
            )
        );
        assertTrue(
            h.onCurve(
                bytes32(
                    hex"0100000000000000000000000000000000000000000000000000000000000080"
                )
            )
        );
        // y=p reduces to zero; the PDA membership predicate is deliberately not strict Ed25519 decoding.
        assertTrue(
            h.onCurve(
                bytes32(
                    hex"edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"
                )
            )
        );
    }
    function _check(string memory key) internal view {
        (bytes32 vault, bytes32 ata, uint8 vb, uint8 ab) = h.svm(
            vm.parseJsonBytes32(fixture, string.concat(key, ".intentHash")),
            config
        );
        assertEq(
            vault,
            vm.parseJsonBytes32(fixture, string.concat(key, ".vault"))
        );
        assertEq(ata, vm.parseJsonBytes32(fixture, string.concat(key, ".ata")));
        assertEq(
            uint256(vb),
            vm.parseJsonUint(fixture, string.concat(key, ".vaultBump"))
        );
        assertEq(
            uint256(ab),
            vm.parseJsonUint(fixture, string.concat(key, ".ataBump"))
        );
    }
}
