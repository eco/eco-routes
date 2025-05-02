pragma solidity ^0.8.26;

import {INativeProver, ProveScalarArgs} from "../interfaces/INativeProver.sol";

contract TestNativeProver is INativeProver {
    bytes32 public allowedStorageValue;

    error invalidStorageSlot();
    error invalidStorageValue();

    function setAllowableStorage(bytes32 _storageValue) external {
        allowedStorageValue = _storageValue;
    }

    function prove(
        ProveScalarArgs memory _proveArgs,
        bytes memory _rlpEncodedL1Header,
        bytes memory _rlpEncodedL2Header,
        bytes memory _settledStateProof,
        bytes[] memory _l2StorageProof,
        bytes memory _rlpEncodedContractAccount,
        bytes[] memory _l2AccountProof
    )
        external
        view
        returns (uint256 chainId, address storingContract, bytes32 storageValue)
    {
        if (_proveArgs.storageValue != allowedStorageValue) {
            revert invalidStorageValue();
        }
        uint256 proofIndex = uint256(bytes32(_settledStateProof));
        return (
            _proveArgs.chainID,
            _proveArgs.contractAddr,
            _proveArgs.storageValue
        );
    }
}
