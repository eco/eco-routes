// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @notice Canonical Eco Solana vault and associated-token-account derivation on EVM.
 * @dev Uses SHA-256 (0x02), field arithmetic and MODEXP (0x05); no Ed25519 precompile is required.
 *      The decompression check follows the Edwards25519 square-root test used by Solana's dalek,
 *      as also implemented in sauce, ref 16243de08, v12-evm/engine/handlers/Pda.huff (PR #416).
 *      This is a PDA membership test, NOT a signature/public-key validation routine: dalek's PDA
 *      test reduces y modulo p and does not reject the sign bit when x is zero.
 *
 *      Both bumps are DERIVED, never caller-supplied. A non-canonical bump can produce a different,
 *      valid-looking, off-curve address which the Portal/ATA program will not use. A CCTP mint to that
 *      address can be unrecoverable. Order commitment alone would prevent bump substitution, not prove
 *      canonicality for an unknown runtime amount. Search from 255 down ensures the first off-curve
 *      digest is canonical. Each search is bounded to 32 attempts (255..224); exhaustion reverts,
 *      never returns a lower/non-canonical address. Chains must provide both standard precompiles.
 */
library SolanaVault {
    uint256 internal constant P =
        0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffed;
    uint256 internal constant D =
        0x52036cee2b6ffe738cc740797779e89800700a4d4141d8ab75eb4dca135978a3;
    uint256 internal constant EXP =
        0x0ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffd;
    uint256 internal constant MAX_ATTEMPTS = 32;
    // ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL
    bytes32 internal constant ATA_PROGRAM =
        0x8c97258f4e2489f1bb3d1029148e0d830b5a1399daff1084048e7bd8dbe9f859;

    error MissingProgramId();
    error MissingTokenProgramId();
    error MissingMint();
    error PdaSearchExhausted();
    error PrecompileFailed(address precompile);

    /// @notice Derive the vault, then its ATA (the actual CCTP mint recipient).
    function derive(
        bytes32 intentHash,
        bytes32 portalProgram,
        bytes32 tokenProgram,
        bytes32 mint
    )
        internal
        view
        returns (bytes32 vault, bytes32 ata, uint8 vaultBump, uint8 ataBump)
    {
        if (portalProgram == bytes32(0)) revert MissingProgramId();
        if (tokenProgram == bytes32(0)) revert MissingTokenProgramId();
        if (mint == bytes32(0)) revert MissingMint();
        (vault, vaultBump) = _find(
            abi.encodePacked("vault", intentHash),
            portalProgram
        );
        (ata, ataBump) = _find(
            abi.encodePacked(vault, tokenProgram, mint),
            ATA_PROGRAM
        );
    }

    /// @dev Only fixed internal seed shapes reach this helper: [5,32] or [32,32,32] bytes. Both satisfy
    ///      Solana's seed count/length limits including the extra bump seed; no arbitrary seed API.
    function _find(
        bytes memory seeds,
        bytes32 program
    ) private view returns (bytes32 result, uint8 bump) {
        bytes memory preimage = abi.encodePacked(
            seeds,
            bytes1(0xff),
            program,
            "ProgramDerivedAddress"
        );
        for (uint256 i; i < MAX_ATTEMPTS; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            bump = uint8(255 - i);
            preimage[seeds.length] = bytes1(bump);
            (bool success, bytes memory output) = address(0x02).staticcall(
                preimage
            );
            if (!success || output.length != 32)
                revert PrecompileFailed(address(0x02));
            result = abi.decode(output, (bytes32));
            if (!isOnCurve(result)) return (result, bump);
        }
        revert PdaSearchExhausted();
    }

    /// @notice Whether a compressed Edwards Y decompresses under Solana's PDA membership rules.
    function isOnCurve(bytes32 compressed) internal view returns (bool) {
        // Solana's compressed Y is little-endian, with the sign of X in the top bit.
        uint256 y;
        for (uint256 i; i < 32; ++i)
            y |= uint256(uint8(compressed[i])) << (8 * i);
        y &= type(uint256).max >> 1;
        uint256 yy = mulmod(y, y, P);
        uint256 u = addmod(yy, P - 1, P);
        uint256 v = addmod(mulmod(D, yy, P), 1, P);
        uint256 v3 = mulmod(mulmod(v, v, P), v, P);
        uint256 v7 = mulmod(mulmod(v3, v3, P), v, P);
        bytes memory input = abi.encode(
            uint256(32),
            uint256(32),
            uint256(32),
            mulmod(u, v7, P),
            EXP,
            P
        );
        (bool success, bytes memory output) = address(0x05).staticcall(input);
        if (!success || output.length != 32)
            revert PrecompileFailed(address(0x05));
        uint256 r = mulmod(mulmod(u, v3, P), abi.decode(output, (uint256)), P);
        uint256 check = mulmod(v, mulmod(r, r, P), P);
        return check == u || check == P - u;
    }
}
