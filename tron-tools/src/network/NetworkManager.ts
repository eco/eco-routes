const TronWeb = require('tronweb');
import { TronNetwork, NetworkHealth } from '../types';
import { TRON_NETWORKS } from '../config/networks';
import { logger } from '../utils/logger';

export class NetworkManager {
  private currentNetwork: TronNetwork;
  private tronWeb: any;
  private healthCache: Map<string, NetworkHealth> = new Map();
  private readonly HEALTH_CACHE_TTL = 60000; // 1 minute

  constructor(networkName: string = 'testnet') {
    this.currentNetwork = TRON_NETWORKS[networkName];
    if (!this.currentNetwork) {
      throw new Error(`Unknown network: ${networkName}`);
    }
    this.initializeTronWeb();
  }

  private initializeTronWeb() {
    const { rpcUrl, apiKey } = this.currentNetwork;
    
    // Create TronWeb instance with API key if available
    const headers = apiKey ? { 'TRON-PRO-API-KEY': apiKey } : {};
    
    this.tronWeb = new TronWeb({
      fullHost: rpcUrl,
      headers,
      solidityNode: rpcUrl,
      eventServer: rpcUrl
    });

    logger.info(`Initialized TronWeb for ${this.currentNetwork.name}`);
  }

  async switchNetwork(networkName: string): Promise<void> {
    const network = TRON_NETWORKS[networkName];
    if (!network) {
      throw new Error(`Unknown network: ${networkName}`);
    }

    this.currentNetwork = network;
    this.initializeTronWeb();
    
    logger.info(`Switched to network: ${network.name}`);
  }

  async checkNetworkHealth(): Promise<NetworkHealth> {
    const cacheKey = this.currentNetwork.name;
    const cached = this.healthCache.get(cacheKey);
    
    if (cached && Date.now() - cached.lastChecked.getTime() < this.HEALTH_CACHE_TTL) {
      return cached;
    }

    const startTime = Date.now();
    
    try {
      const blockInfo = await this.tronWeb.trx.getCurrentBlock();
      const nodeInfo = await this.tronWeb.trx.getNodeInfo();
      
      const responseTime = Date.now() - startTime;
      
      const health: NetworkHealth = {
        blockHeight: blockInfo.block_header.raw_data.number,
        peersConnected: nodeInfo.peerList?.length || 0,
        avgBlockTime: 3000, // Tron ~3 second blocks
        isHealthy: responseTime < 5000 && blockInfo.block_header.raw_data.number > 0,
        lastChecked: new Date(),
        responseTime
      };

      this.healthCache.set(cacheKey, health);
      
      if (health.isHealthy) {
        logger.debug(`Network health check passed for ${this.currentNetwork.name}`);
      } else {
        logger.warn(`Network health check failed for ${this.currentNetwork.name}`);
      }

      return health;
    } catch (error) {
      logger.error(`Network health check error:`, error);
      
      const health: NetworkHealth = {
        blockHeight: 0,
        peersConnected: 0,
        avgBlockTime: 0,
        isHealthy: false,
        lastChecked: new Date(),
        responseTime: Date.now() - startTime
      };

      return health;
    }
  }

  async tryFallbackRpc(): Promise<boolean> {
    if (!this.currentNetwork.fallbackUrls) {
      return false;
    }

    for (const fallbackUrl of this.currentNetwork.fallbackUrls) {
      try {
        logger.info(`Trying fallback RPC: ${fallbackUrl}`);
        
        const fallbackTronWeb = new TronWeb({
          fullHost: fallbackUrl,
          solidityNode: fallbackUrl,
          eventServer: fallbackUrl
        });

        // Test the connection
        await fallbackTronWeb.trx.getCurrentBlock();
        
        // If successful, update the current instance
        this.currentNetwork.rpcUrl = fallbackUrl;
        this.tronWeb = fallbackTronWeb;
        
        logger.info(`Successfully switched to fallback RPC: ${fallbackUrl}`);
        return true;
      } catch (error) {
        logger.warn(`Fallback RPC failed: ${fallbackUrl}`, error);
        continue;
      }
    }

    return false;
  }

  getCurrentNetwork(): TronNetwork {
    return this.currentNetwork;
  }

  getTronWeb(): any {
    return this.tronWeb;
  }

  isMainnet(): boolean {
    return this.currentNetwork.isMainnet;
  }

  getNetworkName(): string {
    return this.currentNetwork.name;
  }

  async getBlockHeight(): Promise<number> {
    try {
      const block = await this.tronWeb.trx.getCurrentBlock();
      return block.block_header.raw_data.number;
    } catch (error) {
      logger.error('Failed to get block height:', error);
      throw error;
    }
  }

  async getChainId(): Promise<string> {
    return this.currentNetwork.chainId;
  }
}