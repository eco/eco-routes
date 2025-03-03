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

    mapping(address => uint256) public tokenThresholds;
    // is there an advantage to combining these? probably not since accesses are pretty independent
    mapping(address => WithdrawalQueueEntry[]) public withdrawalQueues;

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
        // Initialize with a predefined list of tokens
        for (uint256 i = 0; i < _initialTokens.length; ++i) {
            TokenAmount memory token = _initialTokens[i];
            require(token.amount > 0, InvalidAmount());
            require(token.token != address(0), InvalidToken());
            require(tokenThresholds[token.token] == 0, InvalidToken());

            allowedTokens.push(token.token);
            tokenThresholds[token.token] = token.amount;
            emit TokenThresholdChanged(token.token, token.amount);
        }
    }

    //_newWhitelist should be sorted
    function updateWhitelist(TokenAmount[] calldata _newWhitelist) external onlyOwner {
        TokenAmount memory entry = _newWhitelist[0];
        address curr = entry.token;
        tokenThresholds[curr] = _newWhitelist[0].amount;
        for (uint256 i = 1; i < _newWhitelist.length; ++i) {
            require(_newWhitelist[i].token > curr, "whitelist not sorted");
        }
        tokensHash = keccak256(_newWhitelist);
    }

    // Owner can update allowed tokens
    function updateThreshold(
        address _token,
        uint256 _threshold
    ) external onlyOwner {
        if (tokenThresholds[_token] == 0) {
            //add new token
            require(_threshold > 0, InvalidAmount());
            allowedTokens.push(_token);
            tokenThresholds[_token] = _threshold;
            emit TokenThresholdChanged(_token, _threshold);
        } else if (_threshold == 0) {
            //remove existing token
            tokenThresholds[_token] = 0;
            _swapAndPopWhitelist(_token);
            emit TokenThresholdChanged(_token, 0);
        } else {
            //update threshold
            tokenThresholds[_token] = _threshold;
            emit TokenThresholdChanged(_token, _threshold);
        }
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
            WithdrawalQueueEntry memory entry = WithdrawalQueueEntry(
                msg.sender,
                uint96(_amount)
            );
            withdrawalQueues[_preferredToken].push(entry);
            emit AddedToWithdrawalQueue(_preferredToken, entry);
        }
        IEcoDollar(REBASE_TOKEN).burn(msg.sender, _amount);
    }

    // Check pool balance of a user
    // Reflects most recent rebalance
    function getBalance(address user) external view returns (uint256) {
        return IERC20(REBASE_TOKEN).balanceOf(user);
    }

    // to be restricted
    // assumes that intent fees are sent directly to the pool address
    function broadcastYieldInfo(address[] calldata _tokens) external onlyOwner {
        require(keccak(_tokens) == tokensHash, InvalidTokens());
        uint256 localTokens = 0;
        uint256 length = allowedTokens.length;
        for (uint256 i = 0; i < length; ++i) {
            localTokens += IERC20(allowedTokens[i]).balanceOf(address(this));
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

    function _swapAndPopWhitelist(address _tokenToRemove) internal {
        uint256 length = allowedTokens.length;
        for (uint256 i = 0; i < length; ++i) {
            if (allowedTokens[i] == _tokenToRemove) {
                allowedTokens[i] = allowedTokens[length - 1];
                allowedTokens.pop();
                break;
            }
        }
    }
}
