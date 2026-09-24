# Proven Cancellation (EVM) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let anyone cancel an unfulfilled intent on the destination Portal after `route.deadline`, carry that cancellation back through every existing prover as a sentinel claimant, and let the source Portal refund a proven cancellation immediately, with `reward.deadline` kept as the timeout fallback.

**Architecture:** The destination writes `CANCELLED_CLAIMANT` into the existing `claimants[intentHash]` slot, so `fulfill`'s "already fulfilled" check and `prove`'s payload build cover cancellation with no new branches, and the wire format is unchanged. Source provers map the sentinel to `ProofData.outcome = Cancelled` (claimant `address(0)`), so any reader that does not know about cancellation sees "unproven" and falls back to the timeout. `IntentSource` refunds on a proven Cancelled outcome and refuses to withdraw one.

**Tech Stack:** Solidity 0.8.27 (via-IR, Paris, optimizer 1,000,000 runs), Foundry (`forge`), Hardhat + TypeScript tests, prettier-plugin-solidity, solhint.

**Spec:** `CLAUDE/specs/2026-09-24-proven-cancellation-design.md` (same worktree). Implements §3, §4, §6, §8 (EVM), §9 and the EVM column of §10, decisions D1–D8. The SVM side (§5, §7) is a separate plan in eco-routes-svm.

## Global Constraints

- Worktree: `/Users/carlosfebres/dev/eco/eco-routes-proven-cancellation`, branch `cfebres/proven-cancellation`. Use absolute paths; never `cd` (pass `--root` to forge, `--cwd` to yarn, `-C` to git).
- Sentinel: `CANCELLED_CLAIMANT = keccak256("eco.portal.intent.cancelled")` = `0xa8aa898126679f5f179cb3a4e685056aec77686a83e2a6bdf37c6f71dd2fdb5f`. Defined once, file-level, in `contracts/types/Intent.sol`; never re-typed as a literal in contracts.
- Wire format unchanged: `[chainId u64 BE] ‖ N × [intentHash ‖ claimant]`. No destination-side prover code changes.
- `enum Outcome { None, Fulfilled, Cancelled }`; `None` = not proven. Existence of a proof is `outcome != None`, never `claimant != address(0)`. A Cancelled proof has `claimant == address(0)`.
- Time partition: `fulfill` allowed iff `block.timestamp <= route.deadline`; `cancel` allowed iff `block.timestamp > route.deadline` (strict).
- Conflicts: first recorded outcome wins per prover (D7); `AggregatorProver` resolves by member priority.
- Release is a **minor** version (D8): commit subjects use `feat(...)`, `fix(...)`, `test(...)`, `docs(...)`; never `!`, never a `BREAKING CHANGE` footer.
- Every commit message ends with the line `Claude-Session: https://claude.ai/code/session_01Fs7GU5DoDuKhLo9VDktMXP` (pass it as a second `-m`). No co-author lines.
- Stage files by name (`git -C <wt> add <path> ...`), never `git add -A` / `.`.
- Format only the files you touched: `npx --prefix <wt> prettier --write <files>`; lint contracts you touched: `npx --prefix <wt> solhint <files>`. Never blanket-format.
- **EIP-170 size gate:** at baseline `Portal` runtime is **23,650 B** and `PortalTron` **23,650 B** against the 24,576 B limit (**926 B margin**). After every task that touches `Inbox.sol` or `IntentSource.sol`, run the size gate (see Task 1 Step 7). If either exceeds 24,576 B, **STOP and report** — do not change optimizer settings, split contracts, or delete features on your own. The user decides the cut only after seeing measured sizes.
- Repo security gate (`CLAUDE.md`): this is a feature, not a fix for deployed code, but do **not** push or open a PR as part of this plan; the human decides.
- Tests extend `BaseTest` (`test/BaseTest.sol`) where they need a Portal + `TestProver`; match the repo's comment density (short intent comments, NatSpec on public/external contract functions).

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `contracts/types/Intent.sol` | modify | file-level `CANCELLED_CLAIMANT` constant (single definition) |
| `contracts/interfaces/IInbox.sol` | modify | `IntentCancelled` event, `RouteNotExpired`/`ReservedClaimant` errors, `cancel`/`cancelAndProve` |
| `contracts/Inbox.sol` | modify | `CANCELLED` getter, `cancel`, `cancelAndProve`, `_cancel`, sentinel guard in `_fulfill` |
| `contracts/interfaces/IProver.sol` | modify | `Outcome` enum, `ProofData.outcome`, `IntentCancellationProven` event |
| `contracts/prover/BaseProver.sol` | modify | shared `_recordProof` (sentinel → Cancelled, first-recorded-wins), outcome-based challenge |
| `contracts/prover/PolymerProver.sol` | modify | route pairs through `_recordProof`; delete `processIntent` |
| `contracts/prover/LocalProver.sol` | modify | outcome in every return; `CANCELLED_CLAIMANT` → Cancelled |
| `contracts/prover/AggregatorProver.sol` | modify | 96-byte tuple decode, outcome-aware selection, offset-head guard |
| `contracts/interfaces/IIntentSource.sol` | modify | `CancelledIntent(bytes32)` error |
| `contracts/IntentSource.sol` | modify | fast-path refund, withdraw guard |
| `scripts/Deploy.s.sol` | modify | aggregator member probe expects the 96-byte shape |
| `contracts/test/TestProver.sol`, `TestMessageBridgeProver.sol` | modify | helpers set `outcome`; `addCancelledIntent` |
| `contracts/test/MockDomainProver.sol`, `MockDomainProverDirtyChainId.sol` | modify | 3-field literals |
| `contracts/test/DirtyBitsProver.sol` | modify | dirty payload widened to 96 bytes |
| `contracts/test/ShortDynamicProver.sol` | create | 96-byte dynamic-return fabrication case |
| `contracts/test/MockDomainProverLegacyShape.sol` | create | legacy 64-byte member for the deploy probe |
| `test/core/InboxCancel.t.sol` | create | destination cancel semantics + sentinel golden |
| `test/prover/ProofOutcome.t.sol` | create | `BaseProver` outcome recording, conflicts, challenge |
| `test/source/IntentSourceCancellation.t.sol` | create | refund fast path, withdraw guard, fallback, legacy shape |
| `test/core/ProvenCancellationFlow.t.sol` | create | end-to-end cancel → prove → refund, fail-safe legacy reader |
| `test/prover/{PolymerProver,LocalProver,AggregatorProver,HyperProver,LayerZeroProver,MetaProver,CCIPProver}.t.sol` | modify | per-prover cancellation coverage |
| `test/source/IntentSource.t.sol` | modify | 3-field `ProofData` literals in `vm.mockCall` |
| `test/scripts/AggregatorProverMemberValidation.t.sol` | modify | legacy-shape member rejected |
| `scripts/tron/run-tron-evm-intent.ts` | modify | stale "128 hex chars" comment |
| `CLAUDE.md`, `contracts/README.md` | modify | document cancellation and the new selection rule |

---

### Task 1: Destination `cancel` and the shared sentinel

**Files:**
- Modify: `contracts/types/Intent.sol` (append after the last struct)
- Modify: `contracts/interfaces/IInbox.sol` (events/errors block and before `prove`)
- Modify: `contracts/Inbox.sol` (`_fulfill` claimant checks ~line 241-246; new functions after `fulfillAndProve`)
- Create: `test/core/InboxCancel.t.sol`

**Interfaces:**
- Produces: `bytes32 constant CANCELLED_CLAIMANT` (file-level in `contracts/types/Intent.sol`); `Inbox.CANCELLED() returns (bytes32)`; `IInbox.cancel(bytes32 intentHash, Route memory route, bytes32 rewardHash) external`; `Inbox._cancel(bytes32, Route memory, bytes32) internal`; `event IInbox.IntentCancelled(bytes32 indexed intentHash)`; `error IInbox.RouteNotExpired(uint64 deadline)`; `error IInbox.ReservedClaimant()`.

- [ ] **Step 0: Prepare the worktree (once)**

```bash
git -C /Users/carlosfebres/dev/eco/eco-routes-proven-cancellation submodule update --init --recursive
[ -e /Users/carlosfebres/dev/eco/eco-routes-proven-cancellation/node_modules ] || ln -s /Users/carlosfebres/dev/eco/eco-routes/node_modules /Users/carlosfebres/dev/eco/eco-routes-proven-cancellation/node_modules
forge build --root /Users/carlosfebres/dev/eco/eco-routes-proven-cancellation --sizes 2>&1 | grep -E '^\| Portal(Tron)? '
```
Expected: `Portal` and `PortalTron` runtime 23,650 (the baseline). `node_modules` is git-ignored; the symlink is safe because `yarn.lock` is identical to the main checkout.

- [ ] **Step 1: Write the failing tests**

Create `test/core/InboxCancel.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BaseTest} from "../BaseTest.sol";
import {IInbox} from "../../contracts/interfaces/IInbox.sol";
import {Intent, CANCELLED_CLAIMANT} from "../../contracts/types/Intent.sol";

contract InboxCancelTest is BaseTest {
    address internal solver;
    bytes32 internal solverClaimant;

    function setUp() public override {
        super.setUp();
        solver = makeAddr("solver");
        solverClaimant = bytes32(uint256(uint160(solver)));
        // intentSource and the Inbox are the same Portal, so this also
        // approves the Portal to pull the solver's route tokens
        _mintAndApprove(solver, MINT_AMOUNT);
    }

    // BaseTest's intent targets CHAIN_ID (a source-side fixture); the Inbox
    // hashes with block.chainid, so point the intent at this chain
    function _destinationIntent()
        internal
        view
        returns (
            Intent memory destIntent,
            bytes32 intentHash,
            bytes32 rewardHash
        )
    {
        destIntent = intent;
        destIntent.destination = uint64(block.chainid);
        rewardHash = keccak256(abi.encode(destIntent.reward));
        intentHash = keccak256(
            abi.encodePacked(
                destIntent.destination,
                keccak256(abi.encode(destIntent.route)),
                rewardHash
            )
        );
    }

    function testCancelledSentinelGolden() public view {
        assertEq(
            CANCELLED_CLAIMANT,
            0xa8aa898126679f5f179cb3a4e685056aec77686a83e2a6bdf37c6f71dd2fdb5f
        );
        assertEq(CANCELLED_CLAIMANT, keccak256("eco.portal.intent.cancelled"));
        // Never a valid EVM address, so pre-cancellation provers skip it
        assertTrue(uint256(CANCELLED_CLAIMANT) >> 160 != 0);
        assertEq(portal.CANCELLED(), CANCELLED_CLAIMANT);
    }

    function testCancelRevertsAtRouteDeadline() public {
        (
            Intent memory i,
            bytes32 intentHash,
            bytes32 rewardHash
        ) = _destinationIntent();
        vm.warp(i.route.deadline);

        vm.expectRevert(
            abi.encodeWithSelector(
                IInbox.RouteNotExpired.selector,
                i.route.deadline
            )
        );
        portal.cancel(intentHash, i.route, rewardHash);
    }

    function testCancelSucceedsOneSecondAfterRouteDeadline() public {
        (
            Intent memory i,
            bytes32 intentHash,
            bytes32 rewardHash
        ) = _destinationIntent();
        vm.warp(uint256(i.route.deadline) + 1);

        vm.expectEmit(true, true, true, true, address(portal));
        emit IInbox.IntentCancelled(intentHash);
        vm.prank(otherPerson);
        portal.cancel(intentHash, i.route, rewardHash);

        assertEq(portal.claimants(intentHash), CANCELLED_CLAIMANT);
    }

    function testFulfillStillSucceedsAtRouteDeadline() public {
        (
            Intent memory i,
            bytes32 intentHash,
            bytes32 rewardHash
        ) = _destinationIntent();
        vm.warp(i.route.deadline);

        vm.prank(solver);
        portal.fulfill(intentHash, i.route, rewardHash, solverClaimant);

        assertEq(portal.claimants(intentHash), solverClaimant);
    }

    function testCancelRevertsAfterFulfill() public {
        (
            Intent memory i,
            bytes32 intentHash,
            bytes32 rewardHash
        ) = _destinationIntent();
        vm.warp(i.route.deadline);
        vm.prank(solver);
        portal.fulfill(intentHash, i.route, rewardHash, solverClaimant);

        vm.warp(uint256(i.route.deadline) + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IInbox.IntentAlreadyFulfilled.selector,
                intentHash
            )
        );
        portal.cancel(intentHash, i.route, rewardHash);
    }

    function testFulfillRevertsAfterCancelViaExpiry() public {
        (
            Intent memory i,
            bytes32 intentHash,
            bytes32 rewardHash
        ) = _destinationIntent();
        vm.warp(uint256(i.route.deadline) + 1);
        portal.cancel(intentHash, i.route, rewardHash);

        vm.expectRevert(IInbox.IntentExpired.selector);
        vm.prank(solver);
        portal.fulfill(intentHash, i.route, rewardHash, solverClaimant);
    }

    // Defence in depth: even if the clock could run backwards, the stored
    // sentinel alone blocks a later fulfill
    function testFulfillRevertsOnCancelledRecordEvenWithinDeadline() public {
        (
            Intent memory i,
            bytes32 intentHash,
            bytes32 rewardHash
        ) = _destinationIntent();
        vm.warp(uint256(i.route.deadline) + 1);
        portal.cancel(intentHash, i.route, rewardHash);

        vm.warp(i.route.deadline);
        vm.expectRevert(
            abi.encodeWithSelector(
                IInbox.IntentAlreadyFulfilled.selector,
                intentHash
            )
        );
        vm.prank(solver);
        portal.fulfill(intentHash, i.route, rewardHash, solverClaimant);
    }

    function testCancelRevertsWhenAlreadyCancelled() public {
        (
            Intent memory i,
            bytes32 intentHash,
            bytes32 rewardHash
        ) = _destinationIntent();
        vm.warp(uint256(i.route.deadline) + 1);
        portal.cancel(intentHash, i.route, rewardHash);

        vm.expectRevert(
            abi.encodeWithSelector(
                IInbox.IntentAlreadyFulfilled.selector,
                intentHash
            )
        );
        portal.cancel(intentHash, i.route, rewardHash);
    }

    function testCancelRevertsOnWrongPortal() public {
        (
            Intent memory i,
            bytes32 intentHash,
            bytes32 rewardHash
        ) = _destinationIntent();
        i.route.portal = address(0xdead);
        vm.warp(uint256(i.route.deadline) + 1);

        vm.expectRevert(
            abi.encodeWithSelector(IInbox.InvalidPortal.selector, address(0xdead))
        );
        portal.cancel(intentHash, i.route, rewardHash);
    }

    function testCancelRevertsOnHashMismatch() public {
        (Intent memory i, , bytes32 rewardHash) = _destinationIntent();
        bytes32 wrongHash = keccak256("wrong");
        vm.warp(uint256(i.route.deadline) + 1);

        vm.expectRevert(
            abi.encodeWithSelector(IInbox.InvalidHash.selector, wrongHash)
        );
        portal.cancel(wrongHash, i.route, rewardHash);
    }

    function testFulfillRejectsCancelledSentinelClaimant() public {
        (
            Intent memory i,
            bytes32 intentHash,
            bytes32 rewardHash
        ) = _destinationIntent();

        vm.expectRevert(IInbox.ReservedClaimant.selector);
        vm.prank(solver);
        portal.fulfill(intentHash, i.route, rewardHash, CANCELLED_CLAIMANT);
    }

    function testProveCarriesCancelledSentinel() public {
        (
            Intent memory i,
            bytes32 intentHash,
            bytes32 rewardHash
        ) = _destinationIntent();
        vm.warp(uint256(i.route.deadline) + 1);
        portal.cancel(intentHash, i.route, rewardHash);

        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = intentHash;

        vm.expectEmit(true, true, true, true, address(portal));
        emit IInbox.IntentProven(intentHash, CANCELLED_CLAIMANT);
        portal.prove(address(prover), uint64(block.chainid), hashes, "");

        assertEq(prover.argIntentHashes(0), intentHash);
        assertEq(prover.argClaimants(0), CANCELLED_CLAIMANT);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --root /Users/carlosfebres/dev/eco/eco-routes-proven-cancellation --match-contract InboxCancelTest`
Expected: compilation error — `Declaration "CANCELLED_CLAIMANT" not found` / `Member "cancel" not found`.

- [ ] **Step 3: Add the sentinel constant**

Append to `contracts/types/Intent.sol`:

```solidity

/**
 * @notice Reserved claimant value that marks an intent as cancelled on its destination
 * @dev Written into the destination Portal's claimants mapping by cancel() and carried to
 *      the source by the existing (intentHash, claimant) proof payload. Its upper 12 bytes
 *      are non-zero, so it is never a valid EVM address, and as a hash preimage no key
 *      controls it on any VM. Must match eco-svm-std's CANCELLED byte for byte.
 */
bytes32 constant CANCELLED_CLAIMANT = keccak256("eco.portal.intent.cancelled");
```

- [ ] **Step 4: Extend `IInbox`**

In `contracts/interfaces/IInbox.sol`, after the `IntentProven` event add:

```solidity
    /**
     * @notice Emitted when an unfulfilled intent is cancelled after its route deadline
     * @param intentHash Hash of the cancelled intent
     */
    event IntentCancelled(bytes32 indexed intentHash);
```

After the `InsufficientNativeAmount` error add:

```solidity
    /**
     * @notice The route deadline has not passed yet, so the intent cannot be cancelled
     * @param deadline The route deadline
     */
    error RouteNotExpired(uint64 deadline);

    /**
     * @notice The claimant is reserved for cancelled intents
     */
    error ReservedClaimant();
```

Before the `prove` declaration add:

```solidity
    /**
     * @notice Cancels an unfulfilled intent once its route deadline has passed
     * @dev Permissionless. Records the CANCELLED sentinel as the intent's claimant, which
     *      blocks any later fulfill and is proven to the source like a claimant.
     * @param intentHash The hash of the intent to cancel
     * @param route Route information for the intent
     * @param rewardHash Hash of the reward details
     */
    function cancel(
        bytes32 intentHash,
        Route memory route,
        bytes32 rewardHash
    ) external;
```

- [ ] **Step 5: Implement `cancel` in `Inbox`**

In `contracts/Inbox.sol` change the types import to `import {Route, Call, TokenAmount, CANCELLED_CLAIMANT} from "./types/Intent.sol";`.

After the `CHAIN_ID` immutable add:

```solidity
    /**
     * @notice Claimant value recorded for cancelled intents
     */
    bytes32 public constant CANCELLED = CANCELLED_CLAIMANT;
```

After `fulfillAndProve` add:

```solidity
    /**
     * @notice Cancels an unfulfilled intent once its route deadline has passed
     * @dev Permissionless: the caller only chooses when, never the outcome
     * @param intentHash The hash of the intent to cancel
     * @param route The route of the intent
     * @param rewardHash The hash of the reward details
     */
    function cancel(
        bytes32 intentHash,
        Route memory route,
        bytes32 rewardHash
    ) external {
        _cancel(intentHash, route, rewardHash);
    }
```

Next to `_fulfill` add:

```solidity
    /**
     * @notice Internal function to cancel an intent
     * @dev Uses the same claimants slot as fulfill, so the two are mutually exclusive
     * @param intentHash The hash of the intent to cancel
     * @param route The route of the intent
     * @param rewardHash The hash of the reward
     */
    function _cancel(
        bytes32 intentHash,
        Route memory route,
        bytes32 rewardHash
    ) internal {
        if (route.portal != address(this)) {
            revert InvalidPortal(route.portal);
        }

        bytes32 routeHash = keccak256(abi.encode(route));
        bytes32 computedIntentHash = keccak256(
            abi.encodePacked(CHAIN_ID, routeHash, rewardHash)
        );
        if (computedIntentHash != intentHash) {
            revert InvalidHash(intentHash);
        }

        // Strictly after the deadline: fulfill is still allowed at route.deadline
        if (block.timestamp <= route.deadline) {
            revert RouteNotExpired(route.deadline);
        }
        if (claimants[intentHash] != bytes32(0)) {
            revert IntentAlreadyFulfilled(intentHash);
        }

        claimants[intentHash] = CANCELLED_CLAIMANT;

        emit IntentCancelled(intentHash);
    }
```

In `_fulfill`, directly after the `ZeroClaimant` check add:

```solidity
        if (claimant == CANCELLED_CLAIMANT) {
            revert ReservedClaimant();
        }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `forge test --root /Users/carlosfebres/dev/eco/eco-routes-proven-cancellation --match-contract 'InboxCancelTest|InboxTest'`
Expected: all PASS.

- [ ] **Step 7: Size gate**

Run: `forge build --root /Users/carlosfebres/dev/eco/eco-routes-proven-cancellation --sizes 2>&1 | grep -E '^\| Portal(Tron)? '`
Expected: both runtime sizes < 24,576. Record the new margin in the task report. If either is ≥ 24,576: STOP and report (Global Constraints).

- [ ] **Step 8: Format, lint, commit**

```bash
W=/Users/carlosfebres/dev/eco/eco-routes-proven-cancellation
npx --prefix $W prettier --write $W/contracts/types/Intent.sol $W/contracts/interfaces/IInbox.sol $W/contracts/Inbox.sol $W/test/core/InboxCancel.t.sol
npx --prefix $W solhint $W/contracts/types/Intent.sol $W/contracts/interfaces/IInbox.sol $W/contracts/Inbox.sol
git -C $W add contracts/types/Intent.sol contracts/interfaces/IInbox.sol contracts/Inbox.sol test/core/InboxCancel.t.sol
git -C $W commit -m "feat(inbox): cancel unfulfilled intents after the route deadline" -m "Claude-Session: https://claude.ai/code/session_01Fs7GU5DoDuKhLo9VDktMXP"
```

---

### Task 2: `cancelAndProve`

**Files:**
- Modify: `contracts/interfaces/IInbox.sol` (after `cancel`)
- Modify: `contracts/Inbox.sol` (after `cancel`)
- Modify: `test/core/InboxCancel.t.sol`

**Interfaces:**
- Consumes: `Inbox._cancel`, `Inbox.prove(address, uint64, bytes32[] memory, bytes memory) public payable nonReentrant`.
- Produces: `IInbox.cancelAndProve(bytes32 intentHash, Route memory route, bytes32 rewardHash, address prover, uint64 sourceChainDomainID, bytes memory data) external payable`.

- [ ] **Step 1: Write the failing tests**

Append to `InboxCancelTest`:

```solidity
    function testCancelAndProveCancelsAndDispatchesSentinel() public {
        (
            Intent memory i,
            bytes32 intentHash,
            bytes32 rewardHash
        ) = _destinationIntent();
        vm.warp(uint256(i.route.deadline) + 1);
        vm.deal(otherPerson, 1 ether);

        vm.prank(otherPerson);
        portal.cancelAndProve{value: 0.1 ether}(
            intentHash,
            i.route,
            rewardHash,
            address(prover),
            uint64(block.chainid),
            "data"
        );

        assertEq(portal.claimants(intentHash), CANCELLED_CLAIMANT);
        assertEq(prover.proveCallCount(), 1);
        assertEq(prover.argIntentHashes(0), intentHash);
        assertEq(prover.argClaimants(0), CANCELLED_CLAIMANT);
        (address sender, uint64 sourceChainId, , uint256 value) = prover.args();
        assertEq(sender, otherPerson);
        assertEq(sourceChainId, uint64(block.chainid));
        assertEq(value, 0.1 ether);
        assertEq(address(portal).balance, 0);
    }

    function testCancelAndProveRevertsBeforeDeadline() public {
        (
            Intent memory i,
            bytes32 intentHash,
            bytes32 rewardHash
        ) = _destinationIntent();
        vm.warp(i.route.deadline);

        vm.expectRevert(
            abi.encodeWithSelector(
                IInbox.RouteNotExpired.selector,
                i.route.deadline
            )
        );
        portal.cancelAndProve(
            intentHash,
            i.route,
            rewardHash,
            address(prover),
            uint64(block.chainid),
            ""
        );
        assertEq(prover.proveCallCount(), 0);
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --root /Users/carlosfebres/dev/eco/eco-routes-proven-cancellation --match-contract InboxCancelTest`
Expected: compilation error — `Member "cancelAndProve" not found`.

- [ ] **Step 3: Implement**

`IInbox.sol`, after `cancel`:

```solidity
    /**
     * @notice Cancels an unfulfilled intent and initiates proving in one transaction
     * @dev See prove for the sourceChainDomainID warning
     * @param intentHash The hash of the intent to cancel
     * @param route Route information for the intent
     * @param rewardHash Hash of the reward details
     * @param prover Address of prover on the destination chain
     * @param sourceChainDomainID Domain ID of the source chain where the intent was created
     * @param data Additional data for message formatting
     */
    function cancelAndProve(
        bytes32 intentHash,
        Route memory route,
        bytes32 rewardHash,
        address prover,
        uint64 sourceChainDomainID,
        bytes memory data
    ) external payable;
```

`Inbox.sol`, after `cancel`:

```solidity
    /**
     * @notice Cancels an unfulfilled intent and initiates proving in one transaction
     * @dev Mirrors fulfillAndProve: prove forwards this contract's balance to the
     *      prover, which refunds any excess to the caller
     * @param intentHash The hash of the intent to cancel
     * @param route The route of the intent
     * @param rewardHash The hash of the reward details
     * @param prover Address of prover on the destination chain
     * @param sourceChainDomainID Domain ID of the source chain where the intent was created
     * @param data Additional data for message formatting
     */
    function cancelAndProve(
        bytes32 intentHash,
        Route memory route,
        bytes32 rewardHash,
        address prover,
        uint64 sourceChainDomainID,
        bytes memory data
    ) external payable {
        _cancel(intentHash, route, rewardHash);

        bytes32[] memory intentHashes = new bytes32[](1);
        intentHashes[0] = intentHash;

        prove(prover, sourceChainDomainID, intentHashes, data);
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `forge test --root /Users/carlosfebres/dev/eco/eco-routes-proven-cancellation --match-contract InboxCancelTest`
Expected: all PASS.

- [ ] **Step 5: Size gate** — same command and stop rule as Task 1 Step 7.

- [ ] **Step 6: Format, lint, commit**

```bash
W=/Users/carlosfebres/dev/eco/eco-routes-proven-cancellation
npx --prefix $W prettier --write $W/contracts/interfaces/IInbox.sol $W/contracts/Inbox.sol $W/test/core/InboxCancel.t.sol
npx --prefix $W solhint $W/contracts/interfaces/IInbox.sol $W/contracts/Inbox.sol
git -C $W add contracts/interfaces/IInbox.sol contracts/Inbox.sol test/core/InboxCancel.t.sol
git -C $W commit -m "feat(inbox): add cancelAndProve" -m "Claude-Session: https://claude.ai/code/session_01Fs7GU5DoDuKhLo9VDktMXP"
```

---

### Task 3: Widen `ProofData` with `Outcome` (behaviour-preserving)

This task changes the `IProver` ABI and every construction/decoder of `ProofData` in one commit, because the struct change breaks compilation everywhere at once. It does **not** handle the sentinel yet; every recorded proof is `Fulfilled`. The whole Foundry suite must stay green.

**Files:**
- Modify: `contracts/interfaces/IProver.sol`
- Modify: `contracts/prover/BaseProver.sol`
- Modify: `contracts/prover/PolymerProver.sol` (loop ~line 135-151; delete `processIntent` ~156-177)
- Modify: `contracts/prover/LocalProver.sol` (`provenIntents` ~70-107)
- Modify: `contracts/prover/AggregatorProver.sol` (`provenIntents` NatSpec + body ~156-322)
- Modify: `scripts/Deploy.s.sol` (`_tryProvenIntentsShape` ~553-592; comment near ~633)
- Modify: `contracts/test/TestProver.sol`, `contracts/test/TestMessageBridgeProver.sol`, `contracts/test/MockDomainProver.sol`, `contracts/test/MockDomainProverDirtyChainId.sol`, `contracts/test/DirtyBitsProver.sol`
- Create: `contracts/test/ShortDynamicProver.sol`, `contracts/test/MockDomainProverLegacyShape.sol`
- Modify: `test/source/IntentSource.t.sol` (lines ~1378, ~1420, ~1643, ~1889)
- Create: `test/prover/ProofOutcome.t.sol`
- Modify: `test/prover/PolymerProver.t.sol`, `test/prover/AggregatorProver.t.sol`, `test/scripts/AggregatorProverMemberValidation.t.sol`

**Interfaces:**
- Produces: `enum IProver.Outcome { None, Fulfilled, Cancelled }`; `struct IProver.ProofData { address claimant; uint64 destination; Outcome outcome; }`; `event IProver.IntentCancellationProven(bytes32 indexed intentHash, uint64 destination)`; `BaseProver._recordProof(bytes32 intentHash, bytes32 claimantBytes, uint64 destination) internal`; `TestProver.addCancelledIntent(bytes32 _hash, uint64 _destination)`; `ShortDynamicProver`; `MockDomainProverLegacyShape`.

- [ ] **Step 1: Write the failing tests**

Create `test/prover/ProofOutcome.t.sol`:

```solidity
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
```

Append to `PolymerProverTest` (`test/prover/PolymerProver.t.sol`):

```solidity
    function testValidateRecordsFulfilledOutcome() public {
        bytes32 intentHash = _hashIntent(intent);
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = intentHash;
        claimants[0] = bytes32(uint256(uint160(claimant)));

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            destinationProver,
            abi.encodePacked(
                PROOF_SELECTOR,
                bytes32(uint256(uint64(block.chainid)))
            ),
            encodeProofsWithChainId(intentHashes, claimants, OPTIMISM_CHAIN_ID)
        );

        polymerProver.validate(abi.encodePacked(uint256(1)));

        assertEq(
            uint8(polymerProver.provenIntents(intentHash).outcome),
            uint8(IProver.Outcome.Fulfilled)
        );
    }

    // A zero claimant used to be written as an empty record; with outcome as the
    // existence signal it would become a permanent Fulfilled proof that blocks
    // refund, so it must be skipped like BaseProver does
    function testValidateSkipsZeroClaimant() public {
        bytes32 intentHash = _hashIntent(intent);
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = intentHash;
        claimants[0] = bytes32(0);

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            destinationProver,
            abi.encodePacked(
                PROOF_SELECTOR,
                bytes32(uint256(uint64(block.chainid)))
            ),
            encodeProofsWithChainId(intentHashes, claimants, OPTIMISM_CHAIN_ID)
        );

        polymerProver.validate(abi.encodePacked(uint256(1)));

        assertEq(
            uint8(polymerProver.provenIntents(intentHash).outcome),
            uint8(IProver.Outcome.None)
        );
    }
```

Append to `AggregatorProverTest` (`test/prover/AggregatorProver.t.sol`; add `import {ShortDynamicProver} from "../../contracts/test/ShortDynamicProver.sol";`):

```solidity
    function test_provenIntents_returnsFulfilledOutcome() public {
        proverB.addProvenIntent(HASH, address(0xBEEF), DESTINATION);

        IProver.ProofData memory proof = aggregator.provenIntents(HASH);
        assertEq(uint8(proof.outcome), uint8(IProver.Outcome.Fulfilled));
    }

    /// @dev A single dynamic `bytes` value of length 32 ABI-encodes to exactly
    ///      96 bytes: offset head 0x20, length 0x20, then the data word. With
    ///      data = 1 it would decode as claimant address(0x20), destination 32,
    ///      outcome Fulfilled — a fabricated proof. The offset-head guard must
    ///      skip it so the honest proverB still wins.
    function test_provenIntents_skipsShortDynamicReturndataMember() public {
        ShortDynamicProver bad = new ShortDynamicProver();
        AggregatorProver agg = new AggregatorProver(
            _pair(address(bad), address(proverB))
        );
        proverB.addProvenIntent(HASH, address(0xBEEF), DESTINATION);

        IProver.ProofData memory proof = agg.provenIntents(HASH);
        assertEq(proof.claimant, address(0xBEEF));
        assertEq(proof.destination, DESTINATION);
    }
```

Append to `AggregatorProverMemberValidationTest` (`test/scripts/AggregatorProverMemberValidation.t.sol`; add `import {MockDomainProverLegacyShape} from "../../contracts/test/MockDomainProverLegacyShape.sol";`):

```solidity
    /// @dev A member built before proven cancellation returns the two-word
    ///      ProofData. The aggregator only reads the three-word shape, so such a
    ///      member would be skipped for every intent forever; reject it at deploy.
    function test_rejectsMemberWithLegacyTwoWordProvenIntents() public {
        MockDomainProverLegacyShape bad = new MockDomainProverLegacyShape();
        Deploy.DeploymentContext memory ctx = _ctxWith(
            _one(_b32(address(bad)))
        );
        ctx.hyperProver = address(bad);

        vm.expectRevert(
            bytes(
                "member provenIntents does not return a well-formed ProofData"
            )
        );
        harness.exposedValidate(ctx);
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --root /Users/carlosfebres/dev/eco/eco-routes-proven-cancellation --match-contract 'ProofOutcomeTest|PolymerProverTest|AggregatorProverTest|AggregatorProverMemberValidationTest'`
Expected: compilation error — `Member "outcome" not found` / `Source "contracts/test/ShortDynamicProver.sol" not found`.

- [ ] **Step 3: Change `IProver`**

Replace the `ProofData` struct in `contracts/interfaces/IProver.sol` with:

```solidity
    /**
     * @notice What a proof says happened to an intent on its destination
     * @dev None means not proven. Existence of a proof is outcome != None.
     */
    enum Outcome {
        None,
        Fulfilled,
        Cancelled
    }

    /**
     * @notice Proof data stored for each proven intent
     * @param claimant Address eligible to claim the intent rewards (zero when Cancelled)
     * @param destination Chain ID where the intent was proven
     * @param outcome Whether the intent was fulfilled or cancelled on its destination
     */
    struct ProofData {
        address claimant;
        uint64 destination;
        Outcome outcome;
    }
```

After the `IntentProven` event add:

```solidity
    /**
     * @notice Emitted when an intent's cancellation is proven
     * @dev Emitted by the Prover on the source chain.
     * @param intentHash Hash of the cancelled intent
     * @param destination Destination chain ID where the intent was cancelled
     */
    event IntentCancellationProven(
        bytes32 indexed intentHash,
        uint64 destination
    );
```

- [ ] **Step 4: `BaseProver` — shared recorder and outcome-based existence**

In `contracts/prover/BaseProver.sol`, update the mapping comment to `Empty struct (outcome None) indicates intent hasn't been proven`, replace the body of the `_processIntentProofs` loop with a call to the new helper, and add the helper:

```solidity
        for (uint256 i = 0; i < numPairs; i++) {
            uint256 offset = i * 64;

            _recordProof(
                bytes32(data[offset:offset + 32]),
                bytes32(data[offset + 32:offset + 64]),
                destination
            );
        }
    }

    /**
     * @notice Records one (intentHash, claimant) pair as a proof
     * @dev Non-EVM and zero claimants are skipped: neither can be paid on this chain.
     *      The first recorded proof wins; a replay or a conflicting redelivery is
     *      skipped with IntentAlreadyProven so batches keep processing.
     * @param intentHash Hash of the proven intent
     * @param claimantBytes Claimant as recorded on the destination
     * @param destination Chain ID where the intent is being proven
     */
    function _recordProof(
        bytes32 intentHash,
        bytes32 claimantBytes,
        uint64 destination
    ) internal {
        if (!claimantBytes.isValidAddress()) return;

        address claimant = claimantBytes.toAddress();
        if (claimant == address(0)) return;

        if (_provenIntents[intentHash].outcome != Outcome.None) {
            emit IntentAlreadyProven(intentHash);
            return;
        }

        _provenIntents[intentHash] = ProofData({
            claimant: claimant,
            destination: destination,
            outcome: Outcome.Fulfilled
        });
        emit IntentProven(intentHash, claimant, destination);
    }
```

In `challengeIntentProof` change the condition to:

```solidity
        // Only challenge if proof exists and destination chain ID doesn't match
        if (proof.outcome != Outcome.None && proof.destination != destination) {
```

- [ ] **Step 5: `PolymerProver` — use the shared recorder**

In `validate`, replace the tail of the pair loop (the `>> 160` skip, `toAddress` and `processIntent` call) so the loop body ends with:

```solidity
            _recordProof(intentHash, claimantBytes, destinationChainId);
        }
    }
```

Delete the `processIntent` function and its `INTERNAL FUNCTIONS - INTENT PROCESSING` section header. Remove `using AddressConverter for bytes32;` only if the compiler reports it unused (it is still used for `emittingContract.toBytes32()` via the `address` using-for; keep that one).

- [ ] **Step 6: `LocalProver` — outcome in every return**

In `provenIntents` update the NatSpec sentence to `...cause provenIntents to return an unproven ProofData (outcome None)...` and change the returns:

```solidity
            return ProofData(address(0), 0, Outcome.None);          // Case 1
                return ProofData(address(0), 0, Outcome.None);      // Case 2, invalid EVM address
            return ProofData(portalClaimant.toAddress(), _CHAIN_ID, Outcome.Fulfilled); // Case 2
            return ProofData(address(this), _CHAIN_ID, Outcome.Fulfilled);              // Case 3
        return ProofData(address(0), 0, Outcome.None);              // Case 4
```

(Keep the existing comments; the trailing `// Case N` labels above are only for locating the lines — do not add them.)

- [ ] **Step 7: `AggregatorProver` — read the three-word tuple**

Replace the body of `provenIntents` with:

```solidity
        bytes32[] memory members = getWhitelist();
        uint256 length = members.length;

        for (uint256 i = 0; i < length; ++i) {
            address member = members[i].toAddress();

            // No code.length guard: the constructor already rejects codeless
            // members, and a staticcall to a codeless address returns success
            // with EMPTY returndata anyway, which the length check rejects.
            (bool success, bytes memory ret) = member.staticcall(
                abi.encodeWithSelector(
                    IProver.provenIntents.selector,
                    intentHash
                )
            );

            if (!success || ret.length != 96) continue;

            // Decode wide first: unlike decoding directly to ProofData, this
            // cannot revert for any 96-byte payload. Dirty high-order bits and
            // out-of-range outcomes are then skipped like a wrong length.
            (
                bytes32 rawClaimant,
                uint256 rawDestination,
                uint256 rawOutcome
            ) = abi.decode(ret, (bytes32, uint256, uint256));

            if (!rawClaimant.isValidAddress() || rawDestination >> 64 != 0) {
                continue;
            }

            // No eligible member can legitimately hold destination 0:
            // MessageBridgeProver rejects chainId 0 at construction and
            // _resolveChainId reverts UnregisteredDomain(0).
            if (rawDestination == 0) continue;

            if (rawOutcome == uint256(Outcome.Fulfilled)) {
                // A single dynamic return value always starts with the ABI
                // offset head 0x20; decoded naively that word would surface as
                // a fabricated claimant address(0x20)
                if (
                    rawClaimant == bytes32(0) ||
                    rawClaimant == bytes32(uint256(0x20))
                ) {
                    continue;
                }

                return
                    ProofData({
                        claimant: rawClaimant.toAddress(),
                        destination: uint64(rawDestination),
                        outcome: Outcome.Fulfilled
                    });
            }
        }

        return
            ProofData({
                claimant: address(0),
                destination: 0,
                outcome: Outcome.None
            });
```

In the `provenIntents` NatSpec, replace every statement about the 64-byte two-word shape with the three-word shape: `A static ProofData{address; uint64; Outcome;} ABI-encodes to exactly 96 bytes, so ret.length == 96 closes the WRONG-SHAPE case`; replace the empty-dynamic paragraph with: `A single dynamic return value (bytes/string/array) of length 32 ABI-encodes to exactly 96 bytes and always begins with the offset head 0x20; the zero-destination and 0x20-claimant guards skip every such payload, and a member built before proven cancellation (64 bytes) is skipped by the length check.` Change `@notice Returns the first member proof with a non-zero claimant` to `@notice Returns the first member proof, in priority order`.

- [ ] **Step 8: `Deploy.s.sol` — probe the three-word shape**

Replace `_tryProvenIntentsShape` with:

```solidity
    /**
     * @notice Probes whether `member.provenIntents(bytes32)` returns a
     *         well-formed 96-byte ProofData tuple
     * @dev Mirrors _tryChainIdByDomain's low-level-staticcall style, for the
     *      same reason: an interface call would ABI-decode-revert in THIS
     *      frame on a wrong-shaped payload, outside any try/catch. A member
     *      whose read function reverts under staticcall, or returns a
     *      wrong-shaped payload (including the pre-cancellation 64-byte
     *      tuple), is silently skipped forever at runtime by
     *      AggregatorProver's own guards — and membership is immutable, so
     *      this is the last point such a member can be caught.
     *
     *      bytes32(0) is an unproven intent hash, so an honest member returns
     *      (0, 0, None) — three zero words, 96 bytes. This checks SHAPE only;
     *      it never requires a proof.
     * @param member Candidate aggregator member address
     * @return ok True if `member` returned three zero words
     */
    function _tryProvenIntentsShape(
        address member
    ) internal view returns (bool ok) {
        (bool success, bytes memory ret) = member.staticcall(
            abi.encodeWithSignature("provenIntents(bytes32)", bytes32(0))
        );
        if (!success || ret.length != 96) {
            return false;
        }
        (uint256 rawClaimant, uint256 rawDestination, uint256 rawOutcome) = abi
            .decode(ret, (uint256, uint256, uint256));
        // Strict zero-equality, not a range check: it also rejects any single
        // dynamic return value, whose first word is the offset head 0x20.
        return rawClaimant == 0 && rawDestination == 0 && rawOutcome == 0;
    }
```

Near line ~633, the comment that says PolymerProver records proofs "through its own processIntent" becomes "through BaseProver._recordProof".

- [ ] **Step 9: Update test mocks**

`contracts/test/TestProver.sol` — both `addProvenIntent` and `addProvenIntentWithChain` bodies become:

```solidity
        _provenIntents[_hash] = ProofData({
            claimant: _claimant,
            destination: _destination,
            // Keep the pre-outcome meaning: a zero claimant is "not proven"
            outcome: _claimant == address(0) ? Outcome.None : Outcome.Fulfilled
        });
```

and add after them:

```solidity
    /**
     * @notice Helper to manually add a proven cancellation for testing
     */
    function addCancelledIntent(bytes32 _hash, uint64 _destination) public {
        _provenIntents[_hash] = ProofData({
            claimant: address(0),
            destination: _destination,
            outcome: Outcome.Cancelled
        });
    }
```

`contracts/test/TestMessageBridgeProver.sol` — `addProvenIntent` body gets the same `outcome:` line as TestProver.

`contracts/test/MockDomainProver.sol` and `contracts/test/MockDomainProverDirtyChainId.sol`:

```solidity
        return
            IProver.ProofData({
                claimant: address(0),
                destination: 0,
                outcome: IProver.Outcome.None
            });
```

`contracts/test/DirtyBitsProver.sol` — return 96 dirty bytes so the range check (not the length check) is what skips it; update the NatSpec "64 bytes" to "96 bytes":

```solidity
    function provenIntents(
        bytes32
    ) external pure returns (bytes32, bytes32, bytes32) {
        bytes32 word = bytes32(type(uint256).max);
        assembly {
            mstore(0x00, word)
            mstore(0x20, word)
            mstore(0x40, word)
            return(0x00, 0x60)
        }
    }
```

Create `contracts/test/ShortDynamicProver.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title ShortDynamicProver
 * @notice Test prover whose provenIntents() returns a single 32-byte `bytes`
 *         value, which ABI-encodes to exactly 96 bytes: offset head 0x20,
 *         length 0x20, then the data word (here 1)
 * @dev Verifies AggregatorProver.provenIntents does not surface the offset
 *      head as a fabricated claimant address(0x20) with destination 32 and
 *      outcome Fulfilled.
 */
contract ShortDynamicProver {
    function provenIntents(bytes32) external pure returns (bytes memory) {
        return abi.encodePacked(uint256(1));
    }

    function challengeIntentProof(uint64, bytes32, bytes32) external pure {}
}
```

Create `contracts/test/MockDomainProverLegacyShape.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title MockDomainProverLegacyShape
 * @notice Stand-in exposing `chainIdByDomain` and the pre-cancellation
 *         two-word provenIntents return (address claimant, uint64 destination)
 * @dev Used to test that Deploy.validateAggregatorProverMembers rejects
 *      members that AggregatorProver would skip forever.
 */
contract MockDomainProverLegacyShape {
    function chainIdByDomain(uint64) external pure returns (uint64) {
        return 0;
    }

    function provenIntents(bytes32) external pure returns (address, uint64) {
        return (address(0), 0);
    }
}
```

`test/source/IntentSource.t.sol` — each `abi.encode(IProver.ProofData(<claimant>, CHAIN_ID))` (4 sites) gains a third argument `IProver.Outcome.Fulfilled`, e.g. `abi.encode(IProver.ProofData(claimant, CHAIN_ID, IProver.Outcome.Fulfilled))`. The zero-claimant site (`testWithdrawRejectsZeroClaimant`) also uses `Fulfilled` so it keeps exercising `InvalidClaimant`.

- [ ] **Step 10: Build and run the full Foundry suite**

Run: `forge test --root /Users/carlosfebres/dev/eco/eco-routes-proven-cancellation`
Expected: all PASS, including the new tests and the untouched ones (`test_gas_worstCaseFanOutAtMaxMembers` must stay under its 60,000-gas tripwire; if it fails, report the measured number rather than raising the tripwire).
Then grep for any construction you missed: `grep -rn -E 'ProofData\((address|claimant|portalClaimant)' /Users/carlosfebres/dev/eco/eco-routes-proven-cancellation/contracts /Users/carlosfebres/dev/eco/eco-routes-proven-cancellation/test` — every hit must pass three arguments.

- [ ] **Step 11: Run the Hardhat/TS suites (typechain regenerates)**

Run: `yarn --cwd /Users/carlosfebres/dev/eco/eco-routes-proven-cancellation test:hardhat` and `yarn --cwd /Users/carlosfebres/dev/eco/eco-routes-proven-cancellation test:ts`
Expected: PASS (TS tests read `.claimant`/`.destination` by name, so the extra field is transparent).

- [ ] **Step 12: Size gate** — Task 1 Step 7 command and stop rule.

- [ ] **Step 13: Format, lint, commit**

```bash
W=/Users/carlosfebres/dev/eco/eco-routes-proven-cancellation
F="contracts/interfaces/IProver.sol contracts/prover/BaseProver.sol contracts/prover/PolymerProver.sol contracts/prover/LocalProver.sol contracts/prover/AggregatorProver.sol scripts/Deploy.s.sol contracts/test/TestProver.sol contracts/test/TestMessageBridgeProver.sol contracts/test/MockDomainProver.sol contracts/test/MockDomainProverDirtyChainId.sol contracts/test/DirtyBitsProver.sol contracts/test/ShortDynamicProver.sol contracts/test/MockDomainProverLegacyShape.sol test/source/IntentSource.t.sol test/prover/ProofOutcome.t.sol test/prover/PolymerProver.t.sol test/prover/AggregatorProver.t.sol test/scripts/AggregatorProverMemberValidation.t.sol"
for f in $F; do npx --prefix $W prettier --write $W/$f; done
npx --prefix $W solhint $W/contracts/interfaces/IProver.sol $W/contracts/prover/BaseProver.sol $W/contracts/prover/PolymerProver.sol $W/contracts/prover/LocalProver.sol $W/contracts/prover/AggregatorProver.sol
git -C $W add $F
git -C $W commit -m "feat(prover): record a proof outcome alongside the claimant" -m "Claude-Session: https://claude.ai/code/session_01Fs7GU5DoDuKhLo9VDktMXP"
```

---

### Task 4: Map the sentinel to a Cancelled proof (message-bridge provers and Polymer)

**Files:**
- Modify: `contracts/prover/BaseProver.sol` (`_recordProof`)
- Modify: `test/prover/ProofOutcome.t.sol`, `test/prover/PolymerProver.t.sol`

**Interfaces:**
- Consumes: `CANCELLED_CLAIMANT`, `IProver.Outcome`, `IProver.IntentCancellationProven`, `TestProver.prove`.
- Produces: `_recordProof` records `{address(0), destination, Cancelled}` for `claimantBytes == CANCELLED_CLAIMANT`. Hyper, LayerZero, Meta, CCIP (via `_processIntentProofs`) and Polymer (via `validate`) all inherit it.

- [ ] **Step 1: Write the failing tests**

Append to `ProofOutcomeTest` (add `import {CANCELLED_CLAIMANT} from "../../contracts/types/Intent.sol";`):

```solidity
    function testRecordsCancelledOutcome() public {
        bytes32 intentHash = _hashIntent(intent);

        vm.expectEmit(true, true, true, true, address(prover));
        emit IProver.IntentCancellationProven(intentHash, CHAIN_ID);
        prover.prove(
            address(this),
            CHAIN_ID,
            _message(CHAIN_ID, intentHash, CANCELLED_CLAIMANT),
            ""
        );

        IProver.ProofData memory proof = prover.provenIntents(intentHash);
        assertEq(proof.claimant, address(0));
        assertEq(proof.destination, CHAIN_ID);
        assertEq(uint8(proof.outcome), uint8(IProver.Outcome.Cancelled));
    }

    function testCancelledThenFulfilledKeepsFirstRecord() public {
        bytes32 intentHash = _hashIntent(intent);
        prover.prove(
            address(this),
            CHAIN_ID,
            _message(CHAIN_ID, intentHash, CANCELLED_CLAIMANT),
            ""
        );

        vm.expectEmit(true, true, true, true, address(prover));
        emit IProver.IntentAlreadyProven(intentHash);
        prover.prove(
            address(this),
            CHAIN_ID,
            _message(CHAIN_ID, intentHash, bytes32(uint256(uint160(claimant)))),
            ""
        );

        assertEq(
            uint8(prover.provenIntents(intentHash).outcome),
            uint8(IProver.Outcome.Cancelled)
        );
    }

    function testFulfilledThenCancelledKeepsFirstRecord() public {
        bytes32 intentHash = _hashIntent(intent);
        prover.prove(
            address(this),
            CHAIN_ID,
            _message(CHAIN_ID, intentHash, bytes32(uint256(uint160(claimant)))),
            ""
        );

        vm.expectEmit(true, true, true, true, address(prover));
        emit IProver.IntentAlreadyProven(intentHash);
        prover.prove(
            address(this),
            CHAIN_ID,
            _message(CHAIN_ID, intentHash, CANCELLED_CLAIMANT),
            ""
        );

        IProver.ProofData memory proof = prover.provenIntents(intentHash);
        assertEq(proof.claimant, claimant);
        assertEq(uint8(proof.outcome), uint8(IProver.Outcome.Fulfilled));
    }

    function testChallengeDeletesWrongDestinationCancelledProof() public {
        bytes32 intentHash = _hashIntent(intent);
        uint64 wrongDestination = 2;
        prover.prove(
            address(this),
            wrongDestination,
            _message(wrongDestination, intentHash, CANCELLED_CLAIMANT),
            ""
        );

        vm.expectEmit(true, true, true, true, address(prover));
        emit IProver.IntentProofInvalidated(intentHash);
        prover.challengeIntentProof(
            intent.destination,
            keccak256(abi.encode(intent.route)),
            keccak256(abi.encode(intent.reward))
        );

        assertEq(
            uint8(prover.provenIntents(intentHash).outcome),
            uint8(IProver.Outcome.None)
        );
    }
```

Append to `PolymerProverTest` (add the same `CANCELLED_CLAIMANT` import):

```solidity
    function testValidateRecordsCancelledOutcome() public {
        bytes32 intentHash = _hashIntent(intent);
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = intentHash;
        claimants[0] = CANCELLED_CLAIMANT;

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            destinationProver,
            abi.encodePacked(
                PROOF_SELECTOR,
                bytes32(uint256(uint64(block.chainid)))
            ),
            encodeProofsWithChainId(intentHashes, claimants, OPTIMISM_CHAIN_ID)
        );

        _expectEmit();
        emit IProver.IntentCancellationProven(intentHash, OPTIMISM_CHAIN_ID);
        polymerProver.validate(abi.encodePacked(uint256(1)));

        IProver.ProofData memory proof = polymerProver.provenIntents(intentHash);
        assertEq(proof.claimant, address(0));
        assertEq(proof.destination, OPTIMISM_CHAIN_ID);
        assertEq(uint8(proof.outcome), uint8(IProver.Outcome.Cancelled));
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --root /Users/carlosfebres/dev/eco/eco-routes-proven-cancellation --match-contract 'ProofOutcomeTest|PolymerProverTest'`
Expected: the four new Cancelled tests FAIL (outcome None — the sentinel is skipped as a non-EVM address).

- [ ] **Step 3: Implement**

In `BaseProver.sol` add `import {CANCELLED_CLAIMANT} from "../types/Intent.sol";` and replace `_recordProof` with:

```solidity
    /**
     * @notice Records one (intentHash, claimant) pair as a proof
     * @dev The CANCELLED sentinel records a Cancelled proof with no claimant.
     *      Other non-EVM and zero claimants are skipped: neither can be paid on
     *      this chain. The first recorded proof wins; a replay or a conflicting
     *      redelivery is skipped with IntentAlreadyProven so batches keep going.
     * @param intentHash Hash of the proven intent
     * @param claimantBytes Claimant as recorded on the destination
     * @param destination Chain ID where the intent is being proven
     */
    function _recordProof(
        bytes32 intentHash,
        bytes32 claimantBytes,
        uint64 destination
    ) internal {
        address claimant;
        Outcome outcome;

        if (claimantBytes == CANCELLED_CLAIMANT) {
            outcome = Outcome.Cancelled;
        } else {
            if (!claimantBytes.isValidAddress()) return;

            claimant = claimantBytes.toAddress();
            if (claimant == address(0)) return;

            outcome = Outcome.Fulfilled;
        }

        if (_provenIntents[intentHash].outcome != Outcome.None) {
            emit IntentAlreadyProven(intentHash);
            return;
        }

        _provenIntents[intentHash] = ProofData({
            claimant: claimant,
            destination: destination,
            outcome: outcome
        });

        if (outcome == Outcome.Cancelled) {
            emit IntentCancellationProven(intentHash, destination);
        } else {
            emit IntentProven(intentHash, claimant, destination);
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `forge test --root /Users/carlosfebres/dev/eco/eco-routes-proven-cancellation --match-path 'test/prover/*'`
Expected: all PASS.

- [ ] **Step 5: Format, lint, commit**

```bash
W=/Users/carlosfebres/dev/eco/eco-routes-proven-cancellation
npx --prefix $W prettier --write $W/contracts/prover/BaseProver.sol $W/test/prover/ProofOutcome.t.sol $W/test/prover/PolymerProver.t.sol
npx --prefix $W solhint $W/contracts/prover/BaseProver.sol
git -C $W add contracts/prover/BaseProver.sol test/prover/ProofOutcome.t.sol test/prover/PolymerProver.t.sol
git -C $W commit -m "feat(prover): record proven cancellations from the CANCELLED sentinel" -m "Claude-Session: https://claude.ai/code/session_01Fs7GU5DoDuKhLo9VDktMXP"
```

---

### Task 5: `LocalProver` reports cancelled same-chain intents

**Files:**
- Modify: `contracts/prover/LocalProver.sol` (`provenIntents`)
- Modify: `test/prover/LocalProver.t.sol`

**Interfaces:**
- Consumes: `Portal.cancel`, `CANCELLED_CLAIMANT`.
- Produces: `LocalProver.provenIntents(h)` returns `{address(0), CHAIN_ID, Cancelled}` when `claimants[h] == CANCELLED_CLAIMANT`.

- [ ] **Step 1: Write the failing test**

Append to `LocalProverTest`:

```solidity
    function test_provenIntents_ReportsCancelledIntent() public {
        Intent memory _intent = _createIntent(
            address(localProver),
            REWARD_AMOUNT,
            0
        );
        (bytes32 intentHash, ) = _publishAndFundIntent(_intent);

        vm.warp(uint256(_intent.route.deadline) + 1);
        portal.cancel(
            intentHash,
            _intent.route,
            keccak256(abi.encode(_intent.reward))
        );

        IProver.ProofData memory proof = localProver.provenIntents(intentHash);
        assertEq(proof.claimant, address(0));
        assertEq(proof.destination, CHAIN_ID);
        assertEq(uint8(proof.outcome), uint8(IProver.Outcome.Cancelled));
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `forge test --root /Users/carlosfebres/dev/eco/eco-routes-proven-cancellation --match-test test_provenIntents_ReportsCancelledIntent`
Expected: FAIL — outcome None, destination 0 (the sentinel currently hits the invalid-address griefing branch).

- [ ] **Step 3: Implement**

Add `CANCELLED_CLAIMANT` to the existing `Intent.sol` import in `LocalProver.sol`. In `provenIntents`, directly after reading `portalClaimant`, add:

```solidity
        // Cancelled on this chain after the route deadline: a proven cancellation
        if (portalClaimant == CANCELLED_CLAIMANT) {
            return ProofData(address(0), _CHAIN_ID, Outcome.Cancelled);
        }
```

Update the function NatSpec with one line: `Returns a Cancelled proof when the Portal recorded the CANCELLED sentinel.`

- [ ] **Step 4: Run to verify it passes**

Run: `forge test --root /Users/carlosfebres/dev/eco/eco-routes-proven-cancellation --match-contract LocalProverTest`
Expected: all PASS.

- [ ] **Step 5: Format, lint, commit**

```bash
W=/Users/carlosfebres/dev/eco/eco-routes-proven-cancellation
npx --prefix $W prettier --write $W/contracts/prover/LocalProver.sol $W/test/prover/LocalProver.t.sol
npx --prefix $W solhint $W/contracts/prover/LocalProver.sol
git -C $W add contracts/prover/LocalProver.sol test/prover/LocalProver.t.sol
git -C $W commit -m "feat(prover): report cancelled same-chain intents from LocalProver" -m "Claude-Session: https://claude.ai/code/session_01Fs7GU5DoDuKhLo9VDktMXP"
```

---

### Task 6: `AggregatorProver` returns Cancelled member proofs

**Files:**
- Modify: `contracts/prover/AggregatorProver.sol` (`provenIntents`)
- Modify: `test/prover/AggregatorProver.t.sol`

**Interfaces:**
- Consumes: `TestProver.addCancelledIntent`.
- Produces: first member (priority order) with a well-formed Fulfilled **or** Cancelled proof wins; a Cancelled tuple must carry claimant 0.

- [ ] **Step 1: Write the failing tests**

Append to `AggregatorProverTest`:

```solidity
    function test_provenIntents_returnsCancelledMemberProof() public {
        proverB.addCancelledIntent(HASH, DESTINATION);

        IProver.ProofData memory proof = aggregator.provenIntents(HASH);
        assertEq(proof.claimant, address(0));
        assertEq(proof.destination, DESTINATION);
        assertEq(uint8(proof.outcome), uint8(IProver.Outcome.Cancelled));
    }

    function test_provenIntents_firstMemberWinsCancelledOverFulfilled() public {
        proverA.addCancelledIntent(HASH, DESTINATION);
        proverB.addProvenIntent(HASH, address(0xB0B), DESTINATION);

        assertEq(
            uint8(aggregator.provenIntents(HASH).outcome),
            uint8(IProver.Outcome.Cancelled)
        );
    }

    function test_provenIntents_firstMemberWinsFulfilledOverCancelled() public {
        proverA.addProvenIntent(HASH, address(0xA11CE), DESTINATION);
        proverB.addCancelledIntent(HASH, DESTINATION);

        IProver.ProofData memory proof = aggregator.provenIntents(HASH);
        assertEq(proof.claimant, address(0xA11CE));
        assertEq(uint8(proof.outcome), uint8(IProver.Outcome.Fulfilled));
    }

    function test_provenIntents_skipsCancelledTupleWithClaimant() public {
        vm.mockCall(
            address(proverA),
            abi.encodeWithSelector(IProver.provenIntents.selector, HASH),
            abi.encode(address(0xBAD), DESTINATION, uint256(2))
        );
        proverB.addProvenIntent(HASH, address(0xBEEF), DESTINATION);

        assertEq(aggregator.provenIntents(HASH).claimant, address(0xBEEF));
    }

    function test_provenIntents_skipsOutOfRangeOutcome() public {
        vm.mockCall(
            address(proverA),
            abi.encodeWithSelector(IProver.provenIntents.selector, HASH),
            abi.encode(address(0xBAD), DESTINATION, uint256(3))
        );
        proverB.addProvenIntent(HASH, address(0xBEEF), DESTINATION);

        assertEq(aggregator.provenIntents(HASH).claimant, address(0xBEEF));
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `forge test --root /Users/carlosfebres/dev/eco/eco-routes-proven-cancellation --match-contract AggregatorProverTest`
Expected: `returnsCancelledMemberProof` and `firstMemberWinsCancelledOverFulfilled` FAIL (Cancelled tuples are skipped); the others PASS already (they pin the guards).

- [ ] **Step 3: Implement**

In `provenIntents`, after the `Fulfilled` block (before the loop's closing brace) add:

```solidity
            // A cancellation carries no claimant; any claimant bits mean a
            // malformed member, which is skipped like any other bad shape
            if (
                rawOutcome == uint256(Outcome.Cancelled) &&
                rawClaimant == bytes32(0)
            ) {
                return
                    ProofData({
                        claimant: address(0),
                        destination: uint64(rawDestination),
                        outcome: Outcome.Cancelled
                    });
            }
```

Update the NatSpec's KNOWN LIMITATION paragraph: a wrong-destination Cancelled entry shadows exactly like a wrong-destination Fulfilled one, and `withdraw`'s challenge forwarding clears either.

- [ ] **Step 4: Run to verify they pass**

Run: `forge test --root /Users/carlosfebres/dev/eco/eco-routes-proven-cancellation --match-contract 'AggregatorProver'`
Expected: all PASS, including `AggregatorProverIntegration` and the gas tripwire.

- [ ] **Step 5: Format, lint, commit**

```bash
W=/Users/carlosfebres/dev/eco/eco-routes-proven-cancellation
npx --prefix $W prettier --write $W/contracts/prover/AggregatorProver.sol $W/test/prover/AggregatorProver.t.sol
npx --prefix $W solhint $W/contracts/prover/AggregatorProver.sol
git -C $W add contracts/prover/AggregatorProver.sol test/prover/AggregatorProver.t.sol
git -C $W commit -m "feat(prover): surface cancelled member proofs from AggregatorProver" -m "Claude-Session: https://claude.ai/code/session_01Fs7GU5DoDuKhLo9VDktMXP"
```

---

### Task 7: `IntentSource` fast-path refund and withdraw guard

**Files:**
- Modify: `contracts/interfaces/IIntentSource.sol` (errors block, after `InvalidClaimant`)
- Modify: `contracts/IntentSource.sol` (`withdraw` ~449-484, `_validateRefund` ~865-899, `_validateWithdraw` ~907-920)
- Create: `test/source/IntentSourceCancellation.t.sol`

**Interfaces:**
- Consumes: `IProver.Outcome`, `TestProver.addCancelledIntent`, `TestProver.addProvenIntent`.
- Produces: `error IIntentSource.CancelledIntent(bytes32 intentHash)`; `_validateWithdraw(bytes32 intentHash, IProver.ProofData memory proof) internal view`.

- [ ] **Step 1: Write the failing tests**

Create `test/source/IntentSourceCancellation.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BaseTest} from "../BaseTest.sol";
import {IProver} from "../../contracts/interfaces/IProver.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";

contract IntentSourceCancellationTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _mintAndApprove(creator, MINT_AMOUNT);
        _fundUserNative(creator, 10 ether);
    }

    function _routeHash() internal view returns (bytes32) {
        return keccak256(abi.encode(intent.route));
    }

    function testRefundBeforeRewardDeadlineWithProvenCancellation() public {
        _publishAndFund(intent, false);
        bytes32 intentHash = _hashIntent(intent);
        prover.addCancelledIntent(intentHash, CHAIN_ID);
        uint256 creatorA = tokenA.balanceOf(creator);
        uint256 creatorB = tokenB.balanceOf(creator);
        assertLt(block.timestamp, intent.reward.deadline);

        vm.expectEmit(true, true, true, true, address(portal));
        emit IIntentSource.IntentRefunded(intentHash, creator);
        vm.prank(otherPerson);
        intentSource.refund(intent.destination, _routeHash(), intent.reward);

        assertEq(tokenA.balanceOf(creator), creatorA + MINT_AMOUNT);
        assertEq(tokenB.balanceOf(creator), creatorB + MINT_AMOUNT * 2);
        assertEq(
            uint256(intentSource.getRewardStatus(intentHash)),
            uint256(IIntentSource.Status.Refunded)
        );
    }

    function testRefundToBeforeRewardDeadlineWithProvenCancellation() public {
        _publishAndFund(intent, false);
        bytes32 intentHash = _hashIntent(intent);
        prover.addCancelledIntent(intentHash, CHAIN_ID);
        address refundee = makeAddr("refundee");

        vm.prank(creator);
        intentSource.refundTo(
            intent.destination,
            _routeHash(),
            intent.reward,
            refundee
        );

        assertEq(tokenA.balanceOf(refundee), MINT_AMOUNT);
    }

    function testCancellationOnWrongDestinationFallsBackToDeadline() public {
        _publishAndFund(intent, false);
        bytes32 intentHash = _hashIntent(intent);
        prover.addCancelledIntent(intentHash, CHAIN_ID + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.InvalidStatusForRefund.selector,
                IIntentSource.Status.Funded,
                block.timestamp,
                intent.reward.deadline
            )
        );
        intentSource.refund(intent.destination, _routeHash(), intent.reward);

        vm.warp(intent.reward.deadline);
        intentSource.refund(intent.destination, _routeHash(), intent.reward);
        assertEq(tokenA.balanceOf(creator), MINT_AMOUNT);
    }

    function testWithdrawRevertsOnProvenCancellation() public {
        _publishAndFund(intent, false);
        bytes32 intentHash = _hashIntent(intent);
        prover.addCancelledIntent(intentHash, CHAIN_ID);

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.CancelledIntent.selector,
                intentHash
            )
        );
        intentSource.withdraw(intent.destination, _routeHash(), intent.reward);
    }

    function testWithdrawChallengesWrongDestinationCancellation() public {
        _publishAndFund(intent, false);
        bytes32 intentHash = _hashIntent(intent);
        prover.addCancelledIntent(intentHash, CHAIN_ID + 1);

        intentSource.withdraw(intent.destination, _routeHash(), intent.reward);

        assertEq(
            uint8(prover.provenIntents(intentHash).outcome),
            uint8(IProver.Outcome.None)
        );
        assertTrue(intentSource.isIntentFunded(intent));
    }

    function testFulfilledProofStillBlocksEarlyRefund() public {
        _publishAndFund(intent, false);
        bytes32 intentHash = _hashIntent(intent);
        prover.addProvenIntent(intentHash, claimant, CHAIN_ID);

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.IntentNotClaimed.selector,
                intentHash
            )
        );
        intentSource.refund(intent.destination, _routeHash(), intent.reward);
    }

    function testNoProofStillRequiresRewardDeadline() public {
        _publishAndFund(intent, false);

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.InvalidStatusForRefund.selector,
                IIntentSource.Status.Funded,
                block.timestamp,
                intent.reward.deadline
            )
        );
        intentSource.refund(intent.destination, _routeHash(), intent.reward);
    }

    function testRefundedCancellationCannotBeWithdrawn() public {
        _publishAndFund(intent, false);
        bytes32 intentHash = _hashIntent(intent);
        prover.addCancelledIntent(intentHash, CHAIN_ID);
        intentSource.refund(intent.destination, _routeHash(), intent.reward);

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.InvalidStatusForWithdrawal.selector,
                IIntentSource.Status.Refunded
            )
        );
        intentSource.withdraw(intent.destination, _routeHash(), intent.reward);
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `forge test --root /Users/carlosfebres/dev/eco/eco-routes-proven-cancellation --match-contract IntentSourceCancellationTest`
Expected: compilation error — `Member "CancelledIntent" not found`.

- [ ] **Step 3: Add the error**

In `IIntentSource.sol`, after `InvalidClaimant`:

```solidity
    /**
     * @notice The intent was proven cancelled, so its reward can only be refunded
     * @param intentHash Hash of the cancelled intent
     */
    error CancelledIntent(bytes32 intentHash);
```

(The name is not `IntentCancelled` because `Portal` also inherits the `IInbox.IntentCancelled` event, and Solidity rejects an event and an error with the same identifier.)

- [ ] **Step 4: Implement in `IntentSource`**

`withdraw` becomes:

```solidity
        IProver.ProofData memory proof = IProver(reward.prover).provenIntents(
            intentHash
        );

        // If the intent has been proven on a different chain, challenge the proof
        if (
            proof.outcome != IProver.Outcome.None &&
            proof.destination != destination
        ) {
            // Challenge the proof and emit event
            IProver(reward.prover).challengeIntentProof(
                destination,
                routeHash,
                rewardHash
            );

            return;
        }

        _validateWithdraw(intentHash, proof);
        rewardStatuses[intentHash] = Status.Withdrawn;

        IVault vault = IVault(_getOrDeployVault(intentHash));
        vault.withdraw(reward, proof.claimant);

        emit IntentWithdrawn(intentHash, proof.claimant);
```

In `_validateRefund`, replace everything after the proof read with:

```solidity
        // A proven cancellation on the intended destination refunds immediately
        if (
            proof.outcome == IProver.Outcome.Cancelled &&
            proof.destination == destination
        ) {
            return;
        }

        // Anything short of a fulfillment proven on this destination falls back
        // to the reward deadline
        if (
            proof.outcome != IProver.Outcome.Fulfilled ||
            proof.claimant == address(0) ||
            proof.destination != destination
        ) {
            if (block.timestamp < reward.deadline) {
                revert InvalidStatusForRefund(
                    status,
                    block.timestamp,
                    reward.deadline
                );
            }

            return;
        }

        if (status == Status.Initial || status == Status.Funded) {
            revert IntentNotClaimed(intentHash);
        }
```

Replace `_validateWithdraw` with:

```solidity
    /**
     * @notice Validates that vault can be withdrawn from and the proof pays a claimant
     * @dev Allows withdrawal from Initial or Funded status; a cancelled or claimant-less
     *      proof never pays out
     * @param intentHash Hash of the intent
     * @param proof Proof read from the intent's prover
     */
    function _validateWithdraw(
        bytes32 intentHash,
        IProver.ProofData memory proof
    ) internal view {
        Status status = rewardStatuses[intentHash];

        if (status != Status.Initial && status != Status.Funded) {
            revert InvalidStatusForWithdrawal(status);
        }

        if (proof.outcome == IProver.Outcome.Cancelled) {
            revert CancelledIntent(intentHash);
        }

        if (
            proof.outcome != IProver.Outcome.Fulfilled ||
            proof.claimant == address(0)
        ) {
            revert InvalidClaimant();
        }
    }
```

- [ ] **Step 5: Run to verify they pass**

Run: `forge test --root /Users/carlosfebres/dev/eco/eco-routes-proven-cancellation --match-path 'test/source/*'`
Expected: all PASS (existing `IntentSourceTest` included).

- [ ] **Step 6: Full suite + size gate**

Run: `forge test --root /Users/carlosfebres/dev/eco/eco-routes-proven-cancellation` — all PASS. Then the Task 1 Step 7 size gate.

- [ ] **Step 7: Format, lint, commit**

```bash
W=/Users/carlosfebres/dev/eco/eco-routes-proven-cancellation
npx --prefix $W prettier --write $W/contracts/interfaces/IIntentSource.sol $W/contracts/IntentSource.sol $W/test/source/IntentSourceCancellation.t.sol
npx --prefix $W solhint $W/contracts/interfaces/IIntentSource.sol $W/contracts/IntentSource.sol
git -C $W add contracts/interfaces/IIntentSource.sol contracts/IntentSource.sol test/source/IntentSourceCancellation.t.sol
git -C $W commit -m "feat(portal): refund proven cancellations before the reward deadline" -m "Claude-Session: https://claude.ai/code/session_01Fs7GU5DoDuKhLo9VDktMXP"
```

---

### Task 8: (removed) Legacy two-word provers

Decided 2026-09-24 (spec D9): the new `IntentSource` reads provers with the plain typed
`IProver(reward.prover).provenIntents` call. A `reward.prover` that returns the pre-change two-word
`ProofData` makes withdraw and refund revert for that intent; this freeze risk is accepted. Do not add a
tolerant reader. Task numbering is kept so cross-references stay stable.

### Task 9: Per-prover cancellation coverage

Tests only: each concrete receive path records a Cancelled proof from the sentinel, and each source-side prover type drives a fast refund and blocks withdraw.

**Files:**
- Modify: `test/prover/HyperProver.t.sol`, `test/prover/LayerZeroProver.t.sol`, `test/prover/MetaProver.t.sol`, `test/prover/CCIPProver.t.sol`, `test/prover/LocalProver.t.sol`

**Interfaces:**
- Consumes: each file's existing `_formatMessageWithChainId` helper and setUp fixtures; `CANCELLED_CLAIMANT`; `IProver.Outcome`.

- [ ] **Step 1: Write the tests**

In each of the four bridge test files add `import {CANCELLED_CLAIMANT} from "../../contracts/types/Intent.sol";`.

`HyperProverTest`:

```solidity
    function testHandleRecordsCancelledOutcome() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        claimants[0] = CANCELLED_CLAIMANT;

        vm.prank(address(mailbox));
        hyperProver.handle(
            1,
            bytes32(uint256(uint160(whitelistedProver))),
            _formatMessageWithChainId(1, intentHashes, claimants)
        );

        IProver.ProofData memory proof = hyperProver.provenIntents(
            intentHashes[0]
        );
        assertEq(proof.claimant, address(0));
        assertEq(proof.destination, CHAIN_ID);
        assertEq(uint8(proof.outcome), uint8(IProver.Outcome.Cancelled));
    }

    function testHandleCancelledRedeliveryKeepsFulfilledProof() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        claimants[0] = bytes32(uint256(uint160(claimant)));
        vm.prank(address(mailbox));
        hyperProver.handle(
            1,
            bytes32(uint256(uint160(whitelistedProver))),
            _formatMessageWithChainId(1, intentHashes, claimants)
        );

        claimants[0] = CANCELLED_CLAIMANT;
        vm.prank(address(mailbox));
        hyperProver.handle(
            1,
            bytes32(uint256(uint160(whitelistedProver))),
            _formatMessageWithChainId(1, intentHashes, claimants)
        );

        IProver.ProofData memory proof = hyperProver.provenIntents(
            intentHashes[0]
        );
        assertEq(proof.claimant, claimant);
        assertEq(uint8(proof.outcome), uint8(IProver.Outcome.Fulfilled));
    }

    function testRefundsBeforeDeadlineOnHyperProvenCancellation() public {
        // setUp already minted and approved MINT_AMOUNT for creator
        reward.prover = address(hyperProver);
        intent.reward = reward;
        _publishAndFund(intent, false);

        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        claimants[0] = CANCELLED_CLAIMANT;
        vm.prank(address(mailbox));
        hyperProver.handle(
            1,
            bytes32(uint256(uint160(whitelistedProver))),
            _formatMessageWithChainId(1, intentHashes, claimants)
        );

        intentSource.refund(
            intent.destination,
            keccak256(abi.encode(intent.route)),
            intent.reward
        );
        assertEq(tokenA.balanceOf(creator), MINT_AMOUNT);
    }
```

`LayerZeroProverTest`:

```solidity
    function test_lzReceive_recordsCancelledOutcome() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        intentHashes[0] = keccak256("intent");
        bytes32[] memory claimants = new bytes32[](1);
        claimants[0] = CANCELLED_CLAIMANT;

        ILayerZeroReceiver.Origin memory origin = ILayerZeroReceiver.Origin({
            srcEid: uint32(SOURCE_CHAIN_ID),
            sender: SOURCE_PROVER,
            nonce: 1
        });

        vm.prank(address(endpoint));
        lzProver.lzReceive(
            origin,
            bytes32(0),
            _formatMessageWithChainId(SOURCE_CHAIN_ID, intentHashes, claimants),
            address(0),
            ""
        );

        IProver.ProofData memory proof = lzProver.provenIntents(
            intentHashes[0]
        );
        assertEq(proof.destination, uint64(SOURCE_CHAIN_ID));
        assertEq(uint8(proof.outcome), uint8(IProver.Outcome.Cancelled));
    }
```

(`IProver` is already imported in this file; existing tests spell the type `LayerZeroProver.ProofData`, which is the same struct.)

`MetaProverTest`:

```solidity
    function testHandleRecordsCancelledOutcome() public {
        bytes32 intentHash = _hashIntent(intent);
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = intentHash;
        claimants[0] = CANCELLED_CLAIMANT;

        vm.prank(address(metaRouter));
        metaProver.handle(
            uint32(block.chainid),
            bytes32(uint256(uint160(address(prover)))),
            _formatMessageWithChainId(block.chainid, intentHashes, claimants),
            new ReadOperation[](0),
            new bytes[](0)
        );

        IProver.ProofData memory proof = metaProver.provenIntents(intentHash);
        assertEq(proof.destination, uint64(block.chainid));
        assertEq(uint8(proof.outcome), uint8(IProver.Outcome.Cancelled));
    }
```

`CCIPProverTest`:

```solidity
    function testCcipReceiveRecordsCancelledOutcome() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        claimants[0] = CANCELLED_CLAIMANT;

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: uint64(1),
            sender: abi.encode(whitelistedProver),
            data: _formatMessageWithChainId(1, intentHashes, claimants),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(address(router));
        ccipProver.ccipReceive(message);

        IProver.ProofData memory proof = ccipProver.provenIntents(
            intentHashes[0]
        );
        assertEq(proof.destination, CHAIN_ID);
        assertEq(uint8(proof.outcome), uint8(IProver.Outcome.Cancelled));
    }
```

`LocalProverTest` (same-chain fast refund and withdraw guard; add `import {IIntentSource} ...` only if missing — it is already imported):

```solidity
    function test_cancelledIntent_RefundsBeforeRewardDeadline() public {
        Intent memory _intent = _createIntent(
            address(localProver),
            REWARD_AMOUNT,
            0
        );
        (bytes32 intentHash, ) = _publishAndFundIntent(_intent);
        vm.warp(uint256(_intent.route.deadline) + 1);
        portal.cancel(
            intentHash,
            _intent.route,
            keccak256(abi.encode(_intent.reward))
        );
        assertLt(block.timestamp, _intent.reward.deadline);

        uint256 creatorBefore = creator.balance;
        vm.prank(user);
        portal.refund(
            _intent.destination,
            keccak256(abi.encode(_intent.route)),
            _intent.reward
        );
        assertEq(creator.balance, creatorBefore + REWARD_AMOUNT);
    }

    function test_cancelledIntent_WithdrawReverts() public {
        Intent memory _intent = _createIntent(
            address(localProver),
            REWARD_AMOUNT,
            0
        );
        (bytes32 intentHash, ) = _publishAndFundIntent(_intent);
        vm.warp(uint256(_intent.route.deadline) + 1);
        portal.cancel(
            intentHash,
            _intent.route,
            keccak256(abi.encode(_intent.reward))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.CancelledIntent.selector,
                intentHash
            )
        );
        portal.withdraw(
            _intent.destination,
            keccak256(abi.encode(_intent.route)),
            _intent.reward
        );
    }
```

- [ ] **Step 2: Run the tests**

Run: `forge test --root /Users/carlosfebres/dev/eco/eco-routes-proven-cancellation --match-test 'Cancelled|cancelled'`
Expected: all PASS (behaviour landed in Tasks 4, 5, 7). If one fails, it is a real bug in the earlier task — fix it there, not in the test.

- [ ] **Step 3: Format, commit**

```bash
W=/Users/carlosfebres/dev/eco/eco-routes-proven-cancellation
F="test/prover/HyperProver.t.sol test/prover/LayerZeroProver.t.sol test/prover/MetaProver.t.sol test/prover/CCIPProver.t.sol test/prover/LocalProver.t.sol"
for f in $F; do npx --prefix $W prettier --write $W/$f; done
git -C $W add $F
git -C $W commit -m "test(prover): cover proven cancellation on every receive path" -m "Claude-Session: https://claude.ai/code/session_01Fs7GU5DoDuKhLo9VDktMXP"
```

(`CCIPProver.t.sol` is not prettier-clean on `main` today — its lines exceed the print width. Run `npx --prefix $W prettier --check $W/test/prover/CCIPProver.t.sol` on the untouched file first; if it already fails, **skip prettier for that file** and hand-format your addition to match its style.)

---

### Task 10: End-to-end flow and fail-safe reader

**Files:**
- Create: `test/core/ProvenCancellationFlow.t.sol`

**Interfaces:**
- Consumes: everything above; `Portal` acts as both source and destination (same chain) with `TestProver` as the bridge.

- [ ] **Step 1: Write the tests**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BaseTest} from "../BaseTest.sol";
import {IInbox} from "../../contracts/interfaces/IInbox.sol";
import {IProver} from "../../contracts/interfaces/IProver.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {Intent} from "../../contracts/types/Intent.sol";

/// @dev Reader compiled against the pre-cancellation two-word ProofData
interface ILegacyProofReader {
    struct LegacyProofData {
        address claimant;
        uint64 destination;
    }

    function provenIntents(
        bytes32 intentHash
    ) external view returns (LegacyProofData memory);
}

/// @notice Cancel on the destination, prove to the source, refund before reward.deadline
contract ProvenCancellationFlowTest is BaseTest {
    address internal solver;

    function setUp() public override {
        super.setUp();
        solver = makeAddr("solver");
        _mintAndApprove(creator, MINT_AMOUNT);
        _mintAndApprove(solver, MINT_AMOUNT);
    }

    // Same Portal is source and destination; product-shaped deadlines
    function _sameChainIntent()
        internal
        view
        returns (Intent memory i, bytes32 routeHash, bytes32 rewardHash, bytes32 intentHash)
    {
        i = intent;
        i.destination = uint64(block.chainid);
        i.route.deadline = uint64(block.timestamp + 5 minutes);
        i.reward.deadline = uint64(block.timestamp + 7 days);
        routeHash = keccak256(abi.encode(i.route));
        rewardHash = keccak256(abi.encode(i.reward));
        intentHash = keccak256(
            abi.encodePacked(i.destination, routeHash, rewardHash)
        );
    }

    function testCancelProveAndRefundBeforeRewardDeadline() public {
        (
            Intent memory i,
            bytes32 routeHash,
            bytes32 rewardHash,
            bytes32 intentHash
        ) = _sameChainIntent();
        _publishAndFund(i, false);

        vm.warp(uint256(i.route.deadline) + 1);
        vm.prank(otherPerson);
        portal.cancelAndProve(
            intentHash,
            i.route,
            rewardHash,
            address(prover),
            uint64(block.chainid),
            ""
        );

        IProver.ProofData memory proof = prover.provenIntents(intentHash);
        assertEq(uint8(proof.outcome), uint8(IProver.Outcome.Cancelled));
        assertEq(proof.destination, uint64(block.chainid));

        assertLt(block.timestamp, i.reward.deadline);
        vm.prank(otherPerson);
        intentSource.refund(i.destination, routeHash, i.reward);
        assertEq(tokenA.balanceOf(creator), MINT_AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.InvalidStatusForWithdrawal.selector,
                IIntentSource.Status.Refunded
            )
        );
        intentSource.withdraw(i.destination, routeHash, i.reward);
    }

    function testFulfilledIntentCannotBeCancelledOrRefundedEarly() public {
        (
            Intent memory i,
            bytes32 routeHash,
            bytes32 rewardHash,
            bytes32 intentHash
        ) = _sameChainIntent();
        _publishAndFund(i, false);

        vm.warp(i.route.deadline);
        vm.prank(solver);
        portal.fulfillAndProve(
            intentHash,
            i.route,
            rewardHash,
            bytes32(uint256(uint160(claimant))),
            address(prover),
            uint64(block.chainid),
            ""
        );

        vm.warp(uint256(i.route.deadline) + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IInbox.IntentAlreadyFulfilled.selector,
                intentHash
            )
        );
        portal.cancel(intentHash, i.route, rewardHash);

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.IntentNotClaimed.selector,
                intentHash
            )
        );
        intentSource.refund(i.destination, routeHash, i.reward);

        intentSource.withdraw(i.destination, routeHash, i.reward);
        assertEq(tokenA.balanceOf(claimant), MINT_AMOUNT);
    }

    // Spec invariant 6: a reader unaware of cancellation sees "unproven"
    function testLegacyTwoWordReaderSeesCancelledProofAsUnproven() public {
        bytes32 intentHash = keccak256("cancelled");
        prover.addCancelledIntent(intentHash, CHAIN_ID);

        ILegacyProofReader.LegacyProofData memory legacy = ILegacyProofReader(
            address(prover)
        ).provenIntents(intentHash);

        assertEq(legacy.claimant, address(0));
    }
}
```

(`creator`'s tokenA balance after publish is 0 in BaseTest — `_mintAndApprove` mints `MINT_AMOUNT` and `publishAndFund` escrows it — so the refund leaves exactly `MINT_AMOUNT`. The route's own call sends solver-provided tokenA to `creator` only in the fulfilled test, which asserts on `claimant` instead.)

- [ ] **Step 2: Run the tests**

Run: `forge test --root /Users/carlosfebres/dev/eco/eco-routes-proven-cancellation --match-contract ProvenCancellationFlowTest`
Expected: all PASS.

- [ ] **Step 3: Format, commit**

```bash
W=/Users/carlosfebres/dev/eco/eco-routes-proven-cancellation
npx --prefix $W prettier --write $W/test/core/ProvenCancellationFlow.t.sol
git -C $W add test/core/ProvenCancellationFlow.t.sol
git -C $W commit -m "test(portal): cover the cancel, prove, refund flow end to end" -m "Claude-Session: https://claude.ai/code/session_01Fs7GU5DoDuKhLo9VDktMXP"
```

---

### Task 11: Documentation and final verification

**Files:**
- Modify: `CLAUDE.md` (Intent Lifecycle; AggregatorProver paragraph; `AGGREGATOR_PROVER_MEMBERS`)
- Modify: `contracts/README.md` (Portal `refund` security line; Inbox methods)
- Modify: `scripts/tron/run-tron-evm-intent.ts` (comment only)

- [ ] **Step 1: Update docs**

`CLAUDE.md` — Intent Lifecycle list, append:

```markdown
6. **Cancellation** (optional): after `route.deadline`, anyone may `cancel` an unfulfilled intent on the destination `Inbox` (`cancelAndProve` also sends the proof). The destination records the `CANCELLED_CLAIMANT` sentinel in `claimants`, so it can never be fulfilled; provers carry it like a claimant and record `ProofData.outcome = Cancelled` (claimant zero). The source refunds a proven cancellation immediately and never withdraws one; `reward.deadline` remains the timeout fallback. Existence of a proof is `outcome != None`, not a non-zero claimant.
```

In the AggregatorProver paragraph and the `AGGREGATOR_PROVER_MEMBERS` entry, replace "the first member with a non-zero claimant wins" / "Reports an intent as proven when any member has proven it" with "the first member (priority order) holding a well-formed Fulfilled or Cancelled proof wins", and note members must return the three-word `ProofData` (the deploy probe rejects the pre-cancellation two-word shape).

`contracts/README.md` — Portal `refund` security line becomes: `<ins>Security:</ins> Will fail before the reward deadline unless the intent's prover holds a proven cancellation for its destination.` Under the Inbox `### Methods` heading add entries for `cancel` and `cancelAndProve` in the file's existing `<h4><ins>…</ins></h4>` format, stating: callable by anyone strictly after `route.deadline`; reverts if the intent was fulfilled or already cancelled; `cancelAndProve` forwards `msg.value` to the prover like `fulfillAndProve`.

`scripts/tron/run-tron-evm-intent.ts` — the comment `// provenIntents returns ProofData{address claimant, uint64 destination} = 128 hex chars` becomes `// provenIntents returns ProofData{address claimant, uint64 destination, Outcome outcome} = 192 hex chars`. The logic (first word non-zero = fulfilled) is unchanged and still correct.

- [ ] **Step 2: Full verification**

```bash
W=/Users/carlosfebres/dev/eco/eco-routes-proven-cancellation
forge test --root $W
yarn --cwd $W test:hardhat
yarn --cwd $W test:ts
forge build --root $W --sizes 2>&1 | grep -E '^\| (Portal|PortalTron|AggregatorProver|LocalProver|PolymerProver|HyperProver|LayerZeroProver|MetaProver|CCIPProver) '
npx --prefix $W prettier --check $W/CLAUDE.md $W/contracts/README.md $W/scripts/tron/run-tron-evm-intent.ts
```
Expected: every suite PASS; `Portal`/`PortalTron` runtime < 24,576 (report the final margin); prettier clean.

- [ ] **Step 3: Commit**

```bash
W=/Users/carlosfebres/dev/eco/eco-routes-proven-cancellation
git -C $W add CLAUDE.md contracts/README.md scripts/tron/run-tron-evm-intent.ts
git -C $W commit -m "docs: document proven cancellation" -m "Claude-Session: https://claude.ai/code/session_01Fs7GU5DoDuKhLo9VDktMXP"
git -C $W status --short
```
Expected: `git status --short` shows nothing tracked as modified (the `node_modules` symlink is ignored).

---

## Spec coverage (self-review)

| Spec item | Task |
|---|---|
| D1/D2 sentinel, wire unchanged, golden | 1 |
| D3 destination record, `fulfill` rejects sentinel, `prove` unchanged | 1 |
| §4 `cancel` checks and order, `cancelAndProve` | 1, 2 |
| D4/§6.1 `Outcome`, `ProofData.outcome`, `IntentCancellationProven` | 3 |
| §6.2 BaseProver (Hyper/LZ/Meta/CCIP), challenge on `outcome` | 3, 4, 9 |
| §6.2 Polymer | 3, 4 |
| §6.2 LocalProver | 3, 5, 9 |
| §6.2 AggregatorProver (3-word decode, out-of-range enum skipped) | 3, 6 |
| §6.3 IntentSource refund fast path / fallback / withdraw guard | 7 |
| D7 first recorded wins | 4, 6, 9 |
| D8 minor release | Global Constraints (commit subjects) |
| §8 generation isolation / deploy probe | 3 (probe); rollout itself is out of scope for code |
| §9 invariants 1–7 | 1 (1, 5, 7), 7/9/10 (2, 3, 4), 10 (6) |
| §10 EVM column | 1, 2, 4–10 |
| Not in spec, found in code: legacy two-word provers freeze escrow | accepted risk (spec D9), no task |
| Not in spec, found in code: Polymer zero-claimant would become a permanent Fulfilled record | 3 |
| Not in spec, found in code: 96-byte dynamic-return fabrication in AggregatorProver | 3 |
| Not in spec, found in code: Portal is 926 B under EIP-170 | size gate in 1, 2, 3, 7, 11 |
