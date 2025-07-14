// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IProver} from "../interfaces/IProver.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Intent} from "../types/Intent.sol";
import {AddressConverter} from "../libs/AddressConverter.sol";

/**
 * @title BaseProver
 * @notice Base implementation for intent proving contracts
 * @dev Provides core storage and functionality for tracking proven intents
 * and their claimants
 */
abstract contract BaseProver is IProver, ERC165 {
    using AddressConverter for bytes32;
    /**
     * @notice Address of the Portal contract
     * @dev Immutable to prevent unauthorized changes
     */

    address public immutable PORTAL;

    /**
     * @notice Mapping from intent hash to proof data
     * @dev Empty struct (zero claimant) indicates intent hasn't been proven
     */
    mapping(bytes32 => ProofData) internal _provenIntents;

    /**
     * @notice Get proof data for an intent
     * @param intentHash The intent hash to query
     * @return ProofData struct containing claimant and destinationChainID
     */
    function provenIntents(
        bytes32 intentHash
    ) external view returns (ProofData memory) {
        return _provenIntents[intentHash];
    }

    /**
     * @notice Initializes the BaseProver contract
     * @param portal Address of the Portal contract
     */
    constructor(address portal) {
        PORTAL = portal;
    }

    /**
     * @notice Process intent proofs from a cross-chain message
     * @param hashes Array of intent hashes
     * @param claimants Array of claimant addresses
     * @param destinationChainID Chain ID where the intent is being proven
     */
    function _processIntentProofs(
        bytes32[] memory hashes,
        bytes32[] memory claimants,
        uint256 destinationChainID
    ) internal {
        // If arrays are empty, just return early
        if (hashes.length == 0) return;

        // Require matching array lengths for security
        if (hashes.length != claimants.length) {
            revert ArrayLengthMismatch();
        }

        for (uint256 i = 0; i < hashes.length; i++) {
            bytes32 intentHash = hashes[i];

            // Check if the claimant bytes32 represents a valid Ethereum address
            if (!claimants[i].isValidAddress()) {
                // Skip non-EVM addresses that can't be converted
                continue;
            }

            address claimant = claimants[i].toAddress();

            // Validate claimant is not zero address
            if (claimant == address(0)) {
                continue; // Skip invalid claimants
            }

            // Skip rather than revert for already proven intents
            if (_provenIntents[intentHash].claimant != address(0)) {
                emit IntentAlreadyProven(intentHash);
            } else {
                _provenIntents[intentHash] = ProofData({
                    claimant: claimant,
                    destinationChainID: uint64(destinationChainID)
                });
                emit IntentProven(intentHash, claimant);
            }
        }
    }

    /**
     * @notice Challenge an intent proof if destination chain ID doesn't match
     * @dev Can be called by anyone to remove invalid proofs
     * @param _intent The intent to challenge
     */
    function challengeIntentProof(Intent calldata _intent) external {
        bytes32 routeHash = keccak256(abi.encode(_intent.route));
        bytes32 rewardHash = keccak256(abi.encode(_intent.reward));
        bytes32 intentHash = keccak256(
            abi.encodePacked(_intent.destination, routeHash, rewardHash)
        );

        ProofData memory proof = _provenIntents[intentHash];

        // Only challenge if proof exists and destination chain ID doesn't match
        if (
            proof.claimant != address(0) &&
            proof.destinationChainID != _intent.destination
        ) {
            delete _provenIntents[intentHash];
            emit IntentProven(intentHash, address(0)); // Emit with zero address to indicate removal
        }
    }

    /**
     * @notice Checks if this contract supports a given interface
     * @dev Implements ERC165 interface detection
     * @param interfaceId Interface identifier to check
     * @return True if the interface is supported
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view override returns (bool) {
        return
            interfaceId == type(IProver).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
