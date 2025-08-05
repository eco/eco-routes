const { execSync } = require('child_process')

// Check if private key is set in environment
if (!process.env.PRIVATE_KEY_TRON) {
  console.error('❌ Error: PRIVATE_KEY_TRON not found in environment')
  console.error(
    'Please set your private key: export PRIVATE_KEY_TRON=your_private_key_here',
  )
  process.exit(1)
}

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
