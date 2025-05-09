# Eco Routes Cross-Chain Implementation Guide

## Introduction

This guide provides detailed information about the cross-chain implementation in Eco Routes, focusing on the dual-type system that enables compatibility with both EVM chains (like Ethereum) and non-EVM chains (like Solana).

## Architecture Overview

Eco Routes implements a modular architecture that separates concerns while maintaining a unified interface:

```
IntentSource
├── UniversalSource (for cross-chain compatibility)
│   └── BaseSource (common functionality)
└── EvmSource (for Ethereum compatibility)
    └── BaseSource (common functionality)
```

This design enables:
1. **Clean Separation of Concerns**: Each contract handles a specific part of the system
2. **Code Reuse**: Common functionality is shared in the BaseSource contract
3. **Type Safety**: Each implementation handles its specific type system
4. **Unified Interface**: Users interact with a single IntentSource contract

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
    bytes32 token;  // 32 bytes for cross-chain compatibility
    uint256 amount;
}

struct Call {
    bytes32 target;  // 32 bytes for cross-chain compatibility
    bytes data;
    uint256 value;
}

struct Route {
    bytes32 salt;
    uint256 source;
    uint256 destination;
    bytes32 inbox;  // 32 bytes for cross-chain compatibility
    TokenAmount[] tokens;
    Call[] calls;
}

struct Reward {
    bytes32 creator;  // 32 bytes for cross-chain compatibility
    bytes32 prover;   // 32 bytes for cross-chain compatibility
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

## Implementing Cross-Chain Functionality

### BaseSource Contract

The `BaseSource` contract provides common functionality used by both `EvmSource` and `UniversalSource`:

- Shared state storage (`vaults` mapping)
- Common validation functions
- Error handling and events
- Abstract interfaces for intent operations

### EvmSource Contract

The `EvmSource` contract implements intent functionality for EVM chains:

- Uses native `address` type (20 bytes)
- Handles publishing, funding, and reward claiming
- Manages vault creation and interaction
- Implements EVM-specific validation

### UniversalSource Contract

The `UniversalSource` contract implements intent functionality for cross-chain compatibility:

- Uses `bytes32` type (32 bytes) for addresses
- Provides the same operations as `EvmSource` but with universal types
- Converts between `bytes32` and `address` types as needed for vault interaction
- Emits cross-chain compatible events

### IntentSource Contract

The `IntentSource` contract combines both implementations:

- Inherits from both `EvmSource` and `UniversalSource`
- Provides a unified interface for users
- Handles type conversion at the boundary

## Integration Patterns

### Using with EVM Chains

When working only with EVM chains:

```solidity
// Import EVM types
import {Intent, Route, Reward} from "./types/Intent.sol";
import {IIntentSource} from "./interfaces/IIntentSource.sol";

// Create intent with address types
Intent memory intent = Intent({
    route: Route({
        salt: bytes32(0),
        source: 1,
        destination: 2,
        inbox: 0x1234...,  // regular address
        tokens: tokenAmounts,
        calls: calls
    }),
    reward: Reward({...})
});

// Use the IntentSource contract with IIntentSource interface
IIntentSource intentSource = IIntentSource(intentSourceAddress);
bytes32 intentHash = intentSource.publish(intent);
```

### Using with Cross-Chain Applications

When working with both EVM and non-EVM chains:

```solidity
// Import universal types
import {Intent, Route, Reward} from "./types/UniversalIntent.sol";
import {IUniversalIntentSource} from "./interfaces/IUniversalIntentSource.sol";
import {AddressConverter} from "./libs/AddressConverter.sol";

// Create intent with bytes32 identifiers
Intent memory intent = Intent({
    route: Route({
        salt: bytes32(0),
        source: 1,
        destination: 2,
        inbox: AddressConverter.toBytes32(0x1234...),  // convert EVM address to bytes32
        tokens: tokenAmounts,
        calls: calls
    }),
    reward: Reward({
        creator: AddressConverter.toBytes32(msg.sender),
        prover: AddressConverter.toBytes32(proverAddress),
        deadline: block.timestamp + 3600,
        nativeValue: 0.1 ether,
        tokens: tokenAmounts
    })
});

// Use the IntentSource contract with IUniversalIntentSource interface
IUniversalIntentSource intentSource = IUniversalIntentSource(intentSourceAddress);
bytes32 intentHash = intentSource.publish(intent);
```

## Technical Implementation Details

### Vault Interaction

When working with vaults:

1. The `UniversalSource` contract converts from Universal types to EVM types when necessary
2. Vault creation uses the EVM types internally via the `_convertToERC20Reward` method
3. Balance checks use the appropriate address representation based on type

### Event Emissions

Events are emitted in both formats:

1. `IntentCreated` for EVM-specific intents (with `address` fields)
2. `UniversalIntentCreated` for Universal intents (with `bytes32` fields converted to `address` for the Ethereum event system)

### Security Considerations

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

## Testing Cross-Chain Functionality

The test suite includes dedicated tests for cross-chain functionality:

1. **UniversalSource.spec.ts**:
   - Tests Universal intent creation and hashing
   - Tests address type conversion
   - Tests funding and intent vault verification
   - Tests edge cases and validations

2. **CrossChainUtils.spec.ts**:
   - Tests the AddressConverter library
   - Validates address conversion safety

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