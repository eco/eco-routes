// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TypeCasts} from "@hyperlane-xyz/core/contracts/libs/TypeCasts.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {BaseProver} from "./prover/BaseProver.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IInbox} from "./interfaces/IInbox.sol";

import {Intent, Route, Call, TokenAmount} from "./types/Intent.sol";
import {Semver} from "./libs/Semver.sol";

/**
 * @title Inbox
 * @notice Main entry point for fulfilling intents on the destination chain
 * @dev Validates intent hash authenticity, executes calldata, and enables provers
 * to claim rewards on the source chain by checking the fulfilled mapping
 */
contract Inbox is IInbox, Semver {
    using TypeCasts for address;
    using SafeERC20 for IERC20;

    // Mapping of intent hash on the src chain to its fulfillment
    mapping(bytes32 => ClaimantAndBatcherReward) public fulfilled;

    // Mapping of solvers to if they are whitelisted
    mapping(address => bool) public solverWhitelist;

    // address of local hyperlane mailbox
    address public mailbox;

    // Is solving public
    bool public isSolvingPublic;

    // minimum reward to be included in a fulfillHyperBatched tx, to be paid out to the sender of the batch
    uint96 public minBatcherReward;

    /**
     * @notice Initializes the Inbox contract
     * @param _owner Address with access to privileged functions
     * @param _isSolvingPublic Whether solving is public at start
     * @param _solvers Initial whitelist of solvers (only relevant if solving is not public)
     */
    constructor(
        address _owner,
        bool _isSolvingPublic,
        uint96 _minBatcherReward,
        address[] memory _solvers
    ) Ownable(_owner) {
        isSolvingPublic = _isSolvingPublic;
        minBatcherReward = _minBatcherReward;
        for (uint256 i = 0; i < _solvers.length; ++i) {
            solverWhitelist[_solvers[i]] = true;
            emit SolverWhitelistChanged(_solvers[i], true);
        }
    }

    /**
     * @notice Fulfills an intent to be proven via storage proofs
     * @dev Validates intent hash, executes calls, and marks as fulfilled
     * @param _route The route of the intent
     * @param _rewardHash The hash of the reward details
     * @param _claimant The address that will receive the reward on the source chain
     * @param _expectedHash The hash of the intent as created on the source chain
     * @param _localProver The prover contract to use for verification
     * @return Array of execution results from each call
     */
    function fulfill(
        Route memory _route,
        bytes32 _rewardHash,
        address _claimant,
        bytes32 _expectedHash
    )
        public
        payable
        override(IInbox, Eco7683DestinationSettler)
        returns (bytes[] memory)
    {
        (bytes[] memory result, ) = _fulfill(
            _route,
            _rewardHash,
            _claimant,
            _expectedHash
        );

        fulfilled[_expectedHash] = ClaimantAndBatcherReward(
            _claimant,
            uint96(0)
        );

        emit ToBeProven(_expectedHash, _route.source, _claimant);

        return result;
    }

    /**
     * @notice Fulfills an intent and initiates proving in one transaction
     * @dev Executes intent actions and sends proof message to source chain
     * @param _route The route of the intent
     * @param _rewardHash The hash of the reward details
     * @param _claimant The address that will receive the reward on the source chain
     * @param _expectedHash The hash of the intent as created on the source chain
     * @param _localProver Address of prover on the destination chain
     * @param _data Additional data for message formatting
     * @return Array of execution results
     */
    function fulfillAndProve(
        Route memory _route,
        bytes32 _rewardHash,
        address _claimant,
        bytes32 _expectedHash,
        address _localProver,
        bytes calldata _data
    ) public payable returns (bytes[] memory) {
        bytes[] memory result = _fulfill(
            _route,
            _rewardHash,
            _claimant,
            _expectedHash,
            _localProver
        );

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
        (bytes[] memory results, uint256 currentBalance) = _fulfill(
            _route,
            _rewardHash,
            _claimant,
            _expectedHash
        );

        fulfilled[_expectedHash] = ClaimantAndBatcherReward(
            _claimant,
            uint96(0)
        );

        if (currentBalance < fee) {
            revert InsufficientFee(fee);
        }
        if (currentBalance > fee) {
            (bool success, ) = payable(msg.sender).call{
                value: currentBalance - fee
            }("");
            if (!success) {
                revert NativeTransferFailed();
            }
        }
        // Use a helper function to handle the dispatch logic and reduce stack depth
        _dispatchMessage(
            uint32(_route.source),
            _prover32,
            messageBody,
            _metadata,
            _postDispatchHook,
            fee
        );
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

        (bytes[] memory results, uint256 remainingValue) = _fulfill(
            _route,
            _rewardHash,
            _claimant,
            _expectedHash
        );

        if (remainingValue < minBatcherReward) {
            revert InsufficientBatcherReward(minBatcherReward);
        }

        fulfilled[_expectedHash] = ClaimantAndBatcherReward(
            _claimant,
            uint96(remainingValue)
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
    function initiateProving(
        uint256 _sourceChainId,
        bytes32[] memory _intentHashes,
        address _localProver,
        bytes calldata _data
    ) public payable {
        if (_localProver == address(0)) {
            // storage prover case, this method should do nothing
            return;
        }
        uint256 size = _intentHashes.length;
        address[] memory claimants = new address[](size);
        for (uint256 i = 0; i < size; ++i) {
            address claimant = fulfilled[_intentHashes[i]].claimant;
            reward += fulfilled[_intentHashes[i]].reward;
            if (claimant == address(0)) {
                revert IntentNotFulfilled(_intentHashes[i]);
            }
            claimants[i] = claimant;
        }

        emit BatchSent(_intentHashes, _sourceChainID);

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
        (bool success, ) = payable(msg.sender).call{
            value: msg.value + reward - fee
        }("");
        if (!success) {
            revert NativeTransferFailed();
        }
        // Use the same helper function to handle dispatch logic and reduce stack depth
        _dispatchMessage(
            uint32(_sourceChainID),
            _prover32,
            messageBody,
            _metadata,
            _postDispatchHook,
            fee
        );
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
     * @notice Sets the mailbox address
     * @dev Can only be called when mailbox is not set
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
     * @notice Changes minimum reward for batcher
     * @param _minBatcherReward New minimum reward
     */
    function setMinBatcherReward(uint96 _minBatcherReward) public onlyOwner {
        minBatcherReward = _minBatcherReward;
        emit MinBatcherRewardSet(_minBatcherReward);
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
     * @param _localProver The prover contract to use
     * @return Array of execution results
     */
    function _fulfill(
        Route memory _route,
        bytes32 _rewardHash,
        address _claimant,
        bytes32 _expectedHash
    ) internal returns (bytes[] memory, uint256) {
        if (_route.destination != block.chainid) {
            revert WrongChain(_route.destination);
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

        emit Fulfillment(_expectedHash, _route.source, _claimant);

        uint256 routeTokenCount = _route.tokens.length;
        // Transfer ERC20 tokens to the inbox
        for (uint256 i = 0; i < routeTokenCount; ++i) {
            TokenAmount memory approval = _route.tokens[i];
            IERC20(approval.token).safeTransferFrom(
                msg.sender,
                address(this),
                approval.amount
            );
        }

        // Store the results of the calls
        bytes[] memory results = new bytes[](_route.calls.length);

        for (uint256 i = 0; i < _route.calls.length; ++i) {
            Call memory call = _route.calls[i];
            if (call.target.code.length == 0 && call.data.length > 0) {
                // no code at this address
                revert CallToEOA(call.target);
            }
            (bool isProverCall, ) = (call.target).call(
                abi.encodeWithSignature(
                    "supportsInterface(bytes4)",
                    IPROVER_INTERFACE_ID
                )
            );
            if (isProverCall) {
                // call to prover
                revert CallToProver();
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
        return (results, remainingValue);
    }
    
    /**
     * @notice Helper function to dispatch messages to the mailbox
     * @dev Extracts the dispatch logic to reduce stack depth in calling functions
     * @param _sourceChainId Chain ID of the source chain
     * @param _prover32 Prover address as bytes32
     * @param _messageBody Message body to dispatch
     * @param _metadata Metadata for postDispatchHook
     * @param _postDispatchHook Address of postDispatchHook
     * @param _fee Fee to be paid for the dispatch
     */
    function _dispatchMessage(
        uint32 _sourceChainId,
        bytes32 _prover32,
        bytes memory _messageBody,
        bytes memory _metadata,
        address _postDispatchHook,
        uint256 _fee
    ) internal {
        if (_postDispatchHook == address(0)) {
            IMailbox(mailbox).dispatch{value: _fee}(
                _sourceChainId,
                _prover32,
                _messageBody
            );
        } else {
            IMailbox(mailbox).dispatch{value: _fee}(
                _sourceChainId,
                _prover32,
                _messageBody,
                _metadata,
                IPostDispatchHook(_postDispatchHook)
            );
        }
    }

    receive() external payable {}
}
