import { TransactionConfig, TransactionResult } from '../types';
import { DEFAULT_CONFIG } from '../config/networks';
import { logger } from '../utils/logger';

export class TransactionManager {
  private tronWeb: any;
  private pendingTransactions: Map<string, any> = new Map();

  constructor(tronWeb: any) {
    this.tronWeb = tronWeb;
  }

  /**
   * Builds a transaction with proper fee estimation
   */
  async buildTransaction(config: TransactionConfig): Promise<any> {
    try {
      logger.debug('Building transaction:', config);

      const transaction: any = {
        to_address: this.tronWeb.address.toHex(config.to),
        owner_address: this.tronWeb.address.toHex(config.from),
        amount: config.value || 0,
        fee_limit: config.feeLimit || DEFAULT_CONFIG.deployFeeLimit
      };

      // Add contract call data if present
      if (config.data) {
        transaction.data = config.data;
      }

      // Set resource limits if specified
      if (config.energy) {
        transaction.call_token_value = config.energy;
      }

      return transaction;
    } catch (error) {
      logger.error('Failed to build transaction:', error);
      throw error;
    }
  }

  /**
   * Estimates transaction fee
   */
  async estimateTransactionFee(config: TransactionConfig): Promise<{
    energyRequired: number;
    bandwidthRequired: number;
    feeLimit: number;
    estimatedCost: number;
  }> {
    try {
      // For TRX transfers
      if (!config.to || !config.data) {
        return {
          energyRequired: 0,
          bandwidthRequired: 268, // Standard TRX transfer
          feeLimit: 1000000, // 1 TRX in SUN
          estimatedCost: 0 // Free if within bandwidth limit
        };
      }

      // For contract interactions, use TronWeb's built-in estimation
      const transaction = await this.buildTransaction(config);
      
      // This is a simplified estimation - real implementation would
      // use TronWeb's trigger constant contract or similar methods
      return {
        energyRequired: config.energy || 50000,
        bandwidthRequired: Math.ceil((config.data?.length || 0) / 2) + 300,
        feeLimit: config.feeLimit || DEFAULT_CONFIG.deployFeeLimit,
        estimatedCost: this.tronWeb.fromSun(config.feeLimit || DEFAULT_CONFIG.deployFeeLimit)
      };
    } catch (error) {
      logger.error('Failed to estimate transaction fee:', error);
      throw error;
    }
  }

  /**
   * Signs a transaction
   */
  async signTransaction(transaction: any, privateKey?: string): Promise<any> {
    try {
      logger.debug('Signing transaction');

      let signedTx;
      if (privateKey) {
        // Sign with specific private key
        signedTx = await this.tronWeb.trx.sign(transaction, privateKey);
      } else {
        // Sign with default private key
        signedTx = await this.tronWeb.trx.sign(transaction);
      }

      logger.debug('Transaction signed successfully');
      return signedTx;
    } catch (error) {
      logger.error('Failed to sign transaction:', error);
      throw error;
    }
  }

  /**
   * Broadcasts a signed transaction
   */
  async broadcastTransaction(signedTransaction: any): Promise<TransactionResult> {
    try {
      logger.info('Broadcasting transaction');

      const result = await this.tronWeb.trx.sendRawTransaction(signedTransaction);
      
      if (result.result) {
        const txId = result.txid;
        this.pendingTransactions.set(txId, {
          transaction: signedTransaction,
          broadcastAt: new Date(),
          confirmed: false
        });

        logger.info(`Transaction broadcast successful. TX ID: ${txId}`);
        
        return {
          txId,
          blockNumber: 0, // Will be filled when confirmed
          confirmed: false,
          energyUsed: 0,
          bandwidthUsed: 0,
          fee: 0,
          result: result
        };
      } else {
        throw new Error(result.message || 'Transaction broadcast failed');
      }
    } catch (error) {
      logger.error('Failed to broadcast transaction:', error);
      throw error;
    }
  }

  /**
   * Sends a transaction (build + sign + broadcast)
   */
  async sendTransaction(config: TransactionConfig, privateKey?: string): Promise<TransactionResult> {
    try {
      logger.info(`Sending transaction from ${config.from} to ${config.to}`);

      // Build transaction
      const transaction = await this.buildTransaction(config);
      
      // Sign transaction
      const signedTx = await this.signTransaction(transaction, privateKey);
      
      // Broadcast transaction
      const result = await this.broadcastTransaction(signedTx);
      
      return result;
    } catch (error) {
      logger.error('Failed to send transaction:', error);
      throw error;
    }
  }

  /**
   * Waits for transaction confirmation
   */
  async waitForConfirmation(
    txId: string,
    timeoutMs: number = 60000,
    confirmations: number = 1
  ): Promise<TransactionResult> {
    const startTime = Date.now();
    
    return new Promise((resolve, reject) => {
      const checkConfirmation = async () => {
        try {
          const info = await this.tronWeb.trx.getTransactionInfo(txId);
          
          if (info && info.blockNumber) {
            // Transaction is confirmed
            const currentBlock = await this.tronWeb.trx.getCurrentBlock();
            const confirmationCount = currentBlock.block_header.raw_data.number - info.blockNumber + 1;
            
            if (confirmationCount >= confirmations) {
              const result: TransactionResult = {
                txId,
                blockNumber: info.blockNumber,
                confirmed: true,
                energyUsed: info.receipt?.energy_usage_total || 0,
                bandwidthUsed: info.receipt?.net_usage || 0,
                fee: info.fee || 0,
                result: info.receipt?.result || 'SUCCESS'
              };
              
              // Remove from pending transactions
              this.pendingTransactions.delete(txId);
              
              logger.info(`Transaction ${txId} confirmed in block ${info.blockNumber}`);
              resolve(result);
              return;
            }
          }
          
          // Check timeout
          if (Date.now() - startTime > timeoutMs) {
            reject(new Error(`Transaction confirmation timeout after ${timeoutMs}ms`));
            return;
          }
          
          // Wait and check again
          setTimeout(checkConfirmation, 3000); // Check every 3 seconds
        } catch (error) {
          if (Date.now() - startTime > timeoutMs) {
            reject(new Error(`Transaction confirmation timeout: ${error}`));
          } else {
            // Continue checking on error (might be temporary)
            setTimeout(checkConfirmation, 5000);
          }
        }
      };
      
      checkConfirmation();
    });
  }

  /**
   * Sends transaction with confirmation waiting
   */
  async sendAndConfirm(
    config: TransactionConfig,
    privateKey?: string,
    timeoutMs: number = 60000
  ): Promise<TransactionResult> {
    try {
      // Send transaction
      const result = await this.sendTransaction(config, privateKey);
      
      // Wait for confirmation
      const confirmedResult = await this.waitForConfirmation(result.txId, timeoutMs);
      
      return confirmedResult;
    } catch (error) {
      logger.error('Failed to send and confirm transaction:', error);
      throw error;
    }
  }

  /**
   * Retries a failed transaction with increased fee limit
   */
  async retryTransaction(
    config: TransactionConfig,
    privateKey?: string,
    retryCount: number = DEFAULT_CONFIG.maxRetries
  ): Promise<TransactionResult> {
    let lastError: Error | null = null;
    
    for (let attempt = 1; attempt <= retryCount; attempt++) {
      try {
        logger.info(`Transaction attempt ${attempt}/${retryCount}`);
        
        // Increase fee limit for retry attempts
        const adjustedConfig = {
          ...config,
          feeLimit: Math.floor((config.feeLimit || DEFAULT_CONFIG.deployFeeLimit) * (1 + (attempt - 1) * 0.5))
        };
        
        const result = await this.sendAndConfirm(adjustedConfig, privateKey);
        
        logger.info(`Transaction succeeded on attempt ${attempt}`);
        return result;
      } catch (error) {
        lastError = error instanceof Error ? error : new Error('Unknown error');
        logger.warn(`Transaction attempt ${attempt} failed:`, lastError.message);
        
        if (attempt < retryCount) {
          const delay = DEFAULT_CONFIG.retryDelay * attempt;
          logger.info(`Retrying in ${delay}ms...`);
          await new Promise(resolve => setTimeout(resolve, delay));
        }
      }
    }
    
    throw new Error(`Transaction failed after ${retryCount} attempts. Last error: ${lastError?.message}`);
  }

  /**
   * Gets transaction receipt and details
   */
  async getTransactionInfo(txId: string): Promise<any> {
    try {
      const [transaction, transactionInfo] = await Promise.all([
        this.tronWeb.trx.getTransaction(txId),
        this.tronWeb.trx.getTransactionInfo(txId)
      ]);
      
      return {
        transaction,
        info: transactionInfo
      };
    } catch (error) {
      logger.error('Failed to get transaction info:', error);
      throw error;
    }
  }

  /**
   * Cancels a pending transaction (if possible)
   */
  async cancelTransaction(txId: string): Promise<boolean> {
    try {
      // Check if transaction is still pending
      const pending = this.pendingTransactions.get(txId);
      if (!pending) {
        return false; // Transaction not found or already processed
      }
      
      // Check if transaction is confirmed
      const info = await this.tronWeb.trx.getTransactionInfo(txId);
      if (info && info.blockNumber) {
        // Already confirmed, cannot cancel
        this.pendingTransactions.delete(txId);
        return false;
      }
      
      // Try to send a replacement transaction with higher fee
      // (This is a simplified approach - actual cancellation depends on network conditions)
      logger.warn(`Attempting to cancel transaction ${txId}`);
      this.pendingTransactions.delete(txId);
      
      return true;
    } catch (error) {
      logger.error('Failed to cancel transaction:', error);
      return false;
    }
  }

  /**
   * Gets all pending transactions
   */
  getPendingTransactions(): Array<{ txId: string; broadcastAt: Date }> {
    return Array.from(this.pendingTransactions.entries()).map(([txId, data]) => ({
      txId,
      broadcastAt: data.broadcastAt
    }));
  }

  /**
   * Cleans up old pending transactions
   */
  cleanupPendingTransactions(maxAgeMs: number = 300000): number { // 5 minutes default
    const cutoff = Date.now() - maxAgeMs;
    let cleaned = 0;
    
    for (const [txId, data] of this.pendingTransactions.entries()) {
      if (data.broadcastAt.getTime() < cutoff) {
        this.pendingTransactions.delete(txId);
        cleaned++;
      }
    }
    
    if (cleaned > 0) {
      logger.info(`Cleaned up ${cleaned} old pending transactions`);
    }
    
    return cleaned;
  }
}