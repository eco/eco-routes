<div id="top"></div>
<h1>Cross-L2 Actions</h1>

</div>

- [Abstract](#Abstract)
- [Components](#Components)
- [Usage](#usage)
  - [Installation](#installation)
  - [Testing](#testing)
  - [Deployment](#deployment)
  - [End-to-End Testing](#end-to-end-testing)
- [Contributing](#contributing)
- [License](#license)
- [Contact](#contact)

## Abstract

An intents-driven, permissionless, trust-neutral protocol for facilitating the creation, incentivized execution, and proof of cross-L2 transactions.

**Warning: This code has not been audited. Use at your own risk.**

- [Intent Creation / Settlement](#intent-creation--settlement)
- [Intent Fulfillment / Execution](#intent-fulfillment--execution)
- [Intent Proving](#intent-proving)

We identify three main user profiles:

- `Users`: Individuals who want to transact across different L2s.
- `Fillers`: Individuals interested in performing transactions on behalf of others for a fee.
- `Provers`: Individuals interested in proving on the source chain that an intent was fulfilled on the destination chain.

### How it works

A `User` initiates a cross-chain transaction by creating an intent. Put simply, an intent represents a `User`'s end goals on the destination chain. It contains the calls they'd want to make, those calls' corresponding addresses, and the price they'd be willing to pay someone to execute this call on their behalf, along with other metadata. Seeing this intent and being enticed by the fee they'd receive, a `Filler` creates and executes a fulfill transaction on the destination chain that corresponds to the user's intent, storing the fulfilled intent's hash on the destination chain. A `Prover` - perhaps the `Filler` themselves or a service they subscribe to - sees this fulfillment transaction and performs a proof that the hash of the fulfilled transaction on the destination chain matches that of the intent on the source chain. After the intent proven, the filler can withdraw their reward.

## Components

Within the following sections, the terms 'source chain' and 'destination chain' will be relative to any given intent. Each supported chain will have its own `IntentSource`, `Inbox` and `Prover`.

### Intent Creation / Settlement

Intent creation and filler settlement processes both exist on the `IntentSource` on the source chain, and is where the full intent lifecycle will start and end. Both `Users` and `Fillers` interact with this contract, Users to create intents and `Fillers` to claim their reward after fulfillment has been proven.

### Intent Fulfillment / Execution

Intent fulfillment lives on the `Inbox`, which lives on the destination chain. `Fillers` interact with this contract to `fulfill` Users' intents. At time of launch, solving will be private, restricted only to a whitelisted set of filler addresses while we live test the system, but it will soon become possible for anyone to fill orders.

This contract is where the intent lifecycle will start and end. Intent creation and settlement processes both exist on `IntentSource.sol` on the source chain. Both `Users` and `Fillers` interact with this contract, Users to create intents and `Fillers` to claim their reward after fulfillment has been proven.

Intent proving lives on the `Prover`, which is on the source chain. `Provers` are the parties that should be interacting with the Prover contract, but the `IntentSource` does read state from it.

**See [contracts](/contracts) for a detailed API documentation**

## Future Work

- `_hash` (bytes32) the hash of the intent, also the key to the intents mapping
- `_creator` (address) the address that created the intent
- `_destinationChain` (uint256) the destination chain
- `_targets` (address[]) the address on \_destinationChain at which the instruction sets need to be executed
- `_data` (bytes[]) the instructions to be executed on \_targets
- `_rewardTokens` (address[]) the addresses of reward tokens
- `_rewardAmounts` (uint256[]) the amounts of reward tokens
- `_expiryTime` (uint256) the time by which the storage proof must have been created in order for the filler to redeem rewards.
- `_prover` (address) the prover that will verify whether or not this intent has been fulfilled on the destination chain.

## Usage

To get a local copy up and running follow these simple steps.

### Prerequisites

Running this project locally requires the following:

- [NodeJS v18.20.3](https://nodejs.org/en/blog/release/v18.20.3) - using nvm (instructions below)
- [Yarn v1.22.19](https://www.npmjs.com/package/yarn/v/1.22.19)

It is recommended to use `nvm` to install Node. This is a Node version manager so your computer can easily handle multiple versions of Node:

1. Install `nvm` using the following command in your terminal:

<ins>Security:</ins> This method has no permissioning, it can be called by anyone. Notably, it asks the user for raw calldata to be executed by the filler, and transfers tokens from the user into the IntentSource contract. It is very important, therefore, that a user knows exactly what commands they are executing and what their consequences are, as well as what tokens in what quantity they intend to lock up. Also, the user must give this contract permission to move their tokens via a method like permit or approve, otherwise it will revert.

<h4><ins>withdrawRewards</ins></h4>
<h5>Allows withdrawal of reward funds locked up for a given intent.</h5>

Attributes:

- `_hash` (bytes32) the hash of the intent on which withdraw is being attempted

<ins>Security:</ins> This method can be called by anyone, but the caller has no specific rights. Whether or not this method succeeds and who receives the funds if it does depend solely on the intent's proven status and expiry time, as well as the claimant address specified by the solver on the Inbox contract on fulfillment.

## Intent Fulfillment / Execution

Intent fulfillment lives on `Inbox.sol`, which lives on the destination chain. `Fillers` interact with this contract to `fulfill` Users' intents. At time of launch, solving will be private, restricted only to a whitelisted set of filler addresses while we live test the system, but it will soon become possible for anyone to fill orders. `Fillers` may have to call different fulfill methods depending on the prover address specified in the intent - a HyperProver address necessitates a call to either FulfillHyperInstant or FulfillHyperBatched, and a StorageProver necessitates a call to fulfillStorage. See [Intent Proving](#Intent-Proving) for more information.

### Events

<h4><ins>Fulfillment</ins></h4>
<h5>Emitted when an intent is successfully fulfilled</h5>

Attributes:

- `_hash` (bytes32) the hash of the intent, also the key to the intents mapping
- `_sourceChainID` (uint256) the ID of the chain where the fulfilled intent originated
- `_claimant` (address) the address (on the source chain) that will receive the fulfilled intent's reward

<h4><ins>ToBeProven</ins></h4>
<h5>Emitted when an intent is ready to be proven via a storage prover</h5>

Attributes:

- `_hash` (bytes32) the hash of the intent, also the key to the intents mapping
- `_sourceChainID` (uint256) the ID of the chain where the fulfilled intent originated
- `_claimant` (address) the address (on the source chain) that will receive the fulfilled intent's reward

<h4><ins>HyperInstantFulfillment</ins></h4>
<h5>Emitted when an intent is fulfilled with the instant hyperprover path</h5>

Attributes:

- `_hash` (bytes32) the hash of the intent, also the key to the intents mapping
- `_sourceChainID` (uint256) the ID of the chain where the fulfilled intent originated
- `_claimant` (address) the address (on the source chain) that will receive the fulfilled intent's reward

<h4><ins>AddToBatch</ins></h4>
<h5>Emitted when an intent is added to a batch to be proven with the hyperprover</h5>

Attributes:

- `_hash` (bytes32) the hash of the intent, also the key to the intents mapping
- `_sourceChainID` (uint256) the ID of the chain where the fulfilled intent originated
- `_claimant` (address) the address (on the source chain) that will receive the fulfilled intent's reward
- `_prover` (address) the address of the HyperProver these intents will be proven on

<h4><ins>SolvingIsPublic</ins></h4>
<h5>Emitted when solving is made public</h5>

<h4><ins>SolverWhitelistChanged</ins></h4>
<h5>Emitted when the solver whitelist permissions are changed</h5>

Attributes:

- `_solver` (address) the address of the solver whose permissions are being changed
- `_canSolve`(bool) whether or not \_solver will be able to solve after this method is called

### Methods

<h4><ins>fulfillStorage</ins></h4>
<h5> Allows a filler to fulfill an intent on its destination chain to be proven by the StorageProver specified in the intent. The filler also gets to predetermine the address on the destination chain that will receive the reward tokens.</h5>

Attributes:

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

Attributes:

- `_sourceChainID` (uint256) the ID of the chain where the fulfilled intent originated
- `_targets` (address[]) the address on the destination chain at which the instruction sets need to be executed
- `_data` (bytes[]) the instructions to be executed on \_targets
- `_expiryTime` (uint256) the timestamp at which the intent expires
- `_nonce` (bytes32) the nonce of the calldata. Composed of the hash on the source chain of the global nonce and chainID
- `_claimant` (address) the address that can claim the fulfilled intent's fee on the source chain
- `_expectedHash` (bytes32) the hash of the intent. Used to verify that the correct data is being input
- `_prover` (address) the address of the hyperProver on the source chain

<ins>Security:</ins> This method inherits all of the security features in fulfillstorage. This method is also payable, as funds are required to use the hyperlane bridge.

<h4><ins>fulfillHyperBatched</ins></h4>
<h5> Allows a filler to fulfill an intent on its destination chain to be proven by the HyperProver specified in the intent. After fulfilling the intent, this method emits an event that indicates which intent was fulfilled. Fillers of hyperprover-destined intents will listen to these events and batch process them later on. The filler also gets to predetermine the address on the destination chain that will receive the reward tokens. Note: this method is currently not supported by Eco's solver services, but has been included for completeness. Work on services for this method is ongoing.</h5>

Attributes:

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

Attributes:

- `_sourceChainID` (uint256) the chainID of the source chain
- `_prover` (address) the address of the hyperprover on the source chain
- `_intentHashes` (bytes32[]) the hashes of the intents to be proven

<ins>Security:</ins> This method inherits all of the security features in fulfillstorage. This method is also payable, as funds are required to use the hyperlane bridge.

<h4><ins>fetchFee</ins></h4>

<h5> A passthrough method that calls the HyperLane Mailbox and fetches the cost of sending a given message. This method is used inside both the fulfillHyperInstant and sendBatch methods to ensure that the user has enough gas to send the message over HyperLane's bridge.</h5>

Attributes:

- `_sourceChainID` (uint256) the chainID of the source chain
- `_messageBody` (bytes) the message body being sent over the bridge
- `_prover` (address) the address of the hyperprover on the source chain

<ins>Security:</ins> This method inherits all of the security features in fulfillstorage. This method is also payable, as funds are required to use the hyperlane bridge.

<h4><ins>setMailbox</ins></h4>

<h5>Sets the HyperLane Mailbox address to be used for all HyperProving fulfills.</h5>

Attributes:

- `_mailbox` (address) the address of the mailbox.

<ins>Security:</ins> This method can only be called by the owner of the Inbox, and can only be called if the current mailbox address is the zero address. It is intended to be called at time of construction.

<h4><ins>makeSolvingPublic</ins></h4>

<h5>Opens up solving functionality to all addresses if it is currently restricted to a whitelist.</h5>

<ins>Security:</ins> This method can only be called by the owner of the Inbox, and can only be called if solving is not currently public. There is no function to re-restrict solving - once it is public it cannot become private again.

<h4><ins>changeSolverWhitelist</ins></h4>

<h5>Changes the solving permissions for a given address.</h5>

Attributes:

- `_solver` (address) the address of the solver whose permissions are being changed
- `_canSolve`(bool) whether or not \_solver will be able to solve after this method is called

<ins>Security:</ins> This method can only be called by the owner of the Inbox. This method has no tangible effect if isSolvingPublic is true.

<h4><ins>drain</ins></h4>

<h5>Transfers excess gas token out of the contract.</h5>

Attributes:

- `_destination` (address) the destination of the transferred funds

<ins>Security:</ins> This method can only be called by the owner of the Inbox. This method is primarily for testing purposes.

## Intent Proving

Intent proving lives on `Prover.sol` and `HyperProver.sol`, which are on the source chain. `Prover`s are the parties that should be interacting with the `Prover` contract, but the `IntentSource` reads state from it. The methods in this contract are complex and require inputs that can be difficult to generate. In the future we will be building out services to assist with proving, as well as publishing an SDK for input generation and/or spinning up independent proving services. The `HyperProver` contract requires no `Prover` entity to interact with it, but is also read by the `IntentSource`. Please see the scripts directory for usage examples.

## HyperProver (HyperProver.sol)

### Events

<h4><ins>IntentProven</ins></h4>
<h5> emitted when an intent has been successfully proven</h5>

Attributes:

- `_hash` (bytes32) the hash of the intent
- `_claimant` (address) the address that can claim this intent's rewards

<h4><ins>IntentAlreadyProven</ins></h4>
<h5> emitted when an attempt is made to re-prove an already-proven intent</h5>

Attributes:

- `_hash` (bytes32) the hash of the intent

### Methods

<h4><ins>handle</ins></h4>
<h5>Called by the HyperLane Mailbox contract to finish the HyperProving process. This method parses the message sent via HyperLane into intent hashes and their corresponding claimant addresses, then writes them to the provenIntents mapping so that the IntentSource can read from them when a reward withdrawal is attempted.</h5>

Attributes:

- ` ` (uint32) this variable is not used, but is required by the interface. It is the chain ID of the intent's origin chain.
- `_sender` (bytes32) the address that called dispatch() on the HyperLane Mailbox on the destination chain
- `_messageBody` (bytes) the message body containing intent hashes and their corresponding claimants

<ins>Security:</ins> This method is public but there are checks in place to ensure that it reverts unless msg.sender is the local hyperlane mailbox and \_sender is the destination chain's inbox. This method has direct write access to the provenIntents mapping and, therefore, gates access to the rewards for hyperproven intents.

## Storage Prover (Prover.sol)

### Events

<h4><ins>L1WorldStateProven</ins></h4>
<h5> emitted when L1 world state is proven</h5>

Attributes:

- `_blocknumber` (uint256) the block number corresponding to this L1 world state
- `_L1WorldStateRoot` (bytes32) the world state root at \_blockNumber

<h4><ins>L2WorldStateProven</ins></h4>
<h5> emitted when L2 world state is proven</h5>

Attributes:

- `_destinationChainID` (uint256) the chainID of the destination chain
- `_blocknumber` (uint256) the block number corresponding to this L2 world state
- `_L2WorldStateRoot` (bytes32) the world state root at \_blockNumber

<h4><ins>IntentProven</ins></h4>
<h5> emitted when an intent has been successfully proven</h5>

Attributes:

- `_hash` (bytes32) the hash of the intent
- `_claimant` (address) the address that can claim this intent's rewards

### Methods

<h4><ins>proveSettlementLayerState</ins></h4>
<h5> validates input L1 block state against the L1 oracle contract. This method does not need to be called per intent, but the L2 batch containing the intent must have been settled to L1 on or before this block.</h5>

Attributes:

- `rlpEncodedBlockData` (bytes) properly encoded L1 block data

<ins>Security:</ins> This method can be called by anyone. Inputting the correct block's data encoded as expected will result in its hash matching the blockhash found on the L1 oracle contract. This means that the world state root found in that block corresponds to the block on the oracle contract, and that it represents a valid state. Notably, only one block's data is present on the oracle contract at a time, so the input data must match that block specifically, or the method will revert.

<h4><ins>proveWorldStateBedrock</ins></h4>
<h5> Validates World state by ensuring that the passed in world state root corresponds to value in the L2 output oracle on the Settlement Layer.  We submit a `StorageProof` proving that the L2 Block is included in a batch that has been settled to L1 and an `AccountProof` proving that the `StorageProof` submitted is linked to a `WorldState` for the contract that the `StorageProof` is for.</h5>

For Optimism's BedRock release we submit an `outputRoot` storage proof created by concatenating

```solidity
output_root = kecakk256( version_byte || state_root || withdrawal_storage_root || latest_block_hash)
```

2. If you're not on an M1 Mac, skip to step 3. For Node < v15, `nvm` will need to be run in a Rosetta terminal since those versions are not supported by the M1 chip for installation. To do that, in the terminal simply run either:

If running bash:

```sh
arch -x86_64 bash
```

If running zsh:

```sh
arch -x86_64 zsh
```

More information about this can be found in [this thread](https://github.com/nvm-sh/nvm/issues/2350).

3. Install our Node version using the following command:

```sh
nvm install v18.20.3
```

4. Once the installation is complete you can use it by running:

```bash
nvm use v18.20.3
```

You should see it as the active Node version by running:

```bash
nvm ls
```

### Installation

1. Clone the repo

```bash
 git clone git@github.com:ecoinc/Cross-L2-Actions.git
```

2. Install and build using yarn

```bash
 yarn install
```

```bash
 yarn build
```

### Lint

```bash
yarn lint
```

### Testing

```bash
# tests
$ yarn  test

# test coverage
$ yarn coverage
```

### Deployment

Deploy using `deploy.ts` in the `scripts` directory. This script draws from the configs (found in the `config` directory) as well as a local .env file. See `.env.example`.

### End-To-End Testing

This section is under development. While the tests are not yet operational, the scripts are available in the `scripts` directory

## Contributing

1. Fork the Project
2. Create your Branch (`git checkout -b feature/AmazingFeature`)
3. Commit your Changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the Branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- LICENSE -->

## License

[MIT License](./LICENSE)

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- CONTACT -->

## Contact

Project Link: [https://github.com/ecoinc/Cross-L2-Actions](https://github.com/ecoinc/Cross-L2-Actions)

<p align="right">(<a href="#top">back to top</a>)</p>
