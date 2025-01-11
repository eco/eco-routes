// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMessageRecipient} from "@hyperlane-xyz/core/contracts/interfaces/IMessageRecipient.sol";
import {TypeCasts} from "@hyperlane-xyz/core/contracts/libs/TypeCasts.sol";
import {SimpleProver} from "./interfaces/SimpleProver.sol";
import {Semver} from "./libs/Semver.sol";

contract HyperProver is IMessageRecipient, SimpleProver {
    using TypeCasts for bytes32;

    ProofType public constant PROOF_TYPE = ProofType.Hyperlane;

    /**
     * emitted on an attempt to register a claimant on an intent that has already been proven and has a claimant
     * @dev this is an event rather than an error because the expected behavior is to ignore one intent but continue with the rest
     * @param _intentHash the hash of the intent
     */
    event IntentAlreadyProven(bytes32 _intentHash);

    /**
     * emitted on an unauthorized call to the handle() method
     * @param _sender the address that called the handle() method
     */
    error UnauthorizedHandle(address _sender);

    /**
     * emitted when the handle() call is a result of an unauthorized dispatch() call on another chain's Mailbox
     * @param _sender the address that called the dispatch() method
     */
    error UnauthorizedDispatch(address _sender);

    // local mailbox address
    address public immutable MAILBOX;

    // address of the Inbox contract
    // assumes that all Inboxes are deployed via ERC-2470 and hence have the same address
    address public immutable INBOX;

    /**
     * @notice constructor
     * @dev the constructor sets the addresses of the local mailbox and the Inbox contract
     * _mailbox the address of the local mailbox
     * _inbox the address of the Inbox contract
     */
    constructor(address _mailbox, address _inbox) {
        MAILBOX = _mailbox;
        INBOX = _inbox;
    }

    function version() external pure returns (string memory) {
        return Semver.version();
    }

    /**
     * @notice implementation of the handle method required by IMessageRecipient
     * @dev the uint32 value is not used in this implementation, but it is required by the interface. It is the chain ID of the intent's origin chain.
     * @param _sender the address that called the dispatch() method
     * @param _messageBody the message body
     */
    function handle(uint32, bytes32 _sender, bytes calldata _messageBody) public payable {
        if (MAILBOX != msg.sender) {
            revert UnauthorizedHandle(msg.sender);
        }

        address sender = _sender.bytes32ToAddress();

        if (INBOX != sender) {
            revert UnauthorizedDispatch(sender);
        }
        (bytes32[] memory hashes, address[] memory claimants) = abi.decode(
            _messageBody,
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

    function getProofType() external pure override returns (ProofType) {
        return PROOF_TYPE;
    }
}
