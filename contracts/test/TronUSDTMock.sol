// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title TronUSDTMock
 * @notice Reproduces the StandardTokenWithFees.transfer() bug in the Tron USDT
 *         contract (TetherToken, compiled with solc 0.4.18).
 *
 *         In the original, `transfer()` is declared `returns (bool)` but has no
 *         explicit return statement — so solc 0.4.x emits implicit `false`.
 *         Tokens actually move; only the return value is wrong.
 *
 *         `transferFrom()` has an explicit `return true` and works correctly.
 *
 *         This asymmetry means:
 *           - safeTransferFrom (Vault._fundFrom / publishAndFund) succeeds ✓
 *           - safeTransfer     (Vault.withdraw)                    reverts
 *             with SafeERC20FailedOperation(token)                 ✗
 */
contract TronUSDTMock {
    string public name = "Tether USD";
    string public symbol = "USDT";
    uint8 public decimals = 6;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint256 _initialSupply) {
        totalSupply = _initialSupply;
        balanceOf[msg.sender] = _initialSupply;
    }

    /// @dev Tokens move but returns false — mirrors the 0.4.18 implicit-false bug.
    function transfer(address _to, uint256 _value) public returns (bool) {
        require(balanceOf[msg.sender] >= _value, "insufficient balance");
        balanceOf[msg.sender] -= _value;
        balanceOf[_to] += _value;
        return false; // reproduces missing `return` in solc 0.4.18
    }

    /// @dev Standard transferFrom with explicit true — matches real TetherToken.
    function transferFrom(address _from, address _to, uint256 _value) public returns (bool) {
        require(balanceOf[_from] >= _value, "insufficient balance");
        require(allowance[_from][msg.sender] >= _value, "allowance exceeded");
        balanceOf[_from] -= _value;
        balanceOf[_to] += _value;
        allowance[_from][msg.sender] -= _value;
        return true;
    }

    function approve(address _spender, uint256 _value) public returns (bool) {
        allowance[msg.sender][_spender] = _value;
        return true;
    }
}
