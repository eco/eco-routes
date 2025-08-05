const TronWeb = require('tronweb')
const fs = require('fs')
require('dotenv').config()

// Read private key from environment file
const privateKey = process.env.TRON_PRIVATE_KEY
if (!privateKey) {
  console.error('❌ Error: TRON_PRIVATE_KEY not found in .env file')
  console.error('Please add your private key to the .env file:')
  console.error('TRON_PRIVATE_KEY=your_private_key_here')
  process.exit(1)
}

// Initialize TronWeb for Shasta testnet
const tronWeb = new TronWeb.TronWeb({
  fullHost: 'https://api.shasta.trongrid.io',
  privateKey,
})

console.log('🚀 Calling prove method on LayerZero Prover...')
console.log('Network: Shasta Testnet')
console.log('Deployer address:', tronWeb.defaultAddress.base58)

async function callProveMethod() {
  try {
    // LayerZero Prover contract address (replace with actual deployed address)
    const proverAddress = 'TCT5FvMTuUCspdY689LbKbUThCwBVUw4tM' // Replace with actual address

    // Read the LayerZeroProver contract ABI
    const proverArtifact = JSON.parse(
      fs.readFileSync('./build/contracts/LayerZeroProver.json', 'utf8'),
    )

    console.log('📄 Loaded LayerZeroProver contract artifact')
    console.log('Contract address:', proverAddress)

    // Example parameters for the prove method
    const sender = tronWeb.defaultAddress.base58 // Address of the original transaction sender
    const sourceChainId = 10 // Optimism chain ID
    const intentHashes = [
      '0x1234567890123456789012345678901234567890123456789012345678901234',
      '0x2345678901234567890123456789012345678901234567890123456789012345',
    ]
    const claimants = [
      '0x00000000000000000000000068753E04dD540031A5bc33205aBe101915EC8692',
      '0x00000000000000000000000068dEE1F4F344D0182c3D2c49D987C1E6846f5534',
    ]

    // Data for LayerZero message formatting
    // This should contain the source chain prover address and options
    const sourceChainProver =
      '0x00000000000000000000000068dEE1F4F344D0182c3D2c49D987C1E6846f5534' // Optimism prover address
    const options = '0x' // Empty options for default gas limit
    const data = tronWeb.utils.abi.encodeParameters(
      ['bytes32', 'bytes'],
      [sourceChainProver, options],
    )

    console.log('🔧 Prove method parameters:')
    console.log('  - Sender:', sender)
    console.log('  - Source Chain ID:', sourceChainId)
    console.log('  - Intent Hashes:', intentHashes)
    console.log('  - Claimants:', claimants)
    console.log('  - Data length:', data.length)

    // First, let's get the fee estimate
    console.log('💰 Estimating fee...')
    const feeEstimate = await tronWeb
      .contract()
      .at(proverAddress)
      .then((contract) => {
        return contract
          .fetchFee(sourceChainId, intentHashes, claimants, data)
          .call()
      })

    console.log('Estimated fee:', feeEstimate.toString(), 'TRX')

    // Call the prove method
    console.log('⏳ Calling prove method...')

    const transaction =
      await tronWeb.transactionBuilder.triggerConstantContract(
        proverAddress,
        'prove(address,uint256,bytes32[],bytes32[],bytes)',
        {
          feeLimit: 1000000000, // 1 TRX
          callValue: feeEstimate.toString(), // Send the estimated fee
          userFeePercentage: 50,
          originEnergyLimit: 10000000, // 10M energy
        },
        [
          { type: 'address', value: sender },
          { type: 'uint256', value: sourceChainId.toString() },
          { type: 'bytes32[]', value: intentHashes },
          { type: 'bytes32[]', value: claimants },
          { type: 'bytes', value: data },
        ],
        tronWeb.defaultAddress.base58,
      )

    // Sign the transaction
    const signedTx = await tronWeb.trx.sign(transaction)

    // Broadcast the transaction
    const result = await tronWeb.trx.broadcast(signedTx)

    console.log('🔍 Prove method result:', JSON.stringify(result, null, 2))

    if (result.result) {
      console.log('✅ Prove method called successfully!')
      console.log('📋 Transaction ID:', result.txid)
      console.log(
        '🔗 View on Tronscan: https://shasta.tronscan.org/#/transaction/' +
          result.txid,
      )
    } else {
      console.error('❌ Prove method call failed:', result)
    }
  } catch (error) {
    console.error('❌ Error:', error)
  }
}

// Run the prove method call
callProveMethod()
