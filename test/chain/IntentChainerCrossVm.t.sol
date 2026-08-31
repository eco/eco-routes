/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

import {BaseTest} from "../BaseTest.sol";
import {IntentChainer} from "../../contracts/chain/IntentChainer.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {Reward, TokenAmount} from "../../contracts/types/Intent.sol";

/**
 * @title IntentChainerCrossVmTest
 * @notice Asserts this implementation against the fixture the SVM program asserts against.
 * @dev The two chainers owe each other agreement on the BYTES THEY PRODUCE, not on the shape of the input
 *      that produces them — the EVM `Order` is a Solidity struct, the SVM one is a Borsh account, and they
 *      are deliberately different. Nothing else in either suite checks the thing that actually has to hold.
 *
 *      A transform mismatch, an endianness flip, or ceil landing on the wrong side of a division would each
 *      pass every same-side test and still disagree across the boundary, surfacing in production as a solver
 *      delivering the wrong amount on a live lane.
 *
 *      `testdata/cross-vm-vectors.json` is the same file checked into eco-routes-svm at
 *      `programs/intent-chainer/testdata/`. Keep them identical. To add a vector, produce it on one side and
 *      confirm the other reproduces it before committing.
 */
contract IntentChainerCrossVmTest is BaseTest {
    IntentChainer internal chainer;

    string internal constant VECTORS =
        "test/chain/testdata/cross-vm-vectors.json";
    uint64 internal constant DEST_CHAIN = 1399811150;

    function setUp() public override {
        super.setUp();

        chainer = new IntentChainer();
    }

    /**
     * @notice Every vector in the shared file reproduces byte-for-byte.
     * @dev Drives the real `chain` entry point rather than an internal helper, so the assertion covers the
     *      splice, the scale and the published bytes together — the same surface the SVM side asserts.
     */
    function test_crossVm_everyVectorReproducesByteForByte() public {
        string memory json = vm.readFile(VECTORS);

        // Probed rather than read from a wildcard: a single-element `.vectors[*].name` flattens to a scalar
        // and fails to parse as an array, so counting that way would break on a one-vector fixture.
        uint256 count;
        while (
            vm.keyExistsJson(
                json,
                string.concat(".vectors[", vm.toString(count), "].name")
            )
        ) {
            ++count;
        }

        assertGt(count, 0, "fixture carries no vectors");

        for (uint256 i = 0; i < count; ++i) {
            _assertVector(json, i);
        }
    }

    function _assertVector(string memory json, uint256 index) internal {
        string memory base = string.concat(
            ".vectors[",
            vm.toString(index),
            "]"
        );
        string memory name = vm.parseJsonString(
            json,
            string.concat(base, ".name")
        );

        uint256 amountIn = vm.parseUint(
            vm.parseJsonString(json, string.concat(base, ".amount_in"))
        );
        uint256 scale = vm.parseUint(
            vm.parseJsonString(json, string.concat(base, ".scale"))
        );
        uint256 expectedOut = vm.parseUint(
            vm.parseJsonString(
                json,
                string.concat(base, ".expected_amount_out")
            )
        );
        bytes memory expectedRoute = _fromHex(
            vm.parseJsonString(json, string.concat(base, ".expected_route"))
        );

        IntentChainer.Order memory order = _order(json, base, scale);

        TestToken token = TestToken(order.token);
        token.mint(address(chainer), amountIn);

        vm.recordLogs();
        (, , uint256 gotIn, uint256 gotOut) = chainer.chain(order);

        assertEq(gotIn, amountIn, string.concat(name, ": amount_in"));
        assertEq(gotOut, expectedOut, string.concat(name, ": amount_out"));
        assertEq(
            _publishedRoute(),
            expectedRoute,
            string.concat(name, ": route bytes")
        );
    }

    /// @notice Rebuild an order from a vector. Only segments, slots and scale come from the file — the
    ///         reward does not affect the route, so it is fixed here.
    function _order(
        string memory json,
        string memory base,
        uint256 scale
    ) internal view returns (IntentChainer.Order memory) {
        string[] memory rawSegments = vm.parseJsonStringArray(
            json,
            string.concat(base, ".segments")
        );
        bytes[] memory segments = new bytes[](rawSegments.length);
        for (uint256 i = 0; i < rawSegments.length; ++i) {
            segments[i] = _fromHex(rawSegments[i]);
        }

        uint256 slotCount;
        while (
            vm.keyExistsJson(
                json,
                string.concat(
                    base,
                    ".slots[",
                    vm.toString(slotCount),
                    "].width"
                )
            )
        ) {
            ++slotCount;
        }
        IntentChainer.Slot[] memory slots = new IntentChainer.Slot[](slotCount);
        for (uint256 i = 0; i < slotCount; ++i) {
            string memory slotBase = string.concat(
                base,
                ".slots[",
                vm.toString(i),
                "]"
            );
            slots[i] = IntentChainer.Slot({
                width: uint8(
                    vm.parseJsonUint(json, string.concat(slotBase, ".width"))
                ),
                littleEndian: vm.parseJsonBool(
                    json,
                    string.concat(slotBase, ".little_endian")
                )
            });
        }

        TokenAmount[] memory rewardTokens = new TokenAmount[](1);
        rewardTokens[0] = TokenAmount({token: address(tokenB), amount: 0});

        return
            IntentChainer.Order({
                portal: address(portal),
                token: address(tokenB),
                destination: DEST_CHAIN,
                segments: segments,
                slots: slots,
                reward: Reward({
                    deadline: uint64(block.timestamp + 7 days),
                    creator: creator,
                    prover: address(prover),
                    nativeAmount: 0,
                    tokens: rewardTokens
                }),
                scale: scale,
                minAmountIn: 0
            });
    }

    /// @notice The route bytes off the `IntentPublished` log the chain call just produced.
    function _publishedRoute() internal returns (bytes memory route) {
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] != IIntentSource.IntentPublished.selector) {
                continue;
            }

            (, route, , , ) = abi.decode(
                logs[i].data,
                (uint64, bytes, uint64, uint256, TokenAmount[])
            );
            return route;
        }

        revert("IntentPublished not emitted");
    }

    /// @notice Decode an unprefixed hex string. The fixture stores bytes bare so the same file parses
    ///         cleanly from Rust, where a `0x` prefix would need stripping instead.
    function _fromHex(
        string memory s
    ) internal pure returns (bytes memory out) {
        bytes memory raw = bytes(s);
        require(raw.length % 2 == 0, "odd-length hex");

        out = new bytes(raw.length / 2);
        for (uint256 i = 0; i < out.length; ++i) {
            out[i] = bytes1(
                (_nibble(raw[2 * i]) << 4) | _nibble(raw[2 * i + 1])
            );
        }
    }

    function _nibble(bytes1 c) internal pure returns (uint8) {
        uint8 v = uint8(c);

        if (v >= 48 && v <= 57) return v - 48; // 0-9
        if (v >= 97 && v <= 102) return v - 87; // a-f
        if (v >= 65 && v <= 70) return v - 55; // A-F

        revert("bad hex digit");
    }
}

interface TestToken {
    function mint(address to, uint256 amount) external;
}
