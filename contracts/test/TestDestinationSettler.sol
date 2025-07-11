// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../Eco7683DestinationSettler.sol";
import "../Inbox.sol";

contract TestDestinationSettler is Eco7683DestinationSettler {
    Inbox public immutable inbox;

    constructor(address _inbox) {
        inbox = Inbox(payable(_inbox));
    }

    function fulfillAndProve(
        uint64 _sourceChainId,
        Route memory _route,
        bytes32 _rewardHash,
        bytes32 _claimant,
        bytes32 _expectedHash,
        address _localProver,
        bytes memory _data
    ) public payable override returns (bytes[] memory) {
        // Call the inbox's fulfillAndProve function
        return
            inbox.fulfillAndProve{value: msg.value}(
                _sourceChainId,
                _route,
                _rewardHash,
                _claimant,
                _expectedHash,
                _localProver,
                _data
            );
    }
}
