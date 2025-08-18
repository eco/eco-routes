import { TronNetwork } from '../types';

export const TRON_NETWORKS: Record<string, TronNetwork> = {
  mainnet: {
    name: 'Tron Mainnet',
    chainId: '728126428', // 0x2B6653DC
    rpcUrl: process.env.TRON_MAINNET_RPC_URL || 'https://api.trongrid.io',
    apiKey: process.env.TRONGRID_API_KEY,
    isMainnet: true,
    fallbackUrls: [
      process.env.TRON_FALLBACK_RPC_1 || 'https://api.tron.network',
      'https://tron-rpc.publicnode.com'
    ]
  },
  testnet: {
    name: 'Tron Testnet (Shasta)',
    chainId: '2494104990', // 0x94A9059E  
    rpcUrl: process.env.TRON_TESTNET_RPC_URL || 'https://api.shasta.trongrid.io',
    apiKey: process.env.TRONGRID_API_KEY,
    isMainnet: false,
    fallbackUrls: [
      process.env.TRON_FALLBACK_RPC_2 || 'https://api.nileex.io',
      'https://nile.trongrid.io'
    ]
  }
};

export const DEFAULT_CONFIG = {
  energyLimit: parseInt(process.env.DEFAULT_ENERGY_LIMIT || '100000'),
  bandwidthLimit: parseInt(process.env.DEFAULT_BANDWIDTH_LIMIT || '1000'),
  energyPriceSun: parseInt(process.env.ENERGY_PRICE_SUN || '420'),
  deployFeeLimit: parseInt(process.env.CONTRACT_DEPLOY_FEE_LIMIT || '1000000000'),
  maxRetries: parseInt(process.env.MAX_RETRY_ATTEMPTS || '3'),
  retryDelay: parseInt(process.env.RETRY_DELAY_MS || '1000')
};

export const TRONZAP_CONFIG = {
  apiUrl: process.env.TRONZAP_API_URL || 'https://api.tronzap.com',
  apiKey: process.env.TRONZAP_API_KEY
};