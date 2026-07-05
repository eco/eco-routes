// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DepositFactory_CCTPMint_Arc} from "../../contracts/deposit/DepositFactory_CCTPMint_Arc.sol";
import {DepositAddress_CCTPMint_Arc} from "../../contracts/deposit/DepositAddress_CCTPMint_Arc.sol";
import {Portal} from "../../contracts/Portal.sol";
import {ERC7683Implementation} from "../../contracts/ERC7683/ERC7683Implementation.sol";
import {PortalProxy} from "../../contracts/PortalProxy.sol";
import {Account as EcoAccount} from "../../contracts/account/Account.sol";
import {LocalPolicy} from "../../contracts/prover/LocalPolicy.sol";
import {Intent, Route, Reward, RewardToken, TokenAmount, IntentLib} from "../../contracts/types/Intent.sol";
import {Call} from "../../contracts/interfaces/IRuntime.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";

/**
 * @title MockGateway
 * @notice Mock Gateway contract for testing depositFor calls in the CCTP flow
 */
contract MockGateway {
    event DepositFor(address token, address recipient, uint256 amount);

    function depositFor(address token, address recipient, uint256 amount) external {
        emit DepositFor(token, recipient, amount);
    }
}

/**
 * @title DepositIntegration_CCTPMintTest
 * @notice Integration tests for the CCTP+Gateway dual-intent deposit flow.
 *         Exercises the end-to-end lifecycle: factory deployment, deterministic addressing,
 *         token deposits, dual-intent creation, and Portal funding across
 *         DepositFactory_CCTPMint_Arc, DepositAddress_CCTPMint_Arc, and Portal.
 */
contract DepositIntegration_CCTPMintTest is Test {
    DepositFactory_CCTPMint_Arc public factory;
    Portal public portal;
    LocalPolicy public prover;
    TestERC20 public token;

    // Configuration parameters (using same chain for testing)
    uint64 public CHAIN_ID;
    uint64 constant INTENT_DEADLINE_DURATION = 7 days;
    uint32 constant DESTINATION_DOMAIN = 6; // Arc CCTP domain
    uint64 constant ARC_CHAIN_ID = 41455;
    address constant ARC_PROVER_ADDRESS = address(0xBBBB);
    address constant ARC_USDC = address(0xCCCC);
    address constant GATEWAY_ADDRESS = address(0xDDDD);

    // Test user addresses
    address constant USER_DESTINATION = address(0x1111);
    address constant DEPOSITOR = address(0x3333);
    address constant SOLVER = address(0x4444);

    event IntentPublished(
        bytes32 indexed intentHash,
        uint64 destination,
        bytes route,
        address indexed keeper,
        address indexed prover,
        uint64 deadline,
        RewardToken[] rewardTokens
    );

    event IntentFunded(
        bytes32 indexed intentHash,
        address indexed funder,
        bool fullyFunded
    );

    event IntentFulfilled(
        bytes32 indexed intentHash,
        bytes32 indexed claimant,
        uint256 indexed destination
    );

    function setUp() public {
        // Set CHAIN_ID to current chain
        CHAIN_ID = uint64(block.chainid);

        // Deploy token (USDC on source chain)
        token = new TestERC20("USD Coin", "USDC");

        // Deploy Portal
        PortalProxy _proxy = new PortalProxy(address(this));
        EcoAccount _acct = new EcoAccount(address(_proxy));
        Portal _impl = new Portal(address(_acct), address(new ERC7683Implementation()));
        _proxy.registerVersion(1, address(_impl));
        portal = Portal(payable(address(_proxy)));

        // Deploy LocalPolicy (for same-chain testing)
        prover = new LocalPolicy(address(portal));

        // Deploy factory with dual-intent configuration
        factory = new DepositFactory_CCTPMint_Arc(
            address(token),
            address(portal),
            address(prover),
            INTENT_DEADLINE_DURATION,
            DESTINATION_DOMAIN,
            address(0xABCD), // CCTP TokenMessenger mock address
            ARC_CHAIN_ID,
            ARC_PROVER_ADDRESS,
            ARC_USDC,
            GATEWAY_ADDRESS,
            13 // 1.3 bps CCTP fast-deposit fee
        );

        // Fund solver
        vm.deal(SOLVER, 100 ether);
    }

    // ============ End-to-End Flow Tests ============

    /**
     * @notice Full end-to-end test: deploy factory, deploy deposit address,
     *         create dual intents, and verify funding
     */
    function test_integration_fullCCTPMintFlow() public {
        // 1. Get deposit address before deployment
        address depositAddr = factory.getDepositAddress(USER_DESTINATION, DEPOSITOR);
        assertFalse(factory.isDeployed(USER_DESTINATION, DEPOSITOR));

        // 2. User sends tokens to deposit address (simulating CEX withdrawal)
        uint256 depositAmount = 10_000 * 1e6; // 10,000 USDC
        token.mint(depositAddr, depositAmount);
        assertEq(token.balanceOf(depositAddr), depositAmount);

        // 3. Backend deploys deposit contract
        address deployed = factory.deploy(USER_DESTINATION, DEPOSITOR);
        assertEq(deployed, depositAddr);
        assertTrue(factory.isDeployed(USER_DESTINATION, DEPOSITOR));

        DepositAddress_CCTPMint_Arc depositAddress = DepositAddress_CCTPMint_Arc(deployed);
        assertEq(depositAddress.destinationAddress(), bytes32(uint256(uint160(USER_DESTINATION))));
        assertEq(depositAddress.depositor(), DEPOSITOR);

        // 4. Backend creates dual intents
        vm.recordLogs();
        bytes32 intentHash = depositAddress.createIntent();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(intentHash != bytes32(0));

        // 5. Verify tokens moved from deposit address to account
        assertEq(token.balanceOf(depositAddr), 0);

        // 6. Verify intent was funded (tokens moved to account)
        IIntentSource.Status status = portal.getRewardStatus(intentHash);
        assertEq(
            uint256(status),
            uint256(IIntentSource.Status.Funded),
            "Intent should be funded"
        );

        // 7. Verify two IntentPublished events were emitted
        bytes32 intentPublishedSig = keccak256(
            "IntentPublished(bytes32,uint64,bytes,address,address,uint64,(address,uint256,uint256)[])"
        );

        uint256 intentPublishedCount = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == intentPublishedSig) {
                intentPublishedCount++;
            }
        }
        assertEq(intentPublishedCount, 2, "Should emit exactly two IntentPublished events");
    }

    /**
     * @notice Test that the dual intent structure is correct by decoding the published events
     */
    function test_integration_intentStructureIsCorrect() public {
        address deployed = factory.deploy(USER_DESTINATION, DEPOSITOR);
        DepositAddress_CCTPMint_Arc depositAddress = DepositAddress_CCTPMint_Arc(deployed);

        uint256 depositAmount = 10_000 * 1e6;
        token.mint(deployed, depositAmount);

        // Create intent and capture events
        vm.recordLogs();
        bytes32 intentHash = depositAddress.createIntent();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 intentPublishedSig = keccak256(
            "IntentPublished(bytes32,uint64,bytes,address,address,uint64,(address,uint256,uint256)[])"
        );

        // Find and verify both IntentPublished events
        uint256 eventIdx = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == intentPublishedSig) {
                // Indexed fields
                bytes32 publishedIntentHash = logs[i].topics[1];
                address keeper = address(uint160(uint256(logs[i].topics[2])));

                // Non-indexed fields
                (
                    uint64 destination,
                    bytes memory routeBytes,
                    ,
                    RewardToken[] memory rewardTokens
                ) = abi.decode(
                    logs[i].data,
                    (uint64, bytes, uint64, RewardToken[])
                );

                Route memory route = abi.decode(routeBytes, (Route));
                Call[] memory calls = abi.decode(route.payload, (Call[]));

                if (eventIdx == 0) {
                    // Intent 2 (Gateway deposit on Arc) - published first
                    assertEq(destination, ARC_CHAIN_ID, "Intent 2 destination should be Arc chain");
                    assertEq(keeper, DEPOSITOR, "Intent 2 keeper should be depositor");
                    assertEq(route.portal, address(portal), "Intent 2 route portal should be portal address");
                    // Native USDC folds into a single native (address(0)) min-tokens leg.
                    assertEq(route.minTokens.length, 1, "Intent 2 route should have one native min-tokens leg (native USDC)");
                    assertEq(route.minTokens[0].token, address(0), "Intent 2 route min-tokens leg should be native (address(0))");
                    assertEq(calls.length, 2, "Intent 2 route should have two calls (approve + depositFor)");
                    assertEq(rewardTokens.length, 1, "Intent 2 reward should have one native leg (native USDC)");
                    assertEq(rewardTokens[0].token, address(0), "Intent 2 reward leg should be native (address(0))");
                } else {
                    // Intent 1 (CCTP burn on source chain) - published second
                    assertEq(publishedIntentHash, intentHash, "Intent 1 hash should match returned hash");
                    assertEq(destination, CHAIN_ID, "Intent 1 destination should be source chain");
                    assertEq(keeper, DEPOSITOR, "Intent 1 keeper should be depositor");
                    assertEq(route.portal, address(portal), "Intent 1 route portal should be portal address");
                    assertEq(route.minTokens.length, 1, "Intent 1 route should have one min-tokens leg");
                    assertEq(route.minTokens[0].token, address(token), "Intent 1 route min-tokens token should be source USDC");
                    assertEq(route.minTokens[0].amount, depositAmount, "Intent 1 route min-tokens amount should match deposit");
                    assertEq(calls.length, 2, "Intent 1 route should have two calls (approve + CCTP depositForBurn)");
                    assertEq(rewardTokens.length, 1, "Intent 1 reward should have one token");
                    assertEq(rewardTokens[0].token, address(token), "Intent 1 reward token should be source USDC");
                    assertEq(rewardTokens[0].flat, depositAmount, "Intent 1 reward flat should match deposit");
                }

                eventIdx++;
            }
        }

        assertEq(eventIdx, 2, "Should have found exactly two IntentPublished events");
    }

    /**
     * @notice Test multiple deposits and intents
     */
    function test_integration_multipleCCTPDeposits() public {
        address deployed = factory.deploy(USER_DESTINATION, DEPOSITOR);
        DepositAddress_CCTPMint_Arc depositAddress = DepositAddress_CCTPMint_Arc(deployed);

        // First deposit
        uint256 amount1 = 10_000 * 1e6;
        token.mint(deployed, amount1);
        bytes32 intentHash1 = depositAddress.createIntent();
        assertEq(token.balanceOf(deployed), 0);

        // Second deposit (new block.timestamp to avoid salt collision)
        vm.warp(block.timestamp + 1);
        uint256 amount2 = 5_000 * 1e6;
        token.mint(deployed, amount2);
        bytes32 intentHash2 = depositAddress.createIntent();
        assertEq(token.balanceOf(deployed), 0);

        // Intents should be different
        assertTrue(intentHash1 != intentHash2);

        // Both should be funded
        assertEq(
            uint256(portal.getRewardStatus(intentHash1)),
            uint256(IIntentSource.Status.Funded)
        );
        assertEq(
            uint256(portal.getRewardStatus(intentHash2)),
            uint256(IIntentSource.Status.Funded)
        );
    }

    /**
     * @notice Test different users get different deposit addresses
     */
    function test_integration_differentUsersGetDifferentAddresses() public {
        address user2Destination = address(0x2222);
        address depositor2 = address(0x4444);

        // Deploy for user 1
        address deployed1 = factory.deploy(USER_DESTINATION, DEPOSITOR);

        // Deploy for user 2
        address deployed2 = factory.deploy(user2Destination, depositor2);

        // Should have different addresses
        assertTrue(deployed1 != deployed2);

        // Both should work independently
        uint256 amount = 10_000 * 1e6;

        token.mint(deployed1, amount);
        bytes32 intentHash1 = DepositAddress_CCTPMint_Arc(deployed1).createIntent();

        vm.warp(block.timestamp + 1);
        token.mint(deployed2, amount);
        bytes32 intentHash2 = DepositAddress_CCTPMint_Arc(deployed2).createIntent();

        assertTrue(intentHash1 != bytes32(0));
        assertTrue(intentHash2 != bytes32(0));
        assertTrue(intentHash1 != intentHash2);
    }

    /**
     * @notice Test refund flow after deadline
     */
    function test_integration_refundFlowAfterDeadline() public {
        // Deploy and create intent
        address deployed = factory.deploy(USER_DESTINATION, DEPOSITOR);
        DepositAddress_CCTPMint_Arc depositAddress = DepositAddress_CCTPMint_Arc(deployed);

        uint256 amount = 10_000 * 1e6;
        token.mint(deployed, amount);
        bytes32 intentHash = depositAddress.createIntent();

        // Fast forward past deadline
        vm.warp(block.timestamp + INTENT_DEADLINE_DURATION + 1);

        // Note: Depositor can now call Portal.refund() directly since they are the intent keeper
        // This allows refunds through the normal intent flow without a separate function
        // Full refund testing is covered in Portal/IntentSource tests

        // Verify intent exists and is funded
        IIntentSource.Status status = portal.getRewardStatus(intentHash);
        assertEq(
            uint256(status),
            uint256(IIntentSource.Status.Funded),
            "Intent should be funded and ready for potential refund"
        );
    }

    /**
     * @notice Test deterministic addressing works
     */
    function test_integration_deterministicAddressingWorks() public {
        // Get predicted address
        address predicted = factory.getDepositAddress(USER_DESTINATION, DEPOSITOR);

        // Send tokens to predicted address before deployment
        uint256 amount = 10_000 * 1e6;
        token.mint(predicted, amount);
        assertEq(token.balanceOf(predicted), amount);

        // Deploy at predicted address
        address deployed = factory.deploy(USER_DESTINATION, DEPOSITOR);
        assertEq(deployed, predicted);

        // Tokens should still be there
        assertEq(token.balanceOf(deployed), amount);

        // Create intent should work
        DepositAddress_CCTPMint_Arc depositAddress = DepositAddress_CCTPMint_Arc(deployed);
        bytes32 intentHash = depositAddress.createIntent();
        assertTrue(intentHash != bytes32(0));
    }

    /**
     * @notice Test gas estimation for dual-intent flow
     */
    function test_integration_gasEstimation() public {
        // Deploy
        uint256 gasBefore = gasleft();
        address deployed = factory.deploy(USER_DESTINATION, DEPOSITOR);
        uint256 deployGas = gasBefore - gasleft();

        // Create intent
        token.mint(deployed, 10_000 * 1e6);
        gasBefore = gasleft();
        DepositAddress_CCTPMint_Arc(deployed).createIntent();
        uint256 createIntentGas = gasBefore - gasleft();

        // Log gas usage for reference
        emit log_named_uint("Deploy gas", deployGas);
        emit log_named_uint("CreateIntent gas (dual-intent)", createIntentGas);

        // Basic sanity checks
        assertTrue(deployGas > 0);
        assertTrue(createIntentGas > 0);
        assertTrue(deployGas < 500_000); // Should be < 500k for minimal proxy
        assertTrue(createIntentGas < 1_000_000); // Should be < 1M for dual-intent creation
    }

    // ============ CCTP → Account2 → Intent 2 Fulfillment Flow ============

    /**
     * @notice Tests the full two-intent CCTP flow:
     *         1. createIntent() publishes Intent 2 (Gateway deposit on Arc) and Intent 1 (CCTP burn),
     *            with Intent 2's account address as the CCTP mintRecipient.
     *         2. Simulates CCTP minting by funding account2 with native ETH (representing native USDC on Arc).
     *         3. Solver calls LocalPolicy.flashFulfill() for Intent 2, triggering Gateway.depositFor.
     *         4. Verifies Intent 2 is fulfilled and the solver is recorded as claimant.
     *
     * @dev Uses ARC_CHAIN_ID = block.chainid so the Arc LocalPolicy can prove Intent 2 locally.
     *      The MockGateway emits DepositFor without transferring tokens, allowing the route
     *      calls (approve + depositFor) to succeed in a test environment.
     */
    function test_integration_cctpMintsToAccount2AndSolverFulfillsIntent2() public {
        // --- Setup: factory with ARC_CHAIN_ID = block.chainid for local provability ---
        uint64 localChainId = uint64(block.chainid);

        MockGateway mockGateway = new MockGateway();
        TestERC20 arcUsdc = new TestERC20("Arc USDC", "AUSDC");
        LocalPolicy arcProver = new LocalPolicy(address(portal));

        DepositFactory_CCTPMint_Arc localFactory = new DepositFactory_CCTPMint_Arc(
            address(token),
            address(portal),
            address(prover),        // source chain LocalPolicy
            INTENT_DEADLINE_DURATION,
            DESTINATION_DOMAIN,
            address(0xABCD),        // CCTP TokenMessenger (mock address)
            localChainId,           // ARC_CHAIN_ID = block.chainid for local testing
            address(arcProver),     // Arc LocalPolicy (real, on same test chain)
            address(arcUsdc),
            address(mockGateway),
            0                       // maxFeeBps (0 = no fee cap for testing)
        );

        // --- Deploy deposit address and fund with source USDC ---
        address depositAddr = localFactory.deploy(USER_DESTINATION, DEPOSITOR);
        DepositAddress_CCTPMint_Arc da = DepositAddress_CCTPMint_Arc(depositAddr);

        uint256 depositAmount = 10_000 * 1e6; // 10,000 USDC (6 decimals)
        uint256 nativeReward = depositAmount * 1e12; // scaled to 18-decimal native USDC on Arc

        token.mint(depositAddr, depositAmount);

        // --- Create dual intents; capture Intent 2's route and reward from events ---
        vm.recordLogs();
        da.createIntent();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 intentPublishedSig = keccak256(
            "IntentPublished(bytes32,uint64,bytes,address,address,uint64,(address,uint256,uint256)[])"
        );

        // The first IntentPublished event is Intent 2 (Gateway deposit on Arc)
        Route memory route2;
        Reward memory reward2;
        bytes32 intent2Hash;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == intentPublishedSig) {
                intent2Hash = logs[i].topics[1];
                address keeper = address(uint160(uint256(logs[i].topics[2])));
                address proverAddr = address(uint160(uint256(logs[i].topics[3])));

                (
                    ,
                    bytes memory routeBytes,
                    uint64 rewardDeadline,
                    RewardToken[] memory rewardTokens
                ) = abi.decode(
                    logs[i].data,
                    (uint64, bytes, uint64, RewardToken[])
                );

                route2 = abi.decode(routeBytes, (Route));
                reward2 = Reward({
                    deadline: rewardDeadline,
                    keeper: keeper,
                    prover: proverAddr,
                    tokens: rewardTokens,
                    hooks: ""
                });

                break; // first IntentPublished = Intent 2
            }
        }

        assertTrue(intent2Hash != bytes32(0), "Intent 2 hash should be captured");
        // Native reward now folds into the address(0) reward leg's `flat` (no separate nativeAmount field).
        assertEq(reward2.tokens.length, 1, "Intent 2 reward should have one native leg");
        assertEq(reward2.tokens[0].token, address(0), "Intent 2 reward leg should be native (address(0))");
        assertEq(reward2.tokens[0].flat, nativeReward, "Intent 2 native reward should be scaled native USDC");

        // --- Derive account2 address ---
        // account2 is the reward account for Intent 2; CCTP mints native USDC here on Arc
        // Intent 2's source is always `uint64(block.chainid)` (the depositor's source chain) per
        // DepositAddress_CCTPMint_Arc's _constructGatewayIntent; this test sets ARC_CHAIN_ID ==
        // block.chainid for local provability, so source == destination == localChainId here.
        address account2 = portal.intentAccountAddress(1, localChainId, localChainId, abi.encode(route2), reward2);
        assertTrue(account2 != address(0), "account2 address should be non-zero");

        // --- Simulate CCTP mint: fund account2 with native ETH (= native USDC on Arc) ---
        vm.deal(account2, nativeReward);
        assertEq(address(account2).balance, nativeReward, "account2 should hold native USDC after CCTP mint");

        // --- Solver fulfills Intent 2 via Arc LocalPolicy.flashFulfill ---
        address solver = address(0x5555);
        // PR2: flashFulfill no longer flash-loans the reward. The solver must supply the route's native
        // capital (route2's native min-tokens leg, route2.minTokens[0].amount == nativeReward) up front as
        // msg.value; the reward is settled back afterwards.
        vm.deal(solver, nativeReward);

        vm.prank(solver);
        vm.recordLogs();
        arcProver.flashFulfill{value: nativeReward}(
            1,
            route2,
            reward2,
            bytes32(uint256(uint160(solver)))
        );
        Vm.Log[] memory fulfillLogs = vm.getRecordedLogs();

        // --- Verify account2 is drained ---
        assertEq(address(account2).balance, 0, "account2 should be empty after fulfillment");

        // --- Verify Gateway.depositFor was called with correct parameters ---
        bool foundDepositFor = false;
        for (uint256 i = 0; i < fulfillLogs.length; i++) {
            if (fulfillLogs[i].topics[0] == keccak256("DepositFor(address,address,uint256)")) {
                (address tokenArg, address recipient, uint256 amount) = abi.decode(
                    fulfillLogs[i].data,
                    (address, address, uint256)
                );
                assertEq(tokenArg, address(arcUsdc), "depositFor token should be arcUsdc");
                assertEq(recipient, USER_DESTINATION, "depositFor recipient should be user's destination address");
                assertEq(amount, depositAmount, "depositFor amount should match the 6-decimal deposit amount");
                foundDepositFor = true;
                break;
            }
        }
        assertTrue(foundDepositFor, "Gateway.depositFor should have been called");

        // --- Verify Intent 2 is fulfilled and solver is the claimant ---
        // Fulfillment storage lives in the prover now (arcProver, the Arc LocalPolicy named by
        // flashFulfill), not the Portal — read it via provenIntents. Intent 2 carries a single native
        // min-tokens leg, so `fulfilled == providedAmounts == [nativeReward]` (the input the solver provided).
        uint256[] memory expectedFulfilled = new uint256[](1);
        expectedFulfilled[0] = nativeReward;
        assertEq(
            arcProver.provenIntents(intent2Hash).fulfillmentHash,
            IntentLib.fulfillmentHash(
                intent2Hash,
                bytes32(uint256(uint160(solver))),
                expectedFulfilled
            ),
            "Arc prover should record the solver's fulfillment commitment"
        );
        assertEq(
            arcProver.provenIntents(intent2Hash).destination,
            localChainId,
            "Arc prover should record correct destination chain"
        );
    }
}
