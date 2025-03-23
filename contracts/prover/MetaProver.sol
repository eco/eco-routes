// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMetalayerRecipient, ReadOperation} from "@metalayer/contracts/src/interfaces/IMetalayerRecipient.sol";
import {TypeCasts} from "@hyperlane-xyz/core/contracts/libs/TypeCasts.sol";
import {BaseProver} from "./BaseProver.sol";
import {Semver} from "../libs/Semver.sol";

/**
 * @title MetaProver
 * @notice Prover implementation using Caldera Metalayer's cross-chain messaging system
 * @dev Processes proof messages from Metalayer router and records proven intents
 */
contract MetaProver is IMetalayerRecipient, BaseProver, Semver {
    using TypeCasts for bytes32;

    /**
     * @notice Constant indicating this contract uses Metalayer for proving
     */
    ProofType public constant PROOF_TYPE = ProofType.Metalayer;

    /**
     * @notice Emitted when attempting to prove an already-proven intent
     * @dev Event instead of error to allow batch processing to continue
     * @param _intentHash Hash of the already proven intent
     */
    event IntentAlreadyProven(bytes32 _intentHash);

    /**
     * @notice Unauthorized call to handle() detected
     * @param _sender Address that attempted the call
     */
    error UnauthorizedHandle(address _sender);

    /**
     * @notice Unauthorized dispatch detected from source chain
     * @param _sender Address that initiated the invalid dispatch
     */
    error UnauthorizedDispatch(address _sender);

    /**
     * @notice Address of local Metalayer router
     */
    address public immutable ROUTER;

    /**
     * @notice Address of Eco Routes Inbox contract (same across all chains via ERC-2470)
     */
    address public immutable INBOX;

    /**
     * @notice Initializes the MetaProver contract
     * @param _router Address of local Metalayer router
     * @param _inbox Address of Inbox contract
     */
    constructor(address _router, address _inbox) {
        ROUTER = _router;
        INBOX = _inbox;
    }

    /**
     * @notice Handles incoming Metalayer messages containing proof data
     * @dev Processes batch updates to proven intents from valid sources
     * @param _sender Address that dispatched the message on source chain
     * @param _message Encoded array of intent hashes and claimants
     */
    function handle(
        uint32,
        address _sender,
        bytes calldata _message,
        ReadOperation[] calldata,
        bytes[] calldata
    ) external payable {
        // Verify message is from authorized mailbox
        if (ROUTER != msg.sender) {
            revert UnauthorizedHandle(msg.sender);
        }

        if (INBOX != _sender) {
            revert UnauthorizedDispatch(_sender);
        }

        // Decode message containing intent hashes and claimants
        (bytes32[] memory hashes, address[] memory claimants) = abi.decode(
            _message,
            (bytes32[], address[])
        );

        // Process each intent proof
        for (uint256 i = 0; i < hashes.length; i++) {
            (bytes32 intentHash, address claimant) = (hashes[i], claimants[i]);
            if (provenIntents[intentHash] != address(0)) {
                emit IntentAlreadyProven(intentHash);
            } else {
                provenIntents[intentHash] = claimant;
                emit IntentProven(intentHash, claimant);
            }
        }
    }

    /**
     * @notice Returns the proof type used by this prover
     * @return ProofType indicating Metalayer proving mechanism
     */
    function getProofType() external pure override returns (ProofType) {
        return PROOF_TYPE;
    }
}
