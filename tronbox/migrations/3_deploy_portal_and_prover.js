const Portal = artifacts.require('./Portal.sol')
const LayerZeroProver = artifacts.require('./LayerZeroProver.sol')

module.exports = function (deployer, network, accounts) {
  // Deploy Portal first (no constructor arguments)
  deployer
    .deploy(Portal)
    .then(function () {
      console.log('Portal deployed at:', Portal.address)

      // Deploy LayerZeroProver with constructor arguments
      // You'll need to replace these with actual values for your network
      const endpoint = '0x0000000000000000000000000000000000000000' // LayerZero endpoint address
      const portal = Portal.address // Use the deployed Portal address
      const provers = [
        '0x0000000000000000000000000000000000000000000000000000000000000001', // Example prover address
        '0x0000000000000000000000000000000000000000000000000000000000000002', // Example prover address
      ]
      const defaultGasLimit = 200000 // Default gas limit

      return deployer.deploy(
        LayerZeroProver,
        endpoint,
        portal,
        provers,
        defaultGasLimit,
      )
    })
    .then(function () {
      console.log('LayerZeroProver deployed at:', LayerZeroProver.address)
    })
}
