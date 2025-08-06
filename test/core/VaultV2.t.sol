// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {VaultV2} from "../../contracts/VaultV2.sol";
import {IVaultV2} from "../../contracts/interfaces/IVaultV2.sol";
import {IPermit} from "../../contracts/interfaces/IPermit.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";
import {Reward, TokenAmount} from "../../contracts/types/Intent.sol";

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

contract VaultV2Test is Test {
    using Clones for address;

    IVaultV2 internal vault;
    TestERC20 internal token;
    MockPermit internal mockPermit;

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
        vault = IVaultV2(address(new VaultV2()).clone());

        token = new TestERC20("Test Token", "TEST");
        mockPermit = new MockPermit();
    }

    function test_constructor_setsInitialStatus() public view {
        assert(vault.getStatus() == IVaultV2.Status.Initial);
    }

    function test_constructor_setsPortalCorrectly() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 0,
            tokens: tokens
        });

        vm.prank(portal);
        assertTrue(vault.fund(reward, creator, IPermit(address(0))));

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultV2.NotPortalCaller.selector,
                unauthorized
            )
        );
        vault.fund(reward, creator, IPermit(address(0)));
    }

    function test_fund_success_emptyReward() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 0,
            tokens: tokens
        });

        vm.prank(portal);
        bool result = vault.fund(reward, creator, IPermit(address(0)));

        assertTrue(result);
        assert(vault.getStatus() == IVaultV2.Status.Funded);
    }

    function test_fund_success_nativeAndTokens() public {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(token), amount: 1000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 1 ether,
            tokens: tokens
        });

        token.mint(creator, 1000);
        vm.prank(creator);
        token.approve(address(vault), 1000);

        vm.deal(portal, 2 ether);
        vm.prank(portal);
        bool result = vault.fund{value: 1 ether}(
            reward,
            creator,
            IPermit(address(0))
        );

        assertTrue(result);
        assert(vault.getStatus() == IVaultV2.Status.Funded);
        assertEq(address(vault).balance, 1 ether);
        assertEq(token.balanceOf(address(vault)), 1000);
    }

    function test_fund_partialFunding_insufficientNative() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 2 ether,
            tokens: tokens
        });

        vm.deal(portal, 1 ether);
        vm.prank(portal);
        bool result = vault.fund{value: 1 ether}(
            reward,
            creator,
            IPermit(address(0))
        );

        assertFalse(result);
        assert(vault.getStatus() == IVaultV2.Status.Initial);
        assertEq(address(vault).balance, 1 ether);
    }

    function test_fund_partialFunding_insufficientTokens() public {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(token), amount: 2000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 0,
            tokens: tokens
        });

        token.mint(creator, 1000);
        vm.prank(creator);
        token.approve(address(vault), 1000);

        vm.prank(portal);
        bool result = vault.fund(reward, creator, IPermit(address(0)));

        assertFalse(result);
        assert(vault.getStatus() == IVaultV2.Status.Initial);
        assertEq(token.balanceOf(address(vault)), 1000);
    }

    function test_fund_success_multipleTokens() public {
        IERC20 token2 = new TestERC20("Test Token 2", "TEST2");

        TokenAmount[] memory tokens = new TokenAmount[](2);
        tokens[0] = TokenAmount({token: address(token), amount: 1000});
        tokens[1] = TokenAmount({token: address(token2), amount: 500});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 0,
            tokens: tokens
        });

        token.mint(creator, 1000);
        vm.prank(creator);
        token.approve(address(vault), 1000);

        TestERC20(address(token2)).mint(creator, 500);
        vm.prank(creator);
        token2.approve(address(vault), 500);

        vm.prank(portal);
        bool result = vault.fund(reward, creator, IPermit(address(0)));

        assertTrue(result);
        assert(vault.getStatus() == IVaultV2.Status.Funded);
        assertEq(token.balanceOf(address(vault)), 1000);
        assertEq(token2.balanceOf(address(vault)), 500);
    }

    function test_fund_not_portal_caller() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 0,
            tokens: tokens
        });

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultV2.NotPortalCaller.selector,
                unauthorized
            )
        );
        vault.fund(reward, creator, IPermit(address(0)));
    }

    function test_fund_cannotFundTwice() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 0,
            tokens: tokens
        });

        vm.prank(portal);
        bool result1 = vault.fund(reward, creator, IPermit(address(0)));
        assertTrue(result1);
        assert(vault.getStatus() == IVaultV2.Status.Funded);

        vm.prank(portal);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultV2.InvalidStatusForFunding.selector,
                IVaultV2.Status.Funded
            )
        );
        vault.fund(reward, creator, IPermit(address(0)));
    }

    function test_fund_success_prefundedVault() public {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(token), amount: 1000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 1 ether,
            tokens: tokens
        });

        token.mint(address(vault), 1000);
        vm.deal(address(vault), 1 ether);

        vm.prank(portal);
        bool result = vault.fund(reward, creator, IPermit(address(0)));

        assertTrue(result);
        assert(vault.getStatus() == IVaultV2.Status.Funded);
        assertEq(address(vault).balance, 1 ether);
        assertEq(token.balanceOf(address(vault)), 1000);
    }

    function test_fund_success_partiallyPrefunded() public {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(token), amount: 1000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 1 ether,
            tokens: tokens
        });

        token.mint(address(vault), 500);
        vm.deal(address(vault), 0.5 ether);

        token.mint(creator, 500);
        vm.prank(creator);
        token.approve(address(vault), 500);

        vm.deal(portal, 1 ether);
        vm.prank(portal);
        bool result = vault.fund{value: 0.5 ether}(
            reward,
            creator,
            IPermit(address(0))
        );

        assertTrue(result);
        assert(vault.getStatus() == IVaultV2.Status.Funded);
        assertEq(address(vault).balance, 1 ether);
        assertEq(token.balanceOf(address(vault)), 1000);
    }

    function test_fund_success_withPermit() public {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(token), amount: 1000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 0,
            tokens: tokens
        });

        token.mint(creator, 1000);
        vm.prank(creator);
        token.approve(address(mockPermit), 1000);

        mockPermit.setAllowance(creator, address(token), address(vault), 1000);

        vm.prank(portal);
        bool result = vault.fund(reward, creator, IPermit(address(mockPermit)));

        assertTrue(result);
        assert(vault.getStatus() == IVaultV2.Status.Funded);
        assertEq(token.balanceOf(address(vault)), 1000);
        assertEq(token.balanceOf(creator), 0);
    }

    function test_fund_success_withPermit_partialFromPermit() public {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(token), amount: 1000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 0,
            tokens: tokens
        });

        token.mint(creator, 1000);
        vm.prank(creator);
        token.approve(address(vault), 500);
        vm.prank(creator);
        token.approve(address(mockPermit), 500);

        mockPermit.setAllowance(creator, address(token), address(vault), 500);

        vm.prank(portal);
        bool result = vault.fund(reward, creator, IPermit(address(mockPermit)));

        assertTrue(result);
        assert(vault.getStatus() == IVaultV2.Status.Funded);
        assertEq(token.balanceOf(address(vault)), 1000);
        assertEq(token.balanceOf(creator), 0);
    }

    function test_fund_success_withPermit_fallbackToRegularApproval() public {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(token), amount: 1000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 0,
            tokens: tokens
        });

        token.mint(creator, 1000);
        vm.prank(creator);
        token.approve(address(vault), 1000);

        vm.prank(portal);
        bool result = vault.fund(reward, creator, IPermit(address(mockPermit)));

        assertTrue(result);
        assert(vault.getStatus() == IVaultV2.Status.Funded);
        assertEq(token.balanceOf(address(vault)), 1000);
        assertEq(token.balanceOf(creator), 0);
    }

    function test_fund_partial_withPermit_insufficientPermitAllowance() public {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(token), amount: 1000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 0,
            tokens: tokens
        });

        token.mint(creator, 1000);
        vm.prank(creator);
        token.approve(address(mockPermit), 500);

        mockPermit.setAllowance(creator, address(token), address(vault), 500);

        vm.prank(portal);
        bool result = vault.fund(reward, creator, IPermit(address(mockPermit)));

        assertFalse(result);
        assert(vault.getStatus() == IVaultV2.Status.Initial);
        assertEq(token.balanceOf(address(vault)), 500);
        assertEq(token.balanceOf(creator), 500);
    }

    function test_withdraw_success_emptyReward() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 0,
            tokens: tokens
        });

        vm.prank(portal);
        vault.withdraw(reward, claimant);

        assert(vault.getStatus() == IVaultV2.Status.Withdrawn);
    }

    function test_withdraw_success_nativeAndTokens() public {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(token), amount: 1000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 1 ether,
            tokens: tokens
        });

        token.mint(address(vault), 1000);
        vm.deal(address(vault), 1 ether);

        uint256 claimantInitialBalance = claimant.balance;

        vm.prank(portal);
        vault.withdraw(reward, claimant);

        assert(vault.getStatus() == IVaultV2.Status.Withdrawn);
        assertEq(address(vault).balance, 0);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(claimant.balance, claimantInitialBalance + 1 ether);
        assertEq(token.balanceOf(claimant), 1000);
    }

    function test_withdraw_success_multipleTokens() public {
        IERC20 token2 = new TestERC20("Test Token 2", "TEST2");

        TokenAmount[] memory tokens = new TokenAmount[](2);
        tokens[0] = TokenAmount({token: address(token), amount: 1000});
        tokens[1] = TokenAmount({token: address(token2), amount: 500});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 0,
            tokens: tokens
        });

        token.mint(address(vault), 1000);
        TestERC20(address(token2)).mint(address(vault), 500);

        vm.prank(portal);
        vault.withdraw(reward, claimant);

        assert(vault.getStatus() == IVaultV2.Status.Withdrawn);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token2.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(claimant), 1000);
        assertEq(token2.balanceOf(claimant), 500);
    }

    function test_withdraw_success_partialWithdraw_insufficientTokens() public {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(token), amount: 1000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 0,
            tokens: tokens
        });

        token.mint(address(vault), 500);

        vm.prank(portal);
        vault.withdraw(reward, claimant);

        assert(vault.getStatus() == IVaultV2.Status.Withdrawn);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(claimant), 500);
    }

    function test_withdraw_success_partialWithdraw_insufficientNative() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 2 ether,
            tokens: tokens
        });

        vm.deal(address(vault), 1 ether);

        uint256 claimantInitialBalance = claimant.balance;

        vm.prank(portal);
        vault.withdraw(reward, claimant);

        assert(vault.getStatus() == IVaultV2.Status.Withdrawn);
        assertEq(address(vault).balance, 0);
        assertEq(claimant.balance, claimantInitialBalance + 1 ether);
    }

    function test_withdraw_success_fromFundedVault() public {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(token), amount: 1000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 1 ether,
            tokens: tokens
        });

        token.mint(creator, 1000);
        vm.prank(creator);
        token.approve(address(vault), 1000);

        vm.deal(portal, 1 ether);
        vm.prank(portal);
        vault.fund{value: 1 ether}(reward, creator, IPermit(address(0)));

        assert(vault.getStatus() == IVaultV2.Status.Funded);

        uint256 claimantInitialBalance = claimant.balance;

        vm.prank(portal);
        vault.withdraw(reward, claimant);

        assert(vault.getStatus() == IVaultV2.Status.Withdrawn);
        assertEq(address(vault).balance, 0);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(claimant.balance, claimantInitialBalance + 1 ether);
        assertEq(token.balanceOf(claimant), 1000);
    }

    function test_withdraw_not_portal_caller() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 0,
            tokens: tokens
        });

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultV2.NotPortalCaller.selector,
                unauthorized
            )
        );
        vault.withdraw(reward, claimant);
    }

    function test_withdraw_invalid_claimant_zero_address() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 0,
            tokens: tokens
        });

        vm.prank(portal);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultV2.InvalidClaimant.selector,
                address(0)
            )
        );
        vault.withdraw(reward, address(0));
    }

    function test_withdraw_invalid_status_withdrawn() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 0,
            tokens: tokens
        });

        vm.prank(portal);
        vault.withdraw(reward, claimant);
        assert(vault.getStatus() == IVaultV2.Status.Withdrawn);

        vm.prank(portal);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultV2.InvalidStatusForWithdrawal.selector,
                IVaultV2.Status.Withdrawn
            )
        );
        vault.withdraw(reward, claimant);
    }

    function test_withdraw_invalid_status_refunded() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 0,
            tokens: tokens
        });

        vm.prank(portal);
        vault.fund(reward, creator, IPermit(address(0)));

        vm.warp(block.timestamp + 2000);

        vm.prank(portal);
        vault.refund(reward);
        assert(vault.getStatus() == IVaultV2.Status.Refunded);

        vm.prank(portal);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultV2.InvalidStatusForWithdrawal.selector,
                IVaultV2.Status.Refunded
            )
        );
        vault.withdraw(reward, claimant);
    }

    function test_refund_success_emptyReward_afterDeadline() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 0,
            tokens: tokens
        });

        vm.warp(block.timestamp + 2000);

        vm.prank(portal);
        vault.refund(reward);

        assert(vault.getStatus() == IVaultV2.Status.Refunded);
    }

    function test_refund_success_nativeAndTokens_afterDeadline() public {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(token), amount: 1000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 1 ether,
            tokens: tokens
        });

        token.mint(address(vault), 1000);
        vm.deal(address(vault), 1 ether);

        uint256 creatorInitialBalance = creator.balance;

        vm.warp(block.timestamp + 2000);

        vm.prank(portal);
        vault.refund(reward);

        assert(vault.getStatus() == IVaultV2.Status.Refunded);
        assertEq(address(vault).balance, 0);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(creator.balance, creatorInitialBalance + 1 ether);
        assertEq(token.balanceOf(creator), 1000);
    }

    function test_refund_success_multipleTokens_afterDeadline() public {
        IERC20 token2 = new TestERC20("Test Token 2", "TEST2");

        TokenAmount[] memory tokens = new TokenAmount[](2);
        tokens[0] = TokenAmount({token: address(token), amount: 1000});
        tokens[1] = TokenAmount({token: address(token2), amount: 500});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 0,
            tokens: tokens
        });

        token.mint(address(vault), 1000);
        TestERC20(address(token2)).mint(address(vault), 500);

        vm.warp(block.timestamp + 2000);

        vm.prank(portal);
        vault.refund(reward);

        assert(vault.getStatus() == IVaultV2.Status.Refunded);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token2.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(creator), 1000);
        assertEq(token2.balanceOf(creator), 500);
    }

    function test_refund_success_zeroTokenBalance_afterDeadline() public {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(token), amount: 1000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 0,
            tokens: tokens
        });

        vm.warp(block.timestamp + 2000);

        vm.prank(portal);
        vault.refund(reward);

        assert(vault.getStatus() == IVaultV2.Status.Refunded);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(creator), 0);
    }

    function test_refund_success_fromFundedVault_afterDeadline() public {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(token), amount: 1000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 1 ether,
            tokens: tokens
        });

        token.mint(creator, 1000);
        vm.prank(creator);
        token.approve(address(vault), 1000);

        vm.deal(portal, 1 ether);
        vm.prank(portal);
        vault.fund{value: 1 ether}(reward, creator, IPermit(address(0)));

        assert(vault.getStatus() == IVaultV2.Status.Funded);

        uint256 creatorInitialBalance = creator.balance;

        vm.warp(block.timestamp + 2000);

        vm.prank(portal);
        vault.refund(reward);

        assert(vault.getStatus() == IVaultV2.Status.Refunded);
        assertEq(address(vault).balance, 0);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(creator.balance, creatorInitialBalance + 1 ether);
        assertEq(token.balanceOf(creator), 1000);
    }

    function test_refund_success_fromWithdrawnStatus() public {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(token), amount: 1000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 1 ether,
            tokens: tokens
        });

        token.mint(address(vault), 1000);
        vm.deal(address(vault), 1 ether);

        vm.prank(portal);
        vault.withdraw(reward, claimant);
        assert(vault.getStatus() == IVaultV2.Status.Withdrawn);

        uint256 creatorInitialBalance = creator.balance;

        vm.prank(portal);
        vault.refund(reward);

        assert(vault.getStatus() == IVaultV2.Status.Refunded);
        assertEq(address(vault).balance, 0);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(creator.balance, creatorInitialBalance);
        assertEq(token.balanceOf(creator), 0);
    }

    function test_refund_not_portal_caller() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 0,
            tokens: tokens
        });

        vm.warp(block.timestamp + 2000);

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultV2.NotPortalCaller.selector,
                unauthorized
            )
        );
        vault.refund(reward);
    }

    function test_refund_invalid_status_and_deadline_initial() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 0,
            tokens: tokens
        });

        vm.prank(portal);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultV2.InvalidStatusForRefund.selector,
                IVaultV2.Status.Initial,
                block.timestamp,
                reward.deadline
            )
        );
        vault.refund(reward);
    }

    function test_refund_invalid_status_and_deadline_funded() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 0,
            tokens: tokens
        });

        vm.prank(portal);
        vault.fund(reward, creator, IPermit(address(0)));
        assert(vault.getStatus() == IVaultV2.Status.Funded);

        vm.prank(portal);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultV2.InvalidStatusForRefund.selector,
                IVaultV2.Status.Funded,
                block.timestamp,
                reward.deadline
            )
        );
        vault.refund(reward);
    }

    function test_refund_refund_twice() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeValue: 0,
            tokens: tokens
        });

        vm.warp(block.timestamp + 2000);

        vm.prank(portal);
        vault.refund(reward);
        assert(vault.getStatus() == IVaultV2.Status.Refunded);

        vm.prank(portal);
        vault.refund(reward);
        assert(vault.getStatus() == IVaultV2.Status.Refunded);
    }
}
