// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@hyperlane-xyz/core/contracts/libs/TypeCasts.sol";
import "./interfaces/IMetalayerRecipient.sol";
import "./interfaces/SimpleProver.sol";

/**
 * @title MetalayerProver
 * @author Constellation Labs
 * @notice A simple prover implementation for Eco's routing of Metalayer-settled intents.
 * @dev This implementation is designed to be used as a prover for Eco Protocol intents that are routed through Metalayer,
 * and is not designed to be used as a general-purpose prover for Metalayer intents out of the context of Eco Protocol.
 */
contract MetalayerProver is IMetalayerRecipient, SimpleProver {
    using TypeCasts for bytes32;

    ProofType public constant PROOF_TYPE = ProofType.Metalayer;

    /**
     * @notice emitted on an attempt to register a claimant on an intent that has already been proven and has a claimant
     * @dev this is an event rather than an error because the expected behavior is to ignore one intent but continue with the rest
     * @param _intentHash the hash of the intent
     */
    event IntentAlreadyProven(bytes32 _intentHash);

    /**
     * @notice emitted on an unauthorized call to the handle() method
     * @param _sender the address that called the handle() method
     */
    error UnauthorizedHandle(address _sender);

    /**
     * @notice emitted when the handle() call is a result of an unauthorized dispatch() call on another chain's Router
     * @param _sender the address that called the dispatch() method
     */
    error UnauthorizedDispatch(address _sender);

    /// @notice the address of the local MetalayerRouter
    address public immutable ROUTER;

    /// @notice the address of the Inbox contract
    address public immutable INBOX;

    /**
     * @notice Initializes the addresses of the local MetalayerRouter and Eco's Inbox contract
     * @param _router the address of the local MetalayerRouter
     * @param _inbox the address of the Inbox contract
     */
    constructor(address _router, address _inbox) {
        ROUTER = _router;
        INBOX = _inbox;
    }

    /**
     * @notice The current version of the prover
     * @return version identifier
     */
    function version() external pure returns (string memory) {
        return Semver.version();
    }

    /**
     * @notice Handles intents from the MetalayerRouter
     * @param -_chainId the chain ID of the intent's origin chain (not used)
     * @param _sender the address that called the dispatch() method
     * @param _message the write call data (message body)
     * @param -_reads array of read operations performed (not used)
     * @param -_readResults results of the read operations (not used)
     * @dev This function is designed to be called by the MetalayerRouter on the local chain.
     */
    function handle(
        uint32,
        address _sender,
        bytes calldata _message,
        ReadOperation[] calldata,
        bytes[] calldata
    ) external payable {
        if (ROUTER != msg.sender) {
            revert UnauthorizedHandle(msg.sender);
        }

        if (INBOX != _sender) {
            revert UnauthorizedDispatch(_sender);
        }

        (bytes32[] memory hashes, address[] memory claimants) = abi.decode(
            _message,
            (bytes32[], address[])
        );

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
     * @return the proof type
     */
    function getProofType() external pure override returns (ProofType) {
        return PROOF_TYPE;
    }
}
