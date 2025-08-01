// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseTest} from "../BaseTest.sol";
import {Executor} from "../../contracts/Executor.sol";
import {IExecutor} from "../../contracts/interfaces/IExecutor.sol";
import {IProver} from "../../contracts/interfaces/IProver.sol";
import {TestProver} from "../../contracts/test/TestProver.sol";
import {BadERC20} from "../../contracts/test/BadERC20.sol";
import {Call} from "../../contracts/types/Intent.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract ExecutorTest is BaseTest {
    Executor internal executor;
    address internal unauthorizedUser;
    address internal eoaTarget;
    TestProver internal testProver;
    MockContract internal mockContract;

    function setUp() public override {
        super.setUp();
        unauthorizedUser = makeAddr("unauthorizedUser");
        eoaTarget = makeAddr("eoaTarget");

        testProver = new TestProver(address(portal));
        mockContract = new MockContract();

        vm.prank(address(portal));
        executor = new Executor();
    }

    function test_constructor_setsPortalCorrectly() public {
        Call memory call = Call({
            target: address(mockContract),
            value: 0,
            data: abi.encodeWithSignature("succeed()")
        });

        address testPortal = makeAddr("testPortal");
        vm.prank(testPortal);
        Executor testExecutor = new Executor();

        vm.prank(testPortal);
        testExecutor.execute(call);
    }

    function test_execute_revertUnauthorized() public {
        Call memory call = Call({
            target: address(tokenA),
            value: 0,
            data: abi.encodeWithSignature(
                "transfer(address,uint256)",
                otherPerson,
                100
            )
        });

        vm.prank(unauthorizedUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                IExecutor.Unauthorized.selector,
                unauthorizedUser
            )
        );
        executor.execute(call);
    }

    function test_execute_success_authorizedCaller() public {
        tokenA.mint(address(executor), 1000);

        Call memory call = Call({
            target: address(tokenA),
            value: 0,
            data: abi.encodeWithSignature(
                "transfer(address,uint256)",
                otherPerson,
                100
            )
        });

        uint256 balanceBefore = tokenA.balanceOf(otherPerson);

        vm.prank(address(portal));
        bytes memory result = executor.execute(call);

        uint256 balanceAfter = tokenA.balanceOf(otherPerson);

        assertEq(balanceAfter, balanceBefore + 100);
        assertTrue(abi.decode(result, (bool)));
    }

    function test_execute_success_withValue() public {
        vm.deal(address(portal), 10 ether);

        Call memory call = Call({
            target: address(mockContract),
            value: 1 ether,
            data: abi.encodeWithSignature("receiveEther()")
        });

        uint256 contractBalanceBefore = address(mockContract).balance;

        vm.prank(address(portal));
        executor.execute{value: 1 ether}(call);

        uint256 contractBalanceAfter = address(mockContract).balance;
        assertEq(contractBalanceAfter, contractBalanceBefore + 1 ether);
    }

    function test_execute_success_returnsData() public {
        Call memory call = Call({
            target: address(mockContract),
            value: 0,
            data: abi.encodeWithSignature("returnData()")
        });

        vm.prank(address(portal));
        bytes memory result = executor.execute(call);

        assertEq(result, abi.encode(uint256(42), "test"));
    }

    function test_execute_revertCallToEOA_withCalldata() public {
        Call memory call = Call({
            target: eoaTarget,
            value: 0,
            data: abi.encodeWithSignature("someFunction()")
        });

        vm.prank(address(portal));
        vm.expectRevert(
            abi.encodeWithSelector(IExecutor.CallToEOA.selector, eoaTarget)
        );
        executor.execute(call);
    }

    function test_execute_success_EOAWithoutCalldata() public {
        vm.deal(address(portal), 10 ether);

        Call memory call = Call({target: eoaTarget, value: 1 ether, data: ""});

        uint256 balanceBefore = eoaTarget.balance;

        vm.prank(address(portal));
        executor.execute{value: 1 ether}(call);

        uint256 balanceAfter = eoaTarget.balance;
        assertEq(balanceAfter, balanceBefore + 1 ether);
    }

    function test_execute_success_contractWithEmptyCalldata() public {
        Call memory call = Call({
            target: address(mockContract),
            value: 0,
            data: ""
        });

        vm.prank(address(portal));
        bytes memory result = executor.execute(call);

        assertEq(result.length, 0);
    }

    function test_execute_revertCallToProver() public {
        Call memory call = Call({
            target: address(testProver),
            value: 0,
            data: abi.encodeWithSignature("version()")
        });

        vm.prank(address(portal));
        vm.expectRevert(
            abi.encodeWithSelector(
                IExecutor.CallToProver.selector,
                address(testProver)
            )
        );
        executor.execute(call);
    }

    function test_execute_success_contractNotImplementingIProver() public {
        tokenA.mint(address(executor), 1000);

        Call memory call = Call({
            target: address(tokenA),
            value: 0,
            data: abi.encodeWithSignature(
                "transfer(address,uint256)",
                otherPerson,
                100
            )
        });

        vm.prank(address(portal));
        bytes memory result = executor.execute(call);

        assertTrue(abi.decode(result, (bool)));
    }

    function test_execute_revertCallFailed() public {
        Call memory call = Call({
            target: address(mockContract),
            value: 0,
            data: abi.encodeWithSignature("fail()")
        });

        vm.prank(address(portal));
        vm.expectRevert();
        executor.execute(call);
    }

    function test_execute_revertCallFailed_insufficientValue() public {
        Call memory call = Call({
            target: address(mockContract),
            value: 1 ether,
            data: abi.encodeWithSignature("receiveEther()")
        });

        vm.prank(address(portal));
        vm.expectRevert();
        executor.execute(call);
    }

    function test_execute_revertCallFailed_invalidFunction() public {
        Call memory call = Call({
            target: address(tokenA),
            value: 0,
            data: abi.encodeWithSignature("nonExistentFunction()")
        });

        vm.prank(address(portal));
        vm.expectRevert();
        executor.execute(call);
    }

    function test_execute_success_emptyDataToContract() public {
        Call memory call = Call({
            target: address(mockContract),
            value: 0,
            data: ""
        });

        vm.prank(address(portal));
        bytes memory result = executor.execute(call);

        assertEq(result.length, 0);
    }
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
