const TronWeb = require('tronweb')

// Generate a new account
const account = TronWeb.utils.accounts.generateAccount()

console.log('=== Generated TronWeb Key Pair ===')
console.log('Private Key:', account.privateKey)
console.log('Public Key:', account.publicKey)
console.log('Address:', account.address.base58)
console.log('Hex Address:', account.address.hex)

// Display .env format for reference
console.log('\n=== For .env file (if you want to save later) ===')
console.log(`export PRIVATE_KEY_MAINNET=${account.privateKey}`)
console.log(`export PRIVATE_KEY_SHASTA=${account.privateKey}`)
console.log(`export PRIVATE_KEY_NILE=${account.privateKey}`)

console.log('\n✅ Key pair generated successfully!')
console.log('📝 Copy the private key to use with TronBox deployments')
