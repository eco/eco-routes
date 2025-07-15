// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Inbox} from "../Inbox.sol";
import {Intent, Reward} from "../types/Intent.sol";
import {Semver} from "../libs/Semver.sol";
import {IProver} from "../interfaces/IProver.sol";

/**
 * @title SameChainProver
 * @notice Prover implementation for same-chain intent fulfillment
 * @dev Handles proving of intents that are fulfilled on the same chain where they were created
 */
contract SameChainProver is IProver, Semver {
    using SafeCast for uint256;

    /**
     * @notice Address of the Inbox contract
     * @dev Immutable to prevent unauthorized changes
     */
    Inbox private immutable _INBOX;

    uint64 private immutable _CHAIN_ID;

    constructor(address payable inbox) {
        _INBOX = Inbox(inbox);
        _CHAIN_ID = uint64(block.chainid);
    }

    /**
     * @notice Fetches a ProofData from the provenIntents mapping
     * @param intentHash the hash of the intent whose proof data is being queried
     * @return ProofData struct containing the destination chain ID and claimant address
     */

    function provenIntents(
        bytes32 intentHash
    ) public view override returns (ProofData memory) {
        bytes32 fulfilledClaimant = _INBOX.fulfilled(intentHash);
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

    /**
     * @notice Initiates proving of intents on the same chain
     * @dev This function is a no-op for same-chain proving since proofs are created immediately upon fulfillment
     * param sender Address that initiated the proving request (unused)
     * param sourceChainId Chain ID of the source chain (unused)
     * param intentHashes Array of intent hashes to prove (unused)
     * param claimants Array of claimant addresses (unused)
     * param data Additional data for proving (unused)
     */
    function prove(
        address /*sender*/,
        uint256 /*sourceChainId*/,
        bytes32[] calldata /*intentHashes*/,
        bytes32[] calldata /*claimants*/,
        bytes calldata /*data*/
    ) external payable {
        // this function is intentionally left empty as no proof is required
        // for same-chain proving
        // should not revert lest it be called with fulfillandprove
    }

    /**
     * @notice Challenges an intent proof (not applicable for same-chain intents)
     * @dev This function is a no-op for same-chain intents as they cannot be challenged
     */
    function challengeIntentProof(
        uint64 /* destination */,
        bytes32 /* routeHash */,
        Reward calldata /* reward */
    ) external pure {
        // Intentionally left empty as same-chain intents cannot be challenged
        // This is a no-op similar to the prove function above
    }
}
