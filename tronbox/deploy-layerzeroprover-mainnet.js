const TronWeb = require('tronweb')
const fs = require('fs')
require('dotenv').config()

// Read private key from environment
const privateKey = process.env.PRIVATE_KEY_TRON
if (!privateKey) {
  throw new Error(
    'PRIVATE_KEY_TRON not found in environment. Please set your private key: export PRIVATE_KEY_TRON=your_private_key_here',
  )
}

// Initialize TronWeb for TRON mainnet
const tronWeb = new TronWeb.TronWeb({
  fullHost: 'https://api.trongrid.io',
  privateKey,
})

console.log('🚀 Deploying LayerZeroProver contract to TRON mainnet...')
console.log('Network: TRON Mainnet')
console.log('Deployer address:', tronWeb.defaultAddress.base58)

async function deployLayerZeroProver() {
  try {
    // Read the pre-compiled LayerZeroProver contract
    const proverArtifact = JSON.parse(
      fs.readFileSync('./out/LayerZeroProver.sol/LayerZeroProver.json', 'utf8'),
    )

    console.log('📄 Loaded LayerZeroProver contract artifact')
    console.log('Contract name: LayerZeroProver')
    console.log('Bytecode length:', proverArtifact.bytecode.object.length)

    // Constructor arguments for LayerZeroProver
    const endpoint = 'TAy9xwjYjBBN6kutzrZJaAZJHCAejjK1V9' // LayerZero endpoint
    const portal = 'TEQEU8Q23BVFgV2jfCSt2gKdAkbh8BFUbU' // Portal address

    // Provers array - contains the Optimism LayerZeroProver address as bytes32
    const optimisimProverAddress = '0x68dEE1F4F344D0182c3D2c49D987C1E6846f5534'
    // For Tron, we need to encode this as a proper bytes32 array
    const provers = [optimisimProverAddress.padEnd(66, '0')] // Pad to 32 bytes

    const defaultGasLimit = 0 // Not used for Tron - we use energy/bandwidth instead

    console.log('🔧 Constructor arguments:')
    console.log('  - Endpoint:', endpoint)
    console.log('  - Portal:', portal)
    console.log('  - Provers:', provers)
    console.log(
      '  - Default Gas Limit:',
      defaultGasLimit,
      '(not used for Tron)',
    )

    console.log('⏳ Deploying contract to mainnet...')

    // Create a smart contract transaction with constructor parameters
    const transaction = await tronWeb.transactionBuilder.createSmartContract(
      {
        abi: proverArtifact.abi,
        bytecode: proverArtifact.bytecode.object,
        feeLimit: 1000000000, // 1 TRX
        callValue: 0,
        userFeePercentage: 100, // Mainnet fee percentage
        originEnergyLimit: 10000000, // 10M energy for contract deployment
        parameters: [endpoint, portal, provers, defaultGasLimit], // Pass constructor parameters
      },
      tronWeb.defaultAddress.base58,
    )

    // Sign the transaction
    const signedTx = await tronWeb.trx.sign(transaction)

    // Broadcast the transaction
    const result = await tronWeb.trx.broadcast(signedTx)

    console.log('🔍 Deployment result:', JSON.stringify(result, null, 2))

    if (result.result) {
      console.log('✅ LayerZeroProver deployed successfully to TRON mainnet!')
      console.log(
        '📍 Contract address:',
        result.contract_address || result.contractAddress,
      )
      console.log(
        '🔗 View on Tronscan: https://tronscan.org/#/contract/' +
          (result.contract_address || result.contractAddress),
      )
      console.log('📋 Transaction ID:', result.txid)
    } else {
      console.error('❌ Deployment failed:', result)
    }
  } catch (error) {
    console.error('❌ Error:', error)
  }
}

// Run the deployment
deployLayerZeroProver()
