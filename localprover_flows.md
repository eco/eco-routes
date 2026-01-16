# LocalProver Information Flow

This document outlines all possible flows when using LocalProver's `flashFulfill` functionality.

## Flow Diagram

```mermaid
flowchart TD
    Start([User Creates Original Intent]) --> IntentType{Intent Type<br/>determined by<br/>user's request}

    %% Single Intent Path
    IntentType -->|Single intent<br/>can be fulfilled locally| Publish1[User calls Portal.publishAndFund<br/>- creator: User<br/>- prover: LocalProver<br/>- funds deposited to OriginalVault]
    Publish1 --> SimpleFlash[Solver calls LocalProver.flashFulfill<br/>- route, reward, claimant]
    SimpleFlash --> StoreClaimant1[LocalProver marks intent as in-progress<br/>_flashFulfillInProgress = intentHash]
    StoreClaimant1 --> Withdraw1[LocalProver withdraws from OriginalVault<br/>- provenIntents returns LocalProver<br/>- funds sent to LocalProver]
    Withdraw1 --> Fulfill1[LocalProver calls Portal.fulfill<br/>- claimant = actual solver address<br/>- executes route calls<br/>- Portal stores solver in claimants mapping]
    Fulfill1 --> FulfillSuccess1{Fulfill Success?}
    FulfillSuccess1 -->|Yes| PaySolver1[LocalProver transfers to actual claimant:<br/>- All reward ERC20 tokens (minus route consumption)<br/>- All remaining native ETH]
    PaySolver1 --> Done1([✅ Done - Solver has rewards])
    FulfillSuccess1 -->|No - Revert| Revert1([❌ Transaction reverts<br/>Funds stay in OriginalVault<br/>_flashFulfillInProgress cleared on revert])

    %% Secondary Intent Path
    IntentType -->|Requires cross-chain<br/>or external action| Publish2[User calls Portal.publishAndFund<br/>- creator: User<br/>- prover: LocalProver<br/>- funds deposited to OriginalVault]
    Publish2 --> CreateSecondary[Solver creates secondary Intent struct<br/>- creator: **OriginalVault**<br/>- prover: CrossChainProver<br/>- destination: different chain]
    CreateSecondary --> PublishSecondary[Solver calls Portal.publishAndFund<br/>for secondary intent<br/>- funds SecondaryVault with their own money]
    PublishSecondary --> FlashWithSecondary[Solver calls LocalProver.flashFulfill<br/>- route, reward, claimant]
    FlashWithSecondary --> StoreClaimant2[LocalProver marks intent as in-progress<br/>_flashFulfillInProgress = intentHash]
    StoreClaimant2 --> Withdraw2[LocalProver withdraws from OriginalVault<br/>- provenIntents returns LocalProver<br/>- funds sent to LocalProver]
    Withdraw2 --> Fulfill2[LocalProver calls Portal.fulfill<br/>- claimant = actual solver address<br/>- executes route calls<br/>- Portal stores solver in claimants mapping]
    Fulfill2 --> FulfillSuccess2{Fulfill Success?}
    FulfillSuccess2 -->|No - Revert| Revert2([❌ Transaction reverts<br/>Funds in OriginalVault<br/>Funds in SecondaryVault<br/>_flashFulfillInProgress cleared on revert])
    FulfillSuccess2 -->|Yes| PaySolver2[LocalProver transfers to actual claimant:<br/>- All reward ERC20 tokens (minus route consumption)<br/>- All remaining native ETH<br/>✅ Solver has rewards now!]
    PaySolver2 --> SecondaryOutcome{Secondary Intent<br/>Outcome?}

    SecondaryOutcome -->|Proven successful| SecondarySuccess([✅ Complete Success<br/>- Solver got fee<br/>- Secondary completed<br/>- User got service])

    SecondaryOutcome -->|Expires unproven| SecondaryFailed[Secondary intent deadline passes<br/>without proof]
    SecondaryFailed --> SeparateRefunds[Backend calls Portal.refund<br/>on each intent separately]
    SeparateRefunds --> TwoTxRefund([✅ Two-tx refund complete<br/>- User got refund from both vaults<br/>- Solver keeps fee])

    %% Refund Original Only
    Revert1 --> CanRefundOriginal{Original intent<br/>deadline passed?}
    CanRefundOriginal -->|Yes| RefundOrigOnly[User calls Portal.refund<br/>on original intent]
    RefundOrigOnly --> OrigRefunded([✅ User gets original funds back])

    Revert2 --> CanRefundBothSeparate{Deadlines passed?}
    CanRefundBothSeparate -->|Yes| RefundBothSeparate[User calls Portal.refund<br/>on both intents separately]
    RefundBothSeparate --> BothRefundedSeparate([✅ User gets both refunds<br/>in 2 transactions])

    style Done1 fill:#2E7D32
    style SecondarySuccess fill:#2E7D32
    style TwoTxRefund fill:#2E7D32
    style OrigRefunded fill:#2E7D32
    style BothRefundedSeparate fill:#2E7D32
    style PaySolver1 fill:#F57F17
    style PaySolver2 fill:#F57F17
    style Revert1 fill:#C62828
    style Revert2 fill:#C62828
```

## Key Insights

### 1. LocalProver as Intermediary for Funds
- **Problem**: Portal.withdraw requires proof before withdrawal, but flashFulfill needs to withdraw before fulfill
- **Solution**: LocalProver uses temporary in-progress flag
  - Sets `_flashFulfillInProgress = intentHash` BEFORE withdrawal
  - `provenIntents()` returns LocalProver during withdrawal (enables it)
  - Calls fulfill with **actual solver as Portal claimant** (not LocalProver!)
  - Portal stores actual solver in claimants mapping
  - LocalProver transfers remaining funds to solver
  - LocalProver acts as fund intermediary, not recorded as claimant

### 2. Solver Always Gets Paid Immediately
- In both simple and secondary intent scenarios, if `flashFulfill` succeeds, the solver receives their reward right away
- Solver receives:
  - **All ERC20 tokens** from `reward.tokens` (minus any consumed by `route.tokens` for execution)
  - **All native ETH** from `reward.nativeAmount` (minus any consumed by `route.nativeAmount` for execution)
- This reward is **non-refundable** - solver did the work of fulfilling the original intent
- Payment comes from LocalProver's token and ETH balances after withdrawal and fulfill

### 3. Single Intent Flow (Simple)
- Solver calls `flashFulfill` → LocalProver marks in-progress → withdraws to itself → fulfills with solver as claimant → pays solver immediately
- If fulfill fails, transaction reverts and funds stay in vault (_flashFulfillInProgress cleared on revert)
- User can refund after deadline if unfulfilled

### 4. Secondary Intent Flow (Complex)
- Solver pre-funds secondary intent with `originalVault` as creator
- Solver calls `flashFulfill` → LocalProver marks in-progress → withdraws to itself → fulfills → pays solver immediately
- Secondary intent outcome is independent:
  - **Success**: Everyone happy
  - **Failure**: Backend calls `Portal.refund()` twice, solver keeps their fee

### 5. Refund Scenarios
- Backend calls `Portal.refund()` twice (separate transactions):
  - First refunds secondary intent → originalVault
  - Then refunds original intent → user
- Portal.refund is permissionless - anyone can trigger
- Each vault refunds separately (non-atomic but safe)

### 6. Critical Requirement for Secondary Intents
The secondary intent **MUST** have `reward.creator = originalVault` (the vault address of the original intent) for refunds to work correctly. This ensures refunds flow: SecondaryVault → OriginalVault → User. If solver creates secondary with themselves as creator, they have to handle refunds themselves.

## Technical Implementation: provenIntents() State Machine

The `provenIntents()` function handles four distinct cases to enable the LocalProver intermediary pattern, with built-in griefing attack protection:

### Case 1: Griefing protection - LocalProver set as claimant maliciously
- **Trigger**: Portal.claimants[intentHash] == LocalProver address
- **Return**: address(0) (treat as unfulfilled)
- **Purpose**: Prevent griefing where someone calls Portal.fulfill with LocalProver as claimant
- **Note**: In normal flashFulfill, actual solver is set as claimant (not LocalProver), so this case doesn't trigger

### Case 2: Intent fulfilled (via flashFulfill or normal Portal.fulfill)
- **Trigger**: Portal.claimants[intentHash] != 0 and != LocalProver and is valid EVM address
- **Return**: Address from Portal.claimants mapping (actual solver)
- **Purpose**: After flashFulfill completes, Portal.claimants contains the actual solver
- **Also handles**: Normal Portal.fulfill calls

### Case 3: flashFulfill in progress (withdrawal phase)
- **Trigger**: Portal.claimants[intentHash] == 0 but `_flashFulfillInProgress == intentHash`
- **Return**: LocalProver's address
- **Purpose**: Enable Portal.withdraw to succeed during flashFulfill execution
- **Critical**: This allows withdrawal BEFORE fulfill by satisfying Portal's proof requirement
- **Called by**: Portal.withdraw() during flashFulfill transaction

### Case 4: Intent not fulfilled at all
- **Trigger**: Portal.claimants empty and _flashFulfillInProgress != intentHash
- **Return**: address(0)
- **Purpose**: Standard unfulfilled intent response

### Griefing Attack Protection

The state machine includes built-in protection against two potential griefing attacks:

**Attack Vector 1: LocalProver Sentinel Griefing**
- Attacker calls `Portal.fulfill(intentHash, ..., bytes32(address(LocalProver)))`
- Portal sets claimants[intentHash] to LocalProver without going through flashFulfill
- Protection: Case 1 returns `address(0)` instead of reverting (treats as unfulfilled)
- Result: Intent appears unfulfilled, allowing refund after deadline

**Attack Vector 2: Non-EVM bytes32 Griefing**
- Attacker calls `Portal.fulfill(intentHash, ..., nonEVMBytes32)` with invalid EVM address (top 12 bytes non-zero)
- Portal sets claimants[intentHash] to invalid bytes32
- Protection: Case 2 validates address before conversion, returns `address(0)` for invalid addresses
- Result: Intent appears unfulfilled, allowing refund after deadline

**Impact**: Both attack vectors result in the same safe behavior:
- User's service is fulfilled (route executed by attacker)
- Intent cannot be fulfilled again (Portal blocks duplicate fulfills)
- Funds locked until deadline, then refundable to creator
- Attacker loses money for execution costs with no benefit

## Scenarios Summary

### ✅ Success Cases
1. **Simple fulfillment**: Solver gets reward (ERC20 tokens + native ETH), user gets service
2. **Secondary success**: Solver gets reward, secondary completes, user gets full service
3. **Two-tx refund**: Both vaults refunded separately by backend

### ⚠️ Solver Keeps Reward Cases
- In all scenarios where `flashFulfill` succeeds, solver keeps their reward (tokens + native)
- Even if secondary intent fails, solver earned the reward for fulfilling the original intent
- This is fair: solver did work and fronted capital for secondary intent

### ❌ Revert Cases
1. **flashFulfill fails**: Transaction reverts, funds stay in original vault
2. **Portal.refund fails**: Reverts if intent not expired or already proven

## User Experience

### For Users
- Create intent with LocalProver as prover
- Wait for solver to fulfill
- If solver uses secondary intent and it fails: backend calls `Portal.refund()` twice
- Refunds are permissionless - anyone can trigger after deadline

### For Solvers
- Call `flashFulfill` to atomically withdraw + fulfill + get paid
- Get reward immediately (no waiting!):
  - All ERC20 tokens from reward (minus route consumption)
  - All native ETH from reward (minus route consumption)
- If using secondary intent: create it with `reward.creator = originalVault` (address from `Portal.intentVaultAddress(originalIntent)`) for better UX
- Front capital for secondary intent from the reward received

### For Users (Refund Path)
- Two separate transactions to refund both vaults (handled by backend)
- Permissionless: anyone can call Portal.refund() after deadline
- Safe and straightforward - no complex validation logic
