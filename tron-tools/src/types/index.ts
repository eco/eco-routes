export interface TronNetwork {
  name: string;
  chainId: string;
  rpcUrl: string;
  apiKey?: string;
  isMainnet: boolean;
  fallbackUrls?: string[];
}

export interface TronAccount {
  address: string;
  privateKey: string;
  base58Address: string;
  hexAddress: string;
}

export interface ResourceEstimate {
  energy: number;
  bandwidth: number;
  energyCostTRX: number;
  bandwidthCostTRX: number;
  totalCostTRX: number;
  confidence: number; // 0-1 confidence score
}

export interface TransactionConfig {
  feeLimit: number;
  from: string;
  to?: string;
  value?: number;
  data?: string;
  energy?: number;
  bandwidth?: number;
}

export interface DeploymentConfig {
  contractName: string;
  bytecode: string;
  abi: any[];
  constructorParams?: any[];
  feeLimit?: number;
  energy?: number;
  salt?: string; // for CREATE2 deployments
}

export interface TronZapRentalRequest {
  resourceType: 'energy' | 'bandwidth';
  amount: number;
  duration: number; // in hours
  targetAddress: string;
}

export interface TronZapRentalResponse {
  transactionId: string;
  cost: number;
  expiresAt: Date;
  success: boolean;
  error?: string;
}

export interface NetworkHealth {
  blockHeight: number;
  peersConnected: number;
  avgBlockTime: number;
  isHealthy: boolean;
  lastChecked: Date;
  responseTime: number;
}

export interface ContractDeploymentResult {
  contractAddress: string;
  transactionId: string;
  blockNumber: number;
  gasUsed: number;
  energyUsed: number;
  bandwidthUsed: number;
  actualCost: number;
  deploymentTime: Date;
}

export interface TransactionResult {
  txId: string;
  blockNumber: number;
  confirmed: boolean;
  energyUsed: number;
  bandwidthUsed: number;
  fee: number;
  result?: any;
  error?: string;
}