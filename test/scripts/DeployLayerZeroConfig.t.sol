// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../../scripts/Deploy.s.sol";

/// @dev Harness exposing how Deploy lines LAYERZERO_RECEIVE_CONFIRMATIONS up
///      with LAYERZERO_DOMAIN_CONFIG
contract DeployLayerZeroConfigHarness is Deploy {
    function orderReceiveConfirmations(
        string memory domainConfig,
        string memory receiveConfirmations
    ) external pure returns (uint64[] memory) {
        return
            _orderReceiveConfirmations(
                _parseDomainConfig(domainConfig),
                _parseDomainConfig(receiveConfirmations)
            );
    }
}

contract DeployLayerZeroConfigTest is Test {
    DeployLayerZeroConfigHarness internal harness;

    function setUp() public {
        harness = new DeployLayerZeroConfigHarness();
    }

    /// @dev The constructor reads receiveConfirmations by domainConfig index,
    ///      so a reordered env list must still land on the right domain.
    function test_ordersConfirmationsByDomainConfig() public view {
        uint64[] memory confirmations = harness.orderReceiveConfirmations(
            "30101:1,30110:42161,30420:728126428",
            "30420:19,30101:32,30110:20"
        );
        assertEq(confirmations.length, 3);
        assertEq(confirmations[0], 32);
        assertEq(confirmations[1], 20);
        assertEq(confirmations[2], 19);
    }

    function test_revertsOnMissingDomain() public {
        vm.expectRevert(
            bytes("LAYERZERO_RECEIVE_CONFIRMATIONS: missing domain 30110")
        );
        harness.orderReceiveConfirmations(
            "30101:1,30110:42161",
            "30101:32,30184:10"
        );
    }

    function test_revertsOnExtraDomain() public {
        vm.expectRevert(
            bytes(
                "LAYERZERO_RECEIVE_CONFIRMATIONS: 3 entries for 2 LAYERZERO_DOMAIN_CONFIG domains"
            )
        );
        harness.orderReceiveConfirmations(
            "30101:1,30110:42161",
            "30101:32,30110:20,30184:10"
        );
    }

    function test_revertsOnDuplicateDomain() public {
        vm.expectRevert(
            bytes("LAYERZERO_RECEIVE_CONFIRMATIONS: duplicate domain 30101")
        );
        harness.orderReceiveConfirmations(
            "30101:1,30110:42161",
            "30101:32,30101:20"
        );
    }
}
