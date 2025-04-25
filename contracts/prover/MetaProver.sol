// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMetalayerRecipient, ReadOperation} from "@metalayer/contracts/src/interfaces/IMetalayerRecipient.sol";
import {FinalityState} from "@metalayer/contracts/src/lib/MetalayerMessage.sol";
import {TypeCasts} from "@hyperlane-xyz/core/contracts/libs/TypeCasts.sol";
import {MessageBridgeProver} from "./MessageBridgeProver.sol";
import {Semver} from "../libs/Semver.sol";
import {IMetalayerRouter} from "@metalayer/contracts/src/interfaces/IMetalayerRouter.sol";

/**
 * @title MetaProver
 * @notice Prover implementation using Caldera Metalayer's cross-chain messaging system
 * @dev Processes proof messages from Metalayer router and records proven intents
 */
contract MetaProver is IMetalayerRecipient, MessageBridgeProver, Semver {
    using TypeCasts for bytes32;
    using TypeCasts for address;

    /**
     * @notice Constant indicating this contract uses Metalayer for proving
     */
    string public constant PROOF_TYPE = "Metalayer";

    /**
     * @notice Address of local Metalayer router
     */
    address public immutable ROUTER;

    /**
     * @notice Initializes the MetaProver contract
     * @param _router Address of local Metalayer router
     * @param _inbox Address of Inbox contract
     * @param _provers Array of trusted provers to whitelist
     */
    constructor(
        address _router,
        address _inbox,
        address[] memory _provers
    ) MessageBridgeProver(_inbox, _provers) {
        ROUTER = _router;
    }

    /**
     * @notice Handles incoming Metalayer messages containing proof data
     * @dev Processes batch updates to proven intents from valid sources
     * @param _sender Address that dispatched the message on source chain
     * @param _message Encoded array of intent hashes and claimants
     */
    function handle(
        uint32,
        bytes32 _sender,
        bytes calldata _message,
        ReadOperation[] calldata,
        bytes[] calldata
    ) external payable {
        // Verify message is from authorized router
        _validateMessageSender(msg.sender, ROUTER);

        // Verify dispatch originated from valid destinationChain prover
        address sender = _sender.bytes32ToAddress();
        if (!proverWhitelist[sender]) {
            revert UnauthorizedDestinationProve(sender);
        }

        // Decode message containing intent hashes and claimants
        (bytes32[] memory hashes, address[] memory claimants) = abi.decode(
            _message,
            (bytes32[], address[])
        );

        // Process intent proofs using shared implementation
        _processIntentProofs(hashes, claimants);
    }

    /**
     * @notice Initiates proving of intents via Metalayer
     * @dev Sends message to source chain prover with intent data
     * @param _sender Address that initiated the proving request
     * @param _sourceChainId Chain ID of source chain
     * @param _intentHashes Array of intent hashes to prove
     * @param _claimants Array of claimant addresses
     * @param _data Additional data for message formatting
     */
    function destinationProve(
        address _sender,
        uint256 _sourceChainId,
        bytes32[] calldata _intentHashes,
        address[] calldata _claimants,
        bytes calldata _data
    ) external payable override {
        // Ensure array lengths match
        require(_intentHashes.length == _claimants.length, "Array length mismatch");
        
        // Validate the request is from Inbox
        _validateProvingRequest(msg.sender);

        // Calculate and process payment
        uint256 fee = fetchFee(
            _sourceChainId,
            _intentHashes,
            _claimants,
            _data
        );
        _processPayment(fee, _sender);

        // Format message for dispatch
        (
            uint32 domain,
            bytes32 recipient,
            bytes memory message
        ) = processAndFormat(_sourceChainId, _intentHashes, _claimants, _data);

        emit BatchSent(_intentHashes, _sourceChainId);

        // Call Metalayer router's send message function
        IMetalayerRouter(ROUTER).dispatch{value: address(this).balance}(
            domain,
            recipient,
            new ReadOperation[](0),
            message,
            FinalityState.INSTANT,
            200_000
        );
    }

    /**
     * @notice Fetches fee required for message dispatch
     * @dev Queries Metalayer router for fee information
     * @param _sourceChainId Chain ID of source chain
     * @param _intentHashes Array of intent hashes to prove
     * @param _claimants Array of claimant addresses
     * @param _data Additional data for message formatting
     * @return Fee amount required for message dispatch
     */
    function fetchFee(
        uint256 _sourceChainId,
        bytes32[] calldata _intentHashes,
        address[] calldata _claimants,
        bytes calldata _data
    ) public view override returns (uint256) {
        (
            uint32 domain,
            bytes32 recipient,
            bytes memory message
        ) = processAndFormat(_sourceChainId, _intentHashes, _claimants, _data);

        return
            IMetalayerRouter(ROUTER).quoteDispatch(domain, recipient, message);
    }

    /**
     * @notice Returns the proof type used by this prover
     * @return ProofType indicating Metalayer proving mechanism
     */
    function getProofType() external pure override returns (string memory) {
        return PROOF_TYPE;
    }

    /**
     * @notice Processes and formats data for Metalayer message dispatch
     * @dev Prepares all parameters needed for the Router dispatch call
     * @param _sourceChainId Chain ID of the source chain
     * @param hashes Array of intent hashes to prove
     * @param claimants Array of claimant addresses
     * @param _data Additional data for message formatting
     * @return domain Metalayer domain ID
     * @return recipient Recipient address encoded as bytes32
     * @return message Encoded message body with intent hashes and claimants
     */
    function processAndFormat(
        uint256 _sourceChainId,
        bytes32[] calldata hashes,
        address[] calldata claimants,
        bytes calldata _data
    )
        internal
        pure
        returns (uint32 domain, bytes32 recipient, bytes memory message)
    {
        // Array length validation is done in the destinationProve function for consistency
        
        domain = uint32(_sourceChainId);
        recipient = abi.decode(_data, (bytes32));
        message = abi.encode(hashes, claimants);
    }
}
