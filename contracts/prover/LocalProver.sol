// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IProver} from "../interfaces/IProver.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Inbox} from "../Inbox.sol";
import {Intent} from "../types/Intent.sol";
import {Semver} from "../libs/Semver.sol";

/**
 * @title BaseProver
 * @notice Base implementation for intent proving contracts
 * @dev Provides core storage and functionality for tracking proven intents
 * and their claimants
 */
contract SameChainProver is IProver, Semver {
    using SafeCast for uint256;

    error CannotChallengeSameChainIntentProof();

    /**
     * @notice Address of the Inbox contract
     * @dev Immutable to prevent unauthorized changes
     */
    Inbox private immutable _INBOX;

    uint64 private immutable _CHAIN_ID;

    constructor(address payable _inbox) {
        _INBOX = Inbox(_inbox);
        _CHAIN_ID = uint64(block.chainid);
    }

    /**
     * @notice Fetches a ProofData from the provenIntents mapping
     * @param _intentHash the hash of the intent whose proof data is being queried
     * @return ProofData struct containing the destination chain ID and claimant address
     */

    function provenIntents(
        bytes32 _intentHash
    ) public view override returns (ProofData memory) {
        bytes32 fulfilledClaimant = _INBOX.fulfilled(_intentHash);
        // Convert bytes32 to address if it's a valid Ethereum address
        address claimant = address(0);
        if (fulfilledClaimant != bytes32(0)) {
            // Check if top 12 bytes are zero (valid Ethereum address)
            if (uint96(uint256(fulfilledClaimant >> 160)) == 0) {
                claimant = address(uint160(uint256(fulfilledClaimant)));
            }
        }
        return ProofData(claimant, _CHAIN_ID);
    }

    function getProofType() external pure override returns (string memory) {
        return "Same chain";
    }

    function prove(
        address _sender,
        uint256 _sourceChainId,
        bytes32[] calldata _intentHashes,
        bytes32[] calldata _claimants,
        bytes calldata _data
    ) external payable {
        // this function is intentionally left empty as no proof is required
        // for same-chain proving
        // should not revert lest it be called with fulfillandprove
    }

    function challengeIntentProof(Intent calldata) external pure {
        revert CannotChallengeSameChainIntentProof();
    }
}
