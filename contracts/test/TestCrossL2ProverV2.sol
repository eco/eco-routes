pragma solidity ^0.8.26;

contract TestCrossL2ProverV2 {
    uint32[] public chainId;
    address[] public emittingContract;
    bytes[] public topics;
    bytes[] public data;

    constructor(
        uint32 _chainId,
        address _emittingContract,
        bytes memory _topics,
        bytes memory _data
    ) {
        chainId.push(_chainId);
        emittingContract.push(_emittingContract);
        topics.push(_topics);
        data.push(_data);
    }

    function setAll(
        uint32 _chainId,
        address _emittingContract,
        bytes memory _topics,
        bytes memory _data
    ) public {
        chainId.push(_chainId);
        emittingContract.push(_emittingContract);
        topics.push(_topics);
        data.push(_data);
    }

    function setChainId(uint32 _chainId) public {
        chainId.push(_chainId);
    }

    function setEmittingContract(address _emittingContract) public {
        emittingContract.push(_emittingContract);
    }

    function setTopics(bytes memory _topics) public {
        topics.push(_topics);
    }

    function setData(bytes memory _data) public {
        data.push(_data);
    }

    function validateEvent(
        bytes calldata proof
    ) public view returns (uint32, address, bytes memory, bytes memory) {
        uint256 proofIndex = uint256(bytes32(proof));
        return (
            chainId[proofIndex],
            emittingContract[proofIndex],
            topics[proofIndex],
            data[proofIndex]
        );
    }
}
