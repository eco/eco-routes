// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IProver} from "../interfaces/IProver.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {console} from "hardhat/console.sol";

/**
 * @title BaseProver
 * @notice Base implementation for intent proving contracts
 * @dev Provides core storage and functionality for tracking proven intents
 * and their claimants
 */
abstract contract BaseProver is IProver, ERC165 {
    /**
     * @notice Mapping from intent hash to address eligible to claim rewards
     * @dev Zero address indicates intent hasn't been proven
     */
    mapping(bytes32 => address) public provenIntents;

    /**
     * @notice Gets the address eligible to claim rewards for a given intent
     * @param intentHash Hash of the intent to query
     * @return Address of the claimant, or zero address if unproven
     */
    function getIntentClaimant(
        bytes32 intentHash
    ) external view override returns (address) {
        return provenIntents[intentHash];
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override returns (bool) {
        return
            interfaceId == type(IProver).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
