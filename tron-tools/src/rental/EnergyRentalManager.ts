import { logger } from '../utils/logger';
import { TronZapClient } from './TronZapClient';

export interface EnergyRentalOptions {
  requiredEnergy: number;
  requiredBandwidth: number;
  currentEnergy: number;
  currentBandwidth: number;
  currentTrxBalance: number;
  recipientAddress: string;
  network: 'mainnet' | 'testnet';
}

export interface EnergyRentalResult {
  success: boolean;
  rentedEnergy: number;
  rentedBandwidth: number;
  totalCostTrx: number;
  message: string;
  energyRentalTxId?: string;
  bandwidthRentalTxId?: string;
}

export class EnergyRentalManager {
  private tronZapClient: TronZapClient;

  constructor(tronZapClient: TronZapClient) {
    this.tronZapClient = tronZapClient;
  }

  /**
   * Checks if energy rental is needed and affordable, then performs rental if possible
   */
  async ensureSufficientEnergy(options: EnergyRentalOptions): Promise<EnergyRentalResult> {
    const {
      requiredEnergy,
      requiredBandwidth,
      currentEnergy,
      currentBandwidth,
      currentTrxBalance,
      recipientAddress,
      network
    } = options;

    // Calculate deficits
    const energyDeficit = Math.max(0, requiredEnergy - currentEnergy);
    const bandwidthDeficit = Math.max(0, requiredBandwidth - currentBandwidth);

    logger.info(`Energy analysis: Required ${requiredEnergy.toLocaleString()}, Available ${currentEnergy.toLocaleString()}, Deficit ${energyDeficit.toLocaleString()}`);
    logger.info(`Bandwidth analysis: Required ${requiredBandwidth.toLocaleString()}, Available ${currentBandwidth.toLocaleString()}, Deficit ${bandwidthDeficit.toLocaleString()}`);

    // If sufficient resources, no rental needed
    if (energyDeficit === 0 && bandwidthDeficit === 0) {
      return {
        success: true,
        rentedEnergy: 0,
        rentedBandwidth: 0,
        totalCostTrx: 0,
        message: 'Sufficient energy and bandwidth available, no rental needed'
      };
    }

    // On testnet, skip rental (allow direct TRX burning)
    if (network === 'testnet') {
      return {
        success: true,
        rentedEnergy: 0,
        rentedBandwidth: 0,
        totalCostTrx: 0,
        message: 'Testnet deployment: Skipping TronZap rental, will use direct TRX payment'
      };
    }

    // On mainnet, check if energy rental is needed (expensive)
    if (energyDeficit > 0) {
      logger.info('Energy deficit detected on mainnet - checking TronZap rental affordability');
      
      try {
        // Get current TronZap rental prices
        const prices = await this.tronZapClient.getRentalPrices();
        const energyPrice = prices.energy.pricePerUnit;
        const bandwidthPrice = prices.bandwidth.pricePerUnit;
        
        logger.info(`TronZap rates: Energy ${energyPrice.toFixed(8)} TRX/unit, Bandwidth ${bandwidthPrice.toFixed(8)} TRX/unit`);

        // Calculate rental costs
        const energyCost = energyDeficit * energyPrice;
        const bandwidthCost = bandwidthDeficit * bandwidthPrice;
        const totalCost = energyCost + bandwidthCost;

        logger.info(`Rental cost breakdown: Energy ${energyCost.toFixed(6)} TRX, Bandwidth ${bandwidthCost.toFixed(6)} TRX, Total ${totalCost.toFixed(6)} TRX`);

        // Check if we have enough TRX to afford the rental
        if (currentTrxBalance < totalCost) {
          return {
            success: false,
            rentedEnergy: 0,
            rentedBandwidth: 0,
            totalCostTrx: totalCost,
            message: `Insufficient TRX for energy rental. Need ${totalCost.toFixed(6)} TRX, have ${currentTrxBalance.toFixed(6)} TRX. Shortfall: ${(totalCost - currentTrxBalance).toFixed(6)} TRX`
          };
        }

        // Attempt to rent resources
        logger.info('TRX balance sufficient for rental, attempting to rent resources...');
        
        let energyRentalTxId: string | undefined;
        let bandwidthRentalTxId: string | undefined;
        let actualEnergyCost = 0;
        let actualBandwidthCost = 0;

        // Rent energy if needed
        if (energyDeficit > 0) {
          logger.info(`Renting ${energyDeficit.toLocaleString()} energy...`);
          const energyRental = await this.tronZapClient.rentEnergy(energyDeficit, recipientAddress);
          
          if (energyRental.success) {
            energyRentalTxId = energyRental.transactionId;
            actualEnergyCost = energyRental.cost;
            logger.info(`Energy rental successful: TX ${energyRentalTxId}, Cost ${actualEnergyCost.toFixed(6)} TRX`);
          } else {
            return {
              success: false,
              rentedEnergy: 0,
              rentedBandwidth: 0,
              totalCostTrx: totalCost,
              message: `Energy rental failed: ${energyRental.error || 'Unknown error'}`
            };
          }
        }

        // Rent bandwidth if needed (less critical, can fall back to TRX burning)
        if (bandwidthDeficit > 0) {
          logger.info(`Renting ${bandwidthDeficit.toLocaleString()} bandwidth...`);
          try {
            const bandwidthRental = await this.tronZapClient.rentBandwidth(bandwidthDeficit, recipientAddress);
            
            if (bandwidthRental.success) {
              bandwidthRentalTxId = bandwidthRental.transactionId;
              actualBandwidthCost = bandwidthRental.cost;
              logger.info(`Bandwidth rental successful: TX ${bandwidthRentalTxId}, Cost ${actualBandwidthCost.toFixed(6)} TRX`);
            } else {
              logger.warn(`Bandwidth rental failed: ${bandwidthRental.error}. Will use direct TRX burning for bandwidth.`);
            }
          } catch (error) {
            logger.warn(`Bandwidth rental error: ${error}. Will use direct TRX burning for bandwidth.`);
          }
        }

        return {
          success: true,
          rentedEnergy: energyDeficit,
          rentedBandwidth: bandwidthRentalTxId ? bandwidthDeficit : 0,
          totalCostTrx: actualEnergyCost + actualBandwidthCost,
          message: `Successfully rented resources. Energy: ${energyDeficit.toLocaleString()}, Bandwidth: ${bandwidthRentalTxId ? bandwidthDeficit.toLocaleString() : '0 (will burn TRX)'}`,
          energyRentalTxId,
          bandwidthRentalTxId
        };

      } catch (error) {
        logger.error('Failed to get TronZap rental prices:', error);
        
        return {
          success: false,
          rentedEnergy: 0,
          rentedBandwidth: 0,
          totalCostTrx: 0,
          message: `Failed to check TronZap rental prices: ${error}. Cannot proceed with mainnet deployment without energy rental capability.`
        };
      }

    } else {
      // Only bandwidth deficit on mainnet (energy is sufficient)
      logger.info('Energy sufficient, only bandwidth rental needed on mainnet');
      
      try {
        const prices = await this.tronZapClient.getRentalPrices();
        const bandwidthPrice = prices.bandwidth.pricePerUnit;
        const bandwidthCost = bandwidthDeficit * bandwidthPrice;

        if (currentTrxBalance >= bandwidthCost) {
          const bandwidthRental = await this.tronZapClient.rentBandwidth(bandwidthDeficit, recipientAddress);
          
          if (bandwidthRental.success) {
            return {
              success: true,
              rentedEnergy: 0,
              rentedBandwidth: bandwidthDeficit,
              totalCostTrx: bandwidthRental.cost,
              message: `Successfully rented ${bandwidthDeficit.toLocaleString()} bandwidth`,
              bandwidthRentalTxId: bandwidthRental.transactionId
            };
          }
        }
        
        // Bandwidth rental failed or not affordable - acceptable to burn TRX for bandwidth
        logger.warn('Bandwidth rental failed or not affordable. Will use direct TRX burning for bandwidth.');
        return {
          success: true,
          rentedEnergy: 0,
          rentedBandwidth: 0,
          totalCostTrx: 0,
          message: 'Energy sufficient. Bandwidth rental failed, will use direct TRX burning for bandwidth (acceptable cost).'
        };

      } catch (error) {
        logger.warn('Bandwidth rental check failed:', error);
        return {
          success: true,
          rentedEnergy: 0,
          rentedBandwidth: 0,
          totalCostTrx: 0,
          message: 'Energy sufficient. Bandwidth rental unavailable, will use direct TRX burning for bandwidth.'
        };
      }
    }
  }

  /**
   * Verifies that sufficient energy is available after rental
   */
  async verifyEnergyAfterRental(
    requiredEnergy: number,
    requiredBandwidth: number,
    getAccountResources: () => Promise<{ energy: { available: number }, bandwidth: { available: number } }>
  ): Promise<{ success: boolean; message: string; availableEnergy: number; availableBandwidth: number }> {
    
    logger.info('Verifying energy levels after rental...');
    
    const resources = await getAccountResources();
    const availableEnergy = resources.energy.available;
    const availableBandwidth = resources.bandwidth.available;
    
    logger.info(`Post-rental resources: Energy ${availableEnergy.toLocaleString()}, Bandwidth ${availableBandwidth.toLocaleString()}`);
    logger.info(`Required resources: Energy ${requiredEnergy.toLocaleString()}, Bandwidth ${requiredBandwidth.toLocaleString()}`);

    const energyShortfall = Math.max(0, requiredEnergy - availableEnergy);
    const bandwidthShortfall = Math.max(0, requiredBandwidth - availableBandwidth);

    if (energyShortfall > 0) {
      return {
        success: false,
        message: `Energy verification failed! Still need ${energyShortfall.toLocaleString()} more energy. Rental may have failed or been insufficient.`,
        availableEnergy,
        availableBandwidth
      };
    }

    if (bandwidthShortfall > 0) {
      logger.info(`Bandwidth shortfall: ${bandwidthShortfall.toLocaleString()} - will use direct TRX burning`);
    }

    return {
      success: true,
      message: `Energy verification passed! Available: ${availableEnergy.toLocaleString()} energy, ${availableBandwidth.toLocaleString()} bandwidth`,
      availableEnergy,
      availableBandwidth
    };
  }

  /**
   * Gets current energy rental price from TronZap
   */
  async getEnergyPrice(): Promise<number> {
    const prices = await this.tronZapClient.getRentalPrices();
    return prices.energy.pricePerUnit;
  }

  /**
   * Gets current bandwidth rental price from TronZap
   */
  async getBandwidthPrice(): Promise<number> {
    const prices = await this.tronZapClient.getRentalPrices();
    return prices.bandwidth.pricePerUnit;
  }
}