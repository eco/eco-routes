/* eslint-disable no-magic-numbers */
import { ethers } from 'hardhat'

const networkIds: any = {
  noChain: 0,
  sepolia: 11155111,
  optimismSepolia: 11155420,
  baseSepolia: 84532,
  ecoTestnet: 471923,
  hardhat: 31337,
  // arbitrumSepolia: 421614,
  0: 'noChain',
  11155111: 'sepolia',
  11155420: 'optimismSepolia',
  84532: 'baseSepolia',
  471923: 'ecoTestnet',
  // 421614: 'arbitrumSepolia',
  31337: 'hardhat',
}

const actors: any = {
  deployer: '0x6cae25455BF5fCF19cE737Ad50Ee3BC481fCDdD4',
  intentCreator: '0x448729e46C442B55C43218c6DB91c4633D36dFC0',
  solver: '0x7b65Dd8dad147C5DBa896A7c062a477a11a5Ed5E',
  claimant: '0xB4e2a27ed497E2D1aD0C8fB3a47803c934457C58',
  prover: '0x923d4fDfD0Fb231FDA7A71545953Acca41123652',
  recipient: '0xC0Bc9bA69aCD4806c4c48dD6FdFC1677212503e9',
}

const provingMechanisms: any = {
  Self: 0, // Destination is Self
  Settlement: 1, // Source Chain is an L2, Destination is A L1 Settlement Chain
  SettlementL3: 2, // Source Chain is an L3, Destination is a L2 Settlement Chain
  Bedrock: 3, // Source Chain is an L2, Destination Chain is an L2 using Bedrock
  Cannon: 4, // Source Chain is an L2, Destination Chain is an L2 using Cannon
  HyperProver: 5, // Source Chain is an L2 Destination Chain is an L2 using HyperProver
  ArbitrumNitro: 6, // Source Chain is an L2 Destination Chain is an L2 using Arbitrum Nitro
  0: 'Self',
  1: 'Settlement',
  2: 'SettlementL3',
  3: 'Bedrock',
  4: 'Cannon',
  5: 'HyperProver',
  6: 'ArbitrumNitro',
}

const settlementTypes: any = {
  Finalized: 0,
  Posted: 1,
  Confirmed: 2,
  0: 'Finalized', // Finalized on Settlement Chain
  1: 'Posted', // Posted to Settlement Chain
  2: 'Confirmed', // Confirmed Locally
}

// Note intents currently being used are for USDC with a common set of actors
// the other data coming from the network
// Here we store a minimal set of addtional fieds
const intent: any = {
  rewardAmounts: [1001],
  targetAmounts: [1000],
  duration: 3600,
}

const networks: any = {
  sepolia: {
    network: networkIds[11155111],
    chainId: networkIds.sepolia,
    alchemyNetwork: 'sepolia',
    proving: {
      mechanism: provingMechanisms.Settlement,
      l1BlockAddress: '0x0000000000000000000000000000000000000000',
      l2l1MessageParserAddress: '0x0000000000000000000000000000000000000000',
      outputRootVersionNumber: 0,
      l1BlockSlotNumber: 2,
      settlementChain: {
        network: 'sepolia',
        id: networkIds.sepolia,
        contract: '0x0000000000000000000000000000000000000000',
      },
      provingTimeSeconds: 36,
      finalityDelaySeconds: 0,
    },
    // The following settlement contracts are useful for event listening
    settlementContracts: {
      optimismSepolia: '0x05F9613aDB30026FFd634f38e5C4dFd30a197Fa1', // optimismSepolia Dispute Game Factory
      baseSepolia: '0xd6E6dBf4F7EA0ac412fD8b65ED297e64BB7a06E1', // baseSepolia Dispute Game Factory
      // arbitrumSepolia: '0xd80810638dbDF9081b72C1B33c65375e807281C8', // arbitrumSepolia Rollup Admin Contract
    },
  },
  optimismSepolia: {
    network: networkIds[11155420],
    chainId: networkIds.optimismSepolia,
    alchemyNetwork: 'optimism-sepolia',
    sourceChains: ['baseSepolia', 'ecoTestnet'],
    proverContract: {
      address: '0xed84b971657F5B182cc8Bb521EB09C959C215dCC',
      deploymentBlock: 16795390n, // '0x10046Fe'
    },
    intentSource: {
      address: '0x65E1BB1752AE3b6EA7E1c1531fb565Aa4724BFBB',
      deploymentBlock: 16795394n, // '0x1004702
      minimumDuration: 1000,
      counter: 0,
    },
    inbox: {
      address: '0x64Fff610959159Df6bad6402017BfD73Fd233380',
      deploymentBlock: 18354796n, // '0x118126c
    },
    hyperProverContractAddress: '0xfc91Ac2e87Cc661B674DAcF0fB443a5bA5bcD0a3',
    proving: {
      mechanism: provingMechanisms.Cannon,
      l1BlockAddress: '0x4200000000000000000000000000000000000015',
      l2l1MessageParserAddress: '0x4200000000000000000000000000000000000016',
      outputRootVersionNumber: 0,
      l1BlockSlotNumber: 2,
      settlementChain: {
        network: 'sepolia',
        id: networkIds.sepolia,
        contract: '0x05F9613aDB30026FFd634f38e5C4dFd30a197Fa1',
      },
      provingTimeSeconds: 302400,
      finalityDelaySeconds: 0,
    },
    usdcAddress: '0x5fd84259d66Cd46123540766Be93DFE6D43130D7',
    hyperlaneMailboxAddress: '0x6966b0E55883d49BFB24539356a2f8A673E02039',
  },
  baseSepolia: {
    network: networkIds[84532],
    chainId: networkIds.baseSepolia,
    alchemyNetwork: 'base-sepolia',
    sourceChains: ['optimismSepolia', 'ecoTestnet'],
    proverContract: {
      address: '0x5900FF69924Bce8Bb8Cb0718afC23eBE5131315B',
      deploymentBlock: 14812482n, // '0xe20542',
    },
    intentSource: {
      address: '0x2Abddc1F15cCB2E71264a7C32E46873e11302D5b',
      deploymentBlock: 14812485n, // '0xe20545',
      minimumDuration: 1000,
      counter: 0,
    },
    inbox: {
      address: '0x9f73f5b9dA2eC4165638851664D3A9d9302BeBEc',
      deploymentBlock: 14812488n, // '0xe20548',
    },
    hyperProverContractAddress: '0xe3aCb913834Fd062E2B4517f971e6469543434ce',
    proving: {
      mechanism: provingMechanisms.Cannon,
      l1BlockAddress: '0x4200000000000000000000000000000000000015',
      l2l1MessageParserAddress: '0x4200000000000000000000000000000000000016',
      outputRootVersionNumber: 0,
      l1BlockSlotNumber: 2,
      settlementChain: {
        network: 'sepolia',
        id: networkIds.sepolia,
        // Dispute Game Factory address
        contract: '0xd6E6dBf4F7EA0ac412fD8b65ED297e64BB7a06E1',
        // Old L2 Output Oracle Address
        // contract: '0x84457ca9D0163FbC4bbfe4Dfbb20ba46e48DF254',
      },
      provingTimeSeconds: 302400,
      finalityDelaySeconds: 604800,
    },
    // The following settlement contracts are useful for event listening
    settlementContracts: {
      ecoTestnet: '0xb3EDAE5AB86f16242018c7cED4fBCabb3c784951', // ecoTestnet L2 Output Oracle
    },
    usdcAddress: '0x036CbD53842c5426634e7929541eC2318f3dCF7e',
    hyperlaneMailboxAddress: '0x6966b0E55883d49BFB24539356a2f8A673E02039',
  },
  ecoTestnet: {
    network: networkIds[471923],
    chainId: networkIds.ecoTestnet,
    alchemyNetwork: 'eco-testnet',
    sourceChains: ['baseSepolia', 'optimismSepolia'],
    rpcUrl: 'https://eco-testnet.rpc.caldera.xyz/http',
    settlementNetwork: 'baseSepolia',
    proverContract: {
      address: '0x5900FF69924Bce8Bb8Cb0718afC23eBE5131315B',
      deploymentBlock: '0x35dc32', // 3529778n
    },
    intentSource: {
      address: '0x2Abddc1F15cCB2E71264a7C32E46873e11302D5b',
      deploymentBlock: 3529780n, // '0x35dc34',
      minimumDuration: 1000,
      counter: 0,
    },
    inbox: {
      address: '0x9f73f5b9dA2eC4165638851664D3A9d9302BeBEc',
      deploymentBlock: 3529786n, // '0x35dc3a',
    },
    hyperProverContractAddress: '0xe3aCb913834Fd062E2B4517f971e6469543434ce',
    proving: {
      mechanism: provingMechanisms.Bedrock,
      l1BlockAddress: '0x4200000000000000000000000000000000000015',
      l2l1MessageParserAddress: '0x4200000000000000000000000000000000000016',
      l2OutputOracleSlotNumber: 3,
      outputRootVersionNumber: 0,
      l1BlockSlotNumber: 2,
      settlementChain: {
        network: 'baseSepolia',
        id: networkIds.baseSepolia,
        contract: '0xb3EDAE5AB86f16242018c7cED4fBCabb3c784951',
      },
      provingTimeSeconds: 3600,
      finalityDelaySeconds: 12,
    },
    usdcAddress: '0xCf4bc4786C11eB28169C7dd7B630d2Ea48856708',
    hyperlaneMailboxAddress: '0x6966b0E55883d49BFB24539356a2f8A673E02039',
  },
  arbitrumSepolia: {
    network: networkIds[421614],
    chainId: networkIds.arbitrumSepolia,
    alchemyNetwork: 'arbitrum-sepolia',
    settlementNetwork: 'sepolia',
    intentSourceAddress: '',
    proverContract: {
      address: '',
      deploymentBlock: '', // 0n
    },
    inboxAddress: '',
    intentSource: {
      minimumDuration: 1000,
      counter: 0,
    },
    proving: {
      mechanism: provingMechanisms.HyperProver,
      provingTimeSeconds: 604800,
      finalityDelaySeconds: 0,
    },
    usdcAddress: '0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d',
  },
}

const deploymentConfigs = {
  sepoliaSettlement: {
    chainConfigurationKey: {
      chainId: networkIds.sepolia,
      provingMechanism: provingMechanisms.Settlement, // provingMechanism
    },
    chainConfiguration: {
      exists: true,
      settlementChainId: networks.sepolia.proving.settlementChain.id, // settlementChainId
      settlementContract: networks.sepolia.proving.settlementChain.contract, // settlementContract
      blockhashOracle: ethers.ZeroAddress, // blockhashOracle
      outputRootVersionNumber: networks.sepolia.proving.outputRootVersionNumber, // outputRootVersionNumber
      provingTimeSeconds: networks.sepolia.proving.provingTimeSeconds,
      finalityDelaySeconds: networks.sepolia.proving.finalityDelaySeconds,
    },
  },
  sepoliaSettlementL3: {
    chainConfigurationKey: {
      chainId: networkIds.sepolia,
      provingMechanism: provingMechanisms.SettlementL3, // provingMechanism
    },
    chainConfiguration: {
      exists: true,
      settlementChainId: networks.sepolia.proving.settlementChain.id, // settlementChainId
      settlementContract: networks.sepolia.proving.settlementChain.contract, // settlementContract
      blockhashOracle: ethers.ZeroAddress, // blockhashOracle
      outputRootVersionNumber: networks.sepolia.proving.outputRootVersionNumber, // outputRootVersionNumber
      provingTimeSeconds: networks.sepolia.proving.provingTimeSeconds,
      finalityDelaySeconds: networks.sepolia.proving.finalityDelaySeconds,
    },
  },
  baseSepoliaSettlement: {
    chainConfigurationKey: {
      chainId: networkIds.baseSepolia,
      provingMechanism: provingMechanisms.Settlement, // provingMechanism
    },
    chainConfiguration: {
      exists: true,
      settlementChainId: networks.baseSepolia.proving.settlementChain.id, // settlementChainId
      settlementContract: networks.baseSepolia.proving.settlementChain.contract, // settlementContract
      blockhashOracle: ethers.ZeroAddress, // blockhashOracle
      outputRootVersionNumber:
        networks.baseSepolia.proving.outputRootVersionNumber, // outputRootVersionNumber
      provingTimeSeconds: networks.baseSepolia.proving.provingTimeSeconds,
      finalityDelaySeconds: networks.baseSepolia.proving.finalityDelaySeconds,
    },
  },
  baseSepoliaSelf: {
    chainConfigurationKey: {
      chainId: networkIds.baseSepolia,
      provingMechanism: provingMechanisms.Self, // provingMechanism
    },
    chainConfiguration: {
      exists: true,
      settlementChainId: networks.baseSepolia.proving.settlementChain.id, // settlementChainId
      settlementContract: networks.baseSepolia.proving.settlementChain.contract, // settlementContract
      blockhashOracle: ethers.ZeroAddress, // blockhashOracle
      outputRootVersionNumber:
        networks.baseSepolia.proving.outputRootVersionNumber, // outputRootVersionNumber
      provingTimeSeconds: networks.baseSepolia.proving.provingTimeSeconds,
      finalityDelaySeconds: networks.baseSepolia.proving.finalityDelaySeconds,
    },
  },
  baseSepoliaCannon: {
    chainConfigurationKey: {
      chainId: networkIds.baseSepolia,
      provingMechanism: provingMechanisms.Cannon, // provingMechanism
    },
    chainConfiguration: {
      exists: true,
      settlementChainId: networks.baseSepolia.proving.settlementChain.id, // settlementChainId
      settlementContract: networks.baseSepolia.proving.settlementChain.contract, // settlementContract
      blockhashOracle: ethers.ZeroAddress, // blockhashOracle
      outputRootVersionNumber:
        networks.baseSepolia.proving.outputRootVersionNumber, // outputRootVersionNumber
      provingTimeSeconds: networks.baseSepolia.proving.provingTimeSeconds,
      finalityDelaySeconds: networks.baseSepolia.proving.finalityDelaySeconds,
    },
  },
  optimismSepoliaCannon: {
    chainConfigurationKey: {
      chainId: networkIds.optimismSepolia,
      provingMechanism: provingMechanisms.Cannon, // provingMechanism
    },
    chainConfiguration: {
      exists: true,
      settlementChainId: networks.optimismSepolia.proving.settlementChain.id,
      settlementContract:
        networks.optimismSepolia.proving.settlementChain.contract,
      blockhashOracle: ethers.ZeroAddress, // blockhashOracle
      outputRootVersionNumber:
        networks.optimismSepolia.proving.outputRootVersionNumber,
      provingTimeSeconds: networks.optimismSepolia.proving.provingTimeSeconds,
      finalityDelaySeconds:
        networks.optimismSepolia.proving.finalityDelaySeconds,
    },
  },
  ecoTestnetBedrock: {
    chainConfigurationKey: {
      chainId: networkIds.ecoTestnet,
      provingMechanism: provingMechanisms.Bedrock, // provingMechanism
    },
    chainConfiguration: {
      exists: true,
      settlementChainId: networks.ecoTestnet.proving.settlementChain.id,
      settlementContract: networks.ecoTestnet.proving.settlementChain.contract,
      blockhashOracle: ethers.ZeroAddress, // blockhashOracle
      outputRootVersionNumber:
        networks.ecoTestnet.proving.outputRootVersionNumber,
      provingTimeSeconds: networks.ecoTestnet.proving.provingTimeSeconds,
      finalityDelaySeconds: networks.ecoTestnet.proving.finalityDelaySeconds,
    },
  },
  hardhatSelf: {
    chainConfigurationKey: {
      chainId: networkIds.hardhat,
      provingMechanism: provingMechanisms.Self, // provingMechanism
    },
    chainConfiguration: {
      exists: true,
      settlementChainId: networks.baseSepolia.proving.settlementChain.id, // settlementChainId
      settlementContract: networks.baseSepolia.proving.settlementChain.contract, // settlementContract
      blockhashOracle: ethers.ZeroAddress, // blockhashOracle
      outputRootVersionNumber:
        networks.baseSepolia.proving.outputRootVersionNumber, // outputRootVersionNumber
      provingTimeSeconds: networks.baseSepolia.proving.provingTimeSeconds,
      finalityDelaySeconds: networks.baseSepolia.proving.finalityDelaySeconds,
    },
  },
  hardhatBedrock: {
    chainConfigurationKey: {
      chainId: networkIds.hardhat,
      provingMechanism: provingMechanisms.Bedrock, // provingMechanism
    },
    chainConfiguration: {
      exists: true,
      settlementChainId: networks.ecoTestnet.proving.settlementChain.id,
      settlementContract: networks.ecoTestnet.proving.settlementChain.contract,
      blockhashOracle: ethers.ZeroAddress, // blockhashOracle
      outputRootVersionNumber:
        networks.ecoTestnet.proving.outputRootVersionNumber,
      provingTimeSeconds: networks.ecoTestnet.proving.provingTimeSeconds,
      finalityDelaySeconds: networks.ecoTestnet.proving.finalityDelaySeconds,
    },
  },
  hardhatCannon: {
    chainConfigurationKey: {
      chainId: networkIds.hardhat,
      provingMechanism: provingMechanisms.Cannon, // provingMechanism
    },
    chainConfiguration: {
      exists: true,
      settlementChainId: networks.baseSepolia.proving.settlementChain.id, // settlementChainId
      settlementContract: networks.baseSepolia.proving.settlementChain.contract, // settlementContract
      blockhashOracle: ethers.ZeroAddress, // blockhashOracle
      outputRootVersionNumber:
        networks.baseSepolia.proving.outputRootVersionNumber, // outputRootVersionNumber
      provingTimeSeconds: networks.baseSepolia.proving.provingTimeSeconds,
      finalityDelaySeconds: networks.baseSepolia.proving.finalityDelaySeconds,
    },
  },
}

const deploymentChainConfigs = {
  unitTests: [],
  selfStateTests: [deploymentConfigs.hardhatSelf],
  endToEndTests: [
    deploymentConfigs.sepoliaSettlement,
    deploymentConfigs.baseSepoliaCannon,
    deploymentConfigs.ecoTestnetBedrock,
    deploymentConfigs.hardhatCannon,
  ],
  l3SettlementTests: [
    deploymentConfigs.sepoliaSettlementL3,
    deploymentConfigs.baseSepoliaSettlement,
    deploymentConfigs.optimismSepoliaCannon,
    deploymentConfigs.ecoTestnetBedrock,
    deploymentConfigs.hardhatBedrock,
  ],
}

export {
  networkIds,
  actors,
  provingMechanisms,
  settlementTypes,
  intent,
  networks,
  deploymentConfigs,
  deploymentChainConfigs,
}
