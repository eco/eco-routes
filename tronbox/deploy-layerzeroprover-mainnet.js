const TronWeb = require('tronweb')
const fs = require('fs')
require('dotenv').config({ path: '../.env' })

// Read private key from environment
const privateKey = process.env.TRON_PRIVATE_KEY
if (!privateKey) {
  throw new Error(
    'TRON_PRIVATE_KEY not found in environment. Please set your private key: export TRON_PRIVATE_KEY=your_private_key_here',
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
    // Read the pre-compiled LayerZeroProver contract from TronBox build
    const proverArtifact = JSON.parse(
      fs.readFileSync('./build/contracts/LayerZeroProver.json', 'utf8'),
    )

    console.log('📄 Loaded LayerZeroProver contract artifact')
    console.log('Contract name: LayerZeroProver')
    console.log('Bytecode length:', proverArtifact.bytecode.length)

    // Constructor arguments for LayerZeroProver
    const endpoint = 'TAy9xwjYjBBN6kutzrZJaAZJHCAejjK1V9' // LayerZero endpoint
    const delegate = 'TJJYsUz2F4fURzX2Rf4jDWDNdKf5Y86fnk' // Deployer as delegate
    const portal = 'TEQEU8Q23BVFgV2jfCSt2gKdAkbh8BFUbU' // Portal address

    // Provers array - read from environment variable
    const proversStr = process.env.TRON_PROVERS
    if (!proversStr) {
      throw new Error(
        'TRON_PROVERS not found in environment. Please set TRON_PROVERS=prover_address_here',
      )
    }

    // Parse provers string (comma-separated addresses)
    const proverAddresses = proversStr.split(',').map((addr) => addr.trim())
    const provers = proverAddresses.map((addr) => {
      // Remove '0x' prefix if present
      const cleanAddr = addr.startsWith('0x') ? addr.slice(2) : addr
      // Left-pad with zeroes to 64 characters (32 bytes)
      return '0x' + cleanAddr.padStart(64, '0')
    })

    const defaultGasLimit = 0 // Not used for Tron - we use energy/bandwidth instead

    console.log('🔧 Constructor arguments:')
    console.log('  - Endpoint:', endpoint)
    console.log('  - Delegate:', delegate)
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
        bytecode: proverArtifact.bytecode,
        feeLimit: 5000000000, // 5 TRX
        callValue: 0,
        userFeePercentage: 100, // Mainnet fee percentage
        originEnergyLimit: 5000000, // 5M energy for contract deployment
        parameters: [endpoint, delegate, portal, provers, defaultGasLimit], // Pass constructor parameters
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
