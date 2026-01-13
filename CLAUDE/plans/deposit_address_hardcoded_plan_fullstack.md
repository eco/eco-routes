# Deposit Addresses - Hard-Coded Factory Full-Stack Implementation Plan

## High-Level Overview

### What We're Building
A **deposit address system** where users get deterministic, per-user addresses to send tokens for automatic cross-chain bridging via the Routes Protocol.

### Core Concept: "One Factory = One Route"
Each factory deployment represents a **specific bridge route**:
- Example: "Ethereum USDC → Solana USDC" factory
- Example: "Base USDC → Solana USDC" factory
- Hard-coded: destination chain, source token, target token
- Variable: only the user's destination address

## Architecture (3 Parts)

### PART 1: Smart Contracts

**DepositFactory Contract**:
- Factory creates deposit addresses using CREATE2
- Simple API: `getAddress(bytes32 destinationAddress)` → returns deterministic address
- Hard-coded configuration per deployment (chain, tokens, portal addresses)
- Anyone can call `deploy()` to create a deposit contract

**DepositAddress Contract**:
- Personal deposit contract for each user
- Stores user's destination address + route configuration as immutables
- Has ONE function: `createIntent(uint256 amount)` → creates intent in Routes Portal
- Permissionless: anyone can call (typically the backend orchestrator)
- Uses sentinel address pattern for cross-VM compatibility

**Key Design Pattern - Sentinel Addresses**:
- Intent struct uses `address(0)` for cross-chain addresses
- Actual bytes32 addresses stored in contract immutables and events
- Off-chain infrastructure interprets based on destination chain ID
- Works for any chain: EVM↔EVM, EVM↔Solana, etc.

### PART 2: Backend Orchestrator

A Node.js/Python service that acts as the automation layer:

**5 Core Services**:

1. **Balance Monitor**: Polls deposit addresses every ~60s for new deposits
2. **Contract Deployer**: Auto-deploys deposit contracts on first use
3. **Intent Creator**: Calls `createIntent()` when deposits detected
4. **Intent Status Tracker**: Monitors intent fulfillment via Portal events
5. **Event Indexer** (optional): Historical data for analytics

**Database**:
- MongoDB storing: deposit addresses, balances, intents, statuses
- Tracks: which addresses are deployed, last balance, intent lifecycle

**Workflow**:
```
User sends USDC → Deposit Address
  ↓
Backend detects balance increase
  ↓
Backend deploys contract (if first time)
  ↓
Backend calls createIntent(amount)
  ↓
Intent published to Portal
  ↓
Solver fulfills on destination chain
  ↓
Backend tracks completion
```

### PART 3: Testing & Deployment

**Testing**:
- Unit tests for factory and deposit contracts
- Integration tests for end-to-end flows
- Multi-factory independence tests

**Deployment**:
- Deploy factory with route-specific parameters
- Set up backend orchestrator
- Configure monitoring and alerts
- Start with small test amounts

## Key Benefits of This Design

1. **Simple & Gas Efficient**: Only one parameter (destination address) for deterministic derivation
2. **Chain Agnostic**: Works for EVM↔EVM, EVM↔Solana, Solana↔EVM via bytes32 addressing
3. **Permissionless**: No user setup, anyone can trigger operations
4. **CEX Compatible**: Users can withdraw from centralized exchanges directly to deposit address
5. **Automatic**: Backend handles all orchestration, user just sends tokens

## User Experience

1. User gets their deposit address: `factory.getAddress(myDestinationWallet)`
2. User sends USDC to that address (from wallet, CEX, anywhere)
3. Within ~1-2 minutes, funds automatically bridge to destination chain
4. No signatures, no UI interaction needed

## What Needs to Be Built

### Smart Contracts (2 files)
- `contracts/DepositFactory.sol`
- `contracts/DepositAddress.sol`

### Backend Services (1 service with 5 modules)
- Orchestrator service in Node.js/Python
- MongoDB
- Monitoring/alerting integration

### Tests (3 test suites)
- Unit tests for contracts
- Integration tests for flows
- Backend service tests

---

# Detailed Implementation Plan

## PART 1: SMART CONTRACTS

### DepositFactory Contract
**File**: `contracts/DepositFactory.sol`

**Immutable Configuration**:
```solidity
uint64 public immutable DESTINATION_CHAIN;         // e.g., 5107100 for Solana
address public immutable SOURCE_TOKEN;             // e.g., USDC on Ethereum
bytes32 public immutable TARGET_TOKEN;             // Solana USDC SPL token
address public immutable PORTAL_ADDRESS;           // Routes Portal
address public immutable PROVER_ADDRESS;           // Prover contract
bytes32 public immutable DESTINATION_PORTAL;       // Destination portal
uint64 public immutable INTENT_DEADLINE_DURATION;  // e.g., 7 days
```

**Key Functions**:
```solidity
function getAddress(bytes32 destinationAddress) public view returns (address)
function deploy(bytes32 destinationAddress) external returns (address)
function isDeployed(bytes32 destinationAddress) external view returns (bool)
function getConfiguration() external view returns (...)
```

**CREATE2 Pattern**:
- Salt: `keccak256(abi.encodePacked(destinationAddress))`
- Deterministic and simple

### DepositAddress Contract
**File**: `contracts/DepositAddress.sol`

**Immutable Configuration** (inherited from factory):
```solidity
bytes32 public immutable DESTINATION_ADDRESS;
uint64 public immutable DESTINATION_CHAIN;
bytes32 public immutable TARGET_TOKEN;
address public immutable SOURCE_TOKEN;
address public immutable PORTAL_ADDRESS;
address public immutable PROVER_ADDRESS;
bytes32 public immutable DESTINATION_PORTAL;
uint64 public immutable INTENT_DEADLINE_DURATION;
```

**Core Function**:
```solidity
function createIntent(uint256 amount) external nonReentrant returns (bytes32 intentHash)
```

**Intent Construction**:
1. Route: Uses sentinel addresses (address(0)) for cross-VM compatibility
2. Reward: Uses actual source chain ERC20 address for solver incentive
3. Validation: amount > 0, amount <= balance
4. Execution: Approve Portal, call publishAndFund atomically

## PART 2: BACKEND ORCHESTRATOR

### Service Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Backend Stack                          │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌───────────────┐  ┌────────────────┐  ┌───────────────┐   │
│  │   RPC Node    │  │   Database     │  │   Monitoring  │   │
│  │   Provider    │  │   (MongoDB)    │  │   /Alerts     │   │
│  └───────┬───────┘  └────────┬───────┘  └───────────────┘   │
│          │                   │                              │
│  ┌───────┴───────────────────┴───────────────────────┐      │
│  │          Orchestrator Service (Node.js/Python)    │      │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────┐ │      │
│  │  │   Balance    │  │   Contract   │  │  Intent  │ │      │
│  │  │   Monitor    │  │   Deployer   │  │  Creator │ │      │
│  │  └──────────────┘  └──────────────┘  └──────────┘ │      │
│  └───────────────────────────────────────────────────┘      │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Service 1: Balance Monitor

**Purpose**: Poll deposit addresses for incoming deposits

**Implementation**:
- Polls token balances every 30-60 seconds
- Computes deposit addresses deterministically
- Compares current vs last known balance
- Triggers deployment + intent creation on new deposits

**Database Schema**:
```sql
CREATE TABLE deposit_addresses (
  id SERIAL PRIMARY KEY,
  factory_address VARCHAR(42) NOT NULL,
  user_destination_address VARCHAR(66) NOT NULL, -- bytes32
  deposit_address VARCHAR(42) NOT NULL,
  is_deployed BOOLEAN DEFAULT FALSE,
  last_balance VARCHAR(78) NOT NULL,
  last_checked_at TIMESTAMP NOT NULL,
  created_at TIMESTAMP DEFAULT NOW(),
  UNIQUE(factory_address, user_destination_address)
);
```

### Service 2: Contract Deployer

**Purpose**: Deploy deposit contracts on first deposit

**Implementation**:
- Checks `factory.isDeployed()` before deploying
- Calls `factory.deploy(destinationAddress)`
- Waits for confirmation
- Updates database deployment status
- Handles gas estimation and retries

### Service 3: Intent Creator

**Purpose**: Create intents when deposits are ready

**Implementation**:
- Calls `depositAddress.createIntent(amount)`
- Extracts intent hash from receipt
- Stores intent in database
- Monitors intent status

**Database Schema**:
```sql
CREATE TABLE intents (
  id SERIAL PRIMARY KEY,
  intent_hash VARCHAR(66) NOT NULL UNIQUE,
  deposit_address VARCHAR(42) NOT NULL,
  factory_address VARCHAR(42) NOT NULL,
  user_destination_address VARCHAR(66) NOT NULL,
  amount VARCHAR(78) NOT NULL,
  status VARCHAR(20) NOT NULL, -- pending, funded, fulfilled, failed
  tx_hash VARCHAR(66),
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);
```

### Service 4: Intent Status Tracker

**Purpose**: Monitor intent lifecycle

**Implementation**:
- Subscribe to Portal events (WebSocket or polling)
- Update database on status changes
- Alert on stuck intents (past deadline)
- Track metrics (success rate, fulfillment time)

### Service 5: Event Indexer (Optional)

**Purpose**: Historical data and analytics

**Implementation**:
- Index all deposit and intent events
- Provide API for frontend/dashboard
- Backup data source

### Service 6: Deposit Address API

**Purpose**: REST endpoint to get EVM address for Solana address

**Implementation**:
- Generate EVM address for the passed Solana Address
- Store EVM address --> Solana address mapping in database

### Orchestrator Workflow

```
1. Initialization
   └─> Load factory configuration
   └─> Connect to RPC, database
   └─> Start polling loop

2. Per-Factory Polling Cycle (every 60s)
   └─> Get list of known destination addresses
   └─> Compute deposit addresses
   └─> Check balances
   └─> Compare with last known

3. When New Deposit Detected
   └─> Check if deployed → deploy if needed
   └─> Call createIntent(amount)
   └─> Store intent hash
   └─> Monitor status

4. Intent Monitoring
   └─> Listen for events
   └─> Update status
   └─> Alert on failures

5. Error Handling
   └─> Retry failed transactions (3x)
   └─> Alert on persistent failures
   └─> Log all errors
```

### Environment Configuration

```typescript
// .env
RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
DATABASE_URL=mongodb://user:pass@localhost:5432/deposit_orchestrator
FACTORY_ADDRESS=0x...
SOURCE_TOKEN_ADDRESS=0x...
POLL_INTERVAL_SECONDS=60
MAX_RETRIES=3
GAS_LIMIT_MULTIPLIER=1.2
ALERT_WEBHOOK_URL=https://hooks.slack.com/...
```

## PART 3: TESTING & DEPLOYMENT

### Unit Tests

**DepositFactory Tests** (`test/core/DepositFactory.t.sol`):
- Factory deployment with valid/invalid parameters
- getAddress returns deterministic addresses
- deploy creates address at predicted location
- isDeployed returns correct status
- getConfiguration returns correct values

**DepositAddress Tests** (`test/core/DepositAddress.t.sol`):
- Constructor sets immutables correctly
- createIntent validates amount
- createIntent constructs Intent correctly
- createIntent approves and funds vault
- Reentrancy protection
- Multiple createIntent calls work

### Integration Tests

**DepositFlow Tests** (`test/integration/DepositFlow.t.sol`):
- End-to-end: deploy factory → get address → send tokens → deploy → create intent
- Verify intent published and funded
- Mock solver fulfillment
- Verify rewards withdrawable

**MultiFactory Tests** (`test/integration/MultiFactory.t.sol`):
- Multiple factories for different routes
- Same user gets different addresses per factory
- Cross-factory independence

### Deployment Checklist

1. Gather deployment parameters (chain IDs, tokens, portals, provers)
2. Deploy factory for primary route (e.g., ETH → Solana USDC)
3. Verify factory contract on block explorer
4. Test with small amount:
   - Get deposit address
   - Send test USDC
   - Deploy deposit contract
   - Create intent
   - Verify fulfillment
5. Set up backend orchestrator
6. Configure monitoring/alerts
7. Monitor initial intents
8. Deploy additional factories as needed

## Deployment Examples

### Example 1: Ethereum → Solana USDC

```solidity
DepositFactory ethToSolUSDC = new DepositFactory(
    5107100,                                        // Solana mainnet
    0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,    // USDC on Ethereum
    0xEPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v, // USDC on Solana
    0x...,                                          // Portal on Ethereum
    0x...,                                          // Solana prover
    0x...,                                          // Portal on Solana
    7 days                                          // Intent deadline
);
```

### Example 2: Base → Solana USDC

```solidity
DepositFactory baseToSolUSDC = new DepositFactory(
    5107100,                                        // Solana mainnet
    0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,    // USDC on Base
    0xEPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v, // USDC on Solana
    0x...,                                          // Portal on Base
    0x...,                                          // Solana prover
    0x...,                                          // Portal on Solana
    7 days                                          // Intent deadline
);
```

## Monitoring & Alerts

### Key Metrics
- Deposit detection latency
- Deployment success rate
- Intent creation success rate
- Intent fulfillment rate
- Average fulfillment time
- Gas costs per operation

### Alerts
- Failed deployments (after retries)
- Failed intent creation (after retries)
- Stuck intents (past deadline)
- RPC connection failures
- Abnormal gas prices

## Scaling Considerations

### Multiple Factories
- Run one monitoring loop per factory
- Use separate worker processes
- Share database for coordination

### High Volume
- Use Redis for caching
- Batch operations where possible
- Use job queue (Bull, BullMQ)

### Multi-Chain
- Run separate orchestrator per source chain
- Each monitors its chain's factories
- Share database schema

## Alternative Approach: Universal Factory

A universal factory design is available in `docs/deposit_address_universal_plan.md` where:
- One factory supports ALL routes
- User specifies chain/token per deposit
- More flexible but more complex
- Higher gas costs

The hard-coded approach (this plan) is recommended for production due to simplicity and gas efficiency.

---

## Summary

This plan provides a complete full-stack implementation of deposit addresses for the Routes Protocol:

**Smart Contracts**: 2 contracts providing deterministic, permissionless deposit addresses
**Backend**: 5 services handling monitoring, deployment, and orchestration
**Testing**: Comprehensive unit and integration test suite
**Deployment**: Clear checklist with examples

The system enables seamless cross-chain transfers where users simply send tokens to their personal deposit address and receive them automatically on the destination chain.
