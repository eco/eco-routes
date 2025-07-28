const { execSync } = require('child_process')

// Set the private key environment variable
process.env.PRIVATE_KEY_TRON =
  'CB933CFBBE4FDB37DC2E1C8B1943142FCEB533554971DD408C6E3B09D33C67C5'

console.log('🚀 Deploying Portal contract to Shasta testnet...')
console.log(
  'Using private key:',
  process.env.PRIVATE_KEY_TRON.substring(0, 10) + '...',
)
console.log('Using pre-compiled artifacts (no compilation)...')

try {
  // Run the migration without compilation flags - should use existing artifacts
  execSync('tronbox migrate --network shasta --from 5 --to 5', {
    stdio: 'inherit',
    env: process.env,
  })

  console.log('✅ Portal deployment completed successfully!')
} catch (error) {
  console.error('❌ Deployment failed:', error.message)
  process.exit(1)
}
