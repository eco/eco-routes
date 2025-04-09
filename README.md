<div id="top"></div>
<h1>Eco Routes</h1>

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

- [Intent Publishing](#intent-publishing)
- [Intent Funding](#intent-funding)
- [Intent Fulfillment](#intent-fulfillment)
- [Intent Proving](#intent-proving)
- [Reward Settlement](#intent-reward-settlement)

We identify three main user profiles:

- `Users`: Individuals who want to transact across different L2s.
- `Solvers`: Individuals interested in performing transactions on behalf of others for a fee.
- `Provers`: Individuals interested in proving on the source chain that an intent was fulfilled on the destination chain.

### How it works

A `User` wants to initiate a cross-chain transaction by creating an intent. Put simply, an intent represents a `User`'s end goals on the destination chain. It contains the calls they'd want to make, those calls' corresponding addresses, the resources a `Solver` would need to perform those calls, and the rewards the `User` would be willing to pay a `Solver` to execute this call on their behalf, along with other metadata. A `User` can publish this directly on our system or otherwise disseminate that information to a `Solver`. A `User` also must fund this intent - escrow the reward tokens corresponding to the intent. A `Solver`, upon seeing this intent and determining based on the inputs and outputs that it is profitable and ensuring that the `User` has funded the intent, marshalls the required resources and fulfills the intent transaction on the destination chain that corresponds to the user's intent, storing the fulfilled intent's hash on the destination chain. A `Prover` - perhaps the `Solver` themselves or a service they subscribe to - sees this fulfillment transaction and performs a proof that the hash of the fulfilled transaction on the destination chain matches that of the intent on the source chain. After the intent is marked as proven,the `Solver` can withdraw their reward.

We also implement ERC-7683 and enable the creation and fulfillment of intents in our system via that interface.

## Components

Within the following sections, the terms 'source chain' and 'destination chain' will be relative to any given intent. Each supported chain will have its own `IntentSource`, `Inbox` and a set of `Prover`s.

### Intent Publishing

The `IntentSource` contract provides functionality for publishing intents. Intents can be published in this way on any chain, regardless of where the input and output tokens live. An intent need not be published via the `IntentSource` at all - a user can disseminate intent information directly to solvers if they so choose.

### Intent Funding

A funded intent effectively has its reward tokens stored in a `Vault`. An intent can be funded on the `IntentSource` contract during publishing, after the fact via permit2 signatures, or a user may directly transfer tokens to the `Vault`.

### Intent Fulfillment

Intent fulfillment happens on the `Inbox`, which lives on the destination chain. Solvers approve the `Inbox` to pull the required tokens and then call upon the `Inbox` to fulfill the intent. Fulfillment may also trigger some proving-related post-processing, for example relaying a message indicating fulfillment back to the source chain.

### Intent Proving

Intent proving lives on `Prover` contracts, which are on the source chain. `Prover`s are effectively the source chain's oracle for whether an intent was fulfilled on the destination chain. A User chooses ahead of time which `Prover` their intent will query for fulfillment status. There are currently two types of provers: StorageProvers (`Prover.sol`), which use storage proofs to verify the fulfillment of an intent, and HyperProvers(`HyperProver.sol`), which utilize a <a href="https://hyperlane.xyz/" target="_blank">Hyperlane</a> bridge in verifying intent fulfillment.

### Intent Reward Settlement

Intent reward settlement occurs on the `IntentSource` on the destination chain. The withdrawal flow checks that an intent has been fulfilled on the `Prover` and then transfers reward tokens to the address provided by the solver. In the event that an intent was not fulfilled before the deadline, the user can trigger a refund of their reward tokens through the same flow. Other edge cases like overfunding an intent are also handled by the `IntentSource`.

### ERC-7683

Eco's implementation of ERC-7683 allows users to create and fulfill intents on Eco's ecosystem through ERC-7683's rails. `EcoERC7683OriginSettler` is the entrypoint to our system, while `EcoERC7683DestinationSettler` is where they are fulfilled. While `EcoERC7683OriginSettler` is a separate contract, `EcoERC7683DestinationSettler` is an abstract contract inherited by Eco's `Inbox`.

## Contract Addresses

| **Mainnet Chains** | IntentSource                               | Inbox                                      | StorageProver                              | HyperProver                                |
| :----------------- | :----------------------------------------- | :----------------------------------------- | :----------------------------------------- | :----------------------------------------- |
| Optimism           | 0xa6B316239015DFceAC5bc9c19092A9B6f59ed905 | 0xfB853672cE99D9ff0a7DE444bEE1FB2C212D65c0 | 0xE00c8FD8b50Fed6b652A5cC66c1d0C090fde037f | 0xAfD3029f582455ed0f06F22AcD916B27bc9b3a55 |
| Base               | 0xa6B316239015DFceAC5bc9c19092A9B6f59ed905 | 0xfB853672cE99D9ff0a7DE444bEE1FB2C212D65c0 | 0xE00c8FD8b50Fed6b652A5cC66c1d0C090fde037f | 0xc8E7060Cd790A030164aCbE2Bd125A6c06C06f69 |
| Mantle             | 0xa6B316239015DFceAC5bc9c19092A9B6f59ed905 | 0xfB853672cE99D9ff0a7DE444bEE1FB2C212D65c0 | 0xE00c8FD8b50Fed6b652A5cC66c1d0C090fde037f | 0xaf034DD5eaeBB49Dc476402C6650e85Cc22a0f1a |
| Arbitrum           | 0xa6B316239015DFceAC5bc9c19092A9B6f59ed905 | 0xfB853672cE99D9ff0a7DE444bEE1FB2C212D65c0 | WIP                                        | 0xB1017F865c6306319C65266158979278F7f50118 |

| **Testnet Chains** | IntentSource                               | Inbox                                      | StorageProver                              | HyperProver                                |
| :----------------- | :----------------------------------------- | :----------------------------------------- | :----------------------------------------- | :----------------------------------------- |
| OptimismSepolia    | 0x734a3d5a8D691d9b911674E682De5f06517c79ec | 0xB73fD43C293b250Cb354c4631292A318248FB33E | 0xDcbe9977821a2565a153b5c3622a999F7BeDcdD9 | 0x39cBD6e1C0E6a30dF33428a54Ac3940cF33B23D6 |
| BaseSepolia        | 0x734a3d5a8D691d9b911674E682De5f06517c79ec | 0xB73fD43C293b250Cb354c4631292A318248FB33E | 0xDcbe9977821a2565a153b5c3622a999F7BeDcdD9 | 0x39cBD6e1C0E6a30dF33428a54Ac3940cF33B23D6 |
| MantleSepolia      | 0x734a3d5a8D691d9b911674E682De5f06517c79ec | 0xB73fD43C293b250Cb354c4631292A318248FB33E | 0xDcbe9977821a2565a153b5c3622a999F7BeDcdD9 | WIP                                        |
| ArbitrumSepolia    | 0x734a3d5a8D691d9b911674E682De5f06517c79ec | 0xB73fD43C293b250Cb354c4631292A318248FB33E | WIP                                        | 0x6D6556B3a199cbbdcFE4E7Ba3FA6330D066A31a9 |

## Future Work

Fully-operational end-to-end tests are currently under development. We are also working on services for streamlining and batching prover and solver functionalities. Additionally, we intend to build out support for additional chains.

## Usage

To get a local copy up and running follow these simple steps.

### Prerequisites

Running this project locally requires the following:

- [NodeJS v22.10.0](https://nodejs.org/) - using nvm (instructions below)
- [Yarn v1.22.19](https://www.npmjs.com/package/yarn/v/1.22.19)

It is recommended to use `nvm` to install Node. This is a Node version manager so your computer can easily handle multiple versions of Node:

1. Install `nvm` using the following command in your terminal:

```sh
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.5/install.sh | bash
```

2. Install our Node version using the following command:

```sh
nvm install v22.10.0
```

3. Once the installation is complete you can use it by running:

```bash
nvm use v22.10.0
```

You should see it as the active Node version by running:

```bash
nvm ls
```

### Installation

1. Clone the repo

```bash
 git clone git@github.com:the-eco-foundation/eco-routes.git
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
$ yarn test

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

Project Link: [https://github.com/eco/eco-routes](https://github.com/eco/eco-routes)

<p align="right">(<a href="#top">back to top</a>)</p>