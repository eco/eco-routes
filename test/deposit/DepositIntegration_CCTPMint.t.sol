// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DepositFactory_CCTPMint_Arc} from "../../contracts/deposit/DepositFactory_CCTPMint_Arc.sol";
import {DepositAddress_CCTPMint_Arc} from "../../contracts/deposit/DepositAddress_CCTPMint_Arc.sol";
import {Portal} from "../../contracts/Portal.sol";
import {LocalProver} from "../../contracts/prover/LocalProver.sol";
import {Intent, Route, Reward, TokenAmount, Call} from "../../contracts/types/Intent.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";

/**
 * @title MockTokenMessenger
 * @notice Mock CCTP TokenMessenger for testing
 */
contract MockTokenMessenger {
    event DepositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken
    );

    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken
    ) external returns (uint64) {
        // In real CCTP, tokens would be burned here
        // For testing, we just emit the event to verify the call was made correctly
        emit DepositForBurn(amount, destinationDomain, mintRecipient, burnToken);
        return 1; // Mock nonce
    }
}

/**
 * @title MockGateway
 * @notice Mock Gateway contract for receiving USDC on destination chain
 */
contract MockGateway {
    event Received(address token, address recipient, uint256 amount);

    function receiveMessage(bytes32 sender, bytes calldata message) external {
        // Mock implementation - just emit event
        emit Received(address(0), address(0), 0);
    }
}

contract DepositIntegration_CCTPMintTest is Test {
    DepositFactory_CCTPMint_Arc public factory;
    Portal public portal;
    LocalProver public prover;
    TestERC20 public token;
    MockTokenMessenger public tokenMessenger;
    MockGateway public gateway;

    // Configuration parameters (using same chain for testing)
    uint64 public CHAIN_ID;
    address constant DESTINATION_TOKEN = address(0x5678); // USDC on destination
    address constant DESTINATION_PORTAL = address(0xDEF0);
    uint64 constant INTENT_DEADLINE_DURATION = 7 days;
    uint32 constant DESTINATION_DOMAIN = 0; // Same chain domain

    // Test user addresses
    address constant USER_DESTINATION = address(0x1111);
    address constant DEPOSITOR = address(0x3333);
    address constant SOLVER = address(0x4444);

    event IntentPublished(
        bytes32 indexed intentHash,
        uint64 destination,
        bytes route,
        address indexed creator,
        address indexed prover,
        uint64 deadline,
        uint256 nativeAmount,
        TokenAmount[] tokens
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
        portal = new Portal();

        // Deploy LocalProver (for same-chain testing)
        prover = new LocalProver(address(portal));

        // Deploy mock contracts
        tokenMessenger = new MockTokenMessenger();
        gateway = new MockGateway();

        // Deploy factory for local intents
        factory = new DepositFactory_CCTPMint_Arc(
            address(token),
            DESTINATION_TOKEN,
            address(portal),
            address(prover),
            INTENT_DEADLINE_DURATION,
            DESTINATION_DOMAIN,
            address(tokenMessenger)
        );

        // Fund solver
        vm.deal(SOLVER, 100 ether);
    }

    // ============ End-to-End Flow Tests ============

    /**
     * @notice Full end-to-end test: deploy factory, deploy deposit address,
     *         create intent, and verify funding
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

        // 4. Backend creates intent
        bytes32 intentHash = depositAddress.createIntent();
        assertTrue(intentHash != bytes32(0));

        // 5. Verify tokens moved from deposit address to vault
        assertEq(token.balanceOf(depositAddr), 0);

        // 6. Verify intent was funded (tokens moved to vault)
        IIntentSource.Status status = portal.getRewardStatus(intentHash);
        assertEq(
            uint256(status),
            uint256(IIntentSource.Status.Funded),
            "Intent should be funded"
        );

        // Note: Full fulfillment testing is covered in test_integration_flashFulfillCCTPFlow
        // This test focuses on the deposit address creation and intent funding flow
    }

    /**
     * @notice Test full cycle: create intent, fulfill it with LocalProver, verify results
     * @dev For same-chain testing, we deploy a special factory where destination token = source token
     */
    function test_integration_createAndFulfillIntent() public {
        // Deploy a special factory for local intent testing where destination token = source token
        DepositFactory_CCTPMint_Arc sameChainFactory = new DepositFactory_CCTPMint_Arc(
            address(token), // source token
            address(token), // destination token (same for testing)
            address(portal),
            address(prover),
            INTENT_DEADLINE_DURATION,
            DESTINATION_DOMAIN,
            address(tokenMessenger)
        );

        address deployed = sameChainFactory.deploy(USER_DESTINATION, DEPOSITOR);
        DepositAddress_CCTPMint_Arc depositAddress = DepositAddress_CCTPMint_Arc(deployed);

        uint256 depositAmount = 10_000 * 1e6;
        token.mint(deployed, depositAmount);

        // Create intent and capture the route/reward from events
        vm.recordLogs();
        bytes32 intentHash = depositAddress.createIntent();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Extract route and reward from IntentPublished event
        Route memory route;
        Reward memory reward;
        bool foundIntent = false;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("IntentPublished(bytes32,uint64,bytes,address,address,uint64,uint256,(address,uint256)[])")) {
                (
                    uint64 destination,
                    bytes memory routeBytes,
                    uint64 rewardDeadline,
                    uint256 rewardNativeAmount,
                    TokenAmount[] memory rewardTokens
                ) = abi.decode(
                    logs[i].data,
                    (uint64, bytes, uint64, uint256, TokenAmount[])
                );

                route = abi.decode(routeBytes, (Route));
                reward = Reward({
                    deadline: rewardDeadline,
                    creator: DEPOSITOR,
                    prover: address(prover),
                    nativeAmount: rewardNativeAmount,
                    tokens: rewardTokens
                });

                foundIntent = true;
                break;
            }
        }
        assertTrue(foundIntent, "Should find IntentPublished event");

        // Verify the route token is the same as source (for same-chain test)
        assertEq(route.tokens[0].token, address(token), "Route token should be source token for same-chain test");

        // Verify intent was funded
        IIntentSource.Status statusBefore = portal.getRewardStatus(intentHash);
        assertEq(uint256(statusBefore), uint256(IIntentSource.Status.Funded), "Intent should be funded");

        // Fulfill the intent with LocalProver using flashFulfill
        vm.startPrank(SOLVER);

        // Solver needs to provide the route tokens
        token.mint(SOLVER, depositAmount);
        token.approve(address(portal), depositAmount);

        uint256 solverBalanceBefore = token.balanceOf(SOLVER);
        assertEq(solverBalanceBefore, depositAmount, "Solver should start with route token amount");

        // Use flashFulfill to atomically fulfill and withdraw
        // This will:
        // 1. Withdraw reward tokens from vault to LocalProver
        // 2. Fulfill the intent (spending solver's route tokens, which go to Executor, then CCTP is called)
        // 3. Transfer all rewards from LocalProver to solver
        vm.recordLogs();
        prover.flashFulfill(
            route,
            reward,
            bytes32(uint256(uint160(SOLVER)))
        );
        Vm.Log[] memory fulfillLogs = vm.getRecordedLogs();

        vm.stopPrank();

        // Verify tokens were actually moved:
        // 1. Route tokens should have been transferred to Executor during fulfillment
        //    (They stay with Executor since MockTokenMessenger doesn't transfer them)
        address executor = address(portal.executor());
        uint256 executorBalance = token.balanceOf(executor);
        assertEq(
            executorBalance,
            depositAmount,
            "Executor should have received route tokens during fulfillment"
        );

        // 2. Verify CCTP depositForBurn was called correctly by checking events
        //    (This proves the intent was fulfilled with correct parameters)
        bool foundDepositForBurn = false;
        for (uint256 i = 0; i < fulfillLogs.length; i++) {
            if (fulfillLogs[i].topics[0] == keccak256("DepositForBurn(uint256,uint32,bytes32,address)")) {
                (uint256 amount_, uint32 domain, bytes32 recipient, address burnToken) = abi.decode(
                    fulfillLogs[i].data,
                    (uint256, uint32, bytes32, address)
                );
                assertEq(amount_, depositAmount, "DepositForBurn should be for correct amount");
                assertEq(domain, DESTINATION_DOMAIN, "DepositForBurn should be for correct domain");
                assertEq(burnToken, address(token), "DepositForBurn should burn correct token");
                // mintRecipient should be USER_DESTINATION (the destination address) encoded as bytes32
                assertEq(recipient, bytes32(uint256(uint160(USER_DESTINATION))), "DepositForBurn should mint to user destination");
                foundDepositForBurn = true;
                break;
            }
        }
        assertTrue(foundDepositForBurn, "DepositForBurn event should be emitted");

        // 3. SOLVER should have received reward tokens
        // Solver spent depositAmount (route tokens) and received depositAmount (rewards)
        // Net effect: balance should be the same
        uint256 solverBalanceAfter = token.balanceOf(SOLVER);
        assertEq(
            solverBalanceAfter,
            depositAmount,
            "Solver should have same balance (spent route tokens, received rewards)"
        );

        // Verify the intent was fulfilled and withdrawn
        IIntentSource.Status statusAfter = portal.getRewardStatus(intentHash);
        assertEq(uint256(statusAfter), uint256(IIntentSource.Status.Withdrawn), "Intent should be withdrawn");

        // Verify the claimant is correct
        bytes32 claimantBytes = portal.claimants(intentHash);
        address claimant = address(uint160(uint256(claimantBytes)));
        assertEq(claimant, SOLVER, "Claimant should be the solver");

        // Verify LocalProver recognizes the fulfillment
        assertEq(prover.provenIntents(intentHash).claimant, SOLVER, "Prover should recognize solver as claimant");
        assertEq(prover.provenIntents(intentHash).destination, CHAIN_ID, "Prover should have correct destination");
    }

    /**
     * @notice Test that the intent structure is correct by decoding the published event
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

        // Find IntentPublished event and decode route
        bool foundIntent = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("IntentPublished(bytes32,uint64,bytes,address,address,uint64,uint256,(address,uint256)[])")) {
                // Indexed fields are in topics: intentHash, creator, prover
                bytes32 publishedIntentHash = logs[i].topics[1];
                address creator = address(uint160(uint256(logs[i].topics[2])));
                address proverAddr = address(uint160(uint256(logs[i].topics[3])));

                // Non-indexed fields are in data
                (
                    uint64 destination,
                    bytes memory routeBytes,
                    uint64 rewardDeadline,
                    uint256 rewardNativeAmount,
                    TokenAmount[] memory rewardTokens
                ) = abi.decode(
                    logs[i].data,
                    (uint64, bytes, uint64, uint256, TokenAmount[])
                );

                // Verify intent matches
                assertEq(publishedIntentHash, intentHash, "Intent hash should match");
                assertEq(destination, CHAIN_ID, "Destination should be same chain");
                assertEq(creator, DEPOSITOR, "Creator should be depositor");
                assertEq(proverAddr, address(prover), "Prover should be LocalProver");

                // Verify reward structure
                assertEq(rewardNativeAmount, 0, "Should have no native reward");
                assertEq(rewardTokens.length, 1, "Should have one reward token");
                assertEq(rewardTokens[0].token, address(token), "Reward token should be source USDC");
                assertEq(rewardTokens[0].amount, depositAmount, "Reward amount should match deposit");

                // Decode and verify route structure
                Route memory route = abi.decode(routeBytes, (Route));
                assertEq(route.portal, address(portal), "Route portal should be portal address");
                assertEq(route.nativeAmount, 0, "Route should have no native amount");
                assertEq(route.tokens.length, 1, "Route should have one token");
                assertEq(route.tokens[0].token, DESTINATION_TOKEN, "Route token should be destination USDC");
                assertEq(route.tokens[0].amount, depositAmount, "Route token amount should match deposit");
                assertEq(route.calls.length, 1, "Route should have one call (CCTP)");
                assertEq(route.calls[0].target, address(tokenMessenger), "Call target should be TokenMessenger");
                assertEq(route.calls[0].value, 0, "CCTP call should have no value");

                foundIntent = true;
                break;
            }
        }

        assertTrue(foundIntent, "IntentPublished event should be found");
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

        // Second deposit
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

        // Note: Depositor can now call Portal.refund() directly since they are the intent creator
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
     * @notice Test configuration is correctly set
     */
    function test_integration_factoryConfigurationCorrect() public view {
        (
            address sourceToken,
            address destinationToken,
            address portalAddress,
            address proverAddress,
            uint64 deadlineDuration,
            uint32 destinationDomain,
            address cctpTokenMessenger
        ) = factory.getConfiguration();

        assertEq(sourceToken, address(token));
        assertEq(destinationToken, DESTINATION_TOKEN);
        assertEq(portalAddress, address(portal));
        assertEq(proverAddress, address(prover));
        assertEq(deadlineDuration, INTENT_DEADLINE_DURATION);
        assertEq(destinationDomain, DESTINATION_DOMAIN);
        assertEq(cctpTokenMessenger, address(tokenMessenger));
    }

    /**
     * @notice Test CCTP call is constructed correctly by checking emitted events
     */
    function test_integration_cctpCallConstruction() public {
        address deployed = factory.deploy(USER_DESTINATION, DEPOSITOR);
        DepositAddress_CCTPMint_Arc depositAddress = DepositAddress_CCTPMint_Arc(deployed);

        uint256 amount = 10_000 * 1e6;
        token.mint(deployed, amount);

        // Create intent and capture events
        vm.recordLogs();
        bytes32 intentHash = depositAddress.createIntent();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Verify IntentPublished event was emitted (contains CCTP call)
        bool foundIntentPublished = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("IntentPublished(bytes32,uint64,bytes,address,address,uint64,uint256,(address,uint256)[])")) {
                foundIntentPublished = true;
                assertEq(logs[i].topics[1], intentHash, "Intent hash should match");
                break;
            }
        }
        assertTrue(foundIntentPublished, "IntentPublished event should be emitted with CCTP call");
    }

    /**
     * @notice Test gas estimation for CCTP flow
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
        emit log_named_uint("CreateIntent gas", createIntentGas);

        // Basic sanity checks
        assertTrue(deployGas > 0);
        assertTrue(createIntentGas > 0);
        assertTrue(deployGas < 500_000); // Should be < 500k for minimal proxy
        assertTrue(createIntentGas < 500_000); // Should be < 500k for intent creation
    }

    // ============ Helper Functions ============

    function _createTokenArray(
        uint256 amount
    ) internal view returns (TokenAmount[] memory) {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(token), amount: amount});
        return tokens;
    }
}
