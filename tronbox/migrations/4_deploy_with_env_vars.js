const Portal = artifacts.require('./Portal.sol')
const LayerZeroProver = artifacts.require('./LayerZeroProver.sol')

module.exports = function (deployer, network, accounts) {
  // Read constructor arguments from environment variables
  const LAYERZERO_ENDPOINT =
    process.env.LAYERZERO_ENDPOINT ||
    '0x0000000000000000000000000000000000000000'
  const PROVERS = process.env.PROVERS
    ? process.env.PROVERS.split(',')
    : [
        '0x0000000000000000000000000000000000000000000000000000000000000001',
        '0x0000000000000000000000000000000000000000000000000000000000000002',
      ]
  const DEFAULT_GAS_LIMIT = process.env.DEFAULT_GAS_LIMIT || 200000

  console.log('Deployment parameters:')
  console.log('LayerZero Endpoint:', LAYERZERO_ENDPOINT)
  console.log('Provers:', PROVERS)
  console.log('Default Gas Limit:', DEFAULT_GAS_LIMIT)

  // Deploy Portal first
  deployer
    .deploy(Portal)
    .then(function () {
      console.log('Portal deployed at:', Portal.address)

      // Deploy LayerZeroProver with constructor arguments
      return deployer.deploy(
        LayerZeroProver,
        LAYERZERO_ENDPOINT,
        Portal.address,
        PROVERS,
        DEFAULT_GAS_LIMIT,
      )
    })
    .then(function () {
      console.log('LayerZeroProver deployed at:', LayerZeroProver.address)
    })
}
