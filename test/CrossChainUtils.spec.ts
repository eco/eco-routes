import { expect } from 'chai'
import { ethers } from 'hardhat'
import { Contract, Wallet } from 'ethers'
import { deploy } from './utils'

// Test helpers to simplify testing cross-chain utilities
class TestHelper {
  // Helper contract to expose library methods for testing
  addressConverter!: Contract
  intentConverter!: Contract
  dualSignatureVerifier!: Contract
  
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
    
    const IntentConverterTest = await ethers.getContractFactory('IntentConverterTest', signer)
    this.intentConverter = await IntentConverterTest.deploy()
    
    const DualSignatureVerifierTest = await ethers.getContractFactory('DualSignatureVerifierTest', signer)
    this.dualSignatureVerifier = await DualSignatureVerifierTest.deploy()
  }
  
  // Create a sample EVM intent for testing
  createSampleEvmIntent() {
    const tokens = [
      { token: '0x1111111111111111111111111111111111111111', amount: 100n },
      { token: '0x2222222222222222222222222222222222222222', amount: 200n }
    ]
    
    const calls = [
      {
        target: '0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        data: '0x1234',
        value: 10n
      },
      {
        target: '0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
        data: '0x5678',
        value: 20n
      }
    ]
    
    const route = {
      salt: ethers.id('test_salt'),
      source: 1n,
      destination: 2n,
      inbox: '0xCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC',
      tokens,
      calls
    }
    
    const reward = {
      creator: this.testWallet.address,
      prover: '0xDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD',
      deadline: BigInt(Math.floor(Date.now() / 1000) + 3600),
      nativeValue: 50n,
      tokens
    }
    
    return { route, reward }
  }
  
  // Create an OnchainCrosschainOrderData for testing
  createSampleOrderData() {
    const { route, reward } = this.createSampleEvmIntent()
    
    return {
      route,
      creator: reward.creator,
      prover: reward.prover,
      nativeValue: reward.nativeValue,
      rewardTokens: reward.tokens
    }
  }
  
  // Create a GaslessCrosschainOrderData for testing
  createSampleGaslessOrderData() {
    const { route, reward } = this.createSampleEvmIntent()
    
    return {
      destination: route.destination,
      inbox: route.inbox,
      routeTokens: route.tokens,
      calls: route.calls,
      prover: reward.prover,
      nativeValue: reward.nativeValue,
      rewardTokens: reward.tokens
    }
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
      
      const bytes32Array = await helper.addressConverter.toBytes32Array(testAddresses)
      const recoveredAddresses = await helper.addressConverter.toAddressArray(bytes32Array)
      
      for (let i = 0; i < testAddresses.length; i++) {
        expect(recoveredAddresses[i].toLowerCase()).to.equal(testAddresses[i].toLowerCase())
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
  
  describe('IntentConverter', function () {
    it('Should convert TokenAmount between formats', async function () {
      const evmTokenAmount = {
        token: '0x1111111111111111111111111111111111111111',
        amount: 100n
      }
      
      const universalTokenAmount = await helper.intentConverter.toUniversalTokenAmount(evmTokenAmount)
      const convertedBack = await helper.intentConverter.toEvmTokenAmount(universalTokenAmount)
      
      expect(convertedBack.token.toLowerCase()).to.equal(evmTokenAmount.token.toLowerCase())
      expect(convertedBack.amount).to.equal(evmTokenAmount.amount)
    })
    
    it('Should convert Call between formats', async function () {
      const evmCall = {
        target: '0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        data: '0x1234',
        value: 10n
      }
      
      const universalCall = await helper.intentConverter.toUniversalCall(evmCall)
      const convertedBack = await helper.intentConverter.toEvmCall(universalCall)
      
      expect(convertedBack.target.toLowerCase()).to.equal(evmCall.target.toLowerCase())
      expect(convertedBack.data).to.equal(evmCall.data)
      expect(convertedBack.value).to.equal(evmCall.value)
    })
    
    it('Should convert complete Intent between formats', async function () {
      const evmIntent = helper.createSampleEvmIntent()
      
      const universalIntent = await helper.intentConverter.toUniversalIntent(evmIntent)
      const convertedBack = await helper.intentConverter.toEvmIntent(universalIntent)
      
      // Check route properties
      expect(convertedBack.route.salt).to.equal(evmIntent.route.salt)
      expect(convertedBack.route.source).to.equal(evmIntent.route.source)
      expect(convertedBack.route.destination).to.equal(evmIntent.route.destination)
      expect(convertedBack.route.inbox.toLowerCase()).to.equal(evmIntent.route.inbox.toLowerCase())
      
      // Check reward properties
      expect(convertedBack.reward.creator.toLowerCase()).to.equal(evmIntent.reward.creator.toLowerCase())
      expect(convertedBack.reward.prover.toLowerCase()).to.equal(evmIntent.reward.prover.toLowerCase())
      expect(convertedBack.reward.deadline).to.equal(evmIntent.reward.deadline)
      expect(convertedBack.reward.nativeValue).to.equal(evmIntent.reward.nativeValue)
      
      // Length checks for arrays
      expect(convertedBack.route.tokens.length).to.equal(evmIntent.route.tokens.length)
      expect(convertedBack.route.calls.length).to.equal(evmIntent.route.calls.length)
      expect(convertedBack.reward.tokens.length).to.equal(evmIntent.reward.tokens.length)
    })
  })
  
  describe('DualSignatureVerifier', function () {
    it('Should verify signatures with EVM and Universal formats', async function () {
      // Create sample order data
      const evmOrderData = helper.createSampleOrderData()
      
      // Convert to universal format
      const universalOrderData = await helper.intentConverter.toUniversalOnchainOrderData(evmOrderData)
      
      // Create a signature with the test wallet
      const domain = {
        name: 'Eco Protocol',
        version: '1',
        chainId: (await ethers.provider.getNetwork()).chainId,
        verifyingContract: helper.dualSignatureVerifier.target
      }
      
      // Sign the EVM version (we'd usually use the typehash here, but for testing we can just hash the values)
      const messageHash = await helper.dualSignatureVerifier.hashEvmOnchainOrderData(evmOrderData)
      const signature = await helper.testWallet.signMessage(ethers.getBytes(messageHash))
      
      // Verify with both formats
      const isValid = await helper.dualSignatureVerifier.verifyOnchainOrderSignature(
        evmOrderData,
        universalOrderData,
        signature,
        helper.testWallet.address,
        'Eco Protocol',
        '1'
      )
      
      expect(isValid).to.be.true
    })
    
    it('Should verify gasless signatures with EVM and Universal formats', async function () {
      // Create sample gasless order data
      const evmGaslessOrderData = helper.createSampleGaslessOrderData()
      
      // Convert to universal format
      const universalGaslessOrderData = await helper.intentConverter.toUniversalGaslessOrderData(evmGaslessOrderData)
      
      // Create a signature with the test wallet
      const domain = {
        name: 'Eco Protocol',
        version: '1',
        chainId: (await ethers.provider.getNetwork()).chainId,
        verifyingContract: helper.dualSignatureVerifier.target
      }
      
      // Sign the EVM version
      const messageHash = await helper.dualSignatureVerifier.hashEvmGaslessOrderData(evmGaslessOrderData)
      const signature = await helper.testWallet.signMessage(ethers.getBytes(messageHash))
      
      // Verify with both formats
      const isValid = await helper.dualSignatureVerifier.verifyGaslessOrderSignature(
        evmGaslessOrderData,
        universalGaslessOrderData,
        signature,
        helper.testWallet.address,
        'Eco Protocol',
        '1'
      )
      
      expect(isValid).to.be.true
    })
  })
})