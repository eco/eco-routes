// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMailbox, IPostDispatchHook} from "@hyperlane-xyz/core/contracts/interfaces/IMailbox.sol";
import {Eco7683DestinationSettler} from "./Eco7683DestinationSettler.sol";
import {TypeCasts} from "@hyperlane-xyz/core/contracts/libs/TypeCasts.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IInbox} from "./interfaces/IInbox.sol";
import {Intent, Route, Call, TokenAmount} from "./types/Intent.sol";
import {Semver} from "./libs/Semver.sol";

/**
 * @title Inbox
 * @notice Main entry point for fulfilling intents
 * @dev Validates intent hash authenticity and executes calldata. Enables provers
 * to claim rewards on the source chain by checking the fulfilled mapping
 */
contract Inbox is IInbox, Eco7683DestinationSettler, Ownable, Semver {
    using TypeCasts for address;
    using SafeERC20 for IERC20;

    // Mapping of intent hash on the src chain to its fulfillment
    mapping(bytes32 => address) public fulfilled;

    // Mapping of solvers to if they are whitelisted
    mapping(address => bool) public solverWhitelist;

    // address of local hyperlane mailbox
    address public mailbox;

    // Is solving public
    bool public isSolvingPublic;

    struct proveBatch {
        uint256 destinationChainID;
        bytes32[] intentHashes;
    }

    /**
     * @notice Initializes the Inbox contract
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
        for (uint256 i = 0; i < _solvers.length; ++i) {
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
        Route memory _route,
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
        Route memory _route,
        bytes32 _rewardHash,
        address _claimant,
        bytes32 _expectedHash,
        address _prover,
        bytes memory _metadata,
        address _postDispatchHook
    )
        public
        payable
        override(IInbox, Eco7683DestinationSettler)
        returns (bytes[] memory)
    {
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
        bytes[] memory results = _fulfill(
            _route,
            _rewardHash,
            _claimant,
            _expectedHash
        );

        uint256 currentBalance = address(this).balance;
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
        address[] memory claimants = new address[](size);
        for (uint256 i = 0; i < size; ++i) {
            address claimant = fulfilled[_intentHashes[i]];
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

    function fulfillSilent(
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

        return result;
    }

    /**
     * @notice Emits a batch of fulfilled intents and their claimants for cross-chain proving
     * @dev Packs intent hashes and claimant addresses into a single event to optimize gas
     * @param _destinationChainID The chain ID where the batch will be proven
     * @param _intentHashes Array of intent hashes that have been fulfilled
     * @custom:throws IntentNotFulfilled if any intent in the batch has not been fulfilled
     */
    //TODO change to proveBatch struct
    function batchStorageEmit(uint256 _destinationChainID, bytes32[] calldata _intentHashes) public {   
        uint256 size = _intentHashes.length;
        bytes memory claimants;

        for (uint256 i = 0; i < size; ++i) {
            address claimant = fulfilled[_intentHashes[i]];
            if (claimant == address(0)) {
                revert IntentNotFulfilled(_intentHashes[i]);
            }
            claimants = abi.encodePacked(claimants, claimant);
        }
        //pack the intent hashes into a single event using abi.encodePacked
        bytes memory messageBody = abi.encodePacked(_intentHashes, claimants);
        emit BatchToBeProven(_destinationChainID, messageBody);
    }
    
    /**
     * @notice Emits a batch of fulfilled intents and their claimants for multiple chains
     * @dev Packs intent hashes and claimant addresses into a single event for each destination chain
     * @param _proveBatches Array of proveBatch structs containing destination chain ID and intent hashes
     * @custom:throws SizeMismatch if the number of destination chain IDs and intent hashes arrays do not match
     */
    function multichainBatchStorageEmit(proveBatch[] calldata _proveBatches) public {
        uint256 size = _proveBatches.length;

        for (uint256 i = 0; i < size; ++i) {
            batchStorageEmit(_proveBatches[i].destinationChainID, _proveBatches[i].intentHashes);
        }
    }  

    // this function is used to construct the packed message efficently. it packs the intent hashes and claimants into a single bytes
    // object. It does this very lazily, meaning that it will keep packing for a given claimant until the claimant changes. 
    // This is done to save processing gas, but requires that the caller of this function sorts the intent hashes by claimant. 
    // if they fail to do so, the function will end up including the same claimant multiple times in the packed message.
    // The alternative to this would be lots of really inefficient loops that scale poorly with the number of intent hashes.

    // _claimAndBatch is a boolean that tells the prover if it should just claim the intents instead of marking them as proven, 
    // which skips the intermediate step of saving the intent hashes in storage to the prover. I might take this out because I want to reuse this
    // method for both hyperlane and polymer -- and hyperlane needs all the claim calldata here if we're going to claim 🧐🧐🧐🧐🧐🧐

    // eventually we can construct the message in assembly to save gas
    function constructPackedMessage(bytes32[] calldata _intentHashes, bool _batchThenClaim) public view returns (bytes memory) {
        // check that the number of intent hashes is less than 65536
        // we might not need to check that _intentHashes fits in uint16 because calldata is limited
        // and you can't post 2.09mb in a transaction? 
        require(_intentHashes.length < 65536, "IntentHashArrayTooLong");
        uint16 size = uint16(_intentHashes.length);
        bytes memory message;

        // load the first intent hash and check if it has been fulfilled
        uint16 startIndex = 0;
        address currentClaimant = fulfilled[_intentHashes[0]];
        if (currentClaimant == address(0)) {
            revert IntentNotFulfilled(_intentHashes[0]);
        }

        for (uint16 i = 1; i < size; ++i) {
            address loopClaimant = fulfilled[_intentHashes[i]];
            if (loopClaimant == address(0)) {
                revert IntentNotFulfilled(_intentHashes[i]);
            }
            if (loopClaimant != currentClaimant) {
                uint16 chunkSize = i - startIndex;
                // Combine these operations to reduce memory allocations
                message = abi.encodePacked(
                    message, 
                    chunkSize, 
                    currentClaimant,
                    _intentHashes[startIndex:i]
                );
                startIndex = i;
                currentClaimant = loopClaimant;
            }
        }
        
        // Add the last chunk directly to the message with the flag
        return abi.encodePacked(
            _batchThenClaim,
            message,
            size - startIndex,  // Final chunk size
            currentClaimant,
            _intentHashes[startIndex:size]
        );
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
        Route memory _route,
        bytes32 _rewardHash,
        address _claimant,
        bytes32 _expectedHash
    ) internal returns (bytes[] memory) {
        if (_route.destination != block.chainid) {
            revert WrongChain(_route.destination);
        }

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
