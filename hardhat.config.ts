import * as dotenv from 'dotenv'
import { HardhatUserConfig } from 'hardhat/config'
import '@nomicfoundation/hardhat-toolbox'
import '@nomicfoundation/hardhat-viem'
import '@openzeppelin/hardhat-upgrades'
import '@nomicfoundation/hardhat-chai-matchers'
import 'solidity-docgen'
dotenv.config()
const DEPLOYER_PRIVATE_KEY =
  process.env.DEPLOYER_PRIVATE_KEY || '0x' + '11'.repeat(32) // this is to avoid hardhat error
const ALCHEMY_API_KEY = process.env.ALCHEMY_API_KEY || ''

const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      {
        version: '0.8.27',
        settings: {
          viaIR: true,
          optimizer: {
            enabled: true,
          },
        },
      },
    ],
    settings: {
      metadata: {
        bytecodeHash: 'none',
      },
      outputSelection: {
        '*': {
          '*': ['metadata', 'storageLayout'],
        },
      },
    },
  },
  networks: {
    sepolia: {
      chainId: 11155111,
      url: `https://sepolia.g.alchemy.com/v2/${ALCHEMY_API_KEY}`,
      gasPrice: 500000000,
      accounts: [DEPLOYER_PRIVATE_KEY],
    },
    optimismSepolia: {
      chainId: 11155420,
      url: `https://opt-sepolia.g.alchemy.com/v2/${ALCHEMY_API_KEY}`,
      gasPrice: 500000000,
      accounts: [DEPLOYER_PRIVATE_KEY],
    },
    optimismSepoliaBlockscout: {
      chainId: 11155420,
      url: `https://opt-sepolia.g.alchemy.com/v2/${ALCHEMY_API_KEY}`,
      gasPrice: 500000000,
      accounts: [DEPLOYER_PRIVATE_KEY],
    },
    baseSepolia: {
      chainId: 84532,
      url: `https://base-sepolia.g.alchemy.com/v2/${ALCHEMY_API_KEY}`,
      accounts: [DEPLOYER_PRIVATE_KEY],
    },
    ecoTestnet: {
      chainId: 471923,
      url: `https://eco-testnet.rpc.caldera.xyz/http`,
      accounts: [DEPLOYER_PRIVATE_KEY],
    },
    helix: {
      chainId: 8921733,
      url: `https://helix-test.calderachain.xyz/http`,
      accounts: [DEPLOYER_PRIVATE_KEY],
    },
    arbitrumSepolia: {
      chainId: 421614,
      url: `https://arb-sepolia.g.alchemy.com/v2/${ALCHEMY_API_KEY}`,
      accounts: [DEPLOYER_PRIVATE_KEY],
    },
    mainnet: {
      chainId: 1,
      url: `https://eth-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}`,
      accounts: [DEPLOYER_PRIVATE_KEY],
    },
    optimism: {
      chainId: 10,
      url: `https://opt-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}`,
      gasPrice: 100000000,
      accounts: [DEPLOYER_PRIVATE_KEY],
    },
    optimismBlockScout: {
      chainId: 10,
      url: `https://opt-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}`,
      gasPrice: 100000000,
      accounts: [DEPLOYER_PRIVATE_KEY],
    },
    base: {
      chainId: 8453,
      url: `https://base-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}`,
      accounts: [DEPLOYER_PRIVATE_KEY],
    },
    arbitrum: {
      chainId: 42161,
      url: `https://arb-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}`,
      accounts: [DEPLOYER_PRIVATE_KEY],
    },
    mantle: {
      chainId: 5000,
      url: `https://mantle-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}`,
      accounts: [DEPLOYER_PRIVATE_KEY],
    },
    mantleSepolia: {
      chainId: 5003,
      url: `https://rpc.sepolia.mantle.xyz`,
      accounts: [DEPLOYER_PRIVATE_KEY],
    },
    polygon: {
      chainId: 137,
      url: `https://polygon-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}`,
      accounts: [DEPLOYER_PRIVATE_KEY],
    },
    polygonSepolia: {
      chainId: 80002,
      url: `https://polygon-amoy.g.alchemy.com/v2/${ALCHEMY_API_KEY}`,
      accounts: [DEPLOYER_PRIVATE_KEY],
    },
  },
  etherscan: {
    apiKey: {
      optimismSepolia: process.env.OPTIMISM_SCAN_API_KEY || '',
      optimismSepoliaBlockscout: process.env.OPTIMISM_BLOCKSCOUT_API_KEY || '',
      baseSepolia: process.env.BASE_SCAN_API_KEY || '',
      arbitrumSepolia: process.env.ARBSCAN_API_KEY || '',
      arbitrum: process.env.ARBSCAN_API_KEY || '',
      optimism: process.env.OPTIMISM_SCAN_API_KEY || '',
      optimismBlockscout: process.env.OPTIMISM_BLOCKSCOUT_API_KEY || '',
      optimisticEthereum: process.env.OPTIMISM_SCAN_API_KEY || '',
      base: process.env.BASE_SCAN_API_KEY || '',
      ecoTestnet: process.env.CALDERA_SCAN_API_KEY || '',
      helix: process.env.CALDERA_SCAN_API_KEY || '',
      mantle: process.env.MANTLE_SCAN_API_KEY || '',
      mantleSepolia: process.env.MANTLE_SCAN_API_KEY || '',
      polygon: process.env.POLYGON_SCAN_API_KEY || '',
      polygonSepolia: process.env.POLYGON_SCAN_API_KEY || '',
    },
    customChains: [
      {
        network: 'optimismSepolia',
        chainId: 11155420,
        urls: {
          apiURL: 'https://api-sepolia-optimism.etherscan.io/api',
          browserURL: 'https://sepolia-optimism.etherscan.io',
        },
      },
      {
        network: 'optimismSepoliaBlockscout',
        chainId: 11155420,
        urls: {
          apiURL: 'https://optimism-sepolia.blockscout.com/api',
          browserURL: 'https://optimism-sepolia.blockscout.com/',
        },
      },
      {
        network: 'ecoTestnet',
        chainId: 471923,
        urls: {
          apiURL: 'https://eco-testnet.explorer.caldera.xyz/api',
          browserURL: 'https://eco-testnet.explorer.caldera.xyz/',
        },
      },
      {
        network: 'helix',
        chainId: 8921733,
        urls: {
          apiURL: 'https://helix-test.calderaexplorer.xyz/api',
          browserURL: 'https://helix-test.calderaexplorer.xyz/',
        },
      },
      {
        network: 'mantle',
        chainId: 5000,
        urls: {
          apiURL: 'https://api.mantlescan.xyz/api',
          browserURL: 'https://mantlescan.xyz/',
        },
      },
      {
        network: 'mantleSepolia',
        chainId: 5003,
        urls: {
          apiURL: 'https://api-sepolia.mantlescan.xyz/api',
          browserURL: 'https://sepolia.mantlescan.xyz/',
        },
      },
      {
        network: 'arbitrum',
        chainId: 42161,
        urls: {
          apiURL: 'https://api.arbiscan.io/api',
          browserURL: 'https://arbiscan.io/',
        },
      },
      {
        network: 'arbitrumSepolia',
        chainId: 421614,
        urls: {
          apiURL: 'https://api-sepolia.arbiscan.io/api',
          browserURL: 'https://sepolia.arbiscan.io/',
        },
      },
      {
        network: 'polygon',
        chainId: 137,
        urls: {
          apiURL: 'https://api.polygonscan.com/api',
          browserURL: 'https://polygonscan.com/',
        },
      },
      {
        network: 'polygonSepolia',
        chainId: 80002,
        urls: {
          apiURL: 'https://api-amoy.polygonscan.com/api',
          browserURL: 'https://amoy.polygonscan.com/',
        },
      },
    ],
  },
  mocha: {
    timeout: 50000,
  },
  docgen: {
    outputDir: 'docs/solidity',
    templates: './templates',
    theme: 'markdown',
    // pages: 'single',
    // pages: 'items',
    pages: 'files',
    // exclude: ['governance/community'],
    collapseNewlines: true,
    pageExtension: '.md',
  },
  gasReporter: {
    enabled: !!process.env.ENABLE_GAS_REPORT,
    currency: 'USD',
    gasPrice: 100,
    outputFile: process.env.CI ? 'gas-report.txt' : undefined,
  },
}

export default config
