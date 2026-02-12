// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DepositFactory_GatewayDeposit} from "../../contracts/deposit/DepositFactory_GatewayDeposit.sol";
import {DepositAddress_GatewayDeposit} from "../../contracts/deposit/DepositAddress_GatewayDeposit.sol";
import {BaseDepositFactory} from "../../contracts/deposit/BaseDepositFactory.sol";
import {BaseDepositAddress} from "../../contracts/deposit/BaseDepositAddress.sol";
import {Portal} from "../../contracts/Portal.sol";

contract DepositFactory_GatewayDepositTest is Test {
    DepositFactory_GatewayDeposit public factory;
    Portal public portal;

    // Configuration parameters
    uint64 constant DESTINATION_CHAIN = 42161; // Arbitrum
    address constant SOURCE_TOKEN = address(0x1234);
    address constant DESTINATION_TOKEN = address(0x5678);
    address constant PROVER_ADDRESS = address(0x9ABC);
    address constant DESTINATION_PORTAL = address(0xDEF0);
    address constant GATEWAY = address(0xAAAA);
    uint64 constant INTENT_DEADLINE_DURATION = 7 days;

    // Test user addresses
    address constant USER_DESTINATION_1 = address(0x1111);
    address constant USER_DESTINATION_2 = address(0x2222);
    address constant DEPOSITOR_1 = address(0x3333);
    address constant DEPOSITOR_2 = address(0x4444);

    function setUp() public {
        // Deploy Portal
        portal = new Portal();

        // Deploy factory
        factory = new DepositFactory_GatewayDeposit(
            DESTINATION_CHAIN,
            SOURCE_TOKEN,
            DESTINATION_TOKEN,
            address(portal),
            PROVER_ADDRESS,
            DESTINATION_PORTAL,
            GATEWAY,
            INTENT_DEADLINE_DURATION
        );
    }

    // ============ Constructor Tests ============

    function test_constructor_setsConfigurationCorrectly() public view {
        (
            uint64 destChain,
            address sourceToken,
            address destinationToken,
            address portalAddress,
            address proverAddress,
            address destPortal,
            address gateway,
            uint64 deadlineDuration
        ) = factory.getConfiguration();

        assertEq(destChain, DESTINATION_CHAIN);
        assertEq(sourceToken, SOURCE_TOKEN);
        assertEq(destinationToken, DESTINATION_TOKEN);
        assertEq(portalAddress, address(portal));
        assertEq(proverAddress, PROVER_ADDRESS);
        assertEq(destPortal, DESTINATION_PORTAL);
        assertEq(gateway, GATEWAY);
        assertEq(deadlineDuration, INTENT_DEADLINE_DURATION);
    }

    function test_constructor_deploysImplementation() public view {
        address implementation = factory.DEPOSIT_IMPLEMENTATION();
        assertTrue(implementation != address(0));
        assertTrue(implementation.code.length > 0);
    }

    function test_constructor_revertsOnInvalidSourceToken() public {
        vm.expectRevert(BaseDepositFactory.InvalidSourceToken.selector);
        new DepositFactory_GatewayDeposit(
            DESTINATION_CHAIN,
            address(0), // Invalid
            DESTINATION_TOKEN,
            address(portal),
            PROVER_ADDRESS,
            DESTINATION_PORTAL,
            GATEWAY,
            INTENT_DEADLINE_DURATION
        );
    }

    function test_constructor_revertsOnInvalidDestinationToken() public {
        vm.expectRevert(DepositFactory_GatewayDeposit.InvalidTargetToken.selector);
        new DepositFactory_GatewayDeposit(
            DESTINATION_CHAIN,
            SOURCE_TOKEN,
            address(0), // Invalid
            address(portal),
            PROVER_ADDRESS,
            DESTINATION_PORTAL,
            GATEWAY,
            INTENT_DEADLINE_DURATION
        );
    }

    function test_constructor_revertsOnInvalidPortal() public {
        vm.expectRevert(BaseDepositFactory.InvalidPortalAddress.selector);
        new DepositFactory_GatewayDeposit(
            DESTINATION_CHAIN,
            SOURCE_TOKEN,
            DESTINATION_TOKEN,
            address(0), // Invalid
            PROVER_ADDRESS,
            DESTINATION_PORTAL,
            GATEWAY,
            INTENT_DEADLINE_DURATION
        );
    }

    function test_constructor_revertsOnInvalidProver() public {
        vm.expectRevert(BaseDepositFactory.InvalidProverAddress.selector);
        new DepositFactory_GatewayDeposit(
            DESTINATION_CHAIN,
            SOURCE_TOKEN,
            DESTINATION_TOKEN,
            address(portal),
            address(0), // Invalid
            DESTINATION_PORTAL,
            GATEWAY,
            INTENT_DEADLINE_DURATION
        );
    }

    function test_constructor_revertsOnInvalidDestinationPortal() public {
        vm.expectRevert(BaseDepositFactory.InvalidDestinationPortal.selector);
        new DepositFactory_GatewayDeposit(
            DESTINATION_CHAIN,
            SOURCE_TOKEN,
            DESTINATION_TOKEN,
            address(portal),
            PROVER_ADDRESS,
            address(0), // Invalid
            GATEWAY,
            INTENT_DEADLINE_DURATION
        );
    }

    function test_constructor_revertsOnInvalidGateway() public {
        vm.expectRevert(DepositFactory_GatewayDeposit.InvalidGatewayAddress.selector);
        new DepositFactory_GatewayDeposit(
            DESTINATION_CHAIN,
            SOURCE_TOKEN,
            DESTINATION_TOKEN,
            address(portal),
            PROVER_ADDRESS,
            DESTINATION_PORTAL,
            address(0), // Invalid
            INTENT_DEADLINE_DURATION
        );
    }

    function test_constructor_revertsOnInvalidDeadlineDuration() public {
        vm.expectRevert(BaseDepositFactory.InvalidDeadlineDuration.selector);
        new DepositFactory_GatewayDeposit(
            DESTINATION_CHAIN,
            SOURCE_TOKEN,
            DESTINATION_TOKEN,
            address(portal),
            PROVER_ADDRESS,
            DESTINATION_PORTAL,
            GATEWAY,
            0 // Invalid
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
        address deployed = factory.deploy(USER_DESTINATION_1, DEPOSITOR_1);

        assertEq(deployed, predicted);
        assertTrue(deployed.code.length > 0);
    }

    function test_deploy_initializesDepositAddress() public {
        address deployed = factory.deploy(USER_DESTINATION_1, DEPOSITOR_1);
        DepositAddress_GatewayDeposit depositAddress = DepositAddress_GatewayDeposit(deployed);

        assertEq(depositAddress.destinationAddress(), bytes32(uint256(uint160(USER_DESTINATION_1))));
        assertEq(depositAddress.depositor(), DEPOSITOR_1);
    }

    function test_deploy_emitsEvent() public {
        address predicted = factory.getDepositAddress(USER_DESTINATION_1, DEPOSITOR_1);

        vm.expectEmit(true, true, false, false);
        emit BaseDepositFactory.DepositContractDeployed(
            USER_DESTINATION_1,
            predicted
        );

        factory.deploy(USER_DESTINATION_1, DEPOSITOR_1);
    }

    function test_deploy_revertsIfZeroDestinationAddress() public {
        vm.expectRevert(BaseDepositAddress.InvalidDestinationAddress.selector);
        factory.deploy(address(0), DEPOSITOR_1);
    }

    function test_deploy_revertsIfAlreadyDeployed() public {
        factory.deploy(USER_DESTINATION_1, DEPOSITOR_1);

        // Should revert at clone level when trying to deploy to same address
        vm.expectRevert();
        factory.deploy(USER_DESTINATION_1, DEPOSITOR_1);
    }

    function test_deploy_allowsDifferentDepositorsToSameDestination() public {
        address deployed1 = factory.deploy(USER_DESTINATION_1, DEPOSITOR_1);
        address deployed2 = factory.deploy(USER_DESTINATION_1, DEPOSITOR_2);

        assertTrue(deployed1 != deployed2);
        assertTrue(deployed1.code.length > 0);
        assertTrue(deployed2.code.length > 0);

        assertEq(DepositAddress_GatewayDeposit(deployed1).destinationAddress(), bytes32(uint256(uint160(USER_DESTINATION_1))));
        assertEq(DepositAddress_GatewayDeposit(deployed1).depositor(), DEPOSITOR_1);
        assertEq(DepositAddress_GatewayDeposit(deployed2).destinationAddress(), bytes32(uint256(uint160(USER_DESTINATION_1))));
        assertEq(DepositAddress_GatewayDeposit(deployed2).depositor(), DEPOSITOR_2);
    }

    function test_deploy_allowsDifferentUsers() public {
        address deployed1 = factory.deploy(USER_DESTINATION_1, DEPOSITOR_1);
        address deployed2 = factory.deploy(USER_DESTINATION_2, DEPOSITOR_2);

        assertTrue(deployed1 != deployed2);
        assertTrue(deployed1.code.length > 0);
        assertTrue(deployed2.code.length > 0);
    }

    // ============ isDeployed Tests ============

    function test_isDeployed_returnsFalseBeforeDeployment() public view {
        assertFalse(factory.isDeployed(USER_DESTINATION_1, DEPOSITOR_1));
    }

    function test_isDeployed_returnsTrueAfterDeployment() public {
        factory.deploy(USER_DESTINATION_1, DEPOSITOR_1);
        assertTrue(factory.isDeployed(USER_DESTINATION_1, DEPOSITOR_1));
    }

    function test_isDeployed_independentForDifferentUsers() public {
        factory.deploy(USER_DESTINATION_1, DEPOSITOR_1);

        assertTrue(factory.isDeployed(USER_DESTINATION_1, DEPOSITOR_1));
        assertFalse(factory.isDeployed(USER_DESTINATION_2, DEPOSITOR_1));
    }

    // ============ Fuzz Tests ============

    function testFuzz_getDepositAddress_deterministic(
        address destination,
        address depositor
    ) public view {
        vm.assume(destination != address(0));
        vm.assume(depositor != address(0));

        address predicted1 = factory.getDepositAddress(destination, depositor);
        address predicted2 = factory.getDepositAddress(destination, depositor);

        assertEq(predicted1, predicted2);
    }

    function testFuzz_deploy_succeeds(
        address destination,
        address depositor
    ) public {
        vm.assume(destination != address(0));
        vm.assume(depositor != address(0));

        address predicted = factory.getDepositAddress(destination, depositor);
        address deployed = factory.deploy(destination, depositor);

        assertEq(deployed, predicted);
        assertTrue(deployed.code.length > 0);
    }
}
