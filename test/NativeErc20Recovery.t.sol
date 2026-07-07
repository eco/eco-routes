// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./BaseTest.sol";
import {IIntentSource} from "../contracts/interfaces/IIntentSource.sol";

/**
 * @title NativeErc20RecoveryTest
 * @notice Tests for the NATIVE_ERC20 recovery-eligibility check in {IntentSource-_validateRecover}.
 * @dev The shared `portal` fixture from {BaseTest} is deployed with `nativeErc20 = address(0)`,
 *      which keeps the check fully inert (default deployment behavior). `aliasPortal` is a second
 *      deployment configured with a real ERC20 token as its native/ERC20 alias, used to exercise
 *      the check itself.
 */
contract NativeErc20RecoveryTest is BaseTest {
    Portal internal aliasPortal;
    IIntentSource internal aliasIntentSource;
    TestERC20 internal aliasToken;

    uint256 internal constant NATIVE_LEG_AMOUNT = 1 ether;

    function setUp() public override {
        super.setUp();
        _mintAndApprove(creator, MINT_AMOUNT);
        _fundUserNative(creator, 100 ether);

        vm.startPrank(deployer);
        aliasToken = new TestERC20("Alias Token", "ALIAS");
        aliasPortal = new Portal(address(aliasToken));
        vm.stopPrank();

        aliasIntentSource = IIntentSource(address(aliasPortal));
    }

    /// @notice Builds a minimal intent against `aliasPortal` with no reward tokens, only an
    ///         optional native leg, so the alias token never appears in `reward.tokens` directly.
    function _aliasIntent(
        bytes32 saltValue,
        uint256 nativeAmount
    ) internal view returns (Intent memory) {
        TokenAmount[] memory noTokens = new TokenAmount[](0);
        Call[] memory noCalls = new Call[](0);

        Route memory _route = Route({
            salt: saltValue,
            deadline: uint64(expiry),
            portal: address(aliasPortal),
            nativeAmount: 0,
            tokens: noTokens,
            calls: noCalls
        });

        Reward memory _reward = Reward({
            deadline: uint64(expiry),
            creator: creator,
            prover: address(prover),
            nativeAmount: nativeAmount,
            tokens: noTokens
        });

        return Intent({destination: CHAIN_ID, route: _route, reward: _reward});
    }

    function _publishAndFundAlias(
        Intent memory _intent
    ) internal returns (bytes32 intentHash, address vault) {
        vm.prank(creator);
        (intentHash, vault) = aliasIntentSource.publishAndFund{
            value: _intent.reward.nativeAmount
        }(_intent, false);
    }

    /// @notice On the default deployment (`nativeErc20 = address(0)`), recovering an unrelated
    ///         token mistakenly sent to a funded vault behaves exactly as before.
    function testRecover_defaultDeployment_stillWorks() public {
        _publishAndFund(intent, false);

        TestERC20 strayToken = new TestERC20("Stray Token", "STRAY");
        address vault = intentSource.intentVaultAddress(intent);
        strayToken.mint(vault, MINT_AMOUNT);

        vm.prank(creator);
        intentSource.recoverToken(
            intent.destination,
            keccak256(abi.encode(intent.route)),
            intent.reward,
            address(strayToken)
        );

        assertEq(strayToken.balanceOf(vault), 0);
        assertEq(strayToken.balanceOf(creator), MINT_AMOUNT);
    }

    /// @notice On a deployment with a configured alias, the alias token can't be recovered while
    ///         the reward still carries a non-zero native leg.
    function testRecover_aliasToken_blockedWhenNativeLegPresent() public {
        Intent memory aliasIntent = _aliasIntent(
            bytes32(uint256(1)),
            NATIVE_LEG_AMOUNT
        );
        (, address vault) = _publishAndFundAlias(aliasIntent);

        aliasToken.mint(vault, MINT_AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.InvalidRecoverToken.selector,
                address(aliasToken)
            )
        );
        vm.prank(creator);
        aliasIntentSource.recoverToken(
            aliasIntent.destination,
            keccak256(abi.encode(aliasIntent.route)),
            aliasIntent.reward,
            address(aliasToken)
        );
    }

    /// @notice The same alias token remains recoverable for an intent whose reward has no native
    ///         leg — the check only blocks recovery when there's a native amount to protect.
    function testRecover_aliasToken_allowedWhenNoNativeLeg() public {
        Intent memory aliasIntent = _aliasIntent(bytes32(uint256(2)), 0);
        (, address vault) = _publishAndFundAlias(aliasIntent);

        aliasToken.mint(vault, MINT_AMOUNT);

        vm.prank(creator);
        aliasIntentSource.recoverToken(
            aliasIntent.destination,
            keccak256(abi.encode(aliasIntent.route)),
            aliasIntent.reward,
            address(aliasToken)
        );

        assertEq(aliasToken.balanceOf(vault), 0);
        assertEq(aliasToken.balanceOf(creator), MINT_AMOUNT);
    }

    /// @notice A genuinely unrelated token — neither the alias nor a reward token — stays
    ///         recoverable even when the reward carries a native leg.
    function testRecover_unrelatedToken_stillAllowedAlongsideNativeLeg()
        public
    {
        Intent memory aliasIntent = _aliasIntent(
            bytes32(uint256(3)),
            NATIVE_LEG_AMOUNT
        );
        (, address vault) = _publishAndFundAlias(aliasIntent);

        TestERC20 unrelatedToken = new TestERC20("Unrelated Token", "UNRL");
        unrelatedToken.mint(vault, MINT_AMOUNT);

        vm.prank(creator);
        aliasIntentSource.recoverToken(
            aliasIntent.destination,
            keccak256(abi.encode(aliasIntent.route)),
            aliasIntent.reward,
            address(unrelatedToken)
        );

        assertEq(unrelatedToken.balanceOf(vault), 0);
        assertEq(unrelatedToken.balanceOf(creator), MINT_AMOUNT);
    }
}
