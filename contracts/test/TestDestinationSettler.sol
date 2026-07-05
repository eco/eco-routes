// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DestinationSettler, Route} from "../ERC7683/DestinationSettler.sol";
import {Portal} from "../Portal.sol";

contract TestDestinationSettler is DestinationSettler {
    Portal public immutable PORTAL;

    constructor(address _portal) {
        PORTAL = Portal(payable(_portal));
    }

    function fulfillAndProve(
        uint64 _source,
        bytes32 _intentHash,
        Route memory _route,
        bytes32 _rewardHash,
        bytes32 _claimant,
        uint256[] memory _providedAmounts,
        address _prover,
        uint64 _sourceChainDomainID,
        bytes memory _data
    ) public payable override returns (bytes memory) {
        // Call the portal's fulfillAndProve function
        return
            PORTAL.fulfillAndProve{value: msg.value}(
                _source,
                _intentHash,
                _route,
                _rewardHash,
                _claimant,
                _providedAmounts,
                _prover,
                _sourceChainDomainID,
                _data
            );
    }
}
