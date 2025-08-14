import { TronToolkit } from '../dist/TronToolkit.js'
import { logger } from '../dist/utils/logger.js'
import { config } from 'dotenv'

// Load environment variables from parent directory
config({ path: '../.env' })

// Debug environment loading
console.log('Environment check:', {
  hasTronPrivateKey: !!process.env.TRON_PRIVATE_KEY,
  tronPrivateKeyLength: process.env.TRON_PRIVATE_KEY?.length || 0
})

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
 * Equivalent to the SetUlnLZ.s.sol forge script
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

  // Contract addresses - Update with your actual deployed addresses
  private readonly LAYERZERO_PROVER_ADDRESS =
    process.env.LAYERZERO_PROVER_ADDRESS || 'TLZnJetQTgaLNwf8Aos7SeUZ9WL4FxTZZS' // From deployment

  private readonly DVN_ADDRESS =
    process.env.DVN_ADDRESS || 'TNiB7ybFhyLDaW6JAM2BP9QQrAfncwbCyG' // layerzero labs

  private readonly ENDPOINT_ADDRESS =
    process.env.TRON_ENDPOINT_ADDRESS ||
    'TAy9xwjYjBBN6kutzrZJaAZJHCAejjK1V9' // Tron LayerZero Endpoint (base58)

  private readonly SEND_LIB_ADDRESS =
    process.env.SEND_LIB_ADDRESS || 'TWhf9vzMEGmWjn538ymX76sgGN3LxG7mQJ'

  private readonly RECEIVE_LIB_ADDRESS =
    process.env.RECEIVE_LIB_ADDRESS ||
    'TJpoNxF3CreFRpTdLhyXuJzEo4vMAns7Wz' // Receive library (can be different)

  private readonly EXECUTOR_ADDRESS =
    process.env.EXECUTOR_ADDRESS || 'TKSQrCn9r7jdNxWuQGRw8RJT8x4LFNfr7B' // LayerZero Executor

  private readonly PRIVATE_KEY = process.env.TRON_PRIVATE_KEY!

  constructor(networkName: string = 'mainnet') {
    if (!this.PRIVATE_KEY) {
      throw new Error('TRON_PRIVATE_KEY environment variable is required')
    }

    this.toolkit = new TronToolkit({
      network: networkName,
      privateKey: this.PRIVATE_KEY,
      enableEnergyRental: process.env.ENABLE_ENERGY_RENTAL === 'true',
    })
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

      const tronWeb = this.toolkit.getTronWeb()
      const endpointContract = await tronWeb
        .contract()
        .at(this.ENDPOINT_ADDRESS)

      // Estimate energy for the transaction
      const energyEstimate = await this.estimateLibraryEnergy('setSendLibrary')
      logger.info(`Estimated energy needed: ${energyEstimate}`)

      // Ensure sufficient energy if rental is enabled
      if (process.env.ENABLE_ENERGY_RENTAL === 'true') {
        await this.toolkit.autoRentResources(energyEstimate, 0, tronWeb.defaultAddress.base58)
      }

      // Call setSendLibrary on the LayerZero endpoint
      logger.info('Calling setSendLibrary on LayerZero endpoint...')
      const result = await endpointContract.methods
        .setSendLibrary(
          this.LAYERZERO_PROVER_ADDRESS,
          this.OPTIMISM_EID,
          this.SEND_LIB_ADDRESS,
        )
        .send({
          from: tronWeb.defaultAddress.base58,
          shouldPollResponse: true,
        })

      logger.info('Send library configuration completed successfully!')
      logger.info(`Transaction ID: ${result}`)
    } catch (error) {
      logger.error('=== SEND LIBRARY SETUP FAILED ===')
      logger.error('Error details:', {
        name: error.name,
        message: error.message,
        code: error.code,
        stack: error.stack,
        ...(error.receipt && { receipt: error.receipt }),
        ...(error.transaction && { transaction: error.transaction }),
      })
      logger.error('Call arguments that failed:', {
        layerZeroProverAddress: this.LAYERZERO_PROVER_ADDRESS,
        destinationEID: this.OPTIMISM_EID,
        sendLibraryAddress: this.SEND_LIB_ADDRESS,
        endpointAddress: this.ENDPOINT_ADDRESS,
        callerAddress: this.toolkit.getTronWeb().defaultAddress.base58,
      })
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

      const tronWeb = this.toolkit.getTronWeb()
      
      logger.info(`Using endpoint address: ${this.ENDPOINT_ADDRESS}`)
      
      const endpointContract = await tronWeb
        .contract()
        .at(this.ENDPOINT_ADDRESS)

      // Grace period for library transition (24 hours = 86400 seconds)
      const gracePeriod = 86400

      // Estimate energy for the transaction
      logger.info('Estimating energy for setReceiveLibrary...')
      let energyEstimate: number
      try {
        energyEstimate = await this.estimateLibraryEnergy('setReceiveLibrary')
        logger.info(`Estimated energy needed: ${energyEstimate}`)
      } catch (estimationError) {
        logger.warn('Energy estimation failed, using fallback:', estimationError)
        energyEstimate = 150000 // Use fallback
        logger.info(`Using fallback energy estimate: ${energyEstimate}`)
      }

      // Ensure sufficient energy if rental is enabled
      if (process.env.ENABLE_ENERGY_RENTAL === 'true') {
        await this.toolkit.autoRentResources(energyEstimate, 0, tronWeb.defaultAddress.base58)
      }

      // Call setReceiveLibrary on the LayerZero endpoint
      logger.info('Calling setReceiveLibrary on LayerZero endpoint...')
      logger.info('Contract call parameters:', {
        contractAddress: this.ENDPOINT_ADDRESS,
        method: 'setReceiveLibrary',
        parameters: [
          this.LAYERZERO_PROVER_ADDRESS,
          this.OPTIMISM_EID,
          this.RECEIVE_LIB_ADDRESS,
          gracePeriod
        ],
        from: tronWeb.defaultAddress.base58
      })
      
      const result = await endpointContract.methods
        .setReceiveLibrary(
          this.LAYERZERO_PROVER_ADDRESS,
          this.OPTIMISM_EID,
          this.RECEIVE_LIB_ADDRESS,
          gracePeriod,
        )
        .send({
          from: tronWeb.defaultAddress.base58,
          shouldPollResponse: true,
        })

      logger.info('Receive library configuration completed successfully!')
      logger.info(`Transaction ID: ${result}, Grace Period: ${gracePeriod}s`)
    } catch (error) {
      logger.error('=== RECEIVE LIBRARY SETUP FAILED ===')
      logger.error('Raw error:', error)
      logger.error('Error type:', typeof error)
      logger.error('Error details:', {
        name: error?.name,
        message: error?.message,
        code: error?.code,
        stack: error?.stack,
        stringified: String(error),
        ...(error?.receipt && { receipt: error.receipt }),
        ...(error?.transaction && { transaction: error.transaction }),
      })
      logger.error('Call arguments that failed:', {
        layerZeroProverAddress: this.LAYERZERO_PROVER_ADDRESS,
        sourceEID: this.OPTIMISM_EID,
        receiveLibraryAddress: this.RECEIVE_LIB_ADDRESS,
        gracePeriod: 86400,
        endpointAddress: this.ENDPOINT_ADDRESS,
        callerAddress: this.toolkit.getTronWeb().defaultAddress.base58,
      })
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
      logger.info(
        `Gas Limit: ${this.EXECUTOR_GAS_LIMIT}, Value: ${this.EXECUTOR_VALUE}`,
      )

      const tronWeb = this.toolkit.getTronWeb()
      const endpointContract = await tronWeb
        .contract()
        .at(this.ENDPOINT_ADDRESS)

      // Create executor configuration
      // bytes memory executorConfig = abi.encode(uint128(gasLimit), uint128(value))
      const executorConfig = tronWeb.utils.abi.encodeParams(
        ['uint128', 'uint128'],
        [this.EXECUTOR_GAS_LIMIT, this.EXECUTOR_VALUE],
      )

      // Convert executor address to Ethereum-style hex for ABI encoding
      const tronHex = tronWeb.address.toHex(this.EXECUTOR_ADDRESS)
      const executorAddressHex = '0x' + tronHex.substring(2)
      logger.info(`Converting executor address: ${this.EXECUTOR_ADDRESS} -> ${tronHex} -> ${executorAddressHex}`)

      // abi.encode(executorAddress, executorConfig)
      const fullExecutorConfig = tronWeb.utils.abi.encodeParams(
        ['address', 'bytes'],
        [executorAddressHex, executorConfig],
      )

      logger.info(`Executor Config: ${executorConfig}`)
      logger.info(`Full Config: ${fullExecutorConfig}`)

      // Create SetConfigParam for executor
      const setConfigParams: SetConfigParam[] = [
        {
          eid: this.OPTIMISM_EID,
          configType: this.CONFIG_TYPE_EXECUTOR,
          config: fullExecutorConfig,
        },
      ]

      // Estimate energy for the transaction
      const energyEstimate = await this.estimateConfigEnergy(setConfigParams)
      logger.info(`Estimated energy needed: ${energyEstimate}`)

      // Ensure sufficient energy if rental is enabled
      if (process.env.ENABLE_ENERGY_RENTAL === 'true') {
        await this.toolkit.autoRentResources(energyEstimate, 0, tronWeb.defaultAddress.base58)
      }

      // Call setConfig on the LayerZero endpoint for executor configuration
      logger.info('Calling setConfig for executor on LayerZero endpoint...')
      const result = await endpointContract.methods
        .setConfig(
          this.LAYERZERO_PROVER_ADDRESS,
          this.SEND_LIB_ADDRESS, // The Messaging Library for send path
          setConfigParams,
        )
        .send({
          from: tronWeb.defaultAddress.base58,
          shouldPollResponse: true,
        })

      logger.info('Executor configuration completed successfully!')
      logger.info(`Transaction ID: ${result}`)
    } catch (error) {
      logger.error('=== EXECUTOR CONFIGURATION FAILED ===')
      logger.error('Error details:', {
        name: error.name,
        message: error.message,
        code: error.code,
        stack: error.stack,
        ...(error.receipt && { receipt: error.receipt }),
        ...(error.transaction && { transaction: error.transaction }),
      })
      logger.error('Call arguments that failed:', {
        layerZeroProverAddress: this.LAYERZERO_PROVER_ADDRESS,
        sendLibraryAddress: this.SEND_LIB_ADDRESS,
        sourceEID: this.OPTIMISM_EID,
        configType: this.CONFIG_TYPE_EXECUTOR,
        executorAddress: this.EXECUTOR_ADDRESS,
        gasLimit: this.EXECUTOR_GAS_LIMIT,
        value: this.EXECUTOR_VALUE,
        encodedConfig: 'See setConfigParams variable above',
        endpointAddress: this.ENDPOINT_ADDRESS,
        callerAddress: this.toolkit.getTronWeb().defaultAddress.base58,
      })
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
      const requiredDVNsHex = ulnConfig.requiredDVNs.map(addr => {
        const tronHex = tronWeb.address.toHex(addr)
        return '0x' + tronHex.substring(2)
      })
      const optionalDVNsHex = ulnConfig.optionalDVNs.map(addr => {
        const tronHex = tronWeb.address.toHex(addr)
        return '0x' + tronHex.substring(2)
      })
      
      const encodedUlnConfig = tronWeb.utils.abi.encodeParams(
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

      logger.info(`Encoded ULN Config: ${encodedUlnConfig}`)

      // Create SetConfigParam
      const setConfigParams: SetConfigParam[] = [
        {
          eid: this.OPTIMISM_EID,
          configType: this.ULN_CONFIG_TYPE,
          config: encodedUlnConfig,
        },
      ]

      // Get LayerZero endpoint contract
      const endpointContract = await tronWeb
        .contract()
        .at(this.ENDPOINT_ADDRESS)

      // Estimate energy for the transaction
      const energyEstimate = await this.estimateConfigEnergy(setConfigParams)
      logger.info(`Estimated energy needed: ${energyEstimate}`)

      // Ensure sufficient energy if rental is enabled
      if (process.env.ENABLE_ENERGY_RENTAL === 'true') {
        await this.toolkit.autoRentResources(energyEstimate, 0, tronWeb.defaultAddress.base58)
      }

      // Call setConfig on the LayerZero endpoint
      logger.info('Calling setConfig on LayerZero endpoint...')
      logger.info('Contract call parameters:', {
        oapp: this.LAYERZERO_PROVER_ADDRESS,
        lib: this.SEND_LIB_ADDRESS,
        params: setConfigParams,
        from: tronWeb.defaultAddress.base58
      })
      
      const result = await endpointContract.methods
        .setConfig(
          this.LAYERZERO_PROVER_ADDRESS,
          this.SEND_LIB_ADDRESS,
          setConfigParams,
        )
        .send({
          from: tronWeb.defaultAddress.base58,
          shouldPollResponse: true,
        })

      logger.info('Send DVN configuration completed successfully!')
      logger.info(`Transaction ID: ${result}`)
    } catch (error) {
      logger.error('=== SEND DVN CONFIGURATION FAILED ===')
      logger.error('Error details:', {
        name: error.name,
        message: error.message,
        code: error.code,
        stack: error.stack,
        ...(error.receipt && { receipt: error.receipt }),
        ...(error.transaction && { transaction: error.transaction }),
      })
      logger.error('Call arguments that failed:', {
        layerZeroProverAddress: this.LAYERZERO_PROVER_ADDRESS,
        sendLibraryAddress: this.SEND_LIB_ADDRESS,
        destinationEID: this.OPTIMISM_EID,
        configType: this.ULN_CONFIG_TYPE,
        dvnAddress: this.DVN_ADDRESS,
        confirmations: this.SEND_CONFIRMATIONS,
        requiredDVNCount: this.REQUIRED_DVN_COUNT,
        optionalDVNCount: this.OPTIONAL_DVN_COUNT,
        optionalDVNThreshold: this.OPTIONAL_DVN_THRESHOLD,
        encodedConfig: 'See setConfigParams variable above',
        endpointAddress: this.ENDPOINT_ADDRESS,
        callerAddress: this.toolkit.getTronWeb().defaultAddress.base58,
      })
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
      logger.info(`Receive Confirmations: ${this.SEND_CONFIRMATIONS}`)

      // Create ULN configuration for receive
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
      
      logger.info('Attempting to encode ULN config...')
      logger.info('ULN config to encode:', ulnConfig)
      
      let encodedUlnConfig: string
      try {
        // Convert base58 addresses to Ethereum-style hex for ABI encoding
        const requiredDVNsHex = ulnConfig.requiredDVNs.map(addr => {
          const tronHex = tronWeb.address.toHex(addr)
          return '0x' + tronHex.substring(2)
        })
        const optionalDVNsHex = ulnConfig.optionalDVNs.map(addr => {
          const tronHex = tronWeb.address.toHex(addr)
          return '0x' + tronHex.substring(2)
        })
        
        logger.info('Converting DVN addresses for encoding:', {
          requiredDVNs: ulnConfig.requiredDVNs,
          requiredDVNsHex,
          optionalDVNs: ulnConfig.optionalDVNs,
          optionalDVNsHex
        })
        
        // Try TronWeb's ABI encoding with hex addresses
        encodedUlnConfig = tronWeb.utils.abi.encodeParams(
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
        logger.info('Successfully encoded ULN config')
      } catch (encodeError) {
        logger.error('TronWeb ABI encoding failed:', encodeError)
        throw new Error(`Failed to encode ULN config: ${encodeError.message}`)
      }

      // Create SetConfigParam for receive configuration
      const setConfigParams: SetConfigParam[] = [
        {
          eid: this.OPTIMISM_EID,
          configType: this.ULN_CONFIG_TYPE,
          config: encodedUlnConfig,
        },
      ]

      logger.info(`Using endpoint address: ${this.ENDPOINT_ADDRESS}`)
      
      // Get LayerZero endpoint contract
      const endpointContract = await tronWeb
        .contract()
        .at(this.ENDPOINT_ADDRESS)

      // Estimate energy for the transaction
      const energyEstimate = await this.estimateConfigEnergy(setConfigParams)
      logger.info(`Estimated energy needed: ${energyEstimate}`)

      // Ensure sufficient energy if rental is enabled
      if (process.env.ENABLE_ENERGY_RENTAL === 'true') {
        await this.toolkit.autoRentResources(energyEstimate, 0, tronWeb.defaultAddress.base58)
      }

      // Call setConfig on the LayerZero endpoint
      logger.info('Calling setConfig on LayerZero endpoint...')
      logger.info('Contract call parameters:', {
        oapp: this.LAYERZERO_PROVER_ADDRESS,
        lib: this.RECEIVE_LIB_ADDRESS,
        params: setConfigParams,
        from: tronWeb.defaultAddress.base58
      })
      
      const result = await endpointContract.methods
        .setConfig(
          this.LAYERZERO_PROVER_ADDRESS,
          this.RECEIVE_LIB_ADDRESS,
          setConfigParams,
        )
        .send({
          from: tronWeb.defaultAddress.base58,
          shouldPollResponse: true,
        })

      logger.info('Receive DVN configuration completed successfully!')
      logger.info(`Transaction ID: ${result}`)
    } catch (error) {
      logger.error('=== RECEIVE DVN CONFIGURATION FAILED ===')
      logger.error('Error details:', {
        name: error.name,
        message: error.message,
        code: error.code,
        stack: error.stack,
        ...(error.receipt && { receipt: error.receipt }),
        ...(error.transaction && { transaction: error.transaction }),
      })
      
      // Log transaction calldata if available
      if (error.transaction && error.transaction.raw_data_hex) {
        logger.error('Full transaction calldata:', error.transaction.raw_data_hex)
      }
      
      logger.error('Call arguments that failed:', {
        layerZeroProverAddress: this.LAYERZERO_PROVER_ADDRESS,
        receiveLibraryAddress: this.RECEIVE_LIB_ADDRESS,
        sourceEID: this.OPTIMISM_EID,
        configType: this.ULN_CONFIG_TYPE,
        dvnAddress: this.DVN_ADDRESS,
        confirmations: this.SEND_CONFIRMATIONS,
        requiredDVNCount: this.REQUIRED_DVN_COUNT,
        optionalDVNCount: this.OPTIONAL_DVN_COUNT,
        optionalDVNThreshold: this.OPTIONAL_DVN_THRESHOLD,
        encodedConfig: 'See setConfigParams variable above',
        endpointAddress: this.ENDPOINT_ADDRESS,
        callerAddress: this.toolkit.getTronWeb().defaultAddress.base58,
      })
      throw error
    }
  }

  /**
   * Estimate energy needed for setConfig transaction
   */
  private async estimateConfigEnergy(
    setConfigParams: SetConfigParam[],
  ): Promise<number> {
    try {
      const tronWeb = this.toolkit.getTronWeb()
      const endpointContract = await tronWeb
        .contract()
        .at(this.ENDPOINT_ADDRESS)

      // Use TronWeb's energy estimation
      const energyUsed = await tronWeb.transactionBuilder.estimateEnergy(
        endpointContract.address,
        'setConfig(address,address,(uint32,uint32,bytes)[])',
        {},
        [
          {
            type: 'address',
            value: this.LAYERZERO_PROVER_ADDRESS,
          },
          {
            type: 'address',
            value: this.SEND_LIB_ADDRESS,
          },
          {
            type: '(uint32,uint32,bytes)[]',
            value: setConfigParams.map((param) => [
              param.eid,
              param.configType,
              param.config,
            ]),
          },
        ],
        tronWeb.defaultAddress.base58,
      )

      return energyUsed || 200000 // Fallback to reasonable estimate
    } catch (error) {
      logger.warn('Failed to estimate energy, using fallback:', error)
      return 200000 // Conservative fallback estimate
    }
  }

  /**
   * Estimate energy needed for library transactions
   */
  private async estimateLibraryEnergy(
    method: 'setSendLibrary' | 'setReceiveLibrary',
  ): Promise<number> {
    try {
      const tronWeb = this.toolkit.getTronWeb()
      const endpointContract = await tronWeb
        .contract()
        .at(this.ENDPOINT_ADDRESS)

      let energyUsed: number

      if (method === 'setSendLibrary') {
        energyUsed = await tronWeb.transactionBuilder.estimateEnergy(
          endpointContract.address,
          'setSendLibrary(address,uint32,address)',
          {},
          [
            {
              type: 'address',
              value: this.LAYERZERO_PROVER_ADDRESS,
            },
            {
              type: 'uint32',
              value: this.OPTIMISM_EID,
            },
            {
              type: 'address',
              value: this.SEND_LIB_ADDRESS,
            },
          ],
          tronWeb.defaultAddress.base58,
        )
      } else {
        energyUsed = await tronWeb.transactionBuilder.estimateEnergy(
          endpointContract.address,
          'setReceiveLibrary(address,uint32,address,uint256)',
          {},
          [
            {
              type: 'address',
              value: this.LAYERZERO_PROVER_ADDRESS,
            },
            {
              type: 'uint32',
              value: this.OPTIMISM_EID,
            },
            {
              type: 'address',
              value: this.SEND_LIB_ADDRESS,
            },
            {
              type: 'uint256',
              value: 86400, // Grace period
            },
          ],
          tronWeb.defaultAddress.base58,
        )
      }

      return energyUsed || 150000 // Fallback for library methods
    } catch (error) {
      logger.warn('Failed to estimate library energy, using fallback:', error)
      return 150000 // Conservative fallback estimate for library methods
    }
  }

  /**
   * Get current configuration from the LayerZero endpoint
   */
  async getCurrentConfig(): Promise<void> {
    try {
      logger.info('=== Getting Current Configuration ===')

      const tronWeb = this.toolkit.getTronWeb()
      const endpointContract = await tronWeb
        .contract()
        .at(this.ENDPOINT_ADDRESS)

      // Note: This depends on the specific LayerZero endpoint interface
      // You may need to adjust based on the actual endpoint contract methods available
      logger.info(`LayerZero Prover: ${this.LAYERZERO_PROVER_ADDRESS}`)
      logger.info(`Endpoint: ${this.ENDPOINT_ADDRESS}`)
      logger.info(`DVN: ${this.DVN_ADDRESS}`)
      logger.info('Configuration retrieval completed')
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
    //   logger.info('Step 1/2: Setting receive library...')
    //   await this.setReceiveLibrary()
    //   logger.info('✓ Receive library set successfully')

      // Step 2: Configure receive DVN (only if library setup succeeded)
      logger.info('Step 2/2: Configuring receive DVN...')
      await this.configureReceive()
      logger.info('✓ Receive DVN configured successfully')

      logger.info('Receive setup completed successfully!')
    } catch (error) {
      if (error.message?.includes('receive library')) {
        logger.error(
          'Failed during receive library setup. Skipping DVN configuration.',
        )
      } else if (error.message?.includes('DVN')) {
        logger.error('Receive library succeeded, but DVN configuration failed.')
      } else {
        logger.error('Failed to complete receive setup:', error)
      }
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
      default:
        logger.info('Usage: ts-node configure-layerzero-prover.ts [ACTION]')
        logger.info('Actions:')
        logger.info('  send        - Configure send DVN settings')
        logger.info('  receive     - Configure receive DVN settings')
        logger.info(
          '  both        - Configure both send and receive DVN settings',
        )
        logger.info('  send-lib    - Set send library')
        logger.info('  receive-lib - Set receive library')
        logger.info('  all-libs    - Set both send and receive libraries')
        logger.info('  executor    - Set executor configuration')
        logger.info(
          '  setup-send  - Complete send setup (library + executor + DVN)',
        )
        logger.info('  setup-receive - Complete receive setup (library + DVN)')
        logger.info('  full        - Complete setup: send + receive')
        logger.info('  status      - Get current configuration status')
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
