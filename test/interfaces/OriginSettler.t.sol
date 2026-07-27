// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../BaseTest.sol";
import {IOriginSettler} from "../../contracts/interfaces/ERC7683/IOriginSettler.sol";
import {OnchainCrossChainOrder, GaslessCrossChainOrder, ResolvedCrossChainOrder, Output, FillInstruction, OrderData, ORDER_DATA_TYPEHASH} from "../../contracts/types/ERC7683.sol";
import {Portal} from "../../contracts/Portal.sol";
import {OriginSettler} from "../../contracts/ERC7683/OriginSettler.sol";

// Simple concrete implementation for testing
contract TestOriginSettler is IOriginSettler {
    mapping(bytes32 => bool) public opened;

    function open(OnchainCrossChainOrder calldata order) external payable {
        bytes32 orderId = keccak256(abi.encode(order));
        opened[orderId] = true;
        ResolvedCrossChainOrder memory resolved;
        emit Open(orderId, resolved);
    }

    function openFor(
        GaslessCrossChainOrder calldata order,
        bytes calldata /* signature */,
        bytes calldata /* originFillerData */
    ) external payable {
        bytes32 orderId = keccak256(abi.encode(order));
        opened[orderId] = true;
        ResolvedCrossChainOrder memory resolved;
        emit Open(orderId, resolved);
    }

    function resolveFor(
        GaslessCrossChainOrder calldata order,
        bytes calldata /* originFillerData */
    ) external pure returns (ResolvedCrossChainOrder memory) {
        return
            ResolvedCrossChainOrder({
                user: order.user,
                originChainId: order.originChainId,
                openDeadline: order.openDeadline,
                fillDeadline: order.fillDeadline,
                orderId: keccak256(abi.encode(order)),
                maxSpent: new Output[](0),
                minReceived: new Output[](0),
                fillInstructions: new FillInstruction[](0)
            });
    }

    function resolve(
        OnchainCrossChainOrder calldata order
    ) external view returns (ResolvedCrossChainOrder memory) {
        return
            ResolvedCrossChainOrder({
                user: msg.sender,
                originChainId: block.chainid,
                openDeadline: 0,
                fillDeadline: order.fillDeadline,
                orderId: keccak256(abi.encode(order)),
                maxSpent: new Output[](0),
                minReceived: new Output[](0),
                fillInstructions: new FillInstruction[](0)
            });
    }
}

contract OriginSettlerTest is BaseTest {
    TestOriginSettler internal originSettler;

    address internal user;

    function setUp() public override {
        super.setUp();

        user = makeAddr("user");

        vm.prank(deployer);
        originSettler = new TestOriginSettler();

        _mintAndApprove(creator, MINT_AMOUNT);
        _mintAndApprove(user, MINT_AMOUNT);
        _fundUserNative(creator, 10 ether);
        _fundUserNative(user, 10 ether);
    }

    function testOpenOrder() public {
        OnchainCrossChainOrder memory order = OnchainCrossChainOrder({
            fillDeadline: uint32(block.timestamp + 3600),
            orderDataType: keccak256("test"),
            orderData: abi.encode(intent)
        });

        vm.prank(user);
        originSettler.open(order);

        bytes32 orderId = keccak256(abi.encode(order));
        assertTrue(originSettler.opened(orderId));
    }

    function testOpenOrderEmitsEvent() public {
        OnchainCrossChainOrder memory order = OnchainCrossChainOrder({
            fillDeadline: uint32(block.timestamp + 3600),
            orderDataType: keccak256("test"),
            orderData: abi.encode(intent)
        });

        bytes32 orderId = keccak256(abi.encode(order));

        _expectEmit();
        emit IOriginSettler.Open(
            orderId,
            ResolvedCrossChainOrder({
                user: address(0),
                originChainId: 0,
                openDeadline: 0,
                fillDeadline: 0,
                orderId: bytes32(0),
                maxSpent: new Output[](0),
                minReceived: new Output[](0),
                fillInstructions: new FillInstruction[](0)
            })
        );

        vm.prank(user);
        originSettler.open(order);
    }

    function testOpenOrderWithValue() public {
        OnchainCrossChainOrder memory order = OnchainCrossChainOrder({
            fillDeadline: uint32(block.timestamp + 3600),
            orderDataType: keccak256("test"),
            orderData: abi.encode(intent)
        });

        vm.prank(user);
        originSettler.open{value: 1 ether}(order);

        bytes32 orderId = keccak256(abi.encode(order));
        assertTrue(originSettler.opened(orderId));
    }

    function testOpenForGaslessOrder() public {
        GaslessCrossChainOrder memory order = GaslessCrossChainOrder({
            originSettler: address(originSettler),
            user: user,
            nonce: 1,
            originChainId: block.chainid,
            openDeadline: uint32(block.timestamp + 3600),
            fillDeadline: uint32(block.timestamp + 7200),
            orderDataType: keccak256("test"),
            orderData: abi.encode(intent)
        });

        vm.prank(user);
        originSettler.openFor(order, "", "");

        bytes32 orderId = keccak256(abi.encode(order));
        assertTrue(originSettler.opened(orderId));
    }

    /// @notice The gasless `openFor` must reject an order whose signer (order.user)
    ///         is not the reward creator, since refunds/recovery always pay
    ///         reward.creator. Exercises the real OriginSettler logic via Portal.
    function testOpenForRevertsWhenUserNotCreator() public {
        (address gaslessUser, uint256 gaslessUserPk) = makeAddrAndKey(
            "gaslessUser"
        );

        // reward.creator is `creator` (from BaseTest), deliberately != order.user
        OrderData memory orderData = OrderData({
            destination: CHAIN_ID,
            route: abi.encode(route),
            reward: reward,
            routePortal: bytes32(uint256(uint160(address(portal)))),
            routeDeadline: uint64(expiry),
            maxSpent: new Output[](0)
        });

        GaslessCrossChainOrder memory order = GaslessCrossChainOrder({
            originSettler: address(portal),
            user: gaslessUser,
            nonce: 1,
            originChainId: block.chainid,
            openDeadline: uint32(block.timestamp + 3600),
            fillDeadline: uint32(block.timestamp + 7200),
            orderDataType: ORDER_DATA_TYPEHASH,
            orderData: abi.encode(orderData)
        });

        bytes32 structHash = keccak256(
            abi.encode(
                portal.GASLESS_CROSSCHAIN_ORDER_TYPEHASH(),
                order.originSettler,
                order.user,
                order.nonce,
                order.originChainId,
                order.openDeadline,
                order.fillDeadline,
                order.orderDataType,
                keccak256(order.orderData)
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked(
                hex"1901",
                portal.domainSeparatorV4(),
                structHash
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(gaslessUserPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Signature is valid (signed by order.user) so it passes _validateOrderSig;
        // the binding check then fires because order.user != reward.creator.
        vm.expectRevert(
            abi.encodeWithSelector(
                IOriginSettler.InvalidCreatorBinding.selector,
                gaslessUser,
                creator
            )
        );
        vm.prank(otherPerson);
        portal.openFor(order, signature, "");
    }

    // ---------------------------------------------------------------------
    // Publish-event replay characterization (PAR-402)
    //
    // `Open` and `IntentPublished` are AT-LEAST-ONCE, not exactly-once. The
    // intent identity (`orderId` == `intentHash`) is a pure function of
    // (destination, routeHash, rewardHash); it deliberately does not include
    // `GaslessCrossChainOrder.nonce`, and publishing is idempotent by design so
    // that an already-escrowed intent can be re-announced without disturbing
    // the escrow. The tests below pin that contract so a future change cannot
    // silently turn re-announcement into a fund-moving or reverting operation.
    // Off-chain consumers must dedupe on `orderId`.
    // ---------------------------------------------------------------------

    /// @notice Builds a gasless order whose signer is `creator`, satisfying the
    ///         `order.user == reward.creator` binding enforced by `openFor`.
    function _buildGaslessOrder(
        uint256 nonce
    ) internal view returns (GaslessCrossChainOrder memory) {
        OrderData memory orderData = OrderData({
            destination: CHAIN_ID,
            route: abi.encode(route),
            reward: reward,
            routePortal: bytes32(uint256(uint160(address(portal)))),
            routeDeadline: uint64(expiry),
            maxSpent: new Output[](0)
        });

        return
            GaslessCrossChainOrder({
                originSettler: address(portal),
                user: creator,
                nonce: nonce,
                originChainId: block.chainid,
                openDeadline: uint32(block.timestamp + 3600),
                fillDeadline: uint32(block.timestamp + 7200),
                orderDataType: ORDER_DATA_TYPEHASH,
                orderData: abi.encode(orderData)
            });
    }

    function _signGaslessOrder(
        GaslessCrossChainOrder memory order,
        uint256 signerPk
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                portal.GASLESS_CROSSCHAIN_ORDER_TYPEHASH(),
                order.originSettler,
                order.user,
                order.nonce,
                order.originChainId,
                order.openDeadline,
                order.fillDeadline,
                order.orderDataType,
                keccak256(order.orderData)
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked(hex"1901", portal.domainSeparatorV4(), structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @notice Mints/approves enough that a *second* reward pull would succeed
    ///         if one were attempted, so "no second pull" is a real assertion
    ///         rather than an artifact of an exhausted balance or allowance.
    function _overfundCreator() internal {
        vm.startPrank(creator);
        tokenA.mint(creator, MINT_AMOUNT * 4);
        tokenB.mint(creator, MINT_AMOUNT * 4);
        tokenA.approve(address(portal), type(uint256).max);
        tokenB.approve(address(portal), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Counts `Open(bytes32,ResolvedCrossChainOrder)` records and returns
    ///      the last observed orderId (topic1).
    function _countOpenLogs()
        internal
        returns (uint256 count, bytes32 lastOrderId)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 openSig = IOriginSettler.Open.selector;

        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 1 && logs[i].topics[0] == openSig) {
                ++count;
                lastOrderId = logs[i].topics[1];
            }
        }
    }

    /// @notice (a) Replaying the *identical* gasless signature succeeds a second
    ///         time, emits a duplicate `Open` under the same orderId, and moves
    ///         no additional funds. `nonce` is signed but never consumed.
    function testOpenForReplayEmitsDuplicateOpenAndMovesNoFunds() public {
        (, uint256 creatorPk) = makeAddrAndKey("creator");
        _overfundCreator();

        GaslessCrossChainOrder memory order = _buildGaslessOrder(1);
        bytes memory signature = _signGaslessOrder(order, creatorPk);

        (bytes32 intentHash, , ) = intentSource.getIntentHash(
            CHAIN_ID,
            abi.encode(route),
            reward
        );
        address vault = intentSource.intentVaultAddress(intent);

        vm.recordLogs();
        vm.prank(otherPerson);
        portal.openFor(order, signature, "");
        (uint256 firstCount, bytes32 firstOrderId) = _countOpenLogs();

        assertEq(firstCount, 1, "first openFor should emit one Open");
        assertEq(
            firstOrderId,
            intentHash,
            "orderId must equal the derived intentHash"
        );
        assertEq(
            uint8(intentSource.getRewardStatus(intentHash)),
            uint8(IIntentSource.Status.Funded),
            "intent should be fully funded after first openFor"
        );

        uint256 creatorABefore = tokenA.balanceOf(creator);
        uint256 creatorBBefore = tokenB.balanceOf(creator);
        uint256 vaultABefore = tokenA.balanceOf(vault);
        uint256 vaultBBefore = tokenB.balanceOf(vault);

        // Replay: byte-identical order + byte-identical signature, different caller.
        vm.recordLogs();
        vm.prank(otherPerson);
        portal.openFor(order, signature, "");
        (uint256 replayCount, bytes32 replayOrderId) = _countOpenLogs();

        // The nonce is inside the EIP-712 digest but is never consumed on-chain,
        // so the same signature stays valid until openDeadline passes.
        assertEq(replayCount, 1, "replay emits a second, duplicate Open");
        assertEq(
            replayOrderId,
            firstOrderId,
            "duplicate Open carries the same orderId"
        );

        // ...but the escrow is untouched: onlyFundable short-circuits on Funded.
        assertEq(
            tokenA.balanceOf(creator),
            creatorABefore,
            "replay must not pull tokenA again"
        );
        assertEq(
            tokenB.balanceOf(creator),
            creatorBBefore,
            "replay must not pull tokenB again"
        );
        assertEq(
            tokenA.balanceOf(vault),
            vaultABefore,
            "vault tokenA unchanged by replay"
        );
        assertEq(
            tokenB.balanceOf(vault),
            vaultBBefore,
            "vault tokenB unchanged by replay"
        );
    }

    /// @notice (b) Two distinct signed orders differing only by `nonce` collapse
    ///         onto one orderId and one escrow, because `nonce` is not part of
    ///         the intent identity.
    function testOpenForDistinctNoncesCollapseToOneOrderIdAndOneEscrow()
        public
    {
        (, uint256 creatorPk) = makeAddrAndKey("creator");
        _overfundCreator();

        GaslessCrossChainOrder memory orderOne = _buildGaslessOrder(1);
        GaslessCrossChainOrder memory orderTwo = _buildGaslessOrder(2);

        bytes memory sigOne = _signGaslessOrder(orderOne, creatorPk);
        bytes memory sigTwo = _signGaslessOrder(orderTwo, creatorPk);

        // The two orders are genuinely different signed payloads.
        assertNotEq(
            keccak256(sigOne),
            keccak256(sigTwo),
            "differing nonces must produce differing signatures"
        );

        address vault = intentSource.intentVaultAddress(intent);

        vm.recordLogs();
        vm.prank(otherPerson);
        portal.openFor(orderOne, sigOne, "");
        (, bytes32 orderIdOne) = _countOpenLogs();

        uint256 vaultAAfterFirst = tokenA.balanceOf(vault);
        uint256 vaultBAfterFirst = tokenB.balanceOf(vault);

        vm.recordLogs();
        vm.prank(otherPerson);
        portal.openFor(orderTwo, sigTwo, "");
        (, bytes32 orderIdTwo) = _countOpenLogs();

        assertEq(
            orderIdTwo,
            orderIdOne,
            "orderId excludes nonce, so both orders share one identity"
        );
        assertEq(
            tokenA.balanceOf(vault),
            vaultAAfterFirst,
            "second nonce funds no second escrow (tokenA)"
        );
        assertEq(
            tokenB.balanceOf(vault),
            vaultBAfterFirst,
            "second nonce funds no second escrow (tokenB)"
        );
    }

    /// @notice Duplicate publish events are not specific to the gasless path:
    ///         `publish` is permissionless and has no deadline, so anyone can
    ///         re-emit `IntentPublished` for a funded intent forever. Consuming
    ///         a gasless nonce would therefore not make publish events unique.
    function testPublishIsPermissionlesslyRepeatableOnFundedIntent() public {
        _overfundCreator();

        vm.prank(creator);
        (bytes32 intentHash, ) = intentSource.publishAndFund(intent, false);

        assertEq(
            uint8(intentSource.getRewardStatus(intentHash)),
            uint8(IIntentSource.Status.Funded)
        );

        address vault = intentSource.intentVaultAddress(intent);
        uint256 vaultABefore = tokenA.balanceOf(vault);

        // Any address, no signature, no deadline.
        _expectEmit();
        emit IIntentSource.IntentPublished(
            intentHash,
            intent.destination,
            abi.encode(intent.route),
            reward.creator,
            reward.prover,
            reward.deadline,
            reward.nativeAmount,
            reward.tokens
        );
        vm.prank(otherPerson);
        intentSource.publish(intent);

        assertEq(
            tokenA.balanceOf(vault),
            vaultABefore,
            "re-publish must not touch the escrow"
        );
    }

    /// @notice The same holds for the non-gasless `open`: it takes no signature,
    ///         no nonce and no openDeadline, so once an intent is Funded any
    ///         address can re-emit `Open` under the same orderId indefinitely.
    ///         This is why nonce consumption in `openFor` would not make `Open`
    ///         exactly-once -- the duplicate-event surface is the permissionless
    ///         idempotent publish, not the gasless signature.
    function testOpenIsPermissionlesslyRepeatableOnFundedIntent() public {
        _overfundCreator();

        vm.prank(creator);
        (bytes32 intentHash, ) = intentSource.publishAndFund(intent, false);

        OrderData memory orderData = OrderData({
            destination: CHAIN_ID,
            route: abi.encode(route),
            reward: reward,
            routePortal: bytes32(uint256(uint160(address(portal)))),
            routeDeadline: uint64(expiry),
            maxSpent: new Output[](0)
        });
        OnchainCrossChainOrder memory order = OnchainCrossChainOrder({
            fillDeadline: uint32(block.timestamp + 3600),
            orderDataType: ORDER_DATA_TYPEHASH,
            orderData: abi.encode(orderData)
        });

        address vault = intentSource.intentVaultAddress(intent);
        uint256 vaultABefore = tokenA.balanceOf(vault);

        // `otherPerson` holds no reward tokens and gave no approval, yet the
        // call succeeds because onlyFundable short-circuits on Funded.
        vm.recordLogs();
        vm.prank(otherPerson);
        portal.open(order);
        (uint256 count, bytes32 orderId) = _countOpenLogs();

        assertEq(count, 1, "unsigned open re-emits Open on a funded intent");
        assertEq(orderId, intentHash, "same orderId as the original publish");
        assertEq(
            tokenA.balanceOf(vault),
            vaultABefore,
            "re-open must not touch the escrow"
        );
    }

    function testResolveOrder() public view {
        OnchainCrossChainOrder memory order = OnchainCrossChainOrder({
            fillDeadline: uint32(block.timestamp + 3600),
            orderDataType: keccak256("test"),
            orderData: abi.encode(intent)
        });

        ResolvedCrossChainOrder memory resolved = originSettler.resolve(order);

        assertEq(resolved.user, address(this));
        assertEq(resolved.originChainId, block.chainid);
        assertEq(resolved.fillDeadline, order.fillDeadline);
    }

    function testResolveForGaslessOrder() public view {
        GaslessCrossChainOrder memory order = GaslessCrossChainOrder({
            originSettler: address(originSettler),
            user: user,
            nonce: 1,
            originChainId: block.chainid,
            openDeadline: uint32(block.timestamp + 3600),
            fillDeadline: uint32(block.timestamp + 7200),
            orderDataType: keccak256("test"),
            orderData: abi.encode(intent)
        });

        ResolvedCrossChainOrder memory resolved = originSettler.resolveFor(
            order,
            ""
        );

        assertEq(resolved.user, order.user);
        assertEq(resolved.originChainId, order.originChainId);
        assertEq(resolved.fillDeadline, order.fillDeadline);
    }

    function testDomainSeparatorV4() public {
        // Test that the Portal's domainSeparatorV4 returns the correct EIP-712 domain separator
        bytes32 domainSeparator = portal.domainSeparatorV4();

        // Verify domain separator is not zero (basic sanity check)
        assertNotEq(domainSeparator, bytes32(0));

        // The domain separator should be deterministic for the same contract
        // Call it again to ensure consistency
        bytes32 domainSeparator2 = portal.domainSeparatorV4();
        assertEq(domainSeparator, domainSeparator2);

        // The domain separator should be unique to this contract instance
        // Deploy another Portal and verify they have different domain separators
        Portal portal2 = new Portal(address(0));
        bytes32 domainSeparator3 = portal2.domainSeparatorV4();

        // Domain separators should be different due to different contract addresses
        assertNotEq(domainSeparator, domainSeparator3);
    }

    function testDomainSeparatorV4Structure() public view {
        // Test that the domain separator follows EIP-712 structure
        bytes32 domainSeparator = portal.domainSeparatorV4();

        // Calculate expected domain separator manually
        bytes32 typeHash = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        bytes32 nameHash = keccak256(bytes("EcoPortal"));
        bytes32 versionHash = keccak256(bytes("1"));
        uint256 chainId = block.chainid;
        address verifyingContract = address(portal);

        bytes32 expectedDomainSeparator = keccak256(
            abi.encode(
                typeHash,
                nameHash,
                versionHash,
                chainId,
                verifyingContract
            )
        );

        // Verify the domain separator matches our expected calculation
        assertEq(domainSeparator, expectedDomainSeparator);
    }

    function testDomainSeparatorV4ChainDependency() public {
        // Test that domain separator is dependent on chain ID by deploying on different chains
        bytes32 domainSeparator1 = portal.domainSeparatorV4();

        // Deploy a new Portal on a different chain ID
        vm.chainId(999);
        Portal portalDifferentChain = new Portal(address(0));
        bytes32 domainSeparator2 = portalDifferentChain.domainSeparatorV4();

        // Domain separators should be different on different chains
        assertNotEq(domainSeparator1, domainSeparator2);

        // Deploy another Portal on the original chain
        vm.chainId(1);
        Portal portalSameChain = new Portal(address(0));
        bytes32 domainSeparator3 = portalSameChain.domainSeparatorV4();

        // Domain separator should be different from the first portal due to different addresses
        // but should follow the same calculation pattern for the same chain
        assertNotEq(domainSeparator1, domainSeparator3);
        assertNotEq(domainSeparator2, domainSeparator3);
    }
}
