// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {
    Intent,
    Route,
    Reward,
    TokenAmount,
    RewardToken,
    IntentLib
} from "../../../contracts/types/Intent.sol";
import {Hook} from "../../../contracts/types/Intent.sol";

/**
 * @title GoldenVectorTest
 * @notice Emits the routeHash / rewardHash / intentHash of a FIXED intent so the TS SDK's Jest golden
 *         vector (src/__tests__/hashing.test.ts) can assert byte-identical parity with Solidity.
 * @dev Run: forge test --match-path test/v3/sdk/GoldenVector.t.sol -vv
 */
contract GoldenVectorTest is Test {
    function _fixedIntent() internal pure returns (Intent memory intent) {
        TokenAmount[] memory minTokens = new TokenAmount[](1);
        minTokens[0] = TokenAmount({
            token: address(0x1111111111111111111111111111111111111111),
            amount: 1_000_000
        });

        Route memory route = Route({
            salt: bytes32(uint256(0xABCD)),
            deadline: 1_700_000_000,
            portal: address(0x2222222222222222222222222222222222222222),
            keeper: address(0x3333333333333333333333333333333333333333),
            runtime: address(0x4444444444444444444444444444444444444444),
            payload: hex"deadbeef",
            minTokens: minTokens
        });

        RewardToken[] memory tokens = new RewardToken[](1);
        tokens[0] = RewardToken({
            token: address(0x5555555555555555555555555555555555555555),
            rate: 2_000_000_000_000_000_000, // 2 WAD
            flat: 500
        });

        Hook[2] memory hooks;
        hooks[0] = Hook({
            target: address(0x6666666666666666666666666666666666666666),
            data: hex"c0ffee"
        });
        hooks[1] = Hook({target: address(0), data: hex""});

        Reward memory reward = Reward({
            deadline: 1_700_000_500,
            keeper: address(0x7777777777777777777777777777777777777777),
            prover: address(0x8888888888888888888888888888888888888888),
            tokens: tokens,
            hooks: abi.encode(hooks)
        });

        intent = Intent({
            protocolVersion: 1,
            source: 8453,
            destination: 10,
            route: route,
            reward: reward
        });
    }

    function test_emitGoldenVector() public pure {
        Intent memory intent = _fixedIntent();
        bytes32 routeHash = keccak256(abi.encode(intent.route));
        bytes32 rewardHash = keccak256(abi.encode(intent.reward));
        bytes32 intentHash = IntentLib.hashIntent(
            intent.protocolVersion,
            intent.source,
            intent.destination,
            routeHash,
            rewardHash
        );

        console.log("routeHash:");
        console.logBytes32(routeHash);
        console.log("rewardHash:");
        console.logBytes32(rewardHash);
        console.log("intentHash:");
        console.logBytes32(intentHash);
    }
}
