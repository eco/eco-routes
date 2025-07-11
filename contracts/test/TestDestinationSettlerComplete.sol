// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../Eco7683DestinationSettler.sol";
import "../Portal.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AddressConverter} from "../libs/AddressConverter.sol";

contract TestDestinationSettlerComplete is Eco7683DestinationSettler {
    using AddressConverter for bytes32;

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
        address _localProver,
        bytes memory _data
    ) public payable override returns (bytes[] memory) {
        // First, transfer tokens from the solver (msg.sender) to this contract
        uint256 routeTokenCount = _route.tokens.length;
        for (uint256 i = 0; i < routeTokenCount; ++i) {
            TokenAmount memory token = _route.tokens[i];
            IERC20(token.token.toAddress()).transferFrom(
                msg.sender,
                address(this),
                token.amount
            );
            // Then approve the portal to spend these tokens
            IERC20(token.token.toAddress()).approve(
                address(portal),
                token.amount
            );
        }

        // Call the portal's fulfillAndProve function
        return
            portal.fulfillAndProve{value: msg.value}(
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
