// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMessageRecipient} from "@hyperlane-xyz/core/contracts/interfaces/IMessageRecipient.sol";
import {TypeCasts} from "@hyperlane-xyz/core/contracts/libs/TypeCasts.sol";
import {MessageBridgeProver} from "./MessageBridgeProver.sol";
import {Semver} from "../libs/Semver.sol";
import {IMailbox, IPostDispatchHook} from "@hyperlane-xyz/core/contracts/interfaces/IMailbox.sol";

/**
 * @title HyperProver
 * @notice Prover implementation using Hyperlane's cross-chain messaging system
 * @dev Processes proof messages from Hyperlane mailbox and records proven intents
 */
contract HyperProver is IMessageRecipient, MessageBridgeProver, Semver {
    using TypeCasts for bytes32;

    /**
     * @notice Constant indicating this contract uses Hyperlane for proving
     */
    string public constant PROOF_TYPE = "Hyperlane";

    /**
     * @notice Address of local Hyperlane mailbox
     */
    address public immutable MAILBOX;

    /**
     * @notice Initializes the HyperProver contract
     * @param _mailbox Address of local Hyperlane mailbox
     * @param _inbox Address of Inbox contract
     * @param _provers Array of trusted provers to whitelist
     */
    constructor(
        address _mailbox,
        address _inbox,
        address[] memory _provers
    ) MessageBridgeProver(_inbox, _provers) {
        MAILBOX = _mailbox;
    }

    /**
     * @notice Handles incoming Hyperlane messages containing proof data
     * @dev Processes batch updates to proven intents from valid sources
     * param _origin Origin chain ID (unused but required by interface)
     * @param _sender Address that dispatched the message on source chain
     * @param _messageBody Encoded array of intent hashes and claimants
     */
    function handle(
        uint32,
        bytes32 _sender,
        bytes calldata _messageBody
    ) public payable {
        // Verify message is from authorized mailbox
        _validateMessageSender(msg.sender, MAILBOX);

        // Verify dispatch originated from valid destinationChain prover
        address sender = _sender.bytes32ToAddress();
        if (!proverWhitelist[sender]) {
            revert UnauthorizedDestinationProve(sender);
        }

        // Decode message containing intent hashes and claimants
        (bytes32[] memory hashes, address[] memory claimants) = abi.decode(
            _messageBody,
            (bytes32[], address[])
        );

        // Process intent proofs using shared implementation
        _processIntentProofs(hashes, claimants);
    }

    /**
     * @notice Initiates proving of intents via Hyperlane
     * @dev Sends message to source chain prover with intent data
     * @param _sender Address that initiated the proving request
     * @param _sourceChainId Chain ID of the source chain
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

        emit BatchSent(_intentHashes, _sourceChainId);

        // Format and dispatch message
        (
            uint32 destinationDomain,
            bytes32 recipientAddress,
            bytes memory messageBody,
            bytes memory metadata,
            IPostDispatchHook hook
        ) = processAndFormat(_sourceChainId, _intentHashes, _claimants, _data);

        IMailbox(MAILBOX).dispatch{value: address(this).balance}(
            destinationDomain,
            recipientAddress,
            messageBody,
            metadata,
            hook
        );
    }

    /**
     * @notice Calculates the fee required for Hyperlane message dispatch
     * @dev Queries the Mailbox contract for accurate fee estimation
     * @param _sourceChainId Chain ID of the source chain
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
            uint32 destinationDomain,
            bytes32 recipientAddress,
            bytes memory messageBody,
            bytes memory metadata,
            IPostDispatchHook hook
        ) = processAndFormat(_sourceChainId, _intentHashes, _claimants, _data);

        return
            IMailbox(MAILBOX).quoteDispatch(
                destinationDomain,
                recipientAddress,
                messageBody,
                metadata,
                hook
            );
    }

    /**
     * @notice Returns the proof type used by this prover
     * @return ProofType indicating Hyperlane proving mechanism
     */
    function getProofType() external pure override returns (string memory) {
        return PROOF_TYPE;
    }

    /**
     * @notice Processes and formats data for Hyperlane message dispatch
     * @dev Prepares all parameters needed for the Mailbox dispatch call
     * @param _sourceChainId Chain ID of the source chain
     * @param hashes Array of intent hashes to prove
     * @param claimants Array of claimant addresses
     * @param _data Additional data for message formatting
     * @return domain Hyperlane domain ID
     * @return recipient Recipient address encoded as bytes32
     * @return message Encoded message body with intent hashes and claimants
     * @return metadata Additional metadata for the message
     * @return hook Post-dispatch hook contract
     */
    function processAndFormat(
        uint256 _sourceChainId,
        bytes32[] calldata hashes,
        address[] calldata claimants,
        bytes calldata _data
    )
        internal
        view
        returns (
            uint32 domain,
            bytes32 recipient,
            bytes memory message,
            bytes memory metadata,
            IPostDispatchHook hook
        )
    {
        // Ensure arrays have matching lengths
        require(hashes.length == claimants.length, "Array length mismatch");
        
        domain = uint32(_sourceChainId);
        (
            bytes32 _sourceChainProver,
            bytes memory metadataDecoded,
            address hookAddr
        ) = abi.decode(_data, (bytes32, bytes, address));
        recipient = _sourceChainProver;
        message = abi.encode(hashes, claimants);

        metadata = metadataDecoded;
        hook = (hookAddr == address(0))
            ? IMailbox(MAILBOX).defaultHook()
            : IPostDispatchHook(hookAddr);
    }
}
