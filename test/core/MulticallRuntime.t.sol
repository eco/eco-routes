// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseTest} from "../BaseTest.sol";
import {MulticallRuntime} from "../../contracts/runtime/MulticallRuntime.sol";
import {Call} from "../../contracts/interfaces/IRuntime.sol";

/**
 * @title MulticallRuntimeTest
 * @notice Exercises the default runtime's batch execution, EOA guard, and revert bubbling.
 * @dev The runtime is meant to be reached via `delegatecall` from an Account, but its logic is
 *      context-independent, so these tests call it directly: `address(this)` is then the runtime, so a
 *      `transfer` call moves the runtime's own balance and `value:` draws on the runtime's balance. The
 *      `multicall(bytes)` entry takes `abi.encode(Call[])` (the same payload the Account forwards).
 */
contract MulticallRuntimeTest is BaseTest {
    address internal eoaTarget;
    MockContract internal mockContract;

    function setUp() public override {
        super.setUp();
        eoaTarget = makeAddr("eoaTarget");
        mockContract = new MockContract();
    }

    function _run(Call[] memory _calls) internal returns (bytes[] memory) {
        return multicallRuntime.multicall(abi.encode(_calls));
    }

    function test_multicall_success_transfer() public {
        tokenA.mint(address(multicallRuntime), 1000);

        Call[] memory _calls = new Call[](1);
        _calls[0] = Call({
            target: address(tokenA),
            value: 0,
            data: abi.encodeWithSignature(
                "transfer(address,uint256)",
                otherPerson,
                100
            )
        });

        uint256 balanceBefore = tokenA.balanceOf(otherPerson);
        bytes[] memory results = _run(_calls);
        assertEq(tokenA.balanceOf(otherPerson), balanceBefore + 100);
        assertTrue(abi.decode(results[0], (bool)));
    }

    function test_multicall_success_withValue() public {
        vm.deal(address(this), 10 ether);

        Call[] memory _calls = new Call[](1);
        _calls[0] = Call({
            target: address(mockContract),
            value: 1 ether,
            data: abi.encodeWithSignature("receiveEther()")
        });

        uint256 before = address(mockContract).balance;
        multicallRuntime.multicall{value: 1 ether}(abi.encode(_calls));
        assertEq(address(mockContract).balance, before + 1 ether);
    }

    function test_multicall_success_returnsData() public {
        Call[] memory _calls = new Call[](1);
        _calls[0] = Call({
            target: address(mockContract),
            value: 0,
            data: abi.encodeWithSignature("returnData()")
        });

        bytes[] memory results = _run(_calls);
        assertEq(results[0], abi.encode(uint256(42), "test"));
    }

    function test_multicall_revertCallToEOA_withCalldata() public {
        Call[] memory _calls = new Call[](1);
        _calls[0] = Call({
            target: eoaTarget,
            value: 0,
            data: abi.encodeWithSignature("someFunction()")
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                MulticallRuntime.CallToEOA.selector,
                eoaTarget
            )
        );
        _run(_calls);
    }

    function test_multicall_success_EOAWithoutCalldata() public {
        vm.deal(address(this), 10 ether);

        Call[] memory _calls = new Call[](1);
        _calls[0] = Call({target: eoaTarget, value: 1 ether, data: ""});

        uint256 before = eoaTarget.balance;
        multicallRuntime.multicall{value: 1 ether}(abi.encode(_calls));
        assertEq(eoaTarget.balance, before + 1 ether);
    }

    function test_multicall_success_contractWithEmptyCalldata() public {
        Call[] memory _calls = new Call[](1);
        _calls[0] = Call({target: address(mockContract), value: 0, data: ""});

        bytes[] memory results = _run(_calls);
        assertEq(results[0].length, 0);
    }

    function test_multicall_revertCallFailed() public {
        Call[] memory _calls = new Call[](1);
        _calls[0] = Call({
            target: address(mockContract),
            value: 0,
            data: abi.encodeWithSignature("fail()")
        });

        vm.expectRevert();
        _run(_calls);
    }

    function test_multicall_success_batchCalls() public {
        tokenA.mint(address(multicallRuntime), 1000);

        Call[] memory _calls = new Call[](3);
        _calls[0] = Call({
            target: address(tokenA),
            value: 0,
            data: abi.encodeWithSignature(
                "transfer(address,uint256)",
                otherPerson,
                100
            )
        });
        _calls[1] = Call({
            target: address(mockContract),
            value: 0,
            data: abi.encodeWithSignature("succeed()")
        });
        _calls[2] = Call({
            target: address(mockContract),
            value: 0,
            data: abi.encodeWithSignature("returnData()")
        });

        uint256 balanceBefore = tokenA.balanceOf(otherPerson);
        bytes[] memory results = _run(_calls);
        assertEq(tokenA.balanceOf(otherPerson), balanceBefore + 100);
        assertTrue(abi.decode(results[0], (bool)));
        assertTrue(abi.decode(results[1], (bool)));
        assertEq(results[2], abi.encode(uint256(42), "test"));
    }

    /// @notice The fallback path (raw abi.encode(Call[]) forwarded verbatim) runs the same batch.
    function test_fallback_rawPayload_runsCalls() public {
        tokenA.mint(address(multicallRuntime), 1000);

        Call[] memory _calls = new Call[](1);
        _calls[0] = Call({
            target: address(tokenA),
            value: 0,
            data: abi.encodeWithSignature(
                "transfer(address,uint256)",
                otherPerson,
                100
            )
        });

        uint256 balanceBefore = tokenA.balanceOf(otherPerson);
        (bool ok, ) = address(multicallRuntime).call(abi.encode(_calls));
        assertTrue(ok);
        assertEq(tokenA.balanceOf(otherPerson), balanceBefore + 100);
    }

    receive() external payable {}
}

contract MockContract {
    receive() external payable {}

    function fail() external pure {
        revert("Contract failed");
    }

    function succeed() external pure returns (bool) {
        return true;
    }

    function receiveEther() external payable {
        require(msg.value > 0, "No value sent");
    }

    function returnData() external pure returns (uint256, string memory) {
        return (42, "test");
    }
}
