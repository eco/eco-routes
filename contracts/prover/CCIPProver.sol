// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MessageBridgeProver} from "./MessageBridgeProver.sol";
import {Semver} from "../libs/Semver.sol";
import {AddressConverter} from "../libs/AddressConverter.sol";
import {
    IRouterClient
} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {
    IAny2EVMMessageReceiver
} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {
    Client
} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";

/**
 * @title CCIPProver
 * @notice Prover implementation using Chainlink CCIP (Cross-Chain Interoperability Protocol)
 * @dev Extends MessageBridgeProver to send and receive intent proofs across chains via CCIP
 */
contract CCIPProver is MessageBridgeProver, IAny2EVMMessageReceiver, Semver {
    using AddressConverter for bytes32;
    using AddressConverter for address;

    /// @notice The CCIP proof type identifier
    string public constant PROOF_TYPE = "CCIP";

    /// @notice The CCIP Router contract address
    address public immutable ROUTER;

    /// @notice Struct to reduce stack depth when unpacking calldata
    /// @param sourceChainProver The address of the prover on the source chain (as bytes32)
    /// @param gasLimit The gas limit for execution on the destination chain
    /// @param allowOutOfOrderExecution Whether to allow out-of-order execution (CCIP feature)
    struct UnpackedData {
        bytes32 sourceChainProver;
        uint256 gasLimit;
        bool allowOutOfOrderExecution;
    }

    /**
     * @notice Constructs a new CCIPProver
     * @param router The CCIP Router contract address
     * @param portal The portal contract address
     * @param provers Array of whitelisted prover addresses (as bytes32)
     * @param minGasLimit Minimum gas limit for cross-chain messages (0 for default 200k)
     */
    constructor(
        address router,
        address portal,
        bytes32[] memory provers,
        uint256 minGasLimit
    ) MessageBridgeProver(portal, provers, minGasLimit) {
        if (router == address(0)) revert RouterCannotBeZeroAddress();
        ROUTER = router;
    }

    /**
     * @notice Receives cross-chain messages from CCIP
     * @dev Only callable by the CCIP Router. Implements IAny2EVMMessageReceiver
     * @param message The CCIP message containing sender, data, and metadata
     */
    function ccipReceive(
        Client.Any2EVMMessage calldata message
    ) external only(ROUTER) {
        // Decode sender from bytes to address, then convert to bytes32
        address senderAddress = abi.decode(message.sender, (address));
        bytes32 sender = senderAddress.toBytes32();

        // Handle the cross-chain message using base contract functionality
        _handleCrossChainMessage(sender, message.data);
    }

    /**
     * @notice Dispatches a cross-chain message via CCIP
     * @dev Internal function called by the base contract's prove() function
     * @param domainID The destination chain selector (CCIP uses this as destinationChainSelector)
     * @param encodedProofs The encoded proof data to send
     * @param data Additional data containing source chain prover and gas configuration
     * @param fee The fee amount (in native token) to pay for the cross-chain message
     */
    function _dispatchMessage(
        uint64 domainID,
        bytes calldata encodedProofs,
        bytes calldata data,
        uint256 fee
    ) internal override {
        // Unpack the additional data
        UnpackedData memory unpacked = _unpackData(data);

        // Format the CCIP message
        Client.EVM2AnyMessage memory ccipMessage = _formatCCIPMessage(
            unpacked.sourceChainProver,
            encodedProofs,
            unpacked.gasLimit,
            unpacked.allowOutOfOrderExecution
        );

        // Send the message via CCIP Router
        IRouterClient(ROUTER).ccipSend{value: fee}(domainID, ccipMessage);
    }

    /**
     * @notice Calculates the fee required to send a cross-chain message
     * @dev Public function to query fees before sending
     * @param domainID The destination chain selector
     * @param encodedProofs The encoded proof data to send
     * @param data Additional data containing source chain prover and gas configuration
     * @return The fee amount (in native token) required
     */
    function fetchFee(
        uint64 domainID,
        bytes calldata encodedProofs,
        bytes calldata data
    ) public view override returns (uint256) {
        // Unpack the additional data
        UnpackedData memory unpacked = _unpackData(data);

        // Format the CCIP message
        Client.EVM2AnyMessage memory ccipMessage = _formatCCIPMessage(
            unpacked.sourceChainProver,
            encodedProofs,
            unpacked.gasLimit,
            unpacked.allowOutOfOrderExecution
        );

        // Query the fee from CCIP Router
        return IRouterClient(ROUTER).getFee(domainID, ccipMessage);
    }

    /**
     * @notice Unpacks the encoded data into structured format
     * @dev Internal helper to avoid stack too deep errors
     * @param data The encoded data containing source chain prover and gas configuration
     * @return unpacked The unpacked data struct
     */
    function _unpackData(
        bytes calldata data
    ) internal pure returns (UnpackedData memory unpacked) {
        // Decode: (sourceChainProver, gasLimit, allowOutOfOrderExecution)
        (
            unpacked.sourceChainProver,
            unpacked.gasLimit,
            unpacked.allowOutOfOrderExecution
        ) = abi.decode(data, (bytes32, uint256, bool));
    }

    /**
     * @notice Formats a CCIP message for sending
     * @dev Internal helper to construct the EVM2AnyMessage struct
     * @param sourceChainProver The prover address on the source chain
     * @param encodedProofs The proof data payload
     * @param gasLimit The gas limit for execution
     * @param allowOutOfOrderExecution Whether to allow out-of-order execution
     * @return ccipMessage The formatted CCIP message
     */
    function _formatCCIPMessage(
        bytes32 sourceChainProver,
        bytes calldata encodedProofs,
        uint256 gasLimit,
        bool allowOutOfOrderExecution
    ) internal pure returns (Client.EVM2AnyMessage memory ccipMessage) {
        // Convert bytes32 prover address back to address and encode as bytes
        address receiverAddress = sourceChainProver.toAddress();

        // Construct the CCIP message
        ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(receiverAddress),
            data: encodedProofs,
            tokenAmounts: new Client.EVMTokenAmount[](0), // No token transfers
            feeToken: address(0), // Pay fees in native token
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV2({
                    gasLimit: gasLimit,
                    allowOutOfOrderExecution: allowOutOfOrderExecution
                })
            )
        });
    }

    /**
     * @notice Returns the proof type identifier
     * @return The proof type string
     */
    function getProofType() external pure override returns (string memory) {
        return PROOF_TYPE;
    }
}
