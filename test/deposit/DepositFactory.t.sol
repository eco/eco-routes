// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DepositFactory_USDCTransfer_Solana} from "../../contracts/deposit/DepositFactory_USDCTransfer_Solana.sol";
import {DepositAddress_USDCTransfer_Solana} from "../../contracts/deposit/DepositAddress_USDCTransfer_Solana.sol";
import {Portal} from "../../contracts/Portal.sol";

contract DepositFactoryTest is Test {
    DepositFactory_USDCTransfer_Solana public factory;
    Portal public portal;

    // Configuration parameters
    address constant SOURCE_TOKEN = address(0x1234);
    bytes32 constant DESTINATION_TOKEN = bytes32(uint256(0x5678));
    address constant PROVER_ADDRESS = address(0x9ABC);
    bytes32 constant DESTINATION_PORTAL = bytes32(uint256(0xDEF0));
    bytes32 constant PORTAL_PDA = bytes32(uint256(0xABCD));
    bytes32 constant EXECUTOR_ATA = bytes32(uint256(0xEFAB));
    uint64 constant INTENT_DEADLINE_DURATION = 7 days;

    // Test user addresses
    bytes32 constant USER_DESTINATION_1 = bytes32(uint256(0x1111));
    bytes32 constant USER_DESTINATION_2 = bytes32(uint256(0x2222));
    bytes32 constant RECIPIENT_ATA_1 = bytes32(uint256(0x5555));
    bytes32 constant RECIPIENT_ATA_2 = bytes32(uint256(0x6666));
    address constant DEPOSITOR_1 = address(0x3333);
    address constant DEPOSITOR_2 = address(0x4444);

    function setUp() public {
        // Deploy Portal
        portal = new Portal();

        // Deploy factory
        factory = new DepositFactory_USDCTransfer_Solana(
            SOURCE_TOKEN,
            DESTINATION_TOKEN,
            address(portal),
            PROVER_ADDRESS,
            DESTINATION_PORTAL,
            PORTAL_PDA,
            INTENT_DEADLINE_DURATION,
            EXECUTOR_ATA
        );
    }

    // ============ Constructor Tests ============

    function test_constructor_setsConfigurationCorrectly() public view {
        (
            uint64 destChain,
            address sourceToken,
            bytes32 targetToken,
            address portalAddress,
            address proverAddress,
            bytes32 destPortal,
            bytes32 portalPDA,
            uint64 deadlineDuration,
            bytes32 executorATA
        ) = factory.getConfiguration();

        assertEq(destChain, 1399811149); // Solana chain ID
        assertEq(sourceToken, SOURCE_TOKEN);
        assertEq(targetToken, DESTINATION_TOKEN);
        assertEq(portalAddress, address(portal));
        assertEq(proverAddress, PROVER_ADDRESS);
        assertEq(destPortal, DESTINATION_PORTAL);
        assertEq(portalPDA, PORTAL_PDA);
        assertEq(deadlineDuration, INTENT_DEADLINE_DURATION);
        assertEq(executorATA, EXECUTOR_ATA);
    }

    function test_constructor_deploysImplementation() public view {
        address implementation = factory.DEPOSIT_IMPLEMENTATION();
        assertTrue(implementation != address(0));
        assertTrue(implementation.code.length > 0);
    }

    function test_constructor_revertsOnInvalidSourceToken() public {
        vm.expectRevert(DepositFactory_USDCTransfer_Solana.InvalidSourceToken.selector);
        new DepositFactory_USDCTransfer_Solana(
            address(0), // Invalid
            DESTINATION_TOKEN,
            address(portal),
            PROVER_ADDRESS,
            DESTINATION_PORTAL,
            PORTAL_PDA,
            INTENT_DEADLINE_DURATION,
            EXECUTOR_ATA
        );
    }

    function test_constructor_revertsOnInvalidDestinationToken() public {
        vm.expectRevert(DepositFactory_USDCTransfer_Solana.InvalidDestinationToken.selector);
        new DepositFactory_USDCTransfer_Solana(
            SOURCE_TOKEN,
            bytes32(0), // Invalid
            address(portal),
            PROVER_ADDRESS,
            DESTINATION_PORTAL,
            PORTAL_PDA,
            INTENT_DEADLINE_DURATION,
            EXECUTOR_ATA
        );
    }

    function test_constructor_revertsOnInvalidPortal() public {
        vm.expectRevert(DepositFactory_USDCTransfer_Solana.InvalidPortalAddress.selector);
        new DepositFactory_USDCTransfer_Solana(
            SOURCE_TOKEN,
            DESTINATION_TOKEN,
            address(0), // Invalid
            PROVER_ADDRESS,
            DESTINATION_PORTAL,
            PORTAL_PDA,
            INTENT_DEADLINE_DURATION,
            EXECUTOR_ATA
        );
    }

    function test_constructor_revertsOnInvalidProver() public {
        vm.expectRevert(DepositFactory_USDCTransfer_Solana.InvalidProverAddress.selector);
        new DepositFactory_USDCTransfer_Solana(
            SOURCE_TOKEN,
            DESTINATION_TOKEN,
            address(portal),
            address(0), // Invalid
            DESTINATION_PORTAL,
            PORTAL_PDA,
            INTENT_DEADLINE_DURATION,
            EXECUTOR_ATA
        );
    }

    function test_constructor_revertsOnInvalidDestinationPortal() public {
        vm.expectRevert(DepositFactory_USDCTransfer_Solana.InvalidDestinationPortal.selector);
        new DepositFactory_USDCTransfer_Solana(
            SOURCE_TOKEN,
            DESTINATION_TOKEN,
            address(portal),
            PROVER_ADDRESS,
            bytes32(0), // Invalid
            PORTAL_PDA,
            INTENT_DEADLINE_DURATION,
            EXECUTOR_ATA
        );
    }

    function test_constructor_revertsOnInvalidPortalPDA() public {
        vm.expectRevert(DepositFactory_USDCTransfer_Solana.InvalidPortalPDA.selector);
        new DepositFactory_USDCTransfer_Solana(
            SOURCE_TOKEN,
            DESTINATION_TOKEN,
            address(portal),
            PROVER_ADDRESS,
            DESTINATION_PORTAL,
            bytes32(0), // Invalid
            INTENT_DEADLINE_DURATION,
            EXECUTOR_ATA
        );
    }

    function test_constructor_revertsOnInvalidDeadlineDuration() public {
        vm.expectRevert(DepositFactory_USDCTransfer_Solana.InvalidDeadlineDuration.selector);
        new DepositFactory_USDCTransfer_Solana(
            SOURCE_TOKEN,
            DESTINATION_TOKEN,
            address(portal),
            PROVER_ADDRESS,
            DESTINATION_PORTAL,
            PORTAL_PDA,
            0, // Invalid
            EXECUTOR_ATA
        );
    }

    function test_constructor_revertsOnInvalidExecutorATA() public {
        vm.expectRevert(DepositFactory_USDCTransfer_Solana.InvalidExecutorATA.selector);
        new DepositFactory_USDCTransfer_Solana(
            SOURCE_TOKEN,
            DESTINATION_TOKEN,
            address(portal),
            PROVER_ADDRESS,
            DESTINATION_PORTAL,
            PORTAL_PDA,
            INTENT_DEADLINE_DURATION,
            bytes32(0) // Invalid
        );
    }

    // ============ getDepositAddress Tests ============

    function test_getDepositAddress_returnsDeterministicAddress() public view {
        address predicted = factory.getDepositAddress(USER_DESTINATION_1, DEPOSITOR_1);
        assertTrue(predicted != address(0));
    }

    function test_getDepositAddress_sameAddressForSameDestination() public view {
        address predicted1 = factory.getDepositAddress(USER_DESTINATION_1, DEPOSITOR_1);
        address predicted2 = factory.getDepositAddress(USER_DESTINATION_1, DEPOSITOR_1);
        assertEq(predicted1, predicted2);
    }

    function test_getDepositAddress_differentAddressForDifferentDestination()
        public
        view
    {
        address predicted1 = factory.getDepositAddress(USER_DESTINATION_1, DEPOSITOR_1);
        address predicted2 = factory.getDepositAddress(USER_DESTINATION_2, DEPOSITOR_1);
        assertTrue(predicted1 != predicted2);
    }

    function test_getDepositAddress_differentAddressForDifferentDepositor()
        public
        view
    {
        address predicted1 = factory.getDepositAddress(USER_DESTINATION_1, DEPOSITOR_1);
        address predicted2 = factory.getDepositAddress(USER_DESTINATION_1, DEPOSITOR_2);
        assertTrue(predicted1 != predicted2);
    }

    // ============ deploy Tests ============

    function test_deploy_createsContractAtPredictedAddress() public {
        address predicted = factory.getDepositAddress(USER_DESTINATION_1, DEPOSITOR_1);
        address deployed = factory.deploy(USER_DESTINATION_1, DEPOSITOR_1, RECIPIENT_ATA_1);

        assertEq(deployed, predicted);
        assertTrue(deployed.code.length > 0);
    }

    function test_deploy_initializesDepositAddress() public {
        address deployed = factory.deploy(USER_DESTINATION_1, DEPOSITOR_1, RECIPIENT_ATA_1);
        DepositAddress_USDCTransfer_Solana depositAddress = DepositAddress_USDCTransfer_Solana(deployed);

        assertEq(depositAddress.destinationAddress(), USER_DESTINATION_1);
        assertEq(depositAddress.depositor(), DEPOSITOR_1);
        assertEq(depositAddress.recipientATA(), RECIPIENT_ATA_1);
    }

    function test_deploy_emitsEvent() public {
        address predicted = factory.getDepositAddress(USER_DESTINATION_1, DEPOSITOR_1);

        vm.expectEmit(true, true, false, false);
        emit DepositFactory_USDCTransfer_Solana.DepositContractDeployed(
            USER_DESTINATION_1,
            predicted
        );

        factory.deploy(USER_DESTINATION_1, DEPOSITOR_1, RECIPIENT_ATA_1);
    }

    function test_deploy_revertsIfZeroDestinationAddress() public {
        vm.expectRevert(DepositFactory_USDCTransfer_Solana.InvalidDestinationAddress.selector);
        factory.deploy(bytes32(0), DEPOSITOR_1, RECIPIENT_ATA_1);
    }

    function test_deploy_revertsIfAlreadyDeployed() public {
        factory.deploy(USER_DESTINATION_1, DEPOSITOR_1, RECIPIENT_ATA_1);

        // Should revert at clone level when trying to deploy to same address (same destination + same depositor)
        vm.expectRevert();
        factory.deploy(USER_DESTINATION_1, DEPOSITOR_1, RECIPIENT_ATA_1);
    }

    function test_deploy_allowsDifferentDepositorsToSameDestination() public {
        address deployed1 = factory.deploy(USER_DESTINATION_1, DEPOSITOR_1, RECIPIENT_ATA_1);
        address deployed2 = factory.deploy(USER_DESTINATION_1, DEPOSITOR_2, RECIPIENT_ATA_1);

        // Different depositors to same destination should create different addresses
        assertTrue(deployed1 != deployed2);
        assertTrue(deployed1.code.length > 0);
        assertTrue(deployed2.code.length > 0);

        // Verify both are correctly initialized
        assertEq(DepositAddress_USDCTransfer_Solana(deployed1).destinationAddress(), USER_DESTINATION_1);
        assertEq(DepositAddress_USDCTransfer_Solana(deployed1).depositor(), DEPOSITOR_1);
        assertEq(DepositAddress_USDCTransfer_Solana(deployed1).recipientATA(), RECIPIENT_ATA_1);
        assertEq(DepositAddress_USDCTransfer_Solana(deployed2).destinationAddress(), USER_DESTINATION_1);
        assertEq(DepositAddress_USDCTransfer_Solana(deployed2).depositor(), DEPOSITOR_2);
        assertEq(DepositAddress_USDCTransfer_Solana(deployed2).recipientATA(), RECIPIENT_ATA_1);
    }

    function test_deploy_allowsDifferentUsers() public {
        address deployed1 = factory.deploy(USER_DESTINATION_1, DEPOSITOR_1, RECIPIENT_ATA_1);
        address deployed2 = factory.deploy(USER_DESTINATION_2, DEPOSITOR_2, RECIPIENT_ATA_2);

        assertTrue(deployed1 != deployed2);
        assertTrue(deployed1.code.length > 0);
        assertTrue(deployed2.code.length > 0);
    }

    // ============ isDeployed Tests ============

    function test_isDeployed_returnsFalseBeforeDeployment() public view {
        assertFalse(factory.isDeployed(USER_DESTINATION_1, DEPOSITOR_1));
    }

    function test_isDeployed_returnsTrueAfterDeployment() public {
        factory.deploy(USER_DESTINATION_1, DEPOSITOR_1, RECIPIENT_ATA_1);
        assertTrue(factory.isDeployed(USER_DESTINATION_1, DEPOSITOR_1));
    }

    function test_isDeployed_independentForDifferentUsers() public {
        factory.deploy(USER_DESTINATION_1, DEPOSITOR_1, RECIPIENT_ATA_1);

        assertTrue(factory.isDeployed(USER_DESTINATION_1, DEPOSITOR_1));
        assertFalse(factory.isDeployed(USER_DESTINATION_2, DEPOSITOR_1));
    }

    // ============ Multiple Factories Tests ============

    function test_multipleFactories_generateDifferentAddresses() public {
        DepositFactory_USDCTransfer_Solana factory2 = new DepositFactory_USDCTransfer_Solana(
            SOURCE_TOKEN,
            DESTINATION_TOKEN,
            address(portal),
            PROVER_ADDRESS,
            DESTINATION_PORTAL,
            PORTAL_PDA,
            INTENT_DEADLINE_DURATION,
            EXECUTOR_ATA
        );

        address addr1 = factory.getDepositAddress(USER_DESTINATION_1, DEPOSITOR_1);
        address addr2 = factory2.getDepositAddress(USER_DESTINATION_1, DEPOSITOR_1);

        // Different factories should produce different addresses even for same user
        // because they have different implementation addresses
        assertTrue(addr1 != addr2);
    }

    // ============ Fuzz Tests ============

    function testFuzz_getDepositAddress_deterministic(
        bytes32 destination,
        address depositor
    ) public view {
        vm.assume(destination != bytes32(0));
        vm.assume(depositor != address(0));

        address predicted1 = factory.getDepositAddress(destination, depositor);
        address predicted2 = factory.getDepositAddress(destination, depositor);

        assertEq(predicted1, predicted2);
    }

    function testFuzz_deploy_succeeds(
        bytes32 destination,
        address depositor,
        bytes32 recipientATA
    ) public {
        vm.assume(destination != bytes32(0));
        vm.assume(depositor != address(0));
        vm.assume(recipientATA != bytes32(0));

        address predicted = factory.getDepositAddress(destination, depositor);
        address deployed = factory.deploy(destination, depositor, recipientATA);

        assertEq(deployed, predicted);
        assertTrue(deployed.code.length > 0);
    }
}
