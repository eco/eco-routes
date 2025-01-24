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
 * @notice Main entry point for fulfilling intents
 * @dev Validates intent hash authenticity and executes calldata. Enables provers
 * to claim rewards on the source chain by checking the fulfilled mapping
 */
contract Inbox is IInbox, Ownable, Semver {
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
     * @notice Initializes the Inbox contract
     * @dev Privileged functions are designed to only allow one-time changes
     * @param _owner Address with access to privileged functions
     * @param _isSolvingPublic Whether solving is public at start
     * @param _solvers Initial whitelist of solvers (only relevant if solving is not public)
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

    /**
     * @notice Fulfills an intent to be proven via storage proofs
     * @param _route The route of the intent
     * @param _rewardHash The hash of the reward
     * @param _claimant The address that will receive the reward on the source chain
     * @param _expectedHash The hash of the intent as created on the source chain
     * @return Array of execution results from each call
     */
    function fulfillStorage(
        Route calldata _route,
        bytes32 _rewardHash,
        address _claimant,
        bytes32 _expectedHash
    ) external payable returns (bytes[] memory) {
        bytes[] memory result = _fulfill(
            _route,
            _rewardHash,
            _claimant,
            _expectedHash
        );

        emit ToBeProven(_expectedHash, _route.source, _claimant);

        return result;
    }

    /**
     * @notice Fulfills an intent to be proven immediately via Hyperlane's mailbox
     * @dev More expensive but faster than hyperbatched. Requires fee for Hyperlane infrastructure
     * @param _route The route of the intent
     * @param _rewardHash The hash of the reward
     * @param _claimant The address that will receive the reward on the source chain
     * @param _expectedHash The hash of the intent as created on the source chain
     * @param _prover The address of the hyperprover on the source chain
     * @return Array of execution results from each call
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
     * @notice Fulfills an intent to be proven immediately via Hyperlane's mailbox with relayer support
     * @dev More expensive but faster than hyperbatched. Requires fee for Hyperlane infrastructure
     * @param _route The route of the intent
     * @param _rewardHash The hash of the reward
     * @param _claimant The address that will receive the reward on the source chain
     * @param _expectedHash The hash of the intent as created on the source chain
     * @param _prover The address of the hyperprover on the source chain
     * @param _metadata Metadata for postDispatchHook (empty bytes if not applicable)
     * @param _postDispatchHook Address of postDispatchHook (zero address if not applicable)
     * @return Array of execution results from each call
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
        bytes[] memory results = _fulfill(
            _route,
            _rewardHash,
            _claimant,
            _expectedHash
        );
        if (msg.value > fee) {
            (bool success, ) = payable(msg.sender).call{value: msg.value - fee}(
                ""
            );
            if (!success) {
                revert NativeTransferFailed();
            }
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
     * @notice Fulfills an intent to be proven in a batch via Hyperlane's mailbox
     * @dev Less expensive but slower than hyperinstant. Batch dispatched when sendBatch is called.
     * @param _route The route of the intent
     * @param _rewardHash The hash of the reward
     * @param _claimant The address that will receive the reward on the source chain
     * @param _expectedHash The hash of the intent as created on the source chain
     * @param _prover The address of the hyperprover on the source chain
     * @return Array of execution results from each call
     */
    function fulfillHyperBatched(
        Route calldata _route,
        bytes32 _rewardHash,
        address _claimant,
        bytes32 _expectedHash,
        address _prover
    ) external payable returns (bytes[] memory) {
        emit AddToBatch(_expectedHash, _route.source, _claimant, _prover);

        bytes[] memory results = _fulfill(
            _route,
            _rewardHash,
            _claimant,
            _expectedHash
        );

        return results;
    }

    /**
     * @notice Sends a batch of fulfilled intents to the mailbox
     * @dev Intent hashes must correspond to fulfilled intents from specified source chain
     * @param _sourceChainID Chain ID of the source chain
     * @param _prover Address of the hyperprover on the source chain
     * @param _intentHashes Hashes of the intents to be proven
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
     * @notice Sends a batch of fulfilled intents to the mailbox with relayer support
     * @dev Intent hashes must correspond to fulfilled intents from specified source chain
     * @param _sourceChainID Chain ID of the source chain
     * @param _prover Address of the hyperprover on the source chain
     * @param _intentHashes Hashes of the intents to be proven
     * @param _metadata Metadata for postDispatchHook
     * @param _postDispatchHook Address of postDispatchHook
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
            (bool success, ) = payable(msg.sender).call{value: msg.value - fee}(
                ""
            );
            if (!success) {
                revert NativeTransferFailed();
            }
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
     * @notice Quotes the fee required for message dispatch
     * @dev Used to determine fees for fulfillHyperInstant or sendBatch
     * @param _sourceChainID Chain ID of the source chain
     * @param _prover Address of the hyperprover on the source chain
     * @param _messageBody Message being sent over the bridge
     * @param _metadata Metadata for postDispatchHook
     * @param _postDispatchHook Address of postDispatchHook
     * @return fee The required fee amount
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
     * @notice Enables native token transfers on the destination chain
     * @dev Can only be called by the contract itself
     * @param _to Recipient address
     * @param _amount Amount of native tokens to send
     */
    function transferNative(address payable _to, uint256 _amount) public {
        if (msg.sender != address(this)) {
            revert UnauthorizedTransferNative();
        }
        (bool success, ) = _to.call{value: _amount}("");
        if (!success) {
            revert NativeTransferFailed();
        }
    }

    /**
     * @notice Sets the mailbox address
     * @dev Can only be called once during deployment
     * @param _mailbox Address of the Hyperlane mailbox
     */
    function setMailbox(address _mailbox) public onlyOwner {
        if (mailbox == address(0)) {
            mailbox = _mailbox;
            emit MailboxSet(_mailbox);
        }
    }

    /**
     * @notice Makes solving public if currently restricted
     * @dev Cannot be reversed once made public
     */
    function makeSolvingPublic() public onlyOwner {
        if (!isSolvingPublic) {
            isSolvingPublic = true;
            emit SolvingIsPublic();
        }
    }

    /**
     * @notice Updates the solver whitelist
     * @dev Whitelist is ignored if solving is public
     * @param _solver Address of the solver
     * @param _canSolve Whether solver should be whitelisted
     */
    function changeSolverWhitelist(
        address _solver,
        bool _canSolve
    ) public onlyOwner {
        solverWhitelist[_solver] = _canSolve;
        emit SolverWhitelistChanged(_solver, _canSolve);
    }

    /**
     * @notice Internal function to fulfill intents
     * @dev Validates intent and executes calls
     * @param _route The route of the intent
     * @param _rewardHash The hash of the reward
     * @param _claimant The reward recipient address
     * @param _expectedHash The expected intent hash
     * @return Array of execution results
     */
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
        bytes32 intentHash = keccak256(
            abi.encodePacked(routeHash, _rewardHash)
        );

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
            (bool success, bytes memory result) = call.target.call{
                value: call.value
            }(call.data);
            if (!success) {
                revert IntentCallFailed(
                    call.target,
                    call.data,
                    call.value,
                    result
                );
            }
            results[i] = result;
        }
        return results;
    }

    receive() external payable {}
}
