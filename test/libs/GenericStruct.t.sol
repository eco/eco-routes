// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BaseTest} from "../BaseTest.sol";
import {GenericStruct} from "../../contracts/libs/GenericStruct.sol";
import "forge-std/Test.sol";

contract GenericStructTest is BaseTest {
    using GenericStruct for GenericStruct.Struct;

    struct Mail {
        Person from;
        Person to;
        string contents;
        string[] tags;
    }

    struct Person {
        string name;
        address wallet;
    }

    function setUp() public override {
        super.setUp();
    }

    // Mail memory _mail = Mail({
    //     from: Person({
    //         name: "Sammy",
    //         wallet: address(0x2020ae689ED3e017450280CEA110d0ef6E640Da4)
    //     }),
    //     to: Person({
    //         name: "Aria",
    //         wallet: address(0x90779545ffBeF2e2A2e897b3db7b1d36c05C9e70)
    //     }),
    //     contents: "Hello, Aria!",
    //     tags: ["tag1", "tag2"]
    // });
    function setupMail()
        internal
        pure
        returns (
            GenericStruct.Struct memory,
            GenericStruct.Struct memory,
            GenericStruct.Struct memory
        )
    {
        GenericStruct.Chunk[] memory chunks = new GenericStruct.Chunk[](2);

        GenericStruct.Struct memory from = GenericStruct.Struct({
            typeHash: keccak256("Person(string name,address wallet)"),
            chunks: new GenericStruct.Chunk[](1)
        });
        from.chunks[0].primitives = new GenericStruct.Primitive[](2);
        from.chunks[0].primitives[0] = GenericStruct.Primitive({
            isDynamic: true,
            data: abi.encodePacked("Sammy")
        });
        from.chunks[0].primitives[1] = GenericStruct.Primitive({
            isDynamic: false,
            data: abi.encode(
                address(0x2020ae689ED3e017450280CEA110d0ef6E640Da4)
            )
        });

        GenericStruct.Struct memory to = GenericStruct.Struct({
            typeHash: keccak256("Person(string name,address wallet)"),
            chunks: new GenericStruct.Chunk[](1)
        });
        to.chunks[0].primitives = new GenericStruct.Primitive[](2);
        to.chunks[0].primitives[0] = GenericStruct.Primitive({
            isDynamic: true,
            data: abi.encodePacked("Aria")
        });
        to.chunks[0].primitives[1] = GenericStruct.Primitive({
            isDynamic: false,
            data: abi.encode(
                address(0x90779545ffBeF2e2A2e897b3db7b1d36c05C9e70)
            )
        });

        GenericStruct.Primitive memory contents = GenericStruct.Primitive({
            isDynamic: true,
            data: abi.encodePacked("Hello, Aria!")
        });

        GenericStruct.Chunk[] memory tagChunks = new GenericStruct.Chunk[](2);
        tagChunks[0].primitives = new GenericStruct.Primitive[](1);
        tagChunks[0].primitives[0] = GenericStruct.Primitive({
            isDynamic: true,
            data: abi.encodePacked("tag1")
        });
        tagChunks[1].primitives = new GenericStruct.Primitive[](1);
        tagChunks[1].primitives[0] = GenericStruct.Primitive({
            isDynamic: true,
            data: abi.encodePacked("tag2")
        });

        GenericStruct.Array memory tags = GenericStruct.Array({
            isDynamic: true,
            data: tagChunks
        });

        chunks[0].structs = new GenericStruct.Struct[](2);
        chunks[0].structs[0] = from;
        chunks[0].structs[1] = to;
        chunks[1].primitives = new GenericStruct.Primitive[](1);
        chunks[1].primitives[0] = contents;
        chunks[1].arrays = new GenericStruct.Array[](1);
        chunks[1].arrays[0] = tags;

        GenericStruct.Struct memory mail = GenericStruct.Struct({
            typeHash: keccak256(
                "Mail(Person from,Person to,string contents,string[] tags)Person(string name,address wallet)"
            ),
            chunks: chunks
        });

        return (from, to, mail);
    }

    function testStructHash() public pure {
        (
            GenericStruct.Struct memory from,
            GenericStruct.Struct memory to,
            GenericStruct.Struct memory mail
        ) = setupMail();

        bytes32 structHash = from.structHash();
        console.log("From StructHash:");
        console.logBytes32(structHash);

        structHash = to.structHash();
        console.log("To StructHash:");
        console.logBytes32(structHash);

        structHash = mail.structHash();
        console.log("Mail StructHash:");
        console.logBytes32(structHash);
    }

    function testAbiEncode() public pure {
        (
            GenericStruct.Struct memory from,
            GenericStruct.Struct memory to,
            GenericStruct.Struct memory mail
        ) = setupMail();

        console.log("\nGenericStruct From ABI:");
        console.logBytes(from.abiEncode());

        console.log("\nGenericStruct To ABI:");
        console.logBytes(to.abiEncode());

        console.log("\nGenericStruct Mail ABI:");
        console.logBytes(mail.abiEncode());
    }

    struct TestStruct {
        string[][] nested;
    }

    struct TestFixed {
        string[3] names;
        uint256 value;
    }

    function testFixedArrayOfDynamic() public pure {
        TestFixed memory test = TestFixed({
            names: [string("alice"), string("bob"), string("charlie")],
            value: 42
        });

        bytes memory expected = abi.encode(test);
        console.log("\nFixed array of dynamic (string[3]):");
        console.logBytes(expected);
        console.log("Length:", expected.length);

        string[] memory dynamicNames = new string[](3);
        dynamicNames[0] = "alice";
        dynamicNames[1] = "bob";
        dynamicNames[2] = "charlie";

        bytes memory dynamicEncoded = abi.encode(dynamicNames, uint256(42));
        console.log("\nDynamic array (string[]):");
        console.logBytes(dynamicEncoded);
        console.log("Length:", dynamicEncoded.length);
    }

    function testNestedArrays() public pure {
        string[][] memory nestedStrings = new string[][](2);
        nestedStrings[0] = new string[](2);
        nestedStrings[0][0] = "a";
        nestedStrings[0][1] = "b";
        nestedStrings[1] = new string[](1);
        nestedStrings[1][0] = "c";

        GenericStruct.Chunk[] memory innerArray0 = new GenericStruct.Chunk[](2);
        innerArray0[0].primitives = new GenericStruct.Primitive[](1);
        innerArray0[0].primitives[0] = GenericStruct.Primitive({
            isDynamic: true,
            data: abi.encodePacked("a")
        });
        innerArray0[1].primitives = new GenericStruct.Primitive[](1);
        innerArray0[1].primitives[0] = GenericStruct.Primitive({
            isDynamic: true,
            data: abi.encodePacked("b")
        });

        GenericStruct.Chunk[] memory innerArray1 = new GenericStruct.Chunk[](1);
        innerArray1[0].primitives = new GenericStruct.Primitive[](1);
        innerArray1[0].primitives[0] = GenericStruct.Primitive({
            isDynamic: true,
            data: abi.encodePacked("c")
        });

        GenericStruct.Chunk[]
            memory outerArrayChunks = new GenericStruct.Chunk[](2);
        outerArrayChunks[0].arrays = new GenericStruct.Array[](1);
        outerArrayChunks[0].arrays[0] = GenericStruct.Array({
            isDynamic: true,
            data: innerArray0
        });
        outerArrayChunks[1].arrays = new GenericStruct.Array[](1);
        outerArrayChunks[1].arrays[0] = GenericStruct.Array({
            isDynamic: true,
            data: innerArray1
        });

        GenericStruct.Array memory nestedArray = GenericStruct.Array({
            isDynamic: true,
            data: outerArrayChunks
        });

        GenericStruct.Struct memory testStruct = GenericStruct.Struct({
            typeHash: keccak256("Test(string[][] nested)"),
            chunks: new GenericStruct.Chunk[](1)
        });
        testStruct.chunks[0].arrays = new GenericStruct.Array[](1);
        testStruct.chunks[0].arrays[0] = nestedArray;

        bytes memory encoded = testStruct.abiEncode();
        TestStruct memory wrapped = TestStruct({nested: nestedStrings});
        bytes memory expected = abi.encode(wrapped);

        assertEq(encoded, expected, "Nested arrays should match");
    }
}
