// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "../BaseTest.sol";
import {IntentChainer} from "../../contracts/chain/IntentChainer.sol";
import {IntentTemplate as T} from "../../contracts/chain/IntentTemplate.sol";
import {Call, Reward, Route, TokenAmount} from "../../contracts/types/Intent.sol";
import {TemplateFixtures as F} from "./TemplateFixtures.sol";
import {TemplateHarness} from "./IntentTemplate.t.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";

contract FeeOnPushToken is TestERC20 {
    address internal immutable feeSender;
    constructor(address sender) TestERC20("Fee on push", "FEE") {
        feeSender = sender;
    }
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        if (from == feeSender && to != address(0) && value > 0) {
            super._update(from, address(0), 1);
            super._update(from, to, value - 1);
        } else {
            super._update(from, to, value);
        }
    }
}

/// @dev CCTP is an external boundary: capture the exact burn arguments and consume the approved token.
contract CapturingBurn {
    bytes32 public recipient;
    uint256 public amount;
    function depositForBurn(
        uint256 value,
        uint32,
        bytes32 mintRecipient,
        address token
    ) external {
        require(IERC20(token).transferFrom(msg.sender, address(this), value));
        recipient = mintRecipient;
        amount = value;
    }
}

contract IntentChainerRemoteTest is BaseTest {
    IntentChainer internal chainer;
    CapturingBurn internal burn;
    TemplateHarness internal renderer;
    uint256 internal constant AMOUNT = 123456;
    bytes32 internal constant MARKER = bytes32(type(uint256).max);
    address internal constant REMOTE_PORTAL =
        0x95b1EB197B1F9c9035450A7D12722E397DE8F9eb;
    bytes32 internal constant INIT_HASH =
        keccak256("independent remote init code");

    function setUp() public override {
        super.setUp();
        chainer = new IntentChainer();
        burn = new CapturingBurn();
        renderer = new TemplateHarness();
    }

    function test_remoteRecipientIsRouteDataAndLocalVaultStillReceivesFunds()
        public
    {
        IntentChainer.Order memory order = _order();
        Route memory outer = _outerRoute(order);
        bytes32 outerRewardHash = keccak256("outer reward");
        bytes32 outerHash = _hash(
            uint64(block.chainid),
            abi.encode(outer),
            outerRewardHash
        );
        tokenB.mint(address(this), AMOUNT * 2);
        tokenB.approve(address(portal), AMOUNT * 2);
        portal.fulfill(
            outerHash,
            outer,
            outerRewardHash,
            bytes32(uint256(uint160(claimant)))
        );

        bytes32 remoteHash = _hash(
            480,
            abi.encode(AMOUNT),
            keccak256(abi.encode(_remoteReward(AMOUNT)))
        );
        bytes32 recipient = bytes32(
            uint256(
                uint160(
                    vm.computeCreate2Address(
                        remoteHash,
                        INIT_HASH,
                        REMOTE_PORTAL
                    )
                )
            )
        );
        Route memory childRoute = _bridgeRoute(AMOUNT, recipient);
        Reward memory childReward = _localReward(AMOUNT);
        bytes32 childRewardHash = keccak256(abi.encode(childReward));
        bytes32 childHash = _hash(
            uint64(block.chainid),
            abi.encode(childRoute),
            childRewardHash
        );
        address localVault = portal.intentVaultAddress(
            uint64(block.chainid),
            abi.encode(childRoute),
            childReward
        );

        assertEq(tokenB.balanceOf(localVault), AMOUNT);
        assertEq(tokenB.balanceOf(address(chainer)), 0);
        assertEq(
            tokenB.balanceOf(address(uint160(uint256(recipient)))),
            0,
            "remote address never used as a local payee"
        );
        assertEq(burn.amount(), 0, "chain does not burn");

        // Later, intent2's Executor consumes already-populated call data; no return-value splicing.
        portal.fulfill(
            childHash,
            childRoute,
            childRewardHash,
            bytes32(uint256(uint160(claimant)))
        );
        assertEq(burn.amount(), AMOUNT);
        assertEq(burn.recipient(), recipient);
        _addProof(childHash, uint96(block.chainid), claimant);
        uint256 before = tokenB.balanceOf(claimant);
        portal.withdraw(
            uint64(block.chainid),
            keccak256(abi.encode(childRoute)),
            childReward
        );
        assertEq(tokenB.balanceOf(claimant) - before, AMOUNT);
    }

    function test_changedRemoteConfigCannotExecuteOriginalParentIntent()
        public
    {
        IntentChainer.Order memory order = _order();
        bytes32 rewardHash = keccak256("outer reward");
        bytes32 committed = _hash(
            uint64(block.chainid),
            abi.encode(_outerRoute(order)),
            rewardHash
        );
        T.EvmConfig memory config = abi.decode(
            order.template.vaults[0].derivation.config,
            (T.EvmConfig)
        );
        config.portal = address(0xBAD);
        order.template.vaults[0].derivation.config = abi.encode(config);
        Route memory changed = _outerRoute(order);
        assertNotEq(
            committed,
            _hash(uint64(block.chainid), abi.encode(changed), rewardHash)
        );
        tokenB.mint(address(this), AMOUNT);
        tokenB.approve(address(portal), AMOUNT);
        vm.expectRevert();
        portal.fulfill(
            committed,
            changed,
            rewardHash,
            bytes32(uint256(uint160(claimant)))
        );
        assertEq(tokenB.balanceOf(address(this)), AMOUNT);
        assertEq(tokenB.balanceOf(address(chainer)), 0);
    }

    function test_outboundTransferFeeRevertsAtPushShortfall() public {
        IntentChainer.Order memory order = _order();
        FeeOnPushToken feeToken = new FeeOnPushToken(address(chainer));
        order.token = address(feeToken);
        order.reward.tokens[0].token = address(feeToken);
        bytes memory rendered = renderer.render(order.template, AMOUNT, AMOUNT);
        Reward memory completed = order.reward;
        completed.tokens[0].amount = AMOUNT;
        address vault = portal.intentVaultAddress(
            order.destination,
            rendered,
            completed
        );
        feeToken.mint(address(chainer), AMOUNT);
        vm.expectRevert(
            abi.encodeWithSelector(
                IntentChainer.PushShortfall.selector,
                vault,
                AMOUNT,
                AMOUNT - 1
            )
        );
        chainer.chain(order);
        assertEq(feeToken.balanceOf(address(chainer)), AMOUNT);
        assertEq(feeToken.balanceOf(vault), 0);
    }

    function test_settledLocalVaultRejectedEvenWithoutPublication() public {
        IntentChainer.Order memory order = _order();
        order.publish = false;
        tokenB.mint(address(chainer), AMOUNT);
        (bytes32 hash, , , ) = chainer.chain(order);
        _addProof(hash, uint96(order.destination), claimant);
        bytes memory rendered = renderer.render(order.template, AMOUNT, AMOUNT);
        portal.withdraw(
            order.destination,
            keccak256(rendered),
            _localReward(AMOUNT)
        );
        tokenB.mint(address(chainer), AMOUNT);
        vm.expectRevert(
            abi.encodeWithSelector(
                IntentChainer.IntentAlreadySettled.selector,
                hash,
                IIntentSource.Status.Withdrawn
            )
        );
        chainer.chain(order);
        assertEq(tokenB.balanceOf(address(chainer)), AMOUNT);
    }

    function test_solanaTypedConfigRendersFullWidthAtaFromDynamicBorshReward()
        public
    {
        string memory json = vm.readFile(
            "test/chain/testdata/solana-vault-vectors.json"
        );
        T.SolanaConfig memory config = T.SolanaConfig(
            vm.parseJsonBytes32(json, ".portal"),
            vm.parseJsonBytes32(json, ".tokenProgram"),
            vm.parseJsonBytes32(json, ".mint")
        );
        T.Program memory p;
        p.vaults = new T.Vault[](1);
        p.vaults[0].destination = 1000;
        p.vaults[0].route = _literal(hex"010203");
        // Borsh Reward: deadline u64, creator/prover pubkeys, native u64, vector len u32, mint, amount u64.
        bytes memory prefix = abi.encodePacked(
            hex"0094357700000000",
            bytes32(uint256(3)),
            bytes32(uint256(7)),
            uint64(0),
            hex"01000000",
            config.mint
        );
        p.vaults[0].reward.segments = new bytes[](2);
        p.vaults[0].reward.segments[0] = prefix;
        p.vaults[0].reward.items = new T.Item[](1);
        p.vaults[0].reward.items[0] = F.amount(8, true);
        p.vaults[0].derivation = T.VaultDerivation(
            T.VaultKind.SolanaAta,
            abi.encode(config)
        );
        p.route.segments = new bytes[](2);
        p.route.items = new T.Item[](1);
        p.route.items[0] = T.Item(T.ItemKind.Vault, abi.encode(uint256(0)));
        // This full-template expectation is independently generated by the SDK fixture generator.
        assertEq(
            renderer.render(p, 1000, 1000),
            abi.encode(vm.parseJsonBytes32(json, ".borsh1000.ata"))
        );
        assertEq(
            renderer.render(p, 1001, 1001),
            abi.encode(vm.parseJsonBytes32(json, ".borsh1001.ata"))
        );
        assertNotEq(
            renderer.render(p, 1000, 1000),
            renderer.render(p, 1001, 1001)
        );
        // Caller bump injection is not part of this schema and is rejected, not silently decoded away.
        p.vaults[0].derivation.config = bytes.concat(
            abi.encode(config),
            abi.encode(uint8(254), uint8(254))
        );
        vm.expectRevert(T.InvalidConfigEncoding.selector);
        renderer.render(p, 1000, 1000);
    }

    function _order() internal view returns (IntentChainer.Order memory order) {
        order.publish = true;
        order.portal = address(portal);
        order.token = address(tokenB);
        order.destination = uint64(block.chainid);
        order.reward = _localReward(0);
        order.scale = 1e18;
        order.template.vaults = new T.Vault[](1);
        T.Vault memory node;
        node.destination = 480;
        node.route.segments = new bytes[](2);
        node.route.items = new T.Item[](1);
        node.route.items[0] = F.amount(32, false);
        bytes memory encodedReward = abi.encode(_remoteReward(0));
        node.reward.segments = new bytes[](2);
        node.reward.segments[0] = _slice(
            encodedReward,
            0,
            encodedReward.length - 32
        );
        node.reward.items = new T.Item[](1);
        node.reward.items[0] = F.amount(32, false);
        node.derivation = T.VaultDerivation(
            T.VaultKind.EvmCreate2,
            abi.encode(
                T.EvmConfig(REMOTE_PORTAL, 0xff, address(0x1234), INIT_HASH)
            )
        );
        order.template.vaults[0] = node;
        bytes memory marked = abi.encode(_bridgeRoute(uint256(MARKER), MARKER));
        uint256[] memory positions = new uint256[](4);
        uint256 found;
        for (uint256 i; i + 32 <= marked.length; ++i) {
            bytes32 word;
            assembly ("memory-safe") {
                word := mload(add(add(marked, 32), i))
            }
            if (word == MARKER) {
                positions[found++] = i;
                i += 31;
            }
        }
        require(found == 4, "token, approval, burn amount, recipient markers");
        order.template.route.segments = new bytes[](5);
        order.template.route.items = new T.Item[](4);
        uint256 cursor;
        for (uint256 i; i < 4; ++i) {
            order.template.route.segments[i] = _slice(
                marked,
                cursor,
                positions[i] - cursor
            );
            cursor = positions[i] + 32;
            order.template.route.items[i] = i == 3
                ? T.Item(T.ItemKind.Vault, abi.encode(uint256(0)))
                : F.amount(32, false);
        }
        order.template.route.segments[4] = _slice(
            marked,
            cursor,
            marked.length - cursor
        );
    }
    function _outerRoute(
        IntentChainer.Order memory order
    ) internal view returns (Route memory r) {
        r.salt = keccak256("outer");
        r.deadline = uint64(block.timestamp + 1 days);
        r.portal = address(portal);
        r.tokens = new TokenAmount[](1);
        r.tokens[0] = TokenAmount(address(tokenB), AMOUNT);
        r.calls = new Call[](2);
        r.calls[0] = Call(
            address(tokenB),
            abi.encodeCall(IERC20.transfer, (address(chainer), AMOUNT)),
            0
        );
        r.calls[1] = Call(
            address(chainer),
            abi.encodeCall(IntentChainer.chain, (order)),
            0
        );
    }
    function _bridgeRoute(
        uint256 amount,
        bytes32 recipient
    ) internal view returns (Route memory r) {
        r.salt = keccak256("child");
        r.deadline = uint64(block.timestamp + 1 days);
        r.portal = address(portal);
        r.tokens = new TokenAmount[](1);
        r.tokens[0] = TokenAmount(address(tokenB), amount);
        r.calls = new Call[](2);
        r.calls[0] = Call(
            address(tokenB),
            abi.encodeCall(IERC20.approve, (address(burn), amount)),
            0
        );
        r.calls[1] = Call(
            address(burn),
            abi.encodeCall(
                CapturingBurn.depositForBurn,
                (amount, uint32(3), recipient, address(tokenB))
            ),
            0
        );
    }
    function _localReward(
        uint256 amount
    ) internal view returns (Reward memory r) {
        r.deadline = uint64(block.timestamp + 1 days);
        r.creator = creator;
        r.prover = address(prover);
        r.tokens = new TokenAmount[](1);
        r.tokens[0] = TokenAmount(address(tokenB), amount);
    }
    function _remoteReward(
        uint256 amount
    ) internal view returns (Reward memory r) {
        r = _localReward(amount);
        r.tokens[0].token = address(0xFACE);
    }
    function _literal(
        bytes memory data
    ) internal pure returns (T.Template memory t) {
        t.segments = new bytes[](1);
        t.segments[0] = data;
    }
    function _hash(
        uint64 destination,
        bytes memory route,
        bytes32 rewardHash
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(destination, keccak256(route), rewardHash)
            );
    }
    function _slice(
        bytes memory input,
        uint256 offset,
        uint256 length
    ) internal pure returns (bytes memory output) {
        output = new bytes(length);
        for (uint256 i; i < length; ++i) output[i] = input[offset + i];
    }
}
