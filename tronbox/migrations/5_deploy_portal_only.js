const Portal = artifacts.require('./Portal.sol')

module.exports = function (deployer, network, accounts) {
  console.log('🚀 Deploying Portal contract only...')
  console.log('Network:', network)
  console.log('Deployer address:', accounts[0])

  // Deploy only Portal (no constructor arguments needed)
  deployer
    .deploy(Portal)
    .then(function () {
      console.log('✅ Portal deployed successfully!')
      console.log('📍 Portal address:', Portal.address)
      console.log(
        '🔗 View on Tronscan: https://tronscan.org/#/contract/' +
          Portal.address,
      )
    })
    .catch(function (error) {
      console.error('❌ Deployment failed:', error)
    })
}
