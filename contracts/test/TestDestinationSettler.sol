// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../Eco7683DestinationSettler.sol";
import "../Portal.sol";

contract TestDestinationSettler is Eco7683DestinationSettler {
    Portal public immutable portal;

    constructor(address _portal) {
        portal = Portal(payable(_portal));
    }

    function fulfillAndProve(
        uint64 _sourceChainId,
        Route memory _route,
        bytes32 _rewardHash,
        bytes32 _claimant,
        bytes32 _expectedHash,
        address _prover,
        bytes memory _data
    ) public payable override returns (bytes[] memory) {
        // Call the portal's fulfillAndProve function
        return
            portal.fulfillAndProve{value: msg.value}(
                _sourceChainId,
                _route,
                _rewardHash,
                _claimant,
                _expectedHash,
                _prover,
                _data
            );
    }
}
