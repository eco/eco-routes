import { expect } from 'chai'
import { ethers } from 'hardhat'
import { Contract, Signer } from 'ethers'
import { AddressConverter } from '../utils/EcoERC7683'

describe('Universal Intent Source Test', (): void => {
  // Contracts
  let universalIntentSource: Contract
  let intentSource: Contract
  let inbox: Contract
  let metaProver: Contract
  let hyperProver: Contract
  let testERC20: Contract

  // Contract types needed for testing
  type TokenAmount = {
    token: string
    amount: bigint
  }

  type UniversalTokenAmount = {
    token: string // bytes32
    amount: bigint
  }

  type Call = {
    target: string
    data: string
    value: bigint
  }

  type UniversalCall = {
    target: string // bytes32
    data: string
    value: bigint
  }

  type Route = {
    salt: string
    source: bigint
    destination: bigint
    inbox: string
    tokens: TokenAmount[]
    calls: Call[]
  }

  type UniversalRoute = {
    salt: string
    source: bigint
    destination: bigint
    inbox: string // bytes32
    tokens: UniversalTokenAmount[]
    calls: UniversalCall[]
  }

  type Reward = {
    creator: string
    prover: string
    deadline: bigint
    nativeValue: bigint
    tokens: TokenAmount[]
  }

  type UniversalReward = {
    creator: string // bytes32
    prover: string // bytes32
    deadline: bigint
    nativeValue: bigint
    tokens: UniversalTokenAmount[]
  }

  type Intent = {
    route: Route
    reward: Reward
  }

  type UniversalIntent = {
    route: UniversalRoute
    reward: UniversalReward
  }

  // Helper functions for conversion
  function addressToBytes32(address: string): string {
    return ethers.zeroPadValue(address, 32)
  }

  function getBytes32FromAddress(address: string): string {
    return addressToBytes32(address.toLowerCase())
  }

  function getAddressFromBytes32(bytes32: string): string {
    // Remove leading zeros to get the address
    return ethers.getAddress('0x' + bytes32.slice(-40))
  }

  // Convert TokenAmount arrays
  function convertTokenAmounts(tokenAmounts: TokenAmount[]): UniversalTokenAmount[] {
    return tokenAmounts.map(ta => ({
      token: getBytes32FromAddress(ta.token),
      amount: ta.amount
    }))
  }

  // Convert Call arrays
  function convertCalls(calls: Call[]): UniversalCall[] {
    return calls.map(call => ({
      target: getBytes32FromAddress(call.target),
      data: call.data,
      value: call.value
    }))
  }

  // Convert EVM intent to Universal intent
  function convertToUniversalIntent(intent: Intent): UniversalIntent {
    return {
      route: {
        salt: intent.route.salt,
        source: intent.route.source,
        destination: intent.route.destination,
        inbox: getBytes32FromAddress(intent.route.inbox),
        tokens: convertTokenAmounts(intent.route.tokens),
        calls: convertCalls(intent.route.calls)
      },
      reward: {
        creator: getBytes32FromAddress(intent.reward.creator),
        prover: getBytes32FromAddress(intent.reward.prover),
        deadline: intent.reward.deadline,
        nativeValue: intent.reward.nativeValue,
        tokens: convertTokenAmounts(intent.reward.tokens)
      }
    }
  }

  // Test accounts
  let creator: Signer
  let owner: Signer
  let claimant: Signer
  let otherPerson: Signer

  // Test data
  let intent: Intent
  let universalIntent: UniversalIntent
  let intentHash: string
  let routeHash: string
  let vaultAddress: string
  let tokenAmount: bigint

  beforeEach(async (): Promise<void> => {
    [creator, owner, claimant, otherPerson] = await ethers.getSigners()

    // Deploy test contracts with interfaces
    const intentSourceFactory = await ethers.getContractFactory('IntentSource')
    const intentSourceImpl = await intentSourceFactory.deploy()
    
    intentSource = await ethers.getContractAt('IIntentSource', intentSourceImpl.target)
    universalIntentSource = await ethers.getContractAt('IUniversalIntentSource', intentSourceImpl.target)
    
    inbox = await (await ethers.getContractFactory('Inbox')).deploy()

    // deploy provers
    const metaProverFactory = await ethers.getContractFactory('MetaProver')
    metaProver = await metaProverFactory.deploy()

    const hyperProverFactory = await ethers.getContractFactory('HyperProver')
    hyperProver = await hyperProverFactory.deploy()

    // Deploy test token
    const testERC20Factory = await ethers.getContractFactory('TestERC20')
    testERC20 = await testERC20Factory.deploy('Test Token', 'TST')

    // Mint tokens to creator
    tokenAmount = ethers.parseEther('1000')
    await testERC20.mint(await creator.getAddress(), tokenAmount)

    // Basic intent setup
    intent = {
      route: {
        salt: ethers.randomBytes(32),
        source: BigInt(await ethers.provider.getChainId()),
        destination: 100n,
        inbox: await inbox.getAddress(),
        tokens: [
          { token: await testERC20.getAddress(), amount: ethers.parseEther('10') }
        ],
        calls: [
          {
            target: await inbox.getAddress(),
            data: '0x1234',
            value: ethers.parseEther('0.1')
          }
        ]
      },
      reward: {
        creator: await creator.getAddress(),
        prover: await metaProver.getAddress(),
        deadline: BigInt(Math.floor(Date.now() / 1000) + 3600),
        nativeValue: ethers.parseEther('0.5'),
        tokens: [
          { token: await testERC20.getAddress(), amount: ethers.parseEther('5') }
        ]
      }
    }

    // Create universal intent
    universalIntent = convertToUniversalIntent(intent)

    // Approve token spending
    await testERC20.connect(creator).approve(intentSource.target, ethers.parseEther('1000'))
  })

  describe('Universal Intent Hashing and Address Conversion', (): void => {
    it('Should convert address to bytes32 and back', async function () {
      const testAddress = await creator.getAddress()
      const bytes32Value = getBytes32FromAddress(testAddress)
      const recoveredAddress = getAddressFromBytes32(bytes32Value)
      
      expect(recoveredAddress.toLowerCase()).to.equal(testAddress.toLowerCase())
    })

    it('Should correctly hash universal intents', async function () {
      const [hash, routeHashResult, rewardHash] = await universalIntentSource.getIntentHash(universalIntent)
      
      // Explicit hash calculation
      const routeHashManual = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(
        ['tuple(bytes32,uint256,uint256,bytes32,tuple(bytes32,uint256)[],tuple(bytes32,bytes,uint256)[])'],
        [
          [
            universalIntent.route.salt,
            universalIntent.route.source,
            universalIntent.route.destination,
            universalIntent.route.inbox,
            universalIntent.route.tokens,
            universalIntent.route.calls
          ]
        ]
      ))
      
      // Verify route hash matches
      expect(routeHashResult).to.equal(routeHashManual)
      
      intentHash = hash
      routeHash = routeHashResult
    })

    it('Should return correct vault address for universal intent', async function () {
      const vaultAddr = await universalIntentSource.intentVaultAddress(universalIntent)
      expect(vaultAddr).to.be.a('string')
      expect(vaultAddr).to.match(/^0x[a-fA-F0-9]{40}$/)
      
      vaultAddress = vaultAddr
    })
  })

  describe('Universal Intent Publishing', (): void => {
    it('Should successfully publish a universal intent', async function () {
      // Get transaction to publish intent
      const tx = await universalIntentSource.publish(universalIntent)
      
      // Verify it was successful
      const receipt = await tx.wait()
      expect(receipt.status).to.equal(1)
      
      // Verify event was emitted
      const filter = universalIntentSource.filters.UniversalIntentCreated
      const events = await universalIntentSource.queryFilter(filter, receipt.blockNumber, receipt.blockNumber)
      
      expect(events.length).to.be.greaterThan(0)
      expect(events[0].args[0]).to.equal(intentHash)
    })
    
    it('Should reject publishing when source chain is incorrect', async function () {
      // Modify the intent to use a different source chain
      const invalidIntent = { ...universalIntent }
      invalidIntent.route = { ...universalIntent.route, source: 999n }
      
      // Expect revert when publishing
      await expect(universalIntentSource.publish(invalidIntent)).to.be.revertedWithCustomError(
        universalIntentSource,
        'WrongSourceChain'
      )
    })
  })

  describe('Universal Intent Funding', (): void => {
    it('Should fund a universal intent with ERC20 tokens', async function () {
      // Publish intent first
      await universalIntentSource.publish(universalIntent)
      
      // Get required ETH amount
      const ethNeeded = universalIntent.reward.nativeValue
      
      // Fund the intent
      const tx = await universalIntentSource.publishAndFund(
        universalIntent,
        false, // no partial funding
        { value: ethNeeded }
      )
      
      // Verify it was successful
      const receipt = await tx.wait()
      expect(receipt.status).to.equal(1)
      
      // Verify funding event was emitted
      const filter = universalIntentSource.filters.IntentFunded
      const events = await universalIntentSource.queryFilter(filter, receipt.blockNumber, receipt.blockNumber)
      
      expect(events.length).to.be.greaterThan(0)
      expect(events[0].args[0]).to.equal(intentHash)
      
      // Verify vault has correct balances
      const vaultEthBalance = await ethers.provider.getBalance(vaultAddress)
      expect(vaultEthBalance).to.equal(ethNeeded)
      
      const vaultTokenBalance = await testERC20.balanceOf(vaultAddress)
      expect(vaultTokenBalance).to.equal(universalIntent.reward.tokens[0].amount)
    })
    
    it('Should allow partial funding when specified', async function () {
      // Publish intent first
      await universalIntentSource.publish(universalIntent)
      
      // Fund with less than needed
      const partialEth = universalIntent.reward.nativeValue / 2n
      
      // Reduce the token allowance to test partial token funding
      await testERC20.connect(creator).approve(intentSource.target, universalIntent.reward.tokens[0].amount / 2n)
      
      // Fund the intent with partial flag
      const tx = await universalIntentSource.publishAndFund(
        universalIntent,
        true, // allow partial funding
        { value: partialEth }
      )
      
      // Verify it was successful
      const receipt = await tx.wait()
      expect(receipt.status).to.equal(1)
      
      // Verify partial funding event was emitted
      const filter = universalIntentSource.filters.IntentPartiallyFunded
      const events = await universalIntentSource.queryFilter(filter, receipt.blockNumber, receipt.blockNumber)
      
      expect(events.length).to.be.greaterThan(0)
      expect(events[0].args[0]).to.equal(intentHash)
    })
    
    it('Should correctly identify if an intent is funded', async function () {
      // Publish and fund the intent
      await universalIntentSource.publishAndFund(
        universalIntent,
        false, // no partial funding
        { value: universalIntent.reward.nativeValue }
      )
      
      // Check if the intent is funded
      const isFunded = await universalIntentSource.isIntentFunded(universalIntent)
      expect(isFunded).to.be.true
    })
    
    it('Should handle publishAndFundFor with permit correctly', async function () {
      // For simplicity, this test will not test actual permits
      // but rather the basic functionality of publishAndFundFor
      // with a direct allowance
      
      // Get test addresses
      const creatorAddress = await creator.getAddress()
      
      // Publish and fund for the creator
      await universalIntentSource.connect(otherPerson).publishAndFundFor(
        universalIntent,
        creatorAddress,
        ethers.ZeroAddress, // no permit contract
        false // no partial funding
      )
      
      // Check if the intent is funded
      const isFunded = await universalIntentSource.isIntentFunded(universalIntent)
      expect(isFunded).to.be.true
      
      // Verify the funding came from the creator's tokens
      const creatorBalance = await testERC20.balanceOf(creatorAddress)
      expect(creatorBalance).to.equal(tokenAmount - universalIntent.reward.tokens[0].amount)
    })
  })

  describe('Edge Cases', (): void => {
    it('Should revert when trying to fund an already funded intent', async function () {
      // Publish and fund the intent
      await universalIntentSource.publishAndFund(
        universalIntent,
        false, // no partial funding
        { value: universalIntent.reward.nativeValue }
      )
      
      // Try to fund again
      await expect(universalIntentSource.publishAndFund(
        universalIntent,
        false,
        { value: universalIntent.reward.nativeValue }
      )).to.be.revertedWithCustomError(
        universalIntentSource,
        'IntentAlreadyFunded'
      )
    })
    
    it('Should revert when provided insufficient ETH value', async function () {
      // Try to fund with insufficient ETH
      await expect(universalIntentSource.publishAndFund(
        universalIntent,
        false, // no partial funding
        { value: universalIntent.reward.nativeValue / 2n }
      )).to.be.revertedWithCustomError(
        universalIntentSource,
        'InsufficientNativeReward'
      )
    })
    
    it('Should handle zero token amounts correctly', async function () {
      // Modify the intent to have a zero token amount
      const zeroTokenIntent = { ...universalIntent }
      zeroTokenIntent.reward = { 
        ...universalIntent.reward,
        tokens: [{ ...universalIntent.reward.tokens[0], amount: 0n }]
      }
      
      // Publish and fund with just ETH
      await universalIntentSource.publishAndFund(
        zeroTokenIntent,
        false, // no partial funding
        { value: zeroTokenIntent.reward.nativeValue }
      )
      
      // Check if the intent is funded
      const isFunded = await universalIntentSource.isIntentFunded(zeroTokenIntent)
      expect(isFunded).to.be.true
    })
    
    it('Should handle intent with no tokens correctly', async function () {
      // Modify the intent to have no tokens
      const noTokenIntent = { ...universalIntent }
      noTokenIntent.reward = {
        ...universalIntent.reward,
        tokens: []
      }
      
      // Publish and fund with just ETH
      await universalIntentSource.publishAndFund(
        noTokenIntent,
        false, // no partial funding
        { value: noTokenIntent.reward.nativeValue }
      )
      
      // Check if the intent is funded
      const isFunded = await universalIntentSource.isIntentFunded(noTokenIntent)
      expect(isFunded).to.be.true
    })
  })

  describe('Vault Address Calculations', (): void => {
    it('Should calculate the same vault address for equivalent EVM and Universal intents', async function () {
      // Get vault address for both formats
      const universalVaultAddr = await universalIntentSource.intentVaultAddress(universalIntent)
      const evmVaultAddr = await intentSource.intentVaultAddress(intent)
      
      // They should be the same vault
      expect(universalVaultAddr).to.equal(evmVaultAddr)
    })
  })
})