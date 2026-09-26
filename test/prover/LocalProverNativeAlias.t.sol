// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Portal} from "../../contracts/Portal.sol";
import {LocalProver} from "../../contracts/prover/LocalProver.sol";
import {Intent, Route, Reward, TokenAmount, Call} from "../../contracts/types/Intent.sol";

/// @dev Models Arc's shared balance: native transfers also change the ERC20 view.
/// Cheatcodes model protocol-native balance changes; this is not a production token.
contract NativeAliasToken {
    Vm private constant vm =
        Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    mapping(address => mapping(address => uint256)) public allowance;

    function balanceOf(address account) external view returns (uint256) {
        return account.balance / 1e12;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        uint256 nativeAmount = amount * 1e12;
        require(from.balance >= nativeAmount, "alias balance insufficient");
        vm.deal(from, from.balance - nativeAmount);
        vm.deal(to, to.balance + nativeAmount);
    }
}

/// @dev Models Gateway's ERC20 pull after Executor receives native or ERC20 USDC.
contract AliasDepositReceiver {
    function depositFor(
        address token,
        address recipient,
        uint256 amount
    ) external {
        require(
            NativeAliasToken(token).transferFrom(msg.sender, recipient, amount)
        );
    }
}

contract LocalProverNativeAliasTest is Test {
    Portal private portal;
    LocalProver private prover;
    NativeAliasToken private token;
    AliasDepositReceiver private gateway;
    address private creator;
    address private claimant;
    address private recipient;

    function setUp() public {
        token = new NativeAliasToken();
        portal = new Portal(address(token));
        prover = new LocalProver(address(portal));
        gateway = new AliasDepositReceiver();
        creator = makeAddr("creator");
        claimant = makeAddr("claimant");
        recipient = makeAddr("recipient");
        vm.deal(creator, 101 ether);
    }

    function test_erc20RoutePreservesPrincipalAndPaysRemainder() public {
        _fulfill(0, false);
    }

    function test_nativeGatewayRouteStillWorks() public {
        _fulfill(100 ether, true);
    }

    function test_mixedNativeAndErc20RouteUsesCombinedBudget() public {
        _fulfill(10 ether, false);
    }

    function _fulfill(uint256 nativeRoute, bool nativeReward) private {
        uint256 tokenRoute = (100 ether - nativeRoute) / 1e12;
        TokenAmount[] memory routeTokens = new TokenAmount[](
            tokenRoute == 0 ? 0 : 1
        );
        if (tokenRoute > 0)
            routeTokens[0] = TokenAmount(address(token), tokenRoute);
        TokenAmount[] memory rewardTokens = new TokenAmount[](
            nativeReward ? 0 : 1
        );
        if (!nativeReward) rewardTokens[0] = TokenAmount(address(token), 101e6);
        Call[] memory calls = new Call[](2);
        calls[0] = Call(
            address(token),
            abi.encodeCall(token.approve, (address(gateway), 100e6)),
            0
        );
        calls[1] = Call(
            address(gateway),
            abi.encodeCall(
                gateway.depositFor,
                (address(token), recipient, 100e6)
            ),
            0
        );
        Intent memory intent = Intent({
            destination: uint64(block.chainid),
            route: Route(
                bytes32(uint256(1)),
                uint64(block.timestamp + 1000),
                address(portal),
                nativeRoute,
                routeTokens,
                calls
            ),
            reward: Reward(
                uint64(block.timestamp + 2000),
                creator,
                address(prover),
                nativeReward ? 101 ether : 0,
                rewardTokens
            )
        });
        vm.startPrank(creator);
        token.approve(address(portal), 101e6);
        (bytes32 intentHash, address vault) = portal.publishAndFund{
            value: nativeReward ? 101 ether : 0
        }(intent, false);
        vm.stopPrank();
        vm.prank(claimant);
        prover.flashFulfill(
            intent.route,
            intent.reward,
            bytes32(uint256(uint160(claimant)))
        );
        assertEq(
            portal.claimants(intentHash),
            bytes32(uint256(uint160(claimant)))
        );
        assertEq(recipient.balance, 100 ether);
        assertEq(token.balanceOf(recipient), 100e6);
        assertEq(claimant.balance, 1 ether);
        assertEq(vault.balance, 0);
        assertEq(address(prover).balance, 0);
        assertEq(address(portal).balance, 0);
        assertEq(address(portal.executor()).balance, 0);
    }
}
