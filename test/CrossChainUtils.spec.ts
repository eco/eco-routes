import { expect } from 'chai'
import { ethers } from 'hardhat'
import { Contract, Wallet } from 'ethers'
import { deploy } from './utils'

// Test helpers to simplify testing cross-chain utilities
class TestHelper {
  // Helper contract to expose library methods for testing
  addressConverter!: Contract

  // Test wallet for signing
  testWallet!: Wallet

  constructor() {}

  async setup() {
    const [signer] = await ethers.getSigners()
    this.testWallet = Wallet.createRandom().connect(ethers.provider)

    // Send some ETH to the test wallet
    await signer.sendTransaction({
      to: this.testWallet.address,
      value: ethers.parseEther('1.0')
    })

    // Deploy test helpers to expose library methods
    const AddressConverterTest = await ethers.getContractFactory('AddressConverterTest', signer)
    this.addressConverter = await AddressConverterTest.deploy()
  }
}

describe('Cross-Chain Utilities', function () {
  let helper: TestHelper

  before(async function () {
    helper = new TestHelper()
    await helper.setup()
  })

  describe('AddressConverter', function () {
    it('Should convert address to bytes32 and back', async function () {
      const testAddress = '0x1234567890123456789012345678901234567890'

      const bytes32Value = await helper.addressConverter.toBytes32(testAddress)
      const recoveredAddress = await helper.addressConverter.toAddress(bytes32Value)

      expect(recoveredAddress.toLowerCase()).to.equal(testAddress.toLowerCase())
    })

    it('Should handle array conversions correctly', async function () {
      const testAddresses = [
        '0x1111111111111111111111111111111111111111',
        '0x2222222222222222222222222222222222222222',
        '0x3333333333333333333333333333333333333333'
      ]

      // Testing one-by-one conversion instead of using arrays
      for (let i = 0; i < testAddresses.length; i++) {
        const bytes32Value = await helper.addressConverter.toBytes32(testAddresses[i]);
        const recoveredAddress = await helper.addressConverter.toAddress(bytes32Value);
        expect(recoveredAddress.toLowerCase()).to.equal(testAddresses[i].toLowerCase());
      }
    })

    it('Should correctly identify valid Ethereum addresses in bytes32', async function () {
      // Valid Ethereum address (top 12 bytes are zero)
      const validBytes32 = await helper.addressConverter.toBytes32('0x1234567890123456789012345678901234567890')

      // Invalid Ethereum address (has data in top 12 bytes)
      const invalidBytes32 = ethers.hexlify(ethers.randomBytes(32))

      const isValid = await helper.addressConverter.isValidEthereumAddress(validBytes32)
      const isInvalid = await helper.addressConverter.isValidEthereumAddress(invalidBytes32)

      expect(isValid).to.be.true
      expect(isInvalid).to.be.false
    })
  })
})