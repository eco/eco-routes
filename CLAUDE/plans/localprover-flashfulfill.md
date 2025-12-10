# LocalProver FlashFulfill Implementation Plan

## **Overview**
Enable atomic same-chain intent fulfillment with conditional rewards based on secondary intent completion. Funds flow back to original vault if secondary intent fails.

---

## **1. Data Structures**

### **A. Internal Claimants Mapping**
```solidity
// Track flash-fulfilled intents where LocalProver is temporary claimant
mapping(bytes32 => address) internal _claimants;
```

### **B. Escrow Data Structure**
```solidity
struct EscrowData {
    address claimant;              // Solver eligible for rewards
    uint256 nativeAmount;          // Escrowed native tokens
    TokenAmount[] tokens;          // Escrowed ERC20 tokens
    bytes32 secondaryIntentHash;   // Dependent intent that must complete
    uint64 secondaryDeadline;      // Secondary intent deadline (for refund timing)
    bool released;                 // Whether escrow has been released
}

mapping(bytes32 => EscrowData) public escrowedRewards;
```

---

## **2. Modified Methods**

### **A. provenIntents() - Check Internal Mapping First**
```solidity
function provenIntents(bytes32 intentHash)
    external
    view
    returns (ProofData memory proofData)
{
    // PRIORITY 1: Check LocalProver's internal mapping (flash-fulfilled intents)
    address localClaimant = _claimants[intentHash];
    if (localClaimant != address(0)) {
        return ProofData({
            claimant: localClaimant,
            destination: _CHAIN_ID
        });
    }

    // PRIORITY 2: Check Portal's claimants (normally fulfilled intents)
    bytes32 claimant = _PORTAL.claimants(intentHash);
    if (claimant == bytes32(0)) return proofData;

    return ProofData({
        claimant: address(uint160(uint256(claimant))),
        destination: _CHAIN_ID
    });
}
```

---

## **3. New Methods**

### **A. flashFulfill() - Atomic Fulfill with Escrow**

**Signature:**
```solidity
function flashFulfill(
    bytes32 intentHash,
    Intent calldata intent,
    bytes32 claimant,
    bytes32 secondaryIntentHash
) external payable returns (bytes[] memory results)
```

**Flow:**
```
1. Mark intent as proven with LocalProver as claimant
   └─ _claimants[intentHash] = address(this)

2. Withdraw ALL funds from vault to LocalProver
   └─ _PORTAL.withdraw(intentHash, intent)
   └─ LocalProver receives reward.nativeAmount + reward.tokens

3. Approve tokens for fulfill execution
   └─ Loop through tokens, approve Portal/Executor

4. Call fulfill with withdrawn funds
   └─ _PORTAL.fulfill{value: executionNative}(...)
   └─ Fulfill executes calls:
       ├─ Deposit into secondary vault (creator = LocalProver)
       └─ Deposit into bridge (recovery = originalVault?)

5. Calculate excess (what remains in LocalProver after fulfill)
   └─ Excess native = address(this).balance
   └─ Excess tokens = remaining balances

6. Store in escrow
   └─ escrowedRewards[intentHash] = EscrowData({
         claimant: solver address,
         nativeAmount: excess native,
         tokens: excess tokens,
         secondaryIntentHash: provided hash,
         secondaryDeadline: from secondary intent,
         released: false
      })

7. Return fulfill results
```

**Key Points:**
- Entire transaction reverts if fulfill fails (atomic)
- Secondary intent creator = LocalProver (no circular dependency)
- Only excess funds are escrowed (fulfill uses the rest)

---

### **B. releaseEscrow() - Success Path**

**Signature:**
```solidity
function releaseEscrow(bytes32 intentHash) external
```

**Flow:**
```
1. Load escrow
   └─ require(!escrow.released)
   └─ require(escrow.claimant != address(0))

2. Verify secondary intent is PROVEN
   └─ ProofData memory proof = provenIntents(secondaryIntentHash)
   └─ require(proof.claimant != address(0), "Secondary not proven")

3. Transfer escrow to claimant (solver)
   └─ _transferEscrow(escrow, escrow.claimant)
   └─ Transfer native + tokens

4. Mark as released
   └─ escrow.released = true

5. Emit event
   └─ emit EscrowReleased(intentHash, escrow.claimant)
```

**Permissionless:** Anyone can trigger if conditions met

---

### **C. refundEscrow() - Failure Path**

**Signature:**
```solidity
function refundEscrow(
    bytes32 originalIntentHash,
    Intent calldata originalIntent,
    Intent calldata secondaryIntent
) external
```

**Flow:**
```
1. Load escrow
   └─ require(!escrow.released)
   └─ require(escrow.claimant != address(0))

2. Verify secondary intent EXPIRED and NOT PROVEN
   └─ require(block.timestamp > secondaryIntent.reward.deadline)
   └─ ProofData memory proof = provenIntents(secondaryIntentHash)
   └─ require(proof.claimant == address(0), "Already proven")

3. Refund secondary vault → LocalProver
   └─ _PORTAL.refund(...secondary intent params...)
   └─ Funds arrive at LocalProver (we're the creator)

4. Add refunded amounts to escrow
   └─ escrow.nativeAmount += secondaryIntent.reward.nativeAmount
   └─ Add secondary tokens to escrow.tokens array

5. Compute original vault address
   └─ address originalVault = _PORTAL.intentVaultAddress(originalIntent)

6. Transfer ALL escrow (original excess + refunded) to original vault
   └─ _transferEscrow(escrow, originalVault)

7. Mark as released
   └─ escrow.released = true

8. Emit event
   └─ emit EscrowRefunded(intentHash, originalVault)
```

**After this:** Creator calls `Portal.refund(originalIntent)` to get all funds from original vault

**Permissionless:** Anyone can trigger if conditions met

---

## **4. Helper Functions**

### **A. _transferEscrow()**
```solidity
function _transferEscrow(
    EscrowData storage escrow,
    address recipient
) internal {
    // Transfer ERC20 tokens
    for (uint i = 0; i < escrow.tokens.length; i++) {
        uint256 amount = escrow.tokens[i].amount;
        if (amount > 0) {
            IERC20(escrow.tokens[i].token).safeTransfer(recipient, amount);
        }
    }

    // Transfer native tokens
    if (escrow.nativeAmount > 0) {
        (bool success, ) = recipient.call{value: escrow.nativeAmount}("");
        require(success, "Native transfer failed");
    }
}
```

### **B. _addToEscrowTokens()**
```solidity
function _addToEscrowTokens(
    EscrowData storage escrow,
    TokenAmount memory newToken
) internal {
    // Find existing token or add new entry
    for (uint i = 0; i < escrow.tokens.length; i++) {
        if (escrow.tokens[i].token == newToken.token) {
            escrow.tokens[i].amount += newToken.amount;
            return;
        }
    }
    // Token not found, add new entry
    escrow.tokens.push(newToken);
}
```

### **C. _getRemainingBalance()**
```solidity
function _getRemainingBalance(TokenAmount[] memory tokens)
    internal
    view
    returns (TokenAmount[] memory remaining)
{
    remaining = new TokenAmount[](tokens.length);
    for (uint i = 0; i < tokens.length; i++) {
        remaining[i] = TokenAmount({
            token: tokens[i].token,
            amount: IERC20(tokens[i].token).balanceOf(address(this))
        });
    }
}
```

---

## **5. Events**

```solidity
event FlashFulfilled(
    bytes32 indexed intentHash,
    bytes32 indexed claimant,
    bytes32 indexed secondaryIntentHash
);

event EscrowReleased(
    bytes32 indexed intentHash,
    address indexed claimant,
    uint256 nativeAmount
);

event EscrowRefunded(
    bytes32 indexed intentHash,
    address indexed originalVault,
    uint256 nativeAmount
);
```

---

## **6. Security Considerations**

### **A. Reentrancy Protection**
- Add `ReentrancyGuard` from OpenZeppelin
- Apply `nonReentrant` to:
  - `flashFulfill`
  - `releaseEscrow`
  - `refundEscrow`

### **B. Validation Checks**
- Ensure escrow not already released
- Verify secondary intent hash matches
- Check deadlines properly
- Validate claimant addresses

### **C. SafeERC20**
- Use SafeERC20 for all token transfers
- Handle tokens that don't return bool

---

## **7. Complete Fund Flow Diagram**

```
CREATION:
User creates original intent with:
  Route.calls = [
    publishAndFund(secondaryIntent, Reward({creator: LocalProver, ...})),
    depositToBridge(...)
  ]

FLASHFULFILL:
Original Vault (100 tokens)
    ↓ withdraw
LocalProver (100 tokens)
    ↓ fulfill uses 80 tokens
    ├─ Secondary Vault (50 tokens, creator=LocalProver)
    └─ Bridge (30 tokens)
LocalProver Escrow (20 tokens excess)

SUCCESS PATH:
Secondary Intent Proven
    ↓ releaseEscrow()
Solver gets 20 tokens ✓

FAILURE PATH:
Secondary Intent Expired + Unproven
    ↓ refundEscrow()
    ├─ Secondary Vault refund → LocalProver (50 tokens)
    ├─ Bridge recovery → Original Vault (30 tokens)
    └─ LocalProver Escrow (20 + 50 = 70 tokens) → Original Vault
Original Vault (30 + 70 = 100 tokens)
    ↓ Portal.refund()
Creator gets 100 tokens back ✓
```

---

## **8. Key Design Decisions**

### **Circular Dependency Resolution**
- **Problem:** Original vault address depends on original intent hash, which depends on route, which includes secondary intent, which needs original vault address as creator
- **Solution:** Secondary intent creator = LocalProver address (known, no circular dependency)
- **Benefit:** LocalProver can trigger refunds on secondary vault since it's the creator

### **Escrow as Accumulator**
- **Problem:** Need to track both initial excess and refunded amounts
- **Solution:** Update EscrowData when secondary vault refunds, single source of truth
- **Benefit:** Simple transfer at end, clear accounting

### **Permissionless Release/Refund**
- **Design:** Anyone can call releaseEscrow or refundEscrow if conditions met
- **Benefit:** Enables automation, reduces trust assumptions
- **Safety:** Funds only go to predetermined recipients (claimant or original vault)

---

## **9. Implementation Order**

1. ✅ Add data structures (mappings, structs)
2. ✅ Add events
3. ✅ Modify `provenIntents()`
4. ✅ Add helper functions
5. ✅ Implement `flashFulfill()`
6. ✅ Implement `releaseEscrow()`
7. ✅ Implement `refundEscrow()`
8. ✅ Add reentrancy guards
9. ✅ Write unit tests
10. ✅ Write integration tests

---

## **10. Testing Strategy**

### **Unit Tests**
- Test provenIntents priority (internal mapping first, then Portal)
- Test flashFulfill with mock fulfill success/failure
- Test releaseEscrow with proven/unproven secondary
- Test refundEscrow with expired/unexpired secondary
- Test escrow amount accumulation
- Test helper functions

### **Integration Tests**
- Full flow: flashFulfill → secondary proven → releaseEscrow
- Full flow: flashFulfill → secondary expired → refundEscrow → Portal.refund
- Test with multiple tokens
- Test with native + ERC20 combinations
- Test reentrancy scenarios
- Test edge cases (zero amounts, missing tokens, etc.)

---

## **11. Open Questions**

1. **How to get secondaryDeadline?**
   - Pass as parameter to flashFulfill?
   - Extract from secondaryIntent parameter?

2. **Bridge recovery address**
   - Should bridge recovery go to original vault or LocalProver?
   - Depends on bridge implementation

3. **Excess calculation**
   - Should we validate minimum excess (ensure solver gets something)?
   - Or allow any amount?

4. **IntentSource type**
   - flashFulfill needs to call withdraw and fulfill
   - Current type is `Inbox`, should it be `Portal` (IntentSource + Inbox)?

---

**Status:** Ready for implementation
**Branch:** feat/localProver_stitching
**Related Contracts:** LocalProver.sol, Portal.sol, IntentSource.sol
