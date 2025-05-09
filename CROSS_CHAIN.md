# Eco Routes Cross-Chain Implementation

## Overview

Eco Routes is designed to facilitate cross-chain messaging and intent execution. The core data structures (Intent, Route, Call, TokenAmount) were initially designed with Ethereum's `address` type (20 bytes) in mind. To enable compatibility with non-EVM chains like Solana that use 32-byte account IDs, we've implemented a dual-type system with comprehensive conversion utilities.

### Design Principles

1. **Backward Compatibility**: All existing EVM-specific code continues to work unchanged.
2. **Universal Type System**: New Universal types using `bytes32` instead of `address` for cross-chain compatibility.
3. **Easy Conversion**: Utilities for converting between EVM and Universal types.
4. **Dual Signature Verification**: Support for verifying signatures against both type systems.
5. **Identical Structure**: The Universal types mirror the EVM types exactly, just with different field types.

## Implementation Details

### Architecture

The implementation uses a modular architecture for better code organization and reuse:

1. **BaseSource**: Common functionality shared across implementations
2. **EvmSource**: Implementation for EVM chains with `address` (20 bytes) types
3. **UniversalSource**: Implementation for cross-chain with `bytes32` (32 bytes) types
4. **IntentSource**: Main entry point combining both implementations

```
IntentSource
├── UniversalSource (for cross-chain compatibility)
│   └── BaseSource (common functionality)
└── EvmSource (for Ethereum compatibility)
    └── BaseSource (common functionality)
```

### Data Structures

The implementation maintains two parallel sets of data structures:

1. **EVM-specific Types** (in `Intent.sol` and `EcoERC7683.sol`):
   - Use `address` (20 bytes) for Ethereum addresses
   - Maintain backward compatibility

2. **Universal Types** (in `UniversalIntent.sol` and `UniversalEcoERC7683.sol`):
   - Use `bytes32` (32 bytes) for cross-chain account IDs
   - Same structure and field names as EVM types

### Core Components

1. **AddressConverter Library**:
   - Simple type conversion utilities between `address` and `bytes32`
   - Validation functions to ensure safe conversions
   - Array conversion functions for bulk operations

2. **Source Contracts**:
   - `BaseSource`: Shared logic for both implementations
   - `EvmSource`: EVM-specific intent functionality
   - `UniversalSource`: Cross-chain compatible functionality
   - `IntentSource`: Entry point combining both approaches

3. **DualSignatureVerifier Library**:
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
```

### For Cross-Chain Applications

Cross-chain applications should use the Universal types:

```solidity
// Import Universal types
import {Intent, Route, Call, TokenAmount, Reward} from "./types/UniversalIntent.sol";
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
```

### Dual Implementation Architecture

Eco Routes uses inheritance and composition to create a clean, modular architecture:

```solidity
// BaseSource provides common functionality
abstract contract BaseSource {
    // Common functionality used by both implementations
    function _validateSourceChain(...) internal virtual { ... }
    function _returnExcessEth(...) internal virtual { ... }
    // ...other common functionality
}

// EvmSource implements EVM-specific functionality
abstract contract EvmSource is IIntentSource, BaseSource {
    // EVM-specific implementation
    function getIntentHash(Intent calldata intent) external returns (...) { ... }
    function publish(Intent calldata intent) external returns (...) { ... }
    // ...other EVM-specific functions
}

// UniversalSource implements cross-chain functionality
abstract contract UniversalSource is IUniversalIntentSource, BaseSource {
    // Cross-chain implementation
    function getIntentHash(Intent calldata intent) external returns (...) { ... }
    function publish(Intent calldata intent) external returns (...) { ... }
    // ...other universal functions
}

// IntentSource combines both implementations
contract IntentSource is UniversalSource, EvmSource, Semver {
    // Main entry point combining both implementations
    // Function calls are routed to the appropriate parent implementation
}
```

This architecture allows:
1. Code reuse through shared functionality in BaseSource
2. Clear separation of EVM and Universal implementations
3. Combined interface in the IntentSource contract
4. No need for type conversions in the main execution path

### Using the Interfaces

Clients can interact with either interface:

```solidity
// Import IIntentSource for EVM-only applications
import {IIntentSource} from "./interfaces/IIntentSource.sol";
import {Intent} from "./types/Intent.sol";

// Use the EVM-specific interface and types
IIntentSource intentSource = /* get contract address */;
Intent memory evmIntent = /* create EVM intent */;
bytes32 intentHash = intentSource.publish(evmIntent);

// Import IUniversalIntentSource for cross-chain applications
import {IUniversalIntentSource} from "./interfaces/IUniversalIntentSource.sol";
import {Intent as UniversalIntent} from "./types/UniversalIntent.sol";

// Use the Universal-specific interface and types
IUniversalIntentSource universalIntentSource = /* get contract address */;
UniversalIntent memory universalIntent = /* create Universal intent */;
bytes32 intentHash = universalIntentSource.publish(universalIntent);
```

## Type Handling for Non-EVM Chains

For non-EVM chains like Solana:

1. Convert Solana's 32-byte account IDs directly to `bytes32` fields in Universal types.
2. When receiving data from an EVM chain, convert `address` types to `bytes32` by padding with zeros.
3. When sending data to an EVM chain, ensure the bytes32 value is a valid Ethereum address by checking that the top 12 bytes are zero.

## Safety Considerations

When working with cross-chain conversions:

1. **Type Validation**: Always check that a `bytes32` value is a valid Ethereum address before converting to `address`:

   ```solidity
   // Safe conversion from bytes32 to address
   function safeToAddress(bytes32 b) internal pure returns (address) {
       require(AddressConverter.isValidEthereumAddress(b), "Invalid Ethereum address");
       return AddressConverter.toAddress(b);
   }
   ```

2. **Signature Verification**: For cross-chain applications, verify signatures against both EVM and Universal typehashes.
3. **Backward Compatibility**: Maintain backward compatibility by keeping the original EVM types for existing applications.

## Testing

The cross-chain utilities include comprehensive tests:

1. **AddressConverter Tests**: Ensure address-bytes32 conversions work correctly.
2. **IntentConverter Tests**: Verify that all fields are properly converted.
3. **DualSignatureVerifier Tests**: Confirm signatures work with both type systems.

Run the tests with:

```bash
npx hardhat test test/CrossChainUtils.spec.ts
```