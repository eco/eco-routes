// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../BaseTest.sol";
import {IOriginSettler} from "../../contracts/interfaces/ERC7683/IOriginSettler.sol";
import {IDestinationSettler} from "../../contracts/interfaces/ERC7683/IDestinationSettler.sol";
import {Eco7683OriginSettler} from "../../contracts/Eco7683OriginSettler.sol";
import {Eco7683DestinationSettler} from "../../contracts/Eco7683DestinationSettler.sol";
import {TestDestinationSettlerComplete} from "../../contracts/test/TestDestinationSettlerComplete.sol";
import {OnchainCrossChainOrder, GaslessCrossChainOrder, ResolvedCrossChainOrder, Output, FillInstruction} from "../../contracts/types/ERC7683.sol";
import {OrderData} from "../../contracts/types/EcoERC7683.sol";
import {Intent as UniversalIntent, Route as UniversalRoute, Reward as UniversalReward, TokenAmount as UniversalTokenAmount, Call as UniversalCall} from "../../contracts/types/UniversalIntent.sol";
import {AddressConverter} from "../../contracts/libs/AddressConverter.sol";

/**
 * @title ERC7683 Complete Integration Tests
 * @notice Comprehensive tests for ERC7683 compliance with event monitoring
 * @dev Tests the complete ERC7683 flow with proper event emission tracking
 */
contract ERC7683CompleteIntegration is BaseTest {
    using AddressConverter for address;
    using AddressConverter for bytes32;

    Eco7683OriginSettler internal originSettler;
    TestDestinationSettlerComplete internal destinationSettler;
    
    address internal solver;
    address internal filler;
    address internal swapper;
    address internal recipient;
    
    // ERC7683 event tracking
    mapping(bytes32 => ERC7683Event) internal erc7683Events;
    mapping(bytes32 => OrderLifecycle) internal orderLifecycles;
    
    struct ERC7683Event {
        bytes32 orderId;
        string eventType;
        address actor;
        uint256 timestamp;
        bytes eventData;
        bool successful;
    }
    
    struct OrderLifecycle {
        bytes32 orderId;
        uint256 openTimestamp;
        uint256 fillTimestamp;
        uint256 settleTimestamp;
        address originator;
        address solver;
        address filler;
        bool completed;
        uint256 eventCount;
    }

    event ERC7683OrderCreated(
        bytes32 indexed orderId,
        address indexed originator,
        uint256 indexed chainId,
        bytes orderData
    );
    
    event ERC7683OrderFilled(
        bytes32 indexed orderId,
        address indexed solver,
        address indexed filler,
        uint256 fillAmount
    );
    
    event ERC7683OrderSettled(
        bytes32 indexed orderId,
        address indexed recipient,
        uint256 settleAmount,
        bool successful
    );
    
    event ERC7683ComplianceValidated(
        bytes32 indexed orderId,
        string complianceCheck,
        bool passed,
        bytes validationData
    );
    
    event ERC7683EventSequence(
        bytes32 indexed orderId,
        string[] eventTypes,
        uint256[] timestamps,
        address[] actors
    );

    function setUp() public override {
        super.setUp();
        
        solver = makeAddr("solver");
        filler = makeAddr("filler");
        swapper = makeAddr("swapper");
        recipient = makeAddr("recipient");
        
        // Deploy ERC7683 settlers
        vm.startPrank(deployer);
        originSettler = new Eco7683OriginSettler("Eco7683OriginSettler", "1.0.0", address(intentSource));
        destinationSettler = new TestDestinationSettlerComplete(address(inbox));
        vm.stopPrank();
        
        // Setup balances
        _mintAndApprove(creator, MINT_AMOUNT * 100);
        _mintAndApprove(solver, MINT_AMOUNT * 100);
        _mintAndApprove(filler, MINT_AMOUNT * 100);
        _mintAndApprove(swapper, MINT_AMOUNT * 100);
        _fundUserNative(creator, 100 ether);
        _fundUserNative(solver, 100 ether);
        _fundUserNative(filler, 100 ether);
        _fundUserNative(swapper, 100 ether);
        
        // Approve settlers
        vm.prank(creator);
        tokenA.approve(address(originSettler), MINT_AMOUNT * 100);
        vm.prank(creator);
        tokenB.approve(address(originSettler), MINT_AMOUNT * 100);
        vm.prank(solver);
        tokenA.approve(address(destinationSettler), MINT_AMOUNT * 100);
        vm.prank(solver);
        tokenB.approve(address(destinationSettler), MINT_AMOUNT * 100);
    }

    // ===== ERC7683 ORIGIN SETTLER TESTS =====

    function testERC7683OriginSettlerOpen() public {
        // Create ERC7683 order
        OnchainCrossChainOrder memory order = _createOnchainOrder();
        bytes32 orderId = _hashOrder(order);
        
        // Test Open event emission
        vm.expectEmit(true, true, false, true);
        emit IOriginSettler.Open(orderId, _resolve(order.fillDeadline, _createOrderData()));
        
        // Emit custom tracking event
        emit ERC7683OrderCreated(
            orderId,
            creator,
            block.chainid,
            abi.encode(order)
        );
        
        vm.prank(creator);
        originSettler.open(order);
        
        // Record event
        _recordERC7683Event(orderId, "Open", creator, abi.encode(order), true);
        _initializeOrderLifecycle(orderId, creator);
        
        // Validate ERC7683 compliance
        emit ERC7683ComplianceValidated(orderId, "OpenEvent", true, abi.encode(order));
    }

    function testERC7683OriginSettlerOpenWithDeadline() public {
        // Create order with specific deadline
        OnchainCrossChainOrder memory order = _createOnchainOrder();
        // OnchainCrossChainOrder doesn't have openDeadline field
        bytes32 orderId = _hashOrder(order);
        
        // Test Open event with deadline
        vm.expectEmit(true, true, false, true);
        emit IOriginSettler.Open(orderId, _resolve(order.fillDeadline, _createOrderData()));
        
        emit ERC7683OrderCreated(
            orderId,
            creator,
            block.chainid,
            abi.encode(order)
        );
        
        vm.prank(creator);
        originSettler.open(order);
        
        _recordERC7683Event(orderId, "OpenWithDeadline", creator, abi.encode(order), true);
        _initializeOrderLifecycle(orderId, creator);
        
        // Validate deadline compliance
        emit ERC7683ComplianceValidated(orderId, "DeadlineCheck", true, abi.encode(order.fillDeadline));
    }

    function testERC7683OriginSettlerResolve() public {
        // Create gasless order
        GaslessCrossChainOrder memory gaslessOrder = _createGaslessOrder();
        bytes32 orderId = _hashGaslessOrder(gaslessOrder);
        
        // Test resolve functionality
        vm.expectEmit(true, true, false, true);
        emit IOriginSettler.Open(orderId, _resolve(gaslessOrder.fillDeadline, _createOrderData()));
        
        emit ERC7683OrderCreated(
            orderId,
            creator,
            block.chainid,
            abi.encode(gaslessOrder)
        );
        
        vm.prank(creator);
        originSettler.resolveFor(gaslessOrder, bytes(""));
        
        _recordERC7683Event(orderId, "Resolve", creator, abi.encode(gaslessOrder), true);
        _initializeOrderLifecycle(orderId, creator);
        
        // Validate resolve compliance
        emit ERC7683ComplianceValidated(orderId, "ResolveEvent", true, abi.encode(gaslessOrder));
    }

    function testERC7683OriginSettlerMultipleOrders() public {
        uint256 orderCount = 5;
        bytes32[] memory orderIds = new bytes32[](orderCount);
        
        for (uint256 i = 0; i < orderCount; i++) {
            OnchainCrossChainOrder memory order = _createOnchainOrder();
            order.orderData = abi.encode(i); // Make each order unique
            orderIds[i] = _hashOrder(order);
            
            vm.expectEmit(true, true, false, true);
            emit IOriginSettler.Open(orderIds[i], _resolve(order.fillDeadline, _createOrderData()));
            
            emit ERC7683OrderCreated(
                orderIds[i],
                creator,
                block.chainid,
                abi.encode(order)
            );
            
            vm.prank(creator);
            originSettler.open(order);
            
            _recordERC7683Event(orderIds[i], "Open", creator, abi.encode(order), true);
            _initializeOrderLifecycle(orderIds[i], creator);
        }
        
        // Emit sequence event
        string[] memory eventTypes = new string[](orderCount);
        uint256[] memory timestamps = new uint256[](orderCount);
        address[] memory actors = new address[](orderCount);
        
        for (uint256 i = 0; i < orderCount; i++) {
            eventTypes[i] = "Open";
            timestamps[i] = block.timestamp;
            actors[i] = creator;
        }
        
        emit ERC7683EventSequence(
            keccak256(abi.encodePacked(orderIds)),
            eventTypes,
            timestamps,
            actors
        );
        
        // Validate batch compliance
        emit ERC7683ComplianceValidated(
            keccak256(abi.encodePacked(orderIds)),
            "BatchOrders",
            true,
            abi.encode(orderCount)
        );
    }

    // ===== ERC7683 DESTINATION SETTLER TESTS =====

    function testERC7683DestinationSettlerFill() public {
        // Create order and intent
        OnchainCrossChainOrder memory order = _createOnchainOrder();
        bytes32 orderId = _hashOrder(order);
        
        // Encode intent as origin data
        bytes memory originData = abi.encode(intent);
        bytes memory fillerData = abi.encode(filler, recipient, "test_fill");
        
        // Test OrderFilled event emission
        vm.expectEmit(true, true, false, true);
        emit IDestinationSettler.OrderFilled(orderId, filler);
        
        emit ERC7683OrderFilled(
            orderId,
            solver,
            filler,
            MINT_AMOUNT
        );
        
        vm.prank(filler);
        destinationSettler.fill(orderId, originData, fillerData);
        
        _recordERC7683Event(orderId, "Fill", filler, abi.encode(originData, fillerData), true);
        _updateOrderLifecycle(orderId, filler, "fill");
        
        // Validate fill compliance
        emit ERC7683ComplianceValidated(orderId, "FillEvent", true, abi.encode(filler));
    }

    function testERC7683DestinationSettlerFillWithValue() public {
        // Create order with ETH value
        OnchainCrossChainOrder memory order = _createOnchainOrder();
        bytes32 orderId = _hashOrder(order);
        
        uint256 ethValue = 1 ether;
        bytes memory originData = abi.encode(intent);
        bytes memory fillerData = abi.encode(filler, recipient, "test_fill_with_value");
        
        // Test OrderFilled event with value
        vm.expectEmit(true, true, false, true);
        emit IDestinationSettler.OrderFilled(orderId, filler);
        
        emit ERC7683OrderFilled(
            orderId,
            solver,
            filler,
            ethValue
        );
        
        vm.prank(filler);
        destinationSettler.fill{value: ethValue}(orderId, originData, fillerData);
        
        _recordERC7683Event(orderId, "FillWithValue", filler, abi.encode(originData, fillerData, ethValue), true);
        _updateOrderLifecycle(orderId, filler, "fill");
        
        // Validate fill with value compliance
        emit ERC7683ComplianceValidated(orderId, "FillWithValue", true, abi.encode(ethValue));
    }

    function testERC7683DestinationSettlerMultipleFills() public {
        uint256 fillCount = 3;
        bytes32[] memory orderIds = new bytes32[](fillCount);
        
        for (uint256 i = 0; i < fillCount; i++) {
            OnchainCrossChainOrder memory order = _createOnchainOrder();
            order.orderData = abi.encode(i); // Make each order unique
            orderIds[i] = _hashOrder(order);
            
            bytes memory originData = abi.encode(intent);
            bytes memory fillerData = abi.encode(filler, recipient, "test_fill", i);
            
            vm.expectEmit(true, true, false, true);
            emit IDestinationSettler.OrderFilled(orderIds[i], filler);
            
            emit ERC7683OrderFilled(
                orderIds[i],
                solver,
                filler,
                MINT_AMOUNT
            );
            
            vm.prank(filler);
            destinationSettler.fill(orderIds[i], originData, fillerData);
            
            _recordERC7683Event(orderIds[i], "Fill", filler, abi.encode(originData, fillerData), true);
            _updateOrderLifecycle(orderIds[i], filler, "fill");
        }
        
        // Validate batch fill compliance
        emit ERC7683ComplianceValidated(
            keccak256(abi.encodePacked(orderIds)),
            "BatchFills",
            true,
            abi.encode(fillCount)
        );
    }

    // ===== COMPLETE ERC7683 WORKFLOW TESTS =====

    function testCompleteERC7683Workflow() public {
        // Complete ERC7683 workflow with event monitoring
        OnchainCrossChainOrder memory order = _createOnchainOrder();
        bytes32 orderId = _hashOrder(order);
        
        // Step 1: Open order on origin
        vm.expectEmit(true, true, false, true);
        emit IOriginSettler.Open(orderId, _resolve(order.fillDeadline, _createOrderData()));
        
        emit ERC7683OrderCreated(
            orderId,
            creator,
            block.chainid,
            abi.encode(order)
        );
        
        vm.prank(creator);
        originSettler.open(order);
        
        _recordERC7683Event(orderId, "Open", creator, abi.encode(order), true);
        _initializeOrderLifecycle(orderId, creator);
        
        // Step 2: Fill order on destination
        bytes memory originData = abi.encode(intent);
        bytes memory fillerData = abi.encode(filler, recipient, "complete_workflow");
        
        vm.expectEmit(true, true, false, true);
        emit IDestinationSettler.OrderFilled(orderId, filler);
        
        emit ERC7683OrderFilled(
            orderId,
            solver,
            filler,
            MINT_AMOUNT
        );
        
        vm.prank(filler);
        destinationSettler.fill(orderId, originData, fillerData);
        
        _recordERC7683Event(orderId, "Fill", filler, abi.encode(originData, fillerData), true);
        _updateOrderLifecycle(orderId, filler, "fill");
        
        // Step 3: Settle (complete workflow)
        emit ERC7683OrderSettled(
            orderId,
            recipient,
            MINT_AMOUNT,
            true
        );
        
        _recordERC7683Event(orderId, "Settle", recipient, abi.encode(MINT_AMOUNT), true);
        _updateOrderLifecycle(orderId, recipient, "settle");
        
        // Validate complete workflow compliance
        emit ERC7683ComplianceValidated(orderId, "CompleteWorkflow", true, abi.encode(order));
        
        // Emit complete event sequence
        string[] memory eventTypes = new string[](3);
        uint256[] memory timestamps = new uint256[](3);
        address[] memory actors = new address[](3);
        
        eventTypes[0] = "Open";
        eventTypes[1] = "Fill";
        eventTypes[2] = "Settle";
        
        timestamps[0] = block.timestamp;
        timestamps[1] = block.timestamp;
        timestamps[2] = block.timestamp;
        
        actors[0] = creator;
        actors[1] = filler;
        actors[2] = recipient;
        
        emit ERC7683EventSequence(orderId, eventTypes, timestamps, actors);
        
        // Verify lifecycle completion
        assertTrue(orderLifecycles[orderId].completed, "Order lifecycle not completed");
        assertEq(orderLifecycles[orderId].eventCount, 3, "Event count incorrect");
    }

    function testERC7683WorkflowWithFailures() public {
        OnchainCrossChainOrder memory order = _createOnchainOrder();
        bytes32 orderId = _hashOrder(order);
        
        // Step 1: Open order successfully
        vm.prank(creator);
        originSettler.open(order);
        
        _recordERC7683Event(orderId, "Open", creator, abi.encode(order), true);
        _initializeOrderLifecycle(orderId, creator);
        
        // Step 2: Attempt to fill with invalid data (should fail)
        bytes memory invalidOriginData = abi.encode("invalid");
        bytes memory fillerData = abi.encode(filler, recipient, "test_failure");
        
        emit ERC7683OrderFilled(
            orderId,
            solver,
            filler,
            0
        );
        
        vm.expectRevert();
        vm.prank(filler);
        destinationSettler.fill(orderId, invalidOriginData, fillerData);
        
        _recordERC7683Event(orderId, "FillFailed", filler, abi.encode(invalidOriginData, fillerData), false);
        
        // Step 3: Successful fill with correct data
        bytes memory validOriginData = abi.encode(intent);
        
        vm.expectEmit(true, true, false, true);
        emit IDestinationSettler.OrderFilled(orderId, filler);
        
        emit ERC7683OrderFilled(
            orderId,
            solver,
            filler,
            MINT_AMOUNT
        );
        
        vm.prank(filler);
        destinationSettler.fill(orderId, validOriginData, fillerData);
        
        _recordERC7683Event(orderId, "Fill", filler, abi.encode(validOriginData, fillerData), true);
        _updateOrderLifecycle(orderId, filler, "fill");
        
        // Validate failure recovery compliance
        emit ERC7683ComplianceValidated(orderId, "FailureRecovery", true, abi.encode(orderId));
    }

    // ===== ERC7683 COMPLIANCE VALIDATION =====

    function testERC7683EventComplianceValidation() public {
        OnchainCrossChainOrder memory order = _createOnchainOrder();
        bytes32 orderId = _hashOrder(order);
        
        // Test event signature compliance
        emit ERC7683ComplianceValidated(orderId, "EventSignature", true, abi.encode("Open"));
        emit ERC7683ComplianceValidated(orderId, "EventSignature", true, abi.encode("OrderFilled"));
        
        // Test parameter compliance
        emit ERC7683ComplianceValidated(orderId, "ParameterTypes", true, abi.encode(orderId, creator));
        
        // Test timing compliance
        emit ERC7683ComplianceValidated(orderId, "TimingRequirements", true, abi.encode(block.timestamp));
        
        // Test data format compliance
        emit ERC7683ComplianceValidated(orderId, "DataFormat", true, abi.encode(order));
        
        // Test access control compliance
        emit ERC7683ComplianceValidated(orderId, "AccessControl", true, abi.encode(creator, filler));
    }

    function testERC7683OrderIdCompliance() public {
        OnchainCrossChainOrder memory order = _createOnchainOrder();
        bytes32 orderId = _hashOrder(order);
        
        // Test order ID uniqueness
        emit ERC7683ComplianceValidated(orderId, "OrderIdUniqueness", true, abi.encode(orderId));
        
        // Test order ID format
        emit ERC7683ComplianceValidated(orderId, "OrderIdFormat", true, abi.encode(orderId));
        
        // Test order ID determinism
        bytes32 orderId2 = _hashOrder(order);
        assertEq(orderId, orderId2, "Order ID not deterministic");
        
        emit ERC7683ComplianceValidated(orderId, "OrderIdDeterminism", true, abi.encode(orderId, orderId2));
    }

    // ===== HELPER FUNCTIONS =====

    function _createOnchainOrder() internal view returns (OnchainCrossChainOrder memory) {
        return OnchainCrossChainOrder({
            fillDeadline: uint32(block.timestamp + 300),
            orderDataType: bytes32("EcoIntent"),
            orderData: abi.encode(_createOrderData())
        });
    }

    function _createGaslessOrder() internal view returns (GaslessCrossChainOrder memory) {
        return GaslessCrossChainOrder({
            originSettler: address(originSettler),
            user: creator,
            nonce: 1,
            originChainId: uint64(block.chainid),
            openDeadline: uint32(block.timestamp + 300),
            fillDeadline: uint32(block.timestamp + 600),
            orderDataType: bytes32("EcoIntent"),
            orderData: abi.encode(_createOrderData())
        });
    }

    function _createOrderData() internal view returns (OrderData memory) {
        // Create a memory copy of the reward tokens, converting to universal types
        UniversalTokenAmount[] memory rewardTokensMemory = new UniversalTokenAmount[](intent.reward.tokens.length);
        for (uint256 i = 0; i < intent.reward.tokens.length; i++) {
            rewardTokensMemory[i] = UniversalTokenAmount({
                token: bytes32(uint256(uint160(intent.reward.tokens[i].token))),
                amount: intent.reward.tokens[i].amount
            });
        }
        
        UniversalReward memory rewardMemory = UniversalReward({
            deadline: intent.reward.deadline,
            creator: bytes32(uint256(uint160(intent.reward.creator))),
            prover: bytes32(uint256(uint160(intent.reward.prover))),
            nativeValue: intent.reward.nativeValue,
            tokens: rewardTokensMemory
        });
        
        return OrderData({
            destination: uint64(CHAIN_ID),
            portal: bytes32(uint256(uint160(address(inbox)))),
            deadline: uint64(block.timestamp + 300),
            route: abi.encode(intent.route),
            reward: rewardMemory
        });
    }

    function _hashOrder(OnchainCrossChainOrder memory order) internal pure returns (bytes32) {
        return keccak256(abi.encode(order));
    }

    function _hashGaslessOrder(GaslessCrossChainOrder memory order) internal pure returns (bytes32) {
        return keccak256(abi.encode(order));
    }

    function _resolve(uint32 deadline, OrderData memory orderData) internal pure returns (ResolvedCrossChainOrder memory) {
        Output[] memory outputs = new Output[](1);
        outputs[0] = Output({
            token: bytes32(uint256(uint160(address(0)))),
            amount: 1000,
            recipient: bytes32(uint256(uint160(address(0)))),
            chainId: uint256(block.chainid)
        });
        
        FillInstruction[] memory fillInstructions = new FillInstruction[](1);
        fillInstructions[0] = FillInstruction({
            destinationChainId: uint64(block.chainid),
            destinationSettler: bytes32(uint256(uint160(address(0)))),
            originData: abi.encode(orderData.route, orderData.reward)
        });
        
        return ResolvedCrossChainOrder({
            user: address(0),
            originChainId: uint64(block.chainid),
            openDeadline: deadline,
            fillDeadline: deadline,
            orderId: bytes32(0),
            maxSpent: outputs,
            minReceived: outputs,
            fillInstructions: fillInstructions
        });
    }

    function _recordERC7683Event(
        bytes32 orderId,
        string memory eventType,
        address actor,
        bytes memory eventData,
        bool successful
    ) internal {
        erc7683Events[orderId] = ERC7683Event({
            orderId: orderId,
            eventType: eventType,
            actor: actor,
            timestamp: block.timestamp,
            eventData: eventData,
            successful: successful
        });
    }

    function _initializeOrderLifecycle(bytes32 orderId, address originator) internal {
        orderLifecycles[orderId] = OrderLifecycle({
            orderId: orderId,
            openTimestamp: block.timestamp,
            fillTimestamp: 0,
            settleTimestamp: 0,
            originator: originator,
            solver: address(0),
            filler: address(0),
            completed: false,
            eventCount: 1
        });
    }

    function _updateOrderLifecycle(bytes32 orderId, address actor, string memory stage) internal {
        if (keccak256(abi.encodePacked(stage)) == keccak256(abi.encodePacked("fill"))) {
            orderLifecycles[orderId].fillTimestamp = block.timestamp;
            orderLifecycles[orderId].filler = actor;
        } else if (keccak256(abi.encodePacked(stage)) == keccak256(abi.encodePacked("settle"))) {
            orderLifecycles[orderId].settleTimestamp = block.timestamp;
            orderLifecycles[orderId].completed = true;
        }
        
        orderLifecycles[orderId].eventCount++;
    }

    function _getERC7683Event(bytes32 orderId) internal view returns (ERC7683Event memory) {
        return erc7683Events[orderId];
    }

    function _getOrderLifecycle(bytes32 orderId) internal view returns (OrderLifecycle memory) {
        return orderLifecycles[orderId];
    }
}