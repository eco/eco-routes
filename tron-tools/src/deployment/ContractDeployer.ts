import { DeploymentConfig, ContractDeploymentResult, TransactionResult } from '../types';
import { TransactionManager } from '../transaction/TransactionManager';
import { ResourcePredictor } from '../prediction/ResourcePredictor';
import { TronZapClient } from '../rental/TronZapClient';
import { AccountManager } from '../account/AccountManager';
import { DEFAULT_CONFIG } from '../config/networks';
import { logger } from '../utils/logger';

export class ContractDeployer {
  private tronWeb: any;
  private transactionManager: TransactionManager;
  private resourcePredictor: ResourcePredictor;
  private tronZapClient?: TronZapClient;
  private accountManager: AccountManager;
  private deploymentHistory: Map<string, ContractDeploymentResult> = new Map();

  constructor(
    tronWeb: any,
    transactionManager: TransactionManager,
    resourcePredictor: ResourcePredictor,
    accountManager: AccountManager,
    tronZapClient?: TronZapClient
  ) {
    this.tronWeb = tronWeb;
    this.transactionManager = transactionManager;
    this.resourcePredictor = resourcePredictor;
    this.accountManager = accountManager;
    this.tronZapClient = tronZapClient;
  }

  /**
   * Deploys a smart contract to the Tron network
   */
  async deployContract(
    config: DeploymentConfig,
    privateKey?: string,
    autoRentResources: boolean = true
  ): Promise<ContractDeploymentResult> {
    const startTime = Date.now();
    
    try {
      logger.info(`Starting deployment of ${config.contractName}`);

      // Validate deployment configuration
      this.validateDeploymentConfig(config);

      // Predict resource requirements
      const resourceEstimate = await this.resourcePredictor.predictContractDeployment(
        config.bytecode,
        config.constructorParams,
        config.abi
      );

      logger.info(`Estimated resources: ${resourceEstimate.energy} energy, ${resourceEstimate.bandwidth} bandwidth`);

      // Auto-rent resources if enabled and TronZap client available
      if (autoRentResources && this.tronZapClient) {
        await this.ensureSufficientResources(resourceEstimate, privateKey);
      }

      // Prepare deployment transaction
      const deploymentTx = await this.buildDeploymentTransaction(config);

      // Deploy contract using CREATE or CREATE2
      let deploymentResult: TransactionResult;
      
      if (config.salt) {
        deploymentResult = await this.deployWithCreate2(config, privateKey);
      } else {
        deploymentResult = await this.deployWithCreate(deploymentTx, privateKey);
      }

      // Calculate actual contract address
      const contractAddress = await this.getDeployedContractAddress(
        deploymentResult.txId,
        config.salt
      );

      // Verify deployment success
      await this.verifyDeployment(contractAddress, config.abi);

      const deploymentTime = Date.now() - startTime;
      
      const result: ContractDeploymentResult = {
        contractAddress,
        transactionId: deploymentResult.txId,
        blockNumber: deploymentResult.blockNumber,
        gasUsed: 0, // Tron doesn't use gas
        energyUsed: deploymentResult.energyUsed,
        bandwidthUsed: deploymentResult.bandwidthUsed,
        actualCost: this.tronWeb.fromSun(deploymentResult.fee),
        deploymentTime: new Date(Date.now() - deploymentTime)
      };

      // Record deployment in history
      this.deploymentHistory.set(contractAddress, result);

      // Update resource predictor with actual usage
      this.resourcePredictor.recordActualUsage(
        'contractDeploy',
        contractAddress,
        deploymentResult.energyUsed
      );

      logger.info(`Contract ${config.contractName} deployed successfully at ${contractAddress}`);
      return result;

    } catch (error) {
      logger.error(`Contract deployment failed: ${error}`);
      throw error;
    }
  }

  /**
   * Predicts contract address before deployment
   */
  async predictContractAddress(
    deployerAddress: string,
    salt?: string
  ): Promise<string> {
    try {
      if (salt) {
        // CREATE2 address prediction
        const saltBytes = this.tronWeb.utils.code.hexStr2byteArray(salt);
        // Note: This is a simplified implementation
        // Real CREATE2 address calculation would require the full bytecode hash
        return this.tronWeb.address.fromHex('41' + salt.slice(-40));
      } else {
        // CREATE address prediction based on nonce
        const account = await this.accountManager.getAccountInfo(deployerAddress);
        const nonce = account.create_time || 0; // Simplified nonce calculation
        
        // This is a placeholder - actual address prediction would require
        // proper nonce handling and address derivation
        const hash = this.tronWeb.utils.crypto.keccak256(
          deployerAddress + nonce.toString()
        );
        
        return this.tronWeb.address.fromHex('41' + hash.slice(-40));
      }
    } catch (error) {
      logger.error('Failed to predict contract address:', error);
      throw error;
    }
  }

  /**
   * Validates deployment configuration
   */
  private validateDeploymentConfig(config: DeploymentConfig): void {
    if (!config.contractName) {
      throw new Error('Contract name is required');
    }

    if (!config.bytecode || config.bytecode.length === 0) {
      throw new Error('Contract bytecode is required');
    }

    if (!config.abi || !Array.isArray(config.abi)) {
      throw new Error('Contract ABI is required and must be an array');
    }

    // Validate bytecode format
    if (!config.bytecode.startsWith('0x') && !/^[0-9a-fA-F]+$/.test(config.bytecode)) {
      throw new Error('Invalid bytecode format');
    }

    // Validate constructor parameters match ABI
    if (config.constructorParams) {
      const constructor = config.abi.find(item => item.type === 'constructor');
      if (constructor) {
        const expectedParams = constructor.inputs?.length || 0;
        if (config.constructorParams.length !== expectedParams) {
          throw new Error(`Constructor expects ${expectedParams} parameters, got ${config.constructorParams.length}`);
        }
      }
    }

    logger.debug('Deployment configuration validated successfully');
  }

  /**
   * Builds deployment transaction
   */
  private async buildDeploymentTransaction(config: DeploymentConfig): Promise<any> {
    try {
      const options: any = {
        abi: config.abi,
        bytecode: config.bytecode,
        feeLimit: config.feeLimit || DEFAULT_CONFIG.deployFeeLimit
      };

      if (config.constructorParams && config.constructorParams.length > 0) {
        options.parameters = config.constructorParams;
      }

      const transaction = await this.tronWeb.transactionBuilder.createSmartContract(
        options,
        this.accountManager.getCurrentAddress()
      );

      return transaction;
    } catch (error) {
      logger.error('Failed to build deployment transaction:', error);
      throw error;
    }
  }

  /**
   * Deploys contract using standard CREATE
   */
  private async deployWithCreate(
    transaction: any,
    privateKey?: string
  ): Promise<TransactionResult> {
    try {
      logger.debug('Deploying contract using CREATE');

      const signedTx = await this.transactionManager.signTransaction(transaction, privateKey);
      const result = await this.transactionManager.broadcastTransaction(signedTx);
      
      // Wait for confirmation
      const confirmedResult = await this.transactionManager.waitForConfirmation(result.txId);
      
      return confirmedResult;
    } catch (error) {
      logger.error('CREATE deployment failed:', error);
      throw error;
    }
  }

  /**
   * Deploys contract using CREATE2 for deterministic addresses
   */
  private async deployWithCreate2(
    config: DeploymentConfig,
    privateKey?: string
  ): Promise<TransactionResult> {
    try {
      logger.debug('Deploying contract using CREATE2');

      if (!config.salt) {
        throw new Error('Salt is required for CREATE2 deployment');
      }

      // Build CREATE2 deployment transaction
      const options: any = {
        abi: config.abi,
        bytecode: config.bytecode,
        feeLimit: config.feeLimit || DEFAULT_CONFIG.deployFeeLimit,
        call_value: 0,
        consume_user_resource_percent: 100
      };

      if (config.constructorParams && config.constructorParams.length > 0) {
        options.parameters = config.constructorParams;
      }

      // Note: TronWeb doesn't have native CREATE2 support
      // This would require a factory contract or custom implementation
      const transaction = await this.tronWeb.transactionBuilder.createSmartContract(
        options,
        this.accountManager.getCurrentAddress()
      );

      const signedTx = await this.transactionManager.signTransaction(transaction, privateKey);
      const result = await this.transactionManager.broadcastTransaction(signedTx);
      
      const confirmedResult = await this.transactionManager.waitForConfirmation(result.txId);
      
      return confirmedResult;
    } catch (error) {
      logger.error('CREATE2 deployment failed:', error);
      throw error;
    }
  }

  /**
   * Gets the deployed contract address from transaction
   */
  private async getDeployedContractAddress(
    txId: string,
    salt?: string
  ): Promise<string> {
    try {
      const transactionInfo = await this.transactionManager.getTransactionInfo(txId);
      
      // Try multiple potential locations for the contract address
      let hexAddress: string | undefined;
      
      // Method 1: Check nested under info (original logic)
      if (transactionInfo.info && transactionInfo.info.contract_address) {
        hexAddress = transactionInfo.info.contract_address;
      }
      // Method 2: Check top-level contract_address (observed in LayerZeroProver deployment)
      else if (transactionInfo.contract_address) {
        hexAddress = transactionInfo.contract_address;
      }
      // Method 3: Check raw transaction data if available
      else if (transactionInfo.raw_data && transactionInfo.raw_data.contract_address) {
        hexAddress = transactionInfo.raw_data.contract_address;
      }
      
      if (hexAddress) {
        // Ensure hex address starts with 41 (Tron address prefix)
        if (!hexAddress.startsWith('41')) {
          hexAddress = '41' + hexAddress;
        }
        return this.tronWeb.address.fromHex(hexAddress);
      }
      
      // If still no address found, log the transaction structure for debugging
      logger.error('Contract address not found. Transaction info structure:', JSON.stringify(transactionInfo, null, 2));
      throw new Error('Contract address not found in transaction info');
    } catch (error) {
      logger.error('Failed to get deployed contract address:', error);
      throw error;
    }
  }

  /**
   * Verifies successful contract deployment
   */
  private async verifyDeployment(contractAddress: string, abi: any[]): Promise<void> {
    try {
      logger.debug(`Verifying deployment at ${contractAddress}`);

      // Check if contract exists
      const contract = await this.tronWeb.trx.getContract(contractAddress);
      
      if (!contract || !contract.bytecode) {
        throw new Error('Contract not found at deployed address');
      }

      // Try to create contract instance
      const contractInstance = await this.tronWeb.contract(abi, contractAddress);
      
      if (!contractInstance) {
        throw new Error('Failed to create contract instance');
      }

      logger.info(`Contract deployment verified at ${contractAddress}`);
    } catch (error) {
      logger.error('Deployment verification failed:', error);
      throw new Error(`Deployment verification failed: ${error}`);
    }
  }

  /**
   * Ensures sufficient resources for deployment
   */
  private async ensureSufficientResources(
    resourceEstimate: any,
    privateKey?: string
  ): Promise<void> {
    if (!this.tronZapClient) {
      logger.warn('TronZap client not available for auto-resource rental');
      return;
    }

    try {
      const currentAddress = privateKey 
        ? this.accountManager.importAccount(privateKey).address
        : this.accountManager.getCurrentAddress();

      const currentResources = await this.accountManager.getAccountResources(currentAddress);
      
      const energyNeeded = Math.max(0, resourceEstimate.energy - currentResources.energy.available);
      const bandwidthNeeded = Math.max(0, resourceEstimate.bandwidth - currentResources.bandwidth.available);

      if (energyNeeded > 0 || bandwidthNeeded > 0) {
        logger.info(`Auto-renting resources: ${energyNeeded} energy, ${bandwidthNeeded} bandwidth`);
        
        const rental = await this.tronZapClient.autoRent(
          energyNeeded,
          bandwidthNeeded,
          currentAddress,
          0.5 // 50% safety margin for deployments
        );

        if (!rental.success) {
          throw new Error('Failed to rent sufficient resources for deployment');
        }

        logger.info(`Successfully rented resources for deployment (cost: ${rental.totalCost} TRX)`);
      }
    } catch (error) {
      logger.error('Failed to ensure sufficient resources:', error);
      throw error;
    }
  }

  /**
   * Gets deployment history
   */
  getDeploymentHistory(): ContractDeploymentResult[] {
    return Array.from(this.deploymentHistory.values());
  }

  /**
   * Gets specific deployment result
   */
  getDeploymentResult(contractAddress: string): ContractDeploymentResult | undefined {
    return this.deploymentHistory.get(contractAddress);
  }

  /**
   * Batch deploys multiple contracts
   */
  async batchDeploy(
    configs: DeploymentConfig[],
    privateKey?: string,
    autoRentResources: boolean = true
  ): Promise<ContractDeploymentResult[]> {
    const results: ContractDeploymentResult[] = [];
    
    for (let i = 0; i < configs.length; i++) {
      try {
        logger.info(`Deploying contract ${i + 1}/${configs.length}: ${configs[i].contractName}`);
        
        const result = await this.deployContract(configs[i], privateKey, autoRentResources);
        results.push(result);
        
        // Small delay between deployments to avoid network congestion
        if (i < configs.length - 1) {
          await new Promise(resolve => setTimeout(resolve, 2000));
        }
      } catch (error) {
        logger.error(`Batch deployment failed for ${configs[i].contractName}:`, error);
        throw error;
      }
    }
    
    logger.info(`Successfully deployed ${results.length} contracts`);
    return results;
  }

  /**
   * Estimates total deployment cost for multiple contracts
   */
  async estimateBatchDeploymentCost(configs: DeploymentConfig[]): Promise<{
    totalEnergy: number;
    totalBandwidth: number;
    totalCostTRX: number;
    individual: Array<{
      contractName: string;
      energy: number;
      bandwidth: number;
      costTRX: number;
    }>;
  }> {
    const individual = [];
    let totalEnergy = 0;
    let totalBandwidth = 0;
    let totalCostTRX = 0;

    for (const config of configs) {
      const estimate = await this.resourcePredictor.predictContractDeployment(
        config.bytecode,
        config.constructorParams,
        config.abi
      );

      individual.push({
        contractName: config.contractName,
        energy: estimate.energy,
        bandwidth: estimate.bandwidth,
        costTRX: estimate.totalCostTRX
      });

      totalEnergy += estimate.energy;
      totalBandwidth += estimate.bandwidth;
      totalCostTRX += estimate.totalCostTRX;
    }

    return {
      totalEnergy,
      totalBandwidth,
      totalCostTRX,
      individual
    };
  }
}