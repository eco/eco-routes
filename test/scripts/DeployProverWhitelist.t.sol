// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Deploy} from "../../scripts/Deploy.s.sol";
import {TypeCasts} from "@hyperlane-xyz/core/contracts/libs/TypeCasts.sol";
import {AddressConverter} from "../../contracts/libs/AddressConverter.sol";

/**
 * @notice Exposes `Deploy.selfReference` for direct testing
 */
contract DeployHarness is Deploy {
    function exposedSelfReference(
        address addr
    ) external pure returns (bytes32) {
        return selfReference(addr);
    }
}

contract DeployProverWhitelistTest is Test {
    using AddressConverter for address;
    using AddressConverter for bytes32;

    DeployHarness internal harness;

    address internal constant ADDR_ONE =
        0x1111111111111111111111111111111111111111;
    address internal constant ADDR_TWO =
        0x2222222222222222222222222222222222222222;

    function setUp() public {
        harness = new DeployHarness();
    }

    function testSelfReferenceMatchesHyperlaneTypeCasts() public view {
        assertEq(
            harness.exposedSelfReference(ADDR_ONE),
            TypeCasts.addressToBytes32(ADDR_ONE)
        );
        assertEq(
            harness.exposedSelfReference(ADDR_TWO),
            TypeCasts.addressToBytes32(ADDR_TWO)
        );
    }

    function testSelfReferenceMatchesAddressConverter() public view {
        assertEq(
            harness.exposedSelfReference(ADDR_ONE),
            AddressConverter.toBytes32(ADDR_ONE)
        );
        assertEq(
            harness.exposedSelfReference(ADDR_TWO),
            AddressConverter.toBytes32(ADDR_TWO)
        );
    }

    function testSelfReferenceIsValidAddress() public view {
        assertTrue(
            AddressConverter.isValidAddress(
                harness.exposedSelfReference(ADDR_ONE)
            )
        );
        assertTrue(
            AddressConverter.isValidAddress(
                harness.exposedSelfReference(ADDR_TWO)
            )
        );
    }

    /**
     * @notice Regression pin: the old right-padded form must NOT match the
     *         fixed helper, and must fail the repo's own validity check.
     *         This is what fails if someone reintroduces `bytes32(bytes20(addr))`.
     */
    function testRegressionRightPaddedFormIsRejected() public view {
        bytes32 rightPadded = bytes32(bytes20(ADDR_ONE));
        assertTrue(rightPadded != harness.exposedSelfReference(ADDR_ONE));
        assertFalse(AddressConverter.isValidAddress(rightPadded));

        bytes32 rightPaddedTwo = bytes32(bytes20(ADDR_TWO));
        assertTrue(rightPaddedTwo != harness.exposedSelfReference(ADDR_TWO));
        assertFalse(AddressConverter.isValidAddress(rightPaddedTwo));
    }

    function testSelfReferenceRoundTrips() public view {
        assertEq(
            AddressConverter.toAddress(harness.exposedSelfReference(ADDR_ONE)),
            ADDR_ONE
        );
        assertEq(
            AddressConverter.toAddress(harness.exposedSelfReference(ADDR_TWO)),
            ADDR_TWO
        );
    }
}
