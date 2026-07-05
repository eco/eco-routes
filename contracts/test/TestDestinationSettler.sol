// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DestinationSettler, Route, Reward} from "../ERC7683/DestinationSettler.sol";
import {Portal} from "../Portal.sol";

contract TestDestinationSettler is DestinationSettler {
    Portal public immutable PORTAL;

    constructor(address _portal) {
        PORTAL = Portal(payable(_portal));
    }

    function fulfillAndProve(
        uint32 _protocolVersion,
        uint64 _source,
        uint64 _destination,
        Route memory _route,
        Reward memory _reward,
        bytes32 _claimant,
        uint256[] memory _providedAmounts,
        address _prover,
        uint64 _sourceChainDomainID,
        bytes memory _data
    ) public payable override returns (bytes memory) {
        // Call the portal's fulfillAndProve function
        return
            PORTAL.fulfillAndProve{value: msg.value}(
                _protocolVersion,
                _source,
                _destination,
                _route,
                _reward,
                _claimant,
                _providedAmounts,
                _prover,
                _sourceChainDomainID,
                _data
            );
    }
}
