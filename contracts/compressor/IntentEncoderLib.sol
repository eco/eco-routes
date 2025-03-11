struct EncodedIntent {
    uint8 sourceChainIndex;
    uint8 destinationChainIndex;
    // Reward token
    uint8 rewardTokenIndex;
    uint48 rewardAmount;
    // Route token
    uint8 routeTokenIndex;
    uint48 routeAmount;
    // Expiry duration
    uint24 expiresIn;
    // Salt
    bytes8 salt;
}

struct EncodedFulfillment {
    uint8 sourceChainIndex;
    uint8 destinationChainIndex;
    // Reward token
    uint8 routeTokenIndex;
    uint48 routeAmount;
    // Prove type (INSTANT = 0, BATCH = 1)
    uint8 proveType;
    // Recipient
    address recipient;
}

library IntentPacking {
    function decodePublishPayload(
        bytes32 payload
    ) public pure returns (EncodedIntent memory) {
        return
            EncodedIntent({
                sourceChainIndex: uint8(payload[0]), // uint8
                destinationChainIndex: uint8(payload[1]), // uint8
                rewardTokenIndex: uint8(payload[2]), // uint8
                // Reads bytes 3 to 8 and converts them to uint48
                rewardAmount: uint48(_extractUint(payload, 3, 8)), // uint48
                routeTokenIndex: uint8(payload[9]), // uint8
                // Reads bytes 10 to 15 and converts them to uint48
                routeAmount: uint48(_extractUint(payload, 10, 15)), // uint48
                expiresIn: uint24(_extractUint(payload, 16, 18)), // uint24
                salt: bytes8(uint64(_extractUint(payload, 19, 26))) // bytes8
            });
    }

    function decodeFulfillPayload(
        bytes32 payload
    ) public pure returns (EncodedFulfillment memory) {
        return
            EncodedFulfillment({
                sourceChainIndex: uint8(payload[0]), // uint8
                destinationChainIndex: uint8(payload[1]), // uint8
                routeTokenIndex: uint8(payload[2]), // uint8
                // Reads bytes 10 to 15 and converts them to uint48
                routeAmount: uint48(_extractUint(payload, 3, 8)), // uint48
                proveType: uint8(payload[9]),
                recipient: address(uint160(_extractUint(payload, 10, 29))) // uint48
            });
    }

    function _extractUint(
        bytes32 data,
        uint8 start,
        uint8 end
    ) private pure returns (uint256) {
        require(start < end, "range has to be greater than zero");
        require(end <= 32, "Out of bounds");

        uint256 length = end - start + 1;
        uint256 result;
        for (uint8 i = 0; i < length; i++) {
            result |= uint256(uint8(data[start + i])) << ((length - 1 - i) * 8);
        }
        return result;
    }
}
