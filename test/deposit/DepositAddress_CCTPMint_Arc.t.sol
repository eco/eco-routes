// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DepositFactory_CCTPMint_Arc} from "../../contracts/deposit/DepositFactory_CCTPMint_Arc.sol";
import {DepositAddress_CCTPMint_Arc} from "../../contracts/deposit/DepositAddress_CCTPMint_Arc.sol";
import {BaseDepositAddress} from "../../contracts/deposit/BaseDepositAddress.sol";
import {Portal} from "../../contracts/Portal.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";

contract DepositAddress_CCTPMint_ArcTest is Test {
    DepositFactory_CCTPMint_Arc public factory;
    DepositAddress_CCTPMint_Arc public depositAddress;
    Portal public portal;
    TestERC20 public token;

    // Configuration parameters
    uint64 constant DESTINATION_CHAIN = 42161; // Arbitrum
    address constant DESTINATION_TOKEN = address(0x5678);
    address constant PROVER_ADDRESS = address(0x9ABC);
    address constant DESTINATION_PORTAL = address(0xDEF0);
    uint64 constant INTENT_DEADLINE_DURATION = 7 days;
    uint32 constant DESTINATION_DOMAIN = 3; // Arbitrum CCTP domain
    address constant CCTP_TOKEN_MESSENGER = address(0xABCD);

    // Test user addresses
    address constant USER_DESTINATION = address(0x1111);
    address constant DEPOSITOR = address(0x3333);
    address constant ATTACKER = address(0x6666);

    function setUp() public {
        // Deploy token
        token = new TestERC20("Test USDC", "USDC");

        // Deploy Portal
        portal = new Portal();

        // Deploy factory
        factory = new DepositFactory_CCTPMint_Arc(
            address(token),
            DESTINATION_TOKEN,
            address(portal),
            PROVER_ADDRESS,
            INTENT_DEADLINE_DURATION,
            DESTINATION_DOMAIN,
            CCTP_TOKEN_MESSENGER
        );

        // Deploy deposit address
        address deployed = factory.deploy(USER_DESTINATION, DEPOSITOR);
        depositAddress = DepositAddress_CCTPMint_Arc(deployed);
    }

    // ============ Initialization Tests ============

    function test_initialize_setsDestinationAddress() public view {
        assertEq(depositAddress.destinationAddress(), bytes32(uint256(uint160(USER_DESTINATION))));
    }

    function test_initialize_setsDepositor() public view {
        assertEq(depositAddress.depositor(), DEPOSITOR);
    }

    function test_initialize_revertsIfAlreadyInitialized() public {
        vm.expectRevert(BaseDepositAddress.AlreadyInitialized.selector);
        depositAddress.initialize(bytes32(uint256(uint160(USER_DESTINATION))), DEPOSITOR);
    }

    function test_initialize_revertsIfNotCalledByFactory() public {
        // Deploy implementation directly (not via factory)
        DepositAddress_CCTPMint_Arc implementation = new DepositAddress_CCTPMint_Arc();

        vm.prank(ATTACKER);
        vm.expectRevert(BaseDepositAddress.OnlyFactory.selector);
        implementation.initialize(bytes32(uint256(uint160(USER_DESTINATION))), DEPOSITOR);
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
        DepositAddress_CCTPMint_Arc uninit = new DepositAddress_CCTPMint_Arc();

        vm.expectRevert(BaseDepositAddress.NotInitialized.selector);
        uninit.createIntent();
    }

    function test_createIntent_revertsIfZeroAmount() public {
        // Don't mint tokens, so balance is 0
        vm.expectRevert(BaseDepositAddress.ZeroAmount.selector);
        depositAddress.createIntent();
    }

    function test_createIntent_approvesPortalForTokens() public {
        uint256 amount = 10_000 * 1e6;
        token.mint(address(depositAddress), amount);

        depositAddress.createIntent();

        // After publishAndFund, tokens should be transferred to vault
        assertEq(token.balanceOf(address(depositAddress)), 0);
    }

    function test_createIntent_callsPortalPublishAndFund() public {
        uint256 amount = 10_000 * 1e6;
        token.mint(address(depositAddress), amount);

        bytes32 intentHash = depositAddress.createIntent();

        // Verify intent hash is not zero
        assertTrue(intentHash != bytes32(0));
    }

    function test_createIntent_returnsIntentHash() public {
        uint256 amount = 10_000 * 1e6;
        token.mint(address(depositAddress), amount);

        bytes32 intentHash = depositAddress.createIntent();

        assertTrue(intentHash != bytes32(0));
    }

    function test_createIntent_permissionless() public {
        uint256 amount = 10_000 * 1e6;
        token.mint(address(depositAddress), amount);

        // Anyone can call createIntent
        vm.prank(ATTACKER);
        bytes32 intentHash = depositAddress.createIntent();

        assertTrue(intentHash != bytes32(0));
    }

    function test_createIntent_multipleCallsSucceed() public {
        uint256 amount1 = 10_000 * 1e6;
        uint256 amount2 = 5_000 * 1e6;

        // First intent
        token.mint(address(depositAddress), amount1);
        bytes32 intentHash1 = depositAddress.createIntent();

        // Second intent
        token.mint(address(depositAddress), amount2);
        bytes32 intentHash2 = depositAddress.createIntent();

        assertTrue(intentHash1 != bytes32(0));
        assertTrue(intentHash2 != bytes32(0));
        assertTrue(intentHash1 != intentHash2);
    }

    // ============ Fuzz Tests ============

    function testFuzz_createIntent_succeeds(uint256 amount) public {
        vm.assume(amount > 0 && amount <= type(uint256).max / 2);

        token.mint(address(depositAddress), amount);
        bytes32 intentHash = depositAddress.createIntent();

        assertTrue(intentHash != bytes32(0));
    }
}
