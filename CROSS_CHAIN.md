# Eco Routes Cross-Chain Implementation Guide

## Overview

Eco Routes is designed to facilitate cross-chain messaging and intent execution. The core data structures (Intent, Route, Call, TokenAmount) were initially designed with Ethereum's `address` type (20 bytes) in mind. To enable compatibility with non-EVM chains like Solana that use 32-byte account IDs, we've implemented a dual-type system with comprehensive conversion utilities.

### Design Principles

1. **Backward Compatibility**: All existing EVM-specific code continues to work unchanged.
2. **Universal Type System**: New Universal types using `bytes32` instead of `address` for cross-chain compatibility.
3. **Easy Conversion**: Utilities for converting between EVM and Universal types.
4. **Dual Signature Verification**: Support for verifying signatures against both type systems.
5. **Identical Structure**: The Universal types mirror the EVM types exactly, just with different field types.

## Architecture Overview

Eco Routes implements a modular architecture that separates concerns while maintaining a unified interface:

```
Portal
├── UniversalSource (for cross-chain compatibility)
│   └── EvmSource (for Ethereum compatibility)
│       └── BaseSource (common functionality)
└── Inbox (fulfillment functionality)
```

This design enables:

1. **Clean Separation of Concerns**: Each contract handles a specific part of the system
2. **Code Reuse**: Common functionality is shared in the BaseSource contract
3. **Type Safety**: Each implementation handles its specific type system
4. **Unified Interface**: Users interact with a single Portal contract

## Type System Implementation

### EVM Types (20-byte addresses)

The original Eco Routes implementation uses Ethereum's native `address` type (20 bytes):

```solidity
// From Intent.sol
struct TokenAmount {
  address token;
  uint256 amount;
}

struct Call {
  address target;
  bytes data;
  uint256 value;
}

struct Route {
  bytes32 salt;
  uint256 source;
  uint256 destination;
  address inbox;
  TokenAmount[] tokens;
  Call[] calls;
}

struct Reward {
  address creator;
  address prover;
  uint256 deadline;
  uint256 nativeValue;
  TokenAmount[] tokens;
}

struct Intent {
  Route route;
  Reward reward;
}
```

### Universal Types (32-byte identifiers)

For cross-chain compatibility, we've introduced parallel types using `bytes32` instead of `address`:

```solidity
// From UniversalIntent.sol
struct TokenAmount {
  bytes32 token; // 32 bytes for cross-chain compatibility
  uint256 amount;
}

struct Call {
  bytes32 target; // 32 bytes for cross-chain compatibility
  bytes data;
  uint256 value;
}

struct Route {
  bytes32 salt;
  uint256 source;
  uint256 destination;
  bytes32 inbox; // 32 bytes for cross-chain compatibility
  TokenAmount[] tokens;
  Call[] calls;
}

struct Reward {
  bytes32 creator; // 32 bytes for cross-chain compatibility
  bytes32 prover; // 32 bytes for cross-chain compatibility
  uint256 deadline;
  uint256 nativeValue;
  TokenAmount[] tokens;
}

struct Intent {
  Route route;
  Reward reward;
}
```

### Type Conversion

The `AddressConverter` library provides utilities for converting between the two address formats:

```solidity
// From address (20 bytes) to bytes32 (32 bytes)
function toBytes32(address _addr) public pure returns (bytes32) {
  return bytes32(uint256(uint160(_addr)));
}

// From bytes32 (32 bytes) to address (20 bytes)
function toAddress(bytes32 _bytes32) public pure returns (address) {
  require(isValidEthereumAddress(_bytes32), "Invalid Ethereum address");
  return address(uint160(uint256(_bytes32)));
}

// Check if a bytes32 value represents a valid Ethereum address
function isValidEthereumAddress(bytes32 _bytes32) public pure returns (bool) {
  // Top 12 bytes should be zero for a valid Ethereum address
  return uint256(_bytes32) >> 160 == 0;
}
```

## Implementation Details

### Core Components

1. **BaseSource Contract**:

   - Shared state storage (`vaults` mapping)
   - Common validation functions
   - Error handling and events
   - Abstract interfaces for intent operations

2. **EvmSource Contract**:

   - Uses native `address` type (20 bytes)
   - Handles publishing, funding, and reward claiming
   - Manages vault creation and interaction
   - Implements EVM-specific validation

3. **UniversalSource Contract**:

   - Uses `bytes32` type (32 bytes) for addresses
   - Provides the same operations as `EvmSource` but with universal types
   - Converts between `bytes32` and `address` types as needed for vault interaction
   - Emits cross-chain compatible events

4. **Portal Contract**:

   - Inherits from both `UniversalSource` and `Inbox`
   - Provides a unified interface for users
   - Handles type conversion at the boundary

5. **AddressConverter Library**:

   - Simple type conversion utilities between `address` and `bytes32`
   - Validation functions to ensure safe conversions
   - Array conversion functions for bulk operations

6. **DualSignatureVerifier Library**:
   - Verifies EIP-712 signatures against either format
   - Supports both OnchainCrosschainOrderData and GaslessCrosschainOrderData structures
   - Computes correct typehashes for both formats

### Technical Design

Both type systems leverage the fact that in EVM, the `address` type is a 20-byte value that gets padded to 32 bytes when ABI-encoded:

- In EVM, an address is stored as 20 bytes (160 bits)
- When encoded, it's padded to 32 bytes
- The `bytes32` type in the universal format exactly matches this encoding pattern

This approach enables:

- Easy conversion between types with no data loss (for EVM addresses)
- Native representation for non-EVM chain addresses (full 32 bytes)
- Optimized gas usage when working within a single chain type

## Usage Examples

### For EVM-Only Applications

EVM-only applications can continue to use the original types and interfaces:

```solidity
// Import EVM types
import {Intent, Route, Call, TokenAmount, Reward} from "./types/Intent.sol";
import {IIntentSource} from "./interfaces/IIntentSource.sol";

// Create an intent
Intent memory intent = Intent({
    route: Route({
        salt: bytes32(0),
        source: 1,
        destination: 2,
        inbox: 0x1234567890123456789012345678901234567890,
        tokens: new TokenAmount[](0),
        calls: new Call[](0)
    }),
    reward: Reward({
        creator: msg.sender,
        prover: 0x2345678901234567890123456789012345678901,
        deadline: block.timestamp + 3600,
        nativeValue: 0,
        tokens: new TokenAmount[](0)
    })
});

// Use the Portal contract with IIntentSource interface
IIntentSource intentSource = IIntentSource(portalAddress);
bytes32 intentHash = intentSource.publish(intent);
```

### For Cross-Chain Applications

Cross-chain applications should use the Universal types:

```solidity
// Import Universal types
import {Intent, Route, Call, TokenAmount, Reward} from "./types/UniversalIntent.sol";
import {IUniversalIntentSource} from "./interfaces/IUniversalIntentSource.sol";
import {AddressConverter} from "./libs/AddressConverter.sol";

// Create a universal intent
Intent memory intent = Intent({
    route: Route({
        salt: bytes32(0),
        source: 1,
        destination: 2,
        inbox: AddressConverter.toBytes32(0x1234567890123456789012345678901234567890),
        tokens: new TokenAmount[](0),
        calls: new Call[](0)
    }),
    reward: Reward({
        creator: AddressConverter.toBytes32(msg.sender),
        prover: AddressConverter.toBytes32(0x2345678901234567890123456789012345678901),
        deadline: block.timestamp + 3600,
        nativeValue: 0,
        tokens: new TokenAmount[](0)
    })
});

// Use the Portal contract with IUniversalIntentSource interface
IUniversalIntentSource intentSource = IUniversalIntentSource(portalAddress);
bytes32 intentHash = intentSource.publish(intent);
```

## Type Handling for Non-EVM Chains

For non-EVM chains like Solana:

1. Convert Solana's 32-byte account IDs directly to `bytes32` fields in Universal types.
2. When receiving data from an EVM chain, convert `address` types to `bytes32` by padding with zeros.
3. When sending data to an EVM chain, ensure the bytes32 value is a valid Ethereum address by checking that the top 12 bytes are zero.

## Security Considerations

When implementing cross-chain functionality:

1. **Type Validation**: Always validate address conversions

   - Use `AddressConverter.isValidEthereumAddress()` before converting from `bytes32` to `address`
   - Ensure addresses have correct format for the target chain

2. **Chain ID Validation**:

   - Check that intents are published on the correct chain using `_validateSourceChain`
   - Enforce chain-specific security rules

3. **Error Handling**:

   - Use specific error types for different failure scenarios
   - Maintain consistent error messages across implementations

4. **Signature Verification**:
   - For cross-chain applications, verify signatures against both EVM and Universal typehashes
   - Maintain backward compatibility by keeping the original EVM types for existing applications

## Event Emissions

Events are emitted in both formats:

1. `IntentCreated` for EVM-specific intents (with `address` fields)
2. `UniversalIntentCreated` for Universal intents (with `bytes32` fields converted to `address` for the Ethereum event system)

## Testing

The cross-chain utilities include comprehensive tests:

1. **UniversalSource.spec.ts**:

   - Tests Universal intent creation and hashing
   - Tests address type conversion
   - Tests funding and intent vault verification
   - Tests edge cases and validations

2. **CrossChainUtils.spec.ts**:
   - Tests the AddressConverter library
   - Validates address conversion safety

Run the tests with:

```bash
npx hardhat test test/CrossChainUtils.spec.ts
```

## Best Practices

1. **Choose the Right Format**:

   - Use EVM types (`Intent.sol`) for EVM-only applications
   - Use Universal types (`UniversalIntent.sol`) for cross-chain applications

2. **Type Conversion**:

   - Convert at the edge of your application, not in core logic
   - Always validate address conversions

3. **Error Handling**:

   - Handle chain-specific error conditions
   - Provide clear error messages

4. **Testing**:
   - Test with both EVM and simulated non-EVM addresses
   - Verify type conversion in edge cases

## Conclusion

The dual-type system enables Eco Routes to work seamlessly across different blockchain environments while maintaining backward compatibility with existing integrations. By supporting both 20-byte Ethereum addresses and 32-byte universal identifiers, the protocol can connect users and liquidity across the entire blockchain ecosystem.
