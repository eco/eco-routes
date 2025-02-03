<div id="top"></div>
<h1>Eco Routes</h1>

</div>

- [Abstract](#abstract)
- [Components](#components)
- [Contract Addresses](#contract-addresses)
- [Future Work](#future-work)
- [Usage](#usage)
  - [Installation](#installation)
  - [Testing](#testing)
  - [Deployment](#deployment)
  - [End-to-End Testing](#end-to-end-testing)
- [Contributing](#contributing)
- [License](#license)
- [Contact](#contact)

## Abstract

An intents-driven, permissionless, trust-neutral protocol for facilitating the creation, incentivized execution, and proof of crosschain transactions.

- [Intent Creation / Settlement](#intent-creation--settlement)
- [Intent Fulfillment / Execution](#intent-fulfillment--execution)
- [Intent Proving](#intent-proving)

We identify three main user profiles:

- `Users`: Individuals who want to transact across chains.
- `Solvers`: Individuals interested in performing transactions on behalf of others for a fee.
- `Provers`: Individuals interested in proving on the source chain that an intent was fulfilled on the destination chain.

### How it works

A `User` (or someone on the `User`'s behalf) initiates a cross-chain transaction by creating an intent. Put simply, an intent represents a `User`'s end goals on the destination chain. It contains the calls they'd want to make, those calls' corresponding addresses, and the price they'd be willing to pay someone to execute this call on their behalf, along with other metadata. Seeing this intent and being enticed by the fee they'd receive, a `Solver` creates and executes a fulfill transaction on the destination chain that corresponds to the user's intent, storing the fulfilled intent's hash on the destination chain. A `Prover` - perhaps the `Solver` themselves or a service they subscribe to - attests to the fact that the hash of the fulfilled transaction on the destination chain matches that of the intent on the source chain. After the intent proven, the `Solver` can withdraw their reward.


## Components

Within the following sections, the terms `source chain` and `destination chain` will be relative to any given intent. Each supported chain will have its own `IntentSource`, `Inbox`, and `Prover`s.

## Intent Funding

### Intent Publishing / Settlement

Intent creation and settlement processes both exist on the `IntentSource` on the source chain. Both `Users` and `Solvers` interact with this contract, Users to create intents and `Solvers` to claim their reward after fulfillment has been proven.

### Intent Fulfillment / Execution

Intent fulfillment lives on the `Inbox`, which lives on the destination chain. `Solvers` interact with this contract to solve `User`s' intents. At time of launch solving may be private, restricted only to a whitelisted set of solver addresses while we live test the system, but it will soon become possible for anyone to fulfill orders.

### Intent Proving

Intent proving lives on the `Prover` and `HyperProver` contracts, which exist on the source chain. `Provers` are the parties that should be interacting with prover contracts, but the `IntentSource` does read state from it. There are currently two types of provers: StorageProvers (`Prover.sol`), which use storage proofs to verify the fulfillment of an intent, and HyperProvers(`HyperProver.sol`), which utilize a <a href="https://hyperlane.xyz/" target="_blank">Hyperlane</a> bridge in verifying intent fulfillment.

**See [contracts](/contracts) for a detailed API documentation**

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

- [NodeJS v18.20.3](https://nodejs.org/en/blog/release/v18.20.3) - using nvm (instructions below)
- [Yarn v1.22.19](https://www.npmjs.com/package/yarn/v/1.22.19)

It is recommended to use `nvm` to install Node. This is a Node version manager so your computer can easily handle multiple versions of Node:

1. Install `nvm` using the following command in your terminal:

```sh
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.5/install.sh | bash
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

Project Link: [https://github.com/eco/eco-routes](https://github.com/eco/eco-routes)

<p align="right">(<a href="#top">back to top</a>)</p>
