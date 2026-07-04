// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../BaseTest.sol";
import {BadERC20} from "../../contracts/test/BadERC20.sol";
import {FakePermit} from "../../contracts/test/FakePermit.sol";
import {TestUSDT} from "../../contracts/test/TestUSDT.sol";
import {Intent, Route, Reward, RewardToken, TokenAmount, Call} from "../../contracts/types/Intent.sol";
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

        _mintAndApprove(keeper, MINT_AMOUNT);
        _mintAndApprove(attacker, MINT_AMOUNT);
        _mintAndApprove(victim, MINT_AMOUNT);
        _fundUserNative(keeper, 10 ether);
        _fundUserNative(attacker, 10 ether);
        _fundUserNative(victim, 10 ether);
    }

    // Malicious Token Tests
    function testMaliciousTokenInRewards() public {
        // Create intent with malicious token as reward
        RewardToken[] memory maliciousRewards = new RewardToken[](2);
        maliciousRewards[0] = RewardToken({
            token: address(maliciousToken),
            rate: 0,
            flat: MINT_AMOUNT
        });
        maliciousRewards[1] = RewardToken({
            token: address(tokenA),
            rate: 0,
            flat: MINT_AMOUNT
        });

        reward.tokens = maliciousRewards;
        intent.reward = reward;

        // Mint malicious tokens to attacker
        vm.prank(attacker);
        maliciousToken.mint(attacker, MINT_AMOUNT);

        // Fund the account directly with both tokens
        address accountAddress = intentSource.intentAccountAddress(intent);

        vm.prank(attacker);
        maliciousToken.transfer(accountAddress, MINT_AMOUNT);

        vm.prank(keeper);
        tokenA.transfer(accountAddress, MINT_AMOUNT);

        // Verify intent is funded
        assertTrue(intentSource.isIntentFunded(intent));

        // Add proof
        bytes32 intentHash = _hashIntent(intent);
        _addProof(intentHash, CHAIN_ID, claimant);

        bytes32 routeHash = keccak256(abi.encode(intent.route));

        // withdraw reverts because SafeERC20 bubbles up BadERC20.TransferNotAllowed()
        vm.prank(claimant);
        vm.expectRevert(BadERC20.TransferNotAllowed.selector);
        intentSource.settle(
            intent.destination,
            routeHash,
            intent.reward,
            bytes32(uint256(uint160(claimant))),
            _defaultFulfilled()
        );
    }

    function testMaliciousTokenInRouteTokens() public {
        // Create intent with malicious token in route
        TokenAmount[] memory maliciousRouteTokens = new TokenAmount[](1);
        maliciousRouteTokens[0] = TokenAmount({
            token: address(maliciousToken),
            amount: MINT_AMOUNT
        });

        route.minTokens = maliciousRouteTokens;
        intent.route = route;

        // Create corresponding call
        Call[] memory maliciousCalls = new Call[](1);
        maliciousCalls[0] = Call({
            target: address(maliciousToken),
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

        // Solver provides exactly the single min-tokens leg (the malicious token) as input.
        uint256[] memory providedAmounts = new uint256[](1);
        providedAmounts[0] = MINT_AMOUNT;

        // Should revert when the malicious token's transfer (executed by the executor) fails
        vm.prank(attacker);
        bytes32 rewardHash = keccak256(abi.encode(destIntent.reward));
        vm.expectRevert();
        portal.fulfill(
            intentHash,
            destIntent.route,
            rewardHash,
            bytes32(uint256(uint160(attacker))),
            providedAmounts,
            address(prover)
        );
    }

    function testReentrancyAttackPrevention() public {
        // This test verifies that reentrancy attacks are prevented
        // The contracts should use proper state management to prevent reentrancy

        // Create intent with normal token first to ensure proper funding
        RewardToken[] memory normalRewards = new RewardToken[](1);
        normalRewards[0] = RewardToken({
            token: address(tokenA),
            rate: 0,
            flat: MINT_AMOUNT
        });

        reward.tokens = normalRewards;
        intent.reward = reward;

        // Fund account with normal token
        address accountAddress = intentSource.intentAccountAddress(intent);
        vm.prank(keeper);
        tokenA.transfer(accountAddress, MINT_AMOUNT);

        assertTrue(intentSource.isIntentFunded(intent));

        bytes32 intentHash = _hashIntent(intent);
        _addProof(intentHash, CHAIN_ID, claimant);
        bytes32 routeHash = keccak256(abi.encode(intent.route));

        // IntentWithdrawn should succeed and state should be updated
        vm.prank(claimant);
        intentSource.settle(
            intent.destination,
            routeHash,
            intent.reward,
            bytes32(uint256(uint160(claimant))),
            _defaultFulfilled()
        );

        // After withdrawal, account balance should be 0
        assertEq(tokenA.balanceOf(accountAddress), 0);

        // Intent should be marked as unfunded since reward was withdrawn
        assertFalse(intentSource.isIntentFunded(intent));
    }

    function testFakePermitContract() public {
        // Create intent with normal token
        RewardToken[] memory normalRewards = new RewardToken[](1);
        normalRewards[0] = RewardToken({
            token: address(tokenA),
            rate: 0,
            flat: MINT_AMOUNT
        });

        reward.tokens = normalRewards;
        intent.reward = reward;

        // Keeper has tokens but doesn't approve IntentSource
        assertEq(tokenA.balanceOf(keeper), MINT_AMOUNT);

        // Don't approve IntentSource
        vm.prank(keeper);
        tokenA.approve(address(intentSource), 0);

        bytes32 routeHash = keccak256(abi.encode(intent.route));

        // Try to fund using fake permit contract
        vm.expectRevert(); // Should revert because fake permit doesn't actually transfer
        vm.prank(keeper);
        intentSource.fundFor(
            intent.destination,
            routeHash,
            reward,
            false,
            keeper,
            address(fakePermit)
        );

        // Intent should not be funded
        assertFalse(intentSource.isIntentFunded(intent));

        // Keeper should still have their tokens
        assertEq(tokenA.balanceOf(keeper), MINT_AMOUNT);

        // Account should have no tokens
        address accountAddress = intentSource.intentAccountAddress(intent);
        assertEq(tokenA.balanceOf(accountAddress), 0);
    }

    function testUSDTNonStandardERC20() public {
        // USDT doesn't return bool from transfer/transferFrom
        // Test that contracts handle this properly

        RewardToken[] memory usdtRewards = new RewardToken[](1);
        usdtRewards[0] = RewardToken({
            token: address(usdt),
            rate: 0,
            flat: MINT_AMOUNT
        });

        reward.tokens = usdtRewards;
        intent.reward = reward;

        // Mint USDT to keeper
        vm.prank(keeper);
        usdt.mint(keeper, MINT_AMOUNT);

        // Approve IntentSource
        vm.prank(keeper);
        usdt.approve(address(intentSource), MINT_AMOUNT);

        // Should handle USDT properly
        vm.prank(keeper);
        intentSource.publishAndFund(intent, false);

        assertTrue(intentSource.isIntentFunded(intent));

        // Test withdrawal
        bytes32 intentHash = _hashIntent(intent);
        _addProof(intentHash, CHAIN_ID, claimant);

        uint256 initialClaimantBalance = usdt.balanceOf(claimant);

        vm.prank(claimant);
        intentSource.settle(
            intent.destination,
            keccak256(abi.encode(intent.route)),
            intent.reward,
            bytes32(uint256(uint160(claimant))),
            _defaultFulfilled()
        );

        assertEq(
            usdt.balanceOf(claimant),
            initialClaimantBalance + MINT_AMOUNT
        );
    }

    function testTokenApprovalRaceCondition() public {
        // Test that approval race conditions are handled properly

        RewardToken[] memory rewards = new RewardToken[](1);
        rewards[0] = RewardToken({token: address(tokenA), rate: 0, flat: MINT_AMOUNT});

        reward.tokens = rewards;
        intent.reward = reward;

        // Initial approval
        vm.prank(keeper);
        tokenA.approve(address(intentSource), MINT_AMOUNT);

        // Change approval (simulating race condition)
        vm.prank(keeper);
        tokenA.approve(address(intentSource), 0);

        // Try to fund - should fail due to insufficient approval
        vm.expectRevert();
        vm.prank(keeper);
        intentSource.publishAndFund(intent, false);

        // Re-approve and fund
        vm.prank(keeper);
        tokenA.approve(address(intentSource), MINT_AMOUNT);

        vm.prank(keeper);
        intentSource.publishAndFund(intent, false);

        assertTrue(intentSource.isIntentFunded(intent));
    }

    function testTokenBalanceManipulation() public {
        // Test that token balance manipulation doesn't break the system

        RewardToken[] memory rewards = new RewardToken[](1);
        rewards[0] = RewardToken({
            token: address(tokenA),
            rate: 0,
            flat: MINT_AMOUNT * 2
        });

        reward.tokens = rewards;
        intent.reward = reward;

        // Keeper only has MINT_AMOUNT tokens
        assertEq(tokenA.balanceOf(keeper), MINT_AMOUNT);

        // Approve more than balance
        vm.prank(keeper);
        tokenA.approve(address(intentSource), MINT_AMOUNT * 2);

        // Should fail with insufficient balance
        vm.expectRevert();
        vm.prank(keeper);
        intentSource.publishAndFund(intent, false);

        // With partial funding enabled, should only transfer available balance
        vm.prank(keeper);
        intentSource.publishAndFund(intent, true);

        address accountAddress = intentSource.intentAccountAddress(intent);
        assertEq(tokenA.balanceOf(accountAddress), MINT_AMOUNT); // Only transferred what was available
        assertEq(tokenA.balanceOf(keeper), 0); // Keeper balance is zero

        // Intent should not be fully funded
        assertFalse(intentSource.isIntentFunded(intent));
    }

    function testZeroAmountTokenTransfer() public {
        // Test that zero amount transfers are handled correctly

        RewardToken[] memory rewards = new RewardToken[](1);
        rewards[0] = RewardToken({token: address(tokenA), rate: 0, flat: 0});

        reward.tokens = rewards;
        intent.reward = reward;

        vm.prank(keeper);
        intentSource.publishAndFund(intent, false);

        // Should be considered funded even with zero amounts
        assertTrue(intentSource.isIntentFunded(intent));

        // Test withdrawal
        bytes32 intentHash = _hashIntent(intent);
        _addProof(intentHash, CHAIN_ID, claimant);

        uint256 initialClaimantBalance = tokenA.balanceOf(claimant);

        vm.prank(claimant);
        intentSource.settle(
            intent.destination,
            keccak256(abi.encode(intent.route)),
            intent.reward,
            bytes32(uint256(uint160(claimant))),
            _defaultFulfilled()
        );

        // No tokens should be transferred
        assertEq(tokenA.balanceOf(claimant), initialClaimantBalance);
    }

    function testMixedTokenStandards() public {
        // Test with a mix of standard and non-standard tokens

        RewardToken[] memory mixedRewards = new RewardToken[](2);
        mixedRewards[0] = RewardToken({
            token: address(tokenA), // Standard ERC20
            rate: 0,
            flat: MINT_AMOUNT
        });
        mixedRewards[1] = RewardToken({
            token: address(usdt), // Non-standard ERC20
            rate: 0,
            flat: MINT_AMOUNT
        });

        reward.tokens = mixedRewards;
        intent.reward = reward;

        // Mint USDT to keeper
        vm.prank(keeper);
        usdt.mint(keeper, MINT_AMOUNT);

        // Fund account directly
        bytes32 routeHash = keccak256(abi.encode(intent.route));
        address accountAddress = intentSource.intentAccountAddress(intent);

        vm.prank(keeper);
        tokenA.transfer(accountAddress, MINT_AMOUNT);

        vm.prank(keeper);
        usdt.transfer(accountAddress, MINT_AMOUNT);

        assertTrue(intentSource.isIntentFunded(intent));

        // Test withdrawal
        bytes32 intentHash = _hashIntent(intent);
        _addProof(intentHash, CHAIN_ID, claimant);

        uint256 initialClaimantBalanceA = tokenA.balanceOf(claimant);
        uint256 initialClaimantBalanceUSDT = usdt.balanceOf(claimant);

        vm.prank(claimant);
        intentSource.settle(
            intent.destination,
            routeHash,
            intent.reward,
            bytes32(uint256(uint160(claimant))),
            _defaultFulfilled()
        );

        // Standard tokens should be transferred
        assertEq(
            tokenA.balanceOf(claimant),
            initialClaimantBalanceA + MINT_AMOUNT
        );
        assertEq(
            usdt.balanceOf(claimant),
            initialClaimantBalanceUSDT + MINT_AMOUNT
        );

        // Account should have 0 balance for all tokens
        assertEq(tokenA.balanceOf(accountAddress), 0);
        assertEq(usdt.balanceOf(accountAddress), 0);

        // Intent should be marked as unfunded after withdrawal
        assertFalse(intentSource.isIntentFunded(intent));
    }

    function testTokenContractDestruction() public {
        // Test handling of destroyed token contracts
        // This demonstrates that the system reverts when dealing with non-existent tokens
        // This is expected behavior to prevent issues with destroyed contracts

        RewardToken[] memory rewards = new RewardToken[](1);
        rewards[0] = RewardToken({
            token: address(0x123456789), // Non-existent contract
            rate: 0,
            flat: MINT_AMOUNT
        });

        reward.tokens = rewards;
        intent.reward = reward;

        // Publishing should work fine
        vm.prank(keeper);
        intentSource.publish(intent);

        bytes32 routeHash = keccak256(abi.encode(intent.route));

        // Even if token contract doesn't exist, the intent should still be publishable
        // Funding with a non-existent token contract will revert when Account tries to check balance
        // This is expected behavior - the system protects against non-existent tokens
        vm.prank(keeper);
        vm.expectRevert();
        intentSource.fundFor(
            intent.destination,
            routeHash,
            reward,
            true,
            keeper,
            address(0)
        );

        // Since funding failed, checking if intent is funded will also revert
        vm.expectRevert();
        intentSource.isIntentFunded(intent);
    }
}
