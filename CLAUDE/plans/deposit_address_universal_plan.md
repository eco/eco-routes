# Deposit Addresses Implementation Plan - Universal (Multi-Chain) Version

## Overview
Implement a **chain-agnostic** per-user deposit address system where each user gets a deterministically-derived deposit contract that enables automatic cross-chain intent creation. Supports:
- EVM to EVM
- Solana to Solana
- EVM to Solana
- Solana to EVM
- Any cross-chain combination

## User Requirements (Confirmed)
- Destination addresses: Always `bytes32` (EVM addresses left-padded with zeros)
- Factory scope: Multi-destination (supports multiple destination chains)
- Token configuration: User-specified per deposit (source token + target token)
- No Hyperlane recovery mechanism for MVP

## Architecture

### Two New Contracts

1. **DepositFactory** - Generic factory that deploys deterministic deposit addresses for any chain pair and token pair
2. **DepositAddress** - Individual deposit contract that creates intents with user-specified parameters

## Implementation Details

### 1. DepositFactory Contract
**New File**: `contracts/DepositFactory.sol`

**Immutable Configuration** (minimal - only infrastructure):
```solidity
address public immutable PORTAL_ADDRESS;            // Routes Portal on source chain
address public immutable PROVER_ADDRESS;            // Default prover (can be overridden)
uint64 public immutable INTENT_DEADLINE_DURATION;   // e.g., 7 days
```

**Key Functions**:
```solidity
// Compute deterministic address for complete deposit configuration
function getAddress(
    bytes32 destinationAddress,   // User's destination wallet (bytes32 - works for EVM and non-EVM)
    uint64 destinationChain,      // Destination chain ID
    address sourceToken,          // Source ERC20 token on this chain
    bytes32 targetToken           // Target token on destination chain (bytes32)
) public view returns (address)

// Deploy deposit address using CREATE2
function deploy(
    bytes32 destinationAddress,
    uint64 destinationChain,
    address sourceToken,
    bytes32 targetToken
) external returns (address)

// Overload with custom portal address for destination chain
function deploy(
    bytes32 destinationAddress,
    uint64 destinationChain,
    address sourceToken,
    bytes32 targetToken,
    bytes32 destinationPortal     // Portal address on destination chain (bytes32)
) external returns (address)

// Check if address already deployed
function isDeployed(
    bytes32 destinationAddress,
    uint64 destinationChain,
    address sourceToken,
    bytes32 targetToken
) external view returns (bool)
```

**CREATE2 Pattern**:
- Salt: `keccak256(abi.encodePacked(destinationAddress, destinationChain, sourceToken, targetToken))`
- Each unique combination of (destination, chain, source token, target token) gets unique address
- Fully deterministic and predictable
- Anyone can deploy, permissionless

### 2. DepositAddress Contract
**New File**: `contracts/DepositAddress.sol`

**Immutable Configuration** (set at construction - fully generic):
```solidity
bytes32 public immutable DESTINATION_ADDRESS;      // User's destination wallet (bytes32 - works for any chain)
uint64 public immutable DESTINATION_CHAIN;         // Destination chain ID (Solana, Ethereum, etc.)
bytes32 public immutable TARGET_TOKEN;             // Target token on destination (bytes32)
address public immutable PORTAL_ADDRESS;           // Routes Portal on source chain
address public immutable PROVER_ADDRESS;           // Prover contract
address public immutable SOURCE_TOKEN;             // Source ERC20 token on source chain
bytes32 public immutable DESTINATION_PORTAL;       // Portal address on destination chain (bytes32)
uint64 public immutable INTENT_DEADLINE_DURATION;  // Intent expiry duration
```

**Address Format Notes**:
- `DESTINATION_ADDRESS`: bytes32 format
  - For EVM addresses: left-pad 20-byte address with 12 zero bytes
  - For Solana: use 32-byte public key directly
  - For other chains: use native 32-byte format or pad as needed
- `TARGET_TOKEN`: bytes32 format
  - For EVM tokens: left-pad 20-byte address with zeros
  - For Solana SPL: use 32-byte mint address
  - For native tokens: use special marker like `bytes32(0)` or chain-specific convention

**Core Function**:
```solidity
function createIntent(uint256 amount) external nonReentrant returns (bytes32 intentHash)
```

**Intent Construction Logic**:

1. **Route Configuration**:
   ```solidity
   Route({
       salt: keccak256(abi.encodePacked(DESTINATION_ADDRESS, block.timestamp, amount)),
       deadline: uint64(block.timestamp) + INTENT_DEADLINE_DURATION,
       portal: address(0), // Sentinel - actual portal is DESTINATION_PORTAL (bytes32)
       nativeAmount: 0,
       tokens: [TokenAmount({token: address(0), amount: amount})], // Sentinel - actual token is TARGET_TOKEN
       calls: [] // Empty - simple token transfer, no execution needed
   })
   ```

2. **Reward Configuration**:
   ```solidity
   Reward({
       deadline: uint64(block.timestamp) + INTENT_DEADLINE_DURATION,
       creator: address(this), // DepositAddress is the creator (authorization point)
       prover: PROVER_ADDRESS,
       nativeAmount: 0,
       tokens: [TokenAmount({token: SOURCE_TOKEN, amount: amount})] // Actual source chain ERC20
   })
   ```

3. **Intent Creation Flow**:
   - Validate amount > 0 and amount <= balance
   - Construct Intent struct with validated parameters
   - Approve Portal to spend SOURCE_TOKEN
   - Call `Portal.publishAndFund(intent, false)` atomically
   - Emit `IntentCreated` event with full deposit configuration (destination address, chain, tokens)

**Key Design Decision: Sentinel Addresses**
- Use `address(0)` in Route.portal and Route.tokens.token fields
- Actual destination addresses (bytes32 format) stored in contract immutables
- Off-chain infrastructure (backend orchestrator + solvers) interprets sentinel addresses based on:
  - `Intent.destination` chain ID
  - Contract immutables (DESTINATION_ADDRESS, TARGET_TOKEN, DESTINATION_PORTAL)
  - Events that emit full bytes32 values
- This pattern works for **any chain combination** (EVM↔EVM, EVM↔Solana, etc.)

**Why This Works Cross-VM**:
- Routes Protocol already designed for cross-VM compatibility
- Intent struct uses uint64 for chain IDs (not limited to EVM)
- Prover/solver infrastructure interprets intent based on destination chain
- bytes32 format accommodates both 20-byte (EVM) and 32-byte (Solana, etc.) addresses

**Security**:
- ReentrancyGuard on createIntent
- No owner/access control (permissionless by design)
- Validation: amount checks, constructor parameter validation

**Helper Function**:
```solidity
function getInfo() external view returns (
    bytes32 destinationAddress,      // Generic destination (works for any chain)
    uint64 destinationChain,          // Destination chain ID
    bytes32 targetToken,              // Target token (bytes32)
    address sourceToken,              // Source token (address)
    bytes32 destinationPortal,        // Destination portal (bytes32)
    uint256 balance                   // Current balance
)
```

**Utility Functions**:
```solidity
// Helper to convert EVM address to bytes32 (for off-chain use)
function addressToBytes32(address addr) public pure returns (bytes32) {
    return bytes32(uint256(uint160(addr)));
}

// Helper to extract EVM address from bytes32 (for off-chain use)
function bytes32ToAddress(bytes32 b) public pure returns (address) {
    return address(uint160(uint256(b)));
}
```

## Testing Strategy

### Unit Tests
**File**: `test/core/DepositFactory.t.sol`
- Factory deployment with valid/invalid parameters
- getAddress returns deterministic addresses
- getAddress with different chains/tokens returns different addresses
- deploy creates address at predicted location
- isDeployed returns correct status
- CREATE2 collision handling

**File**: `test/core/DepositAddress.t.sol`
- createIntent validates amount correctly
- createIntent constructs Intent with correct fields
- createIntent approves and funds vault
- createIntent emits events correctly
- Reentrancy protection
- Multiple createIntent calls work

### Integration Tests
**File**: `test/integration/DepositFlow.t.sol`
- End-to-end flow: deploy factory → get address → transfer tokens → deploy deposit address → create intent
- Verify intent published and funded correctly
- Mock solver fulfillment and prover verification
- Test reward withdrawal
- Test multiple chain combinations (EVM→EVM, EVM→Solana)

## Critical Files

### New Files to Create
- `contracts/DepositFactory.sol` - Factory contract
- `contracts/DepositAddress.sol` - Deposit address contract
- `test/core/DepositFactory.t.sol` - Factory tests
- `test/core/DepositAddress.t.sol` - Deposit address tests
- `test/integration/DepositFlow.t.sol` - Integration tests

### Existing Files to Reference
- `contracts/Portal.sol` - Portal interface (lines 1-21)
- `contracts/IntentSource.sol` - publishAndFund implementation (lines 274-310)
- `contracts/types/Intent.sol` - Intent, Route, Reward structs (entire file)
- `contracts/interfaces/IIntentSource.sol` - Intent source interface

## Examples: Chain-Agnostic Usage

### Example 1: EVM → Solana (Original use case)
```solidity
// User wants: Ethereum USDC → Solana USDC
factory.getAddress(
    0x1234...5678, // Solana wallet (32-byte pubkey)
    5107100,       // Solana mainnet
    0xA0b8...eB48, // USDC on Ethereum
    0xEPjF...Dt1v  // USDC on Solana (32-byte SPL mint)
)
```

### Example 2: EVM → EVM
```solidity
// User wants: Ethereum USDC → Arbitrum USDC
factory.getAddress(
    bytes32(uint256(uint160(0x9876...4321))), // Arbitrum wallet (EVM address padded)
    42161,                                      // Arbitrum One
    0xA0b8...eB48,                             // USDC on Ethereum
    bytes32(uint256(uint160(0xaf88...d566)))   // USDC on Arbitrum (padded)
)
```

### Example 3: Solana → EVM
```solidity
// User wants: Solana USDC → Ethereum USDC
// (Would be deployed on Solana, but same pattern)
factory.getAddress(
    bytes32(uint256(uint160(0xabcd...ef01))), // Ethereum wallet (padded)
    1,                                          // Ethereum mainnet
    0x...,                                     // USDC SPL on Solana (as address type on Solana VM)
    bytes32(uint256(uint160(0xA0b8...eB48)))  // USDC on Ethereum (padded)
)
```

## Deployment Checklist

1. Deploy DepositFactory with Portal and Prover addresses
2. Verify contracts on block explorer
3. Test with small amounts first for multiple chain pairs
4. Set up backend orchestrator to monitor deposit addresses
5. Coordinate with solver teams on sentinel address interpretation
6. Monitor first intents through to fulfillment

## Notes

- No ownership/upgradeability for MVP (immutable contracts)
- Backend orchestrator responsibility: monitor deposits, call deploy() and createIntent()
- Solver responsibility: interpret sentinel addresses, fulfill intents on destination chain, call prover
- Recovery mechanism deferred to post-MVP (per requirements document recommendation)
- Maximum flexibility: one factory can serve all chain pairs and token pairs
