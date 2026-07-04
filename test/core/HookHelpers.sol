// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAccount} from "../../contracts/interfaces/IAccount.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice External recorder a delegate hook can call so a test can observe that the hook ran, and that
 *         it ran AS the intent's own Account (`lastCaller` == the account, because the hook is
 *         delegatecalled).
 */
contract HookBeacon {
    uint256 public rewardPings;
    uint256 public refundPings;
    address public lastCaller;

    function pingReward() external {
        rewardPings++;
        lastCaller = msg.sender;
    }

    function pingRefund() external {
        refundPings++;
        lastCaller = msg.sender;
    }
}

/**
 * @notice Logic contracts delegatecalled by the Account as the reward/refund hook. Under delegatecall
 *         these run in the Account's context (`address(this)` == the account), exactly like the route
 *         runtime.
 */
contract HookLogic {
    /// @dev Pings the beacon (observably runs as the account).
    function reward(address beacon) external {
        HookBeacon(beacon).pingReward();
    }

    function refund(address beacon) external {
        HookBeacon(beacon).pingRefund();
    }

    /// @dev A hook that always reverts.
    function boom() external pure {
        revert("hook boom");
    }

    /// @dev Attempts to reenter the Portal (e.g. settle/refund); reverts if that call reverts.
    function reenter(address portal, bytes calldata cd) external {
        (bool ok, ) = portal.call(cd);
        require(ok, "reenter reverted");
    }

    /// @dev Attempts to re-invoke the Account's own execute machinery (blocked by onlyPortal).
    function reinvokeExecute(bytes calldata hooks) external {
        IAccount(address(this)).runHook(hooks, 0);
    }

    /// @dev Attempts to move another intent's escrow (blocked: no allowance from the other account).
    function steal(
        address token,
        address from,
        address to,
        uint256 amount
    ) external {
        IERC20(token).transferFrom(from, to, amount);
    }
}
