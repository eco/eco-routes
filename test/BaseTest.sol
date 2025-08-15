// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IntentSource} from "../contracts/IntentSource.sol";
import {Inbox} from "../contracts/Inbox.sol";
import {Intent, Route, Reward, TokenAmount, Call} from "../contracts/types/Intent.sol";
import {TestERC20} from "../contracts/test/TestERC20.sol";

contract BaseTest is Test {
    IntentSource internal intentSource;
    Inbox internal inbox;
    TestERC20 internal tokenA;
    TestERC20 internal tokenB;

    address internal creator = makeAddr("creator");
    address internal claimant = makeAddr("claimant");
    address internal otherPerson = makeAddr("otherPerson");
    bytes32 internal salt = keccak256("salt");

    uint256 constant MINT_AMOUNT = 1_000_000 ether;

    Intent internal intent;
    Route internal route;
    Reward internal reward;

    function setUp() public virtual {
        vm.startPrank(creator);

        // Deploy test tokens
        tokenA = new TestERC20("Token A", "TKNA");
        tokenB = new TestERC20("Token B", "TKNB");

        // Deploy core contracts
        intentSource = new IntentSource();
        address[] memory solvers = new address[](0);
        inbox = new Inbox(creator, true, solvers);

        _setupTestData();

        vm.stopPrank();
    }

    function _setupTestData() internal {
        // Set up route with token transfers
        TokenAmount[] memory routeTokens = new TokenAmount[](1);
        routeTokens[0] = TokenAmount({
            token: address(tokenA),
            amount: 100 ether
        });

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: address(tokenB),
            value: 0,
            data: abi.encodeWithSignature("transfer(address,uint256)", claimant, 50 ether)
        });

        route = Route({
            salt: salt,
            source: uint256(block.chainid),
            destination: 1,
            inbox: address(inbox),
            tokens: routeTokens,
            calls: calls
        });

        // Set up reward
        TokenAmount[] memory rewardTokens = new TokenAmount[](1);
        rewardTokens[0] = TokenAmount({
            token: address(tokenA),
            amount: 10 ether
        });

        reward = Reward({
            creator: creator,
            prover: address(0), // Will be set when needed in tests
            deadline: block.timestamp + 1 hours,
            nativeValue: 0.1 ether,
            tokens: rewardTokens
        });

        // Create intent
        intent = Intent({
            route: route,
            reward: reward
        });
    }

    function _hashIntent(Intent memory _intent) internal pure returns (bytes32) {
        return keccak256(abi.encode(_intent.route, _intent.reward));
    }

    function _mintAndApprove(address user, uint256 amount) internal {
        tokenA.mint(user, amount);
        tokenB.mint(user, amount);
        
        vm.startPrank(user);
        tokenA.approve(address(intentSource), amount);
        tokenA.approve(address(inbox), amount);
        tokenB.approve(address(intentSource), amount);
        tokenB.approve(address(inbox), amount);
        vm.stopPrank();
    }

    function _fundUserNative(address user, uint256 amount) internal {
        vm.deal(user, amount);
    }

    function _expectEmit() internal {
        vm.expectEmit(true, true, true, true);
    }
}