// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Inbox} from "../Inbox.sol";
import {Semver} from "../libs/Semver.sol";
import {IProver} from "../interfaces/IProver.sol";
import {AddressConverter} from "../libs/AddressConverter.sol";

/**
 * @title LocalProver
 * @notice Prover implementation for same-chain intent fulfillment
 * @dev Handles proving of intents that are fulfilled on the same chain where they were created
 */
contract LocalProver is IProver, Semver {
    using SafeCast for uint256;
    using AddressConverter for bytes32;

    /**
     * @notice Address of the Portal contract (Inbox functionality)
     * @dev Immutable to prevent unauthorized changes
     */
    Inbox private immutable _PORTAL;

    uint64 private immutable _CHAIN_ID;

    constructor(address inbox) {
        _PORTAL = Inbox(inbox);
        _CHAIN_ID = uint64(block.chainid);
    }

    /**
     * @notice Fetches a ProofData from the provenIntents mapping
     * @param intentHash the hash of the intent whose proof data is being queried
     * @return ProofData struct containing the destination chain ID and claimant address
     */
    function provenIntents(
        bytes32 intentHash
    ) public view returns (ProofData memory) {
        bytes32 claimant = _PORTAL.claimants(intentHash);

        if (claimant == bytes32(0)) {
            return ProofData(address(0), 0);
        }

        return ProofData(claimant.toAddress(), _CHAIN_ID);
    }

    function getProofType() external pure returns (string memory) {
        return "Same chain";
    }

    /**
     * @notice Initiates proving of intents on the same chain
     * @dev This function is a no-op for same-chain proving since proofs are created immediately upon fulfillment
     */
    function prove(
        address /* sender */,
        uint64 /* sourceChainId */,
        bytes calldata /* encodedProofs */,
        bytes calldata /* data */
    ) external payable {
        // solhint-disable-line no-empty-blocks
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
        bytes32 /* rewardHash */
    ) external pure {
        // solhint-disable-line no-empty-blocks
        // Intentionally left empty as same-chain intents cannot be challenged
        // This is a no-op similar to the prove function above
    }
}
