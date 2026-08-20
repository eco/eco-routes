// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IProver} from "../interfaces/IProver.sol";
import {Semver} from "../libs/Semver.sol";
import {Whitelist} from "../libs/Whitelist.sol";
import {AddressConverter} from "../libs/AddressConverter.sol";

/**
 * @title EcoProver
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
/// @dev Whitelist's getWhitelist()/getWhitelistSize()/isWhitelisted() carry a
///      DIFFERENT meaning here than on every other IProver implementation: on
///      those, "whitelisted" means a trusted remote cross-VM prover address;
///      here it means a local EVM member of the 1-of-N union. Off-chain
///      tooling that reads isWhitelisted() uniformly across IProver
///      implementations will misread this contract.
///
/// @dev WARNING: this address must NEVER be used as a bridge message
///      recipient. `data.sourceChainProver` in a `Portal.prove` /
///      `fulfillAndProve` call must be one of `getMembers()` resolved on the
///      SOURCE chain, never `reward.prover` (which may legitimately be this
///      aggregator). `EcoProver` implements no `handle`, no `lzReceive`, and
///      no fallback, so delivery to it reverts on an unknown selector
///      forever — permanently stranding the message. For every other prover,
///      CREATE3 parity makes `reward.prover` the correct recipient too, which
///      makes this a real footgun: the pattern that works for every other
///      prover silently does not work here.
contract EcoProver is IProver, ERC165, Whitelist, Semver {
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
     *
     *      The `isValidAddress` check below is the ONLY reason the unguarded
     *      `toAddress()` calls in getMembers/provenIntents/challengeIntentProof
     *      never revert; loosening it would make all three revert-capable and
     *      break IntentSource.batchWithdraw's per-intent isolation.
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
     * @dev Iterates members in immutable priority order. Members that are
     *      codeless, revert, or return a zero claimant are skipped and never
     *      propagated: a zero-claimant success must fall through to the next
     *      member, not terminate the search.
     *
     *      The `code.length` guard closes the CODELESS case: a staticcall to a
     *      codeless address SUCCEEDS with empty returndata, and ABI-decoding
     *      empty data would revert in THIS frame where try/catch cannot catch
     *      it. Without it, a member deployed only on other chains would brick
     *      withdraw AND refund for every intent naming this aggregator.
     *      Mirrors the same defense at IntentSource.sol:872-880.
     *
     *      The call below is a low-level staticcall, not an interface call,
     *      and the read path is revert-free for ANY 64-byte payload, honest or
     *      not. A non-dynamic ProofData{address; uint64;} ABI-encodes to
     *      exactly 64 bytes, so `ret.length == 64` closes the WRONG-SHAPE case
     *      first: a code-bearing member returning SUCCESS with insufficient
     *      returndata would otherwise make solc's generated decoder revert in
     *      THIS frame, outside any try/catch. That length check alone is not
     *      enough, though: decoding a full 64-byte payload directly to
     *      (address, uint64) is ALSO strict — solc reverts, still in this
     *      frame, if the upper 96 bits of the address word or the upper 192
     *      bits of the uint64 word are non-zero. So the 64 bytes are decoded
     *      first as (uint256, uint256), which cannot revert for any bit
     *      pattern, and only then range-checked (`>> 160`/`>> 64` non-zero)
     *      before narrowing; a dirty payload is treated exactly like a
     *      wrong-length one, i.e. skipped via `continue`. Either failure
     *      mode — wrong length or dirty high bits — would otherwise be a
     *      permanent freeze of both withdraw and refund for every intent
     *      naming this aggregator, since provenIntents is read by both.
     *
     *      An uncatchable out-of-gas (oversized returndata, or an unbounded
     *      gas burn by a hostile member) is still possible and is ACCEPTED:
     *      solc copies the full returndata into memory in our frame before
     *      any length check runs, so a member returning gigabytes of data
     *      still costs us quadratic memory-expansion gas; a member that
     *      simply burns gas without returning is the same failure mode by a
     *      different mechanism. This is tolerated because deploy-time
     *      validation (`Deploy.validateEcoProverMembers`) only probes that
     *      each member exposes `chainIdByDomain(uint64)` — a duck-typed check
     *      that any contract implementing that one function passes, not a
     *      guarantee of `MessageBridgeProver`-descended or repo-built
     *      bytecode. It guards against an operator's config mistake (e.g. a
     *      non-bridge-attested or unrelated address), not against a
     *      deliberately malicious member contract. That validator also
     *      assumes NON-PROXY member bytecode: a proxy whose fallback returned
     *      a plausible 64-byte payload could defeat the shape checks above;
     *      it does not defend against a malicious proxy member.
     *
     *      No per-member gas cap by design: a cap would silently skip an honest
     *      member whose read exceeds it, leaving a delivered solver unpayable
     *      with no error. A compromised member can already forge a valid-looking
     *      proof through the front door, so a returndata bomb grants it nothing
     *      new. Fan-out is bounded by MAX_MEMBERS.
     *
     *      The size check plus the bit-range check are NOT sufficient on their
     *      own: a member function returning a single EMPTY DYNAMIC value
     *      (bytes, string, any array, or a struct with a dynamic field)
     *      ABI-encodes to exactly 64 bytes too — an offset head `0x20`
     *      followed by a length word `0x00` — which passes `ret.length == 64`
     *      and passes both range checks (`32 >> 160 == 0`, `0 >> 64 == 0`).
     *      Decoded naively, the ABI OFFSET WORD itself would surface as a
     *      fabricated non-zero claimant (`address(0x20)`) with `destination`
     *      0, for every intentHash — the only known payload class that
     *      FABRICATES a claimant rather than being skipped. The
     *      `rawDestination == 0` guard below closes this: no eligible member
     *      can legitimately hold destination 0, since `MessageBridgeProver`
     *      rejects chainId 0 at construction and `_resolveChainId` reverts
     *      `UnregisteredDomain(0)`. A static two-word `ProofData` tuple is
     *      what an honest member actually returns; together the size check,
     *      the bit-range check, and this zero-destination check mean any
     *      wrong-shaped payload is skipped (falls through to the next
     *      member) rather than surfaced.
     *
     *      KNOWN LIMITATION (shadowing): a member holding an entry whose
     *      `destination` is wrong shadows a valid proof held by a
     *      lower-priority member, since this function returns the first
     *      non-zero claimant. `IntentSource.withdraw` recovers by forwarding a
     *      challenge on its wrong-destination branch, so a second `withdraw`
     *      pays, but `_validateRefund` reads the same shadowed value, never
     *      forwards a challenge, and past `reward.deadline` refunds the
     *      creator while the solver who delivered goes unpaid. The mitigation
     *      is `Deploy.validateEcoProverMembers`, which restricts members to
     *      provers whose `destination` is bridge-attested by
     *      `MessageBridgeProver._handleCrossChainMessage`; the asymmetry
     *      itself remains in `IntentSource`.
     * @param intentHash The intent hash to query
     * @return First non-zero member proof, or a zero ProofData if none
     */
    function provenIntents(
        bytes32 intentHash
    ) external view returns (ProofData memory) {
        bytes32[] memory members = getWhitelist();
        uint256 length = members.length;

        for (uint256 i = 0; i < length; ++i) {
            address member = members[i].toAddress();

            if (member.code.length == 0) continue;

            (bool success, bytes memory ret) = member.staticcall(
                abi.encodeWithSelector(
                    IProver.provenIntents.selector,
                    intentHash
                )
            );

            if (!success || ret.length != 64) continue;

            // Decode as two uint256 words first: unlike decoding directly to
            // (address, uint64), this cannot revert for any 64-byte payload.
            // Dirty high-order bits are then rejected by range check, exactly
            // like a wrong-length payload, rather than left to solc's strict
            // (address, uint64) decoder, which WOULD revert in this frame.
            (uint256 rawClaimant, uint256 rawDestination) = abi.decode(
                ret,
                (uint256, uint256)
            );

            if (rawClaimant >> 160 != 0 || rawDestination >> 64 != 0) {
                continue;
            }

            // A single empty dynamic return value (bytes/string/array) encodes
            // to exactly 64 bytes — offset head 0x20, then length 0x00 — which
            // passes the size and range checks above and would otherwise surface
            // the ABI OFFSET WORD as a fabricated claimant with destination 0.
            // No eligible member can legitimately hold destination 0:
            // MessageBridgeProver rejects chainId 0 at construction and
            // _resolveChainId reverts UnregisteredDomain(0).
            if (rawDestination == 0) continue;

            address claimant = address(uint160(rawClaimant));
            uint64 destination = uint64(rawDestination);

            if (claimant != address(0)) {
                return
                    ProofData({claimant: claimant, destination: destination});
            }
        }

        return ProofData({claimant: address(0), destination: 0});
    }

    /**
     * @notice Forwards a challenge to every member prover
     * @dev Forwarding is required, not cosmetic: IntentSource.withdraw calls
     *      this itself on its wrong-destination branch (IntentSource.sol:468).
     *      Reverting here would revert withdraw, and would revert an entire
     *      batchWithdraw (IntentSource.sol:492) over one planted bad proof.
     *
     *      Blanket-forwarding is precise even though this contract cannot tell
     *      which member is wrong: each member re-derives the intent hash and
     *      deletes ONLY its own entry, and ONLY on its own destination mismatch
     *      (BaseProver.sol:112-129). Honest proofs take the false branch and
     *      are untouched.
     * @param destination The intended destination chain ID
     * @param routeHash The hash of the intent's route
     * @param rewardHash The hash of the reward specification
     */
    function challengeIntentProof(
        uint64 destination,
        bytes32 routeHash,
        bytes32 rewardHash
    ) external {
        bytes32[] memory members = getWhitelist();
        uint256 length = members.length;

        for (uint256 i = 0; i < length; ++i) {
            address member = members[i].toAddress();

            // Load-bearing, not defensive filler: solc's extcodesize check
            // inside a high-level `try` call reverts in THIS frame when the
            // target is codeless, outside any `catch` — the `try/catch`
            // below only guards the CALL itself, not the codeless-target
            // case. Without this, a member deployed only on other chains
            // would revert this whole function, and the wrong-destination
            // branch in IntentSource.withdraw that calls it would revert too.
            if (member.code.length == 0) continue;

            try
                IProver(member).challengeIntentProof(
                    destination,
                    routeHash,
                    rewardHash
                )
            {} catch {
                continue;
            }
        }

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
