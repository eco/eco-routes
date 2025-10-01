// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library GenericStruct {
    struct Struct {
        bytes32 typeHash;
        Chunk[] chunks;
    }

    struct Primitive {
        bool isDynamic;
        bytes data;
    }

    struct Array {
        bool isDynamic;
        Chunk[] data;
    }

    struct Chunk {
        Primitive[] primitives;
        Struct[] structs;
        Array[] arrays;
    }

    function structHash(Struct memory s) internal pure returns (bytes32) {
        bytes memory bz = abi.encodePacked(s.typeHash);
        uint256 chunksLen = s.chunks.length;

        for (uint256 i = 0; i < chunksLen; i++) {
            bz = abi.encodePacked(bz, _encodeEip712(s.chunks[i]));
        }

        return keccak256(bz);
    }

    function abiEncode(Struct memory s) internal pure returns (bytes memory) {
        return abi.encodePacked(abi.encode(uint256(32)), _abiEncode(s));
    }

    function _encodeEip712(
        Chunk memory chunk
    ) private pure returns (bytes memory) {
        bytes memory bz;

        uint256 primitiveLen = chunk.primitives.length;
        for (uint256 i = 0; i < primitiveLen; i++) {
            Primitive memory p = chunk.primitives[i];

            bz = p.isDynamic
                ? abi.encodePacked(bz, keccak256(p.data))
                : abi.encodePacked(bz, p.data);
        }

        uint256 structLen = chunk.structs.length;
        for (uint256 i = 0; i < structLen; i++) {
            bz = abi.encodePacked(bz, structHash(chunk.structs[i]));
        }

        uint256 arraysLen = chunk.arrays.length;
        for (uint256 i = 0; i < arraysLen; i++) {
            bz = abi.encodePacked(bz, _encodeEip712(chunk.arrays[i]));
        }

        return bz;
    }

    function _encodeEip712(Array memory array) private pure returns (bytes32) {
        bytes memory bz;
        uint256 arrayLen = array.data.length;

        for (uint256 i = 0; i < arrayLen; i++) {
            bz = abi.encodePacked(bz, _encodeEip712(array.data[i]));
        }

        return keccak256(bz);
    }

    function _abiEncode(Struct memory s) private pure returns (bytes memory) {
        uint256 fieldCount = 0;
        uint256 chunksLen = s.chunks.length;

        for (uint256 i = 0; i < chunksLen; i++) {
            fieldCount += s.chunks[i].primitives.length;
            fieldCount += s.chunks[i].structs.length;
            fieldCount += s.chunks[i].arrays.length;
        }

        bytes[] memory headParts = new bytes[](fieldCount);
        bytes[] memory tailParts = new bytes[](fieldCount);
        bool[] memory hasTail = new bool[](fieldCount);

        uint256 fieldIndex = 0;

        for (uint256 i = 0; i < chunksLen; i++) {
            fieldIndex = _encodeChunkFields(
                s.chunks[i],
                headParts,
                tailParts,
                hasTail,
                fieldIndex
            );
        }

        return _buildHeadTail(headParts, tailParts, hasTail, fieldCount);
    }

    function _abiEncode(
        Array memory array
    ) private pure returns (bytes memory) {
        uint256 arrayLen = array.data.length;
        bytes memory lengthPrefix = array.isDynamic
            ? abi.encode(arrayLen)
            : bytes("");

        bytes[] memory elements = new bytes[](arrayLen);
        bool[] memory isDynamic = new bool[](arrayLen);

        for (uint256 i = 0; i < arrayLen; i++) {
            Chunk memory chunk = array.data[i];

            uint256 totalItems = chunk.primitives.length +
                chunk.structs.length +
                chunk.arrays.length;

            if (totalItems != 1) {
                revert("Array element must have exactly one item");
            }

            if (chunk.primitives.length == 1) {
                Primitive memory p = chunk.primitives[0];

                if (p.isDynamic) {
                    elements[i] = abi.encodePacked(
                        abi.encode(p.data.length),
                        _padTo32(p.data)
                    );
                    isDynamic[i] = true;
                } else {
                    elements[i] = p.data;
                    isDynamic[i] = false;
                }
            } else if (chunk.structs.length == 1) {
                elements[i] = _abiEncode(chunk.structs[0]);
                isDynamic[i] = _isDynamic(chunk.structs[0]);
            } else {
                elements[i] = _abiEncode(chunk.arrays[0]);
                isDynamic[i] = _isDynamic(chunk.arrays[0]);
            }
        }

        uint256 headSize = 0;
        for (uint256 i = 0; i < arrayLen; i++) {
            headSize += isDynamic[i] ? 32 : elements[i].length;
        }

        bytes memory head;
        bytes memory tail;
        uint256 currentTailOffset = headSize;

        for (uint256 i = 0; i < arrayLen; i++) {
            if (isDynamic[i]) {
                head = abi.encodePacked(head, abi.encode(currentTailOffset));
                tail = abi.encodePacked(tail, elements[i]);
                currentTailOffset += elements[i].length;
            } else {
                head = abi.encodePacked(head, elements[i]);
            }
        }

        return abi.encodePacked(lengthPrefix, head, tail);
    }

    function _abiEncode(
        Chunk memory chunk
    ) private pure returns (bytes memory) {
        uint256 totalFields = chunk.primitives.length +
            chunk.structs.length +
            chunk.arrays.length;

        bytes[] memory headParts = new bytes[](totalFields);
        bytes[] memory tailParts = new bytes[](totalFields);
        bool[] memory hasTail = new bool[](totalFields);

        _encodeChunkFields(chunk, headParts, tailParts, hasTail, 0);

        return _buildHeadTail(headParts, tailParts, hasTail, totalFields);
    }

    function _encodeChunkFields(
        Chunk memory chunk,
        bytes[] memory headParts,
        bytes[] memory tailParts,
        bool[] memory hasTail,
        uint256 startIndex
    ) private pure returns (uint256) {
        uint256 fieldIndex = startIndex;

        uint256 primitivesLen = chunk.primitives.length;
        for (uint256 i = 0; i < primitivesLen; i++) {
            if (chunk.primitives[i].isDynamic) {
                tailParts[fieldIndex] = abi.encodePacked(
                    abi.encode(chunk.primitives[i].data.length),
                    _padTo32(chunk.primitives[i].data)
                );
                hasTail[fieldIndex] = true;
            } else {
                headParts[fieldIndex] = chunk.primitives[i].data;
            }

            fieldIndex++;
        }

        uint256 structsLen = chunk.structs.length;
        for (uint256 i = 0; i < structsLen; i++) {
            bytes memory structEncoded = _abiEncode(chunk.structs[i]);

            if (_isDynamic(chunk.structs[i])) {
                tailParts[fieldIndex] = structEncoded;
                hasTail[fieldIndex] = true;
            } else {
                headParts[fieldIndex] = structEncoded;
            }

            fieldIndex++;
        }

        uint256 arraysLen = chunk.arrays.length;
        for (uint256 i = 0; i < arraysLen; i++) {
            bytes memory arrayEncoded = _abiEncode(chunk.arrays[i]);

            if (_isDynamic(chunk.arrays[i])) {
                tailParts[fieldIndex] = arrayEncoded;
                hasTail[fieldIndex] = true;
            } else {
                headParts[fieldIndex] = arrayEncoded;
            }

            fieldIndex++;
        }

        return fieldIndex;
    }

    function _buildHeadTail(
        bytes[] memory headParts,
        bytes[] memory tailParts,
        bool[] memory hasTail,
        uint256 fieldCount
    ) private pure returns (bytes memory) {
        uint256 tailOffset = 0;
        for (uint256 i = 0; i < fieldCount; i++) {
            tailOffset += hasTail[i] ? 32 : headParts[i].length;
        }

        bytes memory head;
        bytes memory tail;

        for (uint256 i = 0; i < fieldCount; i++) {
            if (!hasTail[i]) {
                head = abi.encodePacked(head, headParts[i]);
                continue;
            }

            bytes memory tailPart = tailParts[i];
            head = abi.encodePacked(head, abi.encode(tailOffset));
            tail = abi.encodePacked(tail, tailPart);
            tailOffset += tailPart.length;
        }

        return abi.encodePacked(head, tail);
    }

    function _padTo32(bytes memory data) private pure returns (bytes memory) {
        uint256 len = data.length;
        uint256 paddedLen = ((len + 31) / 32) * 32;

        if (len == paddedLen) {
            return data;
        }

        return abi.encodePacked(data, new bytes(paddedLen - len));
    }

    function _isDynamic(Chunk memory chunk) private pure returns (bool) {
        uint256 primitivesLen = chunk.primitives.length;
        for (uint256 i = 0; i < primitivesLen; i++) {
            if (chunk.primitives[i].isDynamic) {
                return true;
            }
        }

        uint256 structsLen = chunk.structs.length;
        for (uint256 i = 0; i < structsLen; i++) {
            if (_isDynamic(chunk.structs[i])) {
                return true;
            }
        }

        uint256 arraysLen = chunk.arrays.length;
        for (uint256 i = 0; i < arraysLen; i++) {
            if (_isDynamic(chunk.arrays[i])) {
                return true;
            }
        }

        return false;
    }

    function _isDynamic(Array memory array) private pure returns (bool) {
        if (array.isDynamic) {
            return true;
        }

        uint256 dataLen = array.data.length;
        for (uint256 i = 0; i < dataLen; i++) {
            if (_isDynamic(array.data[i])) {
                return true;
            }
        }

        return false;
    }

    function _isDynamic(Struct memory s) private pure returns (bool) {
        uint256 chunksLen = s.chunks.length;
        for (uint256 i = 0; i < chunksLen; i++) {
            if (_isDynamic(s.chunks[i])) {
                return true;
            }
        }
        return false;
    }
}
