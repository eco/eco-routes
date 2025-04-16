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
    ProofType public constant PROOF_TYPE = ProofType.Hyperlane;

    /**
     * @notice Emitted when attempting to prove an already-proven intent
     * @dev Event instead of error to allow batch processing to continue
     * @param _intentHash Hash of the already proven intent
     */
    event IntentAlreadyProven(bytes32 _intentHash);

    /**
     * @notice Emitted when a batch of fulfilled intents is sent to the Hyperlane mailbox to be relayed to the source chain
     * @param _hashes the intent hashes sent in the batch
     * @param _sourceChainID ID of the source chain
     */
    event BatchSent(bytes32[] indexed _hashes, uint256 indexed _sourceChainID);

    /**
     * @notice Unauthorized call to handle() detected
     * @param _sender Address that attempted the call
     */
    error UnauthorizedHandle(address _sender);

    /**
     * @notice Unauthorized call to initiate proving
     * @param _sender Address that initiated
     */
    error UnauthorizedInitiateProving(address _sender);

    /**
     * @notice Address of local Hyperlane mailbox
     */
    address public immutable MAILBOX;

    /**
     * @notice Address of Inbox contract (same across all chains via ERC-2470)
     */
    address public immutable INBOX;

    /**
     * @notice Initializes the HyperProver contract
     * @param _mailbox Address of local Hyperlane mailbox
     * @param _inbox Address of Inbox contract
     */
    constructor(address _mailbox, address _inbox, address[] memory _provers) {
        MAILBOX = _mailbox;
        INBOX = _inbox;
        proverWhitelist[address(this)] = true;
        for (uint256 i = 0; i < _provers.length; i++) {
            proverWhitelist[_provers[i]] = true;
        }
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
        if (MAILBOX != msg.sender) {
            revert UnauthorizedHandle(msg.sender);
        }

        // Verify dispatch originated from valid destinationChain prover
        address sender = _sender.bytes32ToAddress();

        if (!proverWhitelist[sender]) {
            revert UnauthorizedInitiateProving(sender);
        }

        // Decode message containing intent hashes and claimants
        (bytes32[] memory hashes, address[] memory claimants) = abi.decode(
            _messageBody,
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

    function initiateProving(
        uint256 _sourceChainId,
        bytes32[] calldata _intentHashes,
        address[] calldata _claimants,
        address _sourceChainProver,
        bytes calldata _data
    ) external payable override {
        if (msg.sender != INBOX) {
            revert UnauthorizedInitiateProving(msg.sender);
        }

        emit BatchSent(_intentHashes, _sourceChainId);

        (
            uint32 destinationDomain,
            bytes32 recipientAddress,
            bytes memory messageBody,
            bytes memory metadata,
            IPostDispatchHook hook
        ) = processAndFormat(
                _sourceChainId,
                _intentHashes,
                _claimants,
                _sourceChainProver,
                _data
            );

        IMailbox(MAILBOX).dispatch{value: msg.value}(
            destinationDomain,
            recipientAddress,
            messageBody,
            metadata,
            hook
        );
    }

    function fetchFee(
        uint256 _sourceChainId,
        bytes32[] calldata _intentHashes,
        address[] calldata _claimants,
        address _sourceChainProver,
        bytes calldata _data
    ) public view override returns (uint256) {
        (
            uint32 destinationDomain,
            bytes32 recipientAddress,
            bytes memory messageBody,
            bytes memory metadata,
            IPostDispatchHook hook
        ) = processAndFormat(
                _sourceChainId,
                _intentHashes,
                _claimants,
                _sourceChainProver,
                _data
            );

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
    function getProofType() external pure override returns (ProofType) {
        return PROOF_TYPE;
    }

    function processAndFormat(
        uint256 _sourceChainId,
        bytes32[] calldata hashes,
        address[] calldata claimants,
        address _sourceChainProver,
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
        uint32 domain = uint32(_sourceChainId);
        bytes32 recipient = TypeCasts.addressToBytes32(_sourceChainProver);
        bytes memory message = abi.encode(hashes, claimants);

        (bytes memory metadata, address hookAddr) = abi.decode(
            _data,
            (bytes, address)
        );
        IPostDispatchHook hook = (hookAddr == address(0))
            ? IMailbox(MAILBOX).defaultHook()
            : IPostDispatchHook(hookAddr);
    }
}
