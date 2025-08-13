// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Vault} from "../../contracts/vault/Vault.sol";
import {IVault} from "../../contracts/interfaces/IVault.sol";
import {IPermit} from "../../contracts/interfaces/IPermit.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";
import {Reward, TokenAmount} from "../../contracts/types/Intent.sol";
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
    }

    function test_constructor_setsPortalCorrectly() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeAmount: 0,
            tokens: tokens
        });

        vm.prank(portal);
        assertTrue(
            vault.fundFor(
                IVault.Status.Initial,
                reward,
                creator,
                IPermit(address(0))
            )
        );

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.NotPortalCaller.selector,
                unauthorized
            )
        );
        vault.fundFor(
            IVault.Status.Initial,
            reward,
            creator,
            IPermit(address(0))
        );
    }

    function test_fundFor_success_emptyReward() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeAmount: 0,
            tokens: tokens
        });

        vm.prank(portal);
        bool result = vault.fundFor(
            IVault.Status.Initial,
            reward,
            creator,
            IPermit(address(0))
        );

        assertTrue(result);
    }

    function test_fundFor_success_nativeAndTokens() public {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(token), amount: 1000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeAmount: 1 ether,
            tokens: tokens
        });

        token.mint(creator, 1000);
        vm.prank(creator);
        token.approve(address(vault), 1000);

        vm.deal(portal, 2 ether);
        vm.prank(portal);
        bool result = vault.fundFor{value: 1 ether}(
            IVault.Status.Initial,
            reward,
            creator,
            IPermit(address(0))
        );

        assertTrue(result);
        assertEq(address(vault).balance, 1 ether);
        assertEq(token.balanceOf(address(vault)), 1000);
    }

    function test_fundFor_partialFunding_insufficientNative() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeAmount: 2 ether,
            tokens: tokens
        });

        vm.deal(portal, 1 ether);
        vm.prank(portal);
        bool result = vault.fundFor{value: 1 ether}(
            IVault.Status.Initial,
            reward,
            creator,
            IPermit(address(0))
        );

        assertFalse(result);
        assertEq(address(vault).balance, 1 ether);
    }

    function test_fundFor_partialFunding_insufficientTokens() public {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(token), amount: 2000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeAmount: 0,
            tokens: tokens
        });

        token.mint(creator, 1000);
        vm.prank(creator);
        token.approve(address(vault), 1000);

        vm.prank(portal);
        bool result = vault.fundFor(
            IVault.Status.Initial,
            reward,
            creator,
            IPermit(address(0))
        );

        assertFalse(result);
        assertEq(token.balanceOf(address(vault)), 1000);
    }

    function test_fundFor_success_multipleTokens() public {
        IERC20 token2 = new TestERC20("Test Token 2", "TEST2");

        TokenAmount[] memory tokens = new TokenAmount[](2);
        tokens[0] = TokenAmount({token: address(token), amount: 1000});
        tokens[1] = TokenAmount({token: address(token2), amount: 500});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeAmount: 0,
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
            IVault.Status.Initial,
            reward,
            creator,
            IPermit(address(0))
        );

        assertTrue(result);
        assertEq(token.balanceOf(address(vault)), 1000);
        assertEq(token2.balanceOf(address(vault)), 500);
    }

    function test_fundFor_not_portal_caller() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeAmount: 0,
            tokens: tokens
        });

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.NotPortalCaller.selector,
                unauthorized
            )
        );
        vault.fundFor(
            IVault.Status.Initial,
            reward,
            creator,
            IPermit(address(0))
        );
    }

    function test_fundFor_cannotFundWithWrongStatus() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeAmount: 0,
            tokens: tokens
        });

        vm.prank(portal);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.InvalidStatusForFunding.selector,
                IVault.Status.Withdrawn
            )
        );
        vault.fundFor(
            IVault.Status.Withdrawn,
            reward,
            creator,
            IPermit(address(0))
        );
    }

    function test_fundFor_success_prefundedVault() public {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(token), amount: 1000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeAmount: 1 ether,
            tokens: tokens
        });

        token.mint(address(vault), 1000);
        vm.deal(address(vault), 1 ether);

        vm.prank(portal);
        bool result = vault.fundFor(
            IVault.Status.Initial,
            reward,
            creator,
            IPermit(address(0))
        );

        assertTrue(result);
        assertEq(address(vault).balance, 1 ether);
        assertEq(token.balanceOf(address(vault)), 1000);
    }

    function test_fundFor_success_partiallyPrefunded() public {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(token), amount: 1000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeAmount: 1 ether,
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
            IVault.Status.Initial,
            reward,
            creator,
            IPermit(address(0))
        );

        assertTrue(result);
        assertEq(address(vault).balance, 1 ether);
        assertEq(token.balanceOf(address(vault)), 1000);
    }

    function test_fundFor_success_withPermit() public {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(token), amount: 1000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeAmount: 0,
            tokens: tokens
        });

        token.mint(creator, 1000);
        vm.prank(creator);
        token.approve(address(mockPermit), 1000);

        mockPermit.setAllowance(creator, address(token), address(vault), 1000);

        vm.prank(portal);
        bool result = vault.fundFor(
            IVault.Status.Initial,
            reward,
            creator,
            IPermit(address(mockPermit))
        );

        assertTrue(result);
        assertEq(token.balanceOf(address(vault)), 1000);
        assertEq(token.balanceOf(creator), 0);
    }

    function test_fundFor_success_withPermit_partialFromPermit() public {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(token), amount: 1000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeAmount: 0,
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
            IVault.Status.Initial,
            reward,
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
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(token), amount: 1000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeAmount: 0,
            tokens: tokens
        });

        token.mint(creator, 1000);
        vm.prank(creator);
        token.approve(address(vault), 1000);

        vm.prank(portal);
        bool result = vault.fundFor(
            IVault.Status.Initial,
            reward,
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
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(token), amount: 1000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeAmount: 0,
            tokens: tokens
        });

        token.mint(creator, 1000);
        vm.prank(creator);
        token.approve(address(mockPermit), 500);

        mockPermit.setAllowance(creator, address(token), address(vault), 500);

        vm.prank(portal);
        bool result = vault.fundFor(
            IVault.Status.Initial,
            reward,
            creator,
            IPermit(address(mockPermit))
        );

        assertFalse(result);
        assertEq(token.balanceOf(address(vault)), 500);
        assertEq(token.balanceOf(creator), 500);
    }

    function test_withdraw_success_emptyReward() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeAmount: 0,
            tokens: tokens
        });

        vm.prank(portal);
        vault.withdraw(IVault.Status.Funded, reward, claimant);
    }

    function test_withdraw_success_nativeAndTokens() public {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(token), amount: 1000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeAmount: 1 ether,
            tokens: tokens
        });

        token.mint(address(vault), 1000);
        vm.deal(address(vault), 1 ether);

        uint256 claimantInitialBalance = claimant.balance;

        vm.prank(portal);
        vault.withdraw(IVault.Status.Funded, reward, claimant);

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
            nativeAmount: 0,
            tokens: tokens
        });

        token.mint(address(vault), 1000);
        TestERC20(address(token2)).mint(address(vault), 500);

        vm.prank(portal);
        vault.withdraw(IVault.Status.Funded, reward, claimant);

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
            nativeAmount: 0,
            tokens: tokens
        });

        token.mint(address(vault), 500);

        vm.prank(portal);
        vault.withdraw(IVault.Status.Funded, reward, claimant);

        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(claimant), 500);
    }

    function test_withdraw_success_partialWithdraw_insufficientNative() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeAmount: 2 ether,
            tokens: tokens
        });

        vm.deal(address(vault), 1 ether);

        uint256 claimantInitialBalance = claimant.balance;

        vm.prank(portal);
        vault.withdraw(IVault.Status.Funded, reward, claimant);

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
            nativeAmount: 1 ether,
            tokens: tokens
        });

        token.mint(creator, 1000);
        vm.prank(creator);
        token.approve(address(vault), 1000);

        vm.deal(portal, 1 ether);
        vm.prank(portal);
        vault.fundFor{value: 1 ether}(
            IVault.Status.Initial,
            reward,
            creator,
            IPermit(address(0))
        );

        uint256 claimantInitialBalance = claimant.balance;

        vm.prank(portal);
        vault.withdraw(IVault.Status.Funded, reward, claimant);

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
            nativeAmount: 0,
            tokens: tokens
        });

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.NotPortalCaller.selector,
                unauthorized
            )
        );
        vault.withdraw(IVault.Status.Funded, reward, claimant);
    }

    function test_withdraw_invalid_claimant_zero_address() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeAmount: 0,
            tokens: tokens
        });

        vm.prank(portal);
        vm.expectRevert(abi.encodeWithSelector(IVault.ZeroClaimant.selector));
        vault.withdraw(IVault.Status.Funded, reward, address(0));
    }

    function test_withdraw_invalid_status_withdrawn() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeAmount: 0,
            tokens: tokens
        });

        vm.prank(portal);
        vault.withdraw(IVault.Status.Funded, reward, claimant);

        vm.prank(portal);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.InvalidStatusForWithdrawal.selector,
                IVault.Status.Withdrawn
            )
        );
        vault.withdraw(IVault.Status.Withdrawn, reward, claimant);
    }

    function test_withdraw_invalid_status_refunded() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeAmount: 0,
            tokens: tokens
        });

        vm.prank(portal);
        vault.fundFor(
            IVault.Status.Initial,
            reward,
            creator,
            IPermit(address(0))
        );

        vm.warp(block.timestamp + 2000);

        vm.prank(portal);
        vault.refund(IVault.Status.Funded, reward);

        vm.prank(portal);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.InvalidStatusForWithdrawal.selector,
                IVault.Status.Refunded
            )
        );
        vault.withdraw(IVault.Status.Refunded, reward, claimant);
    }

    function test_refund_success_emptyReward_afterDeadline() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeAmount: 0,
            tokens: tokens
        });

        vm.warp(block.timestamp + 2000);

        vm.prank(portal);
        vault.refund(IVault.Status.Funded, reward);
    }

    function test_refund_success_nativeAndTokens_afterDeadline() public {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(token), amount: 1000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeAmount: 1 ether,
            tokens: tokens
        });

        token.mint(address(vault), 1000);
        vm.deal(address(vault), 1 ether);

        uint256 creatorInitialBalance = creator.balance;

        vm.warp(block.timestamp + 2000);

        vm.prank(portal);
        vault.refund(IVault.Status.Funded, reward);

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
            nativeAmount: 0,
            tokens: tokens
        });

        token.mint(address(vault), 1000);
        TestERC20(address(token2)).mint(address(vault), 500);

        vm.warp(block.timestamp + 2000);

        vm.prank(portal);
        vault.refund(IVault.Status.Funded, reward);

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
            nativeAmount: 0,
            tokens: tokens
        });

        vm.warp(block.timestamp + 2000);

        vm.prank(portal);
        vault.refund(IVault.Status.Funded, reward);

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
            nativeAmount: 1 ether,
            tokens: tokens
        });

        token.mint(creator, 1000);
        vm.prank(creator);
        token.approve(address(vault), 1000);

        vm.deal(portal, 1 ether);
        vm.prank(portal);
        vault.fundFor{value: 1 ether}(
            IVault.Status.Initial,
            reward,
            creator,
            IPermit(address(0))
        );

        uint256 creatorInitialBalance = creator.balance;

        vm.warp(block.timestamp + 2000);

        vm.prank(portal);
        vault.refund(IVault.Status.Funded, reward);

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
            nativeAmount: 1 ether,
            tokens: tokens
        });

        token.mint(address(vault), 1000);
        vm.deal(address(vault), 1 ether);

        vm.prank(portal);
        vault.withdraw(IVault.Status.Funded, reward, claimant);

        uint256 creatorInitialBalance = creator.balance;

        vm.prank(portal);
        vault.refund(IVault.Status.Withdrawn, reward);

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
            nativeAmount: 0,
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
        vault.refund(IVault.Status.Funded, reward);
    }

    function test_refund_invalid_status_and_deadline_initial() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeAmount: 0,
            tokens: tokens
        });

        vm.prank(portal);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.InvalidStatusForRefund.selector,
                IVault.Status.Initial,
                block.timestamp,
                reward.deadline
            )
        );
        vault.refund(IVault.Status.Initial, reward);
    }

    function test_refund_invalid_status_and_deadline_funded() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeAmount: 0,
            tokens: tokens
        });

        vm.prank(portal);
        vault.fundFor(
            IVault.Status.Initial,
            reward,
            creator,
            IPermit(address(0))
        );

        vm.prank(portal);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.InvalidStatusForRefund.selector,
                IVault.Status.Funded,
                block.timestamp,
                reward.deadline
            )
        );
        vault.refund(IVault.Status.Funded, reward);
    }

    function test_refund_refund_twice() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeAmount: 0,
            tokens: tokens
        });

        vm.warp(block.timestamp + 2000);

        vm.prank(portal);
        vault.refund(IVault.Status.Funded, reward);

        vm.prank(portal);
        vault.refund(IVault.Status.Refunded, reward);
    }

    function test_recover_success_differentToken() public {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(token), amount: 1000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeAmount: 0,
            tokens: tokens
        });

        TestERC20 differentToken = new TestERC20("Different Token", "DIFF");
        differentToken.mint(address(vault), 500);

        uint256 creatorInitialBalance = differentToken.balanceOf(creator);

        vm.prank(portal);
        vault.recover(reward, address(differentToken));

        assertEq(differentToken.balanceOf(address(vault)), 0);
        assertEq(
            differentToken.balanceOf(creator),
            creatorInitialBalance + 500
        );
    }

    function test_recover_not_portal_caller() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeAmount: 0,
            tokens: tokens
        });

        TestERC20 recoverToken = new TestERC20("Recover Token", "REC");

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.NotPortalCaller.selector,
                unauthorized
            )
        );
        vault.recover(reward, address(recoverToken));
    }

    function test_recover_invalid_token_zero_address() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeAmount: 0,
            tokens: tokens
        });

        vm.prank(portal);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.InvalidRecoverToken.selector,
                address(0)
            )
        );
        vault.recover(reward, address(0));
    }

    function test_recover_invalid_token_reward_token() public {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(token), amount: 1000});

        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeAmount: 0,
            tokens: tokens
        });

        vm.prank(portal);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.InvalidRecoverToken.selector,
                address(token)
            )
        );
        vault.recover(reward, address(token));
    }

    function test_recover_zero_balance() public {
        TokenAmount[] memory tokens = new TokenAmount[](0);
        Reward memory reward = Reward({
            creator: creator,
            prover: address(0),
            deadline: uint64(block.timestamp + 1000),
            nativeAmount: 0,
            tokens: tokens
        });

        TestERC20 recoverToken = new TestERC20("Recover Token", "REC");

        vm.prank(portal);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.ZeroRecoverTokenBalance.selector,
                address(recoverToken)
            )
        );
        vault.recover(reward, address(recoverToken));
    }
}
