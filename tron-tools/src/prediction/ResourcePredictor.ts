import { ResourceEstimate } from '../types';
import { DEFAULT_CONFIG } from '../config/networks';
import { logger } from '../utils/logger';

export class ResourcePredictor {
  private tronWeb: any;
  private historicalData: Map<string, number[]> = new Map();
  
  // Base costs for different operation types
  private readonly BASE_COSTS = {
    transfer: { energy: 0, bandwidth: 268 },
    trc20Transfer: { energy: 14000, bandwidth: 345 },
    contractCall: { energy: 50000, bandwidth: 400 },
    contractDeploy: { energy: 100000, bandwidth: 1000 },
    createAccount: { energy: 0, bandwidth: 300 },
    freezeBalance: { energy: 0, bandwidth: 357 }
  };

  // Instruction costs (approximate energy costs for different operations)
  private readonly INSTRUCTION_COSTS = {
    SLOAD: 200,      // Storage load
    SSTORE: 20000,   // Storage store (new)  
    SSTORE_UPDATE: 5000, // Storage update
    CALL: 700,       // External call
    CREATE: 32000,   // Contract creation
    SHA3: 60,        // Hash function
    BALANCE: 400,    // Balance query
    EXTCODESIZE: 700, // Code size query
    EXTCODECOPY: 700, // Code copy
    LOG: 375,        // Event log
    JUMP: 8,         // Jump instruction
    ADD: 3,          // Arithmetic
    MUL: 5,          // Multiplication
    DIV: 5,          // Division
    MOD: 5           // Modulo
  };

  constructor(tronWeb: any) {
    this.tronWeb = tronWeb;
  }

  /**
   * Predicts resource consumption for a transaction
   */
  async predictTransaction(
    to: string,
    data?: string,
    value?: number,
    operationType: keyof typeof this.BASE_COSTS = 'contractCall'
  ): Promise<ResourceEstimate> {
    try {
      logger.debug(`Predicting resources for ${operationType} transaction`);

      const baseCost = this.BASE_COSTS[operationType];
      let energyEstimate = baseCost.energy;
      let bandwidthEstimate = baseCost.bandwidth;

      // Analyze contract bytecode if available
      if (data && data.length > 0) {
        const analysisResult = this.analyzeContractBytecode(data);
        energyEstimate += analysisResult.estimatedEnergy;
        bandwidthEstimate += Math.floor(data.length / 2); // 2 hex chars = 1 byte
      }

      // Check if target is a contract
      if (this.tronWeb.isAddress(to)) {
        try {
          const contract = await this.tronWeb.trx.getContract(to);
          if (contract && contract.bytecode) {
            // Add complexity factor for existing contracts
            energyEstimate += this.estimateContractComplexity(contract.bytecode);
          }
        } catch (error) {
          // Address might not be a contract, continue with base estimate
          logger.debug('Could not fetch contract info, using base estimates');
        }
      }

      // Apply historical adjustments if available
      const historicalKey = `${operationType}-${to}`;
      if (this.historicalData.has(historicalKey)) {
        const history = this.historicalData.get(historicalKey)!;
        const avgHistorical = history.reduce((a, b) => a + b) / history.length;
        energyEstimate = Math.floor((energyEstimate + avgHistorical) / 2);
      }

      // Calculate costs in TRX
      const energyCostTRX = this.calculateEnergyCost(energyEstimate);
      const bandwidthCostTRX = this.calculateBandwidthCost(bandwidthEstimate);
      const totalCostTRX = energyCostTRX + bandwidthCostTRX;

      // Calculate confidence based on historical data availability
      const confidence = this.calculateConfidence(operationType, historicalKey);

      const estimate: ResourceEstimate = {
        energy: energyEstimate,
        bandwidth: bandwidthEstimate,
        energyCostTRX,
        bandwidthCostTRX,
        totalCostTRX,
        confidence
      };

      logger.info(`Resource prediction: ${JSON.stringify(estimate)}`);
      return estimate;

    } catch (error) {
      logger.error('Failed to predict transaction resources:', error);
      
      // Return conservative fallback estimate
      const fallback = this.BASE_COSTS[operationType];
      return {
        energy: fallback.energy * 2, // Conservative multiplier
        bandwidth: fallback.bandwidth * 1.5,
        energyCostTRX: this.calculateEnergyCost(fallback.energy * 2),
        bandwidthCostTRX: this.calculateBandwidthCost(fallback.bandwidth * 1.5),
        totalCostTRX: 0, // Will be calculated
        confidence: 0.3 // Low confidence for fallback
      };
    }
  }

  /**
   * Predicts resources for contract deployment
   */
  async predictContractDeployment(
    bytecode: string,
    constructorParams?: any[],
    constructorAbi?: any[]
  ): Promise<ResourceEstimate> {
    try {
      logger.debug('Predicting contract deployment resources');

      const baseDeployment = this.BASE_COSTS.contractDeploy;
      let energyEstimate = baseDeployment.energy;
      let bandwidthEstimate = baseDeployment.bandwidth;

      // Analyze deployment bytecode
      const bytecodeAnalysis = this.analyzeContractBytecode(bytecode);
      energyEstimate += bytecodeAnalysis.estimatedEnergy;
      bandwidthEstimate += Math.floor(bytecode.length / 2); // Bytecode size

      // Constructor parameters add to bandwidth
      if (constructorParams && constructorParams.length > 0) {
        try {
          const encodedParams = this.tronWeb.utils.abi.encodeParams(
            constructorAbi?.map(param => param.type) || [],
            constructorParams
          );
          bandwidthEstimate += Math.floor(encodedParams.length / 2);
          energyEstimate += constructorParams.length * 1000; // Rough estimate per param
        } catch (error) {
          logger.warn('Could not encode constructor params for estimation');
        }
      }

      // Apply deployment complexity multiplier
      const complexityMultiplier = this.getDeploymentComplexityMultiplier(bytecode);
      energyEstimate = Math.floor(energyEstimate * complexityMultiplier);

      const energyCostTRX = this.calculateEnergyCost(energyEstimate);
      const bandwidthCostTRX = this.calculateBandwidthCost(bandwidthEstimate);
      const totalCostTRX = energyCostTRX + bandwidthCostTRX;

      return {
        energy: energyEstimate,
        bandwidth: bandwidthEstimate,
        energyCostTRX,
        bandwidthCostTRX,
        totalCostTRX,
        confidence: 0.8 // High confidence for deployments
      };

    } catch (error) {
      logger.error('Failed to predict deployment resources:', error);
      throw error;
    }
  }

  /**
   * Analyzes contract bytecode to estimate complexity
   */
  private analyzeContractBytecode(bytecode: string): { estimatedEnergy: number } {
    let estimatedEnergy = 0;
    
    // Count different instruction patterns (simplified heuristic)
    const instructions = bytecode.match(/.{1,2}/g) || [];
    
    for (const instruction of instructions) {
      const opcode = parseInt(instruction, 16);
      
      // Map opcodes to instruction types (simplified mapping)
      if (opcode >= 0x54 && opcode <= 0x55) {
        // SLOAD, SSTORE
        estimatedEnergy += this.INSTRUCTION_COSTS.SLOAD;
      } else if (opcode >= 0xF0 && opcode <= 0xF5) {
        // CREATE, CALL, etc.
        estimatedEnergy += this.INSTRUCTION_COSTS.CALL;
      } else if (opcode >= 0x20 && opcode <= 0x20) {
        // SHA3
        estimatedEnergy += this.INSTRUCTION_COSTS.SHA3;
      } else {
        // Basic operations
        estimatedEnergy += 3;
      }
    }

    return { estimatedEnergy: Math.floor(estimatedEnergy * 0.1) }; // Scale down
  }

  /**
   * Estimates contract complexity based on bytecode size and patterns
   */
  private estimateContractComplexity(bytecode: string): number {
    const size = bytecode.length / 2; // Convert hex to bytes
    
    if (size < 1000) return 5000;      // Simple contract
    if (size < 5000) return 15000;     // Medium contract  
    if (size < 20000) return 30000;    // Complex contract
    return 50000;                      // Very complex contract
  }

  /**
   * Gets deployment complexity multiplier based on bytecode analysis
   */
  private getDeploymentComplexityMultiplier(bytecode: string): number {
    const size = bytecode.length / 2;
    
    // Base multiplier
    let multiplier = 1.0;
    
    // Size factor
    if (size > 10000) multiplier += 0.5;
    if (size > 20000) multiplier += 0.5;
    
    // Pattern analysis (look for complex operations)
    const complexPatterns = [
      '54', '55', // SLOAD, SSTORE
      'f0', 'f1', 'f2', 'f4', // CREATE, CALL, CALLCODE, DELEGATECALL
      '20' // SHA3
    ];
    
    for (const pattern of complexPatterns) {
      const count = (bytecode.match(new RegExp(pattern, 'gi')) || []).length;
      multiplier += count * 0.01;
    }
    
    return Math.min(multiplier, 2.0); // Cap at 2x
  }

  /**
   * Calculates energy cost in TRX
   */
  private calculateEnergyCost(energy: number): number {
    const costInSun = energy * DEFAULT_CONFIG.energyPriceSun;
    return this.tronWeb.fromSun(costInSun);
  }

  /**
   * Calculates bandwidth cost in TRX
   */
  private calculateBandwidthCost(bandwidth: number): number {
    // Bandwidth is typically free up to daily limit, then 1000 SUN per byte
    const costInSun = bandwidth * 1000;
    return this.tronWeb.fromSun(costInSun);
  }

  /**
   * Calculates prediction confidence score
   */
  private calculateConfidence(
    operationType: string,
    historicalKey: string
  ): number {
    let confidence = 0.5; // Base confidence
    
    // Increase confidence based on operation type familiarity
    switch (operationType) {
      case 'transfer':
        confidence = 0.95;
        break;
      case 'trc20Transfer':
        confidence = 0.90;
        break;
      case 'contractCall':
        confidence = 0.70;
        break;
      case 'contractDeploy':
        confidence = 0.80;
        break;
      default:
        confidence = 0.60;
    }

    // Adjust based on historical data availability
    if (this.historicalData.has(historicalKey)) {
      const historyCount = this.historicalData.get(historicalKey)!.length;
      if (historyCount >= 10) confidence += 0.2;
      else if (historyCount >= 5) confidence += 0.1;
    } else {
      confidence -= 0.1; // Reduce if no historical data
    }

    return Math.min(confidence, 1.0);
  }

  /**
   * Records actual resource usage for learning
   */
  recordActualUsage(
    operationType: string,
    targetAddress: string,
    actualEnergy: number
  ): void {
    const key = `${operationType}-${targetAddress}`;
    
    if (!this.historicalData.has(key)) {
      this.historicalData.set(key, []);
    }
    
    const history = this.historicalData.get(key)!;
    history.push(actualEnergy);
    
    // Keep only last 50 records to prevent memory bloat
    if (history.length > 50) {
      history.shift();
    }
    
    logger.debug(`Recorded actual usage for ${key}: ${actualEnergy} energy`);
  }

  /**
   * Gets prediction statistics
   */
  getStatistics(): any {
    return {
      totalPredictions: this.historicalData.size,
      averageAccuracy: this.calculateAverageAccuracy(),
      mostPredictedOperations: this.getMostPredictedOperations()
    };
  }

  private calculateAverageAccuracy(): number {
    // Simplified accuracy calculation
    // In a real implementation, you'd track prediction vs actual
    return 0.85; // Placeholder
  }

  private getMostPredictedOperations(): string[] {
    return Array.from(this.historicalData.keys())
      .sort((a, b) => this.historicalData.get(b)!.length - this.historicalData.get(a)!.length)
      .slice(0, 5);
  }
}