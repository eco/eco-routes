const TronWeb = require('tronweb')
const fs = require('fs')

// Initialize TronWeb for TRON mainnet
const tronWeb = new TronWeb.TronWeb({
  fullHost: 'https://api.trongrid.io',
  privateKey:
    'CB933CFBBE4FDB37DC2E1C8B1943142FCEB533554971DD408C6E3B09D33C67C5',
})

console.log('🚀 Deploying Portal contract to TRON mainnet...')
console.log('Network: TRON Mainnet')
console.log('Deployer address:', tronWeb.defaultAddress.base58)

async function deployPortal() {
  try {
    // Read the pre-compiled Portal contract
    const portalArtifact = JSON.parse(
      fs.readFileSync('./build/contracts/Portal.json', 'utf8'),
    )

    console.log('📄 Loaded Portal contract artifact')
    console.log('Contract name:', portalArtifact.contractName)
    console.log('Bytecode length:', portalArtifact.bytecode.length)

    // Deploy using raw transaction
    console.log('⏳ Deploying contract to mainnet...')

    // Create a smart contract transaction
    const transaction = await tronWeb.transactionBuilder.createSmartContract(
      {
        abi: portalArtifact.abi,
        bytecode: portalArtifact.bytecode,
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
