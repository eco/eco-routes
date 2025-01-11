// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMailbox, IPostDispatchHook} from "@hyperlane-xyz/core/contracts/interfaces/IMailbox.sol";
import {TypeCasts} from "@hyperlane-xyz/core/contracts/libs/TypeCasts.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IInbox} from "./interfaces/IInbox.sol";
import {Intent, Route, Call} from "./types/Intent.sol";
import {Semver} from "./libs/Semver.sol";

/**
 * @title Inbox
 * @dev The Inbox contract is the main entry point for fulfilling an intent.
 * It validates that the hash is the hash of the other parameters, and then executes the calldata.
 * A prover can then claim the reward on the src chain by looking at the fulfilled mapping.
 */
contract Inbox is IInbox, Ownable {
    using TypeCasts for address;

    uint256 public constant MAX_BATCH_SIZE = 10;

    // Mapping of intent hash on the src chain to its fulfillment
    mapping(bytes32 => address) public fulfilled;

    // Mapping of solvers to if they are whitelisted
    mapping(address => bool) public solverWhitelist;

    // address of local hyperlane mailbox
    address public mailbox;

    // Is solving public
    bool public isSolvingPublic;

    /**
     * constructor
     *  _owner the owner of the contract that gets access to privileged functions
     *  _isSolvingPublic whether or not solving is public at start
     *  _solvers the initial whitelist of solvers, only relevant if {_isSolvingPublic} is false
     * @dev privileged functions are made such that they can only make changes once
     */
    constructor(
        address _owner,
        bool _isSolvingPublic,
        address[] memory _solvers
    ) Ownable(_owner) {
        isSolvingPublic = _isSolvingPublic;
        for (uint256 i = 0; i < _solvers.length; i++) {
            solverWhitelist[_solvers[i]] = true;
            emit SolverWhitelistChanged(_solvers[i], true);
        }
    }

    function version() external pure returns (string memory) {
        return Semver.version();
    }

    /**
     * @notice fulfills an intent to be proven via storage proofs
     * @param _route The route of the intent
     * @param _rewardHash The hash of the reward
     * @param _claimant The address that will receive the reward on the source chain
     * @param _expectedHash The hash of the intent as created on the source chain
     */
    function fulfillStorage(
        Route calldata _route,
        bytes32 _rewardHash,
        address _claimant,
        bytes32 _expectedHash
    ) external payable returns (bytes[] memory) {
        bytes[] memory result = _fulfill(_route, _rewardHash, _claimant, _expectedHash);

        emit ToBeProven(_expectedHash, _route.source, _claimant);

        return result;
    }

    /**
     * @notice fulfills an intent to be proven immediately via Hyperlane's mailbox
     * @param _route The route of the intent
     * @param _rewardHash The hash of the reward
     * @param _claimant The address that will receive the reward on the source chain
     * @param _expectedHash The hash of the intent as created on the source chain
     * @param _prover The address of the hyperprover on the source chain
     * @dev solvers can expect this proof to be more expensive than hyperbatched, but it will be faster.
     * @dev a fee is required to be sent with the transaction, it pays for the use of Hyperlane's architecture
     */
    function fulfillHyperInstant(
        Route calldata _route,
        bytes32 _rewardHash,
        address _claimant,
        bytes32 _expectedHash,
        address _prover
    ) external payable returns (bytes[] memory) {
        return
            fulfillHyperInstantWithRelayer(
                _route,
                _rewardHash,
                _claimant,
                _expectedHash,
                _prover,
                bytes(""),
                address(0)
            );
    }

    /**
     * @notice fulfills an intent to be proven immediately via Hyperlane's mailbox
     * @param _route The route of the intent
     * @param _rewardHash The hash of the reward
     * @param _claimant The address that will receive the reward on the source chain
     * @param _expectedHash The hash of the intent as created on the source chain
     * @param _prover The address of the hyperprover on the source chain
     * @param _metadata the metadata required for the postDispatchHook on the source chain, set to empty bytes if not applicable
     * @param _postDispatchHook the address of the postDispatchHook on the source chain, set to zero address if not applicable
     * @dev solvers can expect this proof to be more expensive than hyperbatched, but it will be faster.
     * @dev a fee is required to be sent with the transaction, it pays for the use of Hyperlane's architecture
     */
    function fulfillHyperInstantWithRelayer(
        Route calldata _route,
        bytes32 _rewardHash,
        address _claimant,
        bytes32 _expectedHash,
        address _prover,
        bytes memory _metadata,
        address _postDispatchHook
    ) public payable returns (bytes[] memory) {
        bytes32[] memory hashes = new bytes32[](1);
        address[] memory claimants = new address[](1);
        hashes[0] = _expectedHash;
        claimants[0] = _claimant;

        bytes memory messageBody = abi.encode(hashes, claimants);
        bytes32 _prover32 = _prover.addressToBytes32();

        emit HyperInstantFulfillment(_expectedHash, _route.source, _claimant);

        uint256 fee = fetchFee(
            _route.source,
            _prover32,
            messageBody,
            _metadata,
            _postDispatchHook
        );
        if (msg.value < fee) {
            revert InsufficientFee(fee);
        }
        bytes[] memory results = _fulfill(_route, _rewardHash, _claimant, _expectedHash);
        if (msg.value > fee) {
            (bool success, ) = payable(msg.sender).call{value: msg.value - fee}("");
            require(success, "Native transfer failed.");
        }
        if (_postDispatchHook == address(0)) {
            IMailbox(mailbox).dispatch{value: fee}(
                uint32(_route.source),
                _prover32,
                messageBody
            );
        } else {
            IMailbox(mailbox).dispatch{value: fee}(
                uint32(_route.source),
                _prover32,
                messageBody,
                _metadata,
                IPostDispatchHook(_postDispatchHook)
            );
        }
        return results;
    }

    /**
     * @notice fulfills an intent to be proven in a batch via Hyperlane's mailbox

     * @param _claimant The address that will receive the reward on the source chain
     * @param _expectedHash The hash of the intent as created on the source chain
     * @param _prover The address of the hyperprover on the source chain
     * @dev solvers can expect this proof to be considerably less expensive than hyperinstant, but it will take longer.
     * @dev the batch will only be dispatched when sendBatch is called
     * @dev this method is not currently supported by Eco's solver services, but is included for completeness.
     */
    function fulfillHyperBatched(
        Route calldata _route,
        bytes32 _rewardHash,
        address _claimant,
        bytes32 _expectedHash,
        address _prover
    ) external payable returns (bytes[] memory) {
        emit AddToBatch(_expectedHash, _route.source, _claimant, _prover);

        bytes[] memory results = _fulfill(_route, _rewardHash, _claimant, _expectedHash);

        return results;
    }

    /**
     * @notice sends a batch of fulfilled intents to the mailbox
     * @param _sourceChainID the chainID of the source chain
     * @param _prover the address of the hyperprover on the source chain
     * @param _intentHashes the hashes of the intents to be proven
     * @dev it is imperative that the intent hashes correspond to fulfilled intents that originated on the chain with chainID {_sourceChainID}
     * @dev a fee is required to be sent with the transaction, it pays for the use of Hyperlane's architecture
     */
    function sendBatch(
        uint256 _sourceChainID,
        address _prover,
        bytes32[] calldata _intentHashes
    ) external payable {
        sendBatchWithRelayer(
            _sourceChainID,
            _prover,
            _intentHashes,
            bytes(""),
            address(0)
        );
    }

    /**
     * @notice sends a batch of fulfilled intents to the mailbox
     * @param _sourceChainID the chainID of the source chain
     * @param _prover the address of the hyperprover on the source chain
     * @param _intentHashes the hashes of the intents to be proven
     * @dev it is imperative that the intent hashes correspond to fulfilled intents that originated on the chain with chainID {_sourceChainID}
     * @dev a fee is required to be sent with the transaction, it pays for the use of Hyperlane's architecture
     */
    function sendBatchWithRelayer(
        uint256 _sourceChainID,
        address _prover,
        bytes32[] calldata _intentHashes,
        bytes memory _metadata,
        address _postDispatchHook
    ) public payable {
        uint256 size = _intentHashes.length;
        if (size > MAX_BATCH_SIZE) {
            revert BatchTooLarge();
        }
        address[] memory claimants = new address[](size);
        for (uint256 i = 0; i < size; i++) {
            address claimant = fulfilled[_intentHashes[i]];
            if (claimant == address(0)) {
                revert IntentNotFulfilled(_intentHashes[i]);
            }
            claimants[i] = claimant;
        }
        bytes memory messageBody = abi.encode(_intentHashes, claimants);
        bytes32 _prover32 = _prover.addressToBytes32();
        uint256 fee = fetchFee(
            _sourceChainID,
            _prover32,
            messageBody,
            _metadata,
            _postDispatchHook
        );
        if (msg.value < fee) {
            revert InsufficientFee(fee);
        }
        if (msg.value > fee) {
            (bool success, ) = payable(msg.sender).call{value: msg.value - fee}("");
            require(success, "Native transfer failed.");
        }
        if (_postDispatchHook == address(0)) {
            IMailbox(mailbox).dispatch{value: fee}(
                uint32(_sourceChainID),
                _prover32,
                messageBody
            );
        } else {
            IMailbox(mailbox).dispatch{value: fee}(
                uint32(_sourceChainID),
                _prover32,
                messageBody,
                _metadata,
                IPostDispatchHook(_postDispatchHook)
            );
        }
    }

    /**
     * @notice wrapper method for the mailbox's quoteDispatch method
     * @param _sourceChainID the chainID of the source chain
     * @param _prover the address of the hyperprover on the source chain
     * @param _messageBody the message body being sent over the bridge
     * @param _metadata the metadata required for the postDispatchHook on the source chain, set to empty bytes if not applicable
     * @param _postDispatchHook the address of the postDispatchHook on the source chain, set to zero address if not applicable
     * @dev this method is used to determine the fee required for fulfillHyperInstant or sendBatch
     */
    function fetchFee(
        uint256 _sourceChainID,
        bytes32 _prover,
        bytes memory _messageBody,
        bytes memory _metadata,
        address _postDispatchHook
    ) public view returns (uint256 fee) {
        return (
            _postDispatchHook == address(0)
                ? IMailbox(mailbox).quoteDispatch(
                    uint32(_sourceChainID),
                    _prover,
                    _messageBody
                )
                : IMailbox(mailbox).quoteDispatch(
                    uint32(_sourceChainID),
                    _prover,
                    _messageBody,
                    _metadata,
                    IPostDispatchHook(_postDispatchHook)
                )
        );
    }

    /**
     * @notice allows for native token transfers on the destination chain
     * @param _to the address to which the native tokens will be sent
     * @param _amount the amount of native tokens to be sent
     * @dev cannot be internal since invoked by low-level call
     * @dev can only be invoked from the contract itself
     */
    function transferNative(address payable _to, uint256 _amount) public {
        if (msg.sender != address(this)) {
            revert UnauthorizedTransferNative();
        }
        (bool success, ) = _to.call{value: _amount}("");
        require(success, "Native transfer failed.");
    }

    /**
     * @notice allows the owner to set the mailbox
     * @param _mailbox the address of the mailbox
     * @dev this can only be called once, to initialize the mailbox, and should be called at time of deployment
     */
    function setMailbox(address _mailbox) public onlyOwner {
        if (mailbox == address(0)) {
            mailbox = _mailbox;
            emit MailboxSet(_mailbox);
        }
    }

    /**
     * @notice makes solving public if it is restricted
     * @dev solving cannot be made private once it is made public
     */
    function makeSolvingPublic() public onlyOwner {
        if (!isSolvingPublic) {
            isSolvingPublic = true;
            emit SolvingIsPublic();
        }
    }

    /**
     * @notice allows the owner to make changes to the solver whitelist
     * @param _solver the address of the solver whose permissions are being changed
     * @param _canSolve whether or not the solver will be on the whitelist afterward
     * @dev the solver whitelist has no meaning if isSolvingPublic is true
     */
    function changeSolverWhitelist(address _solver, bool _canSolve) public onlyOwner {
        solverWhitelist[_solver] = _canSolve;
        emit SolverWhitelistChanged(_solver, _canSolve);
    }

    function _fulfill(
        Route calldata _route,
        bytes32 _rewardHash,
        address _claimant,
        bytes32 _expectedHash
    ) internal returns (bytes[] memory) {
        if (!isSolvingPublic && !solverWhitelist[msg.sender]) {
            revert UnauthorizedSolveAttempt(msg.sender);
        }

        bytes32 routeHash = keccak256(abi.encode(_route));
        bytes32 intentHash = keccak256(abi.encodePacked(routeHash, _rewardHash));

        if (_route.inbox != address(this)) {
            revert InvalidInbox(_route.inbox);
        }

        if (intentHash != _expectedHash) {
            revert InvalidHash(_expectedHash);
        }
        if (fulfilled[intentHash] != address(0)) {
            revert IntentAlreadyFulfilled(intentHash);
        }
        if (_claimant == address(0)) {
            revert ZeroClaimant();
        }

        fulfilled[intentHash] = _claimant;
        emit Fulfillment(_expectedHash, _route.source, _claimant);

        // Store the results of the calls
        bytes[] memory results = new bytes[](_route.calls.length);

        for (uint256 i = 0; i < _route.calls.length; i++) {
            Call calldata call = _route.calls[i];
            if (call.target == mailbox) {
                // no executing calls on the mailbox
                revert CallToMailbox();
            }
            (bool success, bytes memory result) = call.target.call{value: call.value}(
                call.data
            );
            if (!success) {
                revert IntentCallFailed(call.target, call.data, call.value, result);
            }
            results[i] = result;
        }
        return results;
    }

    receive() external payable {}
}
