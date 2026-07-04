// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WAD} from "../types/Intent.sol";

/**
 * @title RewardMath
 * @notice Pure helpers for v3's dynamic reward formula (rate+flat legs).
 * @dev The reward owed for a leg is `fulfilled * rate / WAD + flat`, then capped at the vault balance
 *      available for that token. Splitting the formula ({reward}) from the cap ({capped}) lets settlement
 *      compute the owed amount and then clamp it to escrow without ever paying out more than was
 *      deposited (money-conservation invariant; also the L1 lesson: advance any ledger by PAID not
 *      entitled).
 */
library RewardMath {
    /**
     * @notice Compute the (uncapped) reward for one leg.
     * @dev `Math.mulDiv(fulfilled, rate, WAD) + flat`. {Math.mulDiv} carries the `fulfilled * rate`
     *      product at 512-bit precision and only overflows when the true result exceeds `2**256 - 1`;
     *      the trailing `+ flat` reverts on overflow via checked arithmetic. The rate term rounds down,
     *      which never favors the claimant over the escrow.
     * @param fulfilled Destination amount actually delivered for this leg.
     * @param rate Fixed-point (WAD) reward multiplier.
     * @param flat Flat reward added on top of the rate-scaled term.
     * @return The uncapped reward amount.
     */
    function reward(
        uint256 fulfilled,
        uint256 rate,
        uint256 flat
    ) internal pure returns (uint256) {
        return Math.mulDiv(fulfilled, rate, WAD) + flat;
    }

    /**
     * @notice Clamp an owed amount to the funds actually available.
     * @dev Returns `min(amount, vaultBalance)`. Used so a leg never pays more than the vault holds for
     *      that token; the unpaid difference (if any) flows to the creator as the remainder.
     * @param amount The owed (uncapped) amount.
     * @param vaultBalance The vault balance available for this token.
     * @return The amount to pay, never exceeding `vaultBalance`.
     */
    function capped(
        uint256 amount,
        uint256 vaultBalance
    ) internal pure returns (uint256) {
        return Math.min(amount, vaultBalance);
    }
}
