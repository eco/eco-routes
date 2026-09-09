// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployIntentChainer} from "../../scripts/DeployIntentChainer.s.sol";
import {IntentChainer} from "../../contracts/chain/IntentChainer.sol";
import {ICreate3Deployer} from "../../contracts/tools/ICreate3Deployer.sol";

contract DeployIntentChainerTest is Test {
    address constant FACTORY = 0xC6BAd1EbAF366288dA6FB5689119eDd695a66814;
    address constant PREDICTED = address(0x1234);
    DeployIntentChainer script;

    function setUp() public {
        vm.setEnv("PRIVATE_KEY", "1");
        vm.setEnv("SALT", vm.toString(bytes32(uint256(42))));
        vm.setEnv("EXPECTED_CHAIN_ID", vm.toString(block.chainid));
        vm.etch(FACTORY, hex"00");
        vm.mockCall(
            FACTORY,
            abi.encodeWithSelector(ICreate3Deployer.deployedAddress.selector),
            abi.encode(PREDICTED)
        );
        script = new DeployIntentChainer();
    }

    function test_predictAndVerifyMatchingRuntime() public {
        vm.etch(PREDICTED, type(IntentChainer).runtimeCode);
        script.predictAddress();
        script.verifyAddress();
    }

    function test_runSkipsVerifiedExistingDeployment() public {
        vm.etch(PREDICTED, type(IntentChainer).runtimeCode);
        vm.mockCallRevert(
            FACTORY,
            abi.encodeWithSelector(ICreate3Deployer.deploy.selector),
            "must not deploy again"
        );
        script.run();
    }

    function test_wrongChainRejected() public {
        vm.chainId(block.chainid + 1);
        vm.expectRevert("Unexpected chain ID");
        script.predictAddress();
    }

    function test_missingFactoryRejected() public {
        vm.etch(FACTORY, hex"");
        vm.expectRevert("CREATE3 deployer missing");
        script.predictAddress();
    }

    function test_predictRejectsDifferentExistingRuntime() public {
        vm.etch(PREDICTED, hex"00");
        vm.expectRevert("IntentChainer runtime mismatch");
        script.predictAddress();
    }

    function test_runRejectsDifferentExistingRuntime() public {
        vm.etch(PREDICTED, hex"00");
        vm.expectRevert("IntentChainer runtime mismatch");
        script.run();
    }

    function test_verifyRejectsMissingDeployment() public {
        vm.expectRevert("IntentChainer runtime mismatch");
        script.verifyAddress();
    }

    function test_missingSha256Rejected() public {
        vm.mockCall(address(0x02), bytes("abc"), abi.encode(bytes32(0)));
        vm.expectRevert("SHA-256 precompile unavailable");
        script.predictAddress();
    }

    function test_truncatedModexpRejected() public {
        vm.mockCall(address(0x05), bytes(""), hex"0f");
        vm.expectRevert("MODEXP precompile unavailable");
        script.predictAddress();
    }

    function test_wrongModexpResultRejected() public {
        vm.mockCall(address(0x05), bytes(""), abi.encode(uint256(0)));
        vm.expectRevert("MODEXP precompile unavailable");
        script.predictAddress();
    }

    function test_newDeploymentRuntimeMustMatch() public {
        vm.mockCall(
            FACTORY,
            abi.encodeWithSelector(ICreate3Deployer.deploy.selector),
            abi.encode(PREDICTED)
        );
        vm.expectRevert("IntentChainer runtime mismatch");
        script.run();
    }
}
