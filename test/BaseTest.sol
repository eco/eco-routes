// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {TestERC20} from "../contracts/test/TestERC20.sol";
import {BadERC20} from "../contracts/test/BadERC20.sol";
import {FakePermit} from "../contracts/test/FakePermit.sol";
import {TestProver} from "../contracts/test/TestProver.sol";
import {IntentSource} from "../contracts/IntentSource.sol";
import {Inbox} from "../contracts/Inbox.sol";
import {IIntentSource} from "../contracts/interfaces/IIntentSource.sol";
import {Intent, Route, Reward, TokenAmount, Call} from "../contracts/types/Intent.sol";
import {OnchainCrosschainOrderData, GaslessCrosschainOrderData} from "../contracts/types/EcoERC7683.sol";

contract BaseTest is Test {
    // Constants
    uint256 internal constant MINT_AMOUNT = 1000;
    uint256 internal constant REWARD_NATIVE_ETH = 2 ether;
    uint256 internal constant EXPIRY_DURATION = 123;
    uint96 internal constant CHAIN_ID = 1;

    // Test addresses
    address internal creator;
    address internal claimant;
    address internal otherPerson;
    address internal deployer;

    // Core contracts
    IntentSource internal intentSource;
    TestProver internal prover;
    Inbox internal inbox;

    // Test tokens
    TestERC20 internal tokenA;
    TestERC20 internal tokenB;

    // Test data
    bytes32 internal salt;
    uint256 internal expiry;
    TokenAmount[] internal routeTokens;
    Call[] internal calls;
    TokenAmount[] internal rewardTokens;
    Route internal route;
    Reward internal reward;
    Intent internal intent;

    function setUp() public virtual {
        // Setup test addresses
        creator = makeAddr("creator");
        claimant = makeAddr("claimant");
        otherPerson = makeAddr("otherPerson");
        deployer = makeAddr("deployer");

        vm.startPrank(deployer);

        // Deploy core contracts
        intentSource = new IntentSource();
        inbox = new Inbox();
        prover = new TestProver(address(inbox));

        // Deploy test tokens
        tokenA = new TestERC20("TokenA", "TKA");
        tokenB = new TestERC20("TokenB", "TKB");

        vm.stopPrank();

        // Setup test data
        _setupTestData();
    }

    function _setupTestData() internal {
        expiry = block.timestamp + EXPIRY_DURATION;
        salt = keccak256(abi.encodePacked(uint256(0), block.chainid));

        // Setup route tokens
        routeTokens.push(
            TokenAmount({token: address(tokenA), amount: MINT_AMOUNT})
        );

        // Setup calls
        calls.push(
            Call({
                target: address(tokenA),
                data: abi.encodeWithSignature(
                    "transfer(address,uint256)",
                    creator,
                    MINT_AMOUNT
                ),
                value: 0
            })
        );

        // Setup reward tokens
        rewardTokens.push(
            TokenAmount({token: address(tokenA), amount: MINT_AMOUNT})
        );
        rewardTokens.push(
            TokenAmount({token: address(tokenB), amount: MINT_AMOUNT * 2})
        );

        // Create memory copies of arrays for struct assignment
        TokenAmount[] memory routeTokensMemory = new TokenAmount[](
            routeTokens.length
        );
        for (uint256 i = 0; i < routeTokens.length; i++) {
            routeTokensMemory[i] = routeTokens[i];
        }

        Call[] memory callsMemory = new Call[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            callsMemory[i] = calls[i];
        }

        TokenAmount[] memory rewardTokensMemory = new TokenAmount[](
            rewardTokens.length
        );
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            rewardTokensMemory[i] = rewardTokens[i];
        }

        // Setup route
        route = Route({
            salt: salt,
            source: block.chainid,
            destination: CHAIN_ID,
            inbox: address(inbox),
            tokens: routeTokensMemory,
            calls: callsMemory
        });

        // Setup reward
        reward = Reward({
            creator: creator,
            prover: address(prover),
            deadline: expiry,
            nativeValue: 0,
            tokens: rewardTokensMemory
        });

        // Setup intent
        intent = Intent({route: route, reward: reward});
    }

    function _mintAndApprove(address user, uint256 amount) internal {
        vm.startPrank(user);
        tokenA.mint(user, amount);
        tokenB.mint(user, amount * 2);
        tokenA.approve(address(intentSource), amount);
        tokenB.approve(address(intentSource), amount * 2);
        vm.stopPrank();
    }

    function _fundUserNative(address user, uint256 amount) internal {
        vm.deal(user, amount);
    }

    function _hashIntent(
        Intent memory _intent
    ) internal pure virtual returns (bytes32) {
        bytes32 routeHash = keccak256(abi.encode(_intent.route));
        bytes32 rewardHash = keccak256(abi.encode(_intent.reward));
        return keccak256(abi.encodePacked(routeHash, rewardHash));
    }

    function _addProof(
        bytes32 intentHash,
        uint96 destinationChainId,
        address recipient
    ) internal {
        vm.prank(creator);
        if (destinationChainId == uint96(block.chainid)) {
            prover.addProvenIntent(intentHash, recipient);
        } else {
            prover.addProvenIntentWithChain(
                intentHash,
                recipient,
                destinationChainId
            );
        }
    }

    function _publishAndFund(
        Intent memory _intent,
        bool allowPartial
    ) internal {
        vm.prank(creator);
        intentSource.publishAndFund(_intent, allowPartial);
    }

    function _publishAndFundWithValue(
        Intent memory _intent,
        bool allowPartial,
        uint256 value
    ) internal {
        vm.prank(creator);
        intentSource.publishAndFund{value: value}(_intent, allowPartial);
    }

    function _timeTravel(uint256 timestamp) internal {
        vm.warp(timestamp);
    }

    function _expectRevert(bytes4 selector) internal {
        vm.expectRevert(selector);
    }

    function _expectEmit() internal {
        vm.expectEmit(true, true, true, true);
    }
}
