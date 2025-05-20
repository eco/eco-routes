# API Documentation

Type references can be found in the [types directory](/types).

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
- `allowPartial` (bool) Whether to allow partial funding

<ins>Security:</ins> This method is called by the user to create and completely fund an intent. It will fail if the funder does not have sufficient balance or has not given the IntentSource authority to move all the reward funds.

<h4><ins>fund</ins></h4>
<h5>Funds an existing intent</h5>

Parameters:

- `routeHash` (bytes32) The hash of the route component
- `reward` (Reward) Reward structure containing distribution details
- `allowPartial` (bool) Whether to allow partial funding

<ins>Security:</ins> This method is called by the user to completely fund an intent. It will fail if the funder does not have sufficient balance or has not given the IntentSource authority to move all the reward funds.

<h4><ins>fundFor</ins></h4>
<h5>Funds an intent for a user with permit/allowance</h5>

Parameters:

- `routeHash` (bytes32) The hash of the intent's route component
- `reward` (Reward) Reward structure containing distribution details
- `funder` (address) Address to fund the intent from
- `permitContact` (address) Address of the permitContact instance
- `allowPartial` (bool) Whether to allow partial funding

<ins>Security:</ins> This method will fail if allowPartial is false but incomplete funding is provided. Additionally, this method cannot be called for intents with nonzero native rewards.

<h4><ins>publishAndFundFor</ins></h4>
<h5>Creates and funds an intent using permit/allowance</h5>

Parameters:

- `intent` (Intent) The complete intent specification
- `funder` (address) Address to fund the intent from
- `permitContact` (address) Address of the permitContact instance
- `allowPartial` (bool) Whether to allow partial funding

<ins>Security:</ins> This method is called by the user to create and completely fund an intent. It will fail if the funder does not have sufficient balance or has not given the IntentSource authority to move all the reward funds.

<h4><ins>isIntentFunded</ins></h4>
<h5>Checks if an intent is completely funded</h5>

Parameters:

- `intent` (Intent) Intent to validate

<ins>Security:</ins> Returns false if intent is not completely funded

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

- `routeHash` (bytes32) Hash of the route component
- `reward` (Reward) Reward structure containing distribution details

<ins>Security:</ins> Will fail if intent not expired.

<h4><ins>recoverToken</ins></h4>
<h5>Recover tokens that were sent to the intent vault by mistake</h5>

Parameters:

- `routeHash` (bytes32) Hash of the route component
- `reward` (Reward) Reward structure containing distribution details
- `token` (address) Token address for handling incorrect vault transfers

<ins>Security:</ins> Will fail if token is the zero address or the address of any of the reward tokens. Will also fail if intent has nonzero native token rewards and has not yet been claimed or refunded.

## Inbox (Inbox.sol)

The Inbox is where intent fulfillment lives. Solvers fulfill intents on the Inbox via one of the contract's fulfill methods, which pulls in solver resources and executes the intent's calls on the destination chain. Once an intent has been fulfilled, any subsequent attempts to fulfill it will be reverted. The Inbox also contains post-fulfillment proving-related logic and implements ERC-7683 compatibility through inheritance.

### Events

<h4><ins>Fulfillment</ins></h4>
<h5>Emitted when an intent is successfully fulfilled</h5>

Parameters:

- `_hash` (bytes32) The hash of the intent
- `_sourceChainID` (uint256) The ID of the chain where the fulfilled intent originated
- `_localProver` (address) Address of the prover on the destination chain
- `_claimant` (address) The address (on the source chain) that will receive the fulfilled intent's reward

### Methods

<h4><ins>fulfill</ins></h4>
<h5>Fulfills an intent to be proven via storage proofs</h5>

Parameters:

- `_route` (Route) The route of the intent
- `_rewardHash` (bytes32) The hash of the reward details
- `_claimant` (address) The address that will receive the reward on the source chain
- `_expectedHash` (bytes32) The hash of the intent as created on the source chain
- `_localProver` (address) The prover contract to use for verification

<ins>Security:</ins> This method can be called by anyone, but cannot be called again for the same intent, thus preventing a double fulfillment. This method executes arbitrary calls written by the intent creator on behalf of the Inbox contract - this can be perilous. The Inbox will be the msg.sender for these calls.

Here are some of the things a prospective solver should do before fulfilling an intent:

- Check that the intent is funded: this can be verified by calling isIntentFunded on the IntentSource.
- Verify the prover address provided in the intent: fulfilling an intent with a bad prover will result in loss of funds. Eco maintains a list of provers deployed by the team - use other provers at your own risk.
- Check the intent's expiry time - intents that are not proven by the time they expire can have their rewards clawed back by their creator, regardless of if they are fulfilled. Build in a buffer that corresponds to the prover being used.
- Check that the intent is profitable - there is no internal check for this, it is on the solver to ensure that outputs are greater than inputs + gas cost of fulfillment
- Go through the calls to ensure they aren't doing anything unexpected / won't fail and waste gas. Consider using a simulator. Avoid approving unnecessary funds to the Inbox.

This is not a complete list. Exercise caution and vigilance.

<h4><ins>fulfillAndProve</ins></h4>
<h5>Fulfills an intent and initiates proving in one transaction</h5>

Parameters:

- `_route` (Route) The route of the intent
- `_rewardHash` (bytes32) The hash of the reward details
- `_claimant` (address) The address that will receive the reward on the source chain
- `_expectedHash` (bytes32) The hash of the intent as created on the source chain
- `_localProver` (address) Address of prover on the destination chain
- `_data` (bytes) Additional data for message formatting

<ins>Security:</ins> This method inherits all the security features of the fulfill method. It also initiates the proving process in the same transaction, which helps ensure the intent is properly proven on the source chain.

<h4><ins>initiateProving</ins></h4>
<h5>Initiates proving process for fulfilled intents</h5>

Parameters:

- `_sourceChainId` (uint256) Chain ID of the source chain
- `_intentHashes` (bytes32[]) Array of intent hashes to prove
- `_localProver` (address) Address of prover on the destination chain
- `_data` (bytes) Additional data for message formatting

<ins>Security:</ins> This method verifies that the intents have been fulfilled before attempting to prove them. It delegates the actual proving work to the specified prover contract.

**The address of the localProver may not be the same as the prover address in the intent itself. See Eco's prover documentation to find the destination chain prover that corresponds to the source chain prover found in the intent.**

Read the prover contract to see the data expected in the \_data field and how it should be formatted. It should be noted that initiateProving can be called multiple times for the same intent, so mistakes can be rectified by simply calling it again with the proper arguments.

## Prover Architecture

The Eco Protocol implements a modular prover architecture to support different cross-chain messaging systems while sharing common functionality. The hierarchy of provers is as follows:

### BaseProver (BaseProver.sol)

The abstract base contract that defines core proving functionality shared by all prover implementations.

<h4><ins>provenIntents</ins></h4>
<h5>Mapping of intent hashes to their claimant addresses</h5>

Parameters:

- `intentHash` (bytes32) The hash of the intent to query

<h4><ins>getProofType</ins></h4>
<h5>Returns the type of proof used by the prover implementation</h5>

### MessageBridgeProver (MessageBridgeProver.sol)

An abstract contract that extends BaseProver with functionality for message-based proving across different bridge systems.

<h4><ins>prove</ins></h4>
<h5>Initiates the proving process for fulfilled intents</h5>

Parameters:

- `_sender` (address) Address that initiated the proving request
- `_sourceChainId` (uint256) Chain ID of the source chain
- `_intentHashes` (bytes32[]) Array of intent hashes to prove
- `_claimants` (address[]) Array of claimant addresses
- `_data` (bytes) Additional data used for proving (bridge-specific)

<h4><ins>fetchFee</ins></h4>
<h5>Calculates the fee required for cross-chain message dispatch</h5>

Parameters:

- `_sourceChainDomain` (uint32) Domain of the source chain
- `_intentHashes` (bytes32[]) Array of intent hashes to prove
- `_claimants` (address[]) Array of claimant addresses
- `_data` (bytes) Additional data for message formatting

### HyperProver (HyperProver.sol)

A concrete implementation of MessageBridgeProver that uses Hyperlane for cross-chain messaging.

<h4><ins>handle</ins></h4>
<h5>Handles incoming Hyperlane messages containing proof data</h5>

Parameters:

- `_origin` (uint32) Origin chain ID from the source chain
- `_sender` (bytes32) Address that dispatched the message on source chain
- `_messageBody` (bytes) Encoded array of intent hashes and claimants

<ins>Security:</ins> This method is public but there are checks in place to ensure that it reverts unless msg.sender is the local hyperlane mailbox and \_sender is the destination chain's inbox. This method has direct write access to the provenIntents mapping and, therefore, gates access to the rewards for hyperproven intents.

<h4><ins>prove</ins></h4>
<h5>Initiates proving of intents via Hyperlane</h5>

Parameters:

- `_sender` (address) Address that initiated the proving request
- `_sourceChainId` (uint256) Chain ID of the source chain
- `_intentHashes` (bytes32[]) Array of intent hashes to prove
- `_claimants` (address[]) Array of claimant addresses
- `_data` (bytes) Additional data used for proving

<ins>Security:</ins> Validates that the request comes from the Inbox contract and ensures sufficient fees are provided for cross-chain message transmission.

<h4><ins>fetchFee</ins></h4>
<h5>Calculates the fee required for Hyperlane message dispatch</h5>

Parameters:

- `_sourceChainDomain` (uint32) Domain of the source chain
- `_intentHashes` (bytes32[]) Array of intent hashes to prove
- `_claimants` (address[]) Array of claimant addresses
- `_data` (bytes) Additional data for message formatting

<h4><ins>getProofType</ins></h4>
<h5>Returns the proof type used by this prover</h5>

Returns "Hyperlane" to identify the proving mechanism.

### MetaProver

A concrete implementation of MessageBridgeProver that uses Caldera Metalayer for cross-chain messaging. Similar interface to HyperProver but adapted for Metalayer's messaging system.

## ERC-7683 Integration

Eco Protocol has integrated ERC-7683 compatibility directly into the core protocol. The Inbox contract inherits from Eco7683DestinationSettler, providing ERC-7683 settlement functionality while leveraging the modular message bridge architecture for cross-chain communication.

This integration offers several benefits:

- More consistent codebase with less duplication
- Better security through shared validation logic
- More flexible proving mechanisms
- Easier integration of new cross-chain messaging solutions

## Security Features

All message bridge provers implement these security features:

- **Reentrancy Protection**: Guards against reentrancy attacks during token transfers
- **Array Length Validation**: Ensures message data integrity with array length checks
- **Message Sender Validation**: Prevents unauthorized message handling
- **Payment Processing**: Secure handling of native token payments for bridge fees
- **Prover Whitelisting**: Only authorized addresses can initiate proving
