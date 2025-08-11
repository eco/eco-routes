// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BaseTest} from "../BaseTest.sol";
import {T1Prover} from "../../contracts/prover/t1Prover.sol";
import {IT1XChainReader} from "../../contracts/interfaces/t1/IT1XChainReader.sol";
import {IProver} from "../../contracts/interfaces/IProver.sol";

contract T1ProverTest is BaseTest {

    T1Prover internal t1Prover;
    IT1XChainReader internal xChainReader;

    address internal t1ProverAddress;

    function setUp() public override {
        super.setUp();

        t1ProverAddress = makeAddr("t1ProverAddress");

        vm.startPrank(deployer);

        xChainReader = IT1XChainReader(makeAddr("xChainReader"));

        t1Prover = new T1Prover(
            address(portal),
            uint32(block.chainid),
            address(xChainReader),
            t1ProverAddress
        );

        vm.stopPrank();

        _mintAndApprove(creator, MINT_AMOUNT);
        _fundUserNative(creator, 10 ether);
    }


    function testInitializesCorrectly() public view {
        assertTrue(address(t1Prover) != address(0));
        assertEq(t1Prover.getProofType(), "t1");
    }

    function testImplementsIProverInterface() public view {
        assertTrue(t1Prover.supportsInterface(type(IProver).interfaceId));
    }

    function testRequestIntentProof() public {
        bytes32 intentHash = _hashIntent(intent);
        uint32 destinationDomain = 1;
        
        vm.mockCall(
            address(xChainReader),
            abi.encodeWithSignature("requestRead((uint32,address,uint64,bytes,address))"),
            abi.encode(bytes32("request123"))
        );
        
        vm.expectEmit();
        emit T1Prover.IntentProofRequested(intentHash, bytes32("request123"));
        
        vm.prank(creator);
        t1Prover.requestIntentProof{value: 1 ether}(destinationDomain, intentHash);
        
        // Check that the request was stored
        (uint32 storedDestination, bytes32 storedHash) = t1Prover.readRequestToIntentRequest(bytes32("request123"));
        assertEq(storedDestination, destinationDomain);
        assertEq(storedHash, intentHash);
    }

    function testHandleReadResultWithProof() public {
        bytes32 intentHash = _hashIntent(intent);
        bytes32 requestId = bytes32("request123");
        uint32 destinationDomain = 1;
        
        bytes32 baseSlot = keccak256(abi.encode(requestId, uint256(1)));
        
        vm.store(address(t1Prover), baseSlot, bytes32(uint256(destinationDomain)));
        vm.store(address(t1Prover), bytes32(uint256(baseSlot) + 1), intentHash);
        
        // Mock the xChainReader verifyProofOfReadWithResult call
        vm.mockCall(
            address(xChainReader),
            abi.encodeWithSignature("verifyProofOfReadWithResult(bytes,bytes)"),
            abi.encode(requestId)
        );
        
        // Create result data with non-zero claimant (as expected by handleReadResultWithProof)
        bytes memory result = abi.encode(intentHash, bytes32(uint256(uint160(claimant))));
        
        vm.expectEmit();
        emit IProver.IntentProven(intentHash, claimant, destinationDomain);
        
        vm.prank(creator);
        t1Prover.handleReadResultWithProof("proof", result);
    }

    function testHandleReadResultWithProofFailsWithZeroClaimant() public {
        bytes32 intentHash = _hashIntent(intent);
        bytes32 requestId = bytes32("request123");
        uint32 destinationDomain = 1;
        
        bytes32 baseSlot = keccak256(abi.encode(requestId, uint256(1)));
        vm.store(address(t1Prover), baseSlot, bytes32(uint256(destinationDomain)));
        vm.store(address(t1Prover), bytes32(uint256(baseSlot) + 1), intentHash);
        
        vm.mockCall(
            address(xChainReader),
            abi.encodeWithSignature("verifyProofOfReadWithResult(bytes,bytes)"),
            abi.encode(requestId)
        );
        
        // Create result data with zero claimant (unfulfilled intent)
        bytes memory result = abi.encode(intentHash, bytes32(0));
        
        vm.expectRevert(T1Prover.IntentNotFufilled.selector);
        
        vm.prank(creator);
        t1Prover.handleReadResultWithProof("proof", result);
    }
}
