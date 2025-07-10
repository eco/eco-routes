// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IProver} from "../interfaces/IProver.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

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
     * @notice Mapping from intent hash to address eligible to claim rewards
     * @dev Zero claimant address indicates intent hasn't been proven
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
     * @notice Fetches a ProofData from the provenIntents mapping
     * @param _intentHash the hash of the intent whose proof data is being queried
     * @return ProofData struct containing the destination chain ID and claimant address
     */
    function provenIntents(
        bytes32 _intentHash
    ) public view returns (ProofData memory) {
        return _provenIntents[_intentHash];
    }

    /**
     * @notice Process intent proofs from a cross-chain message
     * @param _destinationChainID ID of the destination chain
     * @param _hashes Array of intent hashes
     * @param _claimants Array of claimant addresses
     */
    function _processIntentProofs(
        uint96 _destinationChainID,
        bytes32[] memory _hashes,
        address[] memory _claimants
    ) internal {
        // If arrays are empty, just return early
        if (_hashes.length == 0) return;

        // Require matching array lengths for security
        if (_hashes.length != _claimants.length) {
            revert ArrayLengthMismatch();
        }

        for (uint256 i = 0; i < _hashes.length; i++) {
            bytes32 intentHash = _hashes[i];
            address claimant = _claimants[i];

            // Validate claimant is not zero address
            if (claimant == address(0)) {
                continue; // Skip invalid claimants
            }

            // covers an edge case in the event of an attack
            uint96 currentDestinationChainID = provenIntents(intentHash)
                .destinationChainID;
            if (
                _destinationChainID != currentDestinationChainID &&
                currentDestinationChainID != 0
            ) {
                revert BadDestinationChainID(
                    intentHash,
                    currentDestinationChainID,
                    _destinationChainID
                );
            }
            // Skip rather than revert for already proven intents
            ProofData storage proofData = _provenIntents[intentHash];
            if (proofData.claimant != address(0)) {
                emit IntentAlreadyProven(intentHash);
            } else {
                proofData.claimant = claimant;
                proofData.destinationChainID = _destinationChainID;
                emit IntentProven(intentHash, claimant);
            }
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
