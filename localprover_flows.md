# LocalProver Information Flow

This document outlines all possible flows when using LocalProver's `flashFulfill` functionality.

## Flow Diagram

```mermaid
flowchart TD
    Start([User Creates Original Intent]) --> IntentType{Intent Type<br/>determined by<br/>user's request}

    %% Single Intent Path
    IntentType -->|Single intent<br/>can be fulfilled locally| Publish1[User calls Portal.publishAndFund<br/>- creator: User<br/>- prover: LocalProver<br/>- funds deposited to OriginalVault]
    Publish1 --> SimpleFlash[Solver calls LocalProver.flashFulfill<br/>- intentHash, route, reward, claimant]
    SimpleFlash --> StoreClaimant1[LocalProver stores actual claimant<br/>in _actualClaimants mapping]
    StoreClaimant1 --> Withdraw1[LocalProver withdraws from OriginalVault<br/>- provenIntents returns LocalProver as claimant<br/>- funds sent to LocalProver]
    Withdraw1 --> Fulfill1[LocalProver calls Portal.fulfill<br/>- claimant = LocalProver address<br/>- executes route calls<br/>- Portal stores LocalProver in claimants mapping]
    Fulfill1 --> FulfillSuccess1{Fulfill Success?}
    FulfillSuccess1 -->|Yes| PaySolver1[LocalProver transfers to actual claimant:<br/>- All reward ERC20 tokens (minus route consumption)<br/>- All remaining native ETH]
    PaySolver1 --> Done1([✅ Done - Solver has rewards])
    FulfillSuccess1 -->|No - Revert| Revert1([❌ Transaction reverts<br/>Funds stay in OriginalVault<br/>_actualClaimants entry cleared on revert])

    %% Secondary Intent Path
    IntentType -->|Requires cross-chain<br/>or external action| Publish2[User calls Portal.publishAndFund<br/>- creator: User<br/>- prover: LocalProver<br/>- funds deposited to OriginalVault]
    Publish2 --> CreateSecondary[Solver creates secondary Intent struct<br/>- creator: **LocalProver**<br/>- prover: CrossChainProver<br/>- destination: different chain]
    CreateSecondary --> PublishSecondary[Solver calls Portal.publishAndFund<br/>for secondary intent<br/>- funds SecondaryVault with their own money]
    PublishSecondary --> FlashWithSecondary[Solver calls LocalProver.flashFulfill<br/>- intentHash, route, reward, claimant]
    FlashWithSecondary --> StoreClaimant2[LocalProver stores actual claimant<br/>in _actualClaimants mapping]
    StoreClaimant2 --> Withdraw2[LocalProver withdraws from OriginalVault<br/>- provenIntents returns LocalProver as claimant<br/>- funds sent to LocalProver]
    Withdraw2 --> Fulfill2[LocalProver calls Portal.fulfill<br/>- claimant = LocalProver address<br/>- executes route calls<br/>- Portal stores LocalProver in claimants mapping]
    Fulfill2 --> FulfillSuccess2{Fulfill Success?}
    FulfillSuccess2 -->|No - Revert| Revert2([❌ Transaction reverts<br/>Funds in OriginalVault<br/>Funds in SecondaryVault<br/>_actualClaimants entry cleared on revert])
    FulfillSuccess2 -->|Yes| PaySolver2[LocalProver transfers to actual claimant:<br/>- All reward ERC20 tokens (minus route consumption)<br/>- All remaining native ETH<br/>✅ Solver has rewards now!]
    PaySolver2 --> SecondaryOutcome{Secondary Intent<br/>Outcome?}

    SecondaryOutcome -->|Proven successful| SecondarySuccess([✅ Complete Success<br/>- Solver got fee<br/>- Secondary completed<br/>- User got service])

    SecondaryOutcome -->|Expires unproven| SecondaryFailed[Secondary intent deadline passes<br/>without proof]
    SecondaryFailed --> RefundChoice{Who refunds?}

    RefundChoice -->|User wants single-tx| UserRefundBoth[User calls LocalProver.refundBoth<br/>- originalIntent<br/>- secondaryIntent]
    UserRefundBoth --> VerifyCreator{Verify secondaryIntent<br/>creator == LocalProver?}
    VerifyCreator -->|No| RevertBadCreator([❌ Revert: InvalidSecondaryCreator])
    VerifyCreator -->|Yes| VerifyExpired{Verify secondary<br/>expired & unproven?}
    VerifyExpired -->|No| RevertNotExpired([❌ Revert: Not expired or already proven])
    VerifyExpired -->|Yes| RefundSecondary[LocalProver calls Portal.refundTo<br/>- secondaryIntent<br/>- refundee: OriginalVault]
    RefundSecondary --> RefundOriginal[LocalProver calls Portal.refund<br/>- originalIntent]
    RefundOriginal --> BothRefunded([✅ Single-tx refund complete<br/>- User got refund from both vaults<br/>- Solver keeps fee])

    RefundChoice -->|Separate refunds| SeparateRefunds[Anyone can call Portal.refund<br/>on each intent separately]
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
    style BothRefunded fill:#2E7D32
    style TwoTxRefund fill:#2E7D32
    style OrigRefunded fill:#2E7D32
    style BothRefundedSeparate fill:#2E7D32
    style PaySolver1 fill:#F57F17
    style PaySolver2 fill:#F57F17
    style Revert1 fill:#C62828
    style Revert2 fill:#C62828
    style RevertBadCreator fill:#C62828
    style RevertNotExpired fill:#C62828
```

## Key Insights

### 1. LocalProver as Intermediary Claimant
- **Problem**: Portal.withdraw requires proof before withdrawal, but flashFulfill needs to withdraw before fulfill
- **Solution**: LocalProver acts as intermediary claimant
  - Stores actual solver address in `_actualClaimants` mapping BEFORE withdrawal
  - `provenIntents()` returns LocalProver as claimant during flashFulfill (enables withdrawal)
  - Calls fulfill with LocalProver as Portal claimant
  - After fulfill, `provenIntents()` returns actual solver from mapping
  - Pays actual solver immediately from LocalProver's balance

### 2. Solver Always Gets Paid Immediately
- In both simple and secondary intent scenarios, if `flashFulfill` succeeds, the solver receives their reward right away
- Solver receives:
  - **All ERC20 tokens** from `reward.tokens` (minus any consumed by `route.tokens` for execution)
  - **All native ETH** from `reward.nativeAmount` (minus any consumed by `route.nativeAmount` for execution)
- This reward is **non-refundable** - solver did the work of fulfilling the original intent
- Payment comes from LocalProver's token and ETH balances after withdrawal and fulfill

### 3. Single Intent Flow (Simple)
- Solver calls `flashFulfill` → LocalProver stores claimant → withdraws to itself → fulfills → pays solver immediately
- If fulfill fails, transaction reverts and funds stay in vault (storage cleared on revert)
- User can refund after deadline if unfulfilled

### 4. Secondary Intent Flow (Complex)
- Solver pre-funds secondary intent with `LocalProver` as creator
- Solver calls `flashFulfill` → LocalProver stores claimant → withdraws to itself → fulfills → pays solver immediately
- Secondary intent outcome is independent:
  - **Success**: Everyone happy
  - **Failure**: User can use `refundBoth()` for single-tx refund, solver keeps their fee

### 5. Refund Scenarios
- **Option A**: User calls `refundBoth()` for single-tx convenience
  - Requires secondary intent creator == LocalProver
  - LocalProver redirects secondary refund to original vault
  - Then refunds original vault
- **Option B**: User calls `Portal.refund()` twice (still works!)
  - Less convenient but always available
  - Each vault refunds separately

### 6. Critical Requirement for `refundBoth()`
The secondary intent **MUST** have `reward.creator = address(LocalProver)` for single-tx refunds to work. If solver creates secondary with themselves as creator, they have to handle refunds themselves.

## Technical Implementation: provenIntents() State Machine

The `provenIntents()` function handles four distinct cases to enable the LocalProver intermediary pattern:

### Case 1: Intent fulfilled via flashFulfill (Portal claimant is LocalProver)
- **Trigger**: Portal.claimants[intentHash] == LocalProver address
- **Return**: Actual solver address from `_actualClaimants` mapping
- **Purpose**: After flashFulfill completes, external queries should see the real solver as claimant

### Case 2: Intent fulfilled via normal Portal.fulfill (not flashFulfill)
- **Trigger**: Portal.claimants[intentHash] != 0 and != LocalProver
- **Return**: Address from Portal.claimants mapping directly
- **Purpose**: Support normal fulfill flow without LocalProver intermediation

### Case 3: flashFulfill in progress (withdrawal phase)
- **Trigger**: Portal.claimants[intentHash] == 0 but `_actualClaimants[intentHash]` != 0
- **Return**: LocalProver's address
- **Purpose**: Enable Portal.withdraw to succeed by returning a valid claimant (LocalProver itself)
- **Critical**: This allows withdrawal BEFORE fulfill by satisfying Portal's proof requirement

### Case 4: Intent not fulfilled at all
- **Trigger**: Both Portal.claimants and `_actualClaimants` are empty
- **Return**: address(0)
- **Purpose**: Standard unfulfilled intent response

## Scenarios Summary

### ✅ Success Cases
1. **Simple fulfillment**: Solver gets reward (ERC20 tokens + native ETH), user gets service
2. **Secondary success**: Solver gets reward, secondary completes, user gets full service
3. **Single-tx refund**: Both vaults refunded to user in one transaction
4. **Two-tx refund**: Both vaults refunded separately

### ⚠️ Solver Keeps Reward Cases
- In all scenarios where `flashFulfill` succeeds, solver keeps their reward (tokens + native)
- Even if secondary intent fails, solver earned the reward for fulfilling the original intent
- This is fair: solver did work and fronted capital for secondary intent

### ❌ Revert Cases
1. **flashFulfill fails**: Transaction reverts, funds stay in original vault
2. **Invalid secondary creator**: `refundBoth()` reverts if secondary creator isn't LocalProver
3. **Not expired**: `refundBoth()` reverts if secondary intent hasn't expired yet
4. **Already proven**: `refundBoth()` reverts if secondary intent already proven

## User Experience

### For Users
- Create intent with LocalProver as prover
- Wait for solver to fulfill
- If solver uses secondary intent and it fails: call `refundBoth()` for convenient single-tx refund
- Fallback: can always call `Portal.refund()` on each intent separately

### For Solvers
- Call `flashFulfill` to atomically withdraw + fulfill + get paid
- Get reward immediately (no waiting!):
  - All ERC20 tokens from reward (minus route consumption)
  - All native ETH from reward (minus route consumption)
- If using secondary intent: create it with `reward.creator = address(LocalProver)` for better UX
- Front capital for secondary intent from the reward received

### For Users (Refund Path)
- Single transaction to get all funds back from both vaults
- Permissionless: anyone can trigger the refund
- Graceful fallback: separate refunds always work even if `refundBoth()` requirements aren't met
