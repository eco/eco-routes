# Deposit Address System Specification

## 1. Context

### Business Problem
Cross-chain token transfers currently require users to interact with complex bridging interfaces, sign transactions, and actively manage their transfers. This creates friction for users withdrawing from centralized exchanges (CEX) or seeking automated cross-chain flows. The Routes Protocol provides an intent-based bridging system, but users still need to manually create intents through a UI.

### User Need
Users need a way to bridge tokens cross-chain that is:
- **CEX-compatible**: Works with withdrawal addresses from exchanges
- **Permissionless**: No account setup or UI interaction required
- **Automatic**: Funds arrive on destination chain without user action
- **Simple**: Just send tokens to an address, like a regular transfer

### System Integration
This system integrates with the Routes Protocol's intent system by:
- Creating deterministic deposit addresses that users can send tokens to
- Automatically detecting deposits and creating intents in the Routes Portal
- Leveraging existing solver networks for cross-chain fulfillment
- Using the Portal's proven cross-chain messaging and verification infrastructure

### Value Proposition
- **For Users**: One-step cross-chain transfers, no signatures or UI needed after initial address lookup
- **For Solvers**: New source of intents to fulfill, with clear reward mechanisms
- **For Routes Protocol**: Expanded use case enabling CEX integration and programmatic bridging
- **For Ecosystem**: Chain-agnostic design supports EVM↔EVM, EVM↔Solana, and future chains

### Design Philosophy
The "hard-coded factory" approach prioritizes simplicity and gas efficiency by deploying separate factory contracts for each specific route (e.g., "Ethereum USDC → Solana USDC"). Each factory has immutable configuration, making deposit address derivation simple (single parameter: destination address) and gas costs minimal.

---

## 2. Requirements

### Functional Requirements

**Smart Contracts:**
- F1: DepositFactory contract must generate deterministic deposit addresses using CREATE2 based on user's destination address
- F2: DepositFactory must deploy DepositAddress contracts at predicted addresses
- F3: DepositFactory must expose view function to check if address is deployed
- F4: DepositFactory must store immutable route configuration (destination chain, tokens, portal addresses)
- F5: DepositAddress contract must accept ERC20 token deposits
- F6: DepositAddress contract must create intents in Routes Portal with correct parameters
- F7: DepositAddress contract must construct intents using sentinel address pattern for cross-VM compatibility
- F8: DepositAddress contract must approve Portal for token transfers and fund the intent atomically
- F9: Multiple factories must operate independently for different routes

**Backend Orchestrator:**
- F10: Balance Monitor service must poll deposit addresses for new deposits at regular intervals
- F11: Contract Deployer service must deploy deposit contracts when first deposit detected
- F12: Intent Creator service must call createIntent() when deposits are ready
- F13: Status Tracker service must monitor intent lifecycle through Portal events
- F14: Event Indexer service must maintain historical record of deposits and intents
- F15: Deposit Address API must provide REST endpoint to generate EVM addresses for Solana addresses
- F16: System must maintain database of deposit addresses, balances, and intent statuses
- F17: System must handle transaction failures with retry logic

**Cross-Chain Compatibility:**
- F18: System must support EVM source chains (Ethereum, Base, Arbitrum, etc.)
- F19: System must support non-EVM destination chains (Solana) via bytes32 addressing
- F20: System must work bidirectionally (EVM→Solana and Solana→EVM)

### Non-Functional Requirements

**Performance:**
- NF1: Deposit detection latency must not exceed 120 seconds
- NF2: Intent creation must complete within 60 seconds of deposit detection
- NF3: Gas costs for createIntent() must be optimized (single approval + single portal call)

**Reliability:**
- NF4: System must implement reentrancy protection on all state-changing functions
- NF5: System must retry failed transactions up to 3 times before alerting
- NF6: System must continue operating if one factory fails
- NF7: Database must maintain consistent state across service restarts

**Security:**
- NF8: Smart contracts must be non-upgradeable (immutable configuration)
- NF9: No admin privileges or centralized control points in contracts
- NF10: Backend must validate all on-chain data before acting

**Usability:**
- NF11: Address generation must be deterministic and reproducible
- NF12: Users must be able to verify their deposit address independently
- NF13: System must work without user having gas on source chain

**Scalability:**
- NF14: Architecture must support multiple factories monitoring simultaneously
- NF15: Database schema must handle high volume of deposits (10K+ per day per factory)
- NF16: System must support horizontal scaling of backend services

### Non-Requirements

**Explicitly Out of Scope:**
- NR1: Universal factory design (choosing hard-coded approach for gas efficiency)
- NR2: Real-time WebSocket notifications to users (polling-based detection is sufficient)
- NR3: Frontend UI for creating intents (system is fully backend-driven)
- NR4: Support for native ETH deposits (ERC20 tokens only)
- NR5: Partial intent fulfillment (full amount or nothing)
- NR6: Intent cancellation after creation (intents are immutable once published)
- NR7: Dynamic route configuration (factory parameters are immutable)
- NR8: Multi-token support per factory (one token pair per factory)

---

## 3. Constraints

### Technology Constraints

**Smart Contracts:**
- Must use Solidity ^0.8.0
- Must use OpenZeppelin libraries for ReentrancyGuard
- Must deploy contracts using Foundry/Hardhat toolchain
- Must use CREATE2 for deterministic address generation

**Backend:**
- Backend services written in Node.js (TypeScript) or Python
- Must use MongoDB for state management
- Must use standard Ethereum RPC providers (Alchemy, Infura)
- Must support environment-based configuration

### Integration Constraints

**Routes Protocol:**
- Must integrate with existing Portal contract interface
- Must use approved Prover contracts for cross-chain verification
- Must construct Intent structs according to Portal specification
- Must emit events compatible with existing indexing infrastructure

**Token Standards:**
- Source tokens must be ERC20 compliant
- Must handle tokens with varying decimals (6, 8, 18)
- Must support both standard and non-standard ERC20 implementations

### Pattern Constraints

**Architecture:**
- One factory per route (hard-coded configuration)
- Factory creates contracts, but anyone can trigger deployment
- All contract operations must be permissionless (no access control)
- Immutable configuration (no upgradeable contracts)

**Addressing:**
- Must use sentinel address (address(0)) in Intent routes for cross-VM compatibility
- Must store actual destination addresses as bytes32 in contract storage
- Must use CREATE2 salt: keccak256(abi.encodePacked(destinationAddress))

### Chain Compatibility

**Supported Chains:**
- Source: Any EVM-compatible chain with Routes Portal deployed
- Destination: EVM chains and Solana (extensible to other chains)
- Must handle different chain IDs and RPC endpoints per factory

### Operational Constraints

**Deployment:**
- Factory deployment requires governance or authorized deployer
- Factories are immutable after deployment
- Backend orchestrator requires secure key management for transaction signing

**Monitoring:**
- Must integrate with existing monitoring/alerting infrastructure
- Must expose metrics for observability (Prometheus format preferred)
- Must log all operations for audit trail

---

## 4. Interface Contract

### Smart Contract Interfaces

#### DepositFactory

```solidity
interface IDepositFactory {
    // Configuration (immutable state variables)
    function DESTINATION_CHAIN() external view returns (uint64);
    function SOURCE_TOKEN() external view returns (address);
    function TARGET_TOKEN() external view returns (bytes32);
    function PORTAL_ADDRESS() external view returns (address);
    function PROVER_ADDRESS() external view returns (address);
    function DESTINATION_PORTAL() external view returns (bytes32);
    function INTENT_DEADLINE_DURATION() external view returns (uint64);

    // Core functions
    /// @notice Get the deterministic address for a given destination
    /// @param destinationAddress The user's address on destination chain (bytes32)
    /// @return The deterministic deposit address on source chain
    function getAddress(bytes32 destinationAddress) external view returns (address);

    /// @notice Deploy a deposit contract at the deterministic address
    /// @param destinationAddress The user's address on destination chain
    /// @return The address of the deployed contract
    function deploy(bytes32 destinationAddress) external returns (address);

    /// @notice Check if a deposit contract is deployed
    /// @param destinationAddress The user's address on destination chain
    /// @return True if contract exists at the address
    function isDeployed(bytes32 destinationAddress) external view returns (bool);

    /// @notice Get all configuration parameters
    /// @return Configuration struct with all immutable values
    function getConfiguration() external view returns (
        uint64 destinationChain,
        address sourceToken,
        bytes32 targetToken,
        address portalAddress,
        address proverAddress,
        bytes32 destinationPortal,
        uint64 intentDeadlineDuration
    );

    // Events
    event DepositContractDeployed(
        bytes32 indexed destinationAddress,
        address indexed depositAddress
    );
}
```

#### DepositAddress

```solidity
interface IDepositAddress {
    // Configuration (immutable state variables)
    function DESTINATION_ADDRESS() external view returns (bytes32);
    function DESTINATION_CHAIN() external view returns (uint64);
    function TARGET_TOKEN() external view returns (bytes32);
    function SOURCE_TOKEN() external view returns (address);
    function PORTAL_ADDRESS() external view returns (address);
    function PROVER_ADDRESS() external view returns (address);
    function DESTINATION_PORTAL() external view returns (bytes32);
    function INTENT_DEADLINE_DURATION() external view returns (uint64);

    /// @notice Create an intent for the deposited tokens
    /// @param amount The amount of tokens to bridge
    /// @return intentHash The hash of the created intent
    function createIntent(uint256 amount) external returns (bytes32 intentHash);

    // Events
    event IntentCreated(
        bytes32 indexed intentHash,
        uint256 amount,
        address indexed caller
    );
}
```

#### Intent Structure

```solidity
struct Intent {
    Route[] routes;
    Reward[] rewards;
    address source;
    uint64 destinationChain;
    uint64 deadline;
    bytes32 destinationSettlementContract;
    bytes32 prover;
}

struct Route {
    address sourceToken;        // address(0) for sentinel pattern
    bytes32 destinationToken;   // actual token address on dest chain
    address sourceIntermediary; // address(0)
    bytes32 destination;        // user's destination address
}

struct Reward {
    address token;    // actual ERC20 address for solver reward
    uint256 amount;   // reward amount
}
```

### Backend API Interfaces

#### Deposit Address API

**Endpoint:** `POST /api/v1/deposit-address`

**Request:**
```json
{
  "factoryAddress": "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb",
  "destinationAddress": "9xQeWvG816bUx9EPjHmaT23yvVM2ZWbrrpZb3jxxxxxxxxx"
}
```

**Response:**
```json
{
  "depositAddress": "0x1234567890abcdef1234567890abcdef12345678",
  "factoryAddress": "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb",
  "destinationAddress": "9xQeWvG816bUx9EPjHmaT23yvVM2ZWbrrpZb3jxxxxxxxxx",
  "destinationChain": 5107100,
  "sourceToken": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
  "targetToken": "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
  "isDeployed": false
}
```

**Endpoint:** `GET /api/v1/deposit-address/:address/status`

**Response:**
```json
{
  "depositAddress": "0x1234567890abcdef1234567890abcdef12345678",
  "balance": "1000000000",
  "isDeployed": true,
  "intents": [
    {
      "intentHash": "0xabcd...",
      "amount": "1000000000",
      "status": "fulfilled",
      "createdAt": "2026-01-13T10:30:00Z",
      "fulfilledAt": "2026-01-13T10:32:15Z"
    }
  ]
}
```

### Database Schemas

#### deposit_addresses Collection

```typescript
{
  _id: ObjectId,
  factoryAddress: string,           // Ethereum address
  userDestinationAddress: string,   // bytes32 hex string
  depositAddress: string,           // Ethereum address
  isDeployed: boolean,
  lastBalance: string,              // uint256 as string
  lastCheckedAt: Date,
  createdAt: Date,
  updatedAt: Date
}

// Indexes
{ factoryAddress: 1, userDestinationAddress: 1 } // unique
{ depositAddress: 1 } // unique
{ factoryAddress: 1, isDeployed: 1 }
```

#### intents Collection

```typescript
{
  _id: ObjectId,
  intentHash: string,               // bytes32 hex string
  depositAddress: string,           // Ethereum address
  factoryAddress: string,           // Ethereum address
  userDestinationAddress: string,   // bytes32 hex string
  amount: string,                   // uint256 as string
  status: string,                   // pending | funded | fulfilled | failed
  txHash: string,                   // transaction hash
  blockNumber: number,
  createdAt: Date,
  updatedAt: Date,
  fulfilledAt: Date | null,
  fulfillmentTxHash: string | null
}

// Indexes
{ intentHash: 1 } // unique
{ depositAddress: 1, createdAt: -1 }
{ status: 1, createdAt: -1 }
{ factoryAddress: 1, status: 1 }
```

### Events

#### DepositContractDeployed

```solidity
event DepositContractDeployed(
    bytes32 indexed destinationAddress,
    address indexed depositAddress
);
```

#### IntentCreated (from DepositAddress)

```solidity
event IntentCreated(
    bytes32 indexed intentHash,
    uint256 amount,
    address indexed caller
);
```

#### IntentPublished (from Portal)

```solidity
event IntentPublished(
    bytes32 indexed intentHash,
    Intent intent
);
```

#### IntentFulfilled (from Portal)

```solidity
event IntentFulfilled(
    bytes32 indexed intentHash,
    address indexed solver
);
```

---

## 5. Examples

### Example 1: Ethereum USDC → Solana USDC Factory

**Deployment:**
```solidity
DepositFactory ethToSolUSDC = new DepositFactory(
    5107100,                                        // Solana mainnet chain ID
    0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,    // USDC on Ethereum
    0xEPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v, // USDC SPL token on Solana (as bytes32)
    0x...,                                          // Routes Portal on Ethereum
    0x...,                                          // Solana Prover contract
    0x...,                                          // Routes Portal on Solana (as bytes32)
    7 days                                          // Intent deadline duration
);
```

**User Flow:**
```javascript
// 1. User gets their deposit address
const solanaAddress = "9xQeWvG816bUx9EPjHmaT23yvVM2ZWbrrpZb3jxxxxxxxxx";
const solanaBytes32 = web3.utils.padLeft(solanaAddress, 64);
const depositAddress = await factory.getAddress(solanaBytes32);
// Returns: 0x1234567890abcdef1234567890abcdef12345678

// 2. User sends USDC from their wallet or CEX to deposit address
// Transaction: Send 1000 USDC to 0x1234567890abcdef1234567890abcdef12345678

// 3. Backend detects deposit (within 60-120 seconds)
// 4. Backend deploys contract if first time
if (!await factory.isDeployed(solanaBytes32)) {
    await factory.deploy(solanaBytes32);
}

// 5. Backend creates intent
const depositContract = await ethers.getContractAt("DepositAddress", depositAddress);
const tx = await depositContract.createIntent(ethers.utils.parseUnits("1000", 6));
const receipt = await tx.wait();
// Intent is now published to Portal

// 6. Solver fulfills on Solana (within minutes to hours)
// 7. User receives USDC on Solana address
```

### Example 2: Base USDC → Solana USDC Factory

**Deployment:**
```solidity
DepositFactory baseToSolUSDC = new DepositFactory(
    5107100,                                        // Solana mainnet chain ID
    0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,    // USDC on Base
    0xEPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v, // USDC SPL token on Solana
    0x...,                                          // Routes Portal on Base
    0x...,                                          // Solana Prover contract
    0x...,                                          // Routes Portal on Solana
    7 days                                          // Intent deadline duration
);
```

**Multi-Factory Independence:**
```javascript
// Same user, different factories
const solanaAddress = "9xQeWvG816bUx9EPjHmaT23yvVM2ZWbrrpZb3jxxxxxxxxx";
const solanaBytes32 = web3.utils.padLeft(solanaAddress, 64);

// Different deposit addresses for same user on different chains
const ethDepositAddress = await ethFactory.getAddress(solanaBytes32);
const baseDepositAddress = await baseFactory.getAddress(solanaBytes32);

console.log(ethDepositAddress);  // 0xaaaa...
console.log(baseDepositAddress); // 0xbbbb... (different!)

// User can send USDC from Ethereum to ethDepositAddress
// User can send USDC from Base to baseDepositAddress
// Both will arrive at same Solana address
```

### Example 3: Edge Cases

**First-Time Deposit (Contract Deployment Required):**
```javascript
// Scenario: User sends tokens to undeployed address
const depositAddress = await factory.getAddress(userBytes32);
const isDeployed = await factory.isDeployed(userBytes32);
// Returns: false

// User sends 100 USDC to depositAddress
// Backend detects deposit
// Backend must deploy first
await factory.deploy(userBytes32);
// Now: isDeployed = true

// Then create intent
await depositContract.createIntent(amount);
```

**Subsequent Deposits (Direct Intent Creation):**
```javascript
// Scenario: User sends more tokens to already-deployed address
const isDeployed = await factory.isDeployed(userBytes32);
// Returns: true

// User sends 500 USDC to depositAddress
// Backend detects deposit
// Backend skips deployment, directly creates intent
await depositContract.createIntent(amount);
```

**Multiple Deposits Before Fulfillment:**
```javascript
// Scenario: User sends multiple deposits rapidly
// Deposit 1: 100 USDC → creates intent with 100 USDC
// Deposit 2: 200 USDC arrives before intent 1 fulfilled
// Backend creates second intent with 200 USDC
// Both intents can be fulfilled independently
```

**Failed Transaction with Retry:**
```javascript
// Scenario: createIntent fails due to network issue
try {
    await depositContract.createIntent(amount);
} catch (error) {
    // Backend retries up to 3 times
    for (let i = 0; i < 3; i++) {
        try {
            await depositContract.createIntent(amount);
            break; // Success
        } catch (retryError) {
            if (i === 2) {
                // Alert operators after 3 failures
                await sendAlert("Intent creation failed after 3 retries");
            }
        }
    }
}
```

### Example 4: Intent Construction

**Resulting Intent Structure:**
```javascript
{
    routes: [
        {
            sourceToken: "0x0000000000000000000000000000000000000000", // sentinel
            destinationToken: "0xEPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
            sourceIntermediary: "0x0000000000000000000000000000000000000000",
            destination: "0x9xQeWvG816bUx9EPjHmaT23yvVM2ZWbrrpZb3jxxxxxxxxx"
        }
    ],
    rewards: [
        {
            token: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", // actual USDC address
            amount: "1000000000" // 1000 USDC (6 decimals)
        }
    ],
    source: "0x1234567890abcdef1234567890abcdef12345678", // deposit address
    destinationChain: 5107100, // Solana
    deadline: 1736860800, // 7 days from intent creation
    destinationSettlementContract: "0x...", // Solana Portal
    prover: "0x..." // Solana Prover
}
```

---

## 6. Acceptance Criteria

### Smart Contract Criteria

- [ ] **AC1**: DepositFactory generates identical addresses for same destinationAddress across calls
- [ ] **AC2**: DepositFactory.deploy() creates contract at exact address returned by getAddress()
- [ ] **AC3**: DepositFactory.isDeployed() returns false before deployment, true after
- [ ] **AC4**: DepositAddress.createIntent() reverts if amount is zero
- [ ] **AC5**: DepositAddress.createIntent() reverts if amount exceeds token balance
- [ ] **AC6**: DepositAddress.createIntent() approves Portal for exact amount
- [ ] **AC7**: DepositAddress.createIntent() publishes intent to Portal with correct parameters
- [ ] **AC8**: DepositAddress.createIntent() returns unique intentHash
- [ ] **AC9**: DepositAddress is protected against reentrancy attacks
- [ ] **AC10**: Multiple DepositAddress.createIntent() calls succeed sequentially
- [ ] **AC11**: Intent routes use address(0) for sourceToken (sentinel pattern)
- [ ] **AC12**: Intent rewards use actual ERC20 address for solver payment
- [ ] **AC13**: Intent destination contains user's bytes32 address
- [ ] **AC14**: Intent deadline is current timestamp + INTENT_DEADLINE_DURATION

### Multi-Factory Criteria

- [ ] **AC15**: Same user gets different deposit addresses from different factories
- [ ] **AC16**: Two factories with different source chains generate different addresses for same user
- [ ] **AC17**: Factory configurations are immutable after deployment
- [ ] **AC18**: Factories operate independently (one failure doesn't affect others)

### Backend Orchestrator Criteria

- [ ] **AC19**: Balance Monitor detects new deposits within 120 seconds
- [ ] **AC20**: Balance Monitor correctly computes balance deltas
- [ ] **AC21**: Contract Deployer successfully deploys on first deposit
- [ ] **AC22**: Contract Deployer skips deployment if already deployed
- [ ] **AC23**: Intent Creator calls createIntent() with correct amount
- [ ] **AC24**: Intent Creator extracts intentHash from transaction receipt
- [ ] **AC25**: Intent Creator updates database with intent record
- [ ] **AC26**: Status Tracker monitors Portal events for intent status changes
- [ ] **AC27**: Status Tracker updates database when intent is fulfilled
- [ ] **AC28**: Failed transactions are retried up to 3 times
- [ ] **AC29**: Operators are alerted after 3 failed retries
- [ ] **AC30**: Database maintains consistent state across service restarts

### Integration Criteria

- [ ] **AC31**: End-to-end flow completes: deposit → detection → deployment → intent → fulfillment
- [ ] **AC32**: Deposit Address API returns correct addresses matching on-chain computation
- [ ] **AC33**: Status API returns accurate balance and intent information
- [ ] **AC34**: System handles concurrent deposits to different addresses
- [ ] **AC35**: System handles multiple deposits to same address before fulfillment

### Performance Criteria

- [ ] **AC36**: createIntent() gas cost is under 200,000 gas
- [ ] **AC37**: Factory deployment gas cost is under 3,000,000 gas
- [ ] **AC38**: DepositAddress deployment gas cost is under 500,000 gas
- [ ] **AC39**: Balance polling cycle completes within 10 seconds per factory
- [ ] **AC40**: Database queries for status checks complete within 100ms

### Security Criteria

- [ ] **AC41**: No reentrancy vulnerabilities in contracts (verified by Slither)
- [ ] **AC42**: No integer overflow/underflow vulnerabilities
- [ ] **AC43**: No unauthorized access to contract functions
- [ ] **AC44**: Backend private keys are securely stored (never in code)
- [ ] **AC45**: RPC endpoints use authenticated connections

### Testing Criteria

- [ ] **AC46**: Unit tests achieve >90% code coverage for contracts
- [ ] **AC47**: Unit tests cover all edge cases (zero amount, insufficient balance, etc.)
- [ ] **AC48**: Integration tests cover full deposit flow
- [ ] **AC49**: Integration tests verify multi-factory independence
- [ ] **AC50**: Backend service tests mock RPC and database interactions

---

## 7. Open Questions

### Technical Design Questions

1. **Polling Interval Optimization**: What is the optimal balance between deposit detection latency and RPC cost?
   - Current plan: 60 seconds
   - Trade-off: Faster polling = higher RPC costs but better UX
   - Need: Real-world testing to determine sweet spot

2. **Gas Cost Budget**: What are acceptable gas costs for production deployment?
   - createIntent: Currently estimated ~150-200k gas
   - Factory deployment: ~2-3M gas
   - DepositAddress deployment: ~300-500k gas
   - Question: Are these costs acceptable? Can they be optimized further?

3. **Sentinel Address Pattern**: Are there any chains where address(0) has special meaning that could break the pattern?
   - Need: Audit all target chains for address(0) handling
   - Mitigation: Document any chain-specific considerations

4. **Multiple Concurrent Deposits**: How should the system handle rapid sequential deposits to the same address?
   - Current approach: Create separate intents for each deposit
   - Alternative: Batch multiple deposits into single intent?
   - Trade-off: Simplicity vs. gas efficiency

### Operational Questions

5. **Stuck Intent Threshold**: At what point should we alert on "stuck" intents?
   - Intent deadline is 7 days
   - Should we alert before deadline (e.g., at 24 hours)?
   - What actions should operators take for stuck intents?

6. **RPC Provider Redundancy**: What backup strategy if primary RPC provider fails?
   - Fallback to secondary provider?
   - Multiple providers in round-robin?
   - Cost vs. reliability trade-off

7. **Rate Limiting**: Should we implement rate limiting for high-volume users?
   - Concern: Users could spam deposits to same address
   - Question: Is this actually a problem given intent-based model?
   - Mitigation: Per-address or per-factory limits?

8. **Error Recovery**: What should happen if intent creation fails but tokens are already in deposit contract?
   - Tokens are "stuck" in contract
   - Options: Rescue function? Manual intervention? Retry indefinitely?
   - Security vs. recoverability trade-off

### Testing & Deployment Questions

9. **Cross-Chain Testing**: How do we test cross-chain fulfillment without mainnet deployment?
   - Testnet availability for all chains?
   - Mock solver for testing?
   - Cost of testing on mainnets?

10. **Factory Deployment Sequence**: What order should factories be deployed in production?
    - Start with single high-volume route (ETH→SOL USDC)?
    - Deploy multiple routes simultaneously?
    - Gradual rollout vs. big launch?

11. **Configuration Updates**: What if factory parameters need updates after deployment?
    - Contracts are immutable by design
    - Options: Deploy new factory? Migration path for users?
    - How to communicate changes to users?

### Monitoring & Analytics Questions

12. **Key Metrics**: What metrics are most important to monitor?
    - Success rate, fulfillment time, gas costs?
    - User behavior (deposit amounts, frequency)?
    - Solver performance per route?

13. **Alerting Thresholds**: What thresholds trigger alerts?
    - Failed deployments: Alert immediately or after N failures?
    - High gas prices: What threshold?
    - Low solver activity: How many unfulfilled intents?

### Business & Product Questions

14. **Fee Model**: Should the system charge fees? If so, how?
    - Current design: No fees (user pays gas indirectly via solver reward)
    - Alternative: Small percentage fee on deposits?
    - Question: Who pays deployment gas?

15. **User Education**: How do users discover their deposit address?
    - Frontend tool to compute address?
    - API for wallets/exchanges to integrate?
    - Documentation and examples?

16. **CEX Integration**: What's needed for exchange integrations?
    - Whitelabel solution for exchanges?
    - Batch withdrawal support?
    - Compliance requirements (KYC/AML)?

---

## Document Control

- **Version**: 1.0
- **Status**: Draft
- **Last Updated**: 2026-01-13
- **Authors**: Routes Protocol Team
- **Related Documents**:
  - Implementation Plan: `CLAUDE/plans/deposit_address_hardcoded_plan_fullstack.md`
  - Universal Factory Alternative: `CLAUDE/plans/deposit_address_universal_plan.md`
