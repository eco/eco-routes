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
    bytes32 constant DESTINATION_TOKEN = bytes32(uint256(0x5678));
    address constant PROVER_ADDRESS = address(0x9ABC);
    bytes32 constant DESTINATION_PORTAL = bytes32(uint256(0xDEF0));
    bytes32 constant PORTAL_PDA = bytes32(uint256(0xABCD));
    bytes32 constant EXECUTOR_ATA = bytes32(uint256(0xEFAB));
    uint64 constant INTENT_DEADLINE_DURATION = 7 days;

    // Test user addresses
    bytes32 constant USER_DESTINATION = bytes32(uint256(0x1111));
    bytes32 constant RECIPIENT_ATA = bytes32(uint256(0x5555));
    address constant DEPOSITOR = address(0x3333);
    address constant ATTACKER = address(0x6666);

    function setUp() public {
        // Deploy token
        token = new TestERC20("Test Token", "TEST");

        // Deploy Portal
        portal = new Portal();

        // Deploy factory
        factory = new DepositFactory(
            address(token),
            DESTINATION_TOKEN,
            address(portal),
            PROVER_ADDRESS,
            DESTINATION_PORTAL,
            PORTAL_PDA,
            INTENT_DEADLINE_DURATION,
            EXECUTOR_ATA
        );

        // Deploy deposit address (RECIPIENT_ATA is passed as destinationAddress for Solana)
        address deployed = factory.deploy(RECIPIENT_ATA, DEPOSITOR);
        depositAddress = DepositAddress(deployed);
    }

    // ============ Initialization Tests ============

    function test_initialize_setsDestinationAddress() public view {
        assertEq(depositAddress.destinationAddress(), RECIPIENT_ATA);
    }

    function test_initialize_setsDepositor() public view {
        assertEq(depositAddress.depositor(), DEPOSITOR);
    }

    function test_initialize_revertsIfAlreadyInitialized() public {
        vm.expectRevert(DepositAddress.AlreadyInitialized.selector);
        depositAddress.initialize(RECIPIENT_ATA, DEPOSITOR);
    }

    function test_initialize_revertsIfNotCalledByFactory() public {
        // Deploy implementation directly (not via factory)
        DepositAddress implementation = new DepositAddress();

        vm.prank(ATTACKER);
        vm.expectRevert(DepositAddress.OnlyFactory.selector);
        implementation.initialize(RECIPIENT_ATA, DEPOSITOR);
    }

    function test_initialize_revertsIfDepositorIsZero() public {
        // Attempt to deploy with zero depositor should revert
        vm.expectRevert(DepositAddress.InvalidDepositor.selector);
        factory.deploy(RECIPIENT_ATA, address(0));
    }

    function test_initialize_revertsIfDestinationAddressIsZero() public {
        vm.expectRevert(DepositAddress.InvalidDestinationAddress.selector);
        factory.deploy(bytes32(0), DEPOSITOR);
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

    function test_createIntent_revertsIfAmountTooLarge() public {
        uint256 tooLarge = uint256(type(uint64).max) + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                DepositAddress.AmountTooLarge.selector,
                tooLarge,
                type(uint64).max
            )
        );
        depositAddress.createIntent(tooLarge);
    }

    function test_createIntent_approvesPortalForTokens() public {
        // 10,000 USDC (6 decimals) = 10,000 * 10^6
        uint256 amount = 10_000 * 1e6;
        token.mint(address(depositAddress), amount);

        depositAddress.createIntent(amount);

        // Check that portal was approved (it should have transferred the tokens)
        // After publishAndFund, the approval should be used
        assertEq(token.balanceOf(address(depositAddress)), 0);
    }

    function test_createIntent_callsPortalPublishAndFund() public {
        uint256 amount = 10_000 * 1e6;
        token.mint(address(depositAddress), amount);

        bytes32 intentHash = depositAddress.createIntent(amount);

        // Verify intent hash is not zero
        assertTrue(intentHash != bytes32(0));
    }

    function test_createIntent_returnsIntentHash() public {
        uint256 amount = 10_000 * 1e6;
        token.mint(address(depositAddress), amount);

        bytes32 intentHash = depositAddress.createIntent(amount);

        assertTrue(intentHash != bytes32(0));
    }

    function test_createIntent_permissionless() public {
        uint256 amount = 10_000 * 1e6;
        token.mint(address(depositAddress), amount);

        // Anyone can call createIntent
        vm.prank(ATTACKER);
        bytes32 intentHash = depositAddress.createIntent(amount);

        assertTrue(intentHash != bytes32(0));
    }

    function test_createIntent_multipleCallsSucceed() public {
        uint256 amount1 = 10_000 * 1e6;
        uint256 amount2 = 5_000 * 1e6;

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
        uint256 amount = 10_000 * 1e6;
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
}
