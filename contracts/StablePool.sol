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

    modifier checkTokenList(address[] calldata tokenList) {
        require(keccak256(abi.encode(tokenList)) == tokensHash, InvalidTokensHash(tokensHash));
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
        _updateThresholds(init, _initialTokens);
    }

    function delistTokens(
        address[] calldata _oldTokens,
        address[] memory _toDelist
    ) external onlyOwner checkTokenList(_oldTokens){
        address[] memory newTokenList;
        uint256 length = _toDelist.length;
        for (uint256 i = 0; i < length; ++i) {
            tokenThresholds[_toDelist[i]] = 0;
        }
        //could just check if the address has a nonzero threshold
        //but i think this is cheaper than the corresponding storage reads
        uint256 oldLength = _oldTokens.length;
        uint256 delistLength = _toDelist.length;
        for (uint256 i = 0; i < oldLength; ++i) {
            bool remains = true;
            for (uint256 j = 0; j < delistLength; ++j) {
                if (_oldTokens[i] == _toDelist[j]) {
                    remains = false;
                    break;
                }
            }
            if (remains) {
                newTokenList.push(_oldTokens[i]);
            }
        }
        tokensHash = keccak256(newTokenList);
        emit WhitelistUpdated(newTokenList);
    }

    function updateThresholds(
        address[] memory _oldTokens,
        TokenAmount[] calldata _whitelistChanges
    ) external onlyOwner {
        _updateThresholds(_oldTokens, _whitelistChanges);
    }

    function _updateThresholds(
        address[] memory _oldTokens,
        TokenAmount[] memory _whitelistChanges
    ) internal {
        require(
            keccak256(_oldTokens) == tokensHash,
            InvalidTokensHash(tokensHash)
        );
        address[] memory toAdd = [];
        uint256 oldLength = _oldTokens.length;
        uint256 changesLength = _whitelistChanges.length;
        //could just check if the address has a zero threshold
        //but i think this is cheaper than the corresponding storage reads
        for (uint256 i = 0; i < changesLength; ++i) {
            address currChange = _whitelistChanges[i];
            require(currChange.amount > 0, "remove using delistTokens");
            bool addNew = true;
            for (uint256 j = 0; j < oldLength; ++j) {
                if (currChange != _oldTokens[j]) {
                    addNew = false;
                    break;
                }
            }
            tokenThresholds[currChange.token] = currChange.amount;
            if (addNew) {
                toAdd.push(currChange.token);
            }
        }
        for (uint256 i = 0; i < toAdd.length; ++i) {
            _oldTokens.push(toAdd[i]);
        }
        if (_oldTokens.length > oldLength) {
            tokensHash = keccak256(_oldTokens);
            emit WhitelistUpdated(_oldTokens);
        }
        emit TokenThresholdsChanged(_whitelistChanges);
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
        require(
            keccak256(_tokens) == tokensHash,
            InvalidTokensHash(tokensHash)
        );
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
    function shrinkAddressArray(address[] memory _array) internal pure returns (address[] memory) {
        uint256 length = _array.length;
        address[] memory result;
        for (uint256 i = length; i > 0; --i) {
            if (_array[i] != address(0)) {
                result.push(_array[i]);
            }
        }
        return result;
    }
}
