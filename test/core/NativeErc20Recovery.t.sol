// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BaseTest} from "../BaseTest.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {Portal} from "../../contracts/Portal.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";
import {TestPolicy} from "../../contracts/test/TestPolicy.sol";
import {Intent, Route, Reward, RewardToken, TokenAmount, Call, IntentLib} from "../../contracts/types/Intent.sol";

/**
 * @title NativeErc20RecoveryTest
 * @notice Covers the {IntentSource-NATIVE_ERC20} recovery-eligibility check: on a deployment where the
 *         native asset is configured to be aliased to an ERC20 token, {IntentSource-recoverToken} must
 *         treat the alias token and a native reward leg as the same underlying asset. Also covers the
 *         matching funding-time guard: a reward may not declare both a native leg and an alias-token leg
 *         at once, on every entry point that can escrow a reward (publish, fund, fundFor).
 */
contract NativeErc20RecoveryTest is BaseTest {
    Portal internal aliasPortal;
    IIntentSource internal aliasIntentSource;
    TestPolicy internal aliasProver;
    TestERC20 internal aliasToken;

    uint256 internal constant NATIVE_FLAT = 1 ether;
    uint256 internal constant ERC20_FLAT = MINT_AMOUNT;

    function setUp() public override {
        super.setUp();

        // A separate deployment where the native asset is aliased to `aliasToken`.
        vm.startPrank(deployer);
        aliasToken = new TestERC20("Alias Token", "ALIAS");
        aliasPortal = new Portal(address(aliasToken));
        aliasIntentSource = IIntentSource(address(aliasPortal));
        aliasProver = new TestPolicy(address(aliasPortal));
        vm.stopPrank();

        _fundUserNative(keeper, 100 ether);
    }

    /**
     * @notice Builds a minimal intent (no calls, no min-tokens) for `aliasPortal` with a single reward
     *         leg, keyed by `salt` so distinct calls produce distinct intent hashes / accounts.
     */
    function _buildAliasIntent(
        bytes32 saltValue,
        RewardToken memory rewardLeg
    ) internal view returns (Intent memory) {
        RewardToken[] memory tokens = new RewardToken[](1);
        tokens[0] = rewardLeg;
        return _buildAliasIntentMultiLeg(saltValue, tokens);
    }

    /**
     * @notice Same as {_buildAliasIntent} but for an arbitrary reward-leg array, so callers can
     *         construct a reward with more than one leg (e.g. a native leg alongside an alias-token leg).
     */
    function _buildAliasIntentMultiLeg(
        bytes32 saltValue,
        RewardToken[] memory rewardLegs
    ) internal view returns (Intent memory) {
        Route memory aliasRoute = Route({
            salt: saltValue,
            deadline: uint64(expiry),
            portal: address(aliasPortal),
            keeper: keeper,
            calls: new Call[](0),
            minTokens: new TokenAmount[](0)
        });

        Reward memory aliasReward = Reward({
            deadline: uint64(expiry),
            keeper: keeper,
            prover: address(aliasProver),
            tokens: rewardLegs
        });

        return Intent({destination: CHAIN_ID, route: aliasRoute, reward: aliasReward});
    }

    /**
     * @notice Sends `amount` of `token` directly to `account`, simulating tokens mistakenly transferred
     *         to the intent's account rather than escrowed through funding.
     */
    function _mistakenlySend(
        TestERC20 token,
        address account,
        uint256 amount
    ) internal {
        token.mint(account, amount);
    }

    /**
     * @notice Default/inert case: with the default `nativeErc20 = address(0)` deployment (the normal
     *         BaseTest portal), recovering an arbitrary unrelated ERC20 token mistakenly sent to a funded
     *         account still succeeds exactly as before.
     */
    function testRecover_defaultDeployment_stillWorks() public {
        _mintAndApprove(keeper, MINT_AMOUNT);
        _publishAndFund(intent, false);

        TestERC20 strayToken = new TestERC20("Stray Token", "STRY");
        address account = intentSource.intentAccountAddress(intent);
        _mistakenlySend(strayToken, account, MINT_AMOUNT);

        intentSource.recoverToken(
            intent.destination,
            keccak256(abi.encode(intent.route)),
            intent.reward,
            address(strayToken)
        );

        assertEq(strayToken.balanceOf(keeper), MINT_AMOUNT);
        assertEq(strayToken.balanceOf(account), 0);
    }

    /**
     * @notice Alias-configured deployment, reward carries a native leg: recovering the alias token must
     *         revert, since it mirrors the same underlying native balance the reward's native leg claims.
     */
    function testRecover_aliasToken_blockedWhenNativeLegPresent() public {
        Intent memory nativeLegIntent = _buildAliasIntent(
            keccak256("native-leg"),
            RewardToken({token: address(0), rate: 0, flat: NATIVE_FLAT})
        );

        vm.prank(keeper);
        aliasIntentSource.publishAndFund{value: NATIVE_FLAT}(nativeLegIntent, false);

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.InvalidRecoverToken.selector,
                address(aliasToken)
            )
        );
        aliasIntentSource.recoverToken(
            nativeLegIntent.destination,
            keccak256(abi.encode(nativeLegIntent.route)),
            nativeLegIntent.reward,
            address(aliasToken)
        );
    }

    /**
     * @notice Same alias-configured deployment, reward carries NO native leg: recovering the alias token
     *         for a different intent still succeeds — the check must not over-block when there's no
     *         native leg to protect.
     */
    function testRecover_aliasToken_allowedWhenNoNativeLeg() public {
        TestERC20 erc20RewardToken = new TestERC20("ERC20 Reward", "ERW");
        vm.startPrank(keeper);
        erc20RewardToken.mint(keeper, ERC20_FLAT);
        erc20RewardToken.approve(address(aliasIntentSource), ERC20_FLAT);
        vm.stopPrank();

        Intent memory noNativeLegIntent = _buildAliasIntent(
            keccak256("no-native-leg"),
            RewardToken({token: address(erc20RewardToken), rate: 0, flat: ERC20_FLAT})
        );

        vm.prank(keeper);
        aliasIntentSource.publishAndFund(noNativeLegIntent, false);

        address account = aliasIntentSource.intentAccountAddress(noNativeLegIntent);
        _mistakenlySend(aliasToken, account, MINT_AMOUNT);

        aliasIntentSource.recoverToken(
            noNativeLegIntent.destination,
            keccak256(abi.encode(noNativeLegIntent.route)),
            noNativeLegIntent.reward,
            address(aliasToken)
        );

        assertEq(aliasToken.balanceOf(keeper), MINT_AMOUNT);
        assertEq(aliasToken.balanceOf(account), 0);
    }

    /**
     * @notice Same alias-configured deployment: recovering a third, genuinely unrelated ERC20 (not the
     *         alias token, not any reward token) still succeeds even when the reward carries a native
     *         leg — the check is specific to the alias token, not a blanket lockout.
     */
    function testRecover_unrelatedToken_stillAllowedAlongsideNativeLeg() public {
        Intent memory nativeLegIntent = _buildAliasIntent(
            keccak256("native-leg-unrelated"),
            RewardToken({token: address(0), rate: 0, flat: NATIVE_FLAT})
        );

        vm.prank(keeper);
        aliasIntentSource.publishAndFund{value: NATIVE_FLAT}(nativeLegIntent, false);

        TestERC20 unrelatedToken = new TestERC20("Unrelated Token", "UNRL");
        address account = aliasIntentSource.intentAccountAddress(nativeLegIntent);
        _mistakenlySend(unrelatedToken, account, MINT_AMOUNT);

        aliasIntentSource.recoverToken(
            nativeLegIntent.destination,
            keccak256(abi.encode(nativeLegIntent.route)),
            nativeLegIntent.reward,
            address(unrelatedToken)
        );

        assertEq(unrelatedToken.balanceOf(keeper), MINT_AMOUNT);
        assertEq(unrelatedToken.balanceOf(account), 0);
    }

    /**
     * @notice A native leg and an alias-token leg mirror the same underlying balance — a reward may not
     *         declare both at once. `publish` must reject it up front.
     */
    function testPublish_revertsWhenNativeAndAliasLegsBothPresent() public {
        RewardToken[] memory tokens = new RewardToken[](2);
        tokens[0] = RewardToken({token: address(0), rate: 0, flat: NATIVE_FLAT});
        tokens[1] = RewardToken({
            token: address(aliasToken),
            rate: 0,
            flat: ERC20_FLAT
        });

        Intent memory doubleLegIntent = _buildAliasIntentMultiLeg(
            keccak256("double-leg-publish"),
            tokens
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IntentLib.RewardTokensNotUnique.selector,
                address(aliasToken)
            )
        );
        vm.prank(keeper);
        aliasIntentSource.publish(doubleLegIntent);
    }

    /**
     * @notice The same guard applies on `fundFor`, which can escrow a reward directly without a prior
     *         `publish` call — the check must not be bypassable through that entry point.
     */
    function testFundFor_revertsWhenNativeAndAliasLegsBothPresent_withoutPriorPublish()
        public
    {
        RewardToken[] memory tokens = new RewardToken[](2);
        tokens[0] = RewardToken({token: address(0), rate: 0, flat: NATIVE_FLAT});
        tokens[1] = RewardToken({
            token: address(aliasToken),
            rate: 0,
            flat: ERC20_FLAT
        });

        Intent memory doubleLegIntent = _buildAliasIntentMultiLeg(
            keccak256("double-leg-fundfor"),
            tokens
        );
        bytes32 routeHash = keccak256(abi.encode(doubleLegIntent.route));

        vm.expectRevert(
            abi.encodeWithSelector(
                IntentLib.RewardTokensNotUnique.selector,
                address(aliasToken)
            )
        );
        aliasIntentSource.fundFor(
            doubleLegIntent.destination,
            routeHash,
            doubleLegIntent.reward,
            false,
            keeper,
            address(0)
        );
    }
}
