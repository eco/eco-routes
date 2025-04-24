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
     * @dev Zero address indicates intent hasn't been proven
     */
    mapping(bytes32 => address) public provenIntents;

    /**
     * @notice Initializes the BaseProver contract
     * @param _inbox Address of the Inbox contract
     */
    constructor(address _inbox) {
        INBOX = _inbox;
    }

    /**
     * @notice Initiates the proving process for intents from the destination chain
     * @dev Implemented by specific prover mechanisms (storage, Hyperlane, Metalayer)
     * @param _sender Address of the original transaction sender
     * @param _sourceChainId Chain ID of the source chain
     * @param _intentHashes Array of intent hashes to prove
     * @param _claimants Array of claimant addresses
     * @param _data Additional data specific to the proving implementation
     */
    function destinationProve(
        address _sender,
        uint256 _sourceChainId,
        bytes32[] calldata _intentHashes,
        address[] calldata _claimants,
        bytes calldata _data
    ) external payable virtual;

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
