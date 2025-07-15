// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Eco7683DestinationSettler, Route} from "../Eco7683DestinationSettler.sol";
import {Portal} from "../Portal.sol";

contract TestDestinationSettler is Eco7683DestinationSettler {
    Portal public immutable PORTAL;

    constructor(address _portal) {
        PORTAL = Portal(payable(_portal));
    }

    function fulfillAndProve(
        bytes32 _intentHash,
        Route memory _route,
        bytes32 _rewardHash,
        bytes32 _claimant,
        address _prover,
        uint64 _source,
        bytes memory _data
    ) public payable override returns (bytes[] memory) {
        // Call the portal's fulfillAndProve function
        return
            PORTAL.fulfillAndProve{value: msg.value}(
                _intentHash,
                _route,
                _rewardHash,
                _claimant,
                _prover,
                _source,
                _data
            );
    }
}
