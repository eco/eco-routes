/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Simple test USDC token with 6 decimals and 1,000,000 initial supply to deployer
contract TestUSDC is ERC20 {
    uint8 private immutable DECIMALS_OVERRIDE;

    constructor()
        ERC20("Fake USD Coin", "USDC")
    {
    DECIMALS_OVERRIDE = 6;
    // 1,000,000 USDC with 6 decimals
    _mint(msg.sender, 1_000_000 * 10 ** uint256(DECIMALS_OVERRIDE));
    }

    function decimals() public view virtual override returns (uint8) {
        return DECIMALS_OVERRIDE;
    }

    // helper for tests
    function mint(address recipient, uint256 amount) public {
        _mint(recipient, amount);
    }

    function transferPayable(
        address recipient,
        uint256 amount
    ) public payable returns (bool) {
        return transfer(recipient, amount);
    }
}
