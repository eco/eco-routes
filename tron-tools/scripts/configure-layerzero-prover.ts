import { TronToolkit } from '../src/TronToolkit'
import { logger } from '../src/utils/logger'
import { config } from 'dotenv'

// Load environment variables
config()

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
  private readonly SRC_EID = 30111 // Source chain endpoint ID
  private readonly DST_EID = 30420 // Destination chain endpoint ID
  private readonly SEND_CONFIRMATIONS = 15

  // Contract addresses - Update with your actual deployed addresses
  private readonly LAYERZERO_PROVER_ADDRESS =
    process.env.LAYERZERO_PROVER_ADDRESS || 'TLZnJetQTgaLNwf8Aos7SeUZ9WL4FxTZZS' // From deployment

  private readonly DVN_ADDRESS =
    process.env.DVN_ADDRESS || '0x427bd19a0463fc4eDc2e247d35eB61323d7E5541' // Deutsche Telekom DVN

  private readonly ENDPOINT_ADDRESS =
    process.env.TRON_ENDPOINT_ADDRESS ||
    '0x0Af59750D5dB5460E5d89E268C474d5F7407c061' // Tron LayerZero Endpoint

  private readonly SEND_LIB_ADDRESS =
    process.env.SEND_LIB_ADDRESS || '0x1322871e4ab09Bc7f5717189434f97bBD9546e95' // Deutsche Telekom Send Lib

  private readonly RECEIVE_LIB_ADDRESS =
    process.env.RECEIVE_LIB_ADDRESS ||
    '0xE369D146219380B24Bb5D9B9E08a5b9936F9E719' // Receive library (can be different)

  private readonly EXECUTOR_ADDRESS =
    process.env.EXECUTOR_ADDRESS || '0x612215D4dB0475a76dCAa36C7f9afD748c42ed2D' // LayerZero Executor

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
      logger.info(`Destination EID: ${this.DST_EID}`)
      logger.info(`Send Library Address: ${this.SEND_LIB_ADDRESS}`)

      const tronWeb = this.toolkit.getNetworkManager().getTronWeb()
      const endpointContract = await tronWeb
        .contract()
        .at(this.ENDPOINT_ADDRESS)

      // Estimate energy for the transaction
      const energyEstimate = await this.estimateLibraryEnergy('setSendLibrary')
      logger.info(`Estimated energy needed: ${energyEstimate}`)

      // Ensure sufficient energy if rental is enabled
      if (process.env.ENABLE_ENERGY_RENTAL === 'true') {
        const rentalManager = this.toolkit.getEnergyRentalManager()
        await rentalManager.ensureSufficientEnergy(energyEstimate, 0)
      }

      // Call setSendLibrary on the LayerZero endpoint
      logger.info('Calling setSendLibrary on LayerZero endpoint...')
      const result = await endpointContract.methods
        .setSendLibrary(
          this.LAYERZERO_PROVER_ADDRESS,
          this.DST_EID,
          this.SEND_LIB_ADDRESS,
        )
        .send({
          from: tronWeb.defaultAddress.hex,
          shouldPollResponse: true,
        })

      logger.info('Send library configuration completed successfully!')
      logger.info(`Transaction ID: ${result}`)
    } catch (error) {
      logger.error('Failed to set send library:', error)
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
      logger.info(`Source EID: ${this.SRC_EID}`)
      logger.info(`Receive Library Address: ${this.RECEIVE_LIB_ADDRESS}`)

      const tronWeb = this.toolkit.getNetworkManager().getTronWeb()
      const endpointContract = await tronWeb
        .contract()
        .at(this.ENDPOINT_ADDRESS)

      // Grace period for library transition (24 hours = 86400 seconds)
      const gracePeriod = 86400

      // Estimate energy for the transaction
      const energyEstimate =
        await this.estimateLibraryEnergy('setReceiveLibrary')
      logger.info(`Estimated energy needed: ${energyEstimate}`)

      // Ensure sufficient energy if rental is enabled
      if (process.env.ENABLE_ENERGY_RENTAL === 'true') {
        const rentalManager = this.toolkit.getEnergyRentalManager()
        await rentalManager.ensureSufficientEnergy(energyEstimate, 0)
      }

      // Call setReceiveLibrary on the LayerZero endpoint
      logger.info('Calling setReceiveLibrary on LayerZero endpoint...')
      const result = await endpointContract.methods
        .setReceiveLibrary(
          this.LAYERZERO_PROVER_ADDRESS,
          this.SRC_EID,
          this.RECEIVE_LIB_ADDRESS,
          gracePeriod,
        )
        .send({
          from: tronWeb.defaultAddress.hex,
          shouldPollResponse: true,
        })

      logger.info('Receive library configuration completed successfully!')
      logger.info(`Transaction ID: ${result}, Grace Period: ${gracePeriod}s`)
    } catch (error) {
      logger.error('Failed to set receive library:', error)
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
      logger.info(`Source EID: ${this.SRC_EID}`)
      logger.info(`Send Library Address: ${this.SEND_LIB_ADDRESS}`)
      logger.info(`Executor Address: ${this.EXECUTOR_ADDRESS}`)
      logger.info(
        `Gas Limit: ${this.EXECUTOR_GAS_LIMIT}, Value: ${this.EXECUTOR_VALUE}`,
      )

      const tronWeb = this.toolkit.getNetworkManager().getTronWeb()
      const endpointContract = await tronWeb
        .contract()
        .at(this.ENDPOINT_ADDRESS)

      // Create executor configuration
      // bytes memory executorConfig = abi.encode(uint128(gasLimit), uint128(value))
      const executorConfig = tronWeb.utils.abi.encodeParameters(
        ['uint128', 'uint128'],
        [this.EXECUTOR_GAS_LIMIT, this.EXECUTOR_VALUE],
      )

      // abi.encode(executorAddress, executorConfig)
      const fullExecutorConfig = tronWeb.utils.abi.encodeParameters(
        ['address', 'bytes'],
        [this.EXECUTOR_ADDRESS, executorConfig],
      )

      logger.info(`Executor Config: ${executorConfig}`)
      logger.info(`Full Config: ${fullExecutorConfig}`)

      // Create SetConfigParam for executor
      const setConfigParams: SetConfigParam[] = [
        {
          eid: this.SRC_EID,
          configType: this.CONFIG_TYPE_EXECUTOR,
          config: fullExecutorConfig,
        },
      ]

      // Estimate energy for the transaction
      const energyEstimate = await this.estimateConfigEnergy(setConfigParams)
      logger.info(`Estimated energy needed: ${energyEstimate}`)

      // Ensure sufficient energy if rental is enabled
      if (process.env.ENABLE_ENERGY_RENTAL === 'true') {
        const rentalManager = this.toolkit.getEnergyRentalManager()
        await rentalManager.ensureSufficientEnergy(energyEstimate, 0)
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
          from: tronWeb.defaultAddress.hex,
          shouldPollResponse: true,
        })

      logger.info('Executor configuration completed successfully!')
      logger.info(`Transaction ID: ${result}`)
    } catch (error) {
      logger.error('Failed to set executor:', error)
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
      logger.info(`Destination EID: ${this.DST_EID}`)
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
      const tronWeb = this.toolkit.getNetworkManager().getTronWeb()
      const encodedUlnConfig = tronWeb.utils.abi.encodeParameters(
        ['uint64', 'uint8', 'uint8', 'uint8', 'address[]', 'address[]'],
        [
          ulnConfig.confirmations,
          ulnConfig.requiredDVNCount,
          ulnConfig.optionalDVNCount,
          ulnConfig.optionalDVNThreshold,
          ulnConfig.requiredDVNs,
          ulnConfig.optionalDVNs,
        ],
      )

      logger.info(`Encoded ULN Config: ${encodedUlnConfig}`)

      // Create SetConfigParam
      const setConfigParams: SetConfigParam[] = [
        {
          eid: this.DST_EID,
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
        const rentalManager = this.toolkit.getEnergyRentalManager()
        await rentalManager.ensureSufficientEnergy(energyEstimate, 0)
      }

      // Call setConfig on the LayerZero endpoint
      logger.info('Calling setConfig on LayerZero endpoint...')
      const result = await endpointContract.methods
        .setConfig(
          this.LAYERZERO_PROVER_ADDRESS,
          this.SEND_LIB_ADDRESS,
          setConfigParams,
        )
        .send({
          from: tronWeb.defaultAddress.hex,
          shouldPollResponse: true,
        })

      logger.info('Send DVN configuration completed successfully!')
      logger.info(`Transaction ID: ${result}`)
    } catch (error) {
      logger.error('Failed to configure send DVN:', error)
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
      logger.info(`Source EID: ${this.SRC_EID}`)
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
      const tronWeb = this.toolkit.getNetworkManager().getTronWeb()
      const encodedUlnConfig = tronWeb.utils.abi.encodeParameters(
        ['uint64', 'uint8', 'uint8', 'uint8', 'address[]', 'address[]'],
        [
          ulnConfig.confirmations,
          ulnConfig.requiredDVNCount,
          ulnConfig.optionalDVNCount,
          ulnConfig.optionalDVNThreshold,
          ulnConfig.requiredDVNs,
          ulnConfig.optionalDVNs,
        ],
      )

      // Create SetConfigParam for receive configuration
      const setConfigParams: SetConfigParam[] = [
        {
          eid: this.SRC_EID,
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
        const rentalManager = this.toolkit.getEnergyRentalManager()
        await rentalManager.ensureSufficientEnergy(energyEstimate, 0)
      }

      // Call setConfig on the LayerZero endpoint
      logger.info('Calling setConfig on LayerZero endpoint...')
      const result = await endpointContract.methods
        .setConfig(
          this.LAYERZERO_PROVER_ADDRESS,
          this.SEND_LIB_ADDRESS,
          setConfigParams,
        )
        .send({
          from: tronWeb.defaultAddress.hex,
          shouldPollResponse: true,
        })

      logger.info('Receive DVN configuration completed successfully!')
      logger.info(`Transaction ID: ${result}`)
    } catch (error) {
      logger.error('Failed to configure receive DVN:', error)
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
      const tronWeb = this.toolkit.getNetworkManager().getTronWeb()
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
        tronWeb.defaultAddress.hex,
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
      const tronWeb = this.toolkit.getNetworkManager().getTronWeb()
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
              value: this.DST_EID,
            },
            {
              type: 'address',
              value: this.SEND_LIB_ADDRESS,
            },
          ],
          tronWeb.defaultAddress.hex,
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
              value: this.SRC_EID,
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
          tronWeb.defaultAddress.hex,
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

      const tronWeb = this.toolkit.getNetworkManager().getTronWeb()
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
      
      await this.setReceiveLibrary()
      await this.configureReceive()
      
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
        logger.info('  setup-send  - Complete send setup (library + executor + DVN)')
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
