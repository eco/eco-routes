// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {TypeCasts} from "@hyperlane-xyz/core/contracts/libs/TypeCasts.sol";

import {TestERC20} from "../contracts/test/TestERC20.sol";
import {BadERC20} from "../contracts/test/BadERC20.sol";
import {FakePermit} from "../contracts/test/FakePermit.sol";
import {TestPolicy} from "../contracts/test/TestPolicy.sol";
import {Portal} from "../contracts/Portal.sol";
import {Inbox} from "../contracts/Inbox.sol";
import {IIntentSource} from "../contracts/interfaces/IIntentSource.sol";
import {Intent, Route, Reward, RewardToken, TokenAmount, Call, IntentLib} from "../contracts/types/Intent.sol";
import {OrderData} from "../contracts/types/ERC7683.sol";

contract BaseTest is Test {
    // Constants
    uint256 internal constant MINT_AMOUNT = 1000;
    uint256 internal constant REWARD_NATIVE_ETH = 2 ether;
    uint256 internal constant EXPIRY_DURATION = 123;
    uint64 internal constant CHAIN_ID = 1;

    // Test addresses
    address internal keeper;
    address internal claimant;
    address internal otherPerson;
    address internal deployer;

    // Core contracts
    Portal internal portal;
    IIntentSource internal intentSource; // Interface for Portal
    Inbox internal inbox; // Backward compatibility alias
    TestPolicy internal prover;

    // Test tokens
    TestERC20 internal tokenA;
    TestERC20 internal tokenB;

    // Test data
    bytes32 internal salt;
    uint256 internal expiry;
    TokenAmount[] internal minTokens;
    Call[] internal calls;
    RewardToken[] internal rewardTokens;
    Route internal route;
    Reward internal reward;
    Intent internal intent;

    function setUp() public virtual {
        // Setup test addresses
        keeper = makeAddr("keeper");
        claimant = makeAddr("claimant");
        otherPerson = makeAddr("otherPerson");
        deployer = makeAddr("deployer");

        vm.startPrank(deployer);

        // Deploy core contracts
        portal = new Portal();
        // Set backward compatibility aliases
        intentSource = IIntentSource(address(portal));
        inbox = Inbox(payable(address(portal)));
        prover = new TestPolicy(address(portal));

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

        // Setup the solver-input floor: one ERC20 leg (tokenA). The solver must provide at least
        // MINT_AMOUNT of tokenA into the execution; the calls consume it (transfer to the beneficiary
        // encoded in the call's calldata).
        minTokens.push(
            TokenAmount({token: address(tokenA), amount: MINT_AMOUNT})
        );

        // Setup calls
        calls.push(
            Call({
                target: address(tokenA),
                data: abi.encodeWithSignature(
                    "transfer(address,uint256)",
                    keeper,
                    MINT_AMOUNT
                ),
                value: 0
            })
        );

        // Setup reward legs (rate 0 => fixed `flat` reward, v2 parity). Leg 0 (tokenA) pairs positionally
        // with minTokens[0]; leg 1 (tokenB) is a flat-only extra.
        rewardTokens.push(
            RewardToken({token: address(tokenA), rate: 0, flat: MINT_AMOUNT})
        );
        rewardTokens.push(
            RewardToken({token: address(tokenB), rate: 0, flat: MINT_AMOUNT * 2})
        );

        // Create memory copies of arrays for struct assignment
        TokenAmount[] memory minTokensMemory = new TokenAmount[](minTokens.length);
        for (uint256 i = 0; i < minTokens.length; i++) {
            minTokensMemory[i] = minTokens[i];
        }

        Call[] memory callsMemory = new Call[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            callsMemory[i] = calls[i];
        }

        RewardToken[] memory rewardTokensMemory = new RewardToken[](
            rewardTokens.length
        );
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            rewardTokensMemory[i] = rewardTokens[i];
        }

        // Setup route (input-floor model: `minTokens` is what the solver provides; delivery is the job of
        // the committed `calls`, and any unconsumed input is moved to the intent's Account).
        route = Route({
            salt: salt,
            deadline: uint64(expiry),
            portal: address(portal),
            keeper: keeper,
            calls: callsMemory,
            minTokens: minTokensMemory
        });

        // Setup reward
        reward = Reward({
            deadline: uint64(expiry),
            keeper: keeper,
            prover: address(prover),
            tokens: rewardTokensMemory
        });

        // Setup intent
        intent = Intent({destination: CHAIN_ID, route: route, reward: reward});
    }

    /**
     * @notice Empty `fulfilled` / `providedAmounts` array (for intents that carry no min-tokens legs).
     */
    function _noFulfilled() internal pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    /**
     * @notice Returns a copy of `arr` sorted strictly ascending by token address (native `address(0)`
     *         first), as `Route.minTokens` requires. Insertion sort — arrays are tiny (<= MAX_IN_TOKENS).
     */
    function _sortTokenAmounts(
        TokenAmount[] memory arr
    ) internal pure returns (TokenAmount[] memory) {
        uint256 n = arr.length;
        for (uint256 i = 1; i < n; ++i) {
            TokenAmount memory key = arr[i];
            uint256 j = i;
            while (j > 0 && uint160(arr[j - 1].token) > uint160(key.token)) {
                arr[j] = arr[j - 1];
                --j;
            }
            arr[j] = key;
        }
        return arr;
    }

    /**
     * @notice The default intent's `fulfilled` / `providedAmounts`: one leg of MINT_AMOUNT, aligned with
     *         the default `minTokens` (the solver provides exactly the floor). In the input-floor model
     *         `fulfilled == providedAmounts`.
     */
    function _defaultFulfilled() internal pure returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = MINT_AMOUNT;
        return amounts;
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
        return
            keccak256(
                abi.encodePacked(_intent.destination, routeHash, rewardHash)
            );
    }

    /**
     * @notice Injects a proven (hash-only) fact for the default intent (fulfilled = [MINT_AMOUNT]).
     * @param intentHash Intent hash
     * @param destinationChainId Destination chain id
     * @param recipient The claimant committed in the fulfillment
     */
    function _addProof(
        bytes32 intentHash,
        uint96 destinationChainId,
        address recipient
    ) internal {
        vm.prank(keeper);
        prover.addProvenFulfillment(
            intentHash,
            bytes32(uint256(uint160(recipient))),
            _defaultFulfilled(),
            uint64(destinationChainId)
        );
    }

    /**
     * @notice Settles the default intent (fulfilled = [MINT_AMOUNT]) to `claimantAddr`.
     */
    function _settle(
        uint64 destination,
        bytes32 routeHash,
        Reward memory _reward,
        address claimantAddr
    ) internal {
        intentSource.settle(
            destination,
            routeHash,
            _reward,
            bytes32(uint256(uint160(claimantAddr))),
            _defaultFulfilled()
        );
    }

    function _publishAndFund(
        Intent memory _intent,
        bool allowPartial
    ) internal {
        vm.prank(keeper);
        intentSource.publishAndFund(_intent, allowPartial);
    }

    function _publishAndFundWithValue(
        Intent memory _intent,
        bool allowPartial,
        uint256 value
    ) internal {
        vm.prank(keeper);
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
