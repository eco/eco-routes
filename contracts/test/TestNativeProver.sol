pragma solidity ^0.8.26;

import {INativeProver, ProveScalarArgs} from "../interfaces/INativeProver.sol";

contract TestNativeProver is INativeProver {
    constructor() {}

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
