// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../BaseTest.sol";
import {Intent, Route, Reward, TokenAmount, Call} from "../../contracts/types/Intent.sol";
import {IBaseSource} from "../../contracts/interfaces/IBaseSource.sol";
import {IProver} from "../../contracts/interfaces/IProver.sol";

contract IntentSourceTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _mintAndApprove(creator, MINT_AMOUNT);
        _fundUserNative(creator, 10 ether);
    }

    // Intent Creation Tests
    function testComputesValidIntentVaultAddress() public view {
        address predictedVault = intentSource.intentVaultAddress(intent);
        assertEq(predictedVault, intentSource.intentVaultAddress(intent));
    }

    function testRevertWhen_PublishingWithWrongSourceChain() public {
        route.source = 12345;
        intent.route = route;

        bytes32 intentHash = keccak256(
            abi.encodePacked(
                keccak256(abi.encode(intent.route)),
                keccak256(abi.encode(intent.reward))
            )
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IBaseSource.WrongSourceChain.selector,
                intentHash
            )
        );
        _publishAndFund(intent, false);
    }

    function testCreatesProperlyWithERC20Rewards() public {
        _publishAndFund(intent, false);
        assertTrue(intentSource.isIntentFunded(intent));
    }

    function testCreatesProperlyWithNativeTokenRewards() public {
        reward.nativeValue = REWARD_NATIVE_ETH;
        intent.reward = reward;

        uint256 initialBalance = creator.balance;
        _publishAndFundWithValue(intent, false, REWARD_NATIVE_ETH * 2);

        assertTrue(intentSource.isIntentFunded(intent));

        address vaultAddress = intentSource.intentVaultAddress(intent);
        assertEq(vaultAddress.balance, REWARD_NATIVE_ETH);

        // Check excess was refunded
        assertTrue(creator.balance > initialBalance - REWARD_NATIVE_ETH * 2);
    }

    function testIncrementsCounterAndLocksUpTokens() public {
        reward.nativeValue = REWARD_NATIVE_ETH;
        intent.reward = reward;

        _publishAndFundWithValue(intent, false, REWARD_NATIVE_ETH);

        address vaultAddress = intentSource.intentVaultAddress(intent);
        assertEq(tokenA.balanceOf(vaultAddress), MINT_AMOUNT);
        assertEq(tokenB.balanceOf(vaultAddress), MINT_AMOUNT * 2);
        assertEq(vaultAddress.balance, REWARD_NATIVE_ETH);
    }

    function testEmitsEvents() public {
        reward.nativeValue = REWARD_NATIVE_ETH;
        intent.reward = reward;

        bytes32 intentHash = _hashIntent(intent);

        _expectEmit();
        emit IIntentSource.IntentCreated(
            intentHash,
            salt,
            block.chainid,
            CHAIN_ID,
            address(inbox),
            routeTokens,
            calls,
            creator,
            address(prover),
            expiry,
            REWARD_NATIVE_ETH,
            rewardTokens
        );

        _publishAndFundWithValue(intent, false, REWARD_NATIVE_ETH);
    }

    // Claiming Rewards Tests
    function testCantWithdrawBeforeExpiryWithoutProof() public {
        _publishAndFund(intent, false);

        vm.expectRevert();
        vm.prank(otherPerson);
        bytes32 routeHash = keccak256(abi.encode(intent.route));
        intentSource.withdrawRewards(routeHash, intent.reward);
    }

    function testWithdrawsToClaimantWithProof() public {
        reward.nativeValue = REWARD_NATIVE_ETH;
        intent.reward = reward;

        _publishAndFundWithValue(intent, false, REWARD_NATIVE_ETH);

        bytes32 intentHash = _hashIntent(intent);
        _addProof(intentHash, CHAIN_ID, claimant);

        uint256 initialBalanceA = tokenA.balanceOf(claimant);
        uint256 initialBalanceB = tokenB.balanceOf(claimant);
        uint256 initialBalanceNative = claimant.balance;

        assertTrue(intentSource.isIntentFunded(intent));

        vm.prank(otherPerson);
        bytes32 routeHash = keccak256(abi.encode(intent.route));
        intentSource.withdrawRewards(routeHash, intent.reward);

        assertFalse(intentSource.isIntentFunded(intent));
        assertEq(tokenA.balanceOf(claimant), initialBalanceA + MINT_AMOUNT);
        assertEq(tokenB.balanceOf(claimant), initialBalanceB + MINT_AMOUNT * 2);
        assertEq(claimant.balance, initialBalanceNative + REWARD_NATIVE_ETH);
    }

    function testEmitsWithdrawalEvent() public {
        _publishAndFund(intent, false);

        bytes32 intentHash = _hashIntent(intent);
        _addProof(intentHash, CHAIN_ID, claimant);

        _expectEmit();
        emit IBaseSource.Withdrawal(intentHash, claimant);

        vm.prank(otherPerson);
        bytes32 routeHash = keccak256(abi.encode(intent.route));
        intentSource.withdrawRewards(routeHash, intent.reward);
    }

    function testDoesNotAllowRepeatWithdrawal() public {
        _publishAndFund(intent, false);

        bytes32 intentHash = _hashIntent(intent);
        _addProof(intentHash, CHAIN_ID, claimant);

        vm.prank(otherPerson);
        bytes32 routeHash = keccak256(abi.encode(intent.route));
        intentSource.withdrawRewards(routeHash, intent.reward);

        vm.expectRevert();
        vm.prank(otherPerson);
        intentSource.withdrawRewards(routeHash, intent.reward);
    }

    function testAllowsRefundIfAlreadyClaimed() public {
        _publishAndFund(intent, false);

        bytes32 intentHash = _hashIntent(intent);
        _addProof(intentHash, CHAIN_ID, claimant);

        _expectEmit();
        emit IBaseSource.Withdrawal(intentHash, claimant);

        vm.prank(otherPerson);
        bytes32 routeHash = keccak256(abi.encode(intent.route));
        intentSource.withdrawRewards(routeHash, intent.reward);

        _expectEmit();
        emit IBaseSource.Refund(intentHash, creator);

        vm.prank(otherPerson);
        intentSource.refund(routeHash, intent.reward);
    }

    // After Expiry Tests
    function testRefundsToCreatorAfterExpiry() public {
        _publishAndFund(intent, false);

        _timeTravel(expiry + 1);

        uint256 initialBalanceA = tokenA.balanceOf(creator);
        uint256 initialBalanceB = tokenB.balanceOf(creator);

        assertTrue(intentSource.isIntentFunded(intent));

        vm.prank(otherPerson);
        bytes32 routeHash = keccak256(abi.encode(intent.route));
        intentSource.refund(routeHash, intent.reward);

        assertFalse(intentSource.isIntentFunded(intent));
        assertEq(tokenA.balanceOf(creator), initialBalanceA + MINT_AMOUNT);
        assertEq(tokenB.balanceOf(creator), initialBalanceB + MINT_AMOUNT * 2);
    }

    function testWithdrawsToClaimantAfterExpiryWithProof() public {
        _publishAndFund(intent, false);

        bytes32 intentHash = _hashIntent(intent);
        _addProof(intentHash, CHAIN_ID, claimant);
        _timeTravel(expiry);

        uint256 initialBalanceA = tokenA.balanceOf(claimant);
        uint256 initialBalanceB = tokenB.balanceOf(claimant);

        assertTrue(intentSource.isIntentFunded(intent));

        vm.prank(otherPerson);
        bytes32 routeHash = keccak256(abi.encode(intent.route));
        intentSource.withdrawRewards(routeHash, intent.reward);

        assertFalse(intentSource.isIntentFunded(intent));
        assertEq(tokenA.balanceOf(claimant), initialBalanceA + MINT_AMOUNT);
        assertEq(tokenB.balanceOf(claimant), initialBalanceB + MINT_AMOUNT * 2);
    }

    function testChallengesIntentProofOnWrongDestinationChain() public {
        _publishAndFund(intent, false);

        bytes32 intentHash = _hashIntent(intent);
        _addProof(intentHash, 2, claimant); // Wrong chain ID
        _timeTravel(expiry);

        // Verify proof exists before challenge
        IProver.ProofData memory proofBefore = prover.provenIntents(intentHash);
        assertTrue(proofBefore.claimant != address(0));

        // Challenge the proof manually
        vm.prank(otherPerson);
        prover.challengeIntentProof(intent);

        // Verify proof was cleared after challenge
        IProver.ProofData memory proofAfter = prover.provenIntents(intentHash);
        assertEq(proofAfter.claimant, address(0));
        assertTrue(intentSource.isIntentFunded(intent));
    }

    function testCantRefundIfProofExists() public {
        _publishAndFund(intent, false);

        bytes32 intentHash = _hashIntent(intent);
        _addProof(intentHash, 2, claimant); // Add any proof

        vm.prank(otherPerson);
        bytes32 routeHash = keccak256(abi.encode(intent.route));
        vm.expectRevert(
            abi.encodeWithSelector(
                IBaseSource.IntentNotClaimed.selector,
                intentHash
            )
        );
        intentSource.refund(routeHash, intent.reward);
    }

    // Batch Withdrawal Tests
    function testBatchWithdrawalFailsBeforeExpiry() public {
        _publishAndFund(intent, false);

        bytes32[] memory routeHashes = new bytes32[](1);
        Reward[] memory rewards = new Reward[](1);
        routeHashes[0] = keccak256(abi.encode(intent.route));
        rewards[0] = intent.reward;

        vm.expectRevert();
        vm.prank(otherPerson);
        intentSource.batchWithdraw(routeHashes, rewards);
    }

    function testBatchWithdrawalSingleIntentBeforeExpiryToClaimant() public {
        reward.nativeValue = REWARD_NATIVE_ETH;
        intent.reward = reward;

        _publishAndFundWithValue(intent, false, REWARD_NATIVE_ETH);

        bytes32 intentHash = _hashIntent(intent);
        _addProof(intentHash, CHAIN_ID, claimant);

        uint256 initialBalanceNative = claimant.balance;

        assertTrue(intentSource.isIntentFunded(intent));
        assertEq(tokenA.balanceOf(claimant), 0);
        assertEq(tokenB.balanceOf(claimant), 0);

        bytes32[] memory routeHashes = new bytes32[](1);
        Reward[] memory rewards = new Reward[](1);
        routeHashes[0] = keccak256(abi.encode(intent.route));
        rewards[0] = intent.reward;

        vm.prank(otherPerson);
        intentSource.batchWithdraw(routeHashes, rewards);

        assertFalse(intentSource.isIntentFunded(intent));
        assertEq(tokenA.balanceOf(claimant), MINT_AMOUNT);
        assertEq(tokenB.balanceOf(claimant), MINT_AMOUNT * 2);
        assertEq(claimant.balance, initialBalanceNative + REWARD_NATIVE_ETH);
    }

    function testBatchWithdrawalAfterExpiryToCreator() public {
        reward.nativeValue = REWARD_NATIVE_ETH;
        intent.reward = reward;

        _publishAndFundWithValue(intent, false, REWARD_NATIVE_ETH);

        _timeTravel(expiry);

        bytes32 intentHash = _hashIntent(intent);
        _addProof(intentHash, CHAIN_ID, creator);

        uint256 initialBalanceNative = creator.balance;

        assertTrue(intentSource.isIntentFunded(intent));

        bytes32[] memory routeHashes = new bytes32[](1);
        Reward[] memory rewards = new Reward[](1);
        routeHashes[0] = keccak256(abi.encode(intent.route));
        rewards[0] = intent.reward;

        vm.prank(otherPerson);
        intentSource.batchWithdraw(routeHashes, rewards);

        assertFalse(intentSource.isIntentFunded(intent));
        assertEq(tokenA.balanceOf(creator), MINT_AMOUNT);
        assertEq(tokenB.balanceOf(creator), MINT_AMOUNT * 2);
        assertEq(creator.balance, initialBalanceNative + REWARD_NATIVE_ETH);
    }

    // Funding Tests
    function testFundIntentWithMultipleTokens() public {
        bytes32 routeHash = keccak256(abi.encode(route));

        address intentVault = intentSource.intentVaultAddress(intent);

        vm.prank(creator);
        tokenA.approve(intentVault, MINT_AMOUNT);
        vm.prank(creator);
        tokenB.approve(intentVault, MINT_AMOUNT * 2);

        vm.prank(creator);
        intentSource.fundFor(routeHash, reward, creator, address(0), false);

        assertTrue(intentSource.isIntentFunded(intent));
        assertEq(tokenA.balanceOf(intentVault), MINT_AMOUNT);
        assertEq(tokenB.balanceOf(intentVault), MINT_AMOUNT * 2);
    }

    function testEmitsIntentFundedEvent() public {
        bytes32 routeHash = keccak256(abi.encode(route));
        bytes32 intentHash = _hashIntent(intent);

        address intentVault = intentSource.intentVaultAddress(intent);

        vm.prank(creator);
        tokenA.approve(intentVault, MINT_AMOUNT);
        vm.prank(creator);
        tokenB.approve(intentVault, MINT_AMOUNT * 2);

        _expectEmit();
        emit IBaseSource.IntentFunded(intentHash, creator);

        vm.prank(creator);
        intentSource.fundFor(routeHash, reward, creator, address(0), false);
    }

    function testHandlesPartialFundingBasedOnAllowance() public {
        bytes32 routeHash = keccak256(abi.encode(route));

        address intentVault = intentSource.intentVaultAddress(intent);

        vm.prank(creator);
        tokenA.approve(intentVault, MINT_AMOUNT / 2);
        vm.prank(creator);
        tokenB.approve(intentVault, MINT_AMOUNT * 2);

        vm.prank(creator);
        intentSource.fundFor(routeHash, reward, creator, address(0), true);

        assertFalse(intentSource.isIntentFunded(intent));
        assertEq(tokenA.balanceOf(intentVault), MINT_AMOUNT / 2);
        assertEq(tokenB.balanceOf(intentVault), MINT_AMOUNT * 2);
    }

    // Edge Cases
    function testHandlesZeroTokenAmounts() public {
        // Create intent with zero amounts
        TokenAmount[] memory zeroRewardTokens = new TokenAmount[](1);
        zeroRewardTokens[0] = TokenAmount({token: address(tokenA), amount: 0});

        Reward memory newReward = reward;
        newReward.tokens = zeroRewardTokens;
        intent.reward = newReward;

        vm.prank(creator);
        intentSource.publish(intent);

        bytes32 routeHash = keccak256(abi.encode(route));

        vm.prank(creator);
        intentSource.fundFor(routeHash, newReward, creator, address(0), false);

        assertTrue(intentSource.isIntentFunded(intent));

        address vaultAddress = intentSource.intentVaultAddress(intent);
        assertEq(tokenA.balanceOf(vaultAddress), 0);
    }

    function testHandlesAlreadyFundedVaults() public {
        // Fund intent initially
        _publishAndFund(intent, false);

        // Try to fund again
        bytes32 routeHash = keccak256(abi.encode(route));

        vm.prank(creator);
        tokenA.approve(address(intentSource), MINT_AMOUNT);

        vm.prank(creator);
        intentSource.fundFor(routeHash, reward, creator, address(0), false);

        assertTrue(intentSource.isIntentFunded(intent));

        address vaultAddress = intentSource.intentVaultAddress(intent);
        assertEq(tokenA.balanceOf(vaultAddress), MINT_AMOUNT);
    }

    function testInsufficientNativeReward() public {
        reward.nativeValue = 1 ether;
        intent.reward = reward;

        vm.expectRevert();
        vm.prank(creator);
        intentSource.publishAndFund{value: 0.5 ether}(intent, false);
    }

    function testPartialFundingWithNativeTokens() public {
        uint256 nativeAmount = 1 ether;
        uint256 sentAmount = 0.5 ether;

        reward.nativeValue = nativeAmount;
        intent.reward = reward;

        bytes32 intentHash = _hashIntent(intent);

        _expectEmit();
        emit IBaseSource.IntentPartiallyFunded(intentHash, creator);

        vm.prank(creator);
        intentSource.publishAndFund{value: sentAmount}(intent, true);

        address vaultAddress = intentSource.intentVaultAddress(intent);
        assertEq(vaultAddress.balance, sentAmount);
        assertFalse(intentSource.isIntentFunded(intent));
    }

    function testUseActualBalanceOverAllowanceForPartialFunding() public {
        uint256 requestedAmount = MINT_AMOUNT * 2;

        // Setup intent with more tokens than creator has
        TokenAmount[] memory largeRewardTokens = new TokenAmount[](1);
        largeRewardTokens[0] = TokenAmount({
            token: address(tokenA),
            amount: requestedAmount
        });

        Reward memory newReward = reward;
        newReward.tokens = largeRewardTokens;
        intent.reward = newReward;

        // Creator only has MINT_AMOUNT tokens but approves twice as much
        assertEq(tokenA.balanceOf(creator), MINT_AMOUNT);

        vm.prank(creator);
        tokenA.approve(address(intentSource), requestedAmount);

        bytes32 intentHash = _hashIntent(intent);

        _expectEmit();
        emit IBaseSource.IntentPartiallyFunded(intentHash, creator);

        vm.prank(creator);
        intentSource.publishAndFund(intent, true);

        address vaultAddress = intentSource.intentVaultAddress(intent);
        assertEq(tokenA.balanceOf(vaultAddress), MINT_AMOUNT);
        assertEq(tokenA.balanceOf(creator), 0);
        assertFalse(intentSource.isIntentFunded(intent));
    }

    function testRevertWhenBalanceAndAllowanceInsufficientWithoutAllowPartial()
        public
    {
        uint256 requestedAmount = MINT_AMOUNT * 2;

        // Setup intent with more tokens than creator has
        TokenAmount[] memory largeRewardTokens = new TokenAmount[](1);
        largeRewardTokens[0] = TokenAmount({
            token: address(tokenA),
            amount: requestedAmount
        });

        Reward memory newReward = reward;
        newReward.tokens = largeRewardTokens;
        intent.reward = newReward;

        // Creator only has MINT_AMOUNT tokens but approves twice as much
        assertEq(tokenA.balanceOf(creator), MINT_AMOUNT);

        vm.prank(creator);
        tokenA.approve(address(intentSource), requestedAmount);

        vm.expectRevert();
        vm.prank(creator);
        intentSource.publishAndFund(intent, false);
    }

    function testWithdrawsRewardsWithMaliciousTokens() public {
        // Deploy malicious token
        BadERC20 maliciousToken = new BadERC20("Malicious", "MAL", creator);

        vm.prank(creator);
        maliciousToken.mint(creator, MINT_AMOUNT);

        // Create reward with malicious token
        TokenAmount[] memory badRewardTokens = new TokenAmount[](2);
        badRewardTokens[0] = TokenAmount({
            token: address(maliciousToken),
            amount: MINT_AMOUNT
        });
        badRewardTokens[1] = TokenAmount({
            token: address(tokenA),
            amount: MINT_AMOUNT
        });

        Reward memory newReward = reward;
        newReward.tokens = badRewardTokens;
        intent.reward = newReward;

        address vaultAddress = intentSource.intentVaultAddress(intent);

        // Transfer tokens to vault
        vm.prank(creator);
        maliciousToken.transfer(vaultAddress, MINT_AMOUNT);

        vm.prank(creator);
        tokenA.transfer(vaultAddress, MINT_AMOUNT);

        assertTrue(intentSource.isIntentFunded(intent));

        bytes32 intentHash = _hashIntent(intent);
        _addProof(intentHash, CHAIN_ID, claimant);

        uint256 initialClaimantBalance = tokenA.balanceOf(claimant);

        // Should not revert despite malicious token
        vm.prank(claimant);
        bytes32 routeHash = keccak256(abi.encode(intent.route));
        intentSource.withdrawRewards(routeHash, intent.reward);

        assertEq(
            tokenA.balanceOf(claimant),
            initialClaimantBalance + MINT_AMOUNT
        );
    }

    function testBalanceOverAllowanceForPartialFunding() public {
        // Create intent with more tokens than creator has
        uint256 requestedAmount = MINT_AMOUNT * 2;

        TokenAmount[] memory largeRewardTokens = new TokenAmount[](1);
        largeRewardTokens[0] = TokenAmount({
            token: address(tokenA),
            amount: requestedAmount
        });

        Reward memory newReward = reward;
        newReward.tokens = largeRewardTokens;
        intent.reward = newReward;

        // Creator only has MINT_AMOUNT tokens but approves twice as much
        assertEq(tokenA.balanceOf(creator), MINT_AMOUNT);

        vm.prank(creator);
        tokenA.approve(address(intentSource), requestedAmount);

        bytes32 intentHash = _hashIntent(intent);

        _expectEmit();
        emit IBaseSource.IntentPartiallyFunded(intentHash, creator);

        vm.prank(creator);
        intentSource.publishAndFund(intent, true);

        address vaultAddress = intentSource.intentVaultAddress(intent);
        // Should transfer actual balance, not approved amount
        assertEq(tokenA.balanceOf(vaultAddress), MINT_AMOUNT);
        assertEq(tokenA.balanceOf(creator), 0);
        assertFalse(intentSource.isIntentFunded(intent));
    }

    function testInsufficientNativeRewardHandling() public {
        uint256 nativeAmount = 1 ether;
        uint256 sentAmount = 0.5 ether;

        reward.nativeValue = nativeAmount;
        intent.reward = reward;

        // Test insufficient native reward without partial funding
        vm.expectRevert();
        vm.prank(creator);
        intentSource.publishAndFund{value: sentAmount}(intent, false);

        // Test with partial funding allowed
        bytes32 intentHash = _hashIntent(intent);

        _expectEmit();
        emit IBaseSource.IntentPartiallyFunded(intentHash, creator);

        vm.prank(creator);
        intentSource.publishAndFund{value: sentAmount}(intent, true);

        address vaultAddress = intentSource.intentVaultAddress(intent);
        assertEq(vaultAddress.balance, sentAmount);
        assertFalse(intentSource.isIntentFunded(intent));
    }

    function testFakePermitContractHandling() public {
        // Deploy fake permit contract
        FakePermitContract fakePermit = new FakePermitContract();

        bytes32 routeHash = keccak256(abi.encode(route));
        address intentVault = intentSource.intentVaultAddress(intent);

        // Creator has tokens but doesn't approve IntentSource
        assertEq(tokenA.balanceOf(creator), MINT_AMOUNT);

        // The fake permit will fail to actually transfer tokens
        vm.expectRevert();
        vm.prank(creator);
        intentSource.fundFor(
            routeHash,
            reward,
            creator,
            address(fakePermit),
            false
        );

        // Verify intent is not funded
        assertFalse(intentSource.isIntentFunded(intent));

        // Verify no tokens were transferred
        assertEq(tokenA.balanceOf(creator), MINT_AMOUNT);
        assertEq(tokenA.balanceOf(intentVault), 0);
    }

    function testZeroValueNativeTokenExploit() public {
        // Critical security test: prevent marking intent as funded with zero native value
        uint256 nativeAmount = 1 ether;

        reward.nativeValue = nativeAmount;
        intent.reward = reward;

        // Try to exploit by sending zero value but claiming intent is funded
        vm.expectRevert();
        vm.prank(creator);
        intentSource.publishAndFund{value: 0}(intent, false);

        // Verify intent is not marked as funded
        assertFalse(intentSource.isIntentFunded(intent));

        // Verify vault has no ETH
        address vaultAddress = intentSource.intentVaultAddress(intent);
        assertEq(vaultAddress.balance, 0);
    }

    function testOverfundedVaultHandling() public {
        // Test behavior when vault has more tokens than required
        _publishAndFund(intent, false);

        // Send additional tokens to vault
        address vaultAddress = intentSource.intentVaultAddress(intent);
        vm.prank(creator);
        tokenA.mint(creator, MINT_AMOUNT);
        vm.prank(creator);
        tokenA.transfer(vaultAddress, MINT_AMOUNT);

        // Vault should now have double the required amount
        assertEq(tokenA.balanceOf(vaultAddress), MINT_AMOUNT * 2);

        // Intent should still be considered funded
        assertTrue(intentSource.isIntentFunded(intent));

        // Withdrawal should work correctly with overfunded vault
        bytes32 intentHash = _hashIntent(intent);
        _addProof(intentHash, CHAIN_ID, claimant);

        uint256 initialBalanceA = tokenA.balanceOf(claimant);
        uint256 initialBalanceB = tokenB.balanceOf(claimant);

        vm.prank(claimant);
        bytes32 routeHash = keccak256(abi.encode(intent.route));
        intentSource.withdrawRewards(routeHash, intent.reward);

        // Claimant should receive reward amount, creator gets the excess
        assertEq(tokenA.balanceOf(claimant), initialBalanceA + MINT_AMOUNT);
        assertEq(tokenB.balanceOf(claimant), initialBalanceB + MINT_AMOUNT * 2);
    }

    function testDuplicateTokensInRewardArray() public {
        // Security test: ensure system handles duplicate tokens gracefully
        TokenAmount[] memory duplicateRewardTokens = new TokenAmount[](3);
        duplicateRewardTokens[0] = TokenAmount({
            token: address(tokenA),
            amount: MINT_AMOUNT
        });
        duplicateRewardTokens[1] = TokenAmount({
            token: address(tokenA), // Duplicate
            amount: MINT_AMOUNT / 2
        });
        duplicateRewardTokens[2] = TokenAmount({
            token: address(tokenB),
            amount: MINT_AMOUNT * 2
        });

        Reward memory newReward = reward;
        newReward.tokens = duplicateRewardTokens;
        intent.reward = newReward;

        // Mint additional tokens for this test
        _mintAndApprove(creator, MINT_AMOUNT * 2);

        // Fund the vault with enough tokens
        address vaultAddress = intentSource.intentVaultAddress(intent);
        vm.prank(creator);
        tokenA.transfer(vaultAddress, MINT_AMOUNT * 2);
        vm.prank(creator);
        tokenB.transfer(vaultAddress, MINT_AMOUNT * 2);

        // Should be considered funded
        assertTrue(intentSource.isIntentFunded(intent));

        bytes32 intentHash = _hashIntent(intent);
        _addProof(intentHash, CHAIN_ID, claimant);

        // Withdrawal should handle duplicates correctly
        vm.prank(claimant);
        bytes32 routeHash = keccak256(abi.encode(intent.route));
        intentSource.withdrawRewards(routeHash, intent.reward);

        // Verify balances (should transfer per each entry, including duplicates)
        assertGt(tokenA.balanceOf(claimant), 0);
        assertGt(tokenB.balanceOf(claimant), 0);
    }

    function testBatchWithdrawWithMixedStates() public {
        // Mint more tokens for multiple intents
        _mintAndApprove(creator, MINT_AMOUNT * 3);

        // Create multiple intents with different states
        Intent[] memory intents = new Intent[](3);

        // Intent 1: Fully funded and proven
        intents[0] = intent;
        _publishAndFund(intents[0], false);
        bytes32 hash1 = _hashIntent(intents[0]);
        _addProof(hash1, CHAIN_ID, claimant);

        // Intent 2: Funded but not proven (should be refunded after expiry)
        intents[1] = intent;
        intents[1].route.salt = keccak256("salt2");
        _publishAndFund(intents[1], false);

        // Intent 3: Proven but different claimant
        intents[2] = intent;
        intents[2].route.salt = keccak256("salt3");
        _publishAndFund(intents[2], false);
        bytes32 hash3 = _hashIntent(intents[2]);
        _addProof(hash3, CHAIN_ID, creator); // Different claimant

        // Time travel past expiry
        _timeTravel(expiry);

        uint256 initialClaimantBalance = tokenA.balanceOf(claimant);
        uint256 initialCreatorBalance = tokenA.balanceOf(creator);

        // Batch withdraw should handle mixed states
        bytes32[] memory routeHashes = new bytes32[](3);
        Reward[] memory rewards = new Reward[](3);
        routeHashes[0] = keccak256(abi.encode(intents[0].route));
        routeHashes[1] = keccak256(abi.encode(intents[1].route));
        routeHashes[2] = keccak256(abi.encode(intents[2].route));
        rewards[0] = intents[0].reward;
        rewards[1] = intents[1].reward;
        rewards[2] = intents[2].reward;

        vm.prank(otherPerson);
        intentSource.batchWithdraw(routeHashes, rewards);

        // Verify correct distributions
        // Intent 1: should go to claimant
        // Intent 2: should go to creator (refund)
        // Intent 3: should go to creator (different claimant)
        assertGt(tokenA.balanceOf(claimant), initialClaimantBalance);
        assertGt(tokenA.balanceOf(creator), initialCreatorBalance);
    }

    function testEventEmissionForAllOperations() public {
        // Test comprehensive event emission
        bytes32 intentHash = _hashIntent(intent);

        // Test IntentCreated event
        _expectEmit();
        emit IIntentSource.IntentCreated(
            intentHash,
            salt,
            block.chainid,
            CHAIN_ID,
            address(inbox),
            intent.route.tokens,
            intent.route.calls,
            creator,
            address(prover),
            expiry,
            0,
            intent.reward.tokens
        );

        vm.prank(creator);
        intentSource.publish(intent);

        // Test IntentFunded event
        bytes32 routeHash = keccak256(abi.encode(route));
        address intentVault = intentSource.intentVaultAddress(intent);

        vm.prank(creator);
        tokenA.approve(intentVault, MINT_AMOUNT);
        vm.prank(creator);
        tokenB.approve(intentVault, MINT_AMOUNT * 2);

        _expectEmit();
        emit IBaseSource.IntentFunded(intentHash, creator);

        vm.prank(creator);
        intentSource.fundFor(routeHash, reward, creator, address(0), false);

        // Test withdrawal event
        _addProof(intentHash, CHAIN_ID, claimant);

        _expectEmit();
        emit IBaseSource.Withdrawal(intentHash, claimant);

        vm.prank(claimant);
        intentSource.withdrawRewards(routeHash, intent.reward);
    }
}

// Mock contract for testing fake permit behavior
contract FakePermitContract {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        // Fake permit that doesn't actually approve tokens
        // This simulates a malicious permit contract
    }

    function allowance(
        address /* owner */,
        address /* spender */
    ) external pure returns (uint256) {
        // Lies about having unlimited allowance
        return type(uint256).max;
    }
}
