// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Account as EcoAccount} from "../../contracts/account/Account.sol";
import {AccountTron} from "../../contracts/tron/AccountTron.sol";
import {IAccount} from "../../contracts/interfaces/IAccount.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {IPermit} from "../../contracts/interfaces/IPermit.sol";
import {IPolicy} from "../../contracts/interfaces/IPolicy.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";
import {TestPolicy} from "../../contracts/test/TestPolicy.sol";
import {TronUSDTMock} from "../../contracts/test/TronUSDTMock.sol";
import {Reward, RewardToken} from "../../contracts/types/Intent.sol";
import {Clones} from "../../contracts/account/Clones.sol";

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

contract AccountTest is Test {
    using Clones for address;

    IAccount internal account;
    TestERC20 internal token;
    MockPermit internal mockPermit;
    TestPolicy internal prover;

    address internal portal;
    address internal keeper;
    address internal claimant;
    address internal unauthorized;

    function setUp() public {
        portal = makeAddr("portal");
        keeper = makeAddr("keeper");
        claimant = makeAddr("claimant");
        unauthorized = makeAddr("unauthorized");

        vm.prank(portal);
        account = IAccount(address(new EcoAccount()).clone(bytes32(0)));

        token = new TestERC20("Test Token", "TEST");
        mockPermit = new MockPermit();

        // The Account now consults `reward.prover.previewRelease(...)` during withdraw, so
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
            keeper: keeper,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens,
            hooks: ""
        });

        vm.prank(portal);
        assertTrue(
            account.fundFor(reward, _targets(reward), keeper, IPermit(address(0)))
        );

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccount.NotPortalCaller.selector,
                unauthorized
            )
        );
        account.fundFor(reward, _targets(reward), keeper, IPermit(address(0)));
    }

    function test_fundFor_success_emptyReward() public {
        RewardToken[] memory tokens = new RewardToken[](0);
        Reward memory reward = Reward({
            keeper: keeper,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens,
            hooks: ""
        });

        vm.prank(portal);
        bool result = account.fundFor(
            reward,
            _targets(reward),
            keeper,
            IPermit(address(0))
        );

        assertTrue(result);
    }

    function test_fundFor_success_nativeAndTokens() public {
        RewardToken[] memory tokens = new RewardToken[](2);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});
        tokens[1] = RewardToken({token: address(0), rate: 0, flat: 1 ether});

        Reward memory reward = Reward({
            keeper: keeper,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens,
            hooks: ""
        });

        token.mint(keeper, 1000);
        vm.prank(keeper);
        token.approve(address(account), 1000);

        vm.deal(portal, 2 ether);
        vm.prank(portal);
        bool result = account.fundFor{value: 1 ether}(
            reward,
            _targets(reward),
            keeper,
            IPermit(address(0))
        );

        assertTrue(result);
        assertEq(address(account).balance, 1 ether);
        assertEq(token.balanceOf(address(account)), 1000);
    }

    function test_fundFor_partialFunding_insufficientNative() public {
        RewardToken[] memory tokens = new RewardToken[](1);
        tokens[0] = RewardToken({token: address(0), rate: 0, flat: 2 ether});
        Reward memory reward = Reward({
            keeper: keeper,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens,
            hooks: ""
        });

        vm.deal(portal, 1 ether);
        vm.prank(portal);
        bool result = account.fundFor{value: 1 ether}(
            reward,
            _targets(reward),
            keeper,
            IPermit(address(0))
        );

        assertFalse(result);
        assertEq(address(account).balance, 1 ether);
    }

    function test_fundFor_partialFunding_insufficientTokens() public {
        RewardToken[] memory tokens = new RewardToken[](1);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 2000});

        Reward memory reward = Reward({
            keeper: keeper,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens,
            hooks: ""
        });

        token.mint(keeper, 1000);
        vm.prank(keeper);
        token.approve(address(account), 1000);

        vm.prank(portal);
        bool result = account.fundFor(
            reward,
            _targets(reward),
            keeper,
            IPermit(address(0))
        );

        assertFalse(result);
        assertEq(token.balanceOf(address(account)), 1000);
    }

    function test_fundFor_success_multipleTokens() public {
        IERC20 token2 = new TestERC20("Test Token 2", "TEST2");

        RewardToken[] memory tokens = new RewardToken[](2);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});
        tokens[1] = RewardToken({token: address(token2), rate: 0, flat: 500});

        Reward memory reward = Reward({
            keeper: keeper,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens,
            hooks: ""
        });

        token.mint(keeper, 1000);
        vm.prank(keeper);
        token.approve(address(account), 1000);

        TestERC20(address(token2)).mint(keeper, 500);
        vm.prank(keeper);
        token2.approve(address(account), 500);

        vm.prank(portal);
        bool result = account.fundFor(
            reward,
            _targets(reward),
            keeper,
            IPermit(address(0))
        );

        assertTrue(result);
        assertEq(token.balanceOf(address(account)), 1000);
        assertEq(token2.balanceOf(address(account)), 500);
    }

    function test_fundFor_not_portal_caller() public {
        RewardToken[] memory tokens = new RewardToken[](0);
        Reward memory reward = Reward({
            keeper: keeper,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens,
            hooks: ""
        });

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccount.NotPortalCaller.selector,
                unauthorized
            )
        );
        account.fundFor(reward, _targets(reward), keeper, IPermit(address(0)));
    }

    function test_fundFor_success_prefundedAccount() public {
        RewardToken[] memory tokens = new RewardToken[](2);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});
        tokens[1] = RewardToken({token: address(0), rate: 0, flat: 1 ether});

        Reward memory reward = Reward({
            keeper: keeper,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens,
            hooks: ""
        });

        token.mint(address(account), 1000);
        vm.deal(address(account), 1 ether);

        vm.prank(portal);
        bool result = account.fundFor(
            reward,
            _targets(reward),
            keeper,
            IPermit(address(0))
        );

        assertTrue(result);
        assertEq(address(account).balance, 1 ether);
        assertEq(token.balanceOf(address(account)), 1000);
    }

    function test_fundFor_success_partiallyPrefunded() public {
        RewardToken[] memory tokens = new RewardToken[](2);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});
        tokens[1] = RewardToken({token: address(0), rate: 0, flat: 1 ether});

        Reward memory reward = Reward({
            keeper: keeper,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens,
            hooks: ""
        });

        token.mint(address(account), 500);
        vm.deal(address(account), 0.5 ether);

        token.mint(keeper, 500);
        vm.prank(keeper);
        token.approve(address(account), 500);

        vm.deal(portal, 1 ether);
        vm.prank(portal);
        bool result = account.fundFor{value: 0.5 ether}(
            reward,
            _targets(reward),
            keeper,
            IPermit(address(0))
        );

        assertTrue(result);
        assertEq(address(account).balance, 1 ether);
        assertEq(token.balanceOf(address(account)), 1000);
    }

    function test_fundFor_success_withPermit() public {
        RewardToken[] memory tokens = new RewardToken[](1);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});

        Reward memory reward = Reward({
            keeper: keeper,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens,
            hooks: ""
        });

        token.mint(keeper, 1000);
        vm.prank(keeper);
        token.approve(address(mockPermit), 1000);

        mockPermit.setAllowance(keeper, address(token), address(account), 1000);

        vm.prank(portal);
        bool result = account.fundFor(
            reward,
            _targets(reward),
            keeper,
            IPermit(address(mockPermit))
        );

        assertTrue(result);
        assertEq(token.balanceOf(address(account)), 1000);
        assertEq(token.balanceOf(keeper), 0);
    }

    function test_fundFor_success_withPermit_partialFromPermit() public {
        RewardToken[] memory tokens = new RewardToken[](1);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});

        Reward memory reward = Reward({
            keeper: keeper,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens,
            hooks: ""
        });

        token.mint(keeper, 1000);
        vm.prank(keeper);
        token.approve(address(account), 500);
        vm.prank(keeper);
        token.approve(address(mockPermit), 500);

        mockPermit.setAllowance(keeper, address(token), address(account), 500);

        vm.prank(portal);
        bool result = account.fundFor(
            reward,
            _targets(reward),
            keeper,
            IPermit(address(mockPermit))
        );

        assertTrue(result);
        assertEq(token.balanceOf(address(account)), 1000);
        assertEq(token.balanceOf(keeper), 0);
    }

    function test_fundFor_success_withPermit_fallbackToRegularApproval()
        public
    {
        RewardToken[] memory tokens = new RewardToken[](1);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});

        Reward memory reward = Reward({
            keeper: keeper,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens,
            hooks: ""
        });

        token.mint(keeper, 1000);
        vm.prank(keeper);
        token.approve(address(account), 1000);

        vm.prank(portal);
        bool result = account.fundFor(
            reward,
            _targets(reward),
            keeper,
            IPermit(address(mockPermit))
        );

        assertTrue(result);
        assertEq(token.balanceOf(address(account)), 1000);
        assertEq(token.balanceOf(keeper), 0);
    }

    function test_fundFor_partial_withPermit_insufficientPermitAllowance()
        public
    {
        RewardToken[] memory tokens = new RewardToken[](1);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});

        Reward memory reward = Reward({
            keeper: keeper,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens,
            hooks: ""
        });

        token.mint(keeper, 1000);
        vm.prank(keeper);
        token.approve(address(mockPermit), 500);

        mockPermit.setAllowance(keeper, address(token), address(account), 500);

        vm.prank(portal);
        bool result = account.fundFor(
            reward,
            _targets(reward),
            keeper,
            IPermit(address(mockPermit))
        );

        assertFalse(result);
        assertEq(token.balanceOf(address(account)), 500);
        assertEq(token.balanceOf(keeper), 500);
    }

    function test_withdraw_success_emptyReward() public {
        RewardToken[] memory tokens = new RewardToken[](0);
        Reward memory reward = Reward({
            keeper: keeper,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens,
            hooks: ""
        });

        vm.prank(portal);
        account.withdraw(reward, claimant, _noFulfilled());
    }

    function test_withdraw_success_nativeAndTokens() public {
        RewardToken[] memory tokens = new RewardToken[](2);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});
        tokens[1] = RewardToken({token: address(0), rate: 0, flat: 1 ether});

        Reward memory reward = Reward({
            keeper: keeper,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens,
            hooks: ""
        });

        token.mint(address(account), 1000);
        vm.deal(address(account), 1 ether);

        uint256 claimantInitialBalance = claimant.balance;

        vm.prank(portal);
        account.withdraw(reward, claimant, _noFulfilled());

        assertEq(address(account).balance, 0);
        assertEq(token.balanceOf(address(account)), 0);
        assertEq(claimant.balance, claimantInitialBalance + 1 ether);
        assertEq(token.balanceOf(claimant), 1000);
    }

    function test_withdraw_success_multipleTokens() public {
        IERC20 token2 = new TestERC20("Test Token 2", "TEST2");

        RewardToken[] memory tokens = new RewardToken[](2);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});
        tokens[1] = RewardToken({token: address(token2), rate: 0, flat: 500});

        Reward memory reward = Reward({
            keeper: keeper,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens,
            hooks: ""
        });

        token.mint(address(account), 1000);
        TestERC20(address(token2)).mint(address(account), 500);

        vm.prank(portal);
        account.withdraw(reward, claimant, _noFulfilled());

        assertEq(token.balanceOf(address(account)), 0);
        assertEq(token2.balanceOf(address(account)), 0);
        assertEq(token.balanceOf(claimant), 1000);
        assertEq(token2.balanceOf(claimant), 500);
    }

    function test_withdraw_success_partialWithdraw_insufficientTokens() public {
        RewardToken[] memory tokens = new RewardToken[](1);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});

        Reward memory reward = Reward({
            keeper: keeper,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens,
            hooks: ""
        });

        token.mint(address(account), 500);

        vm.prank(portal);
        account.withdraw(reward, claimant, _noFulfilled());

        assertEq(token.balanceOf(address(account)), 0);
        assertEq(token.balanceOf(claimant), 500);
    }

    function test_withdraw_success_partialWithdraw_insufficientNative() public {
        RewardToken[] memory tokens = new RewardToken[](1);
        tokens[0] = RewardToken({token: address(0), rate: 0, flat: 2 ether});
        Reward memory reward = Reward({
            keeper: keeper,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens,
            hooks: ""
        });

        vm.deal(address(account), 1 ether);

        uint256 claimantInitialBalance = claimant.balance;

        vm.prank(portal);
        account.withdraw(reward, claimant, _noFulfilled());

        assertEq(address(account).balance, 0);
        assertEq(claimant.balance, claimantInitialBalance + 1 ether);
    }

    function test_withdraw_success_fromFundedAccount() public {
        RewardToken[] memory tokens = new RewardToken[](2);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});
        tokens[1] = RewardToken({token: address(0), rate: 0, flat: 1 ether});

        Reward memory reward = Reward({
            keeper: keeper,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens,
            hooks: ""
        });

        token.mint(keeper, 1000);
        vm.prank(keeper);
        token.approve(address(account), 1000);

        vm.deal(portal, 1 ether);
        vm.prank(portal);
        account.fundFor{value: 1 ether}(
            reward,
            _targets(reward),
            keeper,
            IPermit(address(0))
        );

        uint256 claimantInitialBalance = claimant.balance;

        vm.prank(portal);
        account.withdraw(reward, claimant, _noFulfilled());

        assertEq(address(account).balance, 0);
        assertEq(token.balanceOf(address(account)), 0);
        assertEq(claimant.balance, claimantInitialBalance + 1 ether);
        assertEq(token.balanceOf(claimant), 1000);
    }

    function test_withdraw_not_portal_caller() public {
        RewardToken[] memory tokens = new RewardToken[](0);
        Reward memory reward = Reward({
            keeper: keeper,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens,
            hooks: ""
        });

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccount.NotPortalCaller.selector,
                unauthorized
            )
        );
        account.withdraw(reward, claimant, _noFulfilled());
    }

    function test_refund_success_emptyReward_afterDeadline() public {
        RewardToken[] memory tokens = new RewardToken[](0);
        Reward memory reward = Reward({
            keeper: keeper,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens,
            hooks: ""
        });

        vm.warp(block.timestamp + 2000);

        vm.prank(portal);
        account.refund(reward, keeper);
    }

    function test_refund_success_nativeAndTokens_afterDeadline() public {
        RewardToken[] memory tokens = new RewardToken[](2);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});
        tokens[1] = RewardToken({token: address(0), rate: 0, flat: 1 ether});

        Reward memory reward = Reward({
            keeper: keeper,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens,
            hooks: ""
        });

        token.mint(address(account), 1000);
        vm.deal(address(account), 1 ether);

        uint256 keeperInitialBalance = keeper.balance;

        vm.warp(block.timestamp + 2000);

        vm.prank(portal);
        account.refund(reward, keeper);

        assertEq(address(account).balance, 0);
        assertEq(token.balanceOf(address(account)), 0);
        assertEq(keeper.balance, keeperInitialBalance + 1 ether);
        assertEq(token.balanceOf(keeper), 1000);
    }

    function test_refund_success_multipleTokens_afterDeadline() public {
        IERC20 token2 = new TestERC20("Test Token 2", "TEST2");

        RewardToken[] memory tokens = new RewardToken[](2);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});
        tokens[1] = RewardToken({token: address(token2), rate: 0, flat: 500});

        Reward memory reward = Reward({
            keeper: keeper,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens,
            hooks: ""
        });

        token.mint(address(account), 1000);
        TestERC20(address(token2)).mint(address(account), 500);

        vm.warp(block.timestamp + 2000);

        vm.prank(portal);
        account.refund(reward, keeper);

        assertEq(token.balanceOf(address(account)), 0);
        assertEq(token2.balanceOf(address(account)), 0);
        assertEq(token.balanceOf(keeper), 1000);
        assertEq(token2.balanceOf(keeper), 500);
    }

    function test_refund_success_zeroTokenBalance_afterDeadline() public {
        RewardToken[] memory tokens = new RewardToken[](1);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});

        Reward memory reward = Reward({
            keeper: keeper,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens,
            hooks: ""
        });

        vm.warp(block.timestamp + 2000);

        vm.prank(portal);
        account.refund(reward, keeper);

        assertEq(token.balanceOf(address(account)), 0);
        assertEq(token.balanceOf(keeper), 0);
    }

    function test_refund_success_fromFundedAccount_afterDeadline() public {
        RewardToken[] memory tokens = new RewardToken[](2);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});
        tokens[1] = RewardToken({token: address(0), rate: 0, flat: 1 ether});

        Reward memory reward = Reward({
            keeper: keeper,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens,
            hooks: ""
        });

        token.mint(keeper, 1000);
        vm.prank(keeper);
        token.approve(address(account), 1000);

        vm.deal(portal, 1 ether);
        vm.prank(portal);
        account.fundFor{value: 1 ether}(
            reward,
            _targets(reward),
            keeper,
            IPermit(address(0))
        );

        uint256 keeperInitialBalance = keeper.balance;

        vm.warp(block.timestamp + 2000);

        vm.prank(portal);
        account.refund(reward, keeper);

        assertEq(address(account).balance, 0);
        assertEq(token.balanceOf(address(account)), 0);
        assertEq(keeper.balance, keeperInitialBalance + 1 ether);
        assertEq(token.balanceOf(keeper), 1000);
    }

    function test_refund_success_fromWithdrawnStatus() public {
        RewardToken[] memory tokens = new RewardToken[](2);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});
        tokens[1] = RewardToken({token: address(0), rate: 0, flat: 1 ether});

        Reward memory reward = Reward({
            keeper: keeper,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens,
            hooks: ""
        });

        token.mint(address(account), 1000);
        vm.deal(address(account), 1 ether);

        vm.prank(portal);
        account.withdraw(reward, claimant, _noFulfilled());

        // Capture AFTER the withdraw: the withdraw fully drained the account (claimant accepts, so no
        // residual sweep to keeper), so refund moves nothing and the keeper balance is unchanged.
        uint256 keeperInitialBalance = keeper.balance;

        vm.prank(portal);
        account.refund(reward, keeper);

        assertEq(address(account).balance, 0);
        assertEq(token.balanceOf(address(account)), 0);
        assertEq(keeper.balance, keeperInitialBalance);
        assertEq(token.balanceOf(keeper), 0);
    }

    function test_refund_not_portal_caller() public {
        RewardToken[] memory tokens = new RewardToken[](0);
        Reward memory reward = Reward({
            keeper: keeper,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens,
            hooks: ""
        });

        vm.warp(block.timestamp + 2000);

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccount.NotPortalCaller.selector,
                unauthorized
            )
        );
        account.refund(reward, keeper);
    }

    function test_refund_refund_twice() public {
        RewardToken[] memory tokens = new RewardToken[](0);
        Reward memory reward = Reward({
            keeper: keeper,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens,
            hooks: ""
        });

        vm.warp(block.timestamp + 2000);

        vm.prank(portal);
        account.refund(reward, keeper);

        vm.prank(portal);
        account.refund(reward, keeper);
    }

    function test_recover_success_differentToken() public {
        TestERC20 differentToken = new TestERC20("Different Token", "DIFF");
        differentToken.mint(address(account), 500);

        uint256 keeperInitialBalance = differentToken.balanceOf(keeper);

        vm.prank(portal);
        account.recover(keeper, address(differentToken));

        assertEq(differentToken.balanceOf(address(account)), 0);
        assertEq(
            differentToken.balanceOf(keeper),
            keeperInitialBalance + 500
        );
    }

    function test_recover_not_portal_caller() public {
        TestERC20 recoverToken = new TestERC20("Recover Token", "REC");

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccount.NotPortalCaller.selector,
                unauthorized
            )
        );
        account.recover(keeper, address(recoverToken));
    }

    function test_recover_zero_balance() public {
        TestERC20 recoverToken = new TestERC20("Recover Token", "REC");

        vm.prank(portal);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccount.ZeroRecoverTokenBalance.selector,
                address(recoverToken)
            )
        );
        account.recover(keeper, address(recoverToken));
    }

    function test_withdraw_success_withRevertingClaimant() public {
        // Deploy a contract that always reverts on receive
        RevertingClaimant revertingClaimant = new RevertingClaimant();

        RewardToken[] memory tokens = new RewardToken[](2);
        tokens[0] = RewardToken({token: address(token), rate: 0, flat: 1000});
        tokens[1] = RewardToken({token: address(0), rate: 0, flat: 1 ether});

        Reward memory reward = Reward({
            keeper: keeper, // Normal address that accepts ETH
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens,
            hooks: ""
        });

        token.mint(address(account), 1000);
        vm.deal(address(account), 1 ether);

        uint256 keeperBefore = keeper.balance;

        // Withdrawal succeeds: tokens transfer to the claimant, the claimant rejects the native pay,
        // so that 1 ether becomes residual and is swept to the keeper (funds conserved, not stuck).
        vm.prank(portal);
        account.withdraw(reward, address(revertingClaimant), _noFulfilled());

        // Account fully drained: the un-received native was swept to the keeper.
        assertEq(address(account).balance, 0);
        assertEq(token.balanceOf(address(account)), 0);

        // Native swept to the keeper (the claimant rejected it).
        assertEq(keeper.balance, keeperBefore + 1 ether);

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
            keeper: keeper, // Normal keeper address
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens,
            hooks: ""
        });

        token.mint(address(account), 1000);
        vm.deal(address(account), 1 ether);

        vm.warp(block.timestamp + 2000);

        // Refund should succeed - tokens transfer, ETH remains if refundee rejects
        vm.prank(portal);
        account.refund(reward, address(revertingRefundee));

        // Verify ETH remains in account (refundee rejected it)
        assertEq(address(account).balance, 1 ether);
        assertEq(token.balanceOf(address(account)), 0);

        // Verify refundee received tokens but NOT native ETH (reverted)
        assertEq(address(revertingRefundee).balance, 0);
        assertEq(token.balanceOf(address(revertingRefundee)), 1000);
    }

    // ── TetherToken (Tron USDT) compatibility ─────────────────────────────────

    /**
     * @notice Reproduces the exact on-chain failure seen when withdrawing USDT
     *         rewards locked in a account on Tron (Shasta testnet).
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
     * `false`, and reverts with SafeERC20FailedOperation(token).  The account
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

        // Fund the account via transferFrom (which returns true) — mirrors
        // what publishAndFund does on-chain.
        tether.approve(address(this), 100_000);
        tether.transferFrom(address(this), address(account), 100_000);
        assertEq(tether.balanceOf(address(account)), 100_000);

        RewardToken[] memory tokens = new RewardToken[](1);
        tokens[0] = RewardToken({
            token: address(tether),
            rate: 0,
            flat: 100_000
        });

        Reward memory reward = Reward({
            keeper: keeper,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens,
            hooks: ""
        });

        // Base Account uses SafeERC20 and will revert when TronUSDTMock.transfer()
        // returns false (the ERC20 leg transfer reverts before any residual sweep) —
        // Tron USDT compatibility is handled by AccountTron instead.
        vm.prank(portal);
        vm.expectRevert();
        account.withdraw(reward, claimant, _noFulfilled());
    }

    function test_withdraw_succeeds_withTetherToken_usingAccountTron() public {
        // Deploy the mock that reproduces StandardTokenWithFees.transfer()
        // returning false (no explicit return statement in solc 0.4.18).
        TronUSDTMock tether = new TronUSDTMock(10_000_000);

        // Deploy a AccountTron clone (Tron-aware account) for this test.
        // vm.prank sets msg.sender for the constructor so portal is set correctly.
        vm.prank(portal);
        IAccount accountTron = IAccount(
            address(new AccountTron()).clone(bytes32(uint256(1)))
        );

        // Fund via transferFrom (returns true) — mirrors publishAndFund on-chain.
        tether.approve(address(this), 100_000);
        tether.transferFrom(address(this), address(accountTron), 100_000);
        assertEq(tether.balanceOf(address(accountTron)), 100_000);

        RewardToken[] memory tokens = new RewardToken[](1);
        tokens[0] = RewardToken({
            token: address(tether),
            rate: 0,
            flat: 100_000
        });

        Reward memory reward = Reward({
            keeper: keeper,
            prover: address(prover),
            deadline: uint64(block.timestamp + 1000),
            tokens: tokens,
            hooks: ""
        });

        // AccountTron uses a raw call so it succeeds even though
        // TronUSDTMock.transfer() returns false (reproducing the Tron USDT bug).
        // The balance check in _transferToken confirms tokens actually moved.
        vm.prank(portal);
        accountTron.withdraw(reward, claimant, _noFulfilled());

        // Tokens left the account and arrived at the claimant.
        assertEq(tether.balanceOf(address(accountTron)), 0);
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
