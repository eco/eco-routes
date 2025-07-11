# Eco Protocol Cross-Chain Intent System

## Overview

Eco Protocol enables secure, efficient cross-chain message passing via an intent-based system. This repository contains smart contracts that implement the intent creation, verification, and execution processes.

## Cross-Chain Compatibility Architecture

### Modular Contract Structure

The protocol has been refactored into a modular structure to better support cross-chain compatibility:

1. **BaseSource**: Common functionality shared across all implementations

   - Essential helper functions and state storage
   - Common validation methods and error handling

2. **EvmSource**: EVM-specific implementation using address (20 bytes) types

   - Handles all EVM-specific intent operations
   - Manages reward claiming and refunding

3. **UniversalSource**: Cross-chain compatible implementation using bytes32 (32 bytes) types

   - Universal type support for non-EVM chains like Solana
   - Transparent type conversion for cross-chain compatibility

4. **Portal**: Main entry point combining both implementations
   - Inherits from both UniversalSource and Inbox
   - Presents a unified interface to users

```
Portal
├── UniversalSource (cross-chain implementation)
│   └── EvmSource (address-based implementation)
│       └── BaseSource (common functionality)
└── Inbox (fulfillment functionality)
```

### Dual-Type System

The protocol supports both EVM chains and non-EVM chains like Solana through a dual-type system:

1. **EVM Intent Types (Intent.sol)**

   - Uses Ethereum's native `address` type (20 bytes)
   - Maintains backward compatibility with existing integrations
   - Optimized for EVM-chain interactions

2. **Universal Intent Types (UniversalIntent.sol)**
   - Uses `bytes32` for address identifiers
   - Compatible with all blockchain platforms including Solana
   - Designed for cross-chain messaging
   - Uses the same struct names for simpler integration

### Type Conversion

The protocol includes built-in conversion between the two type systems:

```solidity
// Convert from Universal bytes32 to EVM address
address evmAddress = bytes32AddressId.toAddress();

// Convert from EVM address to Universal bytes32
bytes32 universalAddressId = evmAddress.toBytes32();
```

### Technical Design

The dual-type approach takes advantage of EVM's ABI encoding:

- In EVM, address types are 20 bytes and are padded to 32 bytes when encoded
- The bytes32 type exactly matches this encoding pattern
- This allows both types to be used interchangeably at the binary level

## Integration Guidelines

### For EVM-Only Applications

If your application only needs to interact with EVM chains:

1. Import and use the EVM-specific types:

   ```solidity
   import { Intent, Route, Reward } from "./types/Intent.sol";
   ```

2. Create intents using the familiar address types:

   ```solidity
   Intent memory intent = Intent({
       route: Route({
           salt: bytes32(0),
           source: 1,
           destination: 2,
           inbox: 0x1234...,  // regular address type
           tokens: tokenAmounts,
           calls: calls
       }),
       reward: Reward({...})
   });
   ```

3. Use the Portal contract directly:
   ```solidity
   // The interface will use address types automatically
   IIntentSource intentSource = IIntentSource(portalAddress);
   bytes32 intentHash = intentSource.publish(intent);
   ```

### For Cross-Chain Applications

If your application needs to interact with both EVM and non-EVM chains:

1. Import and use the universal types:

   ```solidity
   import { Intent, Route, Reward } from "./types/UniversalIntent.sol";
   import { AddressConverter } from "./libs/AddressConverter.sol";
   ```

2. Create intents using bytes32 for address identifiers:

   ```solidity
   Intent memory universalIntent = Intent({
       route: Route({
           salt: bytes32(0),
           source: 1,
           destination: 2,
           inbox: AddressConverter.toBytes32(0x1234...),  // convert EVM address to bytes32
           tokens: tokenAmounts,
           calls: calls
       }),
       reward: Reward({...})
   });
   ```

3. Use the IUniversalIntentSource interface:
   ```solidity
   // Use the universal interface with bytes32 types
   IUniversalIntentSource intentSource = IUniversalIntentSource(portalAddress);
   bytes32 intentHash = intentSource.publish(universalIntent);
   ```

## Best Practices

1. Use the universal types (bytes32-based) for core protocol interactions
2. Use the EVM-specific types for user-facing interfaces on EVM chains
3. Convert between types at the edge of your application
4. Remember that reward claiming is always EVM-specific

## Implementation Details

The system consists of the following key components:

1. **Intent Types**:

   - `Intent.sol`: EVM-specific types using address (20 bytes)
   - `UniversalIntent.sol`: Universal types using bytes32 (32 bytes)

2. **Source Implementations**:

   - `BaseSource.sol`: Common functionality
   - `EvmSource.sol`: EVM-specific implementation
   - `UniversalSource.sol`: Cross-chain implementation
   - `Portal.sol`: Combined implementation with Inbox

3. **Conversion Utilities**:
   - `AddressConverter.sol`: Convert between address and bytes32

# API Documentation

Type references can be found in the (types directory)[/types].

## Portal

The Portal is where intent publishing, fulfillment, and reward claiming functionality live. Users (or actors on their behalf) can publish intents here, as well as fund intents' rewards. Solvers can fulfill intents on the destination chain through the Portal. After an intent is fulfilled and proven, a solver can fetch their rewards here as well. This contract is not expected to hold any funds between transactions.

### Events

<h4><ins>IntentPartiallyFunded</ins></h4>
<h5>Signals partial funding of an intent with native tokens</h5>

Parameters:

- `intentHash` (bytes32) The hash of the partially funded intent
- `funder` (address) The address providing the partial funding

<h4><ins>IntentFunded</ins></h4>
<h5>Signals complete funding of an intent with native tokens</h5>

Parameters:

- `intentHash` (bytes32) The hash of the partially funded intent
- `funder` (address) The address providing the partial funding

<h4><ins>IntentCreated</ins></h4>
<h5>Signals the creation of a new cross-chain intent</h5>

Parameters:

- `hash` (bytes32) Unique identifier of the intent
- `salt` (bytes32) Creator-provided uniqueness factor
- `source` (uint256) Source chain identifier
- `destination` (uint256) Destination chain identifier
- `inbox` (address) Address of the receiving contract on the destination chain
- `routeTokens` (TokenAmount[]) Required tokens for executing destination chain calls
- `calls` (Call[]) Instructions to execute on the destination chain
- `creator` (address) Intent originator address
- `prover` (address) Prover contract address
- `deadline` (address) Timestamp for reward claim eligibility
- `nativeValue` (uint256) Native token reward amount
- `rewardTokens` (TokenAmount[]) ERC20 token rewards with amounts

<h4><ins>UniversalIntentCreated</ins></h4>
<h5>Signals the creation of a new cross-chain intent with Universal types</h5>

Parameters:

- `hash` (bytes32) Unique identifier of the intent
- `salt` (bytes32) Creator-provided uniqueness factor
- `source` (uint256) Source chain identifier
- `destination` (uint256) Destination chain identifier
- `inbox` (bytes32) Identifier of the receiving contract on destination chain
- `routeTokens` (TokenAmount[]) Required tokens for executing destination chain calls
- `calls` (Call[]) Instructions to execute on the destination chain
- `creator` (address) Intent originator address
- `prover` (address) Prover contract address
- `deadline` (uint256) Timestamp for reward claim eligibility
- `nativeValue` (uint256) Native token reward amount
- `rewardTokens` (TokenAmount[]) Token rewards with amounts

<h4><ins>Withdrawal</ins></h4>
<h5>Signals successful reward withdrawal</h5>

Parameters:

- `hash` (bytes32) The hash of the claimed intent
- `recipient` (address) The address receiving the rewards

<h4><ins>Refund</ins></h4>
<h5>Signals successful reward refund</h5>

Parameters:

- `hash` (bytes32) The hash of the refunded intent
- `recipient` (address) The address receiving the refund

### Methods

<h4><ins>getRewardStatus</ins></h4>
<h5>Retrieves the current reward claim status for an intent</h5>

Parameters:

- `intentHash` (bytes32) The hash of the intent

<h4><ins>getVaultState</ins></h4>
<h5>Retrieves the current state of an intent's vault</h5>

Parameters:

- `intentHash` (bytes32) The hash of the intent

<h4><ins>getPermitContract</ins></h4>
<h5> Retrieves the permit contract for the token transfers</h5>

Parameters:

- `intentHash` (bytes32) The hash of the intent

<h4><ins>getIntentHash</ins></h4>
<h5>Computes the hash components of an intent</h5>

Parameters:

- `intent` (Intent) The intent to hash

<h4><ins>intentVaultAddress</ins></h4>
<h5>Computes the deterministic vault address for an intent</h5>

Parameters:

- `intent` (Intent) The intent to calculate the vault address for

<h4><ins>publish</ins></h4>
<h5>Creates a new cross-chain intent with associated rewards</h5>

Parameters:

- `intent` (Intent) The complete intent specification

<ins>Security:</ins> This method can be called to create an intent on anyone's behalf. It does not transfer any funds. It emits an event that would give a solver all the information required to fulfill the intent, but the solver is expected to check that the intent is funded before fulfilling.

<h4><ins>publishAndFund</ins></h4>
<h5>Creates and funds an intent in a single transaction</h5>

Parameters:

- `intent` (Intent) The complete intent specification

<ins>Security:</ins> This method is called by the user to create and completely fund an intent. It will fail if the funder does not have sufficient balance or has not given the Portal authority to move all the reward funds.

<h4><ins>fund</ins></h4>
<h5>Funds an existing intent</h5>

Parameters:

- `intent` (Intent) The complete intent specification
- `reward` (Reward) Reward structure containing distribution details

<ins>Security:</ins> This method is called by the user to completely fund an intent. It will fail if the funder does not have sufficient balance or has not given the Portal authority to move all the reward funds.

<h4><ins>fundFor</ins></h4>
<h5>Funds an intent for a user with permit/allowance</h5>

Parameters:

- `routeHash` (bytes32) The hash of the intent's route component
- `reward` (Reward) Reward structure containing distribution details
- `funder` (address) Address to fund the intent from
- `permitContract` (address) Address of the permitContract instance
- `allowPartial` (bool) Whether to allow partial funding

<ins>Security:</ins> This method will fail if allowPartial is false but incomplete funding is provided. Additionally, this method cannot be called for intents with nonzero native rewards.

<h4><ins>publishAndFundFor</ins></h4>
<h5>Creates and funds an intent using permit/allowance</h5>

Parameters:

- `intent` (Intent) The complete intent specification
- `funder` (address) Address to fund the intent from
- `permitContract` (address) Address of the permitContract instance
- `allowPartial` (bool) Whether to allow partial funding

<ins>Security:</ins> This method is called by the user to create and completely fund an intent. It will fail if the funder does not have sufficient balance or has not given the Portal authority to move all the reward funds.

<h4><ins>isIntentFunded</ins></h4>
<h5>Checks if an intent is completely funded</h5>

Parameters:

- `intent` (Intent) Intent to validate

<ins>Security:</ins> This method can be called by anyone, but the caller has no specific rights. Whether or not this method succeeds and who receives the funds if it does depend solely on the intent's proven status and expiry time, as well as the claimant address specified by the solver on the Portal contract on fulfillment.

<h4><ins>withdrawRewards</ins></h4>
<h5>Claims rewards for a successfully fulfilled and proven intent</h5>

Parameters:

- `routeHash` (bytes32) The hash of the intent's route component
- `reward` (Reward) Reward structure containing distribution details

<ins>Security:</ins> Can withdraw anyone's intent, but only to the claimant predetermined by its solver. Withdraws to solver only if intent is proven.

<h4><ins>batchWithdraw</ins></h4>
<h5>Claims rewards for multiple fulfilled and proven intents</h5>

Parameters:

- `routeHashes` (bytes32[]) Array of route component hashes
- `reward` (Reward[]) Array of corresponding reward specifications

<ins>Security:</ins> Can withdraw anyone's intent, but only to the claimant predetermined by its solver. Withdraws to solver only if intent is proven.

<h4><ins>refund</ins></h4>
<h5>Returns rewards to the intent creator</h5>

Parameters:

- `routeHashes` (bytes32[]) Array of route component hashes
- `reward` (Reward[]) Array of corresponding reward specifications

<ins>Security:</ins> Will fail if intent not expired.

<h4><ins>recoverToken</ins></h4>
<h5>Recover tokens that were sent to the intent vault by mistake</h5>

Parameters:

- `routeHashes` (bytes32[]) Array of route component hashes
- `reward` (Reward[]) Array of corresponding reward specifications
- `token` (address) Token address for handling incorrect vault transfers

<ins>Security:</ins> Will fail if token is the zero address or the address of any of the reward tokens. Will also fail if intent has nonzero native token rewards and has not yet been claimed or refunded.

## Inbox (Inbox.sol)

The Inbox functionality is now integrated into the Portal contract. Solvers fulfill intents on the Portal via one of the contract's fulfill methods, which pulls in solver resources and executes the intent's calls on the destination chain. Once an intent has been fulfilled, any subsequent attempts to fulfill it will be reverted. The Portal also contains some post-fulfillment proving-related logic.

### Events

<h4><ins>Fulfillment</ins></h4>
<h5>Emitted when an intent is successfully fulfilled</h5>

Parameters:

- `_hash` (bytes32) the hash of the intent
- `_sourceChainID` (uint256) the ID of the chain where the fulfilled intent originated
- `_claimant` (address) the address (on the source chain) that will receive the fulfilled intent's reward

<h4><ins>ToBeProven</ins></h4>
<h5>Emitted when an intent is ready to be proven via a storage prover</h5>

Parameters:

- `_hash` (bytes32) the hash of the intent
- `_sourceChainID` (uint256) the ID of the chain where the fulfilled intent originated
- `_claimant` (address) the address (on the source chain) that will receive the fulfilled intent's reward

<h4><ins>HyperInstantFulfillment</ins></h4>
<h5>Emitted when an intent is fulfilled with the instant hyperprover path</h5>

Parameters:

- `_hash` (bytes32) the hash of the intent
- `_sourceChainID` (uint256) the ID of the chain where the fulfilled intent originated
- `_claimant` (address) the address (on the source chain) that will receive the fulfilled intent's reward

<h4><ins>AddToBatch</ins></h4>
<h5>Emitted when an intent is added to a batch to be proven with the hyperprover</h5>

Parameters:

- `_hash` (bytes32) the hash of the intent
- `_sourceChainID` (uint256) the ID of the chain where the fulfilled intent originated
- `_claimant` (address) the address (on the source chain) that will receive the fulfilled intent's reward
- `_prover` (address) the address of the HyperProver these intents will be proven on

<h4><ins>AddToBatch</ins></h4>
<h5>Emitted when an intent is added to a Hyperlane batch</h5>

Parameters:

- `_hash` (bytes32) the hash of the intent
- `_sourceChainID` (uint256) the ID of the chain where the fulfilled intent originated
- `_claimant` (address) the address (on the source chain) that will receive the fulfilled
  intent's reward
- `_prover` (address) the address of the Hyperlane prover

<h4><ins>SolvingIsPublic</ins></h4>
<h5>Emitted when solving is made public</h5>

<h4><ins>MailboxSet</ins></h4>
<h5>Emitted when Hyperlane mailbox address is set</h5>

Parameters:

- `_mailbox` (address) address of the mailbox contract

<h4><ins>SolverWhitelistChanged</ins></h4>
<h5>Emitted when the solver whitelist permissions are changed</h5>

Parameters:

- `_solver` (address) the address of the solver whose permissions are being changed
- `_canSolve`(bool) whether or not \_solver will be able to solve after this method is called

### Methods

<h4><ins>fulfillStorage</ins></h4>
<h5> Allows a filler to fulfill an intent on its destination chain to be proven by the StorageProver specified in the intent. The filler also gets to predetermine the address on the destination chain that will receive the reward tokens.</h5>

Parameters:

- `_sourceChainID` (uint256) the ID of the chain where the fulfilled intent originated
- `_targets` (address[]) the address on the destination chain at which the instruction sets need to be executed
- `_data` (bytes[]) the instructions to be executed on \_targets
- `_expiryTime` (uint256) the timestamp at which the intent expires
- `_nonce` (bytes32) the nonce of the calldata. Composed of the hash on the source chain of the global nonce and chainID
- `_claimant` (address) the address that can claim the fulfilled intent's fee on the source chain
- `_expectedHash` (bytes32) the hash of the intent. Used to verify that the correct data is being input

<ins>Security:</ins> This method can be called by anyone, but cannot be called again for the same intent, thus preventing a double fulfillment. This method executes arbitrary calls written by the intent creator on behalf of the Portal contract - it is important that the caller be aware of what they are executing. The Portal will be the msg.sender for these calls. \_sourceChainID, the destination's chainID, the portal address, \_targets, \_data, \_expiryTime, and \_nonce are hashed together to form the intent's hash on the Portal - any incorrect inputs will result in a hash that differs from the original, and will prevent the intent's reward from being withdrawn (as this means the intent fulfilled differed from the one created). The \_expectedHash input exists only to help prevent this before fulfillment.

<h4><ins>fulfillHyperInstant</ins></h4>
<h5> Allows a filler to fulfill an intent on its destination chain to be proven by the HyperProver specified in the intent. After fulfilling the intent, this method packs the intentHash and claimant into a message and sends it over the Hyperlane bridge to the HyperProver on the source chain. The filler also gets to predetermine the address on the destination chain that will receive the reward tokens.</h5>

Parameters:

- `_sourceChainID` (uint256) the ID of the chain where the fulfilled intent originated
- `_targets` (address[]) the address on the destination chain at which the instruction sets need to be executed
- `_data` (bytes[]) the instructions to be executed on \_targets
- `_expiryTime` (uint256) the timestamp at which the intent expires
- `_nonce` (bytes32) the nonce of the calldata. Composed of the hash on the source chain of the global nonce and chainID
- `_claimant` (address) the address that can claim the fulfilled intent's fee on the source chain
- `_expectedHash` (bytes32) the hash of the intent. Used to verify that the correct data is being input
- `_prover` (address) the address of the hyperProver on the source chain

<ins>Security:</ins> This method inherits all of the security features in fulfillstorage. This method is also payable, as funds are required to use the hyperlane bridge.

<h4><ins>fulfillHyperInstantWithRelayer</ins></h4>
<h5> Performs the same functionality as fulfillHyperInstant, but allows the user to use a custom HyperLane relayer and pass in the corresponding metadata. </h5>

Parameters:

- `_sourceChainID` (uint256) the ID of the chain where the fulfilled intent originated
- `_targets` (address[]) the address on the destination chain at which the instruction sets need to be executed
- `_data` (bytes[]) the instructions to be executed on \_targets
- `_expiryTime` (uint256) the timestamp at which the intent expires
- `_nonce` (bytes32) the nonce of the calldata. Composed of the hash on the source chain of the global nonce and chainID
- `_claimant` (address) the address that can claim the fulfilled intent's fee on the source chain
- `_expectedHash` (bytes32) the hash of the intent. Used to verify that the correct data is being input
- `_prover` (address) the address of the hyperProver on the source chain

<ins>Security:</ins> This method inherits all of the security features in fulfillstorage.

<h4><ins>sendBatch</ins></h4>

<h5> Allows a filler to send a batch of HyperProver-destined intents over the HyperLane bridge. This reduces the cost per intent proven, as intents that would have had to be sent in separate messages are now consolidated into one. </h5>

Parameters:

- `_sourceChainID` (uint256) the chainID of the source chain
- `_prover` (address) the address of the hyperprover on the source chain
- `_intentHashes` (bytes32[]) the hashes of the intents to be proven

<ins>Security:</ins> This method ensures that all passed-in hashes correspond to intents that have been fulfilled according to the inbox. It contains a low-level call to send native tokens, but will only do this in the event that the call to this method has a nonzero msg.value. The method is payable because the HyperLane relayer requires fees in native token in order to function.

<h4><ins>sendBatchWithRelayer</ins></h4>

<h5> Performs the same functionality as sendBatch, but allows the user to use a custom HyperLane relayer and pass in the corresponding metadata. </h5>

Parameters:

- `_sourceChainID` (uint256) the chainID of the source chain
- `_prover` (address) the address of the hyperprover on the source chain
- `_intentHashes` (bytes32[]) the hashes of the intents to be proven
- `_metadata` (bytes) Metadata for postDispatchHook (empty bytes if not applicable)
- `_postDispatchHook` (address) Address of postDispatchHook (zero address if not applicable)

<ins>Security:</ins> This method inherits all of the security features in sendBatch. Additionally, the user is charged with the responsibility of ensuring that the passed in metadata and relayer perform according to their expectations.

<h4><ins>fetchFee</ins></h4>

<h5> A passthrough method that calls the HyperLane Mailbox and fetches the cost of sending a given message. This method is used inside both the fulfillHyperInstant and sendBatch methods to ensure that the user has enough gas to send the message over HyperLane's bridge.</h5>

Parameters:

- `_sourceChainID` (uint256) the chainID of the source chain
- `_messageBody` (bytes) the message body being sent over the bridge
- `_prover` (address) the address of the hyperprover on the source chain

<ins>Security:</ins> This method inherits all of the security features in fulfillstorage. This method is also payable, as funds are required to use the hyperlane bridge.

<h4><ins>makeSolvingPublic</ins></h4>

<h5>Opens up solving functionality to all addresses if it is currently restricted to a whitelist.</h5>

<ins>Security:</ins> This method can only be called by the owner of the Inbox, and can only be called if solving is not currently public. There is no function to re-restrict solving - once it is public it cannot become private again.

<h4><ins>changeSolverWhitelist</ins></h4>

<h5>Changes the solving permissions for a given address.</h5>

Parameters:

- `_solver` (address) the address of the solver whose permissions are being changed
- `_canSolve`(bool) whether or not \_solver will be able to solve after this method is called

<ins>Security:</ins> This method can only be called by the owner of the Inbox. This method has no tangible effect if isSolvingPublic is true.

<h4><ins>drain</ins></h4>

<h5>Transfers excess gas token out of the contract.</h5>

Parameters:

- `_destination` (address) the destination of the transferred funds

<ins>Security:</ins> This method can only be called by the owner of the Inbox. This method is primarily for testing purposes.

## Cross-Chain Message Bridge Architecture

Eco Protocol has been refactored to use a modular message bridge architecture for cross-chain communication. This allows the protocol to leverage different messaging systems like Hyperlane and Metalayer while maintaining a consistent interface.

### Message Bridge Provers

The protocol now follows a flexible architecture with a hierarchy of prover implementations:

1. **BaseProver**: Abstract base contract that defines core proving functionality
2. **MessageBridgeProver**: Abstract contract that extends BaseProver with common functionality for message-based proving
3. **Concrete Provers**: Specific implementations for different messaging systems:
   - **HyperProver**: Uses Hyperlane for cross-chain messaging
   - **MetaProver**: Uses Caldera Metalayer for cross-chain messaging

### Security Features

All message bridge provers implement these security features:

- **Reentrancy Protection**: Guards against reentrancy attacks during token transfers
- **Array Length Validation**: Ensures message data integrity with array length checks
- **Message Sender Validation**: Prevents unauthorized message handling
- **Payment Processing**: Secure handling of native token payments for bridge fees
- **Prover Whitelisting**: Only authorized addresses can initiate proving

### Integration Patterns

To use a message bridge prover with the Eco Protocol:

1. **Deploy the Prover**: Deploy the specific prover (HyperProver or MetaProver) with configuration for your chosen message bridge
2. **Register with Inbox**: Add the prover to the Inbox's approved provers list
3. **Create Intents**: Create intents specifying the prover to use for cross-chain proof transmission
4. **Solve Intents**: When solving intents, specify the appropriate proof type in the fulfillment call

### Supported Message Bridges

#### Hyperlane

The HyperProver uses Hyperlane's IMessageRecipient interface to receive and process cross-chain messages. It interacts with the Hyperlane Mailbox contract to send and receive messages.

Configuration parameters:

- Mailbox address: Address of the Hyperlane Mailbox on the current chain
- Trusted provers: List of addresses authorized to send proof messages

#### Metalayer

The MetaProver uses Caldera Metalayer's IMetalayerRecipient interface to receive and process cross-chain messages. It interacts with the Metalayer Router contract to send and receive messages.

Configuration parameters:

- Router address: Address of the Metalayer Router on the current chain
- Trusted provers: List of addresses authorized to send proof messages

### ERC-7683 Support

The previous standalone ERC-7683 implementation has been refactored into the core protocol. Instead of separate settler contracts, ERC-7683 compatibility is now integrated within the Inbox contract using the message bridge provers for cross-chain communication.

This refactoring offers several benefits:

- More consistent codebase with less duplication
- Better security through shared validation logic
- More flexible proving mechanisms
- Easier integration of new cross-chain messaging solutions
