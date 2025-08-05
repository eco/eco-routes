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

console.log('🚀 Deploying Portal contract to TRON mainnet...')
console.log('Network: TRON Mainnet')
console.log('Deployer address:', tronWeb.defaultAddress.base58)

async function deployPortal() {
  try {
    // Read the pre-compiled Portal contract
    const portalArtifact = JSON.parse(
      fs.readFileSync('./out/Portal.sol/Portal.json', 'utf8'),
    )

    console.log('📄 Loaded Portal contract artifact')
    console.log('Contract name: Portal')
    console.log('Bytecode length:', portalArtifact.bytecode.object.length)

    // Deploy using raw transaction
    console.log('⏳ Deploying contract to mainnet...')

    // Create a smart contract transaction
    const transaction = await tronWeb.transactionBuilder.createSmartContract(
      {
        abi: portalArtifact.abi,
        bytecode: portalArtifact.bytecode.object,
        feeLimit: 1000000000, // 1 TRX
        callValue: 0,
        userFeePercentage: 100, // Mainnet fee percentage
        originEnergyLimit: 10000000,
      },
      tronWeb.defaultAddress.base58,
    )

    // Sign the transaction
    const signedTx = await tronWeb.trx.sign(transaction)

    // Broadcast the transaction
    const result = await tronWeb.trx.broadcast(signedTx)

    if (result.result) {
      console.log('✅ Portal deployed successfully to TRON mainnet!')
      console.log('📍 Portal address:', result.contract_address)
      console.log(
        '🔗 View on Tronscan: https://tronscan.org/#/contract/' +
          result.contract_address,
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
deployPortal()
