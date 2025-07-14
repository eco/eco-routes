# Analysis of 6 Failing Tests

## Overview

There are 6 failing tests across HyperProver and MetaProver test suites. All failures are related to deep architectural incompatibilities between the old Intent-based system and the new UniversalIntent-based system.

## Root Cause Analysis

### 1. Ethers.js ENS Resolution Error

The immediate error is:

```
NotImplementedError: Method 'HardhatEthersProvider.resolveName' is not implemented
```

This occurs because ethers.js is trying to resolve what it thinks might be an ENS name. This happens when:

- A string value is passed where ethers expects an address
- The ABI expects an `address` type but receives something that doesn't look like a valid address

### 2. Data Structure Mismatch

The tests are using a mix of old and new data structures:

**Old Intent System:**

- Uses `address` types throughout (portal, token, target, creator, prover)
- Direct address comparisons
- Simple type conversions

**New UniversalIntent System:**

- Uses `bytes32` for cross-chain compatibility
- Requires TypeCasts.addressToBytes32() conversions
- Different hashing mechanisms

### 3. Parameter Order Issues

In MetaProver tests, `fulfillAndProve` is being called with incorrect parameter order:

```typescript
// Wrong (test code):
inbox.fulfillAndProve(
  sourceChainID, // ❌ Should be intentHash
  route,
  rewardHash,
  nonAddressClaimant,
  intentHash, // ❌ Should be source
  prover,
  data,
)

// Correct (per interface):
inbox.fulfillAndProve(
  intentHash,
  route,
  rewardHash,
  claimant,
  prover,
  source,
  data,
)
```

## Why These Tests Need Major Refactoring

### 1. Deep Type System Changes

The tests create Route and Reward objects using the old Intent types:

```typescript
const route = {
    salt: salt,
    deadline: timeStamp + 1000,
    portal: await inbox.getAddress(),  // ❌ address, not bytes32
    tokens: routeTokens,               // ❌ contains addresses
    calls: [...]                       // ❌ contains addresses
}
```

But the contracts now expect the Portal to handle UniversalIntent types where addresses are bytes32.

### 2. Complex Data Flow

The failing tests are end-to-end tests that:

1. Create intents with old data structures
2. Convert them partially to UniversalIntent
3. Pass them through multiple contract calls
4. Expect specific behaviors based on old assumptions

The conversion happens at multiple levels:

- In the test setup
- In the fulfillAndProve call
- In the contract internals
- In the prover logic

### 3. Hash Calculation Differences

The tests use both:

- `hashIntent()` from the old system
- `hashUniversalIntent()` from the new system

These produce different hashes for the same logical intent, causing validation failures.

### 4. Cross-VM Compatibility Testing

The failing tests specifically test cross-VM scenarios with non-EVM addresses:

```typescript
const nonAddressClaimant = ethers.keccak256(
  ethers.toUtf8Bytes("non-evm-claimant-identifier"),
)
```

This creates a bytes32 that doesn't represent a valid Ethereum address, which:

- Triggers ENS resolution attempts in ethers.js
- Breaks assumptions about address validity
- Requires careful handling throughout the stack

## Required Refactoring

To fix these tests properly, we need to:

1. **Completely rewrite test data structures** to use UniversalIntent types from the start
2. **Fix all parameter ordering** in contract calls
3. **Update hash calculations** to use the universal system consistently
4. **Handle type conversions** explicitly at every boundary
5. **Mock or bypass ENS resolution** for non-address bytes32 values
6. **Restructure test expectations** to match the new cross-chain architecture

## Why Simple Fixes Won't Work

1. **Changing parameter order alone** won't fix the type mismatches
2. **Converting types at call sites** won't fix the hash calculation issues
3. **Patching individual conversions** won't fix the systemic architectural differences
4. **The ethers.js error** is a symptom, not the root cause - it's trying to process invalid data

These tests fundamentally assume the old Intent architecture and need to be rewritten for the UniversalIntent system.
