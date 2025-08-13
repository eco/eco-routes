import axios, { AxiosInstance } from 'axios';
import { createHash } from 'crypto';
import { TronZapRentalRequest, TronZapRentalResponse } from '../types';
import { TRONZAP_CONFIG } from '../config/networks';
import { logger } from '../utils/logger';

export class TronZapClient {
  private client: AxiosInstance;
  private apiToken: string;
  private apiSecret: string;

  constructor(apiToken?: string, apiSecret?: string, baseURL?: string) {
    this.apiToken = apiToken || process.env.TRONZAP_API_TOKEN || TRONZAP_CONFIG.apiKey || '';
    this.apiSecret = apiSecret || process.env.TRONZAP_API_SECRET || '';
    
    if (!this.apiToken || !this.apiSecret) {
      throw new Error('TronZap API token and secret are required. Set TRONZAP_API_TOKEN and TRONZAP_API_SECRET in environment variables.');
    }

    this.client = axios.create({
      baseURL: baseURL || TRONZAP_CONFIG.apiUrl,
      timeout: 30000,
      headers: {
        'Content-Type': 'application/json',
        'User-Agent': 'Eco-TronTools/1.0.0'
        // Note: TronZap uses request signature authentication, not Authorization header
      }
    });

    // Add request/response interceptors for logging and authentication
    this.client.interceptors.request.use(
      (config) => {
        logger.debug(`TronZap API Request: ${config.method?.toUpperCase()} ${config.url}`);
        
        // Add TronZap authentication signature
        if (config.data) {
          const requestBody = typeof config.data === 'string' ? config.data : JSON.stringify(config.data);
          const signature = this.calculateSignature(requestBody);
          
          if (config.headers) {
            config.headers['X-API-TOKEN'] = this.apiToken;
            config.headers['X-API-SIGNATURE'] = signature;
          }
        }
        
        return config;
      },
      (error) => {
        logger.error('TronZap API Request Error:', error);
        return Promise.reject(error);
      }
    );

    this.client.interceptors.response.use(
      (response) => {
        logger.debug(`TronZap API Response: ${response.status} ${response.config.url}`);
        return response;
      },
      (error) => {
        logger.error('TronZap API Response Error:', error.response?.data || error.message);
        return Promise.reject(error);
      }
    );
  }

  /**
   * Calculate signature for TronZap API authentication
   */
  private calculateSignature(requestBody: string): string {
    // TronZap signature: SHA256(requestBody + apiSecret)
    const signatureString = requestBody + this.apiSecret;
    return createHash('sha256').update(signatureString).digest('hex');
  }

  /**
   * Get current energy and bandwidth rental prices
   */
  async getRentalPrices(): Promise<{
    energy: { pricePerUnit: number; minAmount: number; maxAmount: number };
    bandwidth: { pricePerUnit: number; minAmount: number; maxAmount: number };
    timestamp: Date;
  }> {
    try {
      // Try the services endpoint with POST method (TronZap API format)
      const response = await this.client.post('/services', {});
      
      // Parse the response based on actual TronZap format
      // For now, return reasonable estimates if we can't parse the exact format
      if (response.data && response.data.services) {
        // Look for energy service in the services array
        const services = response.data.services;
        const energyService = services.find((s: any) => s.name === 'energy' || s.type === 'energy');
        
        return {
          energy: {
            pricePerUnit: energyService?.price || 0.00003, // 0.00003 TRX per energy (reasonable estimate)
            minAmount: energyService?.min_amount || 1000,
            maxAmount: energyService?.max_amount || 10000000
          },
          bandwidth: {
            pricePerUnit: 0.000001, // Bandwidth is much cheaper
            minAmount: 1000,
            maxAmount: 100000
          },
          timestamp: new Date()
        };
      } else {
        // Fallback to reasonable estimates based on TronZap pricing
        logger.warn('Using estimated TronZap pricing - API format may have changed');
        return {
          energy: {
            pricePerUnit: 0.00003, // ~3.7 TRX for ~125k energy (typical USDT transfer)
            minAmount: 1000,
            maxAmount: 10000000
          },
          bandwidth: {
            pricePerUnit: 0.000001,
            minAmount: 1000,
            maxAmount: 100000
          },
          timestamp: new Date()
        };
      }
    } catch (error) {
      logger.error('Failed to get rental prices:', error);
      
      // Return reasonable fallback estimates so deployment can continue
      logger.warn('Using fallback TronZap pricing estimates');
      return {
        energy: {
          pricePerUnit: 0.00003, // Conservative estimate
          minAmount: 1000,
          maxAmount: 10000000
        },
        bandwidth: {
          pricePerUnit: 0.000001,
          minAmount: 1000,
          maxAmount: 100000
        },
        timestamp: new Date()
      };
    }
  }

  /**
   * Rent energy for a specific address
   */
  async rentEnergy(
    amount: number,
    targetAddress: string,
    durationHours: number = 24
  ): Promise<TronZapRentalResponse> {
    try {
      logger.info(`Renting ${amount} energy for ${targetAddress} (${durationHours}h)`);

      // Create energy transaction using TronZap API format
      const request = {
        address: targetAddress,
        energy_amount: amount,
        duration: durationHours, // 1 or 24 hours
        external_id: `eco-deploy-${Date.now()}`, // Unique ID for tracking
        activate_address: false // Don't activate address unless needed
      };

      const response = await this.client.post('/energy-transaction', request);

      if (response.data && response.data.success) {
        const rentalResponse: TronZapRentalResponse = {
          transactionId: response.data.transaction_id || response.data.tx_id,
          cost: response.data.cost_trx || response.data.cost,
          expiresAt: new Date(Date.now() + (durationHours * 60 * 60 * 1000)), // Calculate expiration
          success: true,
          error: undefined
        };

        logger.info(`Successfully rented energy. TX: ${rentalResponse.transactionId}, Cost: ${rentalResponse.cost} TRX`);
        return rentalResponse;
      } else {
        logger.error('Energy rental failed:', response.data);
        return {
          transactionId: '',
          cost: 0,
          expiresAt: new Date(),
          success: false,
          error: response.data?.error || 'Energy rental failed'
        };
      }
      
    } catch (error) {
      logger.error('Failed to rent energy:', error);
      
      return {
        transactionId: '',
        cost: 0,
        expiresAt: new Date(),
        success: false,
        error: error instanceof Error ? error.message : 'Unknown error occurred'
      };
    }
  }

  /**
   * Rent bandwidth for a specific address
   */
  async rentBandwidth(
    amount: number,
    targetAddress: string,
    durationHours: number = 24
  ): Promise<TronZapRentalResponse> {
    try {
      logger.info(`Renting ${amount} bandwidth for ${targetAddress} (${durationHours}h)`);

      const request: TronZapRentalRequest = {
        resourceType: 'bandwidth',
        amount,
        duration: durationHours,
        targetAddress
      };

      const response = await this.client.post('/v1/rental/bandwidth', request);

      const rentalResponse: TronZapRentalResponse = {
        transactionId: response.data.transaction_id,
        cost: response.data.cost_trx,
        expiresAt: new Date(response.data.expires_at),
        success: response.data.success,
        error: response.data.error
      };

      if (rentalResponse.success) {
        logger.info(`Successfully rented bandwidth. TX: ${rentalResponse.transactionId}`);
      } else {
        logger.error(`Bandwidth rental failed: ${rentalResponse.error}`);
      }

      return rentalResponse;
    } catch (error) {
      logger.error('Failed to rent bandwidth:', error);
      
      return {
        transactionId: '',
        cost: 0,
        expiresAt: new Date(),
        success: false,
        error: error instanceof Error ? error.message : 'Unknown error occurred'
      };
    }
  }

  /**
   * Get rental history for an address
   */
  async getRentalHistory(address: string, limit: number = 10): Promise<{
    rentals: Array<{
      transactionId: string;
      resourceType: 'energy' | 'bandwidth';
      amount: number;
      cost: number;
      rentedAt: Date;
      expiresAt: Date;
      status: 'active' | 'expired' | 'cancelled';
    }>;
  }> {
    try {
      const response = await this.client.get(`/v1/rental/history/${address}?limit=${limit}`);
      
      return {
        rentals: response.data.rentals.map((rental: any) => ({
          transactionId: rental.transaction_id,
          resourceType: rental.resource_type,
          amount: rental.amount,
          cost: rental.cost_trx,
          rentedAt: new Date(rental.rented_at),
          expiresAt: new Date(rental.expires_at),
          status: rental.status
        }))
      };
    } catch (error) {
      logger.error('Failed to get rental history:', error);
      return { rentals: [] };
    }
  }

  /**
   * Calculate optimal rental strategy based on predicted usage
   */
  async calculateOptimalRental(
    energyNeeded: number,
    bandwidthNeeded: number,
    targetAddress: string
  ): Promise<{
    recommendation: {
      energyRental: { amount: number; cost: number; duration: number };
      bandwidthRental: { amount: number; cost: number; duration: number };
      totalCost: number;
      savings: number;
    };
    alternatives: Array<{
      description: string;
      energyAmount: number;
      bandwidthAmount: number;
      totalCost: number;
      duration: number;
    }>;
  }> {
    try {
      const prices = await this.getRentalPrices();
      
      // Calculate direct costs
      const energyCost = energyNeeded * prices.energy.pricePerUnit;
      const bandwidthCost = bandwidthNeeded * prices.bandwidth.pricePerUnit;
      const directCost = energyCost + bandwidthCost;

      // Calculate bulk rental options (with discounts)
      const bulkEnergyAmount = Math.max(energyNeeded * 1.5, prices.energy.minAmount);
      const bulkBandwidthAmount = Math.max(bandwidthNeeded * 1.5, prices.bandwidth.minAmount);
      
      const bulkEnergyCost = bulkEnergyAmount * prices.energy.pricePerUnit * 0.9; // 10% discount
      const bulkBandwidthCost = bulkBandwidthAmount * prices.bandwidth.pricePerUnit * 0.9;
      const bulkCost = bulkEnergyCost + bulkBandwidthCost;

      const savings = Math.max(0, directCost - bulkCost);

      return {
        recommendation: {
          energyRental: {
            amount: bulkEnergyAmount,
            cost: bulkEnergyCost,
            duration: 24
          },
          bandwidthRental: {
            amount: bulkBandwidthAmount,
            cost: bulkBandwidthCost,
            duration: 24
          },
          totalCost: bulkCost,
          savings
        },
        alternatives: [
          {
            description: 'Exact amount needed',
            energyAmount: energyNeeded,
            bandwidthAmount: bandwidthNeeded,
            totalCost: directCost,
            duration: 24
          },
          {
            description: '48-hour rental with bulk discount',
            energyAmount: bulkEnergyAmount * 2,
            bandwidthAmount: bulkBandwidthAmount * 2,
            totalCost: bulkCost * 1.8, // 48h with better rate
            duration: 48
          }
        ]
      };
    } catch (error) {
      logger.error('Failed to calculate optimal rental:', error);
      throw error;
    }
  }

  /**
   * Check account balance and rental limits
   */
  async getAccountInfo(): Promise<{
    balance: number;
    dailyRentalLimit: number;
    usedRentalToday: number;
    tier: string;
    discountRate: number;
  }> {
    try {
      const response = await this.client.get('/v1/account/info');
      
      return {
        balance: response.data.balance_trx,
        dailyRentalLimit: response.data.daily_rental_limit,
        usedRentalToday: response.data.used_rental_today,
        tier: response.data.tier,
        discountRate: response.data.discount_rate
      };
    } catch (error) {
      logger.error('Failed to get account info:', error);
      throw error;
    }
  }

  /**
   * Auto-rent resources based on predicted needs with safety margins
   */
  async autoRent(
    energyNeeded: number,
    bandwidthNeeded: number,
    targetAddress: string,
    safetyMargin: number = 0.2 // 20% extra
  ): Promise<{
    energyRental?: TronZapRentalResponse;
    bandwidthRental?: TronZapRentalResponse;
    totalCost: number;
    success: boolean;
  }> {
    try {
      const optimal = await this.calculateOptimalRental(
        energyNeeded * (1 + safetyMargin),
        bandwidthNeeded * (1 + safetyMargin),
        targetAddress
      );

      const results: any = {
        totalCost: 0,
        success: true
      };

      // Rent energy if needed
      if (optimal.recommendation.energyRental.amount > 0) {
        const energyResult = await this.rentEnergy(
          optimal.recommendation.energyRental.amount,
          targetAddress
        );
        results.energyRental = energyResult;
        results.totalCost += energyResult.cost;
        
        if (!energyResult.success) {
          results.success = false;
        }
      }

      // Rent bandwidth if needed
      if (optimal.recommendation.bandwidthRental.amount > 0) {
        const bandwidthResult = await this.rentBandwidth(
          optimal.recommendation.bandwidthRental.amount,
          targetAddress
        );
        results.bandwidthRental = bandwidthResult;
        results.totalCost += bandwidthResult.cost;
        
        if (!bandwidthResult.success) {
          results.success = false;
        }
      }

      return results;
    } catch (error) {
      logger.error('Auto-rent failed:', error);
      return {
        totalCost: 0,
        success: false
      };
    }
  }
}