// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IProver} from "../interfaces/IProver.sol";
import {Semver} from "../libs/Semver.sol";
import {Whitelist} from "../libs/Whitelist.sol";
import {AddressConverter} from "../libs/AddressConverter.sol";

/**
 * @title AggregatorProver
 * @notice Reports an intent as proven when ANY member prover has proven it
 * @dev Stateless 1-of-N union over an immutable set of member provers. Records
 *      no proofs of its own and dispatches no messages: solvers prove through a
 *      concrete member via Portal.prove, and this contract only reads the
 *      results on the source chain.
 *
 *      SECURITY: union semantics mean the security floor is the WEAKEST member.
 *      A compromised member can forge a claimant and drain any vault whose
 *      intent names this aggregator. Membership is immutable and cannot be
 *      ejected; member selection is the security-critical decision.
 *
 *      Reuses Whitelist as an immutable ordered address set. Elsewhere in this
 *      repo Whitelist holds REMOTE cross-VM prover addresses; here it holds
 *      LOCAL EVM member contracts.
 */
contract AggregatorProver is IProver, ERC165, Whitelist, Semver {
    using AddressConverter for bytes32;

    /// @notice Proof mechanism identifier
    string public constant PROOF_TYPE = "Aggregator";

    /// @notice Maximum members; tighter than Whitelist's 20 because every
    ///         member costs a call on both withdraw and refund
    uint256 public constant MAX_MEMBERS = 8;

    /// @notice prove() is not supported; route through a concrete member
    error ProvingNotSupported();

    /// @notice Member set is empty or exceeds MAX_MEMBERS
    error InvalidMemberSet(uint256 size, uint256 maxSize);

    /// @notice Member is zero or not a valid EVM address
    error InvalidMember(bytes32 member);

    /// @notice Member appears more than once in the set
    error DuplicateMember(bytes32 member);

    /// @notice Emitted once per member at construction, so the immutable,
    ///         setter-less set is auditable after deploy
    /// @param member Member prover address
    /// @param priority Index in the set; lower wins on conflict
    event MemberRegistered(address indexed member, uint256 indexed priority);

    /// @notice Emitted when a challenge was RELAYED to members
    /// @dev Does not imply anything was invalidated; a member that deletes an
    ///      entry emits its own IntentProofInvalidated
    event ChallengeForwarded(bytes32 indexed intentHash);

    /**
     * @notice Initializes the aggregator with an ordered, immutable member set
     * @dev Validates the `members` MEMORY PARAMETER, never getWhitelist():
     *      immutables cannot be read during construction.
     *      Whitelist's constructor runs first, so a set larger than its own
     *      20-address cap reverts with WhitelistSizeExceeded, not
     *      InvalidMemberSet.
     * @param members Member prover addresses as bytes32, in priority order
     */
    constructor(bytes32[] memory members) Whitelist(members) {
        uint256 length = members.length;

        if (length == 0 || length > MAX_MEMBERS) {
            revert InvalidMemberSet(length, MAX_MEMBERS);
        }

        for (uint256 i = 0; i < length; ++i) {
            bytes32 member = members[i];

            if (member == bytes32(0) || !member.isValidAddress()) {
                revert InvalidMember(member);
            }

            // O(n^2) over a constructor-only list of at most MAX_MEMBERS
            for (uint256 j = 0; j < i; ++j) {
                if (members[j] == member) {
                    revert DuplicateMember(member);
                }
            }

            emit MemberRegistered(member.toAddress(), i);
        }
    }

    /**
     * @notice Returns the member provers in priority order
     */
    function getMembers() external view returns (address[] memory) {
        bytes32[] memory members = getWhitelist();
        uint256 length = members.length;
        address[] memory result = new address[](length);

        for (uint256 i = 0; i < length; ++i) {
            result[i] = members[i].toAddress();
        }

        return result;
    }

    /**
     * @notice Returns the first member proof with a non-zero claimant
     * @param intentHash The intent hash to query
     */
    function provenIntents(
        bytes32 intentHash
    ) external view returns (ProofData memory) {
        intentHash; // silences unused-parameter warning until Task 2
        return ProofData({claimant: address(0), destination: 0});
    }

    /**
     * @notice Forwards a challenge to every member
     */
    function challengeIntentProof(
        uint64 destination,
        bytes32 routeHash,
        bytes32 rewardHash
    ) external {
        emit ChallengeForwarded(
            keccak256(abi.encodePacked(destination, routeHash, rewardHash))
        );
    }

    /**
     * @notice Always reverts; the aggregator dispatches no messages
     * @dev Reverting makes a misrouted Portal.prove or fulfillAndProve fail
     *      loudly and return the solver's ETH, rather than silently accepting a
     *      proof that was never sent.
     */
    function prove(
        address,
        uint64,
        bytes calldata,
        bytes calldata
    ) external payable {
        revert ProvingNotSupported();
    }

    /**
     * @notice Gets the proof mechanism type used by this prover
     */
    function getProofType() external pure returns (string memory) {
        return PROOF_TYPE;
    }

    /**
     * @notice Checks if this contract supports a given interface
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IProver).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
