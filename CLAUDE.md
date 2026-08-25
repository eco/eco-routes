# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## ⛔ Security: never publish a fix for deployed code

The contracts here are **deployed on-chain and hold user funds.** You usually **cannot tell** whether a given contract is already deployed — so do not try to guess. Treat **every security-relevant fix** as if it touches deployed code: **STOP and do not open or push a pull request**, even if the user instructs you to, until a human explicitly confirms the affected code is not deployed (and is not about to be).

Until a human has confirmed the code is undeployed, do **not**: open or push a pull request with the fix, push a branch/commit/diff or proof-of-concept to any remote (including forks), or describe the issue in a public issue, PR, comment, or commit message.

Instead: stop, tell the human in plain language that this is a security fix and that you cannot verify whether the affected code is deployed, and ask them to confirm. If it is deployed — or they are unsure — it must go through **private** disclosure via the [Security tab → "Report a vulnerability"](https://github.com/eco/eco-routes/security), not the normal PR flow. The exposure happens at the **push** to a public remote, not the merge, and a later revert does not undo it — a fix for deployed code is developed only in the private advisory fork, never pushed here. Full policy: [`SECURITY.md`](./SECURITY.md). This is a hard safety constraint.

## Commands

### Build and Test

- `yarn build` - Build all contracts (Hardhat + Foundry)
- `forge build` - Foundry-only build
- `yarn test` - Complete test suite (Hardhat + TypeScript + Forge)
- `forge test` - Foundry tests only
- `forge test -vvv` - Verbose Foundry testing
- `forge test --match-contract PortalTest` - Run specific contract tests
- `yarn test:hardhat` - Hardhat tests only
- `yarn test:ts` - TypeScript/Jest tests only

### Code Quality

- `yarn format` - Format all code (ESLint + Prettier + Solhint)
- `yarn lint` - Same as format
- `yarn format:solhint` - Solidity linting specifically

### Development

- `forge script scripts/Deploy.s.sol --broadcast --rpc-url $RPC_URL` - Deploy contracts

### Releases

- Releases flow through an auto-refreshing release PR (`autorelease/next`
  branch, title `chore(release): x.y.z`) created by
  `.github/workflows/release-pr.yaml` on each push to `main`. A human
  approves and squash-merges it; `.github/workflows/release-tag.yaml` then
  tags `vx.y.z` and publishes the GitHub release. No direct pushes to
  `main`; no deploys; no npm publish. PR titles must be conventional
  commits (enforced in CI). Details: [`RELEASE.md`](./RELEASE.md).

## Architecture Overview

**Eco Routes** is a cross-chain intent protocol implementing ERC-7683 for standardized cross-chain orders. The system uses a modular architecture with multiple bridge integrations.

### Core Architecture Pattern

The system centers around the **Portal contract** which inherits from both **IntentSource** and **Inbox**:

```
Portal (Main Contract)
├── IntentSource (Source chain operations)
│   └── OriginSettler (ERC-7683 entry point)
├── Inbox (Destination chain operations)
│   └── DestinationSettler (ERC-7683 fulfillment)
└── Semver (Version tracking)
```

**Portal** serves as a unified entry point combining source chain (intent creation/funding) and destination chain (fulfillment) functionality in a single contract.

### Intent Lifecycle

1. **Publishing**: User creates intent on source chain via `IntentSource`
2. **Funding**: Reward tokens escrowed in deterministic Vault (CREATE2)
3. **Fulfillment**: Solver executes intent on destination chain via `Inbox`
4. **Proving**: Cross-chain proof sent via bridge-specific prover
5. **Settlement**: Solver withdraws rewards after proof validation

### Multi-Prover Architecture

The system supports multiple bridge protocols through specialized prover contracts (`contracts/prover/`):

- **HyperProver**: Hyperlane integration via `IMessageRecipient`
- **LayerZeroProver**: LayerZero v2 via `ILayerZeroReceiver`
- **MetaProver**: Metalayer router integration
- **PolymerProver**: Polymer cross-chain verification
- **CCIPProver**: Chainlink CCIP integration
- **LocalProver**: Same-chain proof handling (with a `LocalProverTron` variant for TRON)
- **AggregatorProver**: Read-only 1-of-N union over other provers on the same
  chain. Records no proofs and dispatches no messages — `prove()` reverts;
  solvers prove through a concrete member. Reports an intent as proven when any
  member has proven it, so a creator can name a set of bridges at publish time
  and the solver picks a live one at fulfillment time. Security floor is the
  weakest member, and membership is immutable. Emits no `IntentProven` /
  `IntentProofInvalidated`: **indexers must watch the member provers, not this
  address.** Membership requires a **bridge-attested** `destination`: only
  `MessageBridgeProver` descendants qualify, because their destination is
  cross-checked against the bridge origin domain in `_handleCrossChainMessage`.
  `PolymerProver` and `LocalProver` do not qualify and are rejected at deploy
  time — a member that can record a wrong `destination` shadows valid proofs held
  by lower-priority members, and the refund path cannot recover from that. Even
  with a fully validated member set, a shadowing entry (e.g. a genuinely
  wrong-destination proof from a live bridge) makes the **first** `withdraw`
  succeed while paying nothing: it forwards the challenge to every member and
  returns, and only a second `withdraw` call actually pays. Do not read a
  no-op `withdraw` as a bug by itself — check whether an earlier member's
  proof was just challenged out.

Provers share a common base: `BaseProver` (implements `IProver`, `ERC165`) is the root, and the message-bridge provers extend `MessageBridgeProver` (which itself extends `BaseProver`). All of those follow the standardized `(intentHash, claimant)` message format, using `bytes32` addresses for cross-VM compatibility. **`AggregatorProver` is the exception**: it is `IProver, ERC165, Whitelist, Semver` directly, does not extend `BaseProver` or `MessageBridgeProver`, and handles no message format at all — it dispatches no messages and has no `handle`/`lzReceive`/fallback. Do not assume `BaseProver` semantics for it: its `challengeIntentProof` is a blanket forwarder to every member (see its own NatSpec), not a delete-and-emit like `BaseProver`'s.

### Key Components

**IntentSource** (`contracts/IntentSource.sol`):

- Abstract contract handling intent publishing, funding, reward settlement
- Uses CREATE2 for deterministic vault addresses (with TRON compatibility)
- Status-based state machine: `Initial → Funded → Withdrawn/Refunded`

**Inbox** (`contracts/Inbox.sol`):

- Abstract contract handling intent fulfillment on destination chains
- Uses immutable `Executor` contract for secure batch call execution
- Tracks claimants and manages fulfillment state

**Vault System**:

- Deterministic addresses via CREATE2 with configurable salt
- Supports native ETH and ERC20 tokens
- Handles TRON's different CREATE2 prefix (0x41 vs 0xff)

### Cross-Chain Integration

**Bridge Abstraction**: Each bridge uses custom domain ID mappings (not chain IDs). The system provides a unified interface while bridges handle their own:

- Message routing and validation
- Fee calculation and payment
- Security module validation

**ERC-7683 Compliance**: Full implementation with:

- `OriginSettler`: Entry point with `open()` and gasless `openFor()`
- `DestinationSettler`: Standardized `fill()` fulfillment
- EIP-712 structured data signing for orders
- Intent → ERC-7683 Order format conversion

### Testing Architecture

**Multi-Language Testing**:

- **Foundry** (Solidity): Core contract logic and security tests
- **Hardhat** (TypeScript): Integration and deployment tests
- **Jest**: Unit tests for utilities and scripts

**Test Structure**:

- All Solidity tests extend `BaseTest` for common infrastructure
- Organized by functionality: `core/`, `prover/`, `security/`
- Comprehensive mocks for external protocols (`TestMailbox`, etc.)

### Development Patterns

**Smart Contract Patterns**:

- **Modular Inheritance**: Portal combines specialized components
- **Deterministic Deployment**: CREATE2 for consistent cross-chain addresses
- **Cross-VM Compatibility**: `bytes32` identifiers for non-EVM chains
- **Security-First**: Immutable addresses, status-based state machines

**Configuration**:

- Solidity 0.8.27 with Paris EVM and via-IR optimization (TRON contracts use solc 0.4.25)
- Support for 15+ networks including TRON with special handling
- Environment-based deployment with semantic versioning

### Key Environment Variables

- `DEPLOYER_PRIVATE_KEY` - Deployment account
- `SALT` - CREATE2 salt for deterministic addresses
- `MAILBOX_CONTRACT` - Hyperlane mailbox address
- `ROUTER_CONTRACT` - Metalayer router address
- `LAYERZERO_ENDPOINT` - LayerZero endpoint address
- `LAYERZERO_DELEGATE` - LayerZero delegate (optional; defaults to deployer)
- `POLYMER_CROSS_L2_PROVER_V2` - Polymer CrossL2ProverV2 address
- `CCIP_ROUTER` - Chainlink CCIP router address
- Per-bridge cross-VM prover lists (comma-separated `bytes32` addresses): `HYPER_CROSS_VM_PROVERS`, `META_CROSS_VM_PROVERS`, `LAYERZERO_CROSS_VM_PROVERS`, `POLYMER_CROSS_VM_PROVERS`, `CCIP_CROSS_VM_PROVERS`
- Per-bridge origin domain config (comma-separated `domain:chainId` pairs, e.g. `100:10,200:8453`; unset/empty parses to an empty array): `HYPER_DOMAIN_CONFIG`, `META_DOMAIN_CONFIG`, `LAYERZERO_DOMAIN_CONFIG`, `CCIP_DOMAIN_CONFIG`. `HyperProver`/`MetaProver` resolvers fall back to `domain == chainId`, so `HYPER_DOMAIN_CONFIG`/`META_DOMAIN_CONFIG` are exceptions-only and may be left empty. `LayerZeroProver`/`CCIPProver` use a strict domain->chainId map with no fallback, so `LAYERZERO_DOMAIN_CONFIG`/`CCIP_DOMAIN_CONFIG` must enumerate every origin chain accepted.
- `AGGREGATOR_PROVER_MEMBERS` - Ordered, comma-separated member prover addresses
  for `AggregatorProver` (max 8). Each element may be either a 20-byte address
  (`0x` + 40 hex chars, the form operators will normally write) or a full
  32-byte `bytes32` (`0x` + 64 hex chars); the 20-byte form is left-padded
  automatically. **Order is priority** — the first member with a non-zero
  claimant wins. Unset or empty (the empty string) skips aggregator
  deployment; any other malformed value (wrong element length, a trailing
  comma, etc.) now **fails the deploy loudly** rather than silently
  skipping deployment the way an unparseable value once did.
- `AGGREGATOR_PROVER_ALLOW_UNVERIFIED_MEMBERS` - **Unsafe escape hatch.** When `true`,
  allows `AggregatorProver` members that were not deployed in the current run
  (i.e. not `ctx.hyperProver`/`metaProver`/`layerZeroProver`). Read once in
  `run()` into `ctx.allowUnverifiedMembers`, so `validateAggregatorProverMembers`
  is a pure function of the context and tests set a struct field rather than
  mutating process-wide env state. The EVM-shape, non-zero, has-code,
  `chainIdByDomain`-presence, and `provenIntents`-shape checks still apply, but
  **domain-lane verification is skipped entirely** for members admitted this
  way — there is no per-lane check to skip to, because a member outside the
  matched set never reaches the domain-config loop. `CCIPProver` can _only_
  be admitted through this hatch: it is deployed by a separate script
  (`scripts/DeployCCIPProver.s.sol`), so it can never equal one of `ctx`'s own
  prover fields, and it uses a strict domain->chainId map with no fallback,
  making it the member type most sensitive to a config error. Any member
  admitted via this hatch requires **out-of-band** verification of its domain
  table against the bridge operator's published values before deployment —
  leave the hatch unset unless you have done that audit.

## Integration Notes

- **Bridge Trust Model**: Multi-bridge architecture reduces single points of failure
- **Domain ID Mapping**: Careful distinction between chain IDs and bridge domain IDs
- **Vault Security**: Deterministic address calculation with replay protection
- **Execution Safety**: Isolated Executor prevents dangerous calls to EOAs
- **Gas Optimization**: Via-IR compilation and efficient storage layouts

When adding new bridge integrations, follow the `MessageBridgeProver` pattern and ensure proper domain ID mapping and message format standardization.
