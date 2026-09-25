# Intent chaining

`IntentChainer.chain(order)` measures one local ERC-20 balance, renders a child intent,
optionally publishes it, and pushes the measured balance into that child's **local**
reward vault. It keeps no balance at rest in the intended flow.

The route can now contain two kinds of dynamic item: an amount, or the vault recipient
of another, downstream intent. A downstream intent also has templates for its route
and reward, so its hash and vault address can depend on that same initial measurement.

## Execution boundary

```text
intent1 executes: swap -> chainer receives tokens -> chain(order)
  measure amountIn; compute amountOut
  render downstream intents -> derive remote recipients
  render intent2 route, including its complete CCTP mintRecipient
  resolve/check intent2 LOCAL vault -> optionally publish -> push amountIn locally

later: intent2 executes its already-populated route, including any CCTP burn
later: the bridge mints to the remote intent's vault / Solana vault ATA
```

The chainer does not burn, bridge, approve a messenger, or transfer locally to a remote
address. Executor does not need to splice return values between calls. There is no new
escrow: the local child vault and remote downstream vault remain the custody accounts.

## Order and template layout

```solidity
struct Order {
  bool publish;
  address portal; // LOCAL reward Portal
  address token; // measured local ERC-20
  uint64 destination; // where the child route executes
  IntentTemplate.Program template;
  Reward reward; // one local token leg; amount overwritten with amountIn
  uint256 scale;
  uint256 minAmountIn;
}
```

A program contains `Vault[] vaults` and a root `Template route`. Each template has:

```text
Template { bytes[] segments; Item[] items; }
Item     { ItemKind kind; bytes config; }

rendered = segments[0] || render(items[0]) || segments[1] || ... || segments[n]
segments.length == items.length + 1
```

The SDK's conceptual nested tree is flattened into **dependency-first nodes** in
`program.vaults`. Node i may reference only nodes with index < i. The root route can
reference any node. Self references, forward references, cycles, and missing references
revert. Shared downstream nodes are evaluated once and may be referenced repeatedly.

Each vault node contains:

```text
Vault {
  uint64 destination;       // downstream intent's route execution chain
  Template route;
  Template reward;          // ENTIRE remote Reward serialization
  VaultDerivation derivation;
}
VaultDerivation { VaultKind kind; bytes config; }
```

The renderer builds route/reward bytes, then computes:

```text
intentHash = keccak256(uint64_be(destination) || keccak256(route) || keccak256(reward))
recipient  = derive(intentHash, derivation)
```

For an EVM reward, render the complete `abi.encode(Reward)`, including its outer tuple
offset and array encoding. For a Solana reward, render Borsh (u64 little-endian fields,
32-byte pubkeys, and u32 little-endian vector lengths). Merely serializing EVM addresses
as bytes32 does not turn an EVM reward into a Solana reward.

## Tagged configurations

Every `config` uses standard `abi.encode` of the specified schema, not packed encoding.
Unknown/invalid tags, missing fields, malformed ABI, and trailing config bytes revert.
All tags reserve zero as invalid.

| Item kind  | Config                                             | Rendered bytes      |
| ---------- | -------------------------------------------------- | ------------------- |
| Amount (1) | `AmountConfig(source, scale, width, littleEndian)` | Exactly width bytes |
| Vault (2)  | `abi.encode(uint256 vaultIndex)`                   | Exactly 32 bytes    |

`AmountSource.Input` (1) selects the initially measured amountIn;
`AmountSource.Output` (2) selects `ceil(amountIn * order.scale / 1e18)`.
An amount item applies its own positive WAD-denominated scale with ceiling rounding.
Use item scale `1e18` for no additional transform. All items share the initial context;
nesting never triggers another balance measurement.

Widths must be 1..32, and values that do not fit revert. Use width 32/big-endian for
ABI words and width 8/little-endian for Borsh u64s. Vault items always return a full
32-byte recipient; EVM/TRON addresses are left-zero-padded, Solana ATAs are not truncated.

### EVM and TRON vaults

`VaultKind.EvmCreate2` (1) decodes:

```solidity
struct EvmConfig {
  address portal;
  bytes1 prefix;
  address implementation;
  bytes32 initCodeHash;
}
```

```text
vault = last20(keccak256(prefix || portal || intentHash || initCodeHash))
initCodeHash = keccak256(remote Proxy.creationCode || abi.encode(implementation))
```

All four fields are required and committed. The formula never reads address(this),
uses local Proxy bytecode, or assumes a chain ID or a 0xff prefix. Standard EVM uses
0xff; TRON uses 0x41 AND VaultTron's implementation/hash. Worldchain's different
Portal is simply another explicit deployer.

Implementation is already embedded in initCodeHash. The renderer checks presence,
not whether that pair matches deployed remote code. The author must obtain the
correct remote Portal, implementation and bytecode hash; no remote chain state can
be attested by this calculation.

### Solana vault ATAs

`VaultKind.SolanaAta` (2) decodes:

```solidity
struct SolanaConfig {
  bytes32 portalProgramId;
  bytes32 tokenProgramId;
  bytes32 mint;
}
```

All three identifiers must be nonzero. The associated-token program ID is the canonical
`ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL`.

```text
vault = find_program_address(["vault", intentHash], portalProgramId)
recipient = find_program_address([vault, tokenProgramId, mint], ATA_PROGRAM_ID)
```

Both bumps are **computed**, not caller input. Search starts at 255 and returns the first
off-curve SHA-256 digest. Curve membership is checked with Edwards25519 field arithmetic
and MODEXP (0x05), following the approach in [Sauce PR #416](https://github.com/eco/sauce/pull/416).
The predicate matches Solana's dalek decompression, not a stricter signature/public-key
decoder: noncanonical y is reduced and x=0 with a set sign bit is not additionally rejected.

Each nested search is capped at **32 attempts, bumps 255 through 224**. If the canonical
bump is lower, rendering reverts with `PdaSearchExhausted`; it never substitutes a
different address. Both SHA-256 (0x02) and MODEXP (0x05) must be present and return 32
bytes; errors or malformed responses revert.

This deliberately supersedes the original caller-supplied-bump/SHA-only proposal.
A fixed program ID does not fix the bump: the intent hash depends on the measured
amount. Committing bumps would prevent substitution but not prove canonicality. A
non-canonical bump can produce an off-curve address that the Portal/ATA program does
not use; a CCTP mint there may be unrecoverable. Therefore this API accepts **no bumps**,
and appended bump fields are rejected as noncanonical config encoding.

## Bounds and authority

- At most 8 downstream vault nodes and 8 items per route/reward template.
- At most 32 KiB aggregate rendered bytes across every nested route/reward and the root.
- At most 32 curve checks per PDA, two PDAs per Solana vault node.
- The entire Order, including nested templates/configs/references, is committed in
  intent1's route calldata and therefore its intent hash. Changing a config changes
  that identity; a fulfiller cannot substitute it while executing the original intent.
- Rendering makes no user-selected external calls. Only the fixed cryptographic
  precompiles are called before the usual local Portal/token operations.

As before, the residual exposure is any token donated to the shared chainer out-of-band:
`order.token` is caller-chosen, so the next caller can chain that token's entire balance
into their own order. The intended atomic flow
leaves no balance at rest. Remote rendering introduces no additional custody, deferred
chainer transfer, approvals, callbacks, or sweep endpoint.

The local settlement guard runs even when `publish=false`: Withdrawn and Refunded
children are rejected. The vault may already hold any balance, but its balance increase
from this transfer must cover the whole measured push. Prefunding cannot mask an
outbound transfer fee. These are **local** guarantees, not assertions about remote
settlement status.

Child identity is the builder's responsibility. Use fresh child route salts when
different parents must produce independent children; the parent hash is not mixed into
the child hash. Distinct parents that reuse the complete child preimage and measure
the same amount fund the same unsettled vault. A top-up does not increase that child's
declared reward or delivery obligation: the solver withdraws the declared reward, and
surplus can be refunded to the creator after withdrawal. The same parent still cannot
be fulfilled twice (Inbox enforces this). The removed `VaultAlreadyFunded` rejection
was a prefunding policy, not the parent replay check; it is not replaced by an
empty-vault requirement.

The author/SDK remains responsible for valid opaque route/reward semantics, fresh salts,
deadline headroom, prover/token identifiers, slot/call agreement, and bridge fee treatment.
In particular, a CCTP remote reward must describe the amount actually minted. Template
amount transforms remain proportional; this feature does not add a flat-fee expression.
`_calculateAmountOut` isolates the proportional calculation from balance measurement
without changing its ceiling rounding or introducing fees.

The on-chain five-minute buffer validates only the local **reward** deadline. Child
and downstream **route** deadlines are inside opaque templates and are not validated
by the chainer. Builders must give them enough headroom for later fulfillment; passing
the reward-deadline check does not establish route freshness.

## Deployment and compatibility

V4 replaces the unshipped amount-only Order and chain ABI directly, without a legacy
entrypoint. Existing amount-only fixtures still produce identical route, reward,
intent-hash and local-vault outputs when represented as Amount items. CREATE3 ignores
bytecode, so V4 uses a new salt/version rather than modifying an older deployment.

**Current source targets INTENT_CHAINER_V5 and is not deployed.** V5 retains V4's Order
and chain ABI, permits prefunded child vaults, extracts the output calculation, and
reports `InvalidPortal` for zero/codeless Portals. The rollout script now selects V5's
new CREATE3 salt; it cannot overwrite or reuse the deployed V4 address. The V4 manifest
below remains historical deployment evidence, not evidence that V5 is live. Using V5
requires a separate chainer-only deployment on the execution chains and client address
updates. No Portal or Vault redeployment is needed.

**INTENT_CHAINER_V4** was deployed and verified on 2026-09-09 at:

`0x96f7DBa7E587f359a8f585C335fe510E4dC9bCC0`

The address is identical on all 14 rollout chains: **1, 10, 56, 130, 137, 143, 146,
480, 999, 8453, 9745, 42161, 42220, 57073**. See the
[deployment manifest](../../deployments/intent-chainer-v4.json) for receipts, source
commits, compiler settings and the exact runtime-code hash. Each deployment passed
receipt, bytecode, read-only getter and SHA-256/MODEXP precompile checks.

The operator excluded unfunded chains **169, 466, 2020, 5000, 5330, 8333, 33139,
10241024**; no deployment transactions were sent there. Existing Portals and previous
chainer deployments were not changed. Solver/SDK adoption is a separate step: callers
must use the address and behavior of the version actually deployed. The V4 address
still has the prefunding rejection; none of these source changes alters it.

A new chainer is required on **each chain executing chain()**, not automatically on a
remote recipient chain or the chain executing a later CCTP burn. TRON needs its compatible
build/deployment if it executes chain(), not merely when it is a recipient. A Solana
destination requires no new EVM chainer or Portal deployment for this derivation feature.
Verify source-chain precompile compatibility before enabling Solana items elsewhere.

Use the existing rollout script: `./scripts/deployIntentChainers.sh` is a dry run;
add `--broadcast` to deploy. Its default is the 14-chain fleet above. `CHAIN_IDS`
overrides the selection, and `RPC_<chain id>` overrides an endpoint. The script checks
chain identity, CREATE3 availability, precompiles, existing runtime and consistent
address prediction before broadcasting. It verifies runtime again afterward and
skips an existing deployment only when its bytecode matches exactly.

HyperEVM uses `--gas-estimate-multiplier 105`: V4 was simulated below 2.9M gas,
whereas Foundry's default 130% padding exceeds the observed 3M small-block limit.
Revalidate this headroom when changing the implementation. No big-block account-mode
change is needed for V4. Cross-chain deployment is not atomic; reconcile receipts
after a failure, then rerun to skip already-verified deployments.

## Validation

- Existing Foundry amount, Borsh production-encoder, cross-VM fixture and local lifecycle tests.
- Independent standard-EVM/Worldchain CREATE2 expectations and explicit 0x41/VaultTron tests.
- Nested route/reward rendering, dependency/reference bounds, config validation and commitment tests.
- Real Portal fulfillment -> local child vault -> later populated burn -> claimant withdrawal.
- Prefunded vaults below/equal/above the push, distinct-parent child reuse, same-parent
  replay rejection, and unchanged ceil-rounding/amount fixtures.
- Outbound fee-on-transfer failures through real Portal/Executor calls assert exact
  wrapped PushShortfall and full balance/claimant rollback, with and without publication.
  Hardhat mined-receipt regressions additionally assert no logs survive the reverted transaction.
- SVM Portal's own vault golden plus its SDK-derived ATA, 128 independent vault/ATA vectors,
  128 curve-membership vectors, and dynamic Borsh reward fixtures.
- Non-canonical off-curve candidate rejection, rejected caller bump injection, failed precompiles,
  and bounded-search exhaustion.

The Solana fixtures are checked against eco-routes-svm ref
`95c728850955d3c9aa7c62ba08a87db5be89e220` and generated independently with the Solana SDK,
not this Solidity implementation. See
[scripts/generateSolanaVaultVectors.cjs](../../scripts/generateSolanaVaultVectors.cjs).
