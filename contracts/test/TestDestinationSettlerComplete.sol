// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DestinationSettler, Route} from "../ERC7683/DestinationSettler.sol";
import {Portal} from "../Portal.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AddressConverter} from "../libs/AddressConverter.sol";
import {TokenAmount} from "../types/Intent.sol";

contract TestDestinationSettlerComplete is DestinationSettler {
    using AddressConverter for bytes32;

    Portal public immutable PORTAL;

    constructor(address _portal) {
        PORTAL = Portal(payable(_portal));
    }

    function fulfillAndProve(
        bytes32 _intentHash,
        Route memory _route,
        bytes32 _rewardHash,
        bytes32 _claimant,
        uint256[] memory _providedAmounts,
        address _prover,
        uint64 _source,
        bytes memory _data
    ) public payable override returns (bytes[] memory) {
        // Pull the provided input from the solver (msg.sender) and approve the portal to spend it.
        uint256 inCount = _route.minTokens.length;
        for (uint256 i = 0; i < inCount; ++i) {
            address token = _route.minTokens[i].token;
            if (token != address(0)) {
                IERC20(token).transferFrom(
                    msg.sender,
                    address(this),
                    _providedAmounts[i]
                );
                IERC20(token).approve(address(PORTAL), _providedAmounts[i]);
            }
        }

        // Call the portal's fulfillAndProve function
        return
            PORTAL.fulfillAndProve{value: msg.value}(
                _intentHash,
                _route,
                _rewardHash,
                _claimant,
                _providedAmounts,
                _prover,
                _source,
                _data
            );
    }
}
