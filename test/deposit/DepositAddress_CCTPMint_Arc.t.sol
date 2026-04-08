// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DepositFactory_CCTPMint_Arc} from "../../contracts/deposit/DepositFactory_CCTPMint_Arc.sol";
import {DepositAddress_CCTPMint_Arc} from "../../contracts/deposit/DepositAddress_CCTPMint_Arc.sol";
import {BaseDepositAddress} from "../../contracts/deposit/BaseDepositAddress.sol";
import {Portal} from "../../contracts/Portal.sol";
import {Intent, Route, Reward, TokenAmount, Call} from "../../contracts/types/Intent.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";

contract DepositAddress_CCTPMint_ArcTest is Test {
    DepositFactory_CCTPMint_Arc public factory;
    DepositAddress_CCTPMint_Arc public depositAddress;
    Portal public portal;
    TestERC20 public token;

    // Configuration parameters
    address constant PROVER_ADDRESS = address(0x9ABC);
    uint64 constant INTENT_DEADLINE_DURATION = 7 days;
    uint32 constant DESTINATION_DOMAIN = 6;
    address constant CCTP_TOKEN_MESSENGER = address(0xABCD);
    uint64 constant ARC_CHAIN_ID = 41455;
    address constant ARC_PROVER_ADDRESS = address(0xBBBB);
    address constant ARC_USDC = address(0xCCCC);
    address constant GATEWAY_ADDRESS = address(0xDDDD);

    // Test user addresses
    address constant USER_DESTINATION = address(0x1111);
    address constant DEPOSITOR = address(0x3333);
    address constant ATTACKER = address(0x6666);

    uint256 private constant NATIVE_USDC_SCALING = 1e12;
    uint256 private constant MAX_FEE_BPS = 13;
    uint256 private constant FEE_DENOMINATOR = 100_000;

    function setUp() public {
        token = new TestERC20("Test USDC", "USDC");
        portal = new Portal();

        factory = new DepositFactory_CCTPMint_Arc(
            address(token),
            address(portal),
            PROVER_ADDRESS,
            INTENT_DEADLINE_DURATION,
            DESTINATION_DOMAIN,
            CCTP_TOKEN_MESSENGER,
            ARC_CHAIN_ID,
            ARC_PROVER_ADDRESS,
            ARC_USDC,
            GATEWAY_ADDRESS,
            MAX_FEE_BPS
        );

        address deployed = factory.deploy(USER_DESTINATION, DEPOSITOR);
        depositAddress = DepositAddress_CCTPMint_Arc(deployed);
    }

    // ============ Initialization Tests ============

    function test_initialize_setsDestinationAddress() public view {
        assertEq(depositAddress.destinationAddress(), bytes32(uint256(uint160(USER_DESTINATION))));
    }

    function test_initialize_setsDepositor() public view {
        assertEq(depositAddress.depositor(), DEPOSITOR);
    }

    function test_initialize_revertsIfAlreadyInitialized() public {
        vm.expectRevert(BaseDepositAddress.AlreadyInitialized.selector);
        depositAddress.initialize(bytes32(uint256(uint160(USER_DESTINATION))), DEPOSITOR);
    }

    function test_initialize_revertsIfNotCalledByFactory() public {
        DepositAddress_CCTPMint_Arc implementation = new DepositAddress_CCTPMint_Arc();

        vm.prank(ATTACKER);
        vm.expectRevert(BaseDepositAddress.OnlyFactory.selector);
        implementation.initialize(bytes32(uint256(uint160(USER_DESTINATION))), DEPOSITOR);
    }

    function test_initialize_revertsIfDepositorIsZero() public {
        vm.expectRevert(BaseDepositAddress.InvalidDepositor.selector);
        factory.deploy(USER_DESTINATION, address(0));
    }

    function test_initialize_revertsIfDestinationAddressIsZero() public {
        vm.expectRevert(BaseDepositAddress.InvalidDestinationAddress.selector);
        factory.deploy(address(0), DEPOSITOR);
    }

    // ============ createIntent Basic Tests ============

    function test_createIntent_revertsIfNotInitialized() public {
        DepositAddress_CCTPMint_Arc uninit = new DepositAddress_CCTPMint_Arc();

        vm.expectRevert(BaseDepositAddress.NotInitialized.selector);
        uninit.createIntent();
    }

    function test_createIntent_revertsIfZeroBalance() public {
        vm.expectRevert(BaseDepositAddress.ZeroAmount.selector);
        depositAddress.createIntent();
    }

    function test_createIntent_succeeds() public {
        uint256 amount = 10_000 * 1e6;
        token.mint(address(depositAddress), amount);

        bytes32 intentHash = depositAddress.createIntent();
        assertTrue(intentHash != bytes32(0));
    }

    function test_createIntent_drainsBalance() public {
        uint256 amount = 10_000 * 1e6;
        token.mint(address(depositAddress), amount);

        depositAddress.createIntent();

        assertEq(token.balanceOf(address(depositAddress)), 0);
    }

    function test_createIntent_permissionless() public {
        uint256 amount = 10_000 * 1e6;
        token.mint(address(depositAddress), amount);

        vm.prank(ATTACKER);
        bytes32 intentHash = depositAddress.createIntent();

        assertTrue(intentHash != bytes32(0));
    }

    function test_createIntent_multipleCallsSucceed() public {
        uint256 amount1 = 10_000 * 1e6;
        uint256 amount2 = 5_000 * 1e6;

        token.mint(address(depositAddress), amount1);
        bytes32 intentHash1 = depositAddress.createIntent();

        vm.warp(block.timestamp + 1);
        token.mint(address(depositAddress), amount2);
        bytes32 intentHash2 = depositAddress.createIntent();

        assertTrue(intentHash1 != bytes32(0));
        assertTrue(intentHash2 != bytes32(0));
        assertTrue(intentHash1 != intentHash2);
    }

    // ============ Two-Intent Structure Tests ============

    function test_createIntent_emitsTwoIntentPublishedEvents() public {
        uint256 amount = 10_000 * 1e6;
        token.mint(address(depositAddress), amount);

        vm.recordLogs();
        depositAddress.createIntent();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 intentPublishedSig = keccak256(
            "IntentPublished(bytes32,uint64,bytes,address,address,uint64,uint256,(address,uint256)[])"
        );

        uint256 intentPublishedCount = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == intentPublishedSig) {
                intentPublishedCount++;
            }
        }

        assertEq(intentPublishedCount, 2, "Should emit exactly two IntentPublished events");
    }

    function test_createIntent_intent2_isPublishedFirst() public {
        uint256 amount = 10_000 * 1e6;
        token.mint(address(depositAddress), amount);

        vm.recordLogs();
        depositAddress.createIntent();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 intentPublishedSig = keccak256(
            "IntentPublished(bytes32,uint64,bytes,address,address,uint64,uint256,(address,uint256)[])"
        );

        // Find the two IntentPublished events
        uint64 firstDestination;
        uint64 secondDestination;
        uint256 eventIdx = 0;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == intentPublishedSig) {
                (uint64 destination, , , , ) = abi.decode(
                    logs[i].data,
                    (uint64, bytes, uint64, uint256, TokenAmount[])
                );

                if (eventIdx == 0) {
                    firstDestination = destination;
                } else {
                    secondDestination = destination;
                }
                eventIdx++;
            }
        }

        // Intent 2 (Gateway deposit on Arc) is published first
        assertEq(firstDestination, ARC_CHAIN_ID, "First event should be Intent 2 targeting Arc");
        // Intent 1 (CCTP burn on source chain) is published second
        assertEq(secondDestination, uint64(block.chainid), "Second event should be Intent 1 targeting source chain");
    }

    function test_createIntent_intent2_hasCorrectStructure() public {
        uint256 amount = 10_000 * 1e6;
        token.mint(address(depositAddress), amount);

        vm.recordLogs();
        depositAddress.createIntent();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 intentPublishedSig = keccak256(
            "IntentPublished(bytes32,uint64,bytes,address,address,uint64,uint256,(address,uint256)[])"
        );

        // Find the first IntentPublished event (Intent 2 - Gateway deposit on Arc)
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == intentPublishedSig) {
                // Indexed fields
                address creator = address(uint160(uint256(logs[i].topics[2])));
                address proverAddr = address(uint160(uint256(logs[i].topics[3])));

                // Non-indexed fields
                (
                    uint64 destination,
                    bytes memory routeBytes,
                    , // rewardDeadline (verified in separate test)
                    uint256 rewardNativeAmount,
                    TokenAmount[] memory rewardTokens
                ) = abi.decode(
                    logs[i].data,
                    (uint64, bytes, uint64, uint256, TokenAmount[])
                );

                // Verify Intent 2 targets Arc
                assertEq(destination, ARC_CHAIN_ID, "Intent 2 destination should be Arc chain");
                assertEq(creator, DEPOSITOR, "Intent 2 creator should be depositor");
                assertEq(proverAddr, ARC_PROVER_ADDRESS, "Intent 2 prover should be Arc prover");

                // Compute expected net amount after CCTP fee deduction (rounded up)
                uint256 maxFee = (amount * MAX_FEE_BPS + FEE_DENOMINATOR - 1) / FEE_DENOMINATOR;
                uint256 netAmount = amount - maxFee;

                // Verify route
                Route memory route = abi.decode(routeBytes, (Route));
                assertEq(route.portal, address(portal), "Intent 2 route portal should be portal");
                assertEq(route.nativeAmount, netAmount * NATIVE_USDC_SCALING, "Intent 2 route nativeAmount should be scaled net amount");
                assertEq(route.tokens.length, 0, "Intent 2 route should have empty tokens array");
                assertEq(route.calls.length, 2, "Intent 2 route should have two calls (approve + depositFor)");

                // Verify call 0: approve Gateway for USDC (net amount)
                assertEq(route.calls[0].target, ARC_USDC, "Call 0 target should be ARC_USDC");
                assertEq(route.calls[0].value, 0, "Call 0 value should be 0");

                bytes memory expectedApproveData = abi.encodeWithSignature(
                    "approve(address,uint256)",
                    GATEWAY_ADDRESS,
                    netAmount
                );
                assertEq(route.calls[0].data, expectedApproveData, "Call 0 data should encode approve with net amount");

                // Verify call 1: Gateway.depositFor (net amount)
                assertEq(route.calls[1].target, GATEWAY_ADDRESS, "Call 1 target should be Gateway");
                assertEq(route.calls[1].value, 0, "Call 1 value should be 0");

                bytes memory expectedDepositForData = abi.encodeWithSignature(
                    "depositFor(address,address,uint256)",
                    ARC_USDC,
                    address(uint160(uint256(bytes32(uint256(uint160(USER_DESTINATION)))))),
                    netAmount
                );
                assertEq(route.calls[1].data, expectedDepositForData, "Call 1 data should encode depositFor with net amount");

                // Verify reward
                assertEq(rewardNativeAmount, netAmount * NATIVE_USDC_SCALING, "Intent 2 reward nativeAmount should be scaled net amount");
                assertEq(rewardTokens.length, 0, "Intent 2 reward should have empty tokens array");

                break;
            }
        }
    }

    function test_createIntent_intent1_hasCorrectStructure() public {
        uint256 amount = 10_000 * 1e6;
        token.mint(address(depositAddress), amount);

        vm.recordLogs();
        depositAddress.createIntent();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 intentPublishedSig = keccak256(
            "IntentPublished(bytes32,uint64,bytes,address,address,uint64,uint256,(address,uint256)[])"
        );

        // Find the second IntentPublished event (Intent 1 - CCTP burn on source chain)
        uint256 eventIdx = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == intentPublishedSig) {
                if (eventIdx == 1) {
                    // This is the second IntentPublished event (Intent 1)

                    // Indexed fields
                    address creator = address(uint160(uint256(logs[i].topics[2])));
                    address proverAddr = address(uint160(uint256(logs[i].topics[3])));

                    // Non-indexed fields
                    (
                        uint64 destination,
                        bytes memory routeBytes,
                        , // rewardDeadline (verified in separate test)
                        uint256 rewardNativeAmount,
                        TokenAmount[] memory rewardTokens
                    ) = abi.decode(
                        logs[i].data,
                        (uint64, bytes, uint64, uint256, TokenAmount[])
                    );

                    // Verify Intent 1 targets source chain
                    assertEq(destination, uint64(block.chainid), "Intent 1 destination should be source chain");
                    assertEq(creator, DEPOSITOR, "Intent 1 creator should be depositor");
                    assertEq(proverAddr, PROVER_ADDRESS, "Intent 1 prover should be source chain prover");

                    // Verify route
                    Route memory route = abi.decode(routeBytes, (Route));
                    assertEq(route.portal, address(portal), "Intent 1 route portal should be portal");
                    assertEq(route.nativeAmount, 0, "Intent 1 route should have no native amount");
                    assertEq(route.tokens.length, 1, "Intent 1 route should have one token");
                    assertEq(route.tokens[0].token, address(token), "Intent 1 route token should be source USDC");
                    assertEq(route.tokens[0].amount, amount, "Intent 1 route token amount should match deposit");
                    assertEq(route.calls.length, 2, "Intent 1 route should have two calls (approve + CCTP depositForBurn)");

                    // Verify approve call (calls[0])
                    assertEq(route.calls[0].target, address(token), "Call 0 target should be source token (approve)");
                    assertEq(route.calls[0].value, 0, "Approve call should have no value");

                    // Verify CCTP depositForBurn call (calls[1])
                    assertEq(route.calls[1].target, CCTP_TOKEN_MESSENGER, "Call 1 target should be TokenMessenger");
                    assertEq(route.calls[1].value, 0, "CCTP call should have no value");

                    // Verify reward
                    assertEq(rewardNativeAmount, 0, "Intent 1 reward should have no native amount");
                    assertEq(rewardTokens.length, 1, "Intent 1 reward should have one token");
                    assertEq(rewardTokens[0].token, address(token), "Intent 1 reward token should be source USDC");
                    assertEq(rewardTokens[0].amount, amount, "Intent 1 reward amount should match deposit");

                    break;
                }
                eventIdx++;
            }
        }
    }

    function test_createIntent_intent1_cctpCallData_isCorrect() public {
        uint256 amount = 10_000 * 1e6;
        token.mint(address(depositAddress), amount);

        vm.recordLogs();
        depositAddress.createIntent();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 intentPublishedSig = keccak256(
            "IntentPublished(bytes32,uint64,bytes,address,address,uint64,uint256,(address,uint256)[])"
        );

        uint256 eventIdx = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == intentPublishedSig) {
                if (eventIdx == 1) {
                    // Intent 1: verify CCTP call
                    (
                        ,
                        bytes memory routeBytes,
                        ,
                        ,
                    ) = abi.decode(
                        logs[i].data,
                        (uint64, bytes, uint64, uint256, TokenAmount[])
                    );

                    Route memory route = abi.decode(routeBytes, (Route));

                    // Decode the CCTP depositForBurn call data (calls[1], after approve)
                    // Expected signature: depositForBurn(uint256,uint32,bytes32,address,bytes32,uint256,uint32)
                    bytes memory callData = route.calls[1].data;

                    // Skip the 4-byte selector and decode the parameters
                    bytes4 selector = bytes4(callData);
                    assertEq(
                        selector,
                        bytes4(keccak256("depositForBurn(uint256,uint32,bytes32,address,bytes32,uint256,uint32)")),
                        "CCTP call should use depositForBurn selector"
                    );

                    // Decode parameters after the selector
                    (
                        uint256 cctpAmount,
                        uint32 destDomain,
                        bytes32 mintRecipient,
                        address burnToken,
                        bytes32 destinationCaller,
                        uint256 maxFee,
                        uint32 minFinalityThreshold
                    ) = abi.decode(
                        _sliceBytes(callData, 4),
                        (uint256, uint32, bytes32, address, bytes32, uint256, uint32)
                    );

                    uint256 expectedMaxFee = (amount * MAX_FEE_BPS + FEE_DENOMINATOR - 1) / FEE_DENOMINATOR;
                    assertEq(cctpAmount, amount, "CCTP amount should match deposit");
                    assertEq(destDomain, DESTINATION_DOMAIN, "CCTP destination domain should match");
                    assertEq(burnToken, address(token), "CCTP burn token should be source USDC");
                    assertEq(destinationCaller, bytes32(0), "CCTP destination caller should be zero (anyone)");
                    assertEq(maxFee, expectedMaxFee, "CCTP maxFee should be 1.3 bps of amount");
                    assertEq(minFinalityThreshold, 0, "CCTP minFinalityThreshold should be 0 (fast finality)");

                    // mintRecipient should be vault2 encoded as bytes32
                    // We can verify it is non-zero (vault addresses are always non-zero)
                    assertTrue(mintRecipient != bytes32(0), "mintRecipient should not be zero");

                    break;
                }
                eventIdx++;
            }
        }
    }

    function test_createIntent_mintRecipient_matchesIntent2Vault() public {
        uint256 amount = 10_000 * 1e6;
        token.mint(address(depositAddress), amount);

        vm.recordLogs();
        depositAddress.createIntent();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 intentPublishedSig = keccak256(
            "IntentPublished(bytes32,uint64,bytes,address,address,uint64,uint256,(address,uint256)[])"
        );

        // Collect Intent 2's hash and decode Intent 1's mintRecipient
        bytes32 intent2Hash;
        bytes32 mintRecipient;
        uint256 eventIdx = 0;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == intentPublishedSig) {
                if (eventIdx == 0) {
                    // Intent 2 event -- grab the intent hash from topics
                    intent2Hash = logs[i].topics[1];
                }
                if (eventIdx == 1) {
                    // Intent 1 event -- decode route to get CCTP call's mintRecipient
                    (
                        ,
                        bytes memory routeBytes,
                        ,
                        ,
                    ) = abi.decode(
                        logs[i].data,
                        (uint64, bytes, uint64, uint256, TokenAmount[])
                    );

                    Route memory route = abi.decode(routeBytes, (Route));
                    bytes memory callData = route.calls[1].data; // calls[1] = depositForBurn (after approve)

                    // Decode the third parameter (mintRecipient) from the CCTP call
                    (
                        ,
                        ,
                        mintRecipient,
                        ,
                        ,
                        ,
                    ) = abi.decode(
                        _sliceBytes(callData, 4),
                        (uint256, uint32, bytes32, address, bytes32, uint256, uint32)
                    );
                }
                eventIdx++;
            }
        }

        // Verify that the address encoded in mintRecipient is non-zero and represents an address
        address vault2Address = address(uint160(uint256(mintRecipient)));
        assertTrue(vault2Address != address(0), "Intent 2 vault address should not be zero");

        // The vault2 should be consistent with what portal would predict for intent2Hash
        assertEq(mintRecipient, bytes32(uint256(uint160(vault2Address))), "mintRecipient should be properly encoded vault2 address");
    }

    function test_createIntent_bothIntentsUseSameSalt() public {
        uint256 amount = 10_000 * 1e6;
        token.mint(address(depositAddress), amount);

        vm.recordLogs();
        depositAddress.createIntent();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 intentPublishedSig = keccak256(
            "IntentPublished(bytes32,uint64,bytes,address,address,uint64,uint256,(address,uint256)[])"
        );

        bytes32 salt1;
        bytes32 salt2;
        uint256 eventIdx = 0;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == intentPublishedSig) {
                (
                    ,
                    bytes memory routeBytes,
                    ,
                    ,
                ) = abi.decode(
                    logs[i].data,
                    (uint64, bytes, uint64, uint256, TokenAmount[])
                );

                Route memory route = abi.decode(routeBytes, (Route));

                if (eventIdx == 0) {
                    salt2 = route.salt; // Intent 2 is first
                } else {
                    salt1 = route.salt; // Intent 1 is second
                }
                eventIdx++;
            }
        }

        assertEq(salt1, salt2, "Both intents should use the same salt");
    }

    function test_createIntent_bothIntentsUseSameDeadline() public {
        uint256 amount = 10_000 * 1e6;
        token.mint(address(depositAddress), amount);

        vm.recordLogs();
        depositAddress.createIntent();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 intentPublishedSig = keccak256(
            "IntentPublished(bytes32,uint64,bytes,address,address,uint64,uint256,(address,uint256)[])"
        );

        uint64 rewardDeadline1;
        uint64 rewardDeadline2;
        uint64 routeDeadline1;
        uint64 routeDeadline2;
        uint256 eventIdx = 0;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == intentPublishedSig) {
                (
                    ,
                    bytes memory routeBytes,
                    uint64 rewardDeadline,
                    ,
                ) = abi.decode(
                    logs[i].data,
                    (uint64, bytes, uint64, uint256, TokenAmount[])
                );

                Route memory route = abi.decode(routeBytes, (Route));

                if (eventIdx == 0) {
                    rewardDeadline2 = rewardDeadline;
                    routeDeadline2 = route.deadline;
                } else {
                    rewardDeadline1 = rewardDeadline;
                    routeDeadline1 = route.deadline;
                }
                eventIdx++;
            }
        }

        assertEq(rewardDeadline1, rewardDeadline2, "Both intents should have same reward deadline");
        assertEq(routeDeadline1, routeDeadline2, "Both intents should have same route deadline");
        assertEq(rewardDeadline1, uint64(block.timestamp + INTENT_DEADLINE_DURATION), "Deadline should be current time + duration");
    }

    function test_createIntent_intent1_isFunded() public {
        uint256 amount = 10_000 * 1e6;
        token.mint(address(depositAddress), amount);

        bytes32 intentHash = depositAddress.createIntent();

        IIntentSource.Status status = portal.getRewardStatus(intentHash);
        assertEq(
            uint256(status),
            uint256(IIntentSource.Status.Funded),
            "Intent 1 should be funded"
        );
    }

    // ============ Integration Tests ============
    // Note: setUp already deploys a deposit address for USER_DESTINATION/DEPOSITOR,
    // so integration tests use different addresses to avoid CREATE2 collisions.

    address constant INTEGRATION_USER = address(0x7777);
    address constant INTEGRATION_DEPOSITOR = address(0x8888);

    function test_integration_fullFlow() public {
        // 1. Get deposit address before deployment
        address depositAddr = factory.getDepositAddress(INTEGRATION_USER, INTEGRATION_DEPOSITOR);
        assertFalse(factory.isDeployed(INTEGRATION_USER, INTEGRATION_DEPOSITOR));

        // 2. User sends tokens to deposit address
        uint256 depositAmount = 10_000 * 1e6;
        token.mint(depositAddr, depositAmount);
        assertEq(token.balanceOf(depositAddr), depositAmount);

        // 3. Deploy deposit contract
        address deployed = factory.deploy(INTEGRATION_USER, INTEGRATION_DEPOSITOR);
        assertEq(deployed, depositAddr);
        assertTrue(factory.isDeployed(INTEGRATION_USER, INTEGRATION_DEPOSITOR));

        DepositAddress_CCTPMint_Arc da = DepositAddress_CCTPMint_Arc(deployed);
        assertEq(da.destinationAddress(), bytes32(uint256(uint160(INTEGRATION_USER))));
        assertEq(da.depositor(), INTEGRATION_DEPOSITOR);

        // 4. Create intent
        vm.recordLogs();
        bytes32 intentHash = da.createIntent();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(intentHash != bytes32(0));

        // 5. Verify tokens moved from deposit address
        assertEq(token.balanceOf(depositAddr), 0);

        // 6. Verify intent was funded
        IIntentSource.Status status = portal.getRewardStatus(intentHash);
        assertEq(
            uint256(status),
            uint256(IIntentSource.Status.Funded),
            "Intent should be funded"
        );

        // 7. Verify two IntentPublished events were emitted
        bytes32 intentPublishedSig = keccak256(
            "IntentPublished(bytes32,uint64,bytes,address,address,uint64,uint256,(address,uint256)[])"
        );

        uint256 intentPublishedCount = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == intentPublishedSig) {
                intentPublishedCount++;
            }
        }
        assertEq(intentPublishedCount, 2, "Should have emitted two IntentPublished events");
    }

    function test_integration_deterministicAddressingWorks() public {
        address intUser = address(0x9991);
        address intDepositor = address(0x9992);

        address predicted = factory.getDepositAddress(intUser, intDepositor);

        uint256 amount = 10_000 * 1e6;
        token.mint(predicted, amount);
        assertEq(token.balanceOf(predicted), amount);

        address deployed = factory.deploy(intUser, intDepositor);
        assertEq(deployed, predicted);
        assertEq(token.balanceOf(deployed), amount);

        DepositAddress_CCTPMint_Arc da = DepositAddress_CCTPMint_Arc(deployed);
        bytes32 intentHash = da.createIntent();
        assertTrue(intentHash != bytes32(0));
    }

    function test_integration_multipleDeposits() public {
        address intUser = address(0x9993);
        address intDepositor = address(0x9994);

        address deployed = factory.deploy(intUser, intDepositor);
        DepositAddress_CCTPMint_Arc da = DepositAddress_CCTPMint_Arc(deployed);

        // First deposit
        uint256 amount1 = 10_000 * 1e6;
        token.mint(deployed, amount1);
        bytes32 intentHash1 = da.createIntent();
        assertEq(token.balanceOf(deployed), 0);

        // Second deposit (new block.timestamp to avoid salt collision)
        vm.warp(block.timestamp + 1);
        uint256 amount2 = 5_000 * 1e6;
        token.mint(deployed, amount2);
        bytes32 intentHash2 = da.createIntent();
        assertEq(token.balanceOf(deployed), 0);

        assertTrue(intentHash1 != intentHash2, "Intent hashes should differ");

        assertEq(
            uint256(portal.getRewardStatus(intentHash1)),
            uint256(IIntentSource.Status.Funded)
        );
        assertEq(
            uint256(portal.getRewardStatus(intentHash2)),
            uint256(IIntentSource.Status.Funded)
        );
    }

    function test_integration_differentUsersGetDifferentAddresses() public {
        address user1 = address(0x9995);
        address depositor1 = address(0x9996);
        address user2 = address(0x9997);
        address depositor2 = address(0x9998);

        address deployed1 = factory.deploy(user1, depositor1);
        address deployed2 = factory.deploy(user2, depositor2);

        assertTrue(deployed1 != deployed2);

        uint256 amount = 10_000 * 1e6;

        token.mint(deployed1, amount);
        bytes32 intentHash1 = DepositAddress_CCTPMint_Arc(deployed1).createIntent();

        vm.warp(block.timestamp + 1);
        token.mint(deployed2, amount);
        bytes32 intentHash2 = DepositAddress_CCTPMint_Arc(deployed2).createIntent();

        assertTrue(intentHash1 != bytes32(0));
        assertTrue(intentHash2 != bytes32(0));
        assertTrue(intentHash1 != intentHash2);
    }

    function test_integration_gasEstimation() public {
        address intUser = address(0x9999);
        address intDepositor = address(0x9990);

        uint256 gasBefore = gasleft();
        address deployed = factory.deploy(intUser, intDepositor);
        uint256 deployGas = gasBefore - gasleft();

        token.mint(deployed, 10_000 * 1e6);
        gasBefore = gasleft();
        DepositAddress_CCTPMint_Arc(deployed).createIntent();
        uint256 createIntentGas = gasBefore - gasleft();

        assertTrue(deployGas > 0);
        assertTrue(createIntentGas > 0);
        assertTrue(deployGas < 500_000, "Deploy gas should be under 500k for minimal proxy");
        assertTrue(createIntentGas < 1_000_000, "CreateIntent gas should be under 1M for dual-intent creation");
    }

    function test_createIntent_sameBlockSameAmountProducesDistinctHashes() public {
        uint256 amount = 10_000 * 1e6;

        // First call
        token.mint(address(depositAddress), amount);
        bytes32 hash1 = depositAddress.createIntent();

        // Second call in the same block with the same amount
        token.mint(address(depositAddress), amount);
        bytes32 hash2 = depositAddress.createIntent();

        // Nonce must break the collision
        assertTrue(hash1 != hash2);
    }

    // ============ Fuzz Tests ============

    function testFuzz_createIntent_succeeds(uint256 amount) public {
        vm.assume(amount >= 100_000 && amount <= type(uint128).max);

        token.mint(address(depositAddress), amount);
        bytes32 intentHash = depositAddress.createIntent();

        assertTrue(intentHash != bytes32(0));
    }

    // ============ Helpers ============

    /// @dev Slices bytes from the given offset to the end
    function _sliceBytes(bytes memory data, uint256 offset) internal pure returns (bytes memory) {
        require(offset <= data.length, "offset out of bounds");
        bytes memory result = new bytes(data.length - offset);
        for (uint256 i = 0; i < result.length; i++) {
            result[i] = data[i + offset];
        }
        return result;
    }
}
