// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMailbox} from "@hyperlane-xyz/core/contracts/interfaces/IMailbox.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IStablePool} from "./interfaces/IStablePool.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EcoDollar} from "./EcoDollar.sol";
import {IEcoDollar} from "./interfaces/IEcoDollar.sol";
import {IInbox} from "./interfaces/IInbox.sol";
import {Route, TokenAmount} from "./types/Intent.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract StablePool is IStablePool, Ownable {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    address public immutable LIT_AGENT;

    address public immutable INBOX;

    address public immutable REBASE_TOKEN;

    address public immutable MAILBOX;

    bool public litPaused;

    bytes32 public tokensHash;

    address[] public allowedTokens;

    uint256 public queueCounter;

    mapping(address => uint256) public tokenThresholds;
    // is there an advantage to combining these? probably not since accesses are pretty independent
    // mapping(address => WithdrawalQueueEntry[]) public withdrawalQueues;

    mapping(bytes32 => WithdrawalQueueEntry) public withdrawalQueue;

    modifier checkTokenList(address[] memory tokenList) {
        require(
            keccak256(abi.encode(tokenList)) == tokensHash,
            InvalidTokensHash(tokensHash)
        );
        _;
    }

    constructor(
        address _owner,
        address _litAgent,
        address _inbox,
        address _rebaseToken,
        address _mailbox,
        TokenAmount[] memory _initialTokens
    ) Ownable(_owner) {
        LIT_AGENT = _litAgent;
        INBOX = _inbox;
        REBASE_TOKEN = _rebaseToken;
        MAILBOX = _mailbox;
        address[] memory init;
        _addTokens(init, _initialTokens);
    }

    function delistTokens(
        address[] calldata _oldTokens,
        address[] calldata _toDelist
    ) external onlyOwner checkTokenList(_oldTokens) {
        uint256 oldLength = _oldTokens.length;
        uint256 delistLength = _toDelist.length;
        address[] memory newTokens = new address[](oldLength - delistLength);

        for (uint256 i = 0; i < delistLength; ++i) {
            tokenThresholds[_toDelist[i]] = 0;
        }
        //could just check if the address has a nonzero threshold
        //but i think this is cheaper than the corresponding storage reads
        uint256 counter = 0;
        for (uint256 i = 0; i < oldLength; ++i) {
            bool remains = true;
            for (uint256 j = 0; j < delistLength; ++j) {
                if (_oldTokens[i] == _toDelist[j]) {
                    remains = false;
                    break;
                }
            }
            if (remains) {
                newTokens[counter] = _oldTokens[i];
                ++counter;
            }
        }
        tokensHash = keccak256(abi.encode(newTokens));
        emit WhitelistUpdated(newTokens);
    }

    function addTokens(
        address[] calldata _oldTokens,
        TokenAmount[] calldata _whitelistChanges
    ) external onlyOwner checkTokenList(_oldTokens) {
        _addTokens(_oldTokens, _whitelistChanges);
    }

    function updateThresholds(
        address[] memory _oldTokens,
        TokenAmount[] memory _thresholdChanges
    ) internal {
        uint256 oldLength = _oldTokens.length;
        uint256 changesLength = _thresholdChanges.length;

        for (uint256 i = 0; i < changesLength; ++i) {
            TokenAmount memory currChange = _thresholdChanges[i];
            require(currChange.amount != 0, "remove using delistTokens");
            bool whitelisted = false;
            for (uint256 j = 0; j < oldLength; ++j) {
                if (currChange.token == _oldTokens[j]) {
                    tokenThresholds[currChange.token] = currChange.amount;
                    whitelisted = true;
                    break;
                }
            }
            require(whitelisted, "add using addTokens");
        }
        emit TokenThresholdsChanged(_thresholdChanges);
    }

    function _addTokens(
        address[] memory _oldTokens,
        TokenAmount[] memory _tokensToAdd
    ) internal {
        uint256 oldLength = _oldTokens.length;
        uint256 addLength = _tokensToAdd.length;

        address[] memory newTokens = new address[](oldLength + addLength);

        uint256 i = 0;
        for (i = 0; i < oldLength; ++i) {
            address curr = _oldTokens[i];
            for (uint256 j = 0; j < addLength; ++j) {
                require(
                    curr != _tokensToAdd[j].token,
                    "update using updateThresholds"
                );
            }
            newTokens[i] = curr;
        }
        for (uint256 j = 0; j < addLength; ++j) {
            newTokens[i] = _tokensToAdd[j].token;
            ++i;
        }
        tokensHash = keccak256(abi.encode(newTokens));
        emit WhitelistUpdated(newTokens);
        emit TokenThresholdsChanged(_tokensToAdd);
    }

    // Deposit function
    function deposit(address _token, uint256 _amount) external {
        _deposit(_token, _amount);
        EcoDollar(REBASE_TOKEN).mint(LIT_AGENT, _amount);
        emit Deposited(msg.sender, _token, _amount);
    }

    function _deposit(address _token, uint256 _amount) internal {
        require(tokenThresholds[_token] > 0, InvalidToken());
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
    }

    /**
     * @dev Withdraw `_amount` of `_preferredToken` from the pool
     * @param _preferredToken The token to withdraw
     * @param _amount The amount to withdraw
     */
    function withdraw(address _preferredToken, uint256 _amount) external {
        uint256 tokenBalance = IERC20(REBASE_TOKEN).balanceOf(msg.sender);

        require(
            tokenBalance >= _amount,
            InsufficientTokenBalance(
                _preferredToken,
                tokenBalance,
                _amount - tokenBalance
            )
        );

        IEcoDollar(REBASE_TOKEN).burn(msg.sender, _amount);

        if (tokenBalance > tokenThresholds[_preferredToken]) {
            IERC20(_preferredToken).safeTransfer(msg.sender, _amount);
            emit Withdrawn(msg.sender, _preferredToken, _amount);
        } else {
            // need to rebase, add to withdrawal queue
            _addToWithdrawalQueue(_preferredToken, msg.sender, _amount);
            emit AddedToWithdrawalQueue(_preferredToken, entry);
        }
        IEcoDollar(REBASE_TOKEN).burn(msg.sender, _amount);
    }

    function _addToWithdrawalQueue(
        address _token,
        address _withdrawer,
        uint80 _amount
    ) internal {
        bytes32 headKey = keccak256(_token);
        WithdrawalQueueEntry memory entry = WithdrawalQueueEntry(
            _withdrawer,
            _amount,
            0, //head, but i dont need to store it
            withdrawlQueues[headKey].prevNode // last node of the queue
        );
        withdrawalQueue[queueCounter] = entry;
        withdrawalQueues[headKey].prevNode = queueCounter;
        ++queueCounter
    }

    // Check pool balance of a user
    // Reflects most recent rebalance
    function getBalance(address user) external view returns (uint256) {
        return IERC20(REBASE_TOKEN).balanceOf(user);
    }

    // to be restricted
    // assumes that intent fees are sent directly to the pool address
    function broadcastYieldInfo(
        address[] calldata _tokens
    ) external onlyOwner checkTokenList(_tokens) {
        uint256 localTokens = 0;
        uint256 length = allowedTokens.length;
        for (uint256 i = 0; i < length; ++i) {
            localTokens += IERC20(_tokens[i]).balanceOf(address(this));
        }
        uint256 localShares = EcoDollar(REBASE_TOKEN).totalShares();

        // TODO: hyperlane broadcasting
    }

    function pauseLit() external onlyOwner {
        litPaused = true;
    }

    function unpauseLit() external onlyOwner {
        litPaused = false;
    }

    // signature implies that the intent exists and is funded
    // msg.value is the tip to the caller of sendBatch
    function accessLiquidity(
        Route calldata _route,
        bytes32 _rewardHash,
        bytes32 _intentHash,
        address _prover,
        bytes calldata _litSignature
    ) external payable {
        require(msg.sender == INBOX, InvalidCaller(msg.sender, INBOX));
        require(!litPaused, LitPaused());
        require(
            LIT_AGENT == _intentHash.recover(_litSignature),
            InvalidSignature(_intentHash, _litSignature)
        );

        IInbox(INBOX).fulfillHyperBatched{value: msg.value}(
            _route,
            _rewardHash,
            address(this),
            _intentHash,
            _prover
        );
    }

    function processWithdrawalQueue(address token) external onlyOwner {
        uint256 queueLength = withdrawalQueues[token].length;
        // investigate risk of griefing someone by constantly queueing withdrawals that will push the pool below threshold
        // going through queue backwards to avoid writes
        // can swap and pop if we cannot mitigate
        for (uint256 i = queueLength; i > 0; --i) {
            WithdrawalQueueEntry storage entry = withdrawalQueues[token][i];
            IERC20 stable = IERC20(token);
            if (stable.balanceOf(address(this)) > tokenThresholds[token]) {
                stable.safeTransfer(entry.user, entry.amount);
                withdrawalQueues[token].pop();
            } else {
                // dip below threshold during withdrawal queue processing
                emit WithdrawalQueueThresholdReached(token);
                break;
            }
        }
        // swap and pop

        // for (uint256 i = 0; i < queueLength; --i) {
        //     WithdrawalQueueEntry storage entry = withdrawalQueues[token][i];
        //     IERC20 stable = IERC20(token);
        //     if (stable.balanceOf(address(this)) > tokenThresholds[token]) {
        //         stable.safeTransfer(entry.user, entry.amount);
        //         allowedTokens[i] = allowedTokens[queueLength - 1];
        //         withdrawalQueues[token].pop();
        //     } else {
        //         // dip below threshold during withdrawal queue processing
        //         emit WithdrawalQueueThresholdReached(token);
        //         break;
        //     }
        // }
    }
}
