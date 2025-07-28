const LayerZeroProver = artifacts.require('./LayerZeroProver.sol')

module.exports = function (deployer, network, accounts) {
  // Deploy only LayerZeroProver with constructor arguments
  const endpoint = '0x0000000000000000000000000000000000000000' // Replace with actual endpoint
  const portal = '0x0000000000000000000000000000000000000000' // Replace with actual Portal address
  const provers = [
    '0x0000000000000000000000000000000000000000000000000000000000000001',
    '0x0000000000000000000000000000000000000000000000000000000000000002',
  ]
  const defaultGasLimit = 200000

  deployer
    .deploy(LayerZeroProver, endpoint, portal, provers, defaultGasLimit)
    .then(function () {
      console.log('LayerZeroProver deployed at:', LayerZeroProver.address)
    })
}
