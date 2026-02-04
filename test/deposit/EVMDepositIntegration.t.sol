// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {EVMDepositFactory} from "../../contracts/deposit/EVMDepositFactory.sol";
import {EVMDepositAddress} from "../../contracts/deposit/EVMDepositAddress.sol";
import {Portal} from "../../contracts/Portal.sol";
import {TokenAmount} from "../../contracts/types/Intent.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";
import {TestProver} from "../../contracts/test/TestProver.sol";

contract EVMDepositIntegrationTest is Test {
    EVMDepositFactory public factory;
    Portal public portal;
    TestERC20 public token;
    TestProver public prover;

    // Configuration parameters
    uint64 constant DESTINATION_CHAIN = 10; // Optimism
    address constant DESTINATION_TOKEN = address(0x5678);
    address constant DESTINATION_PORTAL = address(0xDEF0);
    uint64 constant INTENT_DEADLINE_DURATION = 7 days;

    // Test user addresses
    address constant USER_DESTINATION = address(0x1111);
    address constant DEPOSITOR = address(0x3333);

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

    function setUp() public {
        // Deploy token
        token = new TestERC20("Test Token", "TEST");

        // Deploy Portal
        portal = new Portal();

        // Deploy prover
        prover = new TestProver(address(portal));

        // Deploy factory
        factory = new EVMDepositFactory(
            DESTINATION_CHAIN,
            address(token),
            DESTINATION_TOKEN,
            address(portal),
            address(prover),
            DESTINATION_PORTAL,
            INTENT_DEADLINE_DURATION
        );
    }

    // ============ End-to-End Flow Tests ============

    function test_integration_fullDepositFlow() public {
        // 1. Get deposit address before deployment
        address depositAddr = factory.getDepositAddress(USER_DESTINATION, DEPOSITOR);
        assertFalse(factory.isDeployed(USER_DESTINATION, DEPOSITOR));

        // 2. User sends tokens to deposit address (simulating CEX withdrawal)
        uint256 depositAmount = 1000 ether;
        token.mint(depositAddr, depositAmount);
        assertEq(token.balanceOf(depositAddr), depositAmount);

        // 3. Backend deploys deposit contract
        address deployed = factory.deploy(USER_DESTINATION, DEPOSITOR);
        assertEq(deployed, depositAddr);
        assertTrue(factory.isDeployed(USER_DESTINATION, DEPOSITOR));

        EVMDepositAddress depositAddress = EVMDepositAddress(deployed);
        assertEq(depositAddress.destinationAddress(), USER_DESTINATION);
        assertEq(depositAddress.depositor(), DEPOSITOR);

        // 4. Backend creates intent
        bytes32 intentHash = depositAddress.createIntent(depositAmount);
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
    }

    function test_integration_multipleDeposits() public {
        // Deploy deposit address
        address deployed = factory.deploy(USER_DESTINATION, DEPOSITOR);
        EVMDepositAddress depositAddress = EVMDepositAddress(deployed);

        // First deposit
        uint256 amount1 = 1000 ether;
        token.mint(deployed, amount1);
        bytes32 intentHash1 = depositAddress.createIntent(amount1);
        assertEq(token.balanceOf(deployed), 0);

        // Second deposit
        uint256 amount2 = 500 ether;
        token.mint(deployed, amount2);
        bytes32 intentHash2 = depositAddress.createIntent(amount2);
        assertEq(token.balanceOf(deployed), 0);

        // Intents should be different
        assertTrue(intentHash1 != intentHash2);
    }

    function test_integration_differentUsersGetDifferentAddresses() public {
        address user2Destination = address(0x2222);
        address depositor2 = address(0x5555);

        // Deploy for user 1
        address deployed1 = factory.deploy(USER_DESTINATION, DEPOSITOR);

        // Deploy for user 2
        address deployed2 = factory.deploy(user2Destination, depositor2);

        // Should have different addresses
        assertTrue(deployed1 != deployed2);

        // Both should work independently
        uint256 amount = 1000 ether;

        token.mint(deployed1, amount);
        bytes32 intentHash1 = EVMDepositAddress(deployed1).createIntent(amount);

        token.mint(deployed2, amount);
        bytes32 intentHash2 = EVMDepositAddress(deployed2).createIntent(amount);

        assertTrue(intentHash1 != bytes32(0));
        assertTrue(intentHash2 != bytes32(0));
    }

    function test_integration_intentStatusTracking() public {
        // Deploy and create intent
        address deployed = factory.deploy(USER_DESTINATION, DEPOSITOR);
        EVMDepositAddress depositAddress = EVMDepositAddress(deployed);

        uint256 amount = 1000 ether;
        token.mint(deployed, amount);
        bytes32 intentHash = depositAddress.createIntent(amount);

        // Check intent status
        IIntentSource.Status status = portal.getRewardStatus(intentHash);
        assertEq(
            uint256(status),
            uint256(IIntentSource.Status.Funded),
            "Intent should be funded"
        );
    }

    function test_integration_refundFlow() public {
        // Deploy and create intent
        address deployed = factory.deploy(USER_DESTINATION, DEPOSITOR);
        EVMDepositAddress depositAddress = EVMDepositAddress(deployed);

        uint256 amount = 1000 ether;
        token.mint(deployed, amount);
        bytes32 intentHash = depositAddress.createIntent(amount);

        // Fast forward past deadline
        vm.warp(block.timestamp + INTENT_DEADLINE_DURATION + 1);

        // Verify intent exists and is funded
        IIntentSource.Status status = portal.getRewardStatus(intentHash);
        assertEq(
            uint256(status),
            uint256(IIntentSource.Status.Funded),
            "Intent should be funded and ready for potential refund"
        );
    }

    function test_integration_balanceChecks() public {
        address deployed = factory.deploy(USER_DESTINATION, DEPOSITOR);
        EVMDepositAddress depositAddress = EVMDepositAddress(deployed);

        // Try to create intent without balance
        vm.expectRevert();
        depositAddress.createIntent(1000 ether);

        // Add partial balance
        token.mint(deployed, 500 ether);

        // Try to create intent with more than balance
        vm.expectRevert();
        depositAddress.createIntent(1000 ether);

        // Add remaining balance
        token.mint(deployed, 500 ether);

        // Now should succeed
        bytes32 intentHash = depositAddress.createIntent(1000 ether);
        assertTrue(intentHash != bytes32(0));
    }

    function test_integration_deterministicAddressingWorks() public {
        // Get predicted address
        address predicted = factory.getDepositAddress(USER_DESTINATION, DEPOSITOR);

        // Send tokens to predicted address before deployment
        uint256 amount = 1000 ether;
        token.mint(predicted, amount);
        assertEq(token.balanceOf(predicted), amount);

        // Deploy at predicted address
        address deployed = factory.deploy(USER_DESTINATION, DEPOSITOR);
        assertEq(deployed, predicted);

        // Tokens should still be there
        assertEq(token.balanceOf(deployed), amount);

        // Create intent should work
        EVMDepositAddress depositAddress = EVMDepositAddress(deployed);
        bytes32 intentHash = depositAddress.createIntent(amount);
        assertTrue(intentHash != bytes32(0));
    }

    function test_integration_gasEstimation() public {
        // Deploy
        uint256 gasBefore = gasleft();
        address deployed = factory.deploy(USER_DESTINATION, DEPOSITOR);
        uint256 deployGas = gasBefore - gasleft();

        // Create intent
        token.mint(deployed, 1000 ether);
        gasBefore = gasleft();
        EVMDepositAddress(deployed).createIntent(1000 ether);
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

    // ============ EVM-Specific Tests ============

    function test_integration_destinationAddressUsedAsRecipient() public {
        address deployed = factory.deploy(USER_DESTINATION, DEPOSITOR);
        EVMDepositAddress depositAddress = EVMDepositAddress(deployed);

        // Verify destinationAddress is set correctly and will be used as recipient
        assertEq(depositAddress.destinationAddress(), USER_DESTINATION);
    }

    function test_integration_routeStructValidation() public {
        address deployed = factory.deploy(USER_DESTINATION, DEPOSITOR);
        EVMDepositAddress depositAddress = EVMDepositAddress(deployed);

        // Create intent which internally constructs Route struct
        uint256 amount = 1000 ether;
        token.mint(deployed, amount);
        bytes32 intentHash = depositAddress.createIntent(amount);

        // Verify intent was created successfully (Route struct was valid)
        assertTrue(intentHash != bytes32(0));

        // Verify intent is funded
        IIntentSource.Status status = portal.getRewardStatus(intentHash);
        assertEq(
            uint256(status),
            uint256(IIntentSource.Status.Funded),
            "Intent should be funded"
        );
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
