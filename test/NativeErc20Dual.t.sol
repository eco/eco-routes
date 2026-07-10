// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./BaseTest.sol";
import {MockDualInterfaceToken} from "./mocks/MockDualInterfaceToken.sol";
import {PortalRecoverHarness} from "./mocks/PortalRecoverHarness.sol";
import {IIntentSource} from "../contracts/interfaces/IIntentSource.sol";
import {IVault} from "../contracts/interfaces/IVault.sol";
import {PortalTron} from "../contracts/PortalTron.sol";
import {IOriginSettler} from "../contracts/interfaces/ERC7683/IOriginSettler.sol";
import {GaslessCrossChainOrder, OnchainCrossChainOrder, OrderData, Output, ORDER_DATA_TYPEHASH} from "../contracts/types/ERC7683.sol";

/**
 * @title NativeErc20DualTest
 * @notice The tests the existing {NativeErc20RecoveryTest} cannot express. That suite uses a plain
 *         {TestERC20} whose token balance is an independent mapping, so it can only prove the
 *         native-alias guard "reverts on declaration" — never that, absent the guard, a native
 *         reward really walks out through the ERC20 interface.
 *
 *         This suite drives a {MockDualInterfaceToken}: an ERC20 whose `balanceOf(a)` IS `a.balance`
 *         and whose `transfer` moves native — the Arc double-count, where the native asset and a
 *         specific ERC20 (USDC) are two views of ONE balance. That makes the drain path real, so we
 *         can show it is OPEN before the fix (via {PortalRecoverHarness}, which is `recoverToken`
 *         minus the guard) and CLOSED after it, and can exercise the valid reward shapes
 *         (native-only, alias-ERC20-leg-only) end-to-end (fund → withdraw → refund) on an
 *         alias-configured deployment.
 *
 * @dev Coverage map (mirrors the PR review's three-shape table):
 *      - MOCK SANITY: the dual token genuinely aliases native (grounds every test below).
 *      - P1 EXPLOIT: native reward drainable via the alias before the fix; blocked after.
 *      - P1 ROW 2  : alias-ERC20-leg-only reward funds/withdraws/refunds; its recover is blocked
 *                    by the existing reward-tokens loop.
 *      - P2 ROW 1  : native-only reward withdraw/refund payouts on an alias deployment.
 *      - P2 7683   : the guard fires on publishAndFund / publishAndFundFor / signed openFor.
 *      - P3        : alias token at a non-zero leg index; partial funding; PortalTron.
 */
contract NativeErc20DualTest is BaseTest {
    MockDualInterfaceToken internal dual; // the Arc-like native alias (USDC)
    Portal internal aliasPortal; // deployed with `dual` as NATIVE_ERC20
    IIntentSource internal aliasSource;

    uint256 internal constant NATIVE_REWARD = 2 ether;
    uint256 internal constant LEG_AMOUNT = 500; // small vs. the actors' native balances

    function setUp() public override {
        super.setUp();

        vm.startPrank(deployer);
        dual = new MockDualInterfaceToken("Arc USDC", "USDC");
        aliasPortal = new Portal(address(dual));
        vm.stopPrank();

        aliasSource = IIntentSource(address(aliasPortal));

        // The dual token's balance IS native, so fund actors with native to give them "USDC".
        _fundUserNative(creator, 100 ether);
        _fundUserNative(claimant, 1 ether);
        _fundUserNative(otherPerson, 10 ether);
    }

    // ------------------------------------------------------------------ helpers

    function _oneLeg(
        address token,
        uint256 amount
    ) internal pure returns (TokenAmount[] memory legs) {
        legs = new TokenAmount[](1);
        legs[0] = TokenAmount({token: token, amount: amount});
    }

    /// @notice Builds a minimal (no calls) intent against `portalAddr`, salt-keyed for a unique hash.
    function _intentOn(
        address portalAddr,
        bytes32 saltValue,
        uint256 nativeAmount,
        TokenAmount[] memory rewardLegs
    ) internal view returns (Intent memory) {
        Route memory _route = Route({
            salt: saltValue,
            deadline: uint64(expiry),
            portal: portalAddr,
            nativeAmount: 0,
            tokens: new TokenAmount[](0),
            calls: new Call[](0)
        });

        Reward memory _reward = Reward({
            deadline: uint64(expiry),
            creator: creator,
            prover: address(prover),
            nativeAmount: nativeAmount,
            tokens: rewardLegs
        });

        return Intent({destination: CHAIN_ID, route: _route, reward: _reward});
    }

    function _routeHash(Intent memory _intent) internal pure returns (bytes32) {
        return keccak256(abi.encode(_intent.route));
    }

    /// @notice Approves `aliasPortal` to pull `amount` of the dual token from `creator`.
    function _approveDual(uint256 amount) internal {
        vm.prank(creator);
        dual.approve(address(aliasPortal), amount);
    }

    // ==================================================================== MOCK SANITY

    /// @notice The dual token's ERC20 balance mirrors native, and transferring it moves native on
    ///         both sides. Without this, every drain assertion below would be meaningless.
    function testMock_erc20BalanceMirrorsNative() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        vm.deal(alice, 5 ether);
        vm.deal(bob, 0);

        // ERC20 view == native balance.
        assertEq(dual.balanceOf(alice), 5 ether);
        assertEq(dual.balanceOf(bob), 0);

        // An ERC20 transfer moves native.
        vm.prank(alice);
        dual.transfer(bob, 2 ether);

        assertEq(alice.balance, 3 ether);
        assertEq(bob.balance, 2 ether);
        assertEq(dual.balanceOf(alice), 3 ether);
        assertEq(dual.balanceOf(bob), 2 ether);

        // A real native payout is reflected in the ERC20 view too — one balance, two interfaces.
        vm.deal(bob, bob.balance + 1 ether);
        assertEq(dual.balanceOf(bob), 3 ether);
    }

    // ==================================================================== P1 EXPLOIT REGRESSION

    /// @notice BEFORE THE FIX: a native reward can be clawed back through the alias-ERC20 interface.
    ///         `recoverToken` is meant to reclaim only *mistaken* transfers — never reward funds — but
    ///         because the alias token's balance IS the vault's native balance, recovering the alias
    ///         drains the escrowed native reward (here, back to the creator). {PortalRecoverHarness}
    ///         is `recoverToken` with the eligibility guard removed, i.e. the pre-fix code path.
    function testExploit_nativeRewardDrainableViaAliasBeforeFix() public {
        vm.prank(deployer);
        PortalRecoverHarness unfixed = new PortalRecoverHarness(address(dual));

        Intent memory nativeReward = _intentOn(
            address(unfixed),
            keccak256("exploit-before"),
            NATIVE_REWARD,
            new TokenAmount[](0)
        );

        vm.prank(creator);
        IIntentSource(address(unfixed)).publishAndFund{value: NATIVE_REWARD}(
            nativeReward,
            false
        );

        address vault = IIntentSource(address(unfixed)).intentVaultAddress(
            nativeReward
        );
        assertEq(
            vault.balance,
            NATIVE_REWARD,
            "vault escrows the native reward"
        );
        assertEq(
            dual.balanceOf(vault),
            NATIVE_REWARD,
            "alias view sees the same balance"
        );

        uint256 creatorBefore = creator.balance;

        // The drain: recover the alias token. No guard -> vault.recover moves the native out.
        unfixed.recoverTokenUnsafe(
            nativeReward.destination,
            _routeHash(nativeReward),
            nativeReward.reward,
            address(dual)
        );

        assertEq(vault.balance, 0, "native reward drained out of the vault");
        assertEq(
            creator.balance,
            creatorBefore + NATIVE_REWARD,
            "reward clawed back to the creator via the ERC20 door"
        );
    }

    /// @notice AFTER THE FIX: the identical recovery on a stock {Portal} is rejected up front, and the
    ///         native reward stays escrowed for the solver.
    function testExploit_nativeRewardRecoverBlockedAfterFix() public {
        // reward.tokens is EMPTY, so the reward-tokens loop and the zero-address check in
        // _validateRecover cannot fire for `dual`; the revert below is attributable solely to the
        // native-alias branch the fix added.
        Intent memory nativeReward = _intentOn(
            address(aliasPortal),
            keccak256("exploit-after"),
            NATIVE_REWARD,
            new TokenAmount[](0)
        );

        vm.prank(creator);
        aliasSource.publishAndFund{value: NATIVE_REWARD}(nativeReward, false);

        address vault = aliasSource.intentVaultAddress(nativeReward);
        assertEq(vault.balance, NATIVE_REWARD);

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.InvalidRecoverToken.selector,
                address(dual)
            )
        );
        aliasSource.recoverToken(
            nativeReward.destination,
            _routeHash(nativeReward),
            nativeReward.reward,
            address(dual)
        );

        assertEq(vault.balance, NATIVE_REWARD, "reward remains escrowed");
    }

    // ==================================================================== P1 ROW 2: alias-ERC20-leg-only

    /// @notice A reward whose only leg is the alias token (nativeAmount == 0) is a valid shape — the
    ///         guard is inert. It funds by moving real native creator -> vault, and withdraws that
    ///         native out to the claimant through the ERC20 interface.
    function testRow2_aliasErc20LegOnly_fundsAndWithdrawsToClaimant() public {
        Intent memory legIntent = _intentOn(
            address(aliasPortal),
            keccak256("row2-withdraw"),
            0,
            _oneLeg(address(dual), LEG_AMOUNT)
        );

        _approveDual(LEG_AMOUNT);
        vm.prank(creator);
        aliasSource.publishAndFund(legIntent, false);

        address vault = aliasSource.intentVaultAddress(legIntent);
        assertTrue(
            aliasSource.isIntentFunded(legIntent),
            "leg funded from native"
        );
        assertEq(
            vault.balance,
            LEG_AMOUNT,
            "funding moved native into the vault"
        );

        bytes32 intentHash = _hashIntent(legIntent);
        _addProof(intentHash, CHAIN_ID, claimant);

        uint256 claimantBefore = claimant.balance;
        vm.prank(otherPerson);
        aliasSource.withdraw(
            legIntent.destination,
            _routeHash(legIntent),
            legIntent.reward
        );

        assertEq(vault.balance, 0, "vault emptied on withdraw");
        assertEq(
            claimant.balance,
            claimantBefore + LEG_AMOUNT,
            "claimant paid the alias leg as native"
        );
        assertFalse(aliasSource.isIntentFunded(legIntent));
    }

    /// @notice The same alias-ERC20-leg-only reward refunds its native back to the creator after the
    ///         deadline passes without a proof.
    function testRow2_aliasErc20LegOnly_refundsToCreatorAfterExpiry() public {
        Intent memory legIntent = _intentOn(
            address(aliasPortal),
            keccak256("row2-refund"),
            0,
            _oneLeg(address(dual), LEG_AMOUNT)
        );

        _approveDual(LEG_AMOUNT);
        vm.prank(creator);
        aliasSource.publishAndFund(legIntent, false);

        address vault = aliasSource.intentVaultAddress(legIntent);
        assertEq(vault.balance, LEG_AMOUNT);

        _timeTravel(expiry + 1);

        uint256 creatorBefore = creator.balance;
        vm.prank(otherPerson);
        aliasSource.refund(
            legIntent.destination,
            _routeHash(legIntent),
            legIntent.reward
        );

        assertEq(vault.balance, 0, "vault swept on refund");
        assertEq(
            creator.balance,
            creatorBefore + LEG_AMOUNT,
            "alias leg refunded to creator as native"
        );
    }

    /// @notice When the alias token is a *declared reward leg* (nativeAmount == 0), recovering it is
    ///         blocked by the existing reward-tokens loop — the same-asset branch is not even reached.
    function testRow2_aliasErc20Leg_recoverBlockedByRewardTokensLoop() public {
        Intent memory legIntent = _intentOn(
            address(aliasPortal),
            keccak256("row2-recover"),
            0,
            _oneLeg(address(dual), LEG_AMOUNT)
        );

        _approveDual(LEG_AMOUNT);
        vm.prank(creator);
        aliasSource.publishAndFund(legIntent, false);

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.InvalidRecoverToken.selector,
                address(dual)
            )
        );
        aliasSource.recoverToken(
            legIntent.destination,
            _routeHash(legIntent),
            legIntent.reward,
            address(dual)
        );
    }

    // ==================================================================== P2 ROW 1: native-only payouts

    /// @notice A native-only reward withdraws to the claimant on an alias-configured deployment.
    function testNativeOnly_withdrawPaysClaimant_onAliasDeployment() public {
        Intent memory nativeReward = _intentOn(
            address(aliasPortal),
            keccak256("native-withdraw"),
            NATIVE_REWARD,
            new TokenAmount[](0)
        );

        vm.prank(creator);
        aliasSource.publishAndFund{value: NATIVE_REWARD}(nativeReward, false);

        address vault = aliasSource.intentVaultAddress(nativeReward);
        assertEq(vault.balance, NATIVE_REWARD);

        bytes32 intentHash = _hashIntent(nativeReward);
        _addProof(intentHash, CHAIN_ID, claimant);

        uint256 claimantBefore = claimant.balance;
        vm.prank(otherPerson);
        aliasSource.withdraw(
            nativeReward.destination,
            _routeHash(nativeReward),
            nativeReward.reward
        );

        assertEq(claimant.balance, claimantBefore + NATIVE_REWARD);
        assertFalse(aliasSource.isIntentFunded(nativeReward));
    }

    /// @notice A native-only reward refunds to the creator after expiry on an alias deployment.
    function testNativeOnly_refundReturnsToCreator_onAliasDeployment() public {
        Intent memory nativeReward = _intentOn(
            address(aliasPortal),
            keccak256("native-refund"),
            NATIVE_REWARD,
            new TokenAmount[](0)
        );

        vm.prank(creator);
        aliasSource.publishAndFund{value: NATIVE_REWARD}(nativeReward, false);

        address vault = aliasSource.intentVaultAddress(nativeReward);
        assertEq(vault.balance, NATIVE_REWARD);

        _timeTravel(expiry + 1);

        uint256 creatorBefore = creator.balance;
        vm.prank(otherPerson);
        aliasSource.refund(
            nativeReward.destination,
            _routeHash(nativeReward),
            nativeReward.reward
        );

        assertEq(vault.balance, 0);
        assertEq(creator.balance, creatorBefore + NATIVE_REWARD);
    }

    // ==================================================================== P2 7683: guard on every entry

    /// @notice The guard fires on `publishAndFund` — a native amount plus an alias-token leg is rejected.
    function testPublishAndFund_revertsOnNativePlusAliasLeg() public {
        Intent memory conflict = _intentOn(
            address(aliasPortal),
            keccak256("paf-conflict"),
            NATIVE_REWARD,
            _oneLeg(address(dual), LEG_AMOUNT)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.RewardTokensNotUnique.selector,
                address(dual)
            )
        );
        vm.prank(creator);
        aliasSource.publishAndFund{value: NATIVE_REWARD}(conflict, false);
    }

    /// @notice The guard fires on `publishAndFundFor`, the funded-on-behalf entry point.
    function testPublishAndFundFor_revertsOnNativePlusAliasLeg() public {
        Intent memory conflict = _intentOn(
            address(aliasPortal),
            keccak256("paff-conflict"),
            NATIVE_REWARD,
            _oneLeg(address(dual), LEG_AMOUNT)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.RewardTokensNotUnique.selector,
                address(dual)
            )
        );
        vm.prank(otherPerson);
        aliasSource.publishAndFundFor{value: NATIVE_REWARD}(
            conflict,
            false,
            creator,
            address(0)
        );
    }

    /// @notice The guard fires on the gasless ERC-7683 `openFor` path — the untrusted-input surface
    ///         where a solver submits a user's signed order. A native+alias-leg reward is rejected
    ///         before any funds move.
    function testOpenFor_revertsOnNativePlusAliasLeg() public {
        (address user, uint256 userPk) = makeAddrAndKey("gaslessUser");

        // The conflicting reward, carried inside the signed order.
        Reward memory conflictReward = Reward({
            deadline: uint64(expiry),
            creator: user,
            prover: address(prover),
            nativeAmount: NATIVE_REWARD,
            tokens: _oneLeg(address(dual), LEG_AMOUNT)
        });

        Route memory orderRoute = Route({
            salt: keccak256("openfor-conflict"),
            deadline: uint64(expiry),
            portal: address(aliasPortal),
            nativeAmount: 0,
            tokens: new TokenAmount[](0),
            calls: new Call[](0)
        });

        OrderData memory od = OrderData({
            destination: CHAIN_ID,
            route: abi.encode(orderRoute),
            reward: conflictReward,
            routePortal: bytes32(uint256(uint160(address(aliasPortal)))),
            routeDeadline: uint64(expiry),
            maxSpent: new Output[](0)
        });
        bytes memory orderData = abi.encode(od);

        GaslessCrossChainOrder memory order = GaslessCrossChainOrder({
            originSettler: address(aliasPortal),
            user: user,
            nonce: 1,
            originChainId: block.chainid,
            openDeadline: uint32(block.timestamp + 3600),
            fillDeadline: uint32(block.timestamp + 7200),
            orderDataType: ORDER_DATA_TYPEHASH,
            orderData: orderData
        });

        bytes32 structHash = keccak256(
            abi.encode(
                aliasPortal.GASLESS_CROSSCHAIN_ORDER_TYPEHASH(),
                order.originSettler,
                order.user,
                order.nonce,
                order.originChainId,
                order.openDeadline,
                order.fillDeadline,
                order.orderDataType,
                keccak256(order.orderData)
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked(
                hex"1901",
                aliasPortal.domainSeparatorV4(),
                structHash
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.RewardTokensNotUnique.selector,
                address(dual)
            )
        );
        vm.prank(otherPerson); // the solver submits the user's signed order
        aliasPortal.openFor{value: NATIVE_REWARD}(order, signature, "");
    }

    /// @notice The guard also fires on the onchain ERC-7683 `open` path (user is msg.sender), the
    ///         sibling of the gasless `openFor` entry point.
    function testOpen_revertsOnNativePlusAliasLeg() public {
        Reward memory conflictReward = Reward({
            deadline: uint64(expiry),
            creator: creator,
            prover: address(prover),
            nativeAmount: NATIVE_REWARD,
            tokens: _oneLeg(address(dual), LEG_AMOUNT)
        });

        Route memory orderRoute = Route({
            salt: keccak256("open-conflict"),
            deadline: uint64(expiry),
            portal: address(aliasPortal),
            nativeAmount: 0,
            tokens: new TokenAmount[](0),
            calls: new Call[](0)
        });

        OrderData memory od = OrderData({
            destination: CHAIN_ID,
            route: abi.encode(orderRoute),
            reward: conflictReward,
            routePortal: bytes32(uint256(uint160(address(aliasPortal)))),
            routeDeadline: uint64(expiry),
            maxSpent: new Output[](0)
        });

        OnchainCrossChainOrder memory order = OnchainCrossChainOrder({
            fillDeadline: uint32(block.timestamp + 7200),
            orderDataType: ORDER_DATA_TYPEHASH,
            orderData: abi.encode(od)
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.RewardTokensNotUnique.selector,
                address(dual)
            )
        );
        vm.prank(creator);
        aliasPortal.open{value: NATIVE_REWARD}(order);
    }

    // ==================================================================== VALID MULTI-LEG COEXISTENCE

    /// @notice A valid reward may carry the alias token as ONE leg beside an ordinary ERC20 leg (with
    ///         no native amount). A single withdraw must pay the ordinary leg from its own token
    ///         balance AND the alias leg as native — proving per-leg payout is correct when the alias
    ///         sits at a non-zero index of a funded, withdrawable reward (not just a revert case).
    function testRow2_aliasLegPlusRealErc20Leg_fundsAndWithdraws() public {
        uint256 tokenLeg = MINT_AMOUNT;

        TokenAmount[] memory legs = new TokenAmount[](2);
        legs[0] = TokenAmount({token: address(tokenA), amount: tokenLeg});
        legs[1] = TokenAmount({token: address(dual), amount: LEG_AMOUNT});

        Intent memory coexist = _intentOn(
            address(aliasPortal),
            keccak256("coexist"),
            0,
            legs
        );

        // creator must fund both legs: tokenA (real ERC20) and dual (native), each approved to aliasPortal.
        vm.startPrank(creator);
        tokenA.mint(creator, tokenLeg);
        tokenA.approve(address(aliasPortal), tokenLeg);
        dual.approve(address(aliasPortal), LEG_AMOUNT);
        vm.stopPrank();

        vm.prank(creator);
        aliasSource.publishAndFund(coexist, false);

        address vault = aliasSource.intentVaultAddress(coexist);
        assertTrue(aliasSource.isIntentFunded(coexist));
        assertEq(tokenA.balanceOf(vault), tokenLeg, "real ERC20 leg escrowed");
        assertEq(vault.balance, LEG_AMOUNT, "alias leg escrowed as native");

        bytes32 intentHash = _hashIntent(coexist);
        _addProof(intentHash, CHAIN_ID, claimant);

        uint256 claimantNativeBefore = claimant.balance;
        vm.prank(otherPerson);
        aliasSource.withdraw(
            coexist.destination,
            _routeHash(coexist),
            coexist.reward
        );

        assertEq(
            tokenA.balanceOf(claimant),
            tokenLeg,
            "ordinary leg paid in tokens"
        );
        assertEq(
            claimant.balance,
            claimantNativeBefore + LEG_AMOUNT,
            "alias leg paid as native"
        );
        assertEq(tokenA.balanceOf(vault), 0);
        assertEq(vault.balance, 0);
    }

    // ==================================================================== DEFAULT-DEPLOYMENT INERTNESS

    /// @notice On a default deployment (`NATIVE_ERC20 == address(0)`), the funding guard is inert: a
    ///         legitimate reward with BOTH a native amount and an ordinary ERC20 leg funds normally.
    ///         Guards against the fix over-blocking normal (non-alias) chains.
    function testDefaultDeployment_nativePlusErc20LegAllowed() public {
        _mintAndApprove(creator, MINT_AMOUNT); // approves the default `portal` for tokenA

        Intent memory ok = _intentOn(
            address(portal),
            keccak256("default-native-plus-erc20"),
            NATIVE_REWARD,
            _oneLeg(address(tokenA), MINT_AMOUNT)
        );

        vm.prank(creator);
        intentSource.publishAndFund{value: NATIVE_REWARD}(ok, false);

        assertTrue(
            intentSource.isIntentFunded(ok),
            "native+ERC20 reward funds on a default deployment"
        );
    }

    // ==================================================================== P3: index / partial / Tron

    /// @notice The guard scans every leg, not just index 0 — an alias token at a non-zero index still
    ///         collides with a native amount.
    function testGuard_scansAllLegs_aliasAtNonZeroIndex() public {
        TokenAmount[] memory legs = new TokenAmount[](2);
        legs[0] = TokenAmount({token: address(tokenA), amount: LEG_AMOUNT});
        legs[1] = TokenAmount({token: address(dual), amount: LEG_AMOUNT});

        Intent memory conflict = _intentOn(
            address(aliasPortal),
            keccak256("nonzero-index"),
            NATIVE_REWARD,
            legs
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.RewardTokensNotUnique.selector,
                address(dual)
            )
        );
        vm.prank(creator);
        aliasSource.publish(conflict);
    }

    /// @notice Partial funding of an alias-ERC20 leg behaves consistently: the vault's native balance
    ///         tracks exactly what was funded, and the intent is not marked fully funded.
    function testPartialFunding_aliasErc20Leg() public {
        Intent memory legIntent = _intentOn(
            address(aliasPortal),
            keccak256("partial"),
            0,
            _oneLeg(address(dual), LEG_AMOUNT)
        );

        // Approve only half, so only half the leg can be pulled.
        _approveDual(LEG_AMOUNT / 2);
        vm.prank(creator);
        aliasSource.publishAndFund(legIntent, true);

        address vault = aliasSource.intentVaultAddress(legIntent);
        assertEq(
            vault.balance,
            LEG_AMOUNT / 2,
            "vault holds the partially funded native"
        );
        assertEq(dual.balanceOf(vault), LEG_AMOUNT / 2, "alias view agrees");
        assertFalse(
            aliasSource.isIntentFunded(legIntent),
            "not fully funded on a partial fund"
        );
    }

    /// @notice The Tron portal variant received the same constructor change; its guard fires on a
    ///         native+alias-leg reward too (publish rejects before any vault work).
    function testPortalTron_guardRevertsOnNativePlusAliasLeg() public {
        vm.prank(deployer);
        PortalTron tronPortal = new PortalTron(address(dual));

        Intent memory conflict = _intentOn(
            address(tronPortal),
            keccak256("tron-conflict"),
            NATIVE_REWARD,
            _oneLeg(address(dual), LEG_AMOUNT)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.RewardTokensNotUnique.selector,
                address(dual)
            )
        );
        vm.prank(creator);
        IIntentSource(address(tronPortal)).publish(conflict);
    }
}
