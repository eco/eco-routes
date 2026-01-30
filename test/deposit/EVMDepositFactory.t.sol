// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {EVMDepositFactory} from "../../contracts/deposit/EVMDepositFactory.sol";
import {EVMDepositAddress} from "../../contracts/deposit/EVMDepositAddress.sol";
import {Portal} from "../../contracts/Portal.sol";

contract EVMDepositFactoryTest is Test {
    EVMDepositFactory public factory;
    Portal public portal;

    // Configuration parameters
    uint64 constant DESTINATION_CHAIN = 10; // Optimism
    address constant SOURCE_TOKEN = address(0x1234);
    address constant TARGET_TOKEN = address(0x5678); // EVM address
    address constant PROVER_ADDRESS = address(0x9ABC);
    address constant DESTINATION_PORTAL = address(0xDEF0); // EVM address
    uint64 constant INTENT_DEADLINE_DURATION = 7 days;

    // Test user addresses
    address constant USER_DESTINATION_1 = address(0x1111);
    address constant USER_DESTINATION_2 = address(0x2222);
    address constant RECIPIENT_1 = address(0x3333);
    address constant RECIPIENT_2 = address(0x4444);
    address constant DEPOSITOR_1 = address(0x5555);
    address constant DEPOSITOR_2 = address(0x6666);

    function setUp() public {
        // Deploy Portal
        portal = new Portal();

        // Deploy factory
        factory = new EVMDepositFactory(
            DESTINATION_CHAIN,
            SOURCE_TOKEN,
            TARGET_TOKEN,
            address(portal),
            PROVER_ADDRESS,
            DESTINATION_PORTAL,
            INTENT_DEADLINE_DURATION
        );
    }

    // ============ Constructor Tests ============

    function test_constructor_setsConfigurationCorrectly() public view {
        (
            uint64 destChain,
            address sourceToken,
            address targetToken,
            address portalAddress,
            address proverAddress,
            address destPortal,
            uint64 deadlineDuration
        ) = factory.getConfiguration();

        assertEq(destChain, DESTINATION_CHAIN);
        assertEq(sourceToken, SOURCE_TOKEN);
        assertEq(targetToken, TARGET_TOKEN);
        assertEq(portalAddress, address(portal));
        assertEq(proverAddress, PROVER_ADDRESS);
        assertEq(destPortal, DESTINATION_PORTAL);
        assertEq(deadlineDuration, INTENT_DEADLINE_DURATION);
    }

    function test_constructor_deploysImplementation() public view {
        address implementation = factory.DEPOSIT_IMPLEMENTATION();
        assertTrue(implementation != address(0));
        assertTrue(implementation.code.length > 0);
    }

    function test_constructor_revertsOnInvalidSourceToken() public {
        vm.expectRevert(EVMDepositFactory.InvalidSourceToken.selector);
        new EVMDepositFactory(
            DESTINATION_CHAIN,
            address(0), // Invalid
            TARGET_TOKEN,
            address(portal),
            PROVER_ADDRESS,
            DESTINATION_PORTAL,
            INTENT_DEADLINE_DURATION
        );
    }

    function test_constructor_revertsOnInvalidPortal() public {
        vm.expectRevert(EVMDepositFactory.InvalidPortalAddress.selector);
        new EVMDepositFactory(
            DESTINATION_CHAIN,
            SOURCE_TOKEN,
            TARGET_TOKEN,
            address(0), // Invalid
            PROVER_ADDRESS,
            DESTINATION_PORTAL,
            INTENT_DEADLINE_DURATION
        );
    }

    function test_constructor_revertsOnInvalidProver() public {
        vm.expectRevert(EVMDepositFactory.InvalidProverAddress.selector);
        new EVMDepositFactory(
            DESTINATION_CHAIN,
            SOURCE_TOKEN,
            TARGET_TOKEN,
            address(portal),
            address(0), // Invalid
            DESTINATION_PORTAL,
            INTENT_DEADLINE_DURATION
        );
    }

    function test_constructor_revertsOnInvalidTargetToken() public {
        vm.expectRevert(EVMDepositFactory.InvalidTargetToken.selector);
        new EVMDepositFactory(
            DESTINATION_CHAIN,
            SOURCE_TOKEN,
            address(0), // Invalid
            address(portal),
            PROVER_ADDRESS,
            DESTINATION_PORTAL,
            INTENT_DEADLINE_DURATION
        );
    }

    function test_constructor_revertsOnInvalidDestinationPortal() public {
        vm.expectRevert(EVMDepositFactory.InvalidDestinationPortal.selector);
        new EVMDepositFactory(
            DESTINATION_CHAIN,
            SOURCE_TOKEN,
            TARGET_TOKEN,
            address(portal),
            PROVER_ADDRESS,
            address(0), // Invalid
            INTENT_DEADLINE_DURATION
        );
    }

    function test_constructor_revertsOnInvalidDeadlineDuration() public {
        vm.expectRevert(EVMDepositFactory.InvalidDeadlineDuration.selector);
        new EVMDepositFactory(
            DESTINATION_CHAIN,
            SOURCE_TOKEN,
            TARGET_TOKEN,
            address(portal),
            PROVER_ADDRESS,
            DESTINATION_PORTAL,
            0 // Invalid
        );
    }

    // ============ getDepositAddress Tests ============

    function test_getDepositAddress_returnsDeterministicAddress() public view {
        address predicted = factory.getDepositAddress(USER_DESTINATION_1);
        assertTrue(predicted != address(0));
    }

    function test_getDepositAddress_sameAddressForSameDestination() public view {
        address predicted1 = factory.getDepositAddress(USER_DESTINATION_1);
        address predicted2 = factory.getDepositAddress(USER_DESTINATION_1);
        assertEq(predicted1, predicted2);
    }

    function test_getDepositAddress_differentAddressForDifferentDestination()
        public
        view
    {
        address predicted1 = factory.getDepositAddress(USER_DESTINATION_1);
        address predicted2 = factory.getDepositAddress(USER_DESTINATION_2);
        assertTrue(predicted1 != predicted2);
    }

    // ============ deploy Tests ============

    function test_deploy_createsContractAtPredictedAddress() public {
        address predicted = factory.getDepositAddress(USER_DESTINATION_1);
        address deployed = factory.deploy(
            USER_DESTINATION_1,
            RECIPIENT_1,
            DEPOSITOR_1
        );

        assertEq(deployed, predicted);
        assertTrue(deployed.code.length > 0);
    }

    function test_deploy_initializesDepositAddress() public {
        address deployed = factory.deploy(
            USER_DESTINATION_1,
            RECIPIENT_1,
            DEPOSITOR_1
        );
        EVMDepositAddress depositAddress = EVMDepositAddress(deployed);

        assertEq(depositAddress.destinationAddress(), USER_DESTINATION_1);
        assertEq(depositAddress.recipient(), RECIPIENT_1);
        assertEq(depositAddress.depositor(), DEPOSITOR_1);
    }

    function test_deploy_setsRecipientCorrectly() public {
        address deployed = factory.deploy(
            USER_DESTINATION_1,
            RECIPIENT_1,
            DEPOSITOR_1
        );
        EVMDepositAddress depositAddress = EVMDepositAddress(deployed);

        assertEq(depositAddress.recipient(), RECIPIENT_1);
        assertTrue(depositAddress.recipient() != depositAddress.destinationAddress());
    }

    function test_deploy_emitsEvent() public {
        address predicted = factory.getDepositAddress(USER_DESTINATION_1);

        vm.expectEmit(true, true, false, false);
        emit EVMDepositFactory.DepositContractDeployed(
            USER_DESTINATION_1,
            predicted
        );

        factory.deploy(USER_DESTINATION_1, RECIPIENT_1, DEPOSITOR_1);
    }

    function test_deploy_revertsIfAlreadyDeployed() public {
        factory.deploy(USER_DESTINATION_1, RECIPIENT_1, DEPOSITOR_1);

        address predicted = factory.getDepositAddress(USER_DESTINATION_1);
        vm.expectRevert(
            abi.encodeWithSelector(
                EVMDepositFactory.ContractAlreadyDeployed.selector,
                predicted
            )
        );
        factory.deploy(USER_DESTINATION_1, RECIPIENT_2, DEPOSITOR_2);
    }

    function test_deploy_allowsDifferentUsers() public {
        address deployed1 = factory.deploy(
            USER_DESTINATION_1,
            RECIPIENT_1,
            DEPOSITOR_1
        );
        address deployed2 = factory.deploy(
            USER_DESTINATION_2,
            RECIPIENT_2,
            DEPOSITOR_2
        );

        assertTrue(deployed1 != deployed2);
        assertTrue(deployed1.code.length > 0);
        assertTrue(deployed2.code.length > 0);
    }

    // ============ isDeployed Tests ============

    function test_isDeployed_returnsFalseBeforeDeployment() public view {
        assertFalse(factory.isDeployed(USER_DESTINATION_1));
    }

    function test_isDeployed_returnsTrueAfterDeployment() public {
        factory.deploy(USER_DESTINATION_1, RECIPIENT_1, DEPOSITOR_1);
        assertTrue(factory.isDeployed(USER_DESTINATION_1));
    }

    function test_isDeployed_independentForDifferentUsers() public {
        factory.deploy(USER_DESTINATION_1, RECIPIENT_1, DEPOSITOR_1);

        assertTrue(factory.isDeployed(USER_DESTINATION_1));
        assertFalse(factory.isDeployed(USER_DESTINATION_2));
    }

    // ============ Multiple Factories Tests ============

    function test_multipleFactories_generateDifferentAddresses() public {
        EVMDepositFactory factory2 = new EVMDepositFactory(
            DESTINATION_CHAIN,
            SOURCE_TOKEN,
            TARGET_TOKEN,
            address(portal),
            PROVER_ADDRESS,
            DESTINATION_PORTAL,
            INTENT_DEADLINE_DURATION
        );

        address addr1 = factory.getDepositAddress(USER_DESTINATION_1);
        address addr2 = factory2.getDepositAddress(USER_DESTINATION_1);

        // Different factories should produce different addresses even for same user
        // because they have different implementation addresses
        assertTrue(addr1 != addr2);
    }

    // ============ Fuzz Tests ============

    function testFuzz_getDepositAddress_deterministic(
        address destination
    ) public view {
        vm.assume(destination != address(0));

        address predicted1 = factory.getDepositAddress(destination);
        address predicted2 = factory.getDepositAddress(destination);

        assertEq(predicted1, predicted2);
    }

    function testFuzz_deploy_succeeds(
        address destination,
        address recipient,
        address depositor
    ) public {
        vm.assume(destination != address(0));
        vm.assume(recipient != address(0));
        vm.assume(depositor != address(0));

        address predicted = factory.getDepositAddress(destination);
        address deployed = factory.deploy(destination, recipient, depositor);

        assertEq(deployed, predicted);
        assertTrue(deployed.code.length > 0);
    }
}
