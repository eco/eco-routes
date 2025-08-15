import { TronToolkit } from '../dist/TronToolkit.js'
import { logger } from '../dist/utils/logger.js'
import { config } from 'dotenv'

// Load environment variables from parent directory
config({ path: '../.env' })


/**
 * Configuration parameters for LayerZero ULN (Ultra Light Node)
 * Based on the SetUlnLZ.s.sol script
 */
interface UlnConfig {
  confirmations: number
  requiredDVNCount: number
  optionalDVNCount: number
  optionalDVNThreshold: number
  requiredDVNs: string[]
  optionalDVNs: string[]
}

interface SetConfigParam {
  eid: number
  configType: number
  config: string
}

/**
 * Script to configure LayerZeroProver with ULN settings on Tron
 * Uses triggerSmartContract for all transactions to avoid calldata truncation issues
 */
class LayerZeroProverConfig {
  private toolkit: TronToolkit

  // Configuration constants (update these for your deployment)
  private readonly ULN_CONFIG_TYPE = 2
  private readonly CONFIG_TYPE_EXECUTOR = 1

  // DVN configuration
  private readonly REQUIRED_DVN_COUNT = 1
  private readonly OPTIONAL_DVN_COUNT = 0
  private readonly OPTIONAL_DVN_THRESHOLD = 0

  // Executor configuration
  private readonly EXECUTOR_GAS_LIMIT = 800000
  private readonly EXECUTOR_VALUE = 0

  // Chain configuration - Update these for your specific setup
  private readonly TRON_EID = 30420 // Tron chain endpoint ID
  private readonly OPTIMISM_EID = 30111 // Optimism chain endpoint ID
  private readonly SEND_CONFIRMATIONS = 15
  private readonly RECEIVE_CONFIRMATIONS = 10

  // Contract addresses - Update with your actual deployed addresses
  private readonly LAYERZERO_PROVER_ADDRESS =
    process.env.TRON_LAYERZERO_PROVER || 'TVaUrbN3cm6xxvi4e1fc1jUhs19mbtLEd7' // From deployment

  private readonly DVN_ADDRESS =
    process.env.DVN_ADDRESS || 'TNiB7ybFhyLDaW6JAM2BP9QQrAfncwbCyG' // layerzero labs

  private readonly ENDPOINT_ADDRESS =
    process.env.TRON_ENDPOINT_ADDRESS || 'TAy9xwjYjBBN6kutzrZJaAZJHCAejjK1V9' // Tron LayerZero Endpoint (base58)

  private readonly SEND_LIB_ADDRESS =
    process.env.SEND_LIB_ADDRESS || 'TWhf9vzMEGmWjn538ymX76sgGN3LxG7mQJ'

  private readonly RECEIVE_LIB_ADDRESS =
    process.env.RECEIVE_LIB_ADDRESS || 'TJpoNxF3CreFRpTdLhyXuJzEo4vMAns7Wz' // Receive library (can be different)

  private readonly EXECUTOR_ADDRESS =
    process.env.EXECUTOR_ADDRESS || 'TKSQrCn9r7jdNxWuQGRw8RJT8x4LFNfr7B' // LayerZero Executor

  private readonly PRIVATE_KEY = process.env.TRON_PRIVATE_KEY!
  private readonly ENERGY_RENTAL_ENABLED = process.env.ENABLE_ENERGY_RENTAL === 'true'

  constructor(networkName: string = 'mainnet') {
    if (!this.PRIVATE_KEY) {
      throw new Error('TRON_PRIVATE_KEY environment variable is required')
    }

    this.toolkit = new TronToolkit({
      network: networkName as 'mainnet' | 'testnet',
      privateKey: this.PRIVATE_KEY,
    })
  }

  /**
   * Execute a transaction using triggerSmartContract strategy
   */
  private async executeTriggerSmartContract(
    contractAddress: string,
    functionSignature: string,
    parameters: any[],
    feeLimit: number = 150000000
  ): Promise<string> {
    const tronWeb = this.toolkit.getTronWeb()

    try {
      // Build the transaction using triggerSmartContract
      const transaction = await tronWeb.transactionBuilder.triggerSmartContract(
        contractAddress,
        functionSignature,
        {
          feeLimit,
          callValue: 0,
        },
        parameters,
        tronWeb.defaultAddress.base58
      )

      logger.info('Transaction built successfully')
      logger.info('Raw transaction hex:', transaction.transaction.raw_data_hex)

      if (transaction.result && transaction.result.result) {
        // Sign and broadcast the transaction
        const signedTx = await tronWeb.trx.sign(transaction.transaction)
        const result = await tronWeb.trx.sendRawTransaction(signedTx)

        if (result.result) {
          logger.info('Transaction broadcast successful')
          return result.txid
        } else {
          throw new Error(`Transaction broadcast failed: ${JSON.stringify(result)}`)
        }
      } else {
        throw new Error(`Transaction build failed: ${JSON.stringify(transaction)}`)
      }
    } catch (error) {
      logger.error('triggerSmartContract execution failed:', error)
      throw error
    }
  }

  /**
   * Configure send library for LayerZero endpoint
   */
  async setSendLibrary(): Promise<void> {
    try {
      logger.info('=== Setting Send Library ===')
      logger.info(`LayerZero Prover Address: ${this.LAYERZERO_PROVER_ADDRESS}`)
      logger.info(`Destination EID: ${this.OPTIMISM_EID}`)
      logger.info(`Send Library Address: ${this.SEND_LIB_ADDRESS}`)


      // Check energy if rental is disabled
      if (!this.ENERGY_RENTAL_ENABLED) {
        const energyNeeded = await this.estimateLibraryEnergy('setSendLibrary')
        const tronWeb = this.toolkit.getTronWeb()
        const resources = await this.toolkit.getAccountResources()
        
        if (resources.energy.available < energyNeeded) {
          throw new Error(`Insufficient energy: need ${energyNeeded}, have ${resources.energy.available}`)
        }
      }

      // Execute using triggerSmartContract
      const txid = await this.executeTriggerSmartContract(
        this.ENDPOINT_ADDRESS,
        'setSendLibrary(address,uint32,address)',
        [
          { type: 'address', value: this.LAYERZERO_PROVER_ADDRESS },
          { type: 'uint32', value: this.OPTIMISM_EID },
          { type: 'address', value: this.SEND_LIB_ADDRESS }
        ]
      )

      logger.info('Send library configuration completed successfully!')
      logger.info(`Transaction ID: ${txid}`)
    } catch (error) {
      logger.error('=== SEND LIBRARY SETUP FAILED ===')
      logger.error('Error details:', error)
      throw error
    }
  }

  /**
   * Configure receive library for LayerZero endpoint
   */
  async setReceiveLibrary(): Promise<void> {
    try {
      logger.info('=== Setting Receive Library ===')
      logger.info(`LayerZero Prover Address: ${this.LAYERZERO_PROVER_ADDRESS}`)
      logger.info(`Receive Library Address: ${this.RECEIVE_LIB_ADDRESS}`)

      // Grace period for library transition (24 hours = 86400 seconds)
      const gracePeriod = 86400


      // Check energy if rental is disabled
      if (!this.ENERGY_RENTAL_ENABLED) {
        const energyNeeded = await this.estimateLibraryEnergy('setReceiveLibrary')
        const tronWeb = this.toolkit.getTronWeb()
        const resources = await this.toolkit.getAccountResources()
        
        if (resources.energy.available < energyNeeded) {
          throw new Error(`Insufficient energy: need ${energyNeeded}, have ${resources.energy.available}`)
        }
      }

      // Execute using triggerSmartContract
      const txid = await this.executeTriggerSmartContract(
        this.ENDPOINT_ADDRESS,
        'setReceiveLibrary(address,uint32,address,uint256)',
        [
          { type: 'address', value: this.LAYERZERO_PROVER_ADDRESS },
          { type: 'uint32', value: this.OPTIMISM_EID },
          { type: 'address', value: this.RECEIVE_LIB_ADDRESS },
          { type: 'uint256', value: gracePeriod }
        ]
      )

      logger.info('Receive library configuration completed successfully!')
      logger.info(`Transaction ID: ${txid}, Grace Period: ${gracePeriod}s`)
    } catch (error) {
      logger.error('=== RECEIVE LIBRARY SETUP FAILED ===')
      logger.error('Error details:', error)
      throw error
    }
  }

  /**
   * Configure executor for LayerZero endpoint
   */
  async setExecutor(): Promise<void> {
    try {
      logger.info('=== Setting Executor Configuration ===')
      logger.info(`LayerZero Prover Address: ${this.LAYERZERO_PROVER_ADDRESS}`)
      logger.info(`Send Library Address: ${this.SEND_LIB_ADDRESS}`)
      logger.info(`Executor Address: ${this.EXECUTOR_ADDRESS}`)
      logger.info(`Gas Limit: ${this.EXECUTOR_GAS_LIMIT}, Value: ${this.EXECUTOR_VALUE}`)

      const tronWeb = this.toolkit.getTronWeb()

      // Create executor configuration
      const executorConfig = tronWeb.utils.abi.encodeParams(
        ['uint128', 'uint128'],
        [this.EXECUTOR_GAS_LIMIT, this.EXECUTOR_VALUE],
      )

      // Convert executor address to Ethereum-style hex for ABI encoding
      const tronHex = tronWeb.address.toHex(this.EXECUTOR_ADDRESS)
      const executorAddressHex = '0x' + tronHex.substring(2)

      // abi.encode(executorAddress, executorConfig)
      const fullExecutorConfig = tronWeb.utils.abi.encodeParams(
        ['address', 'bytes'],
        [executorAddressHex, executorConfig],
      )

      // Create SetConfigParam for executor
      const setConfigParams: SetConfigParam[] = [
        {
          eid: this.OPTIMISM_EID,
          configType: this.CONFIG_TYPE_EXECUTOR,
          config: fullExecutorConfig,
        },
      ]


      // Check energy if rental is disabled
      if (!this.ENERGY_RENTAL_ENABLED) {
        const energyNeeded = await this.estimateConfigEnergy(setConfigParams)
        const tronWeb = this.toolkit.getTronWeb()
        const resources = await this.toolkit.getAccountResources()
        
        if (resources.energy.available < energyNeeded) {
          throw new Error(`Insufficient energy: need ${energyNeeded}, have ${resources.energy.available}`)
        }
      }

      // Execute using triggerSmartContract
      const txid = await this.executeTriggerSmartContract(
        this.ENDPOINT_ADDRESS,
        'setConfig(address,address,(uint32,uint32,bytes)[])',
        [
          { type: 'address', value: this.LAYERZERO_PROVER_ADDRESS },
          { type: 'address', value: this.SEND_LIB_ADDRESS },
          { 
            type: '(uint32,uint32,bytes)[]', 
            value: setConfigParams.map(p => [p.eid, p.configType, p.config])
          }
        ]
      )

      logger.info('Executor configuration completed successfully!')
      logger.info(`Transaction ID: ${txid}`)
    } catch (error) {
      logger.error('=== EXECUTOR CONFIGURATION FAILED ===')
      logger.error('Error details:', error)
      throw error
    }
  }

  /**
   * Configure send ULN settings for cross-chain communication
   */
  async configureSend(): Promise<void> {
    try {
      logger.info('=== Configuring Send DVN ===')
      logger.info(`LayerZero Prover Address: ${this.LAYERZERO_PROVER_ADDRESS}`)
      logger.info(`Destination EID: ${this.OPTIMISM_EID}`)
      logger.info(`DVN Address: ${this.DVN_ADDRESS}`)
      logger.info(`Send Confirmations: ${this.SEND_CONFIRMATIONS}`)

      // Create ULN configuration
      const ulnConfig: UlnConfig = {
        confirmations: this.SEND_CONFIRMATIONS,
        requiredDVNCount: this.REQUIRED_DVN_COUNT,
        optionalDVNCount: this.OPTIONAL_DVN_COUNT,
        optionalDVNThreshold: this.OPTIONAL_DVN_THRESHOLD,
        requiredDVNs: [this.DVN_ADDRESS],
        optionalDVNs: [],
      }

      // Encode ULN config using TronWeb's ABI encoding
      const tronWeb = this.toolkit.getTronWeb()

      // Convert base58 addresses to Ethereum-style hex for ABI encoding
      const requiredDVNsHex = ulnConfig.requiredDVNs.map((addr) => {
        const tronHex = tronWeb.address.toHex(addr)
        return '0x' + tronHex.substring(2)
      })
      const optionalDVNsHex = ulnConfig.optionalDVNs.map((addr) => {
        const tronHex = tronWeb.address.toHex(addr)
        return '0x' + tronHex.substring(2)
      })

      const rawEncodedConfig = tronWeb.utils.abi.encodeParams(
        ['uint64', 'uint8', 'uint8', 'uint8', 'address[]', 'address[]'],
        [
          ulnConfig.confirmations,
          ulnConfig.requiredDVNCount,
          ulnConfig.optionalDVNCount,
          ulnConfig.optionalDVNThreshold,
          requiredDVNsHex,
          optionalDVNsHex,
        ],
      )

      // Add struct offset to match Solidity's abi.encode() behavior
      const encodedUlnConfig = '0x0000000000000000000000000000000000000000000000000000000000000020' + rawEncodedConfig.substring(2)

      logger.info(`Encoded ULN Config: ${encodedUlnConfig}`)

      // Create SetConfigParam
      const setConfigParams: SetConfigParam[] = [
        {
          eid: this.OPTIMISM_EID,
          configType: this.ULN_CONFIG_TYPE,
          config: encodedUlnConfig,
        },
      ]

      // Check energy if rental is disabled
      if (!this.ENERGY_RENTAL_ENABLED) {
        const energyNeeded = await this.estimateConfigEnergy(setConfigParams)
        const tronWeb = this.toolkit.getTronWeb()
        const resources = await this.toolkit.getAccountResources()
        
        if (resources.energy.available < energyNeeded) {
          throw new Error(`Insufficient energy: need ${energyNeeded}, have ${resources.energy.available}`)
        }
      }

      // Execute using triggerSmartContract
      const txid = await this.executeTriggerSmartContract(
        this.ENDPOINT_ADDRESS,
        'setConfig(address,address,(uint32,uint32,bytes)[])',
        [
          { type: 'address', value: this.LAYERZERO_PROVER_ADDRESS },
          { type: 'address', value: this.SEND_LIB_ADDRESS },
          { 
            type: '(uint32,uint32,bytes)[]', 
            value: setConfigParams.map(p => [p.eid, p.configType, p.config])
          }
        ]
      )

      logger.info('Send DVN configuration completed successfully!')
      logger.info(`Transaction ID: ${txid}`)
    } catch (error) {
      logger.error('=== SEND DVN CONFIGURATION FAILED ===')
      logger.error('Error details:', error)
      throw error
    }
  }

  /**
   * Configure receive ULN settings for cross-chain communication
   */
  async configureReceive(): Promise<void> {
    try {
      logger.info('=== Configuring Receive DVN ===')
      logger.info(`LayerZero Prover Address: ${this.LAYERZERO_PROVER_ADDRESS}`)
      logger.info(`DVN Address: ${this.DVN_ADDRESS}`)
      logger.info(`Receive Confirmations: ${this.RECEIVE_CONFIRMATIONS}`)

      // Create ULN configuration for receive
      const ulnConfig: UlnConfig = {
        confirmations: this.RECEIVE_CONFIRMATIONS,
        requiredDVNCount: this.REQUIRED_DVN_COUNT,
        optionalDVNCount: this.OPTIONAL_DVN_COUNT,
        optionalDVNThreshold: this.OPTIONAL_DVN_THRESHOLD,
        requiredDVNs: [this.DVN_ADDRESS],
        optionalDVNs: [],
      }

      // Encode ULN config using TronWeb's ABI encoding
      const tronWeb = this.toolkit.getTronWeb()

      // Convert base58 addresses to Ethereum-style hex for ABI encoding
      const requiredDVNsHex = ulnConfig.requiredDVNs.map((addr) => {
        const tronHex = tronWeb.address.toHex(addr)
        return '0x' + tronHex.substring(2)
      })
      const optionalDVNsHex = ulnConfig.optionalDVNs.map((addr) => {
        const tronHex = tronWeb.address.toHex(addr)
        return '0x' + tronHex.substring(2)
      })

      const rawEncodedConfig = tronWeb.utils.abi.encodeParams(
        ['uint64', 'uint8', 'uint8', 'uint8', 'address[]', 'address[]'],
        [
          ulnConfig.confirmations,
          ulnConfig.requiredDVNCount,
          ulnConfig.optionalDVNCount,
          ulnConfig.optionalDVNThreshold,
          requiredDVNsHex,
          optionalDVNsHex,
        ],
      )

      // Add struct offset to match Solidity's abi.encode() behavior
      const encodedUlnConfig = '0x0000000000000000000000000000000000000000000000000000000000000020' + rawEncodedConfig.substring(2)

      logger.info(`Encoded ULN Config: ${encodedUlnConfig}`)

      // Create SetConfigParam for receive configuration
      const setConfigParams: SetConfigParam[] = [
        {
          eid: this.OPTIMISM_EID,
          configType: this.ULN_CONFIG_TYPE,
          config: encodedUlnConfig,
        },
      ]

      // Check energy if rental is disabled
      if (!this.ENERGY_RENTAL_ENABLED) {
        const energyNeeded = await this.estimateConfigEnergy(setConfigParams)
        const tronWeb = this.toolkit.getTronWeb()
        const resources = await this.toolkit.getAccountResources()
        
        if (resources.energy.available < energyNeeded) {
          throw new Error(`Insufficient energy: need ${energyNeeded}, have ${resources.energy.available}`)
        }
      }

      // Execute using triggerSmartContract - this is the method that worked!
      const txid = await this.executeTriggerSmartContract(
        this.ENDPOINT_ADDRESS,
        'setConfig(address,address,(uint32,uint32,bytes)[])',
        [
          { type: 'address', value: this.LAYERZERO_PROVER_ADDRESS },
          { type: 'address', value: this.RECEIVE_LIB_ADDRESS },
          { 
            type: '(uint32,uint32,bytes)[]', 
            value: setConfigParams.map(p => [p.eid, p.configType, p.config])
          }
        ]
      )

      logger.info('Receive DVN configuration completed successfully!')
      logger.info(`Transaction ID: ${txid}`)

    } catch (error) {
      logger.error('=== RECEIVE DVN CONFIGURATION FAILED ===')
      logger.error('Error details:', error)
      throw error
    }
  }



  /**
   * Estimate energy needed for setConfig transaction
   */
  private async estimateConfigEnergy(
    setConfigParams: SetConfigParam[],
  ): Promise<number> {
    // Based on successful transaction: 78628 energy used
    // Return 80000 for safety margin
    return 80000
  }

  /**
   * Estimate energy needed for library transactions
   */
  private async estimateLibraryEnergy(
    method: 'setSendLibrary' | 'setReceiveLibrary',
  ): Promise<number> {
    // Library operations are typically lighter than setConfig
    return 50000
  }

  /**
   * Get sender configuration from LayerZero endpoint
   */
  async getConfigSender(): Promise<any> {
    try {
      logger.info('=== Getting Sender Configuration ===')
      const tronWeb = this.toolkit.getTronWeb()

      // Call getConfig on the LayerZero endpoint
      const transaction = await tronWeb.transactionBuilder.triggerSmartContract(
        this.ENDPOINT_ADDRESS,
        'getConfig(address,address,uint32,uint32)',
        { feeLimit: 50000000, callValue: 0 },
        [
          { type: 'address', value: this.LAYERZERO_PROVER_ADDRESS },
          { type: 'address', value: this.SEND_LIB_ADDRESS },
          { type: 'uint32', value: this.OPTIMISM_EID },
          { type: 'uint32', value: this.ULN_CONFIG_TYPE }
        ],
        tronWeb.defaultAddress.base58
      )

      if (transaction.result && transaction.result.result && transaction.constant_result) {
        const result = transaction.constant_result[0]
        logger.info('Raw sender config result:', result)
        
        // Parse the result - it should be ABI-encoded UlnConfig
        const decoded = this.parseUlnConfig(result)
        logger.info('Parsed sender configuration:', JSON.stringify(decoded, null, 2))
        return decoded
      } else {
        throw new Error('Failed to retrieve sender configuration')
      }
    } catch (error) {
      logger.error('Failed to get sender configuration:', error)
      throw error
    }
  }

  /**
   * Get receiver configuration from LayerZero endpoint
   */
  async getConfigReceiver(): Promise<any> {
    try {
      logger.info('=== Getting Receiver Configuration ===')
      const tronWeb = this.toolkit.getTronWeb()

      logger.info('getConfig method inputs:')
      logger.info(`  Endpoint Address: ${this.ENDPOINT_ADDRESS}`)
      logger.info(`  LayerZero Prover Address: ${this.LAYERZERO_PROVER_ADDRESS}`)
      logger.info(`  Receive Library Address: ${this.RECEIVE_LIB_ADDRESS}`)
      logger.info(`  Chain EID: ${this.OPTIMISM_EID}`)
      logger.info(`  Config Type: ${this.ULN_CONFIG_TYPE}`)

      // Call getConfig on the LayerZero endpoint  
      const transaction = await tronWeb.transactionBuilder.triggerSmartContract(
        this.ENDPOINT_ADDRESS,
        'getConfig(address,address,uint32,uint32)',
        { feeLimit: 50000000, callValue: 0 },
        [
          { type: 'address', value: this.LAYERZERO_PROVER_ADDRESS },
          { type: 'address', value: this.RECEIVE_LIB_ADDRESS },
          { type: 'uint32', value: this.OPTIMISM_EID },
          { type: 'uint32', value: this.ULN_CONFIG_TYPE }
        ],
        tronWeb.defaultAddress.base58
      )

      if (transaction.result && transaction.result.result && transaction.constant_result) {
        const result = transaction.constant_result[0]
        logger.info('Raw receiver config result:', result)
        
        // Parse the result - it should be ABI-encoded UlnConfig
        const decoded = this.parseUlnConfig(result)
        logger.info('Parsed receiver configuration:', JSON.stringify(decoded, null, 2))
        return decoded
      } else {
        throw new Error('Failed to retrieve receiver configuration')
      }
    } catch (error) {
      logger.error('Failed to get receiver configuration:', error)
      throw error
    }
  }

  /**
   * Parse UlnConfig from hex result
   */
  private parseUlnConfig(hexResult: string): any {
    try {
      const tronWeb = this.toolkit.getTronWeb()
      
      // The result starts with a struct offset (0x20), skip it
      let cleanHex = hexResult
      if (hexResult.startsWith('0000000000000000000000000000000000000000000000000000000000000020')) {
        cleanHex = hexResult.substring(64) // Skip the first 32 bytes (64 hex chars)
      }
      
      // Decode the UlnConfig struct
      // struct UlnConfig {
      //   uint64 confirmations;
      //   uint8 requiredDVNCount;
      //   uint8 optionalDVNCount; 
      //   uint8 optionalDVNThreshold;
      //   address[] requiredDVNs;
      //   address[] optionalDVNs;
      // }
      
      const decoded = tronWeb.utils.abi.decodeParams(
        ['uint64', 'uint8', 'uint8', 'uint8', 'address[]', 'address[]'],
        '0x' + cleanHex
      )

      // Convert hex addresses back to base58 Tron addresses
      const requiredDVNs = decoded[4].map((addr: string) => {
        if (addr === '0x0000000000000000000000000000000000000000') return null
        try {
          return tronWeb.address.fromHex(addr)
        } catch {
          return addr // Return hex if conversion fails
        }
      }).filter(Boolean)

      const optionalDVNs = decoded[5].map((addr: string) => {
        if (addr === '0x0000000000000000000000000000000000000000') return null
        try {
          return tronWeb.address.fromHex(addr)
        } catch {
          return addr // Return hex if conversion fails
        }
      }).filter(Boolean)

      return {
        confirmations: decoded[0].toString(),
        requiredDVNCount: decoded[1].toString(),
        optionalDVNCount: decoded[2].toString(),
        optionalDVNThreshold: decoded[3].toString(),
        requiredDVNs,
        optionalDVNs,
        primaryDVN: requiredDVNs.length > 0 ? requiredDVNs[0] : null
      }
    } catch (error) {
      logger.error('Failed to parse ULN config:', error)
      logger.info('Raw hex for debugging:', hexResult)
      
      // Try manual parsing of the DVN address
      let manualDVN = null
      try {
        const tronWeb = this.toolkit.getTronWeb()
        
        // Look for common DVN addresses in the hex
        const dvnPatterns = [
          'e369d146219380b24bb5d9b9e08a5b9936f9e719', // LayerZero Labs
          '73a38738170aca1b2ebcb55538ed9c7fb10ccd3b', // Different DVN
        ]
        
        for (const pattern of dvnPatterns) {
          if (hexResult.toLowerCase().includes(pattern)) {
            manualDVN = tronWeb.address.fromHex('0x' + pattern)
            break
          }
        }
      } catch (e) {
        // Ignore manual parsing errors
      }
      
      return {
        raw: hexResult,
        error: error instanceof Error ? error.message : String(error),
        manualDVN
      }
    }
  }

  /**
   * Get proven intent data from the LayerZero prover contract
   */
  async getProvenIntent(): Promise<any> {
    try {
      logger.info('=== Getting Proven Intent Data ===')
      const intentHash = '0x1f0ca5f010942f997927d7cecc4110344559bffadbdfc3bf3ee8b8fa6f026e65'
      logger.info(`Intent Hash: ${intentHash}`)
      logger.info(`LayerZero Prover Address: ${this.LAYERZERO_PROVER_ADDRESS}`)
      
      const tronWeb = this.toolkit.getTronWeb()

      // Call provenIntents on the LayerZero prover contract
      const transaction = await tronWeb.transactionBuilder.triggerSmartContract(
        this.LAYERZERO_PROVER_ADDRESS,
        'provenIntents(bytes32)',
        { feeLimit: 50000000, callValue: 0 },
        [
          { type: 'bytes32', value: intentHash }
        ],
        tronWeb.defaultAddress.base58
      )

      if (transaction.result && transaction.result.result && transaction.constant_result) {
        const result = transaction.constant_result[0]
        logger.info('Raw provenIntents result:', result)
        
        // Try to decode the ProofData struct
        // struct ProofData { address claimant; uint64 destination; }
        if (result && result !== '0x') {
          try {
            const decoded = tronWeb.utils.abi.decodeParams(
              ['address', 'uint64'],
              result
            )
            
            // Convert claimant address back to Tron base58 if it's not zero
            let claimantAddress = decoded[0]
            if (claimantAddress !== '0x0000000000000000000000000000000000000000') {
              try {
                claimantAddress = tronWeb.address.fromHex(decoded[0])
              } catch {
                // Keep as hex if conversion fails
              }
            }

            const proofData = {
              claimant: claimantAddress,
              destination: decoded[1].toString()
            }
            
            logger.info('Parsed proof data:', JSON.stringify(proofData, null, 2))
            return proofData
          } catch (error) {
            logger.error('Failed to decode proof data:', error)
            return { raw: result, error: error instanceof Error ? error.message : String(error) }
          }
        } else {
          logger.info('No proof found for this intent hash')
          return { claimant: '0x0000000000000000000000000000000000000000', destination: '0' }
        }
      } else {
        throw new Error('Failed to retrieve proven intent data')
      }
    } catch (error) {
      logger.error('Failed to get proven intent:', error)
      throw error
    }
  }

  /**
   * Get current configuration from the LayerZero endpoint
   */
  async getCurrentConfig(): Promise<any> {
    try {
      logger.info('=== Getting Current Configuration ===')
      logger.info(`LayerZero Prover: ${this.LAYERZERO_PROVER_ADDRESS}`)
      logger.info(`Endpoint: ${this.ENDPOINT_ADDRESS}`)
      logger.info(`DVN: ${this.DVN_ADDRESS}`)
      
      // Get both sender and receiver configs
      const senderConfig = await this.getConfigSender()
      const receiverConfig = await this.getConfigReceiver()
      
      logger.info('Configuration retrieval completed')
      return { sender: senderConfig, receiver: receiverConfig }
    } catch (error) {
      logger.error('Failed to get current configuration:', error)
      throw error
    }
  }

  /**
   * Complete send setup: set send library, executor, and send DVN config
   */
  async setupSend(): Promise<void> {
    try {
      logger.info('=== Complete Send Setup ===')

      await this.setSendLibrary()
      await this.setExecutor()
      await this.configureSend()

      logger.info('Send setup completed successfully!')
    } catch (error) {
      logger.error('Failed to complete send setup:', error)
      throw error
    }
  }

  /**
   * Complete receive setup: set receive library and receive DVN config
   */
  async setupReceive(): Promise<void> {
    try {
      logger.info('=== Complete Receive Setup ===')

      // Step 1: Set receive library
      logger.info('Step 1/2: Setting receive library...')
      await this.setReceiveLibrary()
      logger.info('✓ Receive library set successfully')

      // Step 2: Configure receive DVN
      logger.info('Step 2/2: Configuring receive DVN...')
      await this.configureReceive()
      logger.info('✓ Receive DVN configured successfully')

      logger.info('Receive setup completed successfully!')
    } catch (error) {
      logger.error('Failed to complete receive setup:', error)
      throw error
    }
  }
}

/**
 * Main execution function
 */
async function main() {
  try {
    const networkName = process.env.TRON_NETWORK || 'mainnet'
    const configScript = new LayerZeroProverConfig(networkName)

    const action = process.argv[2] || 'send'

    switch (action) {
      case 'send':
        await configScript.configureSend()
        break
      case 'receive':
        await configScript.configureReceive()
        break
      case 'both':
        await configScript.configureSend()
        await configScript.configureReceive()
        break
      case 'send-lib':
        await configScript.setSendLibrary()
        break
      case 'receive-lib':
        await configScript.setReceiveLibrary()
        break
      case 'all-libs':
        await configScript.setSendLibrary()
        await configScript.setReceiveLibrary()
        break
      case 'executor':
        await configScript.setExecutor()
        break
      case 'setup-send':
        await configScript.setupSend()
        break
      case 'setup-receive':
        await configScript.setupReceive()
        break
      case 'full':
        await configScript.setupSend()
        await configScript.setupReceive()
        break
      case 'status':
        await configScript.getCurrentConfig()
        break
      case 'get-sender':
        await configScript.getConfigSender()
        break
      case 'get-receiver':
        await configScript.getConfigReceiver()
        break
      case 'get-proven-intent':
        await configScript.getProvenIntent()
        break
      default:
        logger.info('Usage: ts-node configure-layerzero-prover.ts [ACTION]')
        logger.info('Actions:')
        logger.info('  send        - Configure send DVN settings')
        logger.info('  receive     - Configure receive DVN settings')
        logger.info('  both        - Configure both send and receive DVN settings')
        logger.info('  send-lib    - Set send library')
        logger.info('  receive-lib - Set receive library')
        logger.info('  all-libs    - Set both send and receive libraries')
        logger.info('  executor    - Set executor configuration')
        logger.info('  setup-send  - Complete send setup (library + executor + DVN)')
        logger.info('  setup-receive - Complete receive setup (library + DVN)')
        logger.info('  full        - Complete setup: send + receive')
        logger.info('  status      - Get current configuration status')
        logger.info('  get-sender  - Get sender configuration and show DVN')
        logger.info('  get-receiver - Get receiver configuration and show DVN')
        logger.info('  get-proven-intent - Get proven intent data for test intent hash')
        process.exit(1)
    }

    logger.info('LayerZero Prover configuration completed successfully!')
  } catch (error) {
    logger.error('Configuration failed:', error)
    process.exit(1)
  }
}

// Execute main function if this file is run directly
if (require.main === module) {
  main()
}

export { LayerZeroProverConfig }