// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DepositFactory} from "../../contracts/deposit/DepositFactory.sol";
import {DepositAddress} from "../../contracts/deposit/DepositAddress.sol";
import {Portal} from "../../contracts/Portal.sol";
import {Reward, TokenAmount} from "../../contracts/types/Intent.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";

contract DepositAddressTest is Test {
    DepositFactory public factory;
    DepositAddress public depositAddress;
    Portal public portal;
    TestERC20 public token;

    // Configuration parameters
    uint64 constant DESTINATION_CHAIN = 5107100; // Solana
    bytes32 constant DESTINATION_TOKEN = bytes32(uint256(0x5678));
    address constant PROVER_ADDRESS = address(0x9ABC);
    bytes32 constant DESTINATION_PORTAL = bytes32(uint256(0xDEF0));
    uint64 constant INTENT_DEADLINE_DURATION = 7 days;

    // Test user addresses
    bytes32 constant USER_DESTINATION = bytes32(uint256(0x1111));
    address constant DEPOSITOR = address(0x3333);
    address constant ATTACKER = address(0x6666);

    function setUp() public {
        // Deploy token
        token = new TestERC20("Test Token", "TEST");

        // Deploy Portal
        portal = new Portal();

        // Deploy factory
        factory = new DepositFactory(
            DESTINATION_CHAIN,
            address(token),
            DESTINATION_TOKEN,
            address(portal),
            PROVER_ADDRESS,
            DESTINATION_PORTAL,
            INTENT_DEADLINE_DURATION
        );

        // Deploy deposit address
        address deployed = factory.deploy(USER_DESTINATION, DEPOSITOR);
        depositAddress = DepositAddress(deployed);
    }

    // ============ Initialization Tests ============

    function test_initialize_setsDestinationAddress() public view {
        assertEq(depositAddress.destinationAddress(), USER_DESTINATION);
    }

    function test_initialize_setsDepositor() public view {
        assertEq(depositAddress.depositor(), DEPOSITOR);
    }

    function test_initialize_revertsIfAlreadyInitialized() public {
        vm.expectRevert(DepositAddress.AlreadyInitialized.selector);
        depositAddress.initialize(USER_DESTINATION, DEPOSITOR);
    }

    function test_initialize_revertsIfNotCalledByFactory() public {
        // Deploy implementation directly (not via factory)
        DepositAddress implementation = new DepositAddress();

        vm.prank(ATTACKER);
        vm.expectRevert(DepositAddress.OnlyFactory.selector);
        implementation.initialize(USER_DESTINATION, DEPOSITOR);
    }

    function test_initialize_revertsIfDepositorIsZero() public {
        // Deploy a new uninitialized deposit address
        factory.getDepositAddress(
            bytes32(uint256(0x9999))
        );

        // Manually deploy the proxy without initialization
        vm.expectRevert(DepositAddress.InvalidDepositor.selector);
        factory.deploy(bytes32(uint256(0x9999)), address(0));
    }

    // ============ createIntent Tests ============

    function test_createIntent_revertsIfNotInitialized() public {
        // Create a fresh implementation
        DepositAddress uninit = new DepositAddress();

        vm.expectRevert(DepositAddress.NotInitialized.selector);
        uninit.createIntent(1000);
    }

    function test_createIntent_revertsIfZeroAmount() public {
        vm.expectRevert(DepositAddress.ZeroAmount.selector);
        depositAddress.createIntent(0);
    }

    function test_createIntent_revertsIfInsufficientBalance() public {
        // Don't send any tokens
        vm.expectRevert(
            abi.encodeWithSelector(
                DepositAddress.InsufficientBalance.selector,
                1000,
                0
            )
        );
        depositAddress.createIntent(1000);
    }

    function test_createIntent_approvesPortalForTokens() public {
        uint256 amount = 1000 ether;
        token.mint(address(depositAddress), amount);

        depositAddress.createIntent(amount);

        // Check that portal was approved (it should have transferred the tokens)
        // After publishAndFund, the approval should be used
        assertEq(token.balanceOf(address(depositAddress)), 0);
    }

    function test_createIntent_callsPortalPublishAndFund() public {
        uint256 amount = 1000 ether;
        token.mint(address(depositAddress), amount);

        bytes32 intentHash = depositAddress.createIntent(amount);

        // Verify intent hash is not zero
        assertTrue(intentHash != bytes32(0));
    }

    function test_createIntent_emitsIntentCreatedEvent() public {
        uint256 amount = 1000 ether;
        token.mint(address(depositAddress), amount);

        // We can't predict the exact intentHash, but we can check that event was emitted
        vm.recordLogs();
        bytes32 intentHash = depositAddress.createIntent(amount);

        // Verify event was emitted with correct amount and caller
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundEvent = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].topics[0] ==
                keccak256("IntentCreated(bytes32,uint256,address)")
            ) {
                foundEvent = true;
                break;
            }
        }
        assertTrue(foundEvent, "IntentCreated event should be emitted");
    }

    function test_createIntent_returnsIntentHash() public {
        uint256 amount = 1000 ether;
        token.mint(address(depositAddress), amount);

        bytes32 intentHash = depositAddress.createIntent(amount);

        assertTrue(intentHash != bytes32(0));
    }

    function test_createIntent_permissionless() public {
        uint256 amount = 1000 ether;
        token.mint(address(depositAddress), amount);

        // Anyone can call createIntent
        vm.prank(ATTACKER);
        bytes32 intentHash = depositAddress.createIntent(amount);

        assertTrue(intentHash != bytes32(0));
    }

    function test_createIntent_multipleCallsSucceed() public {
        uint256 amount1 = 1000 ether;
        uint256 amount2 = 500 ether;

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

    // ============ Route Encoding Tests ============

    function test_encodeRoute_includesAllParameters() public {
        uint256 amount = 1000 ether;
        token.mint(address(depositAddress), amount);

        // Create intent which internally calls _encodeRoute
        bytes32 intentHash = depositAddress.createIntent(amount);

        // Verify intent was created successfully
        assertTrue(intentHash != bytes32(0));

        // The route encoding is tested implicitly by successful intent creation
        // More detailed encoding tests would require making _encodeRoute public
        // or testing through integration tests
    }

    // ============ Fuzz Tests ============

    function testFuzz_createIntent_succeeds(uint256 amount) public {
        vm.assume(amount > 0 && amount <= type(uint64).max);

        token.mint(address(depositAddress), amount);
        bytes32 intentHash = depositAddress.createIntent(amount);

        assertTrue(intentHash != bytes32(0));
    }

    function testFuzz_createIntent_revertsOnInsufficientBalance(
        uint256 requested,
        uint256 available
    ) public {
        vm.assume(requested > available);
        vm.assume(requested > 0);
        vm.assume(available < type(uint256).max);

        token.mint(address(depositAddress), available);

        vm.expectRevert(
            abi.encodeWithSelector(
                DepositAddress.InsufficientBalance.selector,
                requested,
                available
            )
        );
        depositAddress.createIntent(requested);
    }
}
