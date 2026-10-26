// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IntentTemplate} from "../../contracts/chain/IntentTemplate.sol";

/// @dev Adapts amount-only fixture geometry without changing expected route/reward bytes.
library TemplateFixtures {
    function amount(
        uint8 width,
        bool littleEndian
    ) internal pure returns (IntentTemplate.Item memory) {
        return
            IntentTemplate.Item({
                kind: IntentTemplate.ItemKind.Amount,
                config: abi.encode(
                    IntentTemplate.AmountConfig({
                        source: IntentTemplate.AmountSource.Output,
                        scale: 1e18,
                        width: width,
                        littleEndian: littleEndian
                    })
                )
            });
    }

    function program(
        bytes[] memory segments,
        IntentTemplate.Item[] memory items
    ) internal pure returns (IntentTemplate.Program memory) {
        return
            IntentTemplate.Program({
                vaults: new IntentTemplate.Vault[](0),
                route: IntentTemplate.Template({
                    segments: segments,
                    items: items
                })
            });
    }
}
