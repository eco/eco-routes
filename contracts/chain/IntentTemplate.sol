// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SolanaVault} from "./SolanaVault.sol";

/**
 * @notice Deterministic, bounded rendering of amount and downstream-vault template items.
 * @dev A program is a flattened tree: vaults are listed dependency-first, and a vault may reference
 *      only earlier vaults. The root route may reference any vault. Every route, reward, configuration,
 *      and reference is part of the calling order's calldata commitment. Rendering never reads a
 *      balance, calls a Portal, publishes an intent, or moves value. The only external calls are to
 *      fixed cryptographic precompiles for Solana derivation. All amounts derive from the same
 *      initial measurement. Remote recipients are DATA in the local child's route, not local payees.
 *
 *      Route and reward templates contain the remote VM's exact serialization (ABI or Borsh). Rendering
 *      validates geometry and derivation parameters, not opaque route/reward semantics or deployed remote
 *      bytecode. Authors must verify token identifiers, deadlines, prover, fee treatment and deployment
 *      parameters. In particular, the remote reward must describe the amount that will actually arrive.
 */
library IntentTemplate {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_VAULTS = 8;
    uint256 internal constant MAX_ITEMS = 8;
    uint256 internal constant MAX_RENDERED_BYTES = 32768;

    enum ItemKind {
        Invalid,
        Amount,
        Vault
    }

    enum AmountSource {
        Invalid,
        Input,
        Output
    }

    enum VaultKind {
        Invalid,
        EvmCreate2,
        SolanaAta
    }

    /// @dev Config is canonical abi.encode(AmountConfig) or abi.encode(uint256 vaultIndex).
    struct Item {
        ItemKind kind;
        bytes config;
    }

    struct Template {
        bytes[] segments;
        Item[] items;
    }

    /// @dev The selected initial amount is multiplied by scale / WAD, rounding up, then encoded.
    ///      scale = WAD means no additional transform. Zero scale and truncating encodings revert.
    struct AmountConfig {
        AmountSource source;
        uint256 scale;
        uint8 width;
        bool littleEndian;
    }

    struct VaultDerivation {
        VaultKind kind;
        bytes config;
    }

    /// @dev destination is the downstream intent's execution chain, NOT its reward-vault chain.
    ///      reward renders the entire encoded Reward, including any ABI tuple offset.
    struct Vault {
        uint64 destination;
        Template route;
        Template reward;
        VaultDerivation derivation;
    }

    struct Program {
        Vault[] vaults;
        Template route;
    }

    /// @dev initCodeHash is keccak256(remote Proxy.creationCode || abi.encode(implementation)).
    ///      Both implementation and bytecode are remote parameters; local Proxy bytecode is never used.
    ///      Presence is checked, but the hash/implementation/deployment relationship cannot be attested
    ///      from this chain. Authors must obtain and commit the correct pair for the remote deployment.
    struct EvmConfig {
        address portal;
        bytes1 prefix;
        address implementation;
        bytes32 initCodeHash;
    }

    /// @dev Both bumps are searched canonically on-chain, never accepted from order input.
    struct SolanaConfig {
        bytes32 portalProgramId;
        bytes32 tokenProgramId;
        bytes32 mint;
    }

    error TooManyVaults(uint256 count);
    error TooManyItems(uint256 count);
    error SegmentCountMismatch(uint256 segments, uint256 items);
    error TemplateTooLarge();
    error InvalidItemKind();
    error InvalidVaultKind();
    error InvalidAmountSource();
    error InvalidConfigEncoding();
    error InvalidAmountScale();
    error InvalidAmountWidth(uint8 width);
    error AmountDoesNotFit(uint256 amount, uint8 width);
    error InvalidVaultReference(uint256 index, uint256 available);
    error MissingPortal();
    error MissingPrefix();
    error MissingImplementation();
    error MissingInitCodeHash();

    /// @notice Render downstream intents first, then splice their recipients into the root route.
    /// @dev The aggregate output budget covers ALL nested route/reward bytes plus the root route.
    function render(
        Program calldata program,
        uint256 amountIn,
        uint256 amountOut
    ) internal view returns (bytes memory route) {
        uint256 count = program.vaults.length;
        if (count > MAX_VAULTS) revert TooManyVaults(count);
        bytes32[] memory recipients = new bytes32[](count);
        uint256 remaining = MAX_RENDERED_BYTES;
        for (uint256 i; i < count; ++i) {
            Vault calldata vault = program.vaults[i];
            bytes memory remoteRoute = _render(
                vault.route,
                recipients,
                i,
                amountIn,
                amountOut,
                remaining
            );
            remaining -= remoteRoute.length;
            bytes memory remoteReward = _render(
                vault.reward,
                recipients,
                i,
                amountIn,
                amountOut,
                remaining
            );
            remaining -= remoteReward.length;
            bytes32 intentHash = keccak256(
                abi.encodePacked(
                    vault.destination,
                    keccak256(remoteRoute),
                    keccak256(remoteReward)
                )
            );
            recipients[i] = _derive(intentHash, vault.derivation);
        }
        return
            _render(
                program.route,
                recipients,
                count,
                amountIn,
                amountOut,
                remaining
            );
    }

    /// @notice Derive an EVM/TRON remote vault from explicit, committed deployment parameters.
    /// @dev Returns the 20-byte result LEFT-zero-padded to bytes32, suitable for CCTP mintRecipient.
    ///      No address(this), chain-id branch, assumed 0xff prefix, or local creation code is used.
    function deriveEvm(
        bytes32 intentHash,
        EvmConfig memory config
    ) internal pure returns (bytes32) {
        if (config.portal == address(0)) revert MissingPortal();
        if (config.prefix == bytes1(0)) revert MissingPrefix();
        if (config.implementation == address(0)) revert MissingImplementation();
        if (config.initCodeHash == bytes32(0)) revert MissingInitCodeHash();
        bytes32 digest = keccak256(
            abi.encodePacked(
                config.prefix,
                config.portal,
                intentHash,
                config.initCodeHash
            )
        );
        return bytes32(uint256(digest) & type(uint160).max);
    }

    function _derive(
        bytes32 intentHash,
        VaultDerivation calldata derivation
    ) private view returns (bytes32) {
        if (derivation.kind == VaultKind.EvmCreate2) {
            // Static schemas have a single canonical ABI encoding; exact length also rejects trailing data.
            if (derivation.config.length != 128) revert InvalidConfigEncoding();
            EvmConfig memory config = abi.decode(
                derivation.config,
                (EvmConfig)
            );
            if (keccak256(derivation.config) != keccak256(abi.encode(config)))
                revert InvalidConfigEncoding();
            return deriveEvm(intentHash, config);
        }
        if (derivation.kind == VaultKind.SolanaAta) {
            if (derivation.config.length != 96) revert InvalidConfigEncoding();
            SolanaConfig memory config = abi.decode(
                derivation.config,
                (SolanaConfig)
            );
            (, bytes32 ata, , ) = SolanaVault.derive(
                intentHash,
                config.portalProgramId,
                config.tokenProgramId,
                config.mint
            );
            return ata;
        }
        revert InvalidVaultKind();
    }

    /// @notice Validate one template's geometry without a measurement or allocation.
    function validateShape(Template calldata template) internal pure {
        uint256 count = template.items.length;
        if (count > MAX_ITEMS) revert TooManyItems(count);
        if (template.segments.length != count + 1) {
            revert SegmentCountMismatch(template.segments.length, count);
        }
    }

    function _render(
        Template calldata template,
        bytes32[] memory recipients,
        uint256 available,
        uint256 amountIn,
        uint256 amountOut,
        uint256 remaining
    ) private pure returns (bytes memory result) {
        uint256 count = template.items.length;
        validateShape(template);
        // Bound copies before allocating any rendered output. Item widths are charged as they render.
        uint256 literalSize;
        for (uint256 i; i <= count; ++i) {
            literalSize += template.segments[i].length;
            if (literalSize > remaining) revert TemplateTooLarge();
        }
        remaining -= literalSize;
        result = template.segments[0];
        for (uint256 i; i < count; ++i) {
            Item calldata item = template.items[i];
            bytes memory value;
            if (item.kind == ItemKind.Amount) {
                value = _amount(item.config, amountIn, amountOut);
            } else if (item.kind == ItemKind.Vault) {
                if (item.config.length != 32) revert InvalidConfigEncoding();
                uint256 index = abi.decode(item.config, (uint256));
                // For a nested vault, this rejects self references, forward edges and cycles.
                if (index >= available)
                    revert InvalidVaultReference(index, available);
                value = abi.encode(recipients[index]);
            } else {
                revert InvalidItemKind();
            }
            if (value.length > remaining) revert TemplateTooLarge();
            remaining -= value.length;
            result = bytes.concat(result, value, template.segments[i + 1]);
        }
    }

    function _amount(
        bytes calldata encoded,
        uint256 amountIn,
        uint256 amountOut
    ) private pure returns (bytes memory result) {
        if (encoded.length != 128) revert InvalidConfigEncoding();
        AmountConfig memory config = abi.decode(encoded, (AmountConfig));
        if (keccak256(encoded) != keccak256(abi.encode(config)))
            revert InvalidConfigEncoding();
        if (config.scale == 0) revert InvalidAmountScale();
        if (config.width == 0 || config.width > 32)
            revert InvalidAmountWidth(config.width);
        uint256 amount;
        if (config.source == AmountSource.Input) amount = amountIn;
        else if (config.source == AmountSource.Output) amount = amountOut;
        else revert InvalidAmountSource();
        amount = Math.mulDiv(amount, config.scale, WAD, Math.Rounding.Ceil);
        if (config.width < 32 && amount >> (uint256(config.width) * 8) != 0) {
            revert AmountDoesNotFit(amount, config.width);
        }
        result = new bytes(config.width);
        for (uint256 i; i < config.width; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            result[config.littleEndian ? i : config.width - 1 - i] = bytes1(
                uint8(amount >> (8 * i))
            );
        }
    }
}
