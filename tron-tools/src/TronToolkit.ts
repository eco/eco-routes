import * as dotenv from 'dotenv';
import { NetworkManager } from './network/NetworkManager';
import { AccountManager } from './account/AccountManager';
import { ResourcePredictor } from './prediction/ResourcePredictor';
import { TronZapClient } from './rental/TronZapClient';
import { TransactionManager } from './transaction/TransactionManager';
import { ContractDeployer } from './deployment/ContractDeployer';
import { TronAccount, DeploymentConfig, TransactionConfig, ResourceEstimate } from './types';
import { logger, LogLevel } from './utils/logger';

// Load environment variables
dotenv.config();

export interface TronToolkitConfig {
  network?: 'mainnet' | 'testnet';
  privateKey?: string;
  logLevel?: LogLevel;
  tronZapApiKey?: string;
}

export class TronToolkit {
  private networkManager: NetworkManager;
  private accountManager: AccountManager;
  private resourcePredictor: ResourcePredictor;
  private tronZapClient?: TronZapClient;
  private transactionManager: TransactionManager;
  private contractDeployer: ContractDeployer;

  constructor(config: TronToolkitConfig = {}) {
    // Set log level
    if (config.logLevel !== undefined) {
      logger.setLogLevel(config.logLevel);
    }

    logger.info('Initializing Tron Toolkit...');

    // Initialize network manager
    this.networkManager = new NetworkManager(config.network || 'testnet');
    const tronWeb = this.networkManager.getTronWeb();

    // Initialize account manager
    this.accountManager = new AccountManager(tronWeb);

    // Set private key if provided
    if (config.privateKey) {
      this.accountManager.setPrivateKey(config.privateKey);
    } else if (process.env.TRON_PRIVATE_KEY) {
      this.accountManager.setPrivateKey(process.env.TRON_PRIVATE_KEY);
    }

    // Initialize resource predictor
    this.resourcePredictor = new ResourcePredictor(tronWeb);

    // Initialize TronZap client if API key is available
    try {
      this.tronZapClient = new TronZapClient(
        config.tronZapApiKey || process.env.TRONZAP_API_KEY
      );
      logger.info('TronZap client initialized');
    } catch (error) {
      logger.warn('TronZap client not available:', error);
    }

    // Initialize transaction manager
    this.transactionManager = new TransactionManager(tronWeb);

    // Initialize contract deployer
    this.contractDeployer = new ContractDeployer(
      tronWeb,
      this.transactionManager,
      this.resourcePredictor,
      this.accountManager,
      this.tronZapClient
    );

    logger.info('Tron Toolkit initialized successfully');
  }

  // Network Management
  async switchNetwork(network: 'mainnet' | 'testnet'): Promise<void> {
    await this.networkManager.switchNetwork(network);
    logger.info(`Switched to ${network}`);
  }

  getCurrentNetwork() {
    return this.networkManager.getCurrentNetwork();
  }

  isMainnet(): boolean {
    return this.networkManager.isMainnet();
  }

  async getNetworkHealth() {
    return this.networkManager.checkNetworkHealth();
  }

  async getBlockHeight(): Promise<number> {
    return this.networkManager.getBlockHeight();
  }

  // Account Management
  createAccount(): TronAccount {
    return this.accountManager.createAccount();
  }

  importAccount(privateKey: string): TronAccount {
    return this.accountManager.importAccount(privateKey);
  }

  setPrivateKey(privateKey: string): void {
    this.accountManager.setPrivateKey(privateKey);
  }

  getCurrentAddress(): string {
    return this.accountManager.getCurrentAddress();
  }

  isValidAddress(address: string): boolean {
    return this.accountManager.isValidAddress(address);
  }

  convertAddress(address: string) {
    return this.accountManager.convertAddress(address);
  }

  async getBalance(address?: string): Promise<number> {
    return this.accountManager.getBalance(address);
  }

  async getAccountResources(address?: string) {
    return this.accountManager.getAccountResources(address);
  }

  async getAccountInfo(address?: string) {
    return this.accountManager.getAccountInfo(address);
  }

  // Resource Prediction
  async predictTransaction(
    to: string,
    data?: string,
    value?: number,
    operationType?: 'transfer' | 'trc20Transfer' | 'contractCall' | 'contractDeploy'
  ): Promise<ResourceEstimate> {
    return this.resourcePredictor.predictTransaction(to, data, value, operationType);
  }

  async predictContractDeployment(
    bytecode: string,
    constructorParams?: any[],
    constructorAbi?: any[]
  ): Promise<ResourceEstimate> {
    return this.resourcePredictor.predictContractDeployment(bytecode, constructorParams, constructorAbi);
  }

  // Resource Rental (TronZap)
  async getRentalPrices() {
    if (!this.tronZapClient) {
      throw new Error('TronZap client not available');
    }
    return this.tronZapClient.getRentalPrices();
  }

  async rentEnergy(amount: number, targetAddress: string, durationHours: number = 24) {
    if (!this.tronZapClient) {
      throw new Error('TronZap client not available');
    }
    return this.tronZapClient.rentEnergy(amount, targetAddress, durationHours);
  }

  async rentBandwidth(amount: number, targetAddress: string, durationHours: number = 24) {
    if (!this.tronZapClient) {
      throw new Error('TronZap client not available');
    }
    return this.tronZapClient.rentBandwidth(amount, targetAddress, durationHours);
  }

  async autoRentResources(
    energyNeeded: number,
    bandwidthNeeded: number,
    targetAddress: string,
    safetyMargin: number = 0.2
  ) {
    if (!this.tronZapClient) {
      throw new Error('TronZap client not available');
    }
    return this.tronZapClient.autoRent(energyNeeded, bandwidthNeeded, targetAddress, safetyMargin);
  }

  async calculateOptimalRental(energyNeeded: number, bandwidthNeeded: number, targetAddress: string) {
    if (!this.tronZapClient) {
      throw new Error('TronZap client not available');
    }
    return this.tronZapClient.calculateOptimalRental(energyNeeded, bandwidthNeeded, targetAddress);
  }

  // Transaction Management
  async sendTransaction(config: TransactionConfig, privateKey?: string) {
    return this.transactionManager.sendTransaction(config, privateKey);
  }

  async sendAndConfirm(config: TransactionConfig, privateKey?: string, timeoutMs: number = 60000) {
    return this.transactionManager.sendAndConfirm(config, privateKey, timeoutMs);
  }

  async waitForConfirmation(txId: string, timeoutMs: number = 60000, confirmations: number = 1) {
    return this.transactionManager.waitForConfirmation(txId, timeoutMs, confirmations);
  }

  async getTransactionInfo(txId: string) {
    return this.transactionManager.getTransactionInfo(txId);
  }

  async retryTransaction(config: TransactionConfig, privateKey?: string, retryCount?: number) {
    return this.transactionManager.retryTransaction(config, privateKey, retryCount);
  }

  // Contract Deployment
  async deployContract(
    config: DeploymentConfig,
    privateKey?: string,
    autoRentResources: boolean = true
  ) {
    return this.contractDeployer.deployContract(config, privateKey, autoRentResources);
  }

  async predictContractAddress(deployerAddress: string, salt?: string): Promise<string> {
    return this.contractDeployer.predictContractAddress(deployerAddress, salt);
  }

  async batchDeploy(
    configs: DeploymentConfig[],
    privateKey?: string,
    autoRentResources: boolean = true
  ) {
    return this.contractDeployer.batchDeploy(configs, privateKey, autoRentResources);
  }

  async estimateBatchDeploymentCost(configs: DeploymentConfig[]) {
    return this.contractDeployer.estimateBatchDeploymentCost(configs);
  }

  getDeploymentHistory() {
    return this.contractDeployer.getDeploymentHistory();
  }

  // Utility Methods
  async transferTRX(to: string, amount: number, privateKey?: string) {
    const config: TransactionConfig = {
      from: this.getCurrentAddress(),
      to,
      value: this.networkManager.getTronWeb().toSun(amount),
      feeLimit: 1000000 // 1 TRX in SUN
    };

    return this.sendAndConfirm(config, privateKey);
  }

  async transferTRC20(
    tokenAddress: string,
    to: string,
    amount: number,
    privateKey?: string
  ) {
    const tronWeb = this.networkManager.getTronWeb();
    const contract = await tronWeb.contract().at(tokenAddress);
    
    // Get token decimals for proper amount calculation
    const decimals = await contract.decimals().call();
    const adjustedAmount = amount * Math.pow(10, decimals);

    const result = await contract.transfer(to, adjustedAmount).send({
      feeLimit: 10000000, // 10 TRX
      from: privateKey ? this.importAccount(privateKey).address : this.getCurrentAddress()
    });

    return result;
  }

  // System Management
  async healthCheck(): Promise<{
    network: any;
    account: { address: string; balance: number };
    tronZap: boolean;
    blockHeight: number;
  }> {
    try {
      const [networkHealth, balance, blockHeight] = await Promise.all([
        this.getNetworkHealth(),
        this.getBalance(),
        this.getBlockHeight()
      ]);

      return {
        network: networkHealth,
        account: {
          address: this.getCurrentAddress(),
          balance
        },
        tronZap: !!this.tronZapClient,
        blockHeight
      };
    } catch (error) {
      logger.error('Health check failed:', error);
      throw error;
    }
  }

  getStatistics() {
    return {
      network: this.networkManager.getNetworkName(),
      predictions: this.resourcePredictor.getStatistics(),
      deployments: this.contractDeployer.getDeploymentHistory().length,
      pendingTransactions: this.transactionManager.getPendingTransactions().length
    };
  }

  // Cleanup
  cleanup(): void {
    this.transactionManager.cleanupPendingTransactions();
    logger.info('Tron Toolkit cleanup completed');
  }

  // Direct TronWeb access for advanced users
  getTronWeb() {
    return this.networkManager.getTronWeb();
  }
}