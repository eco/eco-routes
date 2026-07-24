// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../BaseTest.sol";
import {IOriginSettler} from "../../contracts/interfaces/ERC7683/IOriginSettler.sol";
import {OnchainCrossChainOrder, GaslessCrossChainOrder, ResolvedCrossChainOrder, Output, FillInstruction, OrderData, ORDER_DATA_TYPEHASH} from "../../contracts/types/ERC7683.sol";
import {Reward, TokenAmount} from "../../contracts/types/Intent.sol";
import {Portal} from "../../contracts/Portal.sol";
import {OriginSettler} from "../../contracts/ERC7683/OriginSettler.sol";
import {MockERC1271Wallet} from "../../contracts/test/MockERC1271Wallet.sol";

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

    // ---------------------------------------------------------------------
    // openFor signature validation (real Portal path)
    //
    // These exercise OriginSettler._validateOrderSig via the real Portal,
    // which uses OpenZeppelin's SignatureChecker so both EOA (ECDSA) and
    // ERC-1271 contract-wallet signatures are accepted.
    // ---------------------------------------------------------------------

    /// @notice A single-owner ERC-1271 contract wallet (e.g. Safe) can use the
    ///         gasless openFor path when it returns the ERC-1271 magic value.
    function testOpenForErc1271WalletSignatureSucceeds() public {
        (address walletOwner, uint256 walletOwnerPk) = makeAddrAndKey(
            "erc1271Owner"
        );
        MockERC1271Wallet wallet = new MockERC1271Wallet(walletOwner);

        _fundAndApprovePortal(address(wallet));

        GaslessCrossChainOrder memory order = _buildGaslessOrder(
            address(wallet)
        );
        bytes memory signature = _signOrder(order, walletOwnerPk);

        vm.prank(otherPerson); // solver submits the user's signed order
        portal.openFor(order, signature, "");

        // Rewards were escrowed out of the wallet -> openFor succeeded.
        assertEq(tokenA.balanceOf(address(wallet)), 0);
        assertEq(tokenB.balanceOf(address(wallet)), 0);
    }

    /// @notice When the ERC-1271 wallet returns a non-magic value (signature
    ///         not produced by its owner), openFor reverts InvalidSignature.
    function testOpenForErc1271WalletInvalidSignatureReverts() public {
        (address walletOwner, ) = makeAddrAndKey("erc1271Owner2");
        (, uint256 wrongPk) = makeAddrAndKey("wrongSigner");
        MockERC1271Wallet wallet = new MockERC1271Wallet(walletOwner);

        _fundAndApprovePortal(address(wallet));

        GaslessCrossChainOrder memory order = _buildGaslessOrder(
            address(wallet)
        );
        // Signed by a key that is NOT the wallet owner.
        bytes memory signature = _signOrder(order, wrongPk);

        vm.expectRevert(IOriginSettler.InvalidSignature.selector);
        vm.prank(otherPerson);
        portal.openFor(order, signature, "");
    }

    /// @notice EOA signatures continue to work unchanged on the openFor path.
    function testOpenForEoaSignatureStillSucceeds() public {
        (address eoaUser, uint256 eoaPk) = makeAddrAndKey("eoaUser");

        _fundAndApprovePortal(eoaUser);

        GaslessCrossChainOrder memory order = _buildGaslessOrder(eoaUser);
        bytes memory signature = _signOrder(order, eoaPk);

        vm.prank(otherPerson);
        portal.openFor(order, signature, "");

        assertEq(tokenA.balanceOf(eoaUser), 0);
        assertEq(tokenB.balanceOf(eoaUser), 0);
    }

    /// @notice An EOA signature from the wrong key still reverts (no behavior
    ///         change for EOAs relative to the previous ECDSA equality check).
    function testOpenForEoaInvalidSignatureReverts() public {
        (address eoaUser, ) = makeAddrAndKey("eoaUser2");
        (, uint256 wrongPk) = makeAddrAndKey("wrongSigner2");

        _fundAndApprovePortal(eoaUser);

        GaslessCrossChainOrder memory order = _buildGaslessOrder(eoaUser);
        bytes memory signature = _signOrder(order, wrongPk);

        vm.expectRevert(IOriginSettler.InvalidSignature.selector);
        vm.prank(otherPerson);
        portal.openFor(order, signature, "");
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @notice Mints the reward tokens to `funder` and approves the Portal to
    ///         pull them during openFor's funding step.
    function _fundAndApprovePortal(address funder) internal {
        tokenA.mint(funder, MINT_AMOUNT);
        tokenB.mint(funder, MINT_AMOUNT * 2);
        vm.startPrank(funder);
        tokenA.approve(address(portal), MINT_AMOUNT);
        tokenB.approve(address(portal), MINT_AMOUNT * 2);
        vm.stopPrank();
    }

    /// @notice Builds a GaslessCrossChainOrder whose user is both the order
    ///         signer and the reward creator (funder), with a two-token
    ///         reward (tokenA, tokenB) and no native leg.
    function _buildGaslessOrder(
        address orderUser
    ) internal view returns (GaslessCrossChainOrder memory order) {
        TokenAmount[] memory rewardTokensMemory = new TokenAmount[](2);
        rewardTokensMemory[0] = TokenAmount({
            token: address(tokenA),
            amount: MINT_AMOUNT
        });
        rewardTokensMemory[1] = TokenAmount({
            token: address(tokenB),
            amount: MINT_AMOUNT * 2
        });

        Reward memory orderReward = Reward({
            deadline: uint64(expiry),
            creator: orderUser,
            prover: address(prover),
            nativeAmount: 0,
            tokens: rewardTokensMemory
        });

        OrderData memory od = OrderData({
            destination: CHAIN_ID,
            route: abi.encode(route),
            reward: orderReward,
            routePortal: bytes32(uint256(uint160(address(portal)))),
            routeDeadline: uint64(expiry),
            maxSpent: new Output[](0)
        });

        order = GaslessCrossChainOrder({
            originSettler: address(portal),
            user: orderUser,
            nonce: 1,
            originChainId: block.chainid,
            openDeadline: uint32(block.timestamp + 3600),
            fillDeadline: uint32(block.timestamp + 7200),
            orderDataType: ORDER_DATA_TYPEHASH,
            orderData: abi.encode(od)
        });
    }

    /// @notice Produces an EIP-712 signature over the gasless order digest.
    function _signOrder(
        GaslessCrossChainOrder memory order,
        uint256 pk
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
            abi.encodePacked(
                hex"1901",
                portal.domainSeparatorV4(),
                structHash
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
