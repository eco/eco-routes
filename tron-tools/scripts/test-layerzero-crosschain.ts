import { TronToolkit } from '../dist/TronToolkit.js'
import { logger } from '../dist/utils/logger.js'
import { config } from 'dotenv'

// Load environment variables from parent directory
config({ path: '../.env' })

/**
 * Test LayerZero Cross-Chain Flow on Tron
 * Creates, fulfills, and proves an intent to test the LayerZero bridge to Optimism
 */
class TestLayerZeroCrossChain {
  private toolkit: TronToolkit

  // Test amount (0 TRX)
  private readonly TEST_AMOUNT = 0

  // Chain IDs
  private readonly TRON_CHAIN_ID = 728126428 // Tron mainnet chain ID
  private readonly OPTIMISM_CHAIN_ID = 10 // Optimism chain ID
  private readonly OPTIMISM_ENDPOINT_ID = 30111 // LayerZero endpoint ID for Optimism

  // Contract addresses - loaded from environment
  private readonly TRON_PORTAL: string
  private readonly TRON_LAYERZERO_PROVER: string
  private readonly PRIVATE_KEY: string

  constructor() {
    // Load addresses from environment
    this.TRON_PORTAL = process.env.TRON_PORTAL || 'TCqfi3FFEcmWdNzw7bmjrjFrpVgKmsp552'
    this.TRON_LAYERZERO_PROVER = process.env.TRON_LAYERZERO_PROVER || 'TVaUrbN3cm6xxvi4e1fc1jUhs19mbtLEd7'
    this.PRIVATE_KEY = process.env.TRON_PRIVATE_KEY!

    if (!this.PRIVATE_KEY) {
      throw new Error('TRON_PRIVATE_KEY environment variable is required')
    }

    this.toolkit = new TronToolkit({
      network: 'mainnet',
      privateKey: this.PRIVATE_KEY,
    })
  }

  /**
   * Create a test intent that transfers 0 TRX to deployer
   */
  private createTestIntent(deployerAddress: string): any {
    const tronWeb = this.toolkit.getTronWeb()
    const currentTime = Math.floor(Date.now() / 1000)

    // Convert Tron base58 addresses to hex for ABI encoding
    const deployerHex = '0x' + tronWeb.address.toHex(deployerAddress).substring(2)
    const portalHex = '0x' + tronWeb.address.toHex(this.TRON_PORTAL).substring(2)
    const proverHex = '0x' + tronWeb.address.toHex(this.TRON_LAYERZERO_PROVER).substring(2)

    // Create route tokens (empty for TRX transfer)
    const routeTokens: any[] = []

    // Create calls (send 0 TRX to deployer) - convert to tuple array
    const calls = [[deployerHex, '0x', this.TEST_AMOUNT]]

    // Create reward tokens (empty for this test)
    const rewardTokens: any[] = []

    // Create route
    const route = {
      salt: tronWeb.sha3(`test-salt-${currentTime}`),
      deadline: currentTime + 3600000, // 1000 hours from now
      portal: portalHex,
      tokens: routeTokens,
      calls: calls
    }

    // Create reward
    const reward = {
      deadline: currentTime + 3600, // 1 hour from now
      creator: deployerHex,
      prover: proverHex,
      nativeAmount: 0,
      tokens: rewardTokens
    }

    return {
      destination: this.OPTIMISM_CHAIN_ID,
      route: route,
      reward: reward
    }
  }

  /**
   * Hash an intent using the same logic as Solidity
   */
  private hashIntent(intent: any): string {
    const tronWeb = this.toolkit.getTronWeb()
    
    // IMPORTANT: All addresses must be in bytes32 hex form for hash consistency
    // Convert all addresses to bytes32 format like the intent creation does
    const portalBytes32 = intent.route.portal // Already in hex format
    const creatorBytes32 = intent.reward.creator // Already in hex format  
    const proverBytes32 = intent.reward.prover // Already in hex format
    
    // Process tokens and calls arrays with proper hex addresses
    const routeTokensForHash = intent.route.tokens.map((t: any) => [t.address || t[0], t.amount || t[1]])
    const routeCallsForHash = intent.route.calls.map((c: any) => [c.target || c[0], c.data || c[1], c.value || c[2]])
    const rewardTokensForHash = intent.reward.tokens.map((t: any) => [t.address || t[0], t.amount || t[1]])
    
    // Encode route struct exactly like Solidity abi.encode
    const routeEncoded = tronWeb.utils.abi.encodeParams(
      ['bytes32', 'uint64', 'address', '(address,uint256)[]', '(address,bytes,uint256)[]'],
      [
        intent.route.salt,
        intent.route.deadline,
        portalBytes32,
        routeTokensForHash,
        routeCallsForHash
      ]
    )
    console.log('Route encoded:', routeEncoded)
    const routeHash = tronWeb.sha3(routeEncoded)
    console.log('Route hash:', routeHash)

    // Encode reward struct exactly like Solidity abi.encode
    const rewardEncoded = tronWeb.utils.abi.encodeParams(
      ['uint64', 'address', 'address', 'uint256', '(address,uint256)[]'],
      [
        intent.reward.deadline,
        creatorBytes32,
        proverBytes32,
        intent.reward.nativeAmount,
        rewardTokensForHash
      ]
    )
    console.log('Reward encoded:', rewardEncoded)
    const rewardHash = tronWeb.sha3(rewardEncoded)
    console.log('Reward hash:', rewardHash)

    // Match Solidity: keccak256(abi.encodePacked(_intent.destination, routeHash, rewardHash))
    // For encodePacked: uint64 destination is encoded as exactly 8 bytes in big-endian
    // Convert destination to Buffer as big-endian uint64 (8 bytes)
    const destinationBuffer = Buffer.alloc(8)
    destinationBuffer.writeBigUInt64BE(BigInt(intent.destination))
    const destinationHex = destinationBuffer.toString('hex')
    
    // Remove '0x' prefixes and concatenate the raw bytes
    const routeHashBytes = routeHash.substring(2)
    const rewardHashBytes = rewardHash.substring(2)
    const packedData = '0x' + destinationHex + routeHashBytes + rewardHashBytes
    
    console.log('EncodePacked inputs:')
    console.log(`  destination (${intent.destination}):`, destinationHex)
    console.log(`  routeHash:`, routeHash)
    console.log(`  rewardHash:`, rewardHash)
    console.log(`  packed:`, packedData)
    
    const finalHash = tronWeb.sha3(packedData)
    console.log('Final intent hash:', finalHash)
    return finalHash
  }

  /**
   * Execute a transaction using triggerSmartContract
   */
  private async executeTriggerSmartContract(
    contractAddress: string,
    functionSignature: string,
    parameters: any[],
    options: { feeLimit?: number; callValue?: number } = {}
  ): Promise<string> {
    const tronWeb = this.toolkit.getTronWeb()
    const { feeLimit = 150000000, callValue = 0 } = options

    try {
      // Convert raw parameters to TronWeb format if not already formatted
      const formattedParameters = parameters.map(param => {
        if (typeof param === 'object' && param !== null && 'type' in param && 'value' in param) {
          return param // Already formatted
        } else {
          // Raw parameter - return as is for TronWeb
          return param
        }
      })

      const transaction = await tronWeb.transactionBuilder.triggerSmartContract(
        contractAddress,
        functionSignature,
        { feeLimit, callValue },
        formattedParameters,
        tronWeb.defaultAddress.base58
      )

      logger.info(`Transaction built for ${functionSignature}`)
      logger.info('Raw transaction hex:', transaction.transaction.raw_data_hex.substring(0, 100) + '...')

      if (transaction.result && transaction.result.result) {
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
   * Encode proofs for LayerZero prover
   */
  private encodeProofs(intentHashes: string[], claimants: string[]): string {
    if (intentHashes.length !== claimants.length) {
      throw new Error('Array length mismatch')
    }

    const tronWeb = this.toolkit.getTronWeb()
    let encodedProofs = '0x'

    for (let i = 0; i < intentHashes.length; i++) {
      // Remove '0x' prefix and pad to 32 bytes
      const hashHex = intentHashes[i].replace('0x', '').padStart(64, '0')
      const claimantHex = claimants[i].replace('0x', '').padStart(64, '0')
      
      encodedProofs += hashHex + claimantHex
    }

    return encodedProofs
  }

  /**
   * Run the complete LayerZero cross-chain test
   */
  async run(): Promise<void> {
    try {
      const tronWeb = this.toolkit.getTronWeb()
      const deployerAddress = tronWeb.defaultAddress.base58

      logger.info('Testing LayerZero Cross-Chain Flow on Tron Mainnet')
      logger.info(`Deployer address: ${deployerAddress}`)
      logger.info(`Tron Portal address: ${this.TRON_PORTAL}`)
      logger.info(`Tron LayerZero Prover address: ${this.TRON_LAYERZERO_PROVER}`)

      // Create test intent
      const intent = this.createTestIntent(deployerAddress)
      const intentHash = this.hashIntent(intent)
      // Use EXACT same reward hash calculation as in hashIntent method (direct encoding)
      const rewardEncoded = tronWeb.utils.abi.encodeParams(
        ['uint64', 'address', 'address', 'uint256', '(address,uint256)[]'],
        [
          intent.reward.deadline,
          intent.reward.creator, // Already in hex format
          intent.reward.prover, // Already in hex format
          intent.reward.nativeAmount,
          intent.reward.tokens.map((t: any) => [t.address || t[0], t.amount || t[1]])
        ]
      )
      const rewardHash = tronWeb.sha3(rewardEncoded)

      logger.info(`Created Intent Hash: ${intentHash}`)
      
      // Prepare data for LayerZero prover - convert Tron address to proper bytes32
      const deployerHexAddress = tronWeb.address.toHex(deployerAddress)
      const claimantBytes32 = '0x' + deployerHexAddress.substring(2).padStart(64, '0')
      
      // Debug: log the intent structure
      logger.info('Intent structure for debugging:')
      logger.info('Route:', JSON.stringify(intent.route, null, 2))
      logger.info('Reward:', JSON.stringify(intent.reward, null, 2))
      logger.info(`Reward Hash: ${rewardHash}`)
      
      // Debug claimant conversion
      logger.info(`Deployer hex: ${deployerHexAddress}`)
      logger.info(`Claimant bytes32: ${claimantBytes32}`)
      
      // Verify addresses are consistent
      logger.info(`Portal address in route: ${intent.route.portal}`)
      logger.info(`Portal we're calling: ${this.TRON_PORTAL}`)
      
      // Convert and verify they're the same
      const portalBase58FromHex = tronWeb.address.fromHex(intent.route.portal)
      logger.info(`Portal hex converted to base58: ${portalBase58FromHex}`)
      logger.info(`Addresses match: ${portalBase58FromHex === this.TRON_PORTAL}`)

      // Use Optimism LayerZero prover address as source chain prover
      const optimismProverAddressBytes32 = '0x000000000000000000000000b75100b13106eb1e621c749d2959bb5280f616d5'

      // Create LayerZero options (executor options)
      const options = '0x00030100110100000000000000000000000000030d40' // Basic executor option

      const lzData = tronWeb.utils.abi.encodeParams(
        ['bytes32', 'bytes', 'uint256'],
        [
          optimismProverAddressBytes32, // sourceChainProver
          options, // options
          0 // gasLimit (0 = use default)
        ]
      )

      logger.info('=== LZ DATA OBJECT ===')
      logger.info(lzData)
      logger.info('=====================')

      logger.info('=== STEP 1: Fulfilling Intent ===')

      // Log exact parameters being sent to fulfill
      const routeForFulfill = [
        intent.route.salt,
        intent.route.deadline,
        intent.route.portal,
        intent.route.tokens.map((t: any) => [t.address || t[0], t.amount || t[1]]),
        intent.route.calls.map((c: any) => [c.target || c[0], c.data || c[1], c.value || c[2]])
      ]
      
      logger.info('Fulfill parameters:')
      logger.info(`intentHash: ${intentHash}`)
      logger.info(`routeForFulfill:`, JSON.stringify(routeForFulfill, null, 2))
      logger.info(`rewardHash: ${rewardHash}`)
      logger.info(`claimantBytes32: ${claimantBytes32}`)

      // Use the working configure script pattern - map arrays properly
      const fulfillTxid = await this.executeTriggerSmartContract(
        this.TRON_PORTAL,
        'fulfill(bytes32,(bytes32,uint64,address,(address,uint256)[],(address,bytes,uint256)[]),bytes32,bytes32)',
        [
          { type: 'bytes32', value: intentHash },
          { 
            type: '(bytes32,uint64,address,(address,uint256)[],(address,bytes,uint256)[])', 
            value: routeForFulfill
          },
          { type: 'bytes32', value: rewardHash },
          { type: 'bytes32', value: claimantBytes32 }
        ]
      )

      logger.info('Intent fulfilled successfully!')
      logger.info(`Fulfill Transaction ID: ${fulfillTxid}`)

      // Check if intent was fulfilled by querying claimants mapping
      logger.info('Checking fulfillment status...')
      const claimantResult = await tronWeb.transactionBuilder.triggerSmartContract(
        this.TRON_PORTAL,
        'claimants(bytes32)',
        { feeLimit: 50000000, callValue: 0 },
        [{ type: 'bytes32', value: intentHash }],
        tronWeb.defaultAddress.base58
      )

      if (claimantResult.result && claimantResult.result.result && claimantResult.constant_result) {
        const claimantData = claimantResult.constant_result[0]
        logger.info(`Intent fulfilled with claimant: ${claimantData}`)
      }

      logger.info('=== STEP 2: Getting LayerZero Fee ===')

      // Get fee for the proof
      const intentHashes = [intentHash]
      const claimants = [claimantBytes32]
      const encodedProofs = this.encodeProofs(intentHashes, claimants)

      const feeResult = await tronWeb.transactionBuilder.triggerSmartContract(
        this.TRON_LAYERZERO_PROVER,
        'fetchFee(uint64,bytes,bytes)',
        { feeLimit: 50000000, callValue: 0 },
        [
          { type: 'uint64', value: this.OPTIMISM_ENDPOINT_ID },
          { type: 'bytes', value: encodedProofs },
          { type: 'bytes', value: lzData }
        ],
        tronWeb.defaultAddress.base58
      )

      let fee = 0
      if (feeResult.result && feeResult.result.result && feeResult.constant_result) {
        fee = parseInt(feeResult.constant_result[0], 16)
        logger.info(`Required fee: ${fee} sun`)
      } else {
        throw new Error('Failed to get LayerZero fee')
      }

      // Check wallet balance
      const balance = await tronWeb.trx.getBalance(deployerAddress)
      logger.info(`Wallet balance: ${balance} sun`)

      if (balance < fee) {
        logger.error(`Insufficient balance for fee. Required: ${fee}, Available: ${balance}`)
        return
      }

      logger.info('=== STEP 3: Proving Intent ===')

      logger.info('Calling prove with:')
      logger.info(`  - destination chain ID: ${this.OPTIMISM_ENDPOINT_ID}`)
      logger.info(`  - prover address: ${this.TRON_LAYERZERO_PROVER}`)
      logger.info(`  - intent hash: ${intentHash}`)
      logger.info(`  - fee: ${fee}`)

      // Prove the intent
      const proveTxid = await this.executeTriggerSmartContract(
        this.TRON_PORTAL,
        'prove(address,uint64,bytes32[],bytes)',
        [
          { type: 'address', value: this.TRON_LAYERZERO_PROVER },
          { type: 'uint64', value: this.OPTIMISM_ENDPOINT_ID },
          { type: 'bytes32[]', value: intentHashes },
          { type: 'bytes', value: lzData }
        ],
        { feeLimit: 200000000, callValue: fee }
      )

      logger.info('Intent proven successfully!')
      logger.info(`Prove Transaction ID: ${proveTxid}`)

      // Check if proof was recorded
      logger.info('Verifying proof data...')
      const proofResult = await tronWeb.transactionBuilder.triggerSmartContract(
        this.TRON_LAYERZERO_PROVER,
        'provenIntents(bytes32)',
        { feeLimit: 50000000, callValue: 0 },
        [{ type: 'bytes32', value: intentHash }],
        tronWeb.defaultAddress.base58
      )

      if (proofResult.result && proofResult.result.result && proofResult.constant_result) {
        const proofData = proofResult.constant_result[0]
        logger.info(`Proof data recorded: ${proofData}`)
      }

      logger.info('LayerZero cross-chain test completed!')
      logger.info('Next steps:')
      logger.info('1. Check LayerZero scan for the cross-chain message')
      logger.info('2. Verify the proof was received on Optimism manually')
      logger.info('3. Check the LayerZeroProver contract on Optimism for the recorded proof')
      
      logger.info('')
      logger.info('=== TEST SUMMARY ===')
      logger.info(`Intent Hash: ${intentHash}`)
      logger.info(`Fulfill TX: ${fulfillTxid}`)
      logger.info(`Prove TX: ${proveTxid}`)
      logger.info(`LayerZero Fee: ${fee} sun`)
      logger.info('Cross-chain message sent from Tron → Optimism!')

    } catch (error) {
      logger.error('LayerZero cross-chain test failed:', error)
      throw error
    }
  }
}

/**
 * Main execution function
 */
async function main() {
  try {
    const testScript = new TestLayerZeroCrossChain()
    await testScript.run()
    logger.info('LayerZero cross-chain test completed successfully!')
  } catch (error) {
    logger.error('Test failed:', error)
    process.exit(1)
  }
}

// Execute main function if this file is run directly
if (require.main === module) {
  main()
}

export { TestLayerZeroCrossChain }