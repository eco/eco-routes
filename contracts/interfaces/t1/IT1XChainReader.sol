// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

interface IT1XChainReader {
    struct ReadRequest {
        uint32 destinationDomain;
        address targetContract;
        uint64 minBlock;
        bytes callData;
    }

    error InvalidBatchIndex();
    error InvalidProof();
    error OnlyProver();
    error ZeroAddress();

    event Initialized(uint8 version);
    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );
    event ProofOfReadRootCommitted(uint256 batchIndex);
    event ReadRequested(
        bytes32 indexed requestId,
        uint32 indexed destinationDomain,
        address indexed targetContract,
        address requester,
        uint64 minBlock,
        bytes callData,
        uint256 nonce
    );

    function MESSENGER() external view returns (address);
    function commitProofOfReadRoot(
        uint256 batchIndex,
        bytes32 newRoot
    ) external;
    function nextBatchIndex() external view returns (uint256);
    function nonce() external view returns (uint256);
    function owner() external view returns (address);
    function proofOfReadRoots(
        uint256 batchIndex
    ) external view returns (bytes32 root);
    function prover() external view returns (address);
    function renounceOwnership() external;
    function requestRead(
        ReadRequest memory request
    ) external returns (bytes32 requestId);
    function transferOwnership(address newOwner) external;
    function verifyProofOfRead(
        bytes memory encodedProofOfRead
    ) external view returns (bytes32, bytes memory);
}
