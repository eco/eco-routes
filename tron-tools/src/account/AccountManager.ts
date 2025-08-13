import TronWeb from 'tronweb';
import { TronAccount } from '../types';
import { logger } from '../utils/logger';

export class AccountManager {
  private tronWeb: any;

  constructor(tronWeb: any) {
    this.tronWeb = tronWeb;
  }

  /**
   * Creates a new Tron account with a randomly generated private key
   */
  createAccount(): TronAccount {
    try {
      const account = this.tronWeb.utils.accounts.generateAccount();
      
      const tronAccount: TronAccount = {
        address: account.address.base58,
        privateKey: account.privateKey,
        base58Address: account.address.base58,
        hexAddress: account.address.hex
      };

      logger.info(`Created new Tron account: ${tronAccount.base58Address}`);
      return tronAccount;
    } catch (error) {
      logger.error('Failed to create account:', error);
      throw error;
    }
  }

  /**
   * Imports an account from a private key
   */
  importAccount(privateKey: string): TronAccount {
    try {
      // Remove 0x prefix if present
      const cleanPrivateKey = privateKey.startsWith('0x') ? privateKey.slice(2) : privateKey;
      
      // Validate private key format
      if (!/^[0-9a-fA-F]{64}$/.test(cleanPrivateKey)) {
        throw new Error('Invalid private key format');
      }

      const address = this.tronWeb.address.fromPrivateKey(cleanPrivateKey);
      
      const tronAccount: TronAccount = {
        address: address,
        privateKey: cleanPrivateKey,
        base58Address: address,
        hexAddress: this.tronWeb.address.toHex(address)
      };

      logger.info(`Imported Tron account: ${tronAccount.base58Address}`);
      return tronAccount;
    } catch (error) {
      logger.error('Failed to import account:', error);
      throw error;
    }
  }

  /**
   * Sets the private key for TronWeb instance
   */
  setPrivateKey(privateKey: string): void {
    try {
      const cleanPrivateKey = privateKey.startsWith('0x') ? privateKey.slice(2) : privateKey;
      this.tronWeb.setPrivateKey(cleanPrivateKey);
      logger.debug('Private key set for TronWeb instance');
    } catch (error) {
      logger.error('Failed to set private key:', error);
      throw error;
    }
  }

  /**
   * Gets the current default address from TronWeb
   */
  getCurrentAddress(): string {
    try {
      return this.tronWeb.defaultAddress.base58;
    } catch (error) {
      logger.error('Failed to get current address:', error);
      throw error;
    }
  }

  /**
   * Validates if an address is a valid Tron address
   */
  isValidAddress(address: string): boolean {
    try {
      return this.tronWeb.isAddress(address);
    } catch (error) {
      return false;
    }
  }

  /**
   * Converts address between hex and base58 formats
   */
  convertAddress(address: string): { hex: string; base58: string } {
    try {
      if (this.isValidAddress(address)) {
        const isHex = address.startsWith('41') || address.startsWith('0x41');
        
        if (isHex) {
          const base58 = this.tronWeb.address.fromHex(address);
          return {
            hex: address.startsWith('0x') ? address : '0x' + address,
            base58
          };
        } else {
          const hex = this.tronWeb.address.toHex(address);
          return {
            hex,
            base58: address
          };
        }
      } else {
        throw new Error('Invalid Tron address');
      }
    } catch (error) {
      logger.error('Failed to convert address:', error);
      throw error;
    }
  }

  /**
   * Gets account balance in TRX
   */
  async getBalance(address?: string): Promise<number> {
    try {
      const targetAddress = address || this.getCurrentAddress();
      const balance = await this.tronWeb.trx.getBalance(targetAddress);
      return this.tronWeb.fromSun(balance); // Convert from SUN to TRX
    } catch (error) {
      logger.error('Failed to get balance:', error);
      throw error;
    }
  }

  /**
   * Gets account resources (energy and bandwidth)
   */
  async getAccountResources(address?: string): Promise<{
    energy: { available: number; total: number };
    bandwidth: { available: number; total: number };
  }> {
    try {
      const targetAddress = address || this.getCurrentAddress();
      const resources = await this.tronWeb.trx.getAccountResources(targetAddress);
      
      return {
        energy: {
          available: resources.EnergyLimit || 0,
          total: resources.EnergyUsed || 0
        },
        bandwidth: {
          available: resources.freeNetLimit || 0,
          total: resources.freeNetUsed || 0
        }
      };
    } catch (error) {
      logger.error('Failed to get account resources:', error);
      return {
        energy: { available: 0, total: 0 },
        bandwidth: { available: 0, total: 0 }
      };
    }
  }

  /**
   * Gets detailed account information
   */
  async getAccountInfo(address?: string): Promise<any> {
    try {
      const targetAddress = address || this.getCurrentAddress();
      const account = await this.tronWeb.trx.getAccount(targetAddress);
      return account;
    } catch (error) {
      logger.error('Failed to get account info:', error);
      throw error;
    }
  }

  /**
   * Checks if account has sufficient TRX for transaction
   */
  async hasSufficientBalance(requiredTRX: number, address?: string): Promise<boolean> {
    try {
      const balance = await this.getBalance(address);
      return balance >= requiredTRX;
    } catch (error) {
      logger.error('Failed to check balance:', error);
      return false;
    }
  }

  /**
   * Estimates the TRX needed for a transaction based on energy and bandwidth
   */
  estimateTransactionCost(energy: number, bandwidth: number): number {
    // Energy cost: 1 SUN = 1 energy unit when burning TRX
    // Bandwidth cost: 1000 SUN per bandwidth point
    const energyCostSun = energy * 420; // 420 SUN per energy unit (current rate)
    const bandwidthCostSun = bandwidth * 1000; // 1000 SUN per bandwidth
    
    const totalCostSun = energyCostSun + bandwidthCostSun;
    return this.tronWeb.fromSun(totalCostSun); // Convert to TRX
  }
}