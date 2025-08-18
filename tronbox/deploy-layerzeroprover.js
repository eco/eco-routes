const TronWeb = require('tronweb')
const fs = require('fs')
require('dotenv').config()

// Read private key from environment file
const privateKey = process.env.PRIVATE_KEY_TRON
if (!privateKey) {
  console.error('❌ Error: PRIVATE_KEY_TRON not found in .env file')
  console.error('Please add your private key to the .env file:')
  console.error('PRIVATE_KEY_TRON=your_private_key_here')
  process.exit(1)
}

// Initialize TronWeb for Shasta testnet
const tronWeb = new TronWeb.TronWeb({
  fullHost: 'https://api.shasta.trongrid.io',
  privateKey,
})

console.log('🚀 Deploying LayerZeroProver contract using TronWeb...')
console.log('Network: Shasta Testnet')
console.log('Deployer address:', tronWeb.defaultAddress.base58)

async function deployLayerZeroProver() {
  try {
    // Read the pre-compiled LayerZeroProver contract
    const proverArtifact = JSON.parse(
      fs.readFileSync('./build/contracts/LayerZeroProver.json', 'utf8'),
    )

    console.log('📄 Loaded LayerZeroProver contract artifact')
    console.log('Contract name:', proverArtifact.contractName)
    console.log('Bytecode length:', proverArtifact.bytecode.length)

    // Constructor arguments for LayerZeroProver
    const endpoint = 'TCT5FvMTuUCspdY689LbKbUThCwBVUw4tM' // LayerZero endpoint
    const portal = 'TPCLkzVsyAHcscfQDwoXAbtEojfhhEX6oM' // Portal address

    // Convert base58 addresses to hex for provers array
    const prover1Hex =
      '0x0000000000000000000000000000000000000000000000000000000000000001'
    const prover2Hex =
      '0x0000000000000000000000000000000000000000000000000000000000000002'
    const provers = [prover1Hex, prover2Hex]

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

    // For now, let's try deploying without constructor parameters first
    // to see if the basic deployment works
    console.log('⏳ Deploying contract using raw transaction...')

    // Create a smart contract transaction with constructor parameters
    const transaction = await tronWeb.transactionBuilder.createSmartContract(
      {
        abi: proverArtifact.abi,
        bytecode: proverArtifact.bytecode,
        feeLimit: 1000000000, // 1 TRX
        callValue: 0,
        userFeePercentage: 50,
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
      console.log('✅ LayerZeroProver deployed successfully!')
      console.log(
        '📍 Contract address:',
        result.contract_address || result.contractAddress,
      )
      console.log(
        '🔗 View on Tronscan: https://shasta.tronscan.org/#/contract/' +
          (result.contract_address || result.contractAddress),
      )
      console.log('📋 Transaction ID:', result.txid)
      console.log(
        '⚠️  Note: Deployed without constructor parameters - may need manual initialization',
      )
    } else {
      console.error('❌ Deployment failed:', result)
    }
  } catch (error) {
    console.error('❌ Error:', error)
  }
}

// Run the deployment
deployLayerZeroProver()
