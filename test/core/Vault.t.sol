// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Vault} from "../../contracts/vault/Vault.sol";
import {VaultTron} from "../../contracts/vault/VaultTron.sol";
import {IVault} from "../../contracts/interfaces/IVault.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {IPermit} from "../../contracts/interfaces/IPermit.sol";
import {IPolicy} from "../../contracts/interfaces/IPolicy.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";
import {TestPolicy} from "../../contracts/test/TestPolicy.sol";
import {TronUSDTMock} from "../../contracts/test/TronUSDTMock.sol";
import {Reward, RewardToken} from "../../contracts/types/Intent.sol";
import {Clones} from "../../contracts/vault/Clones.sol";

contract MockPermit is IPermit {
    mapping(address => mapping(address => mapping(address => uint160)))
        public allowances;

    function setAllowance(
        address owner,
        address token,
        address spender,
        uint160 amount
    ) external {
        allowances[owner][token][spender] = amount;
    }

    function allowance(
        address owner,
        address token,
        address spender
    ) external view override returns (uint160, uint48, uint48) {
        return (allowances[owner][token][spender], 0, 0);
    }

    function transferFrom(
        address from,
        address to,
        uint160 amount,
        address token
    ) external override {
        require(
            allowances[from][token][to] >= amount,
            "Insufficient permit allowance"
        );
        allowances[from][token][to] -= amount;
        IERC20(token).transferFrom(from, to, amount);
    }

    function transferFrom(
        AllowanceTransferDetails[] calldata transferDetails
    ) external override {
        for (uint256 i = 0; i < transferDetails.length; i++) {
            AllowanceTransferDetails calldata detail = transferDetails[i];
            require(
                allowances[detail.from][detail.token][detail.to] >=
                    detail.amount,
                "Insufficient permit allowance"
            );
            allowances[detail.from][detail.token][detail.to] -= detail.amount;
            IERC20(detail.token).transferFrom(
                detail.from,
                detail.to,
                detail.amount
            );
        }
    }
}

contract VaultTest is Test {
    using Clones for address;

    IVault internal vault;
    TestERC20 internal token;
    MockPermit internal mockPermit;
    TestPolicy internal prover;

    address internal portal;
    address internal creator;
    address internal claimant;
    address internal unauthorized;

    function setUp() public {
        portal = makeAddr("portal");
        creator = makeAddr("creator");
        claimant = makeAddr("claimant");
        unauthorized = makeAddr("unauthorized");

        vm.prank(portal);
        vault = IVault(address(new Vault()).clone(bytes32(0)));

        token = new TestERC20("Test Token", "TEST");
        mockPermit = new MockPermit();

        // The Vault now consults `reward.prover.previewRelease(...)` during withdraw, so
        // every reward literal points at a real prover deployed here.
        prover = new TestPolicy(portal);
    }

    /// @dev Per-leg escrow target for `fundFor`: the fixed `flat` of each reward leg. With rate:0
    ///      legs this reproduces every fund test's fixed-amount semantics.
    function _targets(
        Reward memory reward
    ) internal pure returns (uint256[] memory t) {
        t = new uint256[](reward.tokens.length);
        for (uint256 i; i < reward.tokens.length; ++i)
            t[i] = reward.tokens[i].flat;
    }

    /// @dev Empty core-verified fulfilled[] — previewRelease then returns each leg's `flat`, so
    ///      the payout equals the old fixed amounts.
    function _noFulfilled() internal pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    function test_constructor_setsPortalCorrectly() public {
        RewardToken[] memory tokens = new RewardToken[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens
        });

        vm.prank(portal);
        assertTrue(
            vault.fundFor(reward, _targets(reward), creator, IPermit(address(0)))
        );

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.NotPortalCaller.selector,
                unauthorized
            )
        );
        vault.fundFor(reward, _targets(reward), creator, IPermit(address(0)));
    }

    function test_fundFor_success_emptyReward() public {
        RewardToken[] memory tokens = new RewardToken[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens
        });

        vm.prank(portal);
        bool result = vault.fundFor(
            reward,
            _targets(reward),
            creator,
            IPermit(address(0))
        );

        assertTrue(result);
    }

    function test_fundFor_success_nativeAndTokens() public {
        RewardToken[] memory tokens = new RewardToken[](2);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});
        tokens[1] = RewardToken({token: address(0), rate: 0, flat: 1 ether});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens
        });

        token.mint(creator, 1000);
        vm.prank(creator);
        token.approve(address(vault), 1000);

        vm.deal(portal, 2 ether);
        vm.prank(portal);
        bool result = vault.fundFor{value: 1 ether}(
            reward,
            _targets(reward),
            creator,
            IPermit(address(0))
        );

        assertTrue(result);
        assertEq(address(vault).balance, 1 ether);
        assertEq(token.balanceOf(address(vault)), 1000);
    }

    function test_fundFor_partialFunding_insufficientNative() public {
        RewardToken[] memory tokens = new RewardToken[](1);
        tokens[0] = RewardToken({token: address(0), rate: 0, flat: 2 ether});
        Reward memory reward = Reward({
            creator: creator,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens
        });

        vm.deal(portal, 1 ether);
        vm.prank(portal);
        bool result = vault.fundFor{value: 1 ether}(
            reward,
            _targets(reward),
            creator,
            IPermit(address(0))
        );

        assertFalse(result);
        assertEq(address(vault).balance, 1 ether);
    }

    function test_fundFor_partialFunding_insufficientTokens() public {
        RewardToken[] memory tokens = new RewardToken[](1);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 2000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens
        });

        token.mint(creator, 1000);
        vm.prank(creator);
        token.approve(address(vault), 1000);

        vm.prank(portal);
        bool result = vault.fundFor(
            reward,
            _targets(reward),
            creator,
            IPermit(address(0))
        );

        assertFalse(result);
        assertEq(token.balanceOf(address(vault)), 1000);
    }

    function test_fundFor_success_multipleTokens() public {
        IERC20 token2 = new TestERC20("Test Token 2", "TEST2");

        RewardToken[] memory tokens = new RewardToken[](2);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});
        tokens[1] = RewardToken({token: address(token2), rate: 0, flat: 500});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens
        });

        token.mint(creator, 1000);
        vm.prank(creator);
        token.approve(address(vault), 1000);

        TestERC20(address(token2)).mint(creator, 500);
        vm.prank(creator);
        token2.approve(address(vault), 500);

        vm.prank(portal);
        bool result = vault.fundFor(
            reward,
            _targets(reward),
            creator,
            IPermit(address(0))
        );

        assertTrue(result);
        assertEq(token.balanceOf(address(vault)), 1000);
        assertEq(token2.balanceOf(address(vault)), 500);
    }

    function test_fundFor_not_portal_caller() public {
        RewardToken[] memory tokens = new RewardToken[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens
        });

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.NotPortalCaller.selector,
                unauthorized
            )
        );
        vault.fundFor(reward, _targets(reward), creator, IPermit(address(0)));
    }

    function test_fundFor_success_prefundedVault() public {
        RewardToken[] memory tokens = new RewardToken[](2);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});
        tokens[1] = RewardToken({token: address(0), rate: 0, flat: 1 ether});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens
        });

        token.mint(address(vault), 1000);
        vm.deal(address(vault), 1 ether);

        vm.prank(portal);
        bool result = vault.fundFor(
            reward,
            _targets(reward),
            creator,
            IPermit(address(0))
        );

        assertTrue(result);
        assertEq(address(vault).balance, 1 ether);
        assertEq(token.balanceOf(address(vault)), 1000);
    }

    function test_fundFor_success_partiallyPrefunded() public {
        RewardToken[] memory tokens = new RewardToken[](2);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});
        tokens[1] = RewardToken({token: address(0), rate: 0, flat: 1 ether});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens
        });

        token.mint(address(vault), 500);
        vm.deal(address(vault), 0.5 ether);

        token.mint(creator, 500);
        vm.prank(creator);
        token.approve(address(vault), 500);

        vm.deal(portal, 1 ether);
        vm.prank(portal);
        bool result = vault.fundFor{value: 0.5 ether}(
            reward,
            _targets(reward),
            creator,
            IPermit(address(0))
        );

        assertTrue(result);
        assertEq(address(vault).balance, 1 ether);
        assertEq(token.balanceOf(address(vault)), 1000);
    }

    function test_fundFor_success_withPermit() public {
        RewardToken[] memory tokens = new RewardToken[](1);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens
        });

        token.mint(creator, 1000);
        vm.prank(creator);
        token.approve(address(mockPermit), 1000);

        mockPermit.setAllowance(creator, address(token), address(vault), 1000);

        vm.prank(portal);
        bool result = vault.fundFor(
            reward,
            _targets(reward),
            creator,
            IPermit(address(mockPermit))
        );

        assertTrue(result);
        assertEq(token.balanceOf(address(vault)), 1000);
        assertEq(token.balanceOf(creator), 0);
    }

    function test_fundFor_success_withPermit_partialFromPermit() public {
        RewardToken[] memory tokens = new RewardToken[](1);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens
        });

        token.mint(creator, 1000);
        vm.prank(creator);
        token.approve(address(vault), 500);
        vm.prank(creator);
        token.approve(address(mockPermit), 500);

        mockPermit.setAllowance(creator, address(token), address(vault), 500);

        vm.prank(portal);
        bool result = vault.fundFor(
            reward,
            _targets(reward),
            creator,
            IPermit(address(mockPermit))
        );

        assertTrue(result);
        assertEq(token.balanceOf(address(vault)), 1000);
        assertEq(token.balanceOf(creator), 0);
    }

    function test_fundFor_success_withPermit_fallbackToRegularApproval()
        public
    {
        RewardToken[] memory tokens = new RewardToken[](1);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens
        });

        token.mint(creator, 1000);
        vm.prank(creator);
        token.approve(address(vault), 1000);

        vm.prank(portal);
        bool result = vault.fundFor(
            reward,
            _targets(reward),
            creator,
            IPermit(address(mockPermit))
        );

        assertTrue(result);
        assertEq(token.balanceOf(address(vault)), 1000);
        assertEq(token.balanceOf(creator), 0);
    }

    function test_fundFor_partial_withPermit_insufficientPermitAllowance()
        public
    {
        RewardToken[] memory tokens = new RewardToken[](1);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens
        });

        token.mint(creator, 1000);
        vm.prank(creator);
        token.approve(address(mockPermit), 500);

        mockPermit.setAllowance(creator, address(token), address(vault), 500);

        vm.prank(portal);
        bool result = vault.fundFor(
            reward,
            _targets(reward),
            creator,
            IPermit(address(mockPermit))
        );

        assertFalse(result);
        assertEq(token.balanceOf(address(vault)), 500);
        assertEq(token.balanceOf(creator), 500);
    }

    function test_withdraw_success_emptyReward() public {
        RewardToken[] memory tokens = new RewardToken[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens
        });

        vm.prank(portal);
        vault.withdraw(reward, claimant, _noFulfilled());
    }

    function test_withdraw_success_nativeAndTokens() public {
        RewardToken[] memory tokens = new RewardToken[](2);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});
        tokens[1] = RewardToken({token: address(0), rate: 0, flat: 1 ether});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens
        });

        token.mint(address(vault), 1000);
        vm.deal(address(vault), 1 ether);

        uint256 claimantInitialBalance = claimant.balance;

        vm.prank(portal);
        vault.withdraw(reward, claimant, _noFulfilled());

        assertEq(address(vault).balance, 0);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(claimant.balance, claimantInitialBalance + 1 ether);
        assertEq(token.balanceOf(claimant), 1000);
    }

    function test_withdraw_success_multipleTokens() public {
        IERC20 token2 = new TestERC20("Test Token 2", "TEST2");

        RewardToken[] memory tokens = new RewardToken[](2);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});
        tokens[1] = RewardToken({token: address(token2), rate: 0, flat: 500});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens
        });

        token.mint(address(vault), 1000);
        TestERC20(address(token2)).mint(address(vault), 500);

        vm.prank(portal);
        vault.withdraw(reward, claimant, _noFulfilled());

        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token2.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(claimant), 1000);
        assertEq(token2.balanceOf(claimant), 500);
    }

    function test_withdraw_success_partialWithdraw_insufficientTokens() public {
        RewardToken[] memory tokens = new RewardToken[](1);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens
        });

        token.mint(address(vault), 500);

        vm.prank(portal);
        vault.withdraw(reward, claimant, _noFulfilled());

        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(claimant), 500);
    }

    function test_withdraw_success_partialWithdraw_insufficientNative() public {
        RewardToken[] memory tokens = new RewardToken[](1);
        tokens[0] = RewardToken({token: address(0), rate: 0, flat: 2 ether});
        Reward memory reward = Reward({
            creator: creator,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens
        });

        vm.deal(address(vault), 1 ether);

        uint256 claimantInitialBalance = claimant.balance;

        vm.prank(portal);
        vault.withdraw(reward, claimant, _noFulfilled());

        assertEq(address(vault).balance, 0);
        assertEq(claimant.balance, claimantInitialBalance + 1 ether);
    }

    function test_withdraw_success_fromFundedVault() public {
        RewardToken[] memory tokens = new RewardToken[](2);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});
        tokens[1] = RewardToken({token: address(0), rate: 0, flat: 1 ether});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens
        });

        token.mint(creator, 1000);
        vm.prank(creator);
        token.approve(address(vault), 1000);

        vm.deal(portal, 1 ether);
        vm.prank(portal);
        vault.fundFor{value: 1 ether}(
            reward,
            _targets(reward),
            creator,
            IPermit(address(0))
        );

        uint256 claimantInitialBalance = claimant.balance;

        vm.prank(portal);
        vault.withdraw(reward, claimant, _noFulfilled());

        assertEq(address(vault).balance, 0);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(claimant.balance, claimantInitialBalance + 1 ether);
        assertEq(token.balanceOf(claimant), 1000);
    }

    function test_withdraw_not_portal_caller() public {
        RewardToken[] memory tokens = new RewardToken[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens
        });

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.NotPortalCaller.selector,
                unauthorized
            )
        );
        vault.withdraw(reward, claimant, _noFulfilled());
    }

    function test_refund_success_emptyReward_afterDeadline() public {
        RewardToken[] memory tokens = new RewardToken[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens
        });

        vm.warp(block.timestamp + 2000);

        vm.prank(portal);
        vault.refund(reward, creator);
    }

    function test_refund_success_nativeAndTokens_afterDeadline() public {
        RewardToken[] memory tokens = new RewardToken[](2);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});
        tokens[1] = RewardToken({token: address(0), rate: 0, flat: 1 ether});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens
        });

        token.mint(address(vault), 1000);
        vm.deal(address(vault), 1 ether);

        uint256 creatorInitialBalance = creator.balance;

        vm.warp(block.timestamp + 2000);

        vm.prank(portal);
        vault.refund(reward, creator);

        assertEq(address(vault).balance, 0);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(creator.balance, creatorInitialBalance + 1 ether);
        assertEq(token.balanceOf(creator), 1000);
    }

    function test_refund_success_multipleTokens_afterDeadline() public {
        IERC20 token2 = new TestERC20("Test Token 2", "TEST2");

        RewardToken[] memory tokens = new RewardToken[](2);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});
        tokens[1] = RewardToken({token: address(token2), rate: 0, flat: 500});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens
        });

        token.mint(address(vault), 1000);
        TestERC20(address(token2)).mint(address(vault), 500);

        vm.warp(block.timestamp + 2000);

        vm.prank(portal);
        vault.refund(reward, creator);

        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token2.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(creator), 1000);
        assertEq(token2.balanceOf(creator), 500);
    }

    function test_refund_success_zeroTokenBalance_afterDeadline() public {
        RewardToken[] memory tokens = new RewardToken[](1);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens
        });

        vm.warp(block.timestamp + 2000);

        vm.prank(portal);
        vault.refund(reward, creator);

        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(creator), 0);
    }

    function test_refund_success_fromFundedVault_afterDeadline() public {
        RewardToken[] memory tokens = new RewardToken[](2);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});
        tokens[1] = RewardToken({token: address(0), rate: 0, flat: 1 ether});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens
        });

        token.mint(creator, 1000);
        vm.prank(creator);
        token.approve(address(vault), 1000);

        vm.deal(portal, 1 ether);
        vm.prank(portal);
        vault.fundFor{value: 1 ether}(
            reward,
            _targets(reward),
            creator,
            IPermit(address(0))
        );

        uint256 creatorInitialBalance = creator.balance;

        vm.warp(block.timestamp + 2000);

        vm.prank(portal);
        vault.refund(reward, creator);

        assertEq(address(vault).balance, 0);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(creator.balance, creatorInitialBalance + 1 ether);
        assertEq(token.balanceOf(creator), 1000);
    }

    function test_refund_success_fromWithdrawnStatus() public {
        RewardToken[] memory tokens = new RewardToken[](2);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});
        tokens[1] = RewardToken({token: address(0), rate: 0, flat: 1 ether});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens
        });

        token.mint(address(vault), 1000);
        vm.deal(address(vault), 1 ether);

        vm.prank(portal);
        vault.withdraw(reward, claimant, _noFulfilled());

        // Capture AFTER the withdraw: the withdraw fully drained the vault (claimant accepts, so no
        // residual sweep to creator), so refund moves nothing and the creator balance is unchanged.
        uint256 creatorInitialBalance = creator.balance;

        vm.prank(portal);
        vault.refund(reward, creator);

        assertEq(address(vault).balance, 0);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(creator.balance, creatorInitialBalance);
        assertEq(token.balanceOf(creator), 0);
    }

    function test_refund_not_portal_caller() public {
        RewardToken[] memory tokens = new RewardToken[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens
        });

        vm.warp(block.timestamp + 2000);

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.NotPortalCaller.selector,
                unauthorized
            )
        );
        vault.refund(reward, creator);
    }

    function test_refund_refund_twice() public {
        RewardToken[] memory tokens = new RewardToken[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens
        });

        vm.warp(block.timestamp + 2000);

        vm.prank(portal);
        vault.refund(reward, creator);

        vm.prank(portal);
        vault.refund(reward, creator);
    }

    function test_recover_success_differentToken() public {
        TestERC20 differentToken = new TestERC20("Different Token", "DIFF");
        differentToken.mint(address(vault), 500);

        uint256 creatorInitialBalance = differentToken.balanceOf(creator);

        vm.prank(portal);
        vault.recover(creator, address(differentToken));

        assertEq(differentToken.balanceOf(address(vault)), 0);
        assertEq(
            differentToken.balanceOf(creator),
            creatorInitialBalance + 500
        );
    }

    function test_recover_not_portal_caller() public {
        TestERC20 recoverToken = new TestERC20("Recover Token", "REC");

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.NotPortalCaller.selector,
                unauthorized
            )
        );
        vault.recover(creator, address(recoverToken));
    }

    function test_recover_zero_balance() public {
        TestERC20 recoverToken = new TestERC20("Recover Token", "REC");

        vm.prank(portal);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.ZeroRecoverTokenBalance.selector,
                address(recoverToken)
            )
        );
        vault.recover(creator, address(recoverToken));
    }

    function test_withdraw_success_withRevertingClaimant() public {
        // Deploy a contract that always reverts on receive
        RevertingClaimant revertingClaimant = new RevertingClaimant();

        RewardToken[] memory tokens = new RewardToken[](2);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});
        tokens[1] = RewardToken({token: address(0), rate: 0, flat: 1 ether});

        Reward memory reward = Reward({
            creator: creator, // Normal address that accepts ETH
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens
        });

        token.mint(address(vault), 1000);
        vm.deal(address(vault), 1 ether);

        uint256 creatorBefore = creator.balance;

        // Withdrawal succeeds: tokens transfer to the claimant, the claimant rejects the native pay,
        // so that 1 ether becomes residual and is swept to the creator (funds conserved, not stuck).
        vm.prank(portal);
        vault.withdraw(reward, address(revertingClaimant), _noFulfilled());

        // Vault fully drained: the un-received native was swept to the creator.
        assertEq(address(vault).balance, 0);
        assertEq(token.balanceOf(address(vault)), 0);

        // Native swept to the creator (the claimant rejected it).
        assertEq(creator.balance, creatorBefore + 1 ether);

        // Claimant still received tokens but NOT the native ETH (its receive reverted).
        assertEq(address(revertingClaimant).balance, 0);
        assertEq(token.balanceOf(address(revertingClaimant)), 1000);
    }

    function test_refund_success_withRevertingRefundee() public {
        // Deploy a contract that always reverts on receive
        RevertingClaimant revertingRefundee = new RevertingClaimant();

        RewardToken[] memory tokens = new RewardToken[](2);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});
        tokens[1] = RewardToken({token: address(0), rate: 0, flat: 1 ether});

        Reward memory reward = Reward({
            creator: creator, // Normal creator address
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens
        });

        token.mint(address(vault), 1000);
        vm.deal(address(vault), 1 ether);

        vm.warp(block.timestamp + 2000);

        // Refund should succeed - tokens transfer, ETH remains if refundee rejects
        vm.prank(portal);
        vault.refund(reward, address(revertingRefundee));

        // Verify ETH remains in vault (refundee rejected it)
        assertEq(address(vault).balance, 1 ether);
        assertEq(token.balanceOf(address(vault)), 0);

        // Verify refundee received tokens but NOT native ETH (reverted)
        assertEq(address(revertingRefundee).balance, 0);
        assertEq(token.balanceOf(address(revertingRefundee)), 1000);
    }

    // ── TetherToken (Tron USDT) compatibility ─────────────────────────────────

    /**
     * @notice Reproduces the exact on-chain failure seen when withdrawing USDT
     *         rewards locked in a vault on Tron (Shasta testnet).
     *
     * Root cause: StandardTokenWithFees.transfer() (solc 0.4.18) is declared
     * `returns (bool)` but has no explicit `return` statement, so it always
     * returns the zero value `false` even though tokens actually move:
     *
     *   function transfer(address _to, uint _value) public returns (bool) {
     *       uint fee = calcFee(_value);        // 0 when basisPointsRate == 0
     *       uint sendAmount = _value.sub(fee);
     *       super.transfer(_to, sendAmount);   // tokens move here
     *       if (fee > 0) { ... }
     *       // ← no return statement → implicit false
     *   }
     *
     * OZ SafeERC20._callOptionalReturn decodes the return data as bool, sees
     * `false`, and reverts with SafeERC20FailedOperation(token).  The vault
     * call reverts, tokens stay locked forever.
     *
     * Note: transferFrom() in StandardTokenWithFees *does* have `return true`,
     * which is why publishAndFund (which uses transferFrom) succeeds while only
     * withdraw (which uses safeTransfer → transfer) fails.
     */
    function test_withdraw_reverts_withTetherToken() public {
        // Deploy the mock that reproduces StandardTokenWithFees.transfer()
        // returning false (no explicit return statement in solc 0.4.18).
        TronUSDTMock tether = new TronUSDTMock(10_000_000);

        // Fund the vault via transferFrom (which returns true) — mirrors
        // what publishAndFund does on-chain.
        tether.approve(address(this), 100_000);
        tether.transferFrom(address(this), address(vault), 100_000);
        assertEq(tether.balanceOf(address(vault)), 100_000);

        RewardToken[] memory tokens = new RewardToken[](1);
        tokens[0] = RewardToken({
            token: address(tether),
            rate: 0,
            flat: 100_000
        });

        Reward memory reward = Reward({
            creator: creator,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens
        });

        // Base Vault uses SafeERC20 and will revert when TronUSDTMock.transfer()
        // returns false (the ERC20 leg transfer reverts before any residual sweep) —
        // Tron USDT compatibility is handled by VaultTron instead.
        vm.prank(portal);
        vm.expectRevert();
        vault.withdraw(reward, claimant, _noFulfilled());
    }

    function test_withdraw_succeeds_withTetherToken_usingVaultTron() public {
        // Deploy the mock that reproduces StandardTokenWithFees.transfer()
        // returning false (no explicit return statement in solc 0.4.18).
        TronUSDTMock tether = new TronUSDTMock(10_000_000);

        // Deploy a VaultTron clone (Tron-aware vault) for this test.
        // vm.prank sets msg.sender for the constructor so portal is set correctly.
        vm.prank(portal);
        IVault vaultTron = IVault(
            address(new VaultTron()).clone(bytes32(uint256(1)))
        );

        // Fund via transferFrom (returns true) — mirrors publishAndFund on-chain.
        tether.approve(address(this), 100_000);
        tether.transferFrom(address(this), address(vaultTron), 100_000);
        assertEq(tether.balanceOf(address(vaultTron)), 100_000);

        RewardToken[] memory tokens = new RewardToken[](1);
        tokens[0] = RewardToken({
            token: address(tether),
            rate: 0,
            flat: 100_000
        });

        Reward memory reward = Reward({
            creator: creator,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens
        });

        // VaultTron uses a raw call so it succeeds even though
        // TronUSDTMock.transfer() returns false (reproducing the Tron USDT bug).
        // The balance check in _transferToken confirms tokens actually moved.
        vm.prank(portal);
        vaultTron.withdraw(reward, claimant, _noFulfilled());

        // Tokens left the vault and arrived at the claimant.
        assertEq(tether.balanceOf(address(vaultTron)), 0);
        assertEq(tether.balanceOf(claimant), 100_000);
    }
}

/// @notice Contract that reverts on receive to simulate griefing attack
contract RevertingClaimant {
    receive() external payable {
        revert("RevertingClaimant: I reject your ETH");
    }

    fallback() external payable {
        revert("RevertingClaimant: I reject your ETH");
    }
}
