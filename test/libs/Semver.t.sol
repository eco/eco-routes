// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BaseTest} from "../BaseTest.sol";
import {Semver} from "../../contracts/libs/Semver.sol";

contract TestSemver is Semver {
    // Inherits the version string, which semantic-release rewrites on release
}

contract SemverTest is BaseTest {
    TestSemver internal testSemver;

    function setUp() public override {
        super.setUp();

        vm.prank(deployer);
        testSemver = new TestSemver();
    }

    function testSemverVersion() public view {
        string memory version = testSemver.version();
        _assertValidSemver(version);
    }

    function testSemverVersionConsistency() public view {
        string memory version1 = testSemver.version();
        string memory version2 = testSemver.version();
        assertEq(version1, version2);
    }

    function testGasConsumption() public view {
        uint256 gasBefore = gasleft();
        testSemver.version();
        uint256 gasUsed = gasBefore - gasleft();

        // Version should be very cheap
        assertTrue(gasUsed < 10000);
    }
}
