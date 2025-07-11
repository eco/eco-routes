// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IProver} from "../interfaces/IProver.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Intent} from "../types/Intent.sol";

/**
 * @title BaseProver
 * @notice Base implementation for intent proving contracts
 * @dev Provides core storage and functionality for tracking proven intents
 * and their claimants
 */
abstract contract BaseProver is IProver, ERC165 {
    /**
     * @notice Address of the Inbox contract
     * @dev Immutable to prevent unauthorized changes
     */
    address public immutable INBOX;

    /**
     * @notice Mapping from intent hash to proof data
     * @dev Empty struct (zero claimant) indicates intent hasn't been proven
     */
    mapping(bytes32 => ProofData) internal _provenIntents;

    /**
     * @notice Initializes the BaseProver contract
     * @param _inbox Address of the Inbox contract
     */
    constructor(address _inbox) {
        INBOX = _inbox;
    }

    /**
     * @notice Process intent proofs from a cross-chain message
     * @param _hashes Array of intent hashes
     * @param _claimants Array of claimant addresses
     * @param _destinationChainID Chain ID where the intent is being proven
     */
    function _processIntentProofs(
        bytes32[] memory _hashes,
        bytes32[] memory _claimants,
        uint256 _destinationChainID
    ) internal {
        // If arrays are empty, just return early
        if (_hashes.length == 0) return;

        // Require matching array lengths for security
        if (_hashes.length != _claimants.length) {
            revert ArrayLengthMismatch();
        }

        for (uint256 i = 0; i < _hashes.length; i++) {
            bytes32 intentHash = _hashes[i];
            address claimant = address(uint160(uint256(_claimants[i])));

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
                    destinationChainID: uint96(_destinationChainID)
                });
                emit IntentProven(intentHash, claimant);
            }
        }
    }

    /**
     * @notice Returns the proof data for a given intent hash
     * @param _intentHash Hash of the intent to query
     * @return ProofData containing claimant and destination chain ID
     */
    function provenIntents(bytes32 _intentHash) external view override returns (ProofData memory) {
        return _provenIntents[_intentHash];
    }

    /**
     * @notice Challenge an intent proof if destination chain ID doesn't match
     * @dev Can be called by anyone to remove invalid proofs
     * @param _intent The intent to challenge
     */
    function challengeIntentProof(Intent calldata _intent) external {
        bytes32 routeHash = keccak256(abi.encode(_intent.route));
        bytes32 rewardHash = keccak256(abi.encode(_intent.reward));
        bytes32 intentHash = keccak256(abi.encodePacked(routeHash, rewardHash));
        
        ProofData memory proof = _provenIntents[intentHash];
        
        // Only challenge if proof exists and destination chain ID doesn't match
        if (proof.claimant != address(0) && proof.destinationChainID != _intent.route.destination) {
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