# Example: Type Mismatch in Failing Test

## The Problem in Detail

Here's what happens in the failing "Cross-VM Claimant Compatibility" test:

### 1. Test Creates Old-Style Route

```typescript
const route = {
  salt: salt,
  deadline: timeStamp + 1000,
  portal: await inbox.getAddress(), // Returns "0x123..." (address)
  tokens: [
    {
      token: await token.getAddress(), // Returns "0x456..." (address)
      amount: amount,
    },
  ],
  calls: [
    {
      target: await token.getAddress(), // Returns "0x456..." (address)
      data: calldata,
      value: 0,
    },
  ],
}
```

### 2. Test Partially Converts to UniversalIntent

```typescript
const universalIntent = convertIntentToUniversal({
  destination,
  route, // ⚠️ This contains addresses, not bytes32
  reward, // ⚠️ This contains addresses, not bytes32
})
```

### 3. The Conversion Function Tries to Help

```typescript
// In convertRouteToUniversal():
return {
  salt: route.salt,
  deadline: route.deadline,
  portal: TypeCasts.addressToBytes32(route.portal), // Converts to bytes32
  tokens: route.tokens.map(convertTokenAmountToUniversal),
  calls: route.calls.map(convertCallToUniversal),
}
```

### 4. But the Test Passes the Original Route!

```typescript
await inbox.connect(solver).fulfillAndProve(
  intentHash,
  route, // ❌ Passing original route with addresses!
  rewardHash,
  nonAddressClaimant,
  await hyperProver.getAddress(),
  sourceChainID,
  data,
  { value: fee },
)
```

### 5. Contract Expects Route with Addresses

The Inbox contract's Route struct expects:

```solidity
struct Route {
  bytes32 salt;
  uint64 deadline;
  address portal; // ✅ address type
  TokenAmount[] tokens; // Contains address types
  Call[] calls; // Contains address types
}
```

### 6. But Test Has Non-Address Data

The test uses:

```typescript
const nonAddressClaimant = ethers.keccak256(
  ethers.toUtf8Bytes("non-evm-claimant-identifier"),
)
// Results in: "0x7f8b2c3d4e5f6071829394a5b6c7d8e9fa0b1c2d3e4f506172839495a6b7c8d9"
```

### 7. Ethers.js Tries to Process

When ethers.js encounters this data in a Route struct where it expects addresses:

1. It sees a string that doesn't look like an address
2. It assumes it might be an ENS name
3. It tries to resolve it
4. Hardhat's provider doesn't implement ENS resolution
5. **BOOM!** `NotImplementedError: Method 'HardhatEthersProvider.resolveName' is not implemented`

## The Deep Problem

The test is trying to test cross-VM compatibility by using non-EVM identifiers, but:

1. The Route struct still uses `address` types
2. The test creates data that violates these type constraints
3. Ethers.js enforces type safety and fails
4. The conversion between Intent and UniversalIntent happens at the wrong layer

## Why It Can't Be Simply Fixed

1. **Changing to UniversalRoute everywhere** would require changing the Inbox contract
2. **Keeping Route with addresses** means we can't test cross-VM scenarios properly
3. **The test's core assumption** (that we can use non-address bytes32 in address fields) is invalid
4. **The architecture has changed** but the tests haven't been updated to match

This is why these 6 tests need significant refactoring - they're testing scenarios that are architecturally incompatible with the current contract design.
