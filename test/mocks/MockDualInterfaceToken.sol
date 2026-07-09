// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Vm} from "forge-std/Vm.sol";

/**
 * @title MockDualInterfaceToken
 * @notice A test-only ERC20 whose token balance IS the account's native balance — the
 *         defining property of a chain like Arc, where the native asset is double-counted
 *         as an ERC20 (USDC). The ERC20 interface and native balance are two views of ONE
 *         underlying number, not independent balances.
 *
 * @dev Why this exists: a normal mock ERC20 keeps its own `_balances` mapping that has nothing
 *      to do with `account.balance`. Recovering/withdrawing such a mock moves *bookkeeping
 *      tokens*, so it can only ever prove that a guard "reverts on declaration" — it can never
 *      prove that, absent the guard, a native reward actually walks out through the ERC20 door.
 *      This token closes that gap by making the two interfaces share one balance:
 *
 *        - `balanceOf(a)` returns `a.balance` (the native balance itself).
 *        - `transfer` / `transferFrom` move native to mirror the ERC20 move.
 *
 *      A contract cannot debit an arbitrary account's native ETH on its own, so the move is
 *      done with the `vm.deal` cheatcode. `vm.deal` SETS an absolute balance (it is not
 *      additive), so `_move` reads the current balance and writes the intended new one.
 *
 *      Faithfulness: because both interfaces read and write the same `account.balance`, a real
 *      production native payout (`payable(x).call{value: amt}`) and a cheatcode-driven ERC20
 *      transfer genuinely contend over one balance — reproducing the Arc double-count.
 *
 *      Modeling choices (not verified properties of Arc):
 *      - Amounts are treated as native-denominated 1:1. A real Arc USDC presents 6 decimals over
 *        an 18-decimal native asset (a ~1e12 scale factor); this mock omits that scaling because
 *        the guard under test is amount-independent, so it does not affect any assertion here.
 *      - Crediting via `vm.deal` does not run the recipient's `receive()`, modeling an ERC20
 *        credit as a pure balance write rather than a native value transfer. Every payout
 *        recipient in the suite is an EOA, so this choice is not load-bearing.
 *
 *      Limitations (by construction): Forge-only (uses cheatcodes); `vm.deal` can mint/burn
 *      native, so conservation is enforced by hand in `_move` (debit then credit equal amounts).
 */
contract MockDualInterfaceToken {
    // solhint-disable-next-line max-line-length
    Vm private constant vm =
        Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    string public name;
    string public symbol;
    uint8 public constant decimals = 6; // USDC-like

    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );

    error InsufficientBalance(address from, uint256 balance, uint256 needed);
    error InsufficientAllowance(
        address owner,
        address spender,
        uint256 allowance,
        uint256 needed
    );

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    /// @notice The ERC20 balance IS the native balance — one underlying number, two views.
    function balanceOf(address account) public view returns (uint256) {
        return account.balance;
    }

    /// @dev Not a meaningful quantity for a native-aliased token; total native supply is not
    ///      knowable from a contract. Returned only to complete the ERC20 surface.
    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _move(msg.sender, to, value);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < value) {
                revert InsufficientAllowance(from, msg.sender, allowed, value);
            }
            allowance[from][msg.sender] = allowed - value;
        }
        _move(from, to, value);
        return true;
    }

    /// @dev Moves `value` of native from `from` to `to` to mirror the ERC20 transfer. `vm.deal`
    ///      sets an absolute balance, so compute each side's new balance by hand. The balance
    ///      check mimics an ERC20 insufficient-balance revert.
    function _move(address from, address to, uint256 value) internal {
        uint256 fromBal = from.balance;
        if (fromBal < value) {
            revert InsufficientBalance(from, fromBal, value);
        }
        vm.deal(from, fromBal - value);
        vm.deal(to, to.balance + value);
        emit Transfer(from, to, value);
    }
}
