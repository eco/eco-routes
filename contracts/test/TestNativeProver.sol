pragma solidity ^0.8.26;

import {INativeProver, ProveScalarArgs} from "../interfaces/INativeProver.sol";

contract TestCrossL2ProverV2 is INativeProver {
    uint32[] public chainId;
    address[] public emittingContract;
    bytes[] public topics;
    bytes[] public data;

    constructor(uint32 _chainId, address _emittingContract, bytes memory _topics, bytes memory _data) {
        chainId.push(_chainId);
        emittingContract.push(_emittingContract);
        topics.push(_topics);
        data.push(_data);
    }

    function prove(
        ProveScalarArgs calldata _proveArgs,
        bytes calldata _rlpEncodedL1Header,
        bytes memory _rlpEncodedL2Header,
        bytes calldata _settledStateProof,
        bytes[] calldata _l2StorageProof,
        bytes calldata _rlpEncodedContractAccount,
        bytes[] calldata _l2AccountProof
    ) external view returns (uint256 chainId, address storingContract, bytes32 storageValue) {
        uint256 proofIndex = uint256(bytes32(_settledStateProof));
        return (_proveArgs.chainID, _proveArgs.contractAddr, _proveArgs.storageValue);
    }
}
