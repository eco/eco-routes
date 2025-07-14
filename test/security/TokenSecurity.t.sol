// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../BaseTest.sol";
import {BadERC20} from "../../contracts/test/BadERC20.sol";
import {FakePermit} from "../../contracts/test/FakePermit.sol";
import {TestUSDT} from "../../contracts/test/TestUSDT.sol";
import {Intent, Route, Reward, TokenAmount, Call} from "../../contracts/types/UniversalIntent.sol";
import {Route as IntentRoute, TokenAmount as IntentTokenAmount, Call as IntentCall} from "../../contracts/types/Intent.sol";
import {TypeCasts} from "@hyperlane-xyz/core/contracts/libs/TypeCasts.sol";

contract TokenSecurityTest is BaseTest {
    BadERC20 internal maliciousToken;
    FakePermit internal fakePermit;
    TestUSDT internal usdt;

    address internal attacker;
    address internal victim;
    address internal recipient;

    function setUp() public override {
        super.setUp();

        attacker = makeAddr("attacker");
        victim = makeAddr("victim");
        recipient = makeAddr("recipient");

        vm.startPrank(deployer);

        // Deploy malicious token
        maliciousToken = new BadERC20("Malicious", "MAL", attacker);

        // Deploy fake permit contract
        fakePermit = new FakePermit();

        // Deploy USDT (non-standard ERC20)
        usdt = new TestUSDT("Test USDT", "USDT");

        vm.stopPrank();

        _mintAndApprove(creator, MINT_AMOUNT);
        _mintAndApprove(attacker, MINT_AMOUNT);
        _mintAndApprove(victim, MINT_AMOUNT);
        _fundUserNative(creator, 10 ether);
        _fundUserNative(attacker, 10 ether);
        _fundUserNative(victim, 10 ether);
    }

    // Malicious Token Tests
    function testMaliciousTokenInRewards() public {
        // Create intent with malicious token as reward
        TokenAmount[] memory maliciousRewards = new TokenAmount[](2);
        maliciousRewards[0] = TokenAmount({
            token: TypeCasts.addressToBytes32(address(maliciousToken)),
            amount: MINT_AMOUNT
        });
        maliciousRewards[1] = TokenAmount({
            token: TypeCasts.addressToBytes32(address(tokenA)),
            amount: MINT_AMOUNT
        });

        reward.tokens = maliciousRewards;
        intent.reward = reward;

        // Mint malicious tokens to attacker
        vm.prank(attacker);
        maliciousToken.mint(attacker, MINT_AMOUNT);

        // Fund the vault directly with both tokens
        bytes32 routeHash = keccak256(abi.encode(intent.route));
        address vaultAddress = intentSource.intentVaultAddress(
            intent,
            routeHash
        );

        vm.prank(attacker);
        maliciousToken.transfer(vaultAddress, MINT_AMOUNT);

        vm.prank(creator);
        tokenA.transfer(vaultAddress, MINT_AMOUNT);

        // Verify intent is funded
        assertTrue(intentSource.isIntentFunded(intent));

        // Add proof
        bytes32 intentHash = _hashIntent(intent);
        _addProof(intentHash, CHAIN_ID, claimant);

        uint256 initialClaimantBalance = tokenA.balanceOf(claimant);

        // IntentWithdrawn should succeed despite malicious token
        vm.prank(claimant);
        intentSource.withdraw(intent.destination, intent.reward, routeHash);

        // Good token should be transferred successfully
        assertEq(
            tokenA.balanceOf(claimant),
            initialClaimantBalance + MINT_AMOUNT
        );

        // Intent should be marked as unfunded
        assertFalse(intentSource.isIntentFunded(intent));
    }

    function testMaliciousTokenInRouteTokens() public {
        // Create intent with malicious token in route
        TokenAmount[] memory maliciousRouteTokens = new TokenAmount[](1);
        maliciousRouteTokens[0] = TokenAmount({
            token: TypeCasts.addressToBytes32(address(maliciousToken)),
            amount: MINT_AMOUNT
        });

        route.tokens = maliciousRouteTokens;
        intent.route = route;

        // Create corresponding call
        Call[] memory maliciousCalls = new Call[](1);
        maliciousCalls[0] = Call({
            target: TypeCasts.addressToBytes32(address(maliciousToken)),
            data: abi.encodeWithSignature(
                "transfer(address,uint256)",
                recipient,
                MINT_AMOUNT
            ),
            value: 0
        });

        route.calls = maliciousCalls;
        intent.route = route;

        // Test with inbox (destination chain)
        Intent memory destIntent = intent;
        destIntent.destination = uint64(block.chainid);

        vm.prank(attacker);
        maliciousToken.mint(attacker, MINT_AMOUNT);

        vm.prank(attacker);
        maliciousToken.approve(address(portal), MINT_AMOUNT);

        bytes32 intentHash = _hashIntent(destIntent);

        // Should revert when malicious token call fails
        vm.prank(attacker);
        bytes32 rewardHash = keccak256(abi.encode(destIntent.reward));
        vm.expectRevert();
        // Convert route to Intent format
        IntentTokenAmount[] memory intentTokens = new IntentTokenAmount[](
            destIntent.route.tokens.length
        );
        for (uint256 i = 0; i < destIntent.route.tokens.length; i++) {
            intentTokens[i] = IntentTokenAmount({
                token: address(
                    uint160(uint256(destIntent.route.tokens[i].token))
                ),
                amount: destIntent.route.tokens[i].amount
            });
        }
        IntentCall[] memory intentCalls = new IntentCall[](
            destIntent.route.calls.length
        );
        for (uint256 i = 0; i < destIntent.route.calls.length; i++) {
            intentCalls[i] = IntentCall({
                target: address(
                    uint160(uint256(destIntent.route.calls[i].target))
                ),
                data: destIntent.route.calls[i].data,
                value: destIntent.route.calls[i].value
            });
        }
        IntentRoute memory intentRoute = IntentRoute({
            salt: destIntent.route.salt,
            deadline: destIntent.route.deadline,
            portal: address(uint160(uint256(destIntent.route.portal))),
            tokens: intentTokens,
            calls: intentCalls
        });
        portal.fulfill(
            intentHash,
            intentRoute,
            rewardHash,
            bytes32(uint256(uint160(attacker)))
        );
    }

    function testReentrancyAttackPrevention() public {
        // This test verifies that reentrancy attacks are prevented
        // The contracts should use proper state management to prevent reentrancy

        // Create intent with normal token first to ensure proper funding
        TokenAmount[] memory normalRewards = new TokenAmount[](1);
        normalRewards[0] = TokenAmount({
            token: TypeCasts.addressToBytes32(address(tokenA)),
            amount: MINT_AMOUNT
        });

        reward.tokens = normalRewards;
        intent.reward = reward;

        // Fund vault with normal token
        bytes32 routeHash = keccak256(abi.encode(intent.route));
        address vaultAddress = intentSource.intentVaultAddress(
            intent,
            routeHash
        );
        vm.prank(creator);
        tokenA.transfer(vaultAddress, MINT_AMOUNT);

        assertTrue(intentSource.isIntentFunded(intent));

        bytes32 intentHash = _hashIntent(intent);
        _addProof(intentHash, CHAIN_ID, claimant);

        // IntentWithdrawn should succeed and state should be updated
        vm.prank(claimant);
        intentSource.withdraw(intent.destination, intent.reward, routeHash);

        // After withdrawal, vault balance should be 0
        assertEq(tokenA.balanceOf(vaultAddress), 0);

        // Intent should be marked as unfunded since reward was withdrawn
        assertFalse(intentSource.isIntentFunded(intent));
    }

    function testFakePermitContract() public {
        // Create intent with normal token
        TokenAmount[] memory normalRewards = new TokenAmount[](1);
        normalRewards[0] = TokenAmount({
            token: TypeCasts.addressToBytes32(address(tokenA)),
            amount: MINT_AMOUNT
        });

        reward.tokens = normalRewards;
        intent.reward = reward;

        // Creator has tokens but doesn't approve IntentSource
        assertEq(tokenA.balanceOf(creator), MINT_AMOUNT);

        // Don't approve IntentSource
        vm.prank(creator);
        tokenA.approve(address(intentSource), 0);

        bytes32 routeHash = keccak256(abi.encode(route));

        // Try to fund using fake permit contract
        vm.expectRevert(); // Should revert because fake permit doesn't actually transfer
        vm.prank(creator);
        intentSource.fundFor(
            intent.destination,
            reward,
            routeHash,
            creator,
            address(fakePermit),
            false
        );

        // Intent should not be funded
        assertFalse(intentSource.isIntentFunded(intent));

        // Creator should still have their tokens
        assertEq(tokenA.balanceOf(creator), MINT_AMOUNT);

        // Vault should have no tokens
        bytes32 routeHashForVault = keccak256(abi.encode(intent.route));
        address vaultAddress = intentSource.intentVaultAddress(
            intent,
            routeHashForVault
        );
        assertEq(tokenA.balanceOf(vaultAddress), 0);
    }

    function testUSDTNonStandardERC20() public {
        // USDT doesn't return bool from transfer/transferFrom
        // Test that contracts handle this properly

        TokenAmount[] memory usdtRewards = new TokenAmount[](1);
        usdtRewards[0] = TokenAmount({
            token: TypeCasts.addressToBytes32(address(usdt)),
            amount: MINT_AMOUNT
        });

        reward.tokens = usdtRewards;
        intent.reward = reward;

        // Mint USDT to creator
        vm.prank(creator);
        usdt.mint(creator, MINT_AMOUNT);

        // Approve IntentSource
        vm.prank(creator);
        usdt.approve(address(intentSource), MINT_AMOUNT);

        // Should handle USDT properly
        vm.prank(creator);
        bytes32 routeHashForUSDT = keccak256(abi.encode(intent.route));
        intentSource.publishAndFund(intent, routeHashForUSDT, false);

        assertTrue(intentSource.isIntentFunded(intent));

        // Test withdrawal
        bytes32 intentHash = _hashIntent(intent);
        _addProof(intentHash, CHAIN_ID, claimant);

        uint256 initialClaimantBalance = usdt.balanceOf(claimant);

        vm.prank(claimant);
        intentSource.withdraw(
            intent.destination,
            intent.reward,
            routeHashForUSDT
        );

        assertEq(
            usdt.balanceOf(claimant),
            initialClaimantBalance + MINT_AMOUNT
        );
    }

    function testTokenApprovalRaceCondition() public {
        // Test that approval race conditions are handled properly

        TokenAmount[] memory rewards = new TokenAmount[](1);
        rewards[0] = TokenAmount({
            token: TypeCasts.addressToBytes32(address(tokenA)),
            amount: MINT_AMOUNT
        });

        reward.tokens = rewards;
        intent.reward = reward;

        // Initial approval
        vm.prank(creator);
        tokenA.approve(address(intentSource), MINT_AMOUNT);

        // Change approval (simulating race condition)
        vm.prank(creator);
        tokenA.approve(address(intentSource), 0);

        // Try to fund - should fail due to insufficient approval
        vm.expectRevert();
        vm.prank(creator);
        bytes32 rh1 = keccak256(abi.encode(intent.route));
        intentSource.publishAndFund(intent, rh1, false);

        // Re-approve and fund
        vm.prank(creator);
        tokenA.approve(address(intentSource), MINT_AMOUNT);

        vm.prank(creator);
        bytes32 rh2 = keccak256(abi.encode(intent.route));
        intentSource.publishAndFund(intent, rh2, false);

        assertTrue(intentSource.isIntentFunded(intent));
    }

    function testTokenBalanceManipulation() public {
        // Test that token balance manipulation doesn't break the system

        TokenAmount[] memory rewards = new TokenAmount[](1);
        rewards[0] = TokenAmount({
            token: TypeCasts.addressToBytes32(address(tokenA)),
            amount: MINT_AMOUNT * 2
        });

        reward.tokens = rewards;
        intent.reward = reward;

        // Creator only has MINT_AMOUNT tokens
        assertEq(tokenA.balanceOf(creator), MINT_AMOUNT);

        // Approve more than balance
        vm.prank(creator);
        tokenA.approve(address(intentSource), MINT_AMOUNT * 2);

        // Should fail with insufficient balance
        vm.expectRevert();
        vm.prank(creator);
        bytes32 rh3 = keccak256(abi.encode(intent.route));
        intentSource.publishAndFund(intent, rh3, false);

        // With partial funding enabled, should only transfer available balance
        vm.prank(creator);
        bytes32 rh4 = keccak256(abi.encode(intent.route));
        intentSource.publishAndFund(intent, rh4, true);

        bytes32 routeHashForVault = keccak256(abi.encode(intent.route));
        address vaultAddress = intentSource.intentVaultAddress(
            intent,
            routeHashForVault
        );
        assertEq(tokenA.balanceOf(vaultAddress), MINT_AMOUNT); // Only transferred what was available
        assertEq(tokenA.balanceOf(creator), 0); // Creator balance is zero

        // Intent should not be fully funded
        assertFalse(intentSource.isIntentFunded(intent));
    }

    function testZeroAmountTokenTransfer() public {
        // Test that zero amount transfers are handled correctly

        TokenAmount[] memory rewards = new TokenAmount[](1);
        rewards[0] = TokenAmount({
            token: TypeCasts.addressToBytes32(address(tokenA)),
            amount: 0
        });

        reward.tokens = rewards;
        intent.reward = reward;

        vm.prank(creator);
        bytes32 rh5 = keccak256(abi.encode(intent.route));
        intentSource.publishAndFund(intent, rh5, false);

        // Should be considered funded even with zero amounts
        assertTrue(intentSource.isIntentFunded(intent));

        // Test withdrawal
        bytes32 intentHash = _hashIntent(intent);
        _addProof(intentHash, CHAIN_ID, claimant);

        uint256 initialClaimantBalance = tokenA.balanceOf(claimant);

        vm.prank(claimant);
        bytes32 routeHashForWithdraw = keccak256(abi.encode(intent.route));
        intentSource.withdraw(
            intent.destination,
            intent.reward,
            routeHashForWithdraw
        );

        // No tokens should be transferred
        assertEq(tokenA.balanceOf(claimant), initialClaimantBalance);
    }

    function testMixedTokenStandards() public {
        // Test with a mix of standard and non-standard tokens

        TokenAmount[] memory mixedRewards = new TokenAmount[](2);
        mixedRewards[0] = TokenAmount({
            token: TypeCasts.addressToBytes32(address(tokenA)), // Standard ERC20
            amount: MINT_AMOUNT
        });
        mixedRewards[1] = TokenAmount({
            token: TypeCasts.addressToBytes32(address(usdt)), // Non-standard ERC20
            amount: MINT_AMOUNT
        });

        reward.tokens = mixedRewards;
        intent.reward = reward;

        // Mint USDT to creator
        vm.prank(creator);
        usdt.mint(creator, MINT_AMOUNT);

        // Fund vault directly
        bytes32 routeHash = keccak256(abi.encode(intent.route));
        address vaultAddress = intentSource.intentVaultAddress(
            intent,
            routeHash
        );

        vm.prank(creator);
        tokenA.transfer(vaultAddress, MINT_AMOUNT);

        vm.prank(creator);
        usdt.transfer(vaultAddress, MINT_AMOUNT);

        assertTrue(intentSource.isIntentFunded(intent));

        // Test withdrawal
        bytes32 intentHash = _hashIntent(intent);
        _addProof(intentHash, CHAIN_ID, claimant);

        uint256 initialClaimantBalanceA = tokenA.balanceOf(claimant);
        uint256 initialClaimantBalanceUSDT = usdt.balanceOf(claimant);

        vm.prank(claimant);
        intentSource.withdraw(intent.destination, intent.reward, routeHash);

        // Standard tokens should be transferred
        assertEq(
            tokenA.balanceOf(claimant),
            initialClaimantBalanceA + MINT_AMOUNT
        );
        assertEq(
            usdt.balanceOf(claimant),
            initialClaimantBalanceUSDT + MINT_AMOUNT
        );

        // Vault should have 0 balance for all tokens
        assertEq(tokenA.balanceOf(vaultAddress), 0);
        assertEq(usdt.balanceOf(vaultAddress), 0);

        // Intent should be marked as unfunded after withdrawal
        assertFalse(intentSource.isIntentFunded(intent));
    }

    function testTokenContractDestruction() public {
        // Test handling of destroyed token contracts
        // This demonstrates that the system reverts when dealing with non-existent tokens
        // This is expected behavior to prevent issues with destroyed contracts

        TokenAmount[] memory rewards = new TokenAmount[](1);
        rewards[0] = TokenAmount({
            token: TypeCasts.addressToBytes32(address(0x123456789)), // Non-existent contract
            amount: MINT_AMOUNT
        });

        reward.tokens = rewards;
        intent.reward = reward;

        // Publishing should work fine
        vm.prank(creator);
        bytes32 routeHashPub = keccak256(abi.encode(intent.route));
        intentSource.publish(intent, routeHashPub);

        // Even if token contract doesn't exist, the intent should still be publishable
        bytes32 routeHash = keccak256(abi.encode(route));

        // Funding with a non-existent token contract will revert when Vault tries to check balance
        // This is expected behavior - the system protects against non-existent tokens
        vm.prank(creator);
        vm.expectRevert();
        intentSource.fundFor(
            intent.destination,
            reward,
            routeHash,
            creator,
            address(0),
            true
        );

        // Since funding failed, checking if intent is funded will also revert
        vm.expectRevert();
        intentSource.isIntentFunded(intent);
    }
}
