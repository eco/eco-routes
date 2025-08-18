import { TronZapClient as OfficialTronZapClient, TronZapError } from 'tronzap-sdk';
import { TronZapRentalRequest, TronZapRentalResponse } from '../types';
import { logger } from '../utils/logger';

export class TronZapClient {
  private client: OfficialTronZapClient;

  constructor(apiToken?: string, apiSecret?: string, baseURL?: string) {
    const token = apiToken || process.env.TRONZAP_API_TOKEN || '';
    const secret = apiSecret || process.env.TRONZAP_API_SECRET || '';
    
    if (!token || !secret) {
      throw new Error('TronZap API token and secret are required. Set TRONZAP_API_TOKEN and TRONZAP_API_SECRET in environment variables.');
    }

    this.client = new OfficialTronZapClient({
      apiToken: token,
      apiSecret: secret,
      baseUrl: baseURL || 'https://api.tronzap.com'
    });

    logger.info('TronZap SDK client initialized');
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
      // Use the official SDK to get services
      const services = await this.client.getServices();
      logger.info('TronZap services retrieved successfully');
      
      // Parse energy pricing from the services response
      if ((services as any).energy && Array.isArray((services as any).energy)) {
        const energyServices = (services as any).energy;
        
        // Find the 24-hour service with the widest range for general pricing
        const service24h = energyServices.find((s: any) => s.duration === 24 && s.max_energy >= 1000000);
        
        if (service24h) {
          // Calculate average price per energy unit from the service
          // Using price_131k as reference (131k energy for price_131k TRX)
          const pricePerUnit = service24h.price_131k / 131000;
          
          return {
            energy: {
              pricePerUnit: pricePerUnit,
              minAmount: service24h.min_energy,
              maxAmount: service24h.max_energy
            },
            bandwidth: {
              pricePerUnit: 0.000001, // TronZap mainly focuses on energy
              minAmount: 1000,
              maxAmount: 100000
            },
            timestamp: new Date()
          };
        }
      }
      
      // Fallback to conservative estimates
      logger.warn('Could not parse TronZap pricing structure, using fallback estimates');
      return {
        energy: {
          pricePerUnit: 0.00013, // Based on observed TronZap pricing
          minAmount: 50000,
          maxAmount: 5000000
        },
        bandwidth: {
          pricePerUnit: 0.000001,
          minAmount: 1000,
          maxAmount: 100000
        },
        timestamp: new Date()
      };
      
    } catch (error) {
      if (error instanceof TronZapError) {
        logger.error(`TronZap API error (${error.code}): ${error.message}`);
      } else {
        logger.error('Failed to get TronZap services:', error);
      }
      
      // Return reasonable fallback estimates so deployment can continue
      logger.warn('Using fallback TronZap pricing estimates due to API error');
      return {
        energy: {
          pricePerUnit: 0.00013, // Conservative estimate based on TronZap pricing
          minAmount: 50000,
          maxAmount: 5000000
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

      // Use the official SDK to create energy transaction  
      const transaction = await this.client.createEnergyTransaction(
        targetAddress,
        amount,
        durationHours === 1 ? 1 : 24 // TronZap supports 1 or 24 hours
      );

      if (transaction && transaction.transaction_id) {
        const rentalResponse: TronZapRentalResponse = {
          transactionId: transaction.transaction_id || transaction.id || '',
          cost: transaction.cost_trx || transaction.cost || 0,
          expiresAt: new Date(Date.now() + (durationHours * 60 * 60 * 1000)),
          success: true,
          error: undefined
        };

        logger.info(`Successfully rented energy. TX: ${rentalResponse.transactionId}, Cost: ${rentalResponse.cost} TRX`);
        return rentalResponse;
      } else {
        logger.error('Energy rental failed:', transaction);
        return {
          transactionId: '',
          cost: 0,
          expiresAt: new Date(),
          success: false,
          error: transaction?.error?.message || 'Energy rental failed'
        };
      }
      
    } catch (error) {
      if (error instanceof TronZapError) {
        logger.error(`TronZap energy rental error (${error.code}): ${error.message}`);
        return {
          transactionId: '',
          cost: 0,
          expiresAt: new Date(),
          success: false,
          error: `TronZap Error ${error.code}: ${error.message}`
        };
      }
      
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
   * Note: TronZap primarily focuses on energy rental, bandwidth is less common
   */
  async rentBandwidth(
    amount: number,
    targetAddress: string,
    durationHours: number = 24
  ): Promise<TronZapRentalResponse> {
    logger.warn('TronZap primarily focuses on energy rental. Bandwidth rental not commonly supported.');
    
    // Return a failure response for bandwidth rental since TronZap mainly handles energy
    return {
      transactionId: '',
      cost: 0,
      expiresAt: new Date(),
      success: false,
      error: 'Bandwidth rental not supported by TronZap - use direct TRX burning for bandwidth'
    };
  }

  /**
   * Get rental history for an address (not supported in current TronZap SDK)
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
    logger.warn('Rental history not available in current TronZap SDK');
    return { rentals: [] };
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
      const balance = await this.client.getBalance();
      
      return {
        balance: balance.balance || 0,
        dailyRentalLimit: 0, // Not available in current SDK
        usedRentalToday: 0, // Not available in current SDK
        tier: 'standard', // Not available in current SDK
        discountRate: 0 // Not available in current SDK
      };
    } catch (error) {
      logger.error('Failed to get account balance:', error);
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