// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BaseTest} from "../BaseTest.sol";
import {UniversalSource} from "../../contracts/source/UniversalSource.sol";
import {IUniversalIntentSource} from "../../contracts/interfaces/IUniversalIntentSource.sol";
import {IBaseSource} from "../../contracts/interfaces/IBaseSource.sol";
import {Intent as UniversalIntent, Route as UniversalRoute, Reward as UniversalReward, TokenAmount as UniversalTokenAmount, Call as UniversalCall} from "../../contracts/types/UniversalIntent.sol";
import {Intent as EVMIntent, Route as EVMRoute, Reward as EVMReward, TokenAmount as EVMTokenAmount, Call as EVMCall} from "../../contracts/types/Intent.sol";
import {AddressConverter} from "../../contracts/libs/AddressConverter.sol";

contract UniversalSourceTest is BaseTest {
    using AddressConverter for address;
    using AddressConverter for bytes32;

    UniversalSource internal universalSource;

    // Universal test data
    UniversalIntent internal universalIntent;
    UniversalRoute internal universalRoute;
    UniversalReward internal universalReward;
    UniversalTokenAmount[] internal universalRouteTokens;
    UniversalCall[] internal universalCalls;
    UniversalTokenAmount[] internal universalRewardTokens;

    function setUp() public override {
        super.setUp();

        // Use intentSource which inherits from both UniversalSource and EvmSource
        universalSource = UniversalSource(address(intentSource));

        _mintAndApprove(creator, MINT_AMOUNT * 4);
        _fundUserNative(creator, 10 ether);

        // Also approve tokens to the universalSource contract
        vm.startPrank(creator);
        tokenA.approve(address(universalSource), MINT_AMOUNT * 4);
        tokenB.approve(address(universalSource), MINT_AMOUNT * 8);
        vm.stopPrank();

        _setupUniversalTestData();
    }

    function _setupUniversalTestData() internal {
        // Setup universal route tokens
        universalRouteTokens.push(
            UniversalTokenAmount({
                token: address(tokenA).toBytes32(),
                amount: MINT_AMOUNT
            })
        );

        // Setup universal calls
        universalCalls.push(
            UniversalCall({
                target: address(tokenA).toBytes32(),
                data: abi.encodeWithSignature(
                    "transfer(address,uint256)",
                    creator,
                    MINT_AMOUNT
                ),
                value: 0
            })
        );

        // Setup universal reward tokens
        universalRewardTokens.push(
            UniversalTokenAmount({
                token: address(tokenA).toBytes32(),
                amount: MINT_AMOUNT
            })
        );
        universalRewardTokens.push(
            UniversalTokenAmount({
                token: address(tokenB).toBytes32(),
                amount: MINT_AMOUNT * 2
            })
        );

        // Create memory copies of arrays for struct assignment
        UniversalTokenAmount[]
            memory universalRouteTokensMemory = new UniversalTokenAmount[](
                universalRouteTokens.length
            );
        for (uint256 i = 0; i < universalRouteTokens.length; i++) {
            universalRouteTokensMemory[i] = universalRouteTokens[i];
        }

        UniversalCall[] memory universalCallsMemory = new UniversalCall[](
            universalCalls.length
        );
        for (uint256 i = 0; i < universalCalls.length; i++) {
            universalCallsMemory[i] = universalCalls[i];
        }

        UniversalTokenAmount[]
            memory universalRewardTokensMemory = new UniversalTokenAmount[](
                universalRewardTokens.length
            );
        for (uint256 i = 0; i < universalRewardTokens.length; i++) {
            universalRewardTokensMemory[i] = universalRewardTokens[i];
        }

        // Setup universal route
        universalRoute = UniversalRoute({
            salt: salt,
            source: block.chainid,
            destination: CHAIN_ID,
            inbox: address(inbox).toBytes32(),
            tokens: universalRouteTokensMemory,
            calls: universalCallsMemory
        });

        // Setup universal reward
        universalReward = UniversalReward({
            creator: creator.toBytes32(),
            prover: address(prover).toBytes32(),
            deadline: expiry,
            nativeValue: 0,
            tokens: universalRewardTokensMemory
        });

        // Setup universal intent
        universalIntent = UniversalIntent({
            route: universalRoute,
            reward: universalReward
        });
    }

    function _convertToEVMIntent(
        UniversalIntent memory _universalIntent
    ) internal pure returns (EVMIntent memory) {
        // Convert route tokens
        EVMTokenAmount[] memory evmRouteTokens = new EVMTokenAmount[](
            _universalIntent.route.tokens.length
        );
        for (uint256 i = 0; i < _universalIntent.route.tokens.length; i++) {
            evmRouteTokens[i] = EVMTokenAmount({
                token: _universalIntent.route.tokens[i].token.toAddress(),
                amount: _universalIntent.route.tokens[i].amount
            });
        }

        // Convert calls
        EVMCall[] memory evmCalls = new EVMCall[](
            _universalIntent.route.calls.length
        );
        for (uint256 i = 0; i < _universalIntent.route.calls.length; i++) {
            evmCalls[i] = EVMCall({
                target: _universalIntent.route.calls[i].target.toAddress(),
                data: _universalIntent.route.calls[i].data,
                value: _universalIntent.route.calls[i].value
            });
        }

        // Convert reward tokens
        EVMTokenAmount[] memory evmRewardTokens = new EVMTokenAmount[](
            _universalIntent.reward.tokens.length
        );
        for (uint256 i = 0; i < _universalIntent.reward.tokens.length; i++) {
            evmRewardTokens[i] = EVMTokenAmount({
                token: _universalIntent.reward.tokens[i].token.toAddress(),
                amount: _universalIntent.reward.tokens[i].amount
            });
        }

        return
            EVMIntent({
                route: EVMRoute({
                    salt: _universalIntent.route.salt,
                    source: _universalIntent.route.source,
                    destination: _universalIntent.route.destination,
                    inbox: _universalIntent.route.inbox.toAddress(),
                    tokens: evmRouteTokens,
                    calls: evmCalls
                }),
                reward: EVMReward({
                    creator: _universalIntent.reward.creator.toAddress(),
                    prover: _universalIntent.reward.prover.toAddress(),
                    deadline: _universalIntent.reward.deadline,
                    nativeValue: _universalIntent.reward.nativeValue,
                    tokens: evmRewardTokens
                })
            });
    }

    function testUniversalIntentHashing() public {
        (bytes32 universalHash, , ) = universalSource.getIntentHash(
            universalIntent
        );

        EVMIntent memory evmIntent = _convertToEVMIntent(universalIntent);
        (bytes32 evmHash, , ) = intentSource.getIntentHash(evmIntent);

        // Universal and EVM intents should produce the same hash
        assertEq(universalHash, evmHash);
    }

    function testUniversalIntentVaultAddress() public {
        address universalVault = universalSource.intentVaultAddress(
            universalIntent
        );

        EVMIntent memory evmIntent = _convertToEVMIntent(universalIntent);
        address evmVault = intentSource.intentVaultAddress(evmIntent);

        // Universal and EVM intents should produce the same vault address
        assertEq(universalVault, evmVault);
    }

    function testPublishUniversalIntent() public {
        vm.prank(creator);
        universalSource.publish(universalIntent);

        // Verify intent was published (we can check by trying to fund it)
        bytes32 routeHash = keccak256(abi.encode(universalIntent.route));

        // Get vault address and approve tokens to it for fundFor to work
        address intentVault = universalSource.intentVaultAddress(
            universalIntent
        );

        vm.startPrank(creator);
        tokenA.approve(intentVault, MINT_AMOUNT);
        tokenB.approve(intentVault, MINT_AMOUNT * 2);

        universalSource.fundFor(
            routeHash,
            universalIntent.reward,
            creator,
            address(0),
            false
        );
        vm.stopPrank();

        assertTrue(universalSource.isIntentFunded(universalIntent));
    }

    function testPublishEmitsUniversalIntentCreatedEvent() public {
        (bytes32 intentHash, , ) = universalSource.getIntentHash(
            universalIntent
        );

        _expectEmit();
        emit IUniversalIntentSource.UniversalIntentCreated(
            intentHash,
            salt,
            block.chainid,
            CHAIN_ID,
            address(inbox).toBytes32(),
            universalRouteTokens,
            universalCalls,
            creator,
            address(prover),
            expiry,
            0,
            universalRewardTokens
        );

        vm.prank(creator);
        universalSource.publish(universalIntent);
    }

    function testFundUniversalIntent() public {
        vm.prank(creator);
        universalSource.publishAndFund(universalIntent, false);

        assertTrue(universalSource.isIntentFunded(universalIntent));
    }

    function testFundUniversalIntentWithNativeReward() public {
        universalReward.nativeValue = REWARD_NATIVE_ETH;
        universalIntent.reward = universalReward;

        vm.prank(creator);
        universalSource.publishAndFund{value: REWARD_NATIVE_ETH}(
            universalIntent,
            false
        );

        assertTrue(universalSource.isIntentFunded(universalIntent));

        address vaultAddress = universalSource.intentVaultAddress(
            universalIntent
        );
        assertEq(vaultAddress.balance, REWARD_NATIVE_ETH);
    }

    function testWithdrawUniversalRewards() public {
        vm.prank(creator);
        universalSource.publishAndFund(universalIntent, false);

        (bytes32 intentHash, , ) = universalSource.getIntentHash(
            universalIntent
        );

        vm.prank(creator);
        prover.addProvenIntent(intentHash, claimant);

        uint256 initialBalanceA = tokenA.balanceOf(claimant);
        uint256 initialBalanceB = tokenB.balanceOf(claimant);

        bytes32 routeHash = keccak256(abi.encode(universalIntent.route));
        vm.prank(otherPerson);
        universalSource.withdrawRewards(routeHash, universalIntent.reward);

        assertEq(tokenA.balanceOf(claimant), initialBalanceA + MINT_AMOUNT);
        assertEq(tokenB.balanceOf(claimant), initialBalanceB + MINT_AMOUNT * 2);
        assertFalse(universalSource.isIntentFunded(universalIntent));
    }

    function testRefundUniversalIntent() public {
        vm.prank(creator);
        universalSource.publishAndFund(universalIntent, false);

        _timeTravel(expiry + 1);

        uint256 initialBalanceA = tokenA.balanceOf(creator);
        uint256 initialBalanceB = tokenB.balanceOf(creator);

        bytes32 routeHash = keccak256(abi.encode(universalIntent.route));
        vm.prank(otherPerson);
        universalSource.refund(routeHash, universalIntent.reward);

        assertEq(tokenA.balanceOf(creator), initialBalanceA + MINT_AMOUNT);
        assertEq(tokenB.balanceOf(creator), initialBalanceB + MINT_AMOUNT * 2);
        assertFalse(universalSource.isIntentFunded(universalIntent));
    }

    function testConsistentHashingBetweenFormats() public {
        // Test that the same intent produces the same hash regardless of format
        EVMIntent memory evmIntent = _convertToEVMIntent(universalIntent);

        (bytes32 universalHash, , ) = universalSource.getIntentHash(
            universalIntent
        );
        (bytes32 evmHash, , ) = intentSource.getIntentHash(evmIntent);

        assertEq(universalHash, evmHash);
    }

    function testConsistentVaultAddressBetweenFormats() public {
        // Test that the same intent produces the same vault address regardless of format
        EVMIntent memory evmIntent = _convertToEVMIntent(universalIntent);

        address universalVault = universalSource.intentVaultAddress(
            universalIntent
        );
        address evmVault = intentSource.intentVaultAddress(evmIntent);

        assertEq(universalVault, evmVault);
    }

    function testInsufficientNativeRewardUniversal() public {
        universalReward.nativeValue = 1 ether;
        universalIntent.reward = universalReward;

        vm.expectRevert(
            abi.encodeWithSelector(
                IBaseSource.InsufficientNativeReward.selector,
                keccak256(
                    abi.encodePacked(
                        keccak256(abi.encode(universalIntent.route)),
                        keccak256(abi.encode(universalIntent.reward))
                    )
                )
            )
        );
        vm.prank(creator);
        universalSource.publishAndFund{value: 0.5 ether}(
            universalIntent,
            false
        );
    }

    function testWrongSourceChainUniversal() public {
        universalRoute.source = 12345;
        universalIntent.route = universalRoute;

        vm.expectRevert(
            abi.encodeWithSelector(
                IBaseSource.WrongSourceChain.selector,
                keccak256(
                    abi.encodePacked(
                        keccak256(abi.encode(universalIntent.route)),
                        keccak256(abi.encode(universalIntent.reward))
                    )
                )
            )
        );
        vm.prank(creator);
        universalSource.publishAndFund(universalIntent, false);
    }
}
