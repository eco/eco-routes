// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseProver} from "./BaseProver.sol";
import {ITEEProver} from "../interfaces/ITEEProver.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Semver} from "../libs/Semver.sol";

/**
 * @title TEEProver
 * @notice Prover implementation that verifies oracle signatures over intent proofs
 * @dev Uses EIP-712 typed data signatures for secure proving. The oracle address is
 *      immutable and set at construction. Signatures include chain ID for replay protection.
 */
contract TEEProver is ITEEProver, BaseProver, EIP712, Semver {
    using ECDSA for bytes32;

    /**
     * @notice Immutable oracle address that signs proofs
     * @dev Set once during construction and cannot be changed
     */
    address public immutable ORACLE;

    /**
     * @notice EIP-712 type hash for proof verification
     * @dev Covers destination chain ID and hash of encoded proofs
     */
    bytes32 public constant PROOF_TYPEHASH =
        keccak256("Proof(uint64 destination,bytes32 proofsHash)");

    /**
     * @notice Initializes the TEEProver contract
     * @param portal Address of the Portal contract
     * @param oracle Address of the oracle that signs proofs
     */
    constructor(
        address portal,
        address oracle
    ) BaseProver(portal) EIP712("TEEProver", "1.0.0") {
        if (oracle == address(0)) {
            revert ZeroOracle();
        }

        ORACLE = oracle;
    }

    /**
     * @notice Verifies oracle signature over proof data
     * @dev Uses EIP-712 typed data signature verification
     * @param destination Destination chain ID where intents were fulfilled
     * @param encodedProofs Encoded proof data: abi.encodePacked(intentHash1, claimant1, ...)
     * @param signature Oracle's ECDSA signature
     * @return True if signature is valid, false otherwise
     */
    function _verifyProof(
        uint64 destination,
        bytes calldata encodedProofs,
        bytes calldata signature
    ) internal view returns (bool) {
        // Compute proofs hash
        bytes32 proofsHash = keccak256(encodedProofs);

        // Create EIP-712 struct hash
        bytes32 structHash = keccak256(
            abi.encode(PROOF_TYPEHASH, destination, proofsHash)
        );

        // Get EIP-712 typed data hash
        bytes32 hash = _hashTypedDataV4(structHash);

        // Recover signer from signature
        address signer = hash.recover(signature);

        // Verify signer is oracle
        return signer == ORACLE;
    }

    /**
     * @notice Prove intents with oracle signature
     * @dev Implements IProver interface. Ignores sender parameter (required by interface).
     *      Supports proving single or multiple intents with one signature.
     * @param sourceChainDomainID Destination chain ID where intents were fulfilled
     * @param encodedProofs Encoded proof data: abi.encodePacked(intentHash1, claimant1, intentHash2, claimant2, ...)
     * @param data Oracle's EIP-712 signature over (sourceChainDomainID, keccak256(encodedProofs))
     */
    function prove(
        address, // sender - unused
        uint64 sourceChainDomainID,
        bytes calldata encodedProofs,
        bytes calldata data // signature
    ) external payable override {
        // Verify oracle signature
        if (!_verifyProof(sourceChainDomainID, encodedProofs, data)) {
            revert InvalidSignature();
        }

        // Process and mark intents as proven
        _processIntentProofs(encodedProofs, sourceChainDomainID);
    }

    /**
     * @notice Returns the proof mechanism type
     * @return String indicating this is a TEE oracle-based prover
     */
    function getProofType() external pure override returns (string memory) {
        return "TEE_ORACLE";
    }
}
