// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DepositFactory_GatewayDeposit} from "../../contracts/deposit/DepositFactory_GatewayDeposit.sol";
import {DepositAddress_GatewayDeposit} from "../../contracts/deposit/DepositAddress_GatewayDeposit.sol";
import {BaseDepositAddress} from "../../contracts/deposit/BaseDepositAddress.sol";
import {Portal} from "../../contracts/Portal.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";

contract DepositAddress_GatewayDepositTest is Test {
    DepositFactory_GatewayDeposit public factory;
    DepositAddress_GatewayDeposit public depositAddress;
    Portal public portal;
    TestERC20 public token;

    // Configuration parameters
    uint64 constant DESTINATION_CHAIN = 42161; // Arbitrum
    address constant DESTINATION_TOKEN = address(0x5678);
    address constant PROVER_ADDRESS = address(0x9ABC);
    address constant DESTINATION_PORTAL = address(0xDEF0);
    address constant GATEWAY = address(0xAAAA);
    uint64 constant INTENT_DEADLINE_DURATION = 7 days;

    // Test user addresses
    address constant USER_DESTINATION = address(0x1111);
    address constant DEPOSITOR = address(0x3333);
    address constant ATTACKER = address(0x6666);

    function setUp() public {
        // Deploy token
        token = new TestERC20("Test Token", "TEST");

        // Deploy Portal
        portal = new Portal();

        // Deploy factory
        factory = new DepositFactory_GatewayDeposit(
            DESTINATION_CHAIN,
            address(token),
            DESTINATION_TOKEN,
            address(portal),
            PROVER_ADDRESS,
            DESTINATION_PORTAL,
            GATEWAY,
            INTENT_DEADLINE_DURATION
        );

        // Deploy deposit address
        address deployed = factory.deploy(USER_DESTINATION, DEPOSITOR);
        depositAddress = DepositAddress_GatewayDeposit(deployed);
    }

    // ============ Initialization Tests ============

    function test_initialize_setsDestinationAddress() public view {
        assertEq(depositAddress.destinationAddress(), USER_DESTINATION);
    }

    function test_initialize_setsDepositor() public view {
        assertEq(depositAddress.depositor(), DEPOSITOR);
    }

    function test_initialize_revertsIfAlreadyInitialized() public {
        vm.expectRevert(BaseDepositAddress.AlreadyInitialized.selector);
        depositAddress.initialize(USER_DESTINATION, DEPOSITOR);
    }

    function test_initialize_revertsIfNotCalledByFactory() public {
        // Deploy implementation directly (not via factory)
        DepositAddress_GatewayDeposit implementation = new DepositAddress_GatewayDeposit();

        vm.prank(ATTACKER);
        vm.expectRevert(BaseDepositAddress.OnlyFactory.selector);
        implementation.initialize(USER_DESTINATION, DEPOSITOR);
    }

    function test_initialize_revertsIfDepositorIsZero() public {
        vm.expectRevert(BaseDepositAddress.InvalidDepositor.selector);
        factory.deploy(USER_DESTINATION, address(0));
    }

    function test_initialize_revertsIfDestinationAddressIsZero() public {
        vm.expectRevert(BaseDepositAddress.InvalidDestinationAddress.selector);
        factory.deploy(address(0), DEPOSITOR);
    }

    // ============ createIntent Tests ============

    function test_createIntent_revertsIfNotInitialized() public {
        // Create a fresh implementation
        DepositAddress_GatewayDeposit uninit = new DepositAddress_GatewayDeposit();

        vm.expectRevert(BaseDepositAddress.NotInitialized.selector);
        uninit.createIntent(1000);
    }

    function test_createIntent_revertsIfZeroAmount() public {
        vm.expectRevert(BaseDepositAddress.ZeroAmount.selector);
        depositAddress.createIntent(0);
    }

    function test_createIntent_revertsIfInsufficientBalance() public {
        uint256 amount = 10_000 * 1e18;
        // Don't mint tokens, so balance is 0

        vm.expectRevert(
            abi.encodeWithSelector(
                BaseDepositAddress.InsufficientBalance.selector,
                amount,
                0
            )
        );
        depositAddress.createIntent(amount);
    }

    function test_createIntent_approvesPortalForTokens() public {
        uint256 amount = 10_000 * 1e18;
        token.mint(address(depositAddress), amount);

        depositAddress.createIntent(amount);

        // After publishAndFund, tokens should be transferred to vault
        assertEq(token.balanceOf(address(depositAddress)), 0);
    }

    function test_createIntent_callsPortalPublishAndFund() public {
        uint256 amount = 10_000 * 1e18;
        token.mint(address(depositAddress), amount);

        bytes32 intentHash = depositAddress.createIntent(amount);

        // Verify intent hash is not zero
        assertTrue(intentHash != bytes32(0));
    }

    function test_createIntent_returnsIntentHash() public {
        uint256 amount = 10_000 * 1e18;
        token.mint(address(depositAddress), amount);

        bytes32 intentHash = depositAddress.createIntent(amount);

        assertTrue(intentHash != bytes32(0));
    }

    function test_createIntent_permissionless() public {
        uint256 amount = 10_000 * 1e18;
        token.mint(address(depositAddress), amount);

        // Anyone can call createIntent
        vm.prank(ATTACKER);
        bytes32 intentHash = depositAddress.createIntent(amount);

        assertTrue(intentHash != bytes32(0));
    }

    function test_createIntent_multipleCallsSucceed() public {
        uint256 amount1 = 10_000 * 1e18;
        uint256 amount2 = 5_000 * 1e18;

        // First intent
        token.mint(address(depositAddress), amount1);
        bytes32 intentHash1 = depositAddress.createIntent(amount1);

        // Second intent
        token.mint(address(depositAddress), amount2);
        bytes32 intentHash2 = depositAddress.createIntent(amount2);

        assertTrue(intentHash1 != bytes32(0));
        assertTrue(intentHash2 != bytes32(0));
        assertTrue(intentHash1 != intentHash2);
    }

    // ============ Fuzz Tests ============

    function testFuzz_createIntent_succeeds(uint256 amount) public {
        vm.assume(amount > 0 && amount <= type(uint256).max / 2);

        token.mint(address(depositAddress), amount);
        bytes32 intentHash = depositAddress.createIntent(amount);

        assertTrue(intentHash != bytes32(0));
    }
}
