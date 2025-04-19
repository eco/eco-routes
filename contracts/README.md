# API Documentation

Type references can be found in the (types directory)[/types].

## IntentSource

The IntentSource is where intent publishing and reward claiming functionality live. Users (or actors on their behalf) can publish intents here, as well as fund intents' rewards. After an intent is fulfilled and proven, a solver can fetch their rewards here as well. This contract is not expected to hold any funds between transactions.

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

<ins>Security:</ins> This method is called by the user to create and completely fund an intent. It will fail if the funder does not have sufficient balance or has not given the IntentSource authority to move all the reward funds.

<h4><ins>fund</ins></h4>
<h5>Funds an existing intent</h5>

Parameters:

- `intent` (Intent) The complete intent specification
- `reward` (Reward) Reward structure containing distribution details

<ins>Security:</ins> This method is called by the user to completely fund an intent. It will fail if the funder does not have sufficient balance or has not given the IntentSource authority to move all the reward funds.

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

<ins>Security:</ins> This method is called by the user to create and completely fund an intent. It will fail if the funder does not have sufficient balance or has not given the IntentSource authority to move all the reward funds.

<h4><ins>isIntentFunded</ins></h4>
<h5>Checks if an intent is completely funded</h5>

Parameters:

- `intent` (Intent) Intent to validate

<ins>Security:</ins> This method can be called by anyone, but the caller has no specific rights. Whether or not this method succeeds and who receives the funds if it does depend solely on the intent's proven status and expiry time, as well as the claimant address specified by the solver on the Inbox contract on fulfillment.

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

The Inbox is where intent fulfillment lives. Solvers fulfill intents on the Inbox via one of the contract's fulfill methods, which pulls in solver resources and executes the intent's calls on the destination chain. Once an intent has been fulfilled, any subsequent attempts to fulfill it will be reverted. The Inbox also contains some post-fulfillment proving-related logic.

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

<ins>Security:</ins> This method can be called by anyone, but cannot be called again for the same intent, thus preventing a double fulfillment. This method executes arbitrary calls written by the intent creator on behalf of the Inbox contract - it is important that the caller be aware of what they are executing. The Inbox will be the msg.sender for these calls. \_sourceChainID, the destination's chainID, the inbox address, \_targets, \_data, \_expiryTime, and \_nonce are hashed together to form the intent's hash on the IntentSource - any incorrect inputs will result in a hash that differs from the original, and will prevent the intent's reward from being withdrawn (as this means the intent fulfilled differed from the one created). The \_expectedHash input exists only to help prevent this before fulfillment.

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
<h5> Performs the same functionality as fulfillHyperInstant, but allows the user to use a custom HyperLane relayer and pass in the corresponding metadata</h5>

Parameters:

- `_sourceChainID` (uint256) the ID of the chain where the fulfilled intent originated
- `_targets` (address[]) the address on the destination chain at which the instruction sets need to be executed
- `_data` (bytes[]) the instructions to be executed on \_targets
- `_expiryTime` (uint256) the timestamp at which the intent expires
- `_nonce` (bytes32) the nonce of the calldata. Composed of the hash on the source chain of the global nonce and chainID
- `_claimant` (address) the address that can claim the fulfilled intent's fee on the source chain
- `_expectedHash` (bytes32) the hash of the intent. Used to verify that the correct data is being input
- `_prover` (address) the address of the hyperProver on the source chain
- `_metadata` (bytes) Metadata for postDispatchHook (empty bytes if not applicable)
- `_postDispatchHook` (address) Address of postDispatchHook (zero address if not applicable)

<ins>Security:</ins> This method inherits all of the security features in fulfillstorage. This method is also payable, as funds are required to use the hyperlane bridge. Additionally, the user is charged with the responsibility of ensuring that the passed in metadata and relayer perform according to their expectations

<h4><ins>fulfillHyperBatched</ins></h4>`
<h5> Allows a filler to fulfill an intent on its destination chain to be proven by the HyperProver specified in the intent. After fulfilling the intent, this method emits an event that indicates which intent was fulfilled. Fillers of hyperprover-destined intents will listen to these events and batch process them later on. The filler also gets to predetermine the address on the destination chain that will receive the reward tokens. Note: this method is currently not supported by Eco's solver services, but has been included for completeness. Work on services for this method is ongoing.</h5>

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

## HyperProver (HyperProver.sol)

A message-based implementation of BaseProver that consumes data coming from HyperLane's message bridge sent by the Inbox on the destination chain. intentHash - claimant address pairs sent across the chain are written to the HyperProver's provenIntents mapping and are later read by the IntentSource when reward withdrawals are attempted.

### Events

<h4><ins>IntentProven</ins></h4>
<h5> emitted when an intent has been successfully proven</h5>

Parameters:

- `_hash` (bytes32) the hash of the intent
- `_claimant` (address) the address that can claim this intent's rewards

<h4><ins>IntentAlreadyProven</ins></h4>
<h5> emitted when an attempt is made to re-prove an already-proven intent</h5>

Parameters:

- `_hash` (bytes32) the hash of the intent

### Methods

<h4><ins>handle</ins></h4>
<h5>Called by the HyperLane Mailbox contract to finish the HyperProving process. This method parses the message sent via HyperLane into intent hashes and their corresponding claimant addresses, then writes them to the provenIntents mapping so that the IntentSource can read from them when a reward withdrawal is attempted.</h5>

Parameters:

- ` ` (uint32) this variable is not used, but is required by the interface. it is the chain ID of the intent's origin chain.
- `_sender` (bytes32) the address that called dispatch() on the HyperLane Mailbox on the destination chain
- `_messageBody` (bytes) the message body containing intent hashes and their corresponding claimants

<ins>Security:</ins> This method is public but there are checks in place to ensure that it reverts unless msg.sender is the local hyperlane mailbox and \_sender is the destination chain's inbox. This method has direct write access to the provenIntents mapping and, therefore, gates access to the rewards for hyperproven intents.

## Storage Prover (Prover.sol)

A storage-based implementation of BaseProver that utilizes the digests posted between rollups and mainnet to verify fulfilled status of intents on the destination chain.

### Events

<h4><ins>L1WorldStateProven</ins></h4>
<h5> emitted when L1 world state is proven</h5>

Parameters:

- `_blocknumber` (uint256) the block number corresponding to this L1 world state
- `_L1WorldStateRoot` (bytes32) the world state root at \_blockNumber

<h4><ins>L2WorldStateProven</ins></h4>
<h5> emitted when L2 world state is proven</h5>

Parameters:

- `_destinationChainID` (uint256) the chainID of the destination chain
- `_blocknumber` (uint256) the block number corresponding to this L2 world state
- `_L2WorldStateRoot` (bytes32) the world state root at \_blockNumber

<h4><ins>IntentProven</ins></h4>
<h5> emitted when an intent has been successfully proven</h5>

Parameters:

- `_hash` (bytes32) the hash of the intent
- `_claimant` (address) the address that can claim this intent's rewards

### Methods

<h4><ins>proveSettlementLayerState</ins></h4>
<h5> validates input L1 block state against the L1 oracle contract. This method does not need to be called per intent, but the L2 batch containing the intent must have been settled to L1 on or before this block.</h5>

Parameters:

- `rlpEncodedBlockData` (bytes) properly encoded L1 block data

<ins>Security:</ins> This method can be called by anyone. Inputting the correct block's data encoded as expected will result in its hash matching the blockhash found on the L1 oracle contract. This means that the world state root found in that block corresponds to the block on the oracle contract, and that it represents a valid state. Notably, only one block's data is present on the oracle contract at a time, so the input data must match that block specifically, or the method will revert.

<h4><ins>proveWorldStateBedrock</ins></h4>
<h5> Validates World state by ensuring that the passed in world state root corresponds to value in the L2 output oracle on the Settlement Layer.  We submit a `StorageProof` proving that the L2 Block is included in a batch that has been settled to L1 and an `AccountProof` proving that the `StorageProof` submitted is linked to a `WorldState` for the contract that the `StorageProof` is for.</h5>

For Optimisms BedRock release we submit an `outputRoot` storage proof created by concatenating

```solidity
output_root = kecakk256( version_byte || state_root || withdrawal_storage_root || latest_block_hash)
```

## ERC-7683

Eco Protocol also allows the creation and solving of intents via the ERC-7683 interface.

## Eco7683OriginSettler

An implementation of the ERC-7683 OriginSettler designed to work with Eco protocol. This contract is where intents are created and funded. Reward withdrawal has not yet been implemented within Eco's ERC7683 implementation, but it can be accomplished via the IntentSource contract.

### Events

<h4><ins>Open</ins></h4>
<h5>Signals that an order has been opened</h5>

Parameters:

- `orderId` (bytes32) a unique order identifier within this settlement system
- `resolvedOrder` (ResolvedCrossChainOrder) resolved order that would be returned by resolve if called instead of Open

### Methods

<h4><ins>open</ins></h4>
<h5>Opens an Eco intent directly on chain</h5>

Parameters:

- `_order` (OnchainCrossChainOrder) the onchain order containing all relevant intent data. The orderData of the order is of type OnchainCrosschainOrderData.

<ins>Security:</ins> This method will fail if the orderDataType does not match the typehash of OnchainCrosschainOrderData. This method is payable to account for users who wish to create intents that reward solvers with native tokens. A user should have approved the Eco7683OriginSettler to transfer reward tokens. This method will also fail if a user attempts to use it to open an intent that has already been funded.

<h4><ins>openFor</ins></h4>
<h5>Opens an Eco intent on behalf of a user</h5>

Parameters:

- `_order` (GaslessCrossChainOrder) the gasless order containing all relevant intent data. The orderData of the order is of type GaslessCrosschainOrderData.
- `_signature` (bytes32) the intent user's signature over _order
  _ `_originFillerData` (bytes) filler data for the origin chain (this is vestigial, not used and included only to maintain compatibility)

<ins>Security:</ins> This method will fail if the orderDataType does not match the typehash of GaslessCrosschainOrderData. This method is made payable in the event that the caller of this method (a solver) is opening an intent that has native token as a reward. How that solver receives the native token from the user is not within the scope of this method. This method also demands that the intent is funded in its entirety and will fail if the requisite funds have not been approved by the user. Lastly, this method will fail if the same intent has already been funded.

<h4><ins>resolve</ins></h4>
<h5>resolves an OnchainCrossChainOrder to a ResolvedCrossChainOrder</h5>

Parameters:

- `_order` (OnchainCrossChainOrder) the OnchainCrossChainOrder to be resolved

<h4><ins>resolveFor</ins></h4>
<h5>resolves a GaslessCrossChainOrder to a ResolvedCrossChainOrder</h5>

Parameters:

- `_order` (OnchainCrossChainOrder) the GaslessCrossChainOrder to be resolved

## Eco7683DestinationSettler

An implementation of the ERC-7683 DestinationSettler designed to work with Eco protocol. This is an abstract contract whose functionality is present on Eco's Inbox contract. This is where intent fulfillment lives within the ERC-7683 system.

### Events

<h4><ins>OrderFilled</ins></h4>
<h5>Emitted when an intent is fulfilled via the Eco7683DestinationSettler using Hyperlane instant proving</h5>

Parameters:

- `_orderId` (bytes32) Hash of the fulfilled intent
- `_solver` (address) Address that fulfilled the intent

### Methods

<h4><ins>fill</ins></h4>
<h5>Fills an order on the destination chain</h5>

Parameters:

- `_orderId` (bytes32) Unique identifier for the order being filled
- `_originData` (bytes) Data emitted on the origin chain to parameterize the fill, equivalent to the originData field from the fillInstruction of the ResolvedCrossChainOrder. An encoded Intent struct.
- `_fillerData` (bytes) Data provided by the filler to inform the fill or express their preferences. an encoding of the ProofType (enum), claimant (address), and optionally postDispatchHook (address) and metadata (bytes) in the event that the intent is to be proven against a HyperProver.

<ins>Security:</ins> This method fails if the intent's fillDeadline has passed. It also inherits all of the security features in fulfillStorage / fulfillHyperInstantWithRelayer.
