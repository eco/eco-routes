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

As before, the residual exposure is a balance donated to the shared chainer out-of-band:
the next caller can chain that balance into their own order. The intended atomic flow
leaves no balance at rest. Remote rendering introduces no additional custody, deferred
chainer transfer, approvals, callbacks, or sweep endpoint.

The local settlement guard runs even when `publish=false`. The local vault must not
already cover the amount being pushed, and its balance increase must cover the whole
push. These are **local** guarantees, not assertions about remote settlement status.

The author/SDK remains responsible for valid opaque route/reward semantics, fresh salts,
deadline headroom, prover/token identifiers, slot/call agreement, and bridge fee treatment.
In particular, a CCTP remote reward must describe the amount actually minted. Template
amount transforms remain proportional; this feature does not add a flat-fee expression.

## Deployment and compatibility

The user confirmed this chainer is unshipped: Order and chain's ABI are updated directly,
without a legacy entrypoint. Existing amount-only fixtures still produce identical route,
reward, intent-hash and local-vault outputs when represented as Amount items.

Deploy version **INTENT_CHAINER_V4** before eco-solver uses the new ABI. CREATE3 ignores
bytecode, so a new salt/version is required to distinguish an older implementation.
No deployment is performed by this PR.

A new chainer is required on **each chain executing chain()**, not automatically on a
remote recipient chain or the chain executing a later CCTP burn. The requested EVM fleet
checklist is **1, 10, 130, 137, 146, 480, 999, 2020, 8453, 9745, 42161**; enable each only
after deploying/verifying the new chainer there. TRON needs its compatible build/deployment
if it executes chain(), not merely when it is a recipient. A Solana destination requires
no new EVM chainer or Portal deployment for this derivation feature. Source-chain
precompile compatibility must be verified before enabling Solana items.

## Validation

- Existing Foundry amount, Borsh production-encoder, cross-VM fixture and local lifecycle tests.
- Independent standard-EVM/Worldchain CREATE2 expectations and explicit 0x41/VaultTron tests.
- Nested route/reward rendering, dependency/reference bounds, config validation and commitment tests.
- Real Portal fulfillment -> local child vault -> later populated burn -> claimant withdrawal.
- SVM Portal's own vault golden plus its SDK-derived ATA, 128 independent vault/ATA vectors,
  128 curve-membership vectors, and dynamic Borsh reward fixtures.
- Non-canonical off-curve candidate rejection, rejected caller bump injection, failed precompiles,
  and bounded-search exhaustion.

The Solana fixtures are checked against eco-routes-svm ref
`95c728850955d3c9aa7c62ba08a87db5be89e220` and generated independently with the Solana SDK,
not this Solidity implementation. See
[scripts/generateSolanaVaultVectors.cjs](../../scripts/generateSolanaVaultVectors.cjs).
