# Cross-Chain Compatibility Architecture

## Overview

Eco Protocol now supports both EVM chains and non-EVM chains (like Solana) with a dual-type approach that maintains backward compatibility while enabling cross-chain functionality.

## Key Components

### 1. Dual Type System

The protocol uses two parallel type systems:

1. **EVM-Specific (Intent.sol)**
   - Uses Ethereum's native `address` type (20 bytes)
   - Maintains backward compatibility with existing integrations
   - Optimized for EVM-chain interactions

2. **Universal Cross-Chain (UniversalIntent.sol)**
   - Uses `bytes32` for address identifiers
   - Compatible with all blockchain platforms
   - Designed for cross-chain messaging

### 2. Type Conversion

The `IntentConverter` utility provides seamless conversion between the two type systems, making it simple to move between EVM-specific and universal formats:

```solidity
// Convert from EVM to universal format
UniversalIntent memory universalIntent = IntentConverter.toUniversalIntent(intent);

// Convert from universal to EVM format
Intent memory intent = IntentConverter.toIntent(universalIntent);
```

### 3. Implementation Design

Both type systems leverage the fact that in EVM, the `address` type is a 20-byte value that gets padded to 32 bytes when ABI-encoded:

- In EVM, an address is stored as 20 bytes (160 bits)
- When encoded, it's padded to 32 bytes
- The `bytes32` type in the universal format exactly matches this encoding pattern

This approach enables:
- Easy conversion between types with no data loss (for EVM addresses)
- Native representation for non-EVM chain addresses (full 32 bytes)
- Optimized gas usage when working within a single chain type

## Usage Guidelines

### For EVM-Only Applications

If your integration only needs to work with EVM chains:

```solidity
// Import EVM-specific types
import {Intent, Route, Reward} from "./types/Intent.sol";

// Create intent with address types
Intent memory intent = Intent({
    route: Route({
        salt: bytes32(0),
        source: 1,
        destination: 2,
        inbox: 0x1234...,  // uses address type
        tokens: tokenAmounts,
        calls: calls
    }),
    reward: Reward({...})
});
```

### For Cross-Chain Applications

If your integration needs to work with both EVM and non-EVM chains:

```solidity
// Import universal types
import {UniversalIntent, UniversalRoute, UniversalReward} from "./types/UniversalIntent.sol";

// Create intent with bytes32 identifiers
UniversalIntent memory intent = UniversalIntent({
    route: UniversalRoute({
        salt: bytes32(0),
        source: 1,
        destination: 2,
        inbox: bytes32(uint256(uint160(0x1234...))),  // for EVM addresses
        // or directly use bytes32 for non-EVM addresses
        tokens: tokenAmounts,
        calls: calls
    }),
    reward: UniversalReward({...})
});
```

### Converting Between Formats

For applications that need to interact with both formats:

```solidity
import {IntentConverter} from "./utils/IntentConverter.sol";

// Convert EVM intent to universal format
UniversalIntent memory universalIntent = IntentConverter.toUniversalIntent(evmIntent);

// Process in universal format (works with all chains)
// ...

// Convert back to EVM format if needed
Intent memory evmIntent = IntentConverter.toIntent(universalIntent);
```

## Best Practices

1. **Choose the Right Format**:
   - Use `Intent.sol` for EVM-only applications
   - Use `UniversalIntent.sol` for cross-chain applications
   - Convert between formats at the edge of your application

2. **Address Handling**:
   - When working with EVM addresses, convert to bytes32 using `bytes32(uint256(uint160(address)))`
   - When working with non-EVM identifiers, use the full bytes32 capacity

3. **Security Considerations**:
   - Always validate address conversions when crossing chain boundaries
   - Be aware that non-EVM addresses won't necessarily match the EVM address pattern (20 bytes + padding)
   - Consider using address verification for each chain type

## Technical Implementation Notes

1. **Storage Efficiency**:
   - Both `address` and `bytes32` types use 32 bytes of storage in Solidity
   - The runtime cost is nearly identical between the two formats

2. **ABI Encoding**:
   - The function signatures differ in the typehash calculations
   - EIP-712 signatures must account for the correct type name

3. **Cross-Chain Addressing**:
   - The universal format accommodates different address formats across chains
   - Non-EVM chains like Solana can use the full 32 bytes for addresses

4. **Gas Optimization**:
   - For operations within EVM chains, the EVM-specific format may use less gas
   - For cross-chain operations, conversion is minimal overhead compared to cross-chain messaging costs