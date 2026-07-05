// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseTest} from "../BaseTest.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {IAccount} from "../../contracts/interfaces/IAccount.sol";
import {Intent, Route, Reward, RewardToken, TokenAmount, IntentLib} from "../../contracts/types/Intent.sol";
import {Call} from "../../contracts/interfaces/IRuntime.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";

/**
 * @title DualVaultRuntimeTest
 * @notice PR3 coverage: Model C chain-parameterized dual account (address separation + same-chain
 *         collapse + confusion-attack prevention), the gated fallback forwarder, recoverToken, and
 *         executeAsOwner's escrow/proof lock.
 * @dev Runs with `block.chainid == CHAIN_ID` so the default same-chain intent's `source` matches this
 *      chain — {IntentSource-executeAsOwner} is gated on `block.chainid == intent.source`.
 */
contract DualVaultRuntimeTest is BaseTest {
    ProbeRuntime internal probe;
    TestERC20 internal tokenC; // a non-reward token, for recover / owner-cook tests

    function setUp() public override {
        vm.chainId(uint256(CHAIN_ID));
        super.setUp();
        _mintAndApprove(keeper, MINT_AMOUNT);
        _fundUserNative(keeper, 10 ether);
        probe = new ProbeRuntime();
        tokenC = new TestERC20("TokenC", "TKC");
    }

    // --------------------------------------------------------------------
    // Model C — chain-parameterized dual account
    // --------------------------------------------------------------------

    /// @notice Cross-chain intent: source (escrow) and destination (execution) accounts are DISTINCT.
    function test_dualVault_crossChain_addressesSeparate() public view {
        Intent memory x = intent;
        x.source = 10;
        x.destination = 20;
        bytes32 hash = _hashIntent(x);

        address src = portal.accountAddress(hash, x.source);
        address dst = portal.accountAddress(hash, x.destination);

        assertTrue(src != dst, "cross-chain accounts must differ");
        // intentAccountAddress returns the SOURCE (escrow) account.
        assertEq(portal.intentAccountAddress(x), src);
    }

    /// @notice Same-chain intent (source == destination): the two salts collapse to ONE account.
    function test_dualVault_sameChain_collapses() public view {
        Intent memory x = intent; // source == destination == CHAIN_ID by default
        assertEq(x.source, x.destination);
        bytes32 hash = _hashIntent(x);

        address src = portal.accountAddress(hash, x.source);
        address dst = portal.accountAddress(hash, x.destination);

        assertEq(src, dst, "same-chain accounts must collapse to one address");
        assertEq(portal.intentAccountAddress(x), src);
    }

    /// @notice Source-in-hash: A->B and A'->B are distinct intents with distinct accounts.
    function test_sourceInHash_differentSourcesDiffer() public view {
        Intent memory a = intent;
        a.source = 10;
        a.destination = 20;
        Intent memory b = intent;
        b.source = 11; // different origin, same destination
        b.destination = 20;

        assertTrue(
            _hashIntent(a) != _hashIntent(b),
            "source must change the intent hash"
        );
    }

    /// @notice Confusion-attack prevention: funding the SOURCE account of an A->B intent leaves the
    ///         DESTINATION account (a different address) untouched, so a source-side op can never reach
    ///         destination-side leftovers.
    function test_confusionAttack_sourceOpCannotReachDestVault() public {
        // A->B intent whose source is THIS chain (so we can fund it here) and destination is remote.
        Intent memory x = intent;
        x.source = CHAIN_ID;
        x.destination = 777;
        x.reward = reward;

        vm.prank(keeper);
        (bytes32 hash, address srcAccount) = intentSource.publishAndFund(
            x,
            false
        );

        address dstAccount = portal.accountAddress(hash, x.destination);
        assertTrue(
            srcAccount != dstAccount,
            "source account must differ from dest"
        );

        // The escrow landed in the SOURCE account, NOT the destination account.
        assertEq(tokenA.balanceOf(srcAccount), MINT_AMOUNT);
        assertEq(tokenA.balanceOf(dstAccount), 0);
    }

    // --------------------------------------------------------------------
    // Gated fallback forwarder
    // --------------------------------------------------------------------

    /// @notice Outside an in-flight execute, any calldata to the account reverts FallbackNotInExecute.
    function test_fallback_revertsOutsideExecute() public {
        // Deploy the account (funding only sends tokens to the counterfactual address; executeAsOwner on
        // an Initial intent deploys the clone) then poke it while NO execute is on the stack. Use an
        // empty-reward variant: the AccountLocked anti-rug lock applies to Initial too (not just Funded)
        // once there are live reward legs, and this test is exercising the fallback mechanism, not the
        // lock — an empty-reward intent (like a deposit/owner-cook intent) is never locked.
        Intent memory x = intent;
        x.reward.tokens = new RewardToken[](0);
        bytes32 hash = _hashIntent(x);
        address account = portal.accountAddress(hash, x.source);
        vm.prank(keeper);
        intentSource.executeAsOwner(
            x,
            address(probe),
            abi.encodeWithSelector(ProbeRuntime.run.selector)
        );
        assertGt(account.code.length, 0, "account must be deployed");

        (bool ok, bytes memory ret) = account.call(
            abi.encodeWithSignature("anything(uint256)", uint256(1))
        );
        assertFalse(ok, "fallback must reject calldata outside execute");
        assertEq(bytes4(ret), IAccount.FallbackNotInExecute.selector);
    }

    /// @notice Bare native transfers (empty calldata) are accepted by receive() (counterfactual funding).
    function test_receive_acceptsBareNative() public {
        // Empty-reward variant — see test_fallback_revertsOutsideExecute for why.
        Intent memory x = intent;
        x.reward.tokens = new RewardToken[](0);
        bytes32 hash = _hashIntent(x);
        address account = portal.accountAddress(hash, x.source);
        // Deploy the clone first so the transfer reaches the Account's receive() (not a codeless address).
        vm.prank(keeper);
        intentSource.executeAsOwner(
            x,
            address(probe),
            abi.encodeWithSelector(ProbeRuntime.run.selector)
        );

        vm.deal(otherPerson, 1 ether);
        vm.prank(otherPerson);
        (bool ok, ) = account.call{value: 1 ether}("");
        assertTrue(ok, "receive must accept bare native");
        assertEq(account.balance, 1 ether);
    }

    /// @notice During execute, a callback re-entering the account is FORWARDED to the in-execute runtime.
    function test_fallback_forwardsCallbackDuringExecute() public {
        // executeAsOwner on an empty-reward intent is permitted regardless of status (no live escrow ever
        // possible). It deploys the source account and delegatecalls the ProbeRuntime, which calls back
        // into the account; the gated fallback forwards that callback to the ProbeRuntime, which writes a
        // sentinel to account storage.
        Intent memory x = intent;
        x.reward.tokens = new RewardToken[](0);
        bytes32 hash = _hashIntent(x);
        address account = portal.accountAddress(hash, x.source);

        vm.prank(keeper);
        intentSource.executeAsOwner(
            x,
            address(probe),
            abi.encodeWithSelector(ProbeRuntime.run.selector)
        );

        // The forwarded callback ran in the account's context and wrote the sentinel.
        assertEq(
            uint256(vm.load(account, probe.SENTINEL_SLOT())),
            probe.SENTINEL()
        );
    }

    // --------------------------------------------------------------------
    // executeAsOwner escrow/proof lock — Initial-status pre-plant regression
    // --------------------------------------------------------------------

    /// @notice Adversarial-sweep regression: a keeper cannot run executeAsOwner on an Initial (unfunded)
    ///         intent that still has live reward legs to plant a persistent side effect (e.g. an ERC20
    ///         approval) that would later let them drain escrow a solver is owed, once the intent is
    ///         funded and fulfilled. The lock must apply to Initial too, not just Funded.
    function test_executeAsOwner_lockedWhileInitial_hasLiveRewardLegs() public {
        // Status is Initial: publishAndFund/fund has NOT been called for `intent` yet.
        Call[] memory _calls = new Call[](1);
        _calls[0] = Call({
            target: address(tokenA), // tokenA is intent.reward.tokens[0].token
            value: 0,
            data: abi.encodeWithSignature(
                "approve(address,uint256)",
                keeper,
                type(uint256).max
            )
        });

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.AccountLocked.selector,
                _hashIntent(intent)
            )
        );
        intentSource.executeAsOwner(
            intent,
            address(multicallRuntime),
            abi.encode(_calls)
        );

        // Confirm no approval was planted: fund normally, then verify the keeper cannot pull the escrow
        // via the (never-granted) allowance.
        vm.prank(keeper);
        intentSource.publishAndFund(intent, false);
        address account = intentSource.intentAccountAddress(intent);
        assertEq(
            tokenA.allowance(account, keeper),
            0,
            "no approval must have been planted"
        );
        vm.expectRevert();
        vm.prank(keeper);
        tokenA.transferFrom(account, keeper, MINT_AMOUNT);
    }

    // --------------------------------------------------------------------
    // recoverToken (wrong-token rescue, reward-leg exclusion)
    // --------------------------------------------------------------------

    function test_recoverToken_rescuesStrayToken() public {
        vm.prank(keeper);
        (, address account) = intentSource.publishAndFund(intent, false);

        // A token that is NOT a reward leg gets stuck in the account.
        tokenC.mint(account, 500);

        uint256 before = tokenC.balanceOf(keeper);
        intentSource.recoverToken(
            intent.source,
            intent.destination,
            keccak256(abi.encode(intent.route)),
            intent.reward,
            address(tokenC)
        );
        assertEq(tokenC.balanceOf(keeper), before + 500);
        assertEq(tokenC.balanceOf(account), 0);
    }

    function test_recoverToken_revertsForRewardToken() public {
        vm.prank(keeper);
        intentSource.publishAndFund(intent, false);

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.InvalidRecoverToken.selector,
                address(tokenA)
            )
        );
        intentSource.recoverToken(
            intent.source,
            intent.destination,
            keccak256(abi.encode(intent.route)),
            intent.reward,
            address(tokenA) // tokenA IS a reward leg
        );
    }

    // --------------------------------------------------------------------
    // executeAsOwner — escrow/proof lock
    // --------------------------------------------------------------------

    function test_executeAsOwner_revertsForNonOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.NotAccountOwner.selector,
                otherPerson
            )
        );
        vm.prank(otherPerson);
        intentSource.executeAsOwner(intent, address(probe), "");
    }

    function test_executeAsOwner_lockedWhileFundedBeforeDeadline() public {
        vm.prank(keeper);
        intentSource.publishAndFund(intent, false); // Funded, has legs, before deadline

        bytes32 hash = _hashIntent(intent);
        vm.expectRevert(
            abi.encodeWithSelector(IIntentSource.AccountLocked.selector, hash)
        );
        vm.prank(keeper);
        intentSource.executeAsOwner(
            intent,
            address(probe),
            abi.encodeWithSelector(ProbeRuntime.run.selector)
        );
    }

    function test_executeAsOwner_lockedWhenProven() public {
        vm.prank(keeper);
        intentSource.publishAndFund(intent, false);

        bytes32 hash = _hashIntent(intent);
        _addProof(hash, CHAIN_ID, claimant); // valid proof for this destination

        vm.expectRevert(
            abi.encodeWithSelector(IIntentSource.AccountLocked.selector, hash)
        );
        vm.prank(keeper);
        intentSource.executeAsOwner(
            intent,
            address(probe),
            abi.encodeWithSelector(ProbeRuntime.run.selector)
        );
    }

    function test_executeAsOwner_allowedAfterDeadlineNoProof() public {
        vm.prank(keeper);
        (, address account) = intentSource.publishAndFund(intent, false);

        // A stray token to cook out of the account once the escrow is free.
        tokenC.mint(account, 300);

        _timeTravel(expiry + 1); // past the reward deadline, no proof -> escrow free

        Call[] memory _calls = new Call[](1);
        _calls[0] = Call({
            target: address(tokenC),
            value: 0,
            data: abi.encodeWithSignature(
                "transfer(address,uint256)",
                keeper,
                uint256(300)
            )
        });

        uint256 before = tokenC.balanceOf(keeper);
        vm.prank(keeper);
        intentSource.executeAsOwner(
            intent,
            address(multicallRuntime),
            abi.encode(_calls)
        );
        assertEq(tokenC.balanceOf(keeper), before + 300);
    }
}

/**
 * @notice Test runtime that, when delegatecalled by the Account, calls back into the Account so the gated
 *         fallback forwards the callback back to this runtime, which writes a sentinel to Account storage.
 */
contract ProbeRuntime {
    bytes32 public constant SENTINEL_SLOT = bytes32(uint256(0x1234));
    uint256 public constant SENTINEL = 0xC0FFEE;

    /// @dev Entry: reached via `Account.execute` delegatecall. `address(this)` is the Account. Calling it
    ///      with `mark()` calldata hits the Account's fallback, which (in-execute) forwards to this runtime.
    function run() external {
        (bool ok, ) = address(this).call(
            abi.encodeWithSelector(this.mark.selector)
        );
        require(ok, "callback not forwarded");
    }

    /// @dev Reached via the forwarded fallback delegatecall; runs in the Account's context.
    function mark() external {
        bytes32 slot = SENTINEL_SLOT;
        uint256 val = SENTINEL;
        assembly {
            sstore(slot, val)
        }
    }
}
