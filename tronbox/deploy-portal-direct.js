const { execSync } = require('child_process')

// Set the private key environment variable
process.env.PRIVATE_KEY_TRON =
  'CB933CFBBE4FDB37DC2E1C8B1943142FCEB533554971DD408C6E3B09D33C67C5'

console.log(
  '🚀 Deploying Portal contract directly using pre-compiled artifacts...',
)
console.log(
  'Using private key:',
  process.env.PRIVATE_KEY_TRON.substring(0, 10) + '...',
)

try {
  // Use TronBox console to deploy directly
  const deployCommand = `
    const Portal = artifacts.require('./Portal.sol');
    console.log('Deploying Portal contract...');
    Portal.new().then(function(instance) {
      console.log('✅ Portal deployed successfully!');
      console.log('📍 Portal address:', instance.address);
      console.log('🔗 View on Tronscan: https://tronscan.org/#/contract/' + instance.address);
      process.exit(0);
    }).catch(function(error) {
      console.error('❌ Deployment failed:', error);
      process.exit(1);
    });
  `

  execSync(`echo '${deployCommand}' | tronbox console --network shasta`, {
    stdio: 'inherit',
    env: process.env,
  })
} catch (error) {
  console.error('❌ Deployment failed:', error.message)
  process.exit(1)
}
