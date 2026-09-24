// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BaseTest} from "../BaseTest.sol";
import {IProver} from "../../contracts/interfaces/IProver.sol";

/// @notice Outcome recording in BaseProver._processIntentProofs, driven through TestProver
contract ProofOutcomeTest is BaseTest {
    function _message(
        uint64 chainId,
        bytes32 intentHash,
        bytes32 claimantBytes
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(chainId, intentHash, claimantBytes);
    }

    function testRecordsFulfilledOutcome() public {
        bytes32 intentHash = _hashIntent(intent);

        prover.prove(
            address(this),
            CHAIN_ID,
            _message(CHAIN_ID, intentHash, bytes32(uint256(uint160(claimant)))),
            ""
        );

        IProver.ProofData memory proof = prover.provenIntents(intentHash);
        assertEq(proof.claimant, claimant);
        assertEq(proof.destination, CHAIN_ID);
        assertEq(uint8(proof.outcome), uint8(IProver.Outcome.Fulfilled));
    }

    function testZeroClaimantStaysUnproven() public {
        bytes32 intentHash = _hashIntent(intent);

        prover.prove(
            address(this),
            CHAIN_ID,
            _message(CHAIN_ID, intentHash, bytes32(0)),
            ""
        );

        assertEq(
            uint8(prover.provenIntents(intentHash).outcome),
            uint8(IProver.Outcome.None)
        );
    }

    function testUnprovenIntentReadsNone() public view {
        IProver.ProofData memory proof = prover.provenIntents(
            keccak256("nothing")
        );
        assertEq(proof.claimant, address(0));
        assertEq(proof.destination, 0);
        assertEq(uint8(proof.outcome), uint8(IProver.Outcome.None));
    }
}
