// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IProver} from "./IProver.sol";
import {Route, Intent, Reward} from "../types/Intent.sol";

/**
 * @title ILocalProver
 * @notice Interface for LocalProver with flash-fulfill capability
 * @dev Extends IProver with flash-fulfill functionality for same-chain intents
 */
interface ILocalProver is IProver {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidClaimant();
    error InvalidIntentHash();
    error NativeTransferFailed();
    error InvalidSecondaryCreator();
    error MissingActualClaimant();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when an intent is flash-fulfilled
     * @param intentHash Hash of the fulfilled intent
     * @param claimant Address receiving the fulfillment reward
     * @param nativeFee Amount of native tokens paid to claimant (ERC20 tokens also transferred but not tracked here)
     */
    event FlashFulfilled(
        bytes32 indexed intentHash,
        bytes32 indexed claimant,
        uint256 nativeFee
    );

    /**
     * @notice Emitted when both original and secondary intents are refunded
     * @param originalIntentHash Hash of the original intent
     * @param secondaryIntentHash Hash of the secondary intent
     * @param originalVault Address of the original vault receiving refunds
     */
    event BothRefunded(
        bytes32 indexed originalIntentHash,
        bytes32 indexed secondaryIntentHash,
        address indexed originalVault
    );

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Atomically withdraws, fulfills an intent, and pays claimant the fulfillment reward
     * @dev Claimant receives all reward tokens and native (minus amounts consumed by route execution)
     * @param intentHash Hash of the intent to flash-fulfill
     * @param route Route information for the intent
     * @param reward Reward details for the intent
     * @param claimant Address that receives the fulfillment reward (ERC20 tokens + native ETH)
     * @return results Results from the fulfill execution
     */
    function flashFulfill(
        bytes32 intentHash,
        Route calldata route,
        Reward calldata reward,
        bytes32 claimant
    ) external payable returns (bytes[] memory results);

    /**
     * @notice Refunds both original and secondary intents in a single transaction
     * @dev Secondary intent must have LocalProver as creator for this to work
     * @param originalIntent Complete original intent struct
     * @param secondaryIntent Complete secondary intent struct
     */
    function refundBoth(
        Intent calldata originalIntent,
        Intent calldata secondaryIntent
    ) external;
}
