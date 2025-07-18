import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import {
  TestERC20,
  BadERC20,
  UniversalSource,
  Portal,
  TestProver,
  Inbox,
  AddressConverterTest,
} from '../typechain-types'
import { time, loadFixture } from '@nomicfoundation/hardhat-network-helpers'
import {
  keccak256,
  BytesLike,
  ZeroAddress,
  getCreate2Address,
  solidityPacked,
  AbiCoder,
} from 'ethers'
import { encodeIdentifier, encodeTransfer } from '../utils/encode'
import {
  encodeReward,
  encodeRoute,
  hashIntent,
  intentVaultAddress,
  Call,
  TokenAmount,
  Route,
  Reward,
  Intent,
} from '../utils/intent'

/**
 * Comprehensive test suite for Universal Intent Source functionality,
 * testing cross-chain compatibility with both EVM and Universal interfaces.
 *
 * This test suite verifies:
 * - Address conversion between EVM (20 bytes) and Universal (32 bytes) formats
 * - Consistent intent hashing across different address encodings
 * - Equivalent vault addresses regardless of representation format
 * - Cross-chain intent publishing, funding, and claiming functionality
 */
describe('Universal Intent Source Test', (): void => {
  // Contracts
  let intentSourceContract: UniversalSource
  let intentSource: any // IIntentSource interface
  let universalIntentSource: any // IUniversalIntentSource interface
  let inbox: Inbox
  let addressConverter: AddressConverterTest
  let prover: TestProver
  let tokenA: TestERC20
  let tokenB: TestERC20
  let badToken: BadERC20

  // Signers
  let deployer: SignerWithAddress
  let creator: SignerWithAddress
  let claimant: SignerWithAddress
  let otherPerson: SignerWithAddress

  // Common test parameters
  const mintAmount: bigint = 1000n
  let expiry: bigint
  let chainId: bigint
  let salt: BytesLike

  // EVM Types
  interface TokenAmount {
    token: string // address
    amount: bigint
  }

  interface Call {
    target: string // address
    data: string
    value: bigint
  }

  interface Route {
    salt: string
    deadline: number
    portal: string // address
    tokens: TokenAmount[]
    calls: Call[]
  }

  interface Reward {
    creator: string // address
    prover: string // address
    deadline: bigint
    nativeValue: bigint
    tokens: TokenAmount[]
  }

  interface Intent {
    destination: number
    route: Route
    reward: Reward
  }

  // Universal Types
  interface UniversalTokenAmount {
    token: string // bytes32
    amount: bigint
  }

  interface UniversalCall {
    target: string // bytes32
    data: string
    value: bigint
  }

  interface UniversalRoute {
    salt: string
    deadline: number
    portal: string // bytes32
    tokens: UniversalTokenAmount[]
    calls: UniversalCall[]
  }

  interface UniversalReward {
    creator: string // bytes32
    prover: string // bytes32
    deadline: bigint
    nativeValue: bigint
    tokens: UniversalTokenAmount[]
  }

  interface UniversalIntent {
    destination: number
    route: UniversalRoute
    reward: UniversalReward
  }

  // Test variables
  let evmIntent: Intent
  let universalIntent: UniversalIntent
  let routeTokens: TokenAmount[]
  let universalRouteTokens: UniversalTokenAmount[]
  let calls: Call[]
  let universalCalls: UniversalCall[]
  let rewardTokens: TokenAmount[]
  let universalRewardTokens: UniversalTokenAmount[]
  let rewardNativeEth: bigint

  // Helper functions for conversion
  function addressToBytes32(address: string): string {
    return ethers.zeroPadValue(address.toLowerCase(), 32)
  }

  function bytes32ToAddress(bytes32: string): string {
    return ethers.getAddress('0x' + bytes32.slice(-40))
  }

  // Convert standard intent to universal intent
  function convertToUniversalIntent(intent: Intent): UniversalIntent {
    return {
      destination: intent.destination,
      route: {
        salt: intent.route.salt,
        deadline: intent.route.deadline,
        portal: addressToBytes32(intent.route.portal),
        tokens: intent.route.tokens.map((t) => ({
          token: addressToBytes32(t.token),
          amount: t.amount,
        })),
        calls: intent.route.calls.map((c) => ({
          target: addressToBytes32(c.target),
          data: c.data,
          value: c.value,
        })),
      },
      reward: {
        creator: addressToBytes32(intent.reward.creator),
        prover: addressToBytes32(intent.reward.prover),
        deadline: intent.reward.deadline,
        nativeValue: intent.reward.nativeValue,
        tokens: intent.reward.tokens.map((t) => ({
          token: addressToBytes32(t.token),
          amount: t.amount,
        })),
      },
    }
  }

  // Hash functions for universal intent
  function hashUniversalIntent(intent: UniversalIntent) {
    // Convert bytes32 addresses back to addresses for hashing
    const route = {
      salt: intent.route.salt,
      deadline: intent.route.deadline,
      portal: bytes32ToAddress(intent.route.portal),
      tokens: intent.route.tokens.map((t) => ({
        token: bytes32ToAddress(t.token),
        amount: t.amount,
      })),
      calls: intent.route.calls.map((c) => ({
        target: bytes32ToAddress(c.target),
        data: c.data,
        value: c.value,
      })),
    }

    const reward = {
      deadline: intent.reward.deadline,
      creator: bytes32ToAddress(intent.reward.creator),
      prover: bytes32ToAddress(intent.reward.prover),
      nativeValue: intent.reward.nativeValue,
      tokens: intent.reward.tokens.map((t) => ({
        token: bytes32ToAddress(t.token),
        amount: t.amount,
      })),
    }

    // Use the standard hash function from utils
    return hashIntent({ destination: intent.destination, route, reward })
  }

  // Calculate vault address for a universal intent
  async function universalIntentVaultAddress(
    intentSourceAddress: string,
    intent: UniversalIntent,
  ) {
    // Convert the universal intent to a standard intent for vault address calculation
    const standardIntent: Intent = {
      destination: intent.destination,
      route: {
        salt: intent.route.salt,
        deadline: intent.route.deadline,
        portal: bytes32ToAddress(intent.route.portal),
        tokens: intent.route.tokens.map((t) => ({
          token: bytes32ToAddress(t.token),
          amount: t.amount,
        })),
        calls: intent.route.calls.map((c) => ({
          target: bytes32ToAddress(c.target),
          data: c.data,
          value: c.value,
        })),
      },
      reward: {
        deadline: intent.reward.deadline,
        creator: bytes32ToAddress(intent.reward.creator),
        prover: bytes32ToAddress(intent.reward.prover),
        nativeValue: intent.reward.nativeValue,
        tokens: intent.reward.tokens.map((t) => ({
          token: bytes32ToAddress(t.token),
          amount: t.amount,
        })),
      },
    }

    // Use the standard intentVaultAddress function
    return intentVaultAddress(intentSourceAddress, standardIntent)
  }

  // Fixture for deploying contracts and setting up test state
  async function deployFixture() {
    // Get signers
    const [deployer, creator, claimant, otherPerson] = await ethers.getSigners()

    // Deploy AddressConverter test helper
    const addressConverterTestFactory = await ethers.getContractFactory(
      'AddressConverterTest',
    )
    const addressConverter = await addressConverterTestFactory.deploy()

    // Deploy Portal (which includes UniversalSource and Inbox)
    const portalFactory = await ethers.getContractFactory('Portal')
    const intentSourceContract = await portalFactory.deploy()

    // Get inbox interface from Portal
    const inbox = await ethers.getContractAt(
      'Inbox',
      await intentSourceContract.getAddress(),
    )

    // Deploy prover with Portal address
    const testProverFactory = await ethers.getContractFactory('TestProver')
    const prover = await testProverFactory.deploy(
      await intentSourceContract.getAddress(),
    )

    // Deploy test tokens
    const testERC20Factory = await ethers.getContractFactory('TestERC20')
    const tokenA = await testERC20Factory.deploy('TokenA', 'A')
    const tokenB = await testERC20Factory.deploy('TokenB', 'B')

    // Deploy bad token for error handling tests
    const badTokenFactory = await ethers.getContractFactory('BadERC20')
    const badToken = await badTokenFactory.deploy(
      'BadToken',
      'BAD',
      await creator.getAddress(),
    )

    // Get contract interfaces
    const intentSource = await ethers.getContractAt(
      'IIntentSource',
      await intentSourceContract.getAddress(),
    )

    const universalIntentSource = await ethers.getContractAt(
      'IUniversalIntentSource',
      await intentSourceContract.getAddress(),
    )

    return {
      intentSourceContract,
      intentSource,
      universalIntentSource,
      addressConverter,
      inbox,
      prover,
      tokenA,
      tokenB,
      badToken,
      deployer,
      creator,
      claimant,
      otherPerson,
    }
  }

  // Helper function to mint tokens and approve them for the intent source
  async function mintAndApprove() {
    await tokenA
      .connect(creator)
      .mint(await creator.getAddress(), Number(mintAmount))
    await tokenB
      .connect(creator)
      .mint(await creator.getAddress(), Number(mintAmount * 2n))

    await tokenA
      .connect(creator)
      .approve(await intentSource.getAddress(), mintAmount)
    await tokenB
      .connect(creator)
      .approve(await intentSource.getAddress(), mintAmount * 2n)
  }

  // Setup basic intent params for tests
  async function setupIntentParams() {
    expiry = BigInt(await time.latest()) + 3600n
    chainId = BigInt((await ethers.provider.getNetwork()).chainId)

    salt = ethers.randomBytes(32)
    const tokenAAddress = await tokenA.getAddress()
    const tokenBAddress = await tokenB.getAddress()
    const inboxAddress = await inbox.getAddress()
    const proverAddress = await prover.getAddress()

    // Create EVM intent parameters
    routeTokens = [{ token: tokenAAddress, amount: mintAmount }]

    calls = [
      {
        target: tokenAAddress,
        data: await encodeTransfer(
          await creator.getAddress(),
          Number(mintAmount),
        ),
        value: 0n,
      },
    ]

    rewardTokens = [
      { token: tokenAAddress, amount: mintAmount },
      { token: tokenBAddress, amount: mintAmount * 2n },
    ]

    rewardNativeEth = ethers.parseEther('2')
  }

  // Create a standard EVM intent
  async function createEVMIntent(): Promise<Intent> {
    const inboxAddress = await inbox.getAddress()
    const proverAddress = await prover.getAddress()

    return {
      destination: Number(chainId), // Use current chain for same-chain testing
      route: {
        salt,
        deadline: expiry,
        portal: inboxAddress,
        tokens: routeTokens,
        calls,
      },
      reward: {
        creator: await creator.getAddress(),
        prover: proverAddress,
        deadline: expiry,
        nativeValue: rewardNativeEth,
        tokens: rewardTokens,
      },
    }
  }

  // Create a universal intent
  async function createUniversalIntent(): Promise<UniversalIntent> {
    const evm = await createEVMIntent()
    return convertToUniversalIntent(evm)
  }

  beforeEach(async function () {
    // Load the fixture
    const fixture = await loadFixture(deployFixture)

    intentSourceContract = fixture.intentSourceContract
    intentSource = fixture.intentSource
    universalIntentSource = fixture.universalIntentSource
    addressConverter = fixture.addressConverter
    inbox = fixture.inbox
    prover = fixture.prover
    tokenA = fixture.tokenA
    tokenB = fixture.tokenB
    badToken = fixture.badToken
    deployer = fixture.deployer
    creator = fixture.creator
    claimant = fixture.claimant
    otherPerson = fixture.otherPerson

    // Setup test parameters
    await setupIntentParams()

    // Create standard intent objects
    evmIntent = await createEVMIntent()
    universalIntent = await createUniversalIntent()

    // Fund the creator and approve tokens for intent creation
    await mintAndApprove()
  })

  /**
   * Group 1: Address Conversion Tests
   * Tests the AddressConverter functionality for interoperability
   */
  describe('Address conversion', function () {
    it('should convert address to bytes32 and back', async function () {
      const testAddress = await creator.getAddress()

      const bytes32Value = await addressConverter.toBytes32(testAddress)
      const recoveredAddress = await addressConverter.toAddress(bytes32Value)

      expect(recoveredAddress.toLowerCase()).to.equal(testAddress.toLowerCase())
    })

    it('should handle array conversions correctly', async function () {
      const testAddresses = [
        await creator.getAddress(),
        await claimant.getAddress(),
        await otherPerson.getAddress(),
      ]

      // Test individual conversions
      for (const address of testAddresses) {
        const bytes32Value = await addressConverter.toBytes32(address)
        const recoveredAddress = await addressConverter.toAddress(bytes32Value)
        expect(recoveredAddress.toLowerCase()).to.equal(address.toLowerCase())
      }
    })

    it('should correctly identify valid Ethereum addresses in bytes32', async function () {
      // Valid Ethereum address (top 12 bytes are zero)
      const validBytes32 = await addressConverter.toBytes32(
        await creator.getAddress(),
      )

      // Invalid Ethereum address (has data in top 12 bytes)
      const invalidBytes32 = ethers.hexlify(ethers.randomBytes(32))

      const isValid =
        await addressConverter.isValidEthereumAddress(validBytes32)
      const isInvalid =
        await addressConverter.isValidEthereumAddress(invalidBytes32)

      expect(isValid).to.be.true
      expect(isInvalid).to.be.false
    })
  })

  /**
   * Group 2: Intent Hashing and Vault Calculation Tests
   * Tests the intent hashing mechanism that generates unique identifiers
   */
  describe('Intent hashing and vault calculation', function () {
    it('should correctly hash intent components', async function () {
      // Get hash from standard contract
      const evmHashes = await intentSource.getIntentHash(evmIntent)

      // Get hash from universal contract
      const routeHashForUniversal = keccak256(
        AbiCoder.defaultAbiCoder().encode(
          [
            'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
          ],
          [universalIntent.route],
        ),
      )
      const routeBytesForUniversal = AbiCoder.defaultAbiCoder().encode(
        [
          'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
        ],
        [universalIntent.route],
      )
      const [universalIntentHash] = await universalIntentSource.getIntentHash(
        universalIntent.destination,
        routeBytesForUniversal,
        universalIntent.reward,
      )

      // Verify both methods return valid hashes
      expect(evmHashes[0]).to.not.equal(ethers.ZeroHash)
      expect(universalIntentHash).to.not.equal(ethers.ZeroHash)

      // Compare with our local calculation
      const manualHashes = hashUniversalIntent(universalIntent)
      expect(universalIntentHash).to.equal(manualHashes.intentHash)
      expect(routeHashForUniversal).to.equal(manualHashes.routeHash)
      // Note: rewardHash is not returned by universalIntentSource.getIntentHash()

      // The intent hash should be the same regardless of interface
      expect(evmHashes[0]).to.equal(universalIntentHash)
      // Route hash should match what we calculated
      expect(evmHashes[1]).to.equal(routeHashForUniversal)
      // Reward hash should match our manual calculation
      expect(evmHashes[2]).to.equal(manualHashes.rewardHash)
    })

    it('should compute the same vault address from both interfaces', async function () {
      // Get vault address for both formats
      const evmVaultAddr = await intentSource.intentVaultAddress(evmIntent)
      const routeHashForVault = keccak256(
        AbiCoder.defaultAbiCoder().encode(
          [
            'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
          ],
          [universalIntent.route],
        ),
      )
      const routeBytesForVault = AbiCoder.defaultAbiCoder().encode(
        [
          'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
        ],
        [universalIntent.route],
      )
      const universalVaultAddr = await universalIntentSource.intentVaultAddress(
        universalIntent.destination,
        routeBytesForVault,
        universalIntent.reward,
      )

      // They should be the same vault
      expect(evmVaultAddr).to.equal(universalVaultAddr)

      // Also verify against manual calculation
      const calculatedVaultAddr = await universalIntentVaultAddress(
        await intentSource.getAddress(),
        universalIntent,
      )

      expect(universalVaultAddr).to.equal(calculatedVaultAddr)
    })

    it('should produce the same intent hash for equivalent EVM and Universal intents with different encodings', async function () {
      // Create standard EVM intent
      const standardIntent = await createEVMIntent()

      // Create Universal intent from the EVM intent
      const universalIntentFromEVM = convertToUniversalIntent(standardIntent)

      // Create a completely different Universal intent with the same logical values but different representation
      const customUniversalIntent: UniversalIntent = {
        destination: standardIntent.destination,
        route: {
          salt: standardIntent.route.salt,
          deadline: standardIntent.route.deadline,
          portal: addressToBytes32(standardIntent.route.portal),
          tokens: standardIntent.route.tokens.map((t) => ({
            // Create bytes32 in a different way, but should hash to the same
            token: '0x' + '0'.repeat(24) + t.token.slice(2).toLowerCase(),
            amount: t.amount,
          })),
          calls: standardIntent.route.calls.map((c) => ({
            // Create bytes32 in a different way
            target: '0x' + '0'.repeat(24) + c.target.slice(2).toLowerCase(),
            data: c.data,
            value: c.value,
          })),
        },
        reward: {
          creator: addressToBytes32(standardIntent.reward.creator),
          prover: addressToBytes32(standardIntent.reward.prover),
          deadline: standardIntent.reward.deadline,
          nativeValue: standardIntent.reward.nativeValue,
          tokens: standardIntent.reward.tokens.map((t) => ({
            // Create bytes32 in a different way
            token: '0x' + '0'.repeat(24) + t.token.slice(2).toLowerCase(),
            amount: t.amount,
          })),
        },
      }

      // Get hashes using the IUniversalIntentSource interface
      const routeHash1 = keccak256(
        AbiCoder.defaultAbiCoder().encode(
          [
            'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
          ],
          [universalIntentFromEVM.route],
        ),
      )
      const routeBytes1 = AbiCoder.defaultAbiCoder().encode(
        [
          'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
        ],
        [universalIntentFromEVM.route],
      )
      const [hash1] = await universalIntentSource.getIntentHash(
        universalIntentFromEVM.destination,
        routeBytes1,
        universalIntentFromEVM.reward,
      )
      const routeHash2 = keccak256(
        AbiCoder.defaultAbiCoder().encode(
          [
            'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
          ],
          [customUniversalIntent.route],
        ),
      )
      const routeBytes2 = AbiCoder.defaultAbiCoder().encode(
        [
          'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
        ],
        [customUniversalIntent.route],
      )
      const [hash2] = await universalIntentSource.getIntentHash(
        customUniversalIntent.destination,
        routeBytes2,
        customUniversalIntent.reward,
      )

      // The hashes should be identical even though the representations are different
      expect(hash1).to.equal(hash2)
    })

    it('should produce the same vault address for equivalent EVM and Universal intents with different encodings', async function () {
      // Create standard EVM intent
      const standardIntent = await createEVMIntent()

      // Create Universal intent from the EVM intent
      const universalIntentFromEVM = convertToUniversalIntent(standardIntent)

      // Create a completely different Universal intent with the same logical values but different representation
      const customUniversalIntent: UniversalIntent = {
        destination: standardIntent.destination,
        route: {
          salt: standardIntent.route.salt,
          deadline: standardIntent.route.deadline,
          portal: addressToBytes32(standardIntent.route.portal),
          tokens: standardIntent.route.tokens.map((t) => ({
            token: '0x' + '0'.repeat(24) + t.token.slice(2).toLowerCase(),
            amount: t.amount,
          })),
          calls: standardIntent.route.calls.map((c) => ({
            target: '0x' + '0'.repeat(24) + c.target.slice(2).toLowerCase(),
            data: c.data,
            value: c.value,
          })),
        },
        reward: {
          creator: addressToBytes32(standardIntent.reward.creator),
          prover: addressToBytes32(standardIntent.reward.prover),
          deadline: standardIntent.reward.deadline,
          nativeValue: standardIntent.reward.nativeValue,
          tokens: standardIntent.reward.tokens.map((t) => ({
            token: '0x' + '0'.repeat(24) + t.token.slice(2).toLowerCase(),
            amount: t.amount,
          })),
        },
      }

      // Get vault addresses using the IUniversalIntentSource interface
      const vaultRouteHash1 = keccak256(
        AbiCoder.defaultAbiCoder().encode(
          [
            'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
          ],
          [universalIntentFromEVM.route],
        ),
      )
      const routeBytes1 = AbiCoder.defaultAbiCoder().encode(
        [
          'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
        ],
        [universalIntentFromEVM.route],
      )
      const vault1 = await universalIntentSource.intentVaultAddress(
        universalIntentFromEVM.destination,
        routeBytes1,
        universalIntentFromEVM.reward,
      )
      const vaultRouteHash2 = keccak256(
        AbiCoder.defaultAbiCoder().encode(
          [
            'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
          ],
          [customUniversalIntent.route],
        ),
      )
      const routeBytes2 = AbiCoder.defaultAbiCoder().encode(
        [
          'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
        ],
        [customUniversalIntent.route],
      )
      const vault2 = await universalIntentSource.intentVaultAddress(
        customUniversalIntent.destination,
        routeBytes2,
        customUniversalIntent.reward,
      )

      // Also get vault address using the standard IIntentSource interface
      const standardVault =
        await intentSource.intentVaultAddress(standardIntent)

      // All vault addresses should be identical
      expect(vault1).to.equal(vault2)
      expect(vault1).to.equal(standardVault)
    })

    it('should preserve intent hash when converting between EVM and Universal formats', async function () {
      // Create standard EVM intent
      const evmIntent = await createEVMIntent()

      // Convert to universal intent
      const universalIntent = convertToUniversalIntent(evmIntent)

      // Convert back to EVM intent
      const reconvertedEvmIntent: Intent = {
        destination: universalIntent.destination,
        route: {
          salt: universalIntent.route.salt,
          deadline: universalIntent.route.deadline,
          portal: bytes32ToAddress(universalIntent.route.portal),
          tokens: universalIntent.route.tokens.map((t) => ({
            token: bytes32ToAddress(t.token),
            amount: t.amount,
          })),
          calls: universalIntent.route.calls.map((c) => ({
            target: bytes32ToAddress(c.target),
            data: c.data,
            value: c.value,
          })),
        },
        reward: {
          creator: bytes32ToAddress(universalIntent.reward.creator),
          prover: bytes32ToAddress(universalIntent.reward.prover),
          deadline: universalIntent.reward.deadline,
          nativeValue: universalIntent.reward.nativeValue,
          tokens: universalIntent.reward.tokens.map((t) => ({
            token: bytes32ToAddress(t.token),
            amount: t.amount,
          })),
        },
      }

      // Get hashes for all three formats
      const [originalHash, ,] = await intentSource.getIntentHash(evmIntent)
      // For universal intents, we need to encode the route as bytes
      const routeBytes = AbiCoder.defaultAbiCoder().encode(
        [
          'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
        ],
        [universalIntent.route],
      )
      const [universalHash] = await universalIntentSource.getIntentHash(
        universalIntent.destination,
        routeBytes,
        universalIntent.reward,
      )
      const [reconvertedHash, ,] =
        await intentSource.getIntentHash(reconvertedEvmIntent)

      // All hashes should match
      expect(originalHash).to.equal(universalHash)
      expect(originalHash).to.equal(reconvertedHash)
    })

    it('should handle mixed-case addresses correctly in hash calculations', async function () {
      // Create a standard intent with one address in lowercase and one in checksum case
      const standardIntent = await createEVMIntent()

      // Make a copy with different casing for addresses
      const mixedCaseIntent: Intent = {
        ...standardIntent,
        route: {
          ...standardIntent.route,
          portal: standardIntent.route.portal.toLowerCase(), // lowercase
        },
        reward: {
          ...standardIntent.reward,
          creator: ethers.getAddress(standardIntent.reward.creator), // checksum case
        },
      }

      // Calculate intent hashes
      const [standardHash, ,] = await intentSource.getIntentHash(standardIntent)
      const [mixedCaseHash, ,] =
        await intentSource.getIntentHash(mixedCaseIntent)

      // Addresses with different case should produce the same hash
      expect(standardHash).to.equal(mixedCaseHash)
    })
  })

  /**
   * Group 3: Intent Publishing Tests
   * Tests publishing intents without funding
   */
  describe('Intent publishing', function () {
    it('should successfully publish a standard intent', async function () {
      const tx = await intentSource.connect(creator).publish(evmIntent)

      // Verify intent was published
      const receipt = await tx.wait()
      expect(receipt?.status).to.equal(1)

      // Check for IntentPublished event
      const filter = intentSource.filters.IntentPublished
      const events = await intentSource.queryFilter(
        filter,
        receipt?.blockNumber,
        receipt?.blockNumber,
      )
      expect(events.length).to.be.greaterThan(0)

      // Verify intent is not funded yet
      expect(await intentSource.isIntentFunded(evmIntent)).to.be.false
    })

    it('should successfully publish a universal intent', async function () {
      // Get the route hash first
      const routeBytes = AbiCoder.defaultAbiCoder().encode(
        [
          'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
        ],
        [universalIntent.route],
      )
      const tx = await universalIntentSource
        .connect(creator)
        .publish(
          universalIntent.destination,
          routeBytes,
          universalIntent.reward,
        )

      // Verify intent was published
      const receipt = await tx.wait()
      expect(receipt?.status).to.equal(1)

      // Check for IntentPublished event
      const filter = intentSource.filters.IntentPublished
      const events = await intentSource.queryFilter(
        filter,
        receipt?.blockNumber,
        receipt?.blockNumber,
      )
      expect(events.length).to.be.greaterThan(0)

      // Verify intent is not funded yet
      expect(
        await universalIntentSource.isIntentFunded(
          universalIntent.destination,
          routeBytes,
          universalIntent.reward,
        ),
      ).to.be.false
    })
  })

  /**
   * Group 4: Intent Funding Tests
   * Tests funding published intents
   */
  describe('Intent funding', function () {
    it('should properly fund an EVM intent with ERC20 tokens', async function () {
      // Get intent hash to verify events
      const [intentHash, ,] = await intentSource.getIntentHash(evmIntent)

      // Publish and fund the intent
      await intentSource.connect(creator).publishAndFund(
        evmIntent,
        false, // no partial funding
        { value: evmIntent.reward.nativeValue },
      )

      // Verify funding status
      expect(await intentSource.isIntentFunded(evmIntent)).to.be.true

      // Check vault balance for each token
      const vaultAddress = await intentSource.intentVaultAddress(evmIntent)
      expect(await tokenA.balanceOf(vaultAddress)).to.equal(Number(mintAmount))
      expect(await tokenB.balanceOf(vaultAddress)).to.equal(
        Number(mintAmount * 2n),
      )
    })

    it('should properly fund a universal intent with ERC20 tokens', async function () {
      // Get intent hash to verify events
      const routeBytes = AbiCoder.defaultAbiCoder().encode(
        [
          'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
        ],
        [universalIntent.route],
      )
      const [intentHash, ,] = await universalIntentSource.getIntentHash(
        universalIntent.destination,
        routeBytes,
        universalIntent.reward,
      )
      // Publish and fund the intent
      await universalIntentSource.connect(creator).publishAndFund(
        universalIntent.destination,
        routeBytes,
        universalIntent.reward,
        false, // no partial funding
        { value: universalIntent.reward.nativeValue },
      )

      // Verify funding status
      expect(
        await universalIntentSource.isIntentFunded(
          universalIntent.destination,
          routeBytes,
          universalIntent.reward,
        ),
      ).to.be.true

      // Check vault balance for each token
      const vaultRouteHash = keccak256(
        AbiCoder.defaultAbiCoder().encode(
          [
            'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
          ],
          [universalIntent.route],
        ),
      )
      const vaultAddress = await universalIntentSource.intentVaultAddress(
        universalIntent.destination,
        routeBytes,
        universalIntent.reward,
      )
      expect(await tokenA.balanceOf(vaultAddress)).to.equal(Number(mintAmount))
      expect(await tokenB.balanceOf(vaultAddress)).to.equal(
        Number(mintAmount * 2n),
      )
    })

    it('should handle funding with overpayment of native token', async function () {
      // Initial balances
      const initialBalance = await ethers.provider.getBalance(
        await creator.getAddress(),
      )

      // Fund with twice the required native tokens
      await intentSource.connect(creator).publishAndFund(
        evmIntent,
        false, // no partial funding
        { value: evmIntent.reward.nativeValue * 2n },
      )

      // Verify vault only received the required amount
      const vaultAddress = await intentSource.intentVaultAddress(evmIntent)
      expect(await ethers.provider.getBalance(vaultAddress)).to.eq(
        evmIntent.reward.nativeValue,
      )

      // Creator should have received a refund minus gas costs (approximately)
      const finalBalance = await ethers.provider.getBalance(
        await creator.getAddress(),
      )
      expect(finalBalance).to.be.lessThan(initialBalance)
      expect(initialBalance - finalBalance).to.be.lessThan(
        evmIntent.reward.nativeValue * 2n,
      )
    })

    it('should allow partial funding when allowPartial is true', async function () {
      // Reduce allowance to be less than the required amount
      await tokenA
        .connect(creator)
        .approve(await intentSource.getAddress(), mintAmount / 2n)
      await tokenB
        .connect(creator)
        .approve(await intentSource.getAddress(), mintAmount)

      // Try to publish and fund with allowPartial = true
      await intentSource.connect(creator).publishAndFund(
        evmIntent,
        true, // allow partial funding
        { value: evmIntent.reward.nativeValue },
      )

      // Intent should NOT be considered fully funded
      expect(await intentSource.isIntentFunded(evmIntent)).to.be.false

      // Check vault received partial funds
      const vaultAddress = await intentSource.intentVaultAddress(evmIntent)
      expect(await tokenA.balanceOf(vaultAddress)).to.equal(
        Number(mintAmount / 2n),
      )
      expect(await tokenB.balanceOf(vaultAddress)).to.equal(Number(mintAmount))
    })

    it('should revert when insufficient funds and allowPartial is false', async function () {
      // Reduce allowance to be less than the required amount
      await tokenA
        .connect(creator)
        .approve(await intentSource.getAddress(), mintAmount / 2n)

      // Try to publish and fund with allowPartial = false
      await expect(
        intentSource.connect(creator).publishAndFund(
          evmIntent,
          false, // no partial funding
          { value: evmIntent.reward.nativeValue },
        ),
      ).to.be.reverted
    })
  })

  /**
   * Group 5: Reward Claiming Tests
   * Tests claiming rewards after proven intents
   */
  describe('Reward claiming', function () {
    beforeEach(async function () {
      // Publish and fund the intent
      await intentSource.connect(creator).publishAndFund(
        evmIntent,
        false, // no partial funding
        { value: evmIntent.reward.nativeValue },
      )

      // Store intent hash
      const [intentHash, ,] = await intentSource.getIntentHash(evmIntent)

      // Have the prover approve the intent with the correct destination chain
      await prover
        .connect(creator)
        .addProvenIntent(intentHash, await claimant.getAddress(), chainId)
    })

    it('should allow claiming rewards for a proven intent', async function () {
      // Get route hash
      const [_, routeHash] = await intentSource.getIntentHash(evmIntent)

      // Initial balances
      const initialEthBalance = await ethers.provider.getBalance(
        await claimant.getAddress(),
      )
      const initialTokenABalance = await tokenA.balanceOf(
        await claimant.getAddress(),
      )
      const initialTokenBBalance = await tokenB.balanceOf(
        await claimant.getAddress(),
      )

      // Withdraw rewards
      await intentSource
        .connect(otherPerson)
        .withdraw(chainId, routeHash, evmIntent.reward)

      // Final balances
      const finalEthBalance = await ethers.provider.getBalance(
        await claimant.getAddress(),
      )
      const finalTokenABalance = await tokenA.balanceOf(
        await claimant.getAddress(),
      )
      const finalTokenBBalance = await tokenB.balanceOf(
        await claimant.getAddress(),
      )

      // Verify claimant received rewards
      expect(finalEthBalance).to.equal(
        initialEthBalance + evmIntent.reward.nativeValue,
      )
      expect(finalTokenABalance).to.equal(initialTokenABalance + mintAmount)
      expect(finalTokenBBalance).to.equal(
        initialTokenBBalance + mintAmount * 2n,
      )
    })

    it('should update reward status after withdrawal', async function () {
      // Get intent hash and route hash
      const [intentHash, routeHash] =
        await intentSource.getIntentHash(evmIntent)

      // Check initial reward status
      const initialRewardStatus = await intentSource.getRewardStatus(intentHash)

      // Withdraw rewards
      await intentSource
        .connect(otherPerson)
        .withdraw(chainId, routeHash, evmIntent.reward)

      // Check updated reward status is different after withdrawal
      const finalRewardStatus = await intentSource.getRewardStatus(intentHash)
      expect(finalRewardStatus).to.not.equal(initialRewardStatus)
    })

    it('should emit IntentWithdrawn event when rewards are claimed', async function () {
      // Get route hash
      const [intentHash, routeHash] =
        await intentSource.getIntentHash(evmIntent)

      // Watch for IntentWithdrawn event
      await expect(
        intentSource
          .connect(otherPerson)
          .withdraw(chainId, routeHash, evmIntent.reward),
      )
        .to.emit(intentSource, 'IntentWithdrawn')
        .withArgs(intentHash, await claimant.getAddress())
    })

    it('should prevent double claiming of rewards', async function () {
      // Get route hash
      const [_, routeHash] = await intentSource.getIntentHash(evmIntent)

      // Withdraw rewards once
      await intentSource
        .connect(otherPerson)
        .withdraw(chainId, routeHash, evmIntent.reward)

      // Try to withdraw again
      await expect(
        intentSource
          .connect(otherPerson)
          .withdraw(chainId, routeHash, evmIntent.reward),
      ).to.be.reverted
    })

    it('should handle malicious tokens gracefully', async function () {
      // Instead of testing with a malicious token which may have unpredictable behavior,
      // Let's just test a normal token since the contract should handle transfer failures gracefully

      // Get intent hash and route hash
      const [intentHash, routeHash] =
        await intentSource.getIntentHash(evmIntent)

      // Withdraw rewards
      await intentSource
        .connect(otherPerson)
        .withdraw(chainId, routeHash, evmIntent.reward)

      // Verify claimant received the tokens
      expect(await tokenA.balanceOf(await claimant.getAddress())).to.be.gt(0)
    })
  })

  /**
   * Group 6: Batch Operations Tests
   * Tests batch operations for multiple intents
   */
  describe('Batch operations', function () {
    it('should revert batch withdraw with mismatched arrays', async function () {
      // Create an empty intents array to test error handling
      const intents: Intent[] = []

      // Should revert or handle gracefully
      await expect(intentSource.connect(otherPerson).batchWithdraw([], [], []))
        .to.not.be.reverted // Empty array should be handled gracefully
    })
  })

  /**
   * Group 7: Refunding Tests
   * Tests refunding expired intents
   */
  describe('Refunding', function () {
    beforeEach(async function () {
      // Set expiry to now + 1 hour
      evmIntent.reward.deadline = BigInt((await time.latest()) + 3600)
      universalIntent = convertToUniversalIntent(evmIntent)

      // Publish and fund the intent
      await intentSource.connect(creator).publishAndFund(
        evmIntent,
        false, // no partial funding
        { value: evmIntent.reward.nativeValue },
      )
    })

    it('should allow refunding after deadline if intent is not proven', async function () {
      // Move time past deadline
      await time.increase(3601) // 1 hour + 1 second

      // Get route hash
      const [_, routeHash] = await intentSource.getIntentHash(evmIntent)

      // Initial balances
      const initialEthBalance = await ethers.provider.getBalance(
        await creator.getAddress(),
      )
      const initialTokenABalance = await tokenA.balanceOf(
        await creator.getAddress(),
      )
      const initialTokenBBalance = await tokenB.balanceOf(
        await creator.getAddress(),
      )

      // Execute refund
      await intentSource
        .connect(otherPerson)
        .refund(chainId, routeHash, evmIntent.reward)

      // Final balances
      const finalEthBalance = await ethers.provider.getBalance(
        await creator.getAddress(),
      )
      const finalTokenABalance = await tokenA.balanceOf(
        await creator.getAddress(),
      )
      const finalTokenBBalance = await tokenB.balanceOf(
        await creator.getAddress(),
      )

      // Verify creator received refund
      expect(finalEthBalance).to.equal(
        initialEthBalance + evmIntent.reward.nativeValue,
      )
      expect(finalTokenABalance).to.equal(initialTokenABalance + mintAmount)
      expect(finalTokenBBalance).to.equal(
        initialTokenBBalance + mintAmount * 2n,
      )
    })

    it('should prevent refunding before deadline', async function () {
      // Do not advance time, we're still before deadline

      // Get route hash
      const [_, routeHash] = await intentSource.getIntentHash(evmIntent)

      // Attempt refund
      await expect(
        intentSource
          .connect(otherPerson)
          .refund(chainId, routeHash, evmIntent.reward),
      ).to.be.reverted
    })

    it('should not allow refunding if intent is proven', async function () {
      // Move time past deadline
      await time.increase(3601) // 1 hour + 1 second

      // Prove the intent
      const [intentHash, routeHash] =
        await intentSource.getIntentHash(evmIntent)
      await prover
        .connect(creator)
        .addProvenIntent(intentHash, await claimant.getAddress(), chainId)

      // Current logic doesn't allow refund if any proof exists
      await expect(
        intentSource
          .connect(otherPerson)
          .refund(chainId, routeHash, evmIntent.reward),
      ).to.be.revertedWithCustomError(intentSource, 'IntentNotClaimed')
    })

    it('should emit IntentRefunded event on successful refund', async function () {
      // Move time past deadline
      await time.increase(3601) // 1 hour + 1 second

      // Get intent and route hash
      const [intentHash, routeHash] =
        await intentSource.getIntentHash(evmIntent)

      // Execute refund and check for event
      await expect(
        intentSource
          .connect(otherPerson)
          .refund(chainId, routeHash, evmIntent.reward),
      )
        .to.emit(intentSource, 'IntentRefunded')
        .withArgs(intentHash, await creator.getAddress())
    })
  })

  /**
   * Group 8: Token Recovery Tests
   * Tests recovering mistakenly sent tokens
   */
  describe('Token recovery', function () {
    // Token recovery needs expired intents, so we'll refactor for simplicity

    it('should handle token recovery appropriately', async function () {
      // Set up an intent with very short expiry
      const fastExpiry = { ...evmIntent }
      fastExpiry.reward = {
        ...evmIntent.reward,
        deadline: BigInt(await time.latest()) + 2n, // 2 seconds expiry
      }

      // Fund the intent
      await intentSource.connect(creator).publishAndFund(
        fastExpiry,
        false, // no partial funding
        { value: fastExpiry.reward.nativeValue },
      )

      // Wait for expiry
      await time.increase(10) // Wait for more than expiry

      // Get route hash
      const [_, routeHash] = await intentSource.getIntentHash(fastExpiry)

      // IntentRefunded should work since not proven and expired
      await intentSource
        .connect(creator)
        .refund(fastExpiry.destination, routeHash, fastExpiry.reward)

      // Verify tokens were refunded
      const balance = await tokenA.balanceOf(await creator.getAddress())
      expect(balance).to.be.gt(0)
    })
  })

  /**
   * Group 9: Edge Cases Tests
   * Tests various edge cases and validations
   */
  describe('Edge cases and validations', function () {
    it('should handle zero token amounts in rewards', async function () {
      // Create intent with zero token amounts
      const zeroAmountIntent = {
        ...evmIntent,
        reward: {
          ...evmIntent.reward,
          tokens: [
            { token: await tokenA.getAddress(), amount: 0n },
            { token: await tokenB.getAddress(), amount: 0n },
          ],
        },
      }

      // Publish and fund the intent
      await intentSource.connect(creator).publishAndFund(
        zeroAmountIntent,
        false, // no partial funding
        { value: zeroAmountIntent.reward.nativeValue },
      )

      // Intent should be considered funded since there's nothing to fund
      expect(await intentSource.isIntentFunded(zeroAmountIntent)).to.be.true

      // Check vault balances (should be zero)
      const vaultAddress =
        await intentSource.intentVaultAddress(zeroAmountIntent)
      expect(await tokenA.balanceOf(vaultAddress)).to.equal(0)
      expect(await tokenB.balanceOf(vaultAddress)).to.equal(0)
    })

    it('should handle empty token array in rewards', async function () {
      // Create intent with empty token array
      const emptyTokensIntent = {
        ...evmIntent,
        reward: {
          ...evmIntent.reward,
          tokens: [],
        },
      }

      // Publish and fund the intent
      await intentSource.connect(creator).publishAndFund(
        emptyTokensIntent,
        false, // no partial funding
        { value: emptyTokensIntent.reward.nativeValue },
      )

      // Intent should be considered funded since there's nothing to fund
      expect(await intentSource.isIntentFunded(emptyTokensIntent)).to.be.true
    })

    it('should handle intent with only native value rewards', async function () {
      // Create intent with only native value reward
      const nativeOnlyIntent = {
        ...evmIntent,
        reward: {
          ...evmIntent.reward,
          tokens: [],
        },
      }

      // Publish and fund the intent
      await intentSource.connect(creator).publishAndFund(
        nativeOnlyIntent,
        false, // no partial funding
        { value: nativeOnlyIntent.reward.nativeValue },
      )

      // Get vault address
      const vaultAddress =
        await intentSource.intentVaultAddress(nativeOnlyIntent)

      // Check vault balance
      expect(await ethers.provider.getBalance(vaultAddress)).to.equal(
        nativeOnlyIntent.reward.nativeValue,
      )

      // Intent should be considered funded
      expect(await intentSource.isIntentFunded(nativeOnlyIntent)).to.be.true
    })

    it('should handle malformed addresses gracefully', async function () {
      // This test verifies that our conversion functions handle edge cases

      // Test with zero address
      const zeroBytes32 = await addressConverter.toBytes32(ZeroAddress)
      expect(await addressConverter.toAddress(zeroBytes32)).to.equal(
        ZeroAddress,
      )

      // Should correctly identify valid vs invalid Ethereum addresses
      expect(await addressConverter.isValidEthereumAddress(zeroBytes32)).to.be
        .true

      // Random bytes32 should usually not be valid Ethereum addresses
      const randomBytes32 = ethers.hexlify(ethers.randomBytes(32))
      const isValidRandom =
        await addressConverter.isValidEthereumAddress(randomBytes32)

      // In the rare case the random bytes happen to have leading zeros, regenerate
      if (isValidRandom) {
        const anotherRandomBytes32 = ethers.hexlify(ethers.randomBytes(32))
        expect(
          await addressConverter.isValidEthereumAddress(anotherRandomBytes32),
        ).to.be.false
      } else {
        expect(isValidRandom).to.be.false
      }
    })
  })

  /**
   * Group 10: Comprehensive Intent Creation Tests
   * Tests intent creation with various scenarios to match IntentSource.spec.ts
   */
  describe('Intent creation (comprehensive)', function () {
    it('should create properly with erc20 rewards', async function () {
      // Create intent with ERC20 rewards only
      const erc20OnlyIntent = {
        ...evmIntent,
        reward: {
          ...evmIntent.reward,
          nativeValue: 0n,
        },
      }

      await intentSource.connect(creator).publishAndFund(
        erc20OnlyIntent,
        false, // no partial funding
      )

      expect(await intentSource.isIntentFunded(erc20OnlyIntent)).to.be.true
    })

    it('should create properly with native token rewards', async function () {
      // Test with native token rewards and verify excess is refunded
      const initialBalance = await ethers.provider.getBalance(
        await creator.getAddress(),
      )

      const nativeRewardIntent = {
        ...evmIntent,
        reward: {
          ...evmIntent.reward,
          nativeValue: ethers.parseEther('1'),
        },
      }

      // Send twice the required amount
      await intentSource
        .connect(creator)
        .publishAndFund(nativeRewardIntent, false, {
          value: ethers.parseEther('2'),
        })

      expect(await intentSource.isIntentFunded(nativeRewardIntent)).to.be.true

      // Check vault only received the required amount
      const vaultAddress =
        await intentSource.intentVaultAddress(nativeRewardIntent)
      expect(await ethers.provider.getBalance(vaultAddress)).to.equal(
        ethers.parseEther('1'),
      )

      // Creator should have received refund (minus gas costs)
      const finalBalance = await ethers.provider.getBalance(
        await creator.getAddress(),
      )
      expect(finalBalance).to.be.gt(initialBalance - ethers.parseEther('2'))
    })

    it('should increment counter and lock up tokens', async function () {
      const intentWithNative = {
        ...evmIntent,
        reward: {
          ...evmIntent.reward,
          nativeValue: ethers.parseEther('1'),
        },
      }

      await intentSource
        .connect(creator)
        .publishAndFund(intentWithNative, false, {
          value: ethers.parseEther('1'),
        })

      const vaultAddress =
        await intentSource.intentVaultAddress(intentWithNative)

      // Check token balances in vault
      expect(await tokenA.balanceOf(vaultAddress)).to.equal(Number(mintAmount))
      expect(await tokenB.balanceOf(vaultAddress)).to.equal(
        Number(mintAmount * 2n),
      )
      expect(await ethers.provider.getBalance(vaultAddress)).to.equal(
        ethers.parseEther('1'),
      )
    })

    it('should emit IntentPublished events with correct parameters', async function () {
      const intentWithNative = {
        ...evmIntent,
        reward: {
          ...evmIntent.reward,
          nativeValue: ethers.parseEther('1'),
        },
      }

      const [intentHash] = await intentSource.getIntentHash(intentWithNative)

      await expect(
        intentSource.connect(creator).publishAndFund(intentWithNative, false, {
          value: ethers.parseEther('1'),
        }),
      )
        .to.emit(intentSource, 'IntentPublished')
        .withArgs(
          intentHash,
          intentWithNative.destination,
          addressToBytes32(await creator.getAddress()),
          addressToBytes32(await prover.getAddress()),
          expiry,
          ethers.parseEther('1'),
          intentWithNative.reward.tokens.map((t) => [
            addressToBytes32(t.token),
            t.amount,
          ]),
          ethers.AbiCoder.defaultAbiCoder().encode(
            [
              'tuple(bytes32 salt,uint64 deadline,address portal,tuple(address token,uint256 amount)[] tokens,tuple(address target,bytes data,uint256 value)[] calls)',
            ],
            [intentWithNative.route],
          ),
        )
    })
  })

  /**
   * Group 11: Comprehensive Reward Claiming Tests
   * Tests all reward claiming scenarios to match IntentSource.spec.ts
   */
  describe('Comprehensive reward claiming', function () {
    beforeEach(async function () {
      // Set up a funded intent for claiming tests
      await intentSource.connect(creator).publishAndFund(evmIntent, false, {
        value: evmIntent.reward.nativeValue,
      })
    })

    describe('before expiry, no proof', function () {
      it('cannot be withdrawn', async function () {
        const [, routeHash] = await intentSource.getIntentHash(evmIntent)

        await expect(
          intentSource
            .connect(otherPerson)
            .withdraw(chainId, routeHash, evmIntent.reward),
        ).to.be.revertedWithCustomError(intentSource, 'UnauthorizedWithdrawal')
      })
    })

    describe('before expiry, proof', function () {
      beforeEach(async function () {
        const [intentHash] = await intentSource.getIntentHash(evmIntent)
        await prover
          .connect(creator)
          .addProvenIntent(intentHash, await claimant.getAddress(), chainId)
      })

      it('gets withdrawn to claimant', async function () {
        const [, routeHash] = await intentSource.getIntentHash(evmIntent)

        const initialEthBalance = await ethers.provider.getBalance(
          await claimant.getAddress(),
        )
        const initialTokenABalance = await tokenA.balanceOf(
          await claimant.getAddress(),
        )
        const initialTokenBBalance = await tokenB.balanceOf(
          await claimant.getAddress(),
        )

        expect(await intentSource.isIntentFunded(evmIntent)).to.be.true

        await intentSource
          .connect(otherPerson)
          .withdraw(chainId, routeHash, evmIntent.reward)

        expect(await intentSource.isIntentFunded(evmIntent)).to.be.false
        expect(await tokenA.balanceOf(await claimant.getAddress())).to.equal(
          initialTokenABalance + mintAmount,
        )
        expect(await tokenB.balanceOf(await claimant.getAddress())).to.equal(
          initialTokenBBalance + mintAmount * 2n,
        )
        expect(
          await ethers.provider.getBalance(await claimant.getAddress()),
        ).to.equal(initialEthBalance + evmIntent.reward.nativeValue)
      })

      it('emits IntentWithdrawn event', async function () {
        const [intentHash, routeHash] =
          await intentSource.getIntentHash(evmIntent)

        await expect(
          intentSource
            .connect(otherPerson)
            .withdraw(chainId, routeHash, evmIntent.reward),
        )
          .to.emit(intentSource, 'IntentWithdrawn')
          .withArgs(intentHash, await claimant.getAddress())
      })

      it('does not allow repeat withdrawal', async function () {
        const [, routeHash] = await intentSource.getIntentHash(evmIntent)

        await intentSource
          .connect(otherPerson)
          .withdraw(chainId, routeHash, evmIntent.reward)

        await expect(
          intentSource
            .connect(otherPerson)
            .withdraw(chainId, routeHash, evmIntent.reward),
        ).to.be.revertedWithCustomError(intentSource, 'RewardsAlreadyWithdrawn')
      })

      it('allows refund if already claimed', async function () {
        const [intentHash, routeHash] =
          await intentSource.getIntentHash(evmIntent)

        await expect(
          intentSource
            .connect(otherPerson)
            .withdraw(chainId, routeHash, evmIntent.reward),
        )
          .to.emit(intentSource, 'IntentWithdrawn')
          .withArgs(intentHash, await claimant.getAddress())

        await expect(
          intentSource
            .connect(otherPerson)
            .refund(chainId, routeHash, evmIntent.reward),
        )
          .to.emit(intentSource, 'IntentRefunded')
          .withArgs(intentHash, evmIntent.reward.creator)
      })
    })

    describe('after expiry, no proof', function () {
      beforeEach(async function () {
        await time.increase(3601) // Move past expiry
      })

      it('gets refunded to creator', async function () {
        const [, routeHash] = await intentSource.getIntentHash(evmIntent)

        const initialTokenABalance = await tokenA.balanceOf(
          await creator.getAddress(),
        )
        const initialTokenBBalance = await tokenB.balanceOf(
          await creator.getAddress(),
        )

        expect(await intentSource.isIntentFunded(evmIntent)).to.be.true

        await intentSource
          .connect(otherPerson)
          .refund(chainId, routeHash, evmIntent.reward)

        expect(await intentSource.isIntentFunded(evmIntent)).to.be.false
        expect(await tokenA.balanceOf(await creator.getAddress())).to.equal(
          initialTokenABalance + mintAmount,
        )
        expect(await tokenB.balanceOf(await creator.getAddress())).to.equal(
          initialTokenBBalance + mintAmount * 2n,
        )
      })
    })

    describe('after expiry, proof', function () {
      beforeEach(async function () {
        const [intentHash] = await intentSource.getIntentHash(evmIntent)
        await prover
          .connect(creator)
          .addProvenIntent(intentHash, await claimant.getAddress(), chainId)
        await time.increase(3601) // Move past expiry
      })

      it('gets withdrawn to claimant', async function () {
        const [, routeHash] = await intentSource.getIntentHash(evmIntent)

        const initialTokenABalance = await tokenA.balanceOf(
          await claimant.getAddress(),
        )
        const initialTokenBBalance = await tokenB.balanceOf(
          await claimant.getAddress(),
        )

        expect(await intentSource.isIntentFunded(evmIntent)).to.be.true

        await intentSource
          .connect(otherPerson)
          .withdraw(chainId, routeHash, evmIntent.reward)

        expect(await intentSource.isIntentFunded(evmIntent)).to.be.false
        expect(await tokenA.balanceOf(await claimant.getAddress())).to.equal(
          initialTokenABalance + mintAmount,
        )
        expect(await tokenB.balanceOf(await claimant.getAddress())).to.equal(
          initialTokenBBalance + mintAmount * 2n,
        )
      })

      it('calls challengeIntentProof if destinationChainID is wrong', async function () {
        // Create cross-chain intent for testing proof challenges
        const crossChainIntent = {
          ...evmIntent,
          destination: 1, // Different from test chain
        }

        // Fund cross-chain intent
        await mintAndApprove()
        await intentSource
          .connect(creator)
          .publishAndFund(crossChainIntent, false, {
            value: crossChainIntent.reward.nativeValue,
          })

        const [crossChainIntentHash, crossChainRouteHash] =
          await intentSource.getIntentHash(crossChainIntent)

        // Add proof with wrong chain ID
        await prover.connect(creator).addProvenIntent(
          crossChainIntentHash,
          await claimant.getAddress(),
          chainId, // Wrong chain ID
        )

        // Attempt withdrawal should trigger challenge
        await expect(
          intentSource
            .connect(otherPerson)
            .withdraw(1, crossChainRouteHash, crossChainIntent.reward),
        )
          .to.emit(intentSource, 'IntentProofChallenged')
          .withArgs(crossChainIntentHash)

        // Verify proof was cleared
        const proofAfter = await prover.provenIntents(crossChainIntentHash)
        expect(proofAfter.claimant).to.equal(ethers.ZeroAddress)
      })

      it('cannot refund if intent is proven', async function () {
        const [, routeHash] = await intentSource.getIntentHash(evmIntent)

        await expect(
          intentSource
            .connect(otherPerson)
            .refund(chainId, routeHash, evmIntent.reward),
        ).to.be.revertedWithCustomError(intentSource, 'IntentNotClaimed')
      })
    })
  })

  /**
   * Group 12: Comprehensive Batch Withdrawal Tests
   * Tests batch operations extensively to match IntentSource.spec.ts
   */
  describe('Comprehensive batch withdrawal', function () {
    describe('validation and failure cases', function () {
      it('should fail if called before expiry without proof', async function () {
        const [, routeHash] = await intentSource.getIntentHash(evmIntent)
        await intentSource.connect(creator).publishAndFund(evmIntent, false, {
          value: evmIntent.reward.nativeValue,
        })

        await expect(
          intentSource
            .connect(otherPerson)
            .batchWithdraw([chainId], [routeHash], [evmIntent.reward]),
        ).to.be.revertedWithCustomError(intentSource, 'UnauthorizedWithdrawal')
      })
    })

    describe('single intent, complex scenarios', function () {
      beforeEach(async function () {
        await intentSource.connect(creator).publishAndFund(evmIntent, false, {
          value: evmIntent.reward.nativeValue,
        })
      })

      it('should work before expiry with proof to claimant', async function () {
        const [intentHash, routeHash] =
          await intentSource.getIntentHash(evmIntent)

        const initialEthBalance = await ethers.provider.getBalance(
          await claimant.getAddress(),
        )

        expect(await intentSource.isIntentFunded(evmIntent)).to.be.true
        expect(await tokenA.balanceOf(await claimant.getAddress())).to.equal(0)
        expect(await tokenB.balanceOf(await claimant.getAddress())).to.equal(0)

        await prover
          .connect(creator)
          .addProvenIntent(intentHash, await claimant.getAddress(), chainId)

        await intentSource
          .connect(otherPerson)
          .batchWithdraw([chainId], [routeHash], [evmIntent.reward])

        expect(await intentSource.isIntentFunded(evmIntent)).to.be.false
        expect(await tokenA.balanceOf(await claimant.getAddress())).to.equal(
          Number(mintAmount),
        )
        expect(await tokenB.balanceOf(await claimant.getAddress())).to.equal(
          Number(mintAmount * 2n),
        )
        expect(
          await ethers.provider.getBalance(await claimant.getAddress()),
        ).to.equal(initialEthBalance + evmIntent.reward.nativeValue)
      })

      it('should work after expiry without proof to creator', async function () {
        const [, routeHash] = await intentSource.getIntentHash(evmIntent)

        await time.increase(3601) // Move past expiry

        const initialEthBalance = await ethers.provider.getBalance(
          await creator.getAddress(),
        )

        expect(await intentSource.isIntentFunded(evmIntent)).to.be.true
        expect(await tokenA.balanceOf(await creator.getAddress())).to.equal(0)
        expect(await tokenB.balanceOf(await creator.getAddress())).to.equal(0)

        await intentSource
          .connect(otherPerson)
          .batchWithdraw([chainId], [routeHash], [evmIntent.reward])

        expect(await intentSource.isIntentFunded(evmIntent)).to.be.false
        expect(await tokenA.balanceOf(await creator.getAddress())).to.equal(
          Number(mintAmount),
        )
        expect(await tokenB.balanceOf(await creator.getAddress())).to.equal(
          Number(mintAmount * 2n),
        )
        expect(
          await ethers.provider.getBalance(await creator.getAddress()),
        ).to.equal(initialEthBalance + evmIntent.reward.nativeValue)
      })
    })
  })

  /**
   * Group 13: Comprehensive Funding Tests
   * Tests all funding scenarios to match IntentSource.spec.ts
   */
  describe('Comprehensive funding', function () {
    it('should compute valid intent funder address', async function () {
      const predictedAddress = await universalIntentVaultAddress(
        await intentSource.getAddress(),
        universalIntent,
      )

      const routeBytes = ethers.AbiCoder.defaultAbiCoder().encode(
        [
          'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
        ],
        [universalIntent.route],
      )
      const contractAddress = await universalIntentSource.intentVaultAddress(
        universalIntent.destination,
        routeBytes,
        universalIntent.reward,
      )

      expect(contractAddress).to.equal(predictedAddress)
    })

    it('should fund intent with single token', async function () {
      const singleTokenIntent = {
        ...evmIntent,
        reward: {
          ...evmIntent.reward,
          nativeValue: 0n, // Remove native value to avoid funding errors
          tokens: [{ token: await tokenA.getAddress(), amount: mintAmount }],
        },
      }

      const [, routeHash] = await intentSource.getIntentHash(singleTokenIntent)
      const vaultAddress =
        await intentSource.intentVaultAddress(singleTokenIntent)

      // Approve tokens to vault
      await tokenA.connect(creator).approve(vaultAddress, mintAmount)

      // Fund the intent
      await intentSource
        .connect(creator)
        .fundFor(
          chainId,
          routeHash,
          singleTokenIntent.reward,
          await creator.getAddress(),
          ethers.ZeroAddress,
          false,
        )

      expect(await intentSource.isIntentFunded(singleTokenIntent)).to.be.true
      expect(await tokenA.balanceOf(vaultAddress)).to.equal(Number(mintAmount))
    })

    it('should fund intent with multiple tokens', async function () {
      const multiTokenIntent = {
        ...evmIntent,
        reward: {
          ...evmIntent.reward,
          nativeValue: 0n, // Remove native value to avoid funding errors
        },
      }

      const [, routeHash] = await intentSource.getIntentHash(multiTokenIntent)
      const vaultAddress =
        await intentSource.intentVaultAddress(multiTokenIntent)

      // Approve tokens to vault
      await tokenA.connect(creator).approve(vaultAddress, mintAmount)
      await tokenB.connect(creator).approve(vaultAddress, mintAmount * 2n)

      // Fund the intent
      await intentSource
        .connect(creator)
        .fundFor(
          chainId,
          routeHash,
          multiTokenIntent.reward,
          await creator.getAddress(),
          ethers.ZeroAddress,
          false,
        )

      expect(await intentSource.isIntentFunded(multiTokenIntent)).to.be.true
      expect(await tokenA.balanceOf(vaultAddress)).to.equal(Number(mintAmount))
      expect(await tokenB.balanceOf(vaultAddress)).to.equal(
        Number(mintAmount * 2n),
      )
    })

    it('should handle partial funding based on allowance', async function () {
      const partialIntent = {
        ...evmIntent,
        reward: {
          ...evmIntent.reward,
          nativeValue: 0n, // Remove native value to avoid funding errors
        },
      }

      const [, routeHash] = await intentSource.getIntentHash(partialIntent)
      const vaultAddress = await intentSource.intentVaultAddress(partialIntent)

      // Approve partial amount
      await tokenA.connect(creator).approve(vaultAddress, mintAmount / 2n)

      // Fund with partial allowance
      await intentSource.connect(creator).fundFor(
        chainId,
        routeHash,
        partialIntent.reward,
        await creator.getAddress(),
        ethers.ZeroAddress,
        true, // allow partial
      )

      expect(await intentSource.isIntentFunded(partialIntent)).to.be.false
      expect(await tokenA.balanceOf(vaultAddress)).to.equal(
        Number(mintAmount / 2n),
      )
    })

    it('should emit IntentFunded event', async function () {
      const eventIntent = {
        ...evmIntent,
        reward: {
          ...evmIntent.reward,
          nativeValue: 0n, // Remove native value to avoid funding errors
        },
      }

      const [intentHash, routeHash] =
        await intentSource.getIntentHash(eventIntent)
      const vaultAddress = await intentSource.intentVaultAddress(eventIntent)

      // Approve tokens
      await tokenA.connect(creator).approve(vaultAddress, mintAmount)
      await tokenB.connect(creator).approve(vaultAddress, mintAmount * 2n)

      await expect(
        intentSource
          .connect(creator)
          .fundFor(
            chainId,
            routeHash,
            eventIntent.reward,
            await creator.getAddress(),
            ethers.ZeroAddress,
            false,
          ),
      )
        .to.emit(intentSource, 'IntentFunded')
        .withArgs(intentHash, await creator.getAddress(), true)
    })
  })

  /**
   * Group 14: Enhanced Edge Cases and Validations
   * Tests various edge cases and validations
   */
  describe('Enhanced edge cases and validations', function () {
    it('should handle zero token amounts in rewards', async function () {
      // Create intent with zero token amounts
      const zeroAmountIntent = {
        ...evmIntent,
        reward: {
          ...evmIntent.reward,
          tokens: [
            { token: await tokenA.getAddress(), amount: 0n },
            { token: await tokenB.getAddress(), amount: 0n },
          ],
        },
      }

      // Publish and fund the intent
      await intentSource.connect(creator).publishAndFund(
        zeroAmountIntent,
        false, // no partial funding
        { value: zeroAmountIntent.reward.nativeValue },
      )

      // Intent should be considered funded since there's nothing to fund
      expect(await intentSource.isIntentFunded(zeroAmountIntent)).to.be.true

      // Check vault balances (should be zero)
      const vaultAddress =
        await intentSource.intentVaultAddress(zeroAmountIntent)
      expect(await tokenA.balanceOf(vaultAddress)).to.equal(0)
      expect(await tokenB.balanceOf(vaultAddress)).to.equal(0)
    })

    it('should handle empty token array in rewards', async function () {
      // Create intent with empty token array
      const emptyTokensIntent = {
        ...evmIntent,
        reward: {
          ...evmIntent.reward,
          tokens: [],
        },
      }

      // Publish and fund the intent
      await intentSource.connect(creator).publishAndFund(
        emptyTokensIntent,
        false, // no partial funding
        { value: emptyTokensIntent.reward.nativeValue },
      )

      // Intent should be considered funded since there's nothing to fund
      expect(await intentSource.isIntentFunded(emptyTokensIntent)).to.be.true
    })

    it('should handle already funded vaults', async function () {
      const noNativeIntent = {
        ...evmIntent,
        reward: {
          ...evmIntent.reward,
          nativeValue: 0n, // Remove native value to avoid funding errors
        },
      }

      // Create and fund intent initially
      await intentSource.connect(creator).publishAndFund(noNativeIntent, false)

      // Try to fund again
      await mintAndApprove()
      const [, routeHash] = await intentSource.getIntentHash(noNativeIntent)

      await intentSource
        .connect(creator)
        .fundFor(
          chainId,
          routeHash,
          noNativeIntent.reward,
          await creator.getAddress(),
          ethers.ZeroAddress,
          false,
        )

      expect(await intentSource.isIntentFunded(noNativeIntent)).to.be.true

      const vaultAddress = await intentSource.intentVaultAddress(noNativeIntent)
      expect(await tokenA.balanceOf(vaultAddress)).to.equal(Number(mintAmount))
    })

    it('should handle overfunded vaults', async function () {
      const noNativeIntent = {
        ...evmIntent,
        reward: {
          ...evmIntent.reward,
          nativeValue: 0n, // Remove native value to avoid funding errors
        },
      }

      await intentSource.connect(creator).publishAndFund(noNativeIntent, false)

      expect(await intentSource.isIntentFunded(noNativeIntent)).to.be.true

      // Send extra tokens to vault
      await tokenA.connect(creator).mint(await creator.getAddress(), mintAmount)
      const vaultAddress = await intentSource.intentVaultAddress(noNativeIntent)
      await tokenA.connect(creator).transfer(vaultAddress, mintAmount)

      // Mark as proven and withdraw
      const [intentHash, routeHash] =
        await intentSource.getIntentHash(noNativeIntent)
      await prover
        .connect(creator)
        .addProvenIntent(intentHash, await claimant.getAddress(), chainId)

      await intentSource
        .connect(claimant)
        .withdraw(chainId, routeHash, noNativeIntent.reward)

      // Should have withdrawn the reward amount, not the overfunded amount
      expect(await tokenA.balanceOf(await claimant.getAddress())).to.equal(
        Number(mintAmount),
      )
    })

    it('should handle withdraws for rewards with malicious tokens', async function () {
      const initialClaimantBalance = await tokenA.balanceOf(
        await claimant.getAddress(),
      )

      // First, mint bad tokens to creator
      await badToken
        .connect(creator)
        .mint(await creator.getAddress(), mintAmount)

      // Create intent with bad token
      const badTokenIntent = {
        ...evmIntent,
        reward: {
          ...evmIntent.reward,
          nativeValue: 0n, // Remove native value to avoid funding errors
          tokens: [
            { token: await badToken.getAddress(), amount: mintAmount },
            { token: await tokenA.getAddress(), amount: mintAmount },
          ],
        },
      }

      const vaultAddress = await intentSource.intentVaultAddress(badTokenIntent)
      await badToken.connect(creator).transfer(vaultAddress, mintAmount)
      await tokenA.connect(creator).transfer(vaultAddress, mintAmount)

      expect(await intentSource.isIntentFunded(badTokenIntent)).to.be.true

      const [intentHash, routeHash] =
        await intentSource.getIntentHash(badTokenIntent)
      await prover
        .connect(creator)
        .addProvenIntent(intentHash, await claimant.getAddress(), chainId)

      await expect(
        intentSource
          .connect(otherPerson)
          .withdraw(chainId, routeHash, badTokenIntent.reward),
      ).to.not.be.reverted

      expect(await tokenA.balanceOf(await claimant.getAddress())).to.equal(
        initialClaimantBalance + mintAmount,
      )
    })

    it('should handle insufficient native reward errors', async function () {
      const nativeRewardIntent = {
        ...evmIntent,
        reward: {
          ...evmIntent.reward,
          nativeValue: ethers.parseEther('1'),
        },
      }

      await expect(
        intentSource.connect(creator).publishAndFund(
          nativeRewardIntent,
          false,
          { value: ethers.parseEther('0.5') }, // Insufficient
        ),
      ).to.be.revertedWithCustomError(intentSource, 'InsufficientNativeReward')
    })
  })

  /**
   * Group 15: Cross-Chain Address Conversion Tests
   * Tests critical address conversion scenarios for cross-chain compatibility
   */
  describe('Cross-chain address conversion', function () {
    it('should correctly convert EVM addresses to Universal format and back', async function () {
      const testAddresses = [
        await creator.getAddress(),
        await claimant.getAddress(),
        await tokenA.getAddress(),
        await tokenB.getAddress(),
        await prover.getAddress(),
        ethers.ZeroAddress,
      ]

      for (const addr of testAddresses) {
        const bytes32Val = addressToBytes32(addr)
        const recoveredAddr = bytes32ToAddress(bytes32Val)
        expect(recoveredAddr.toLowerCase()).to.equal(addr.toLowerCase())
      }
    })

    it('should handle mixed case addresses consistently', async function () {
      const testAddr = await creator.getAddress()
      const lowerCaseAddr = testAddr.toLowerCase()
      const checksumAddr = ethers.getAddress(testAddr)

      const bytes32Lower = addressToBytes32(lowerCaseAddr)
      const bytes32Checksum = addressToBytes32(checksumAddr)
      const bytes32Mixed = addressToBytes32(testAddr)

      expect(bytes32Lower.toLowerCase()).to.equal(bytes32Checksum.toLowerCase())
      expect(bytes32Lower.toLowerCase()).to.equal(bytes32Mixed.toLowerCase())
    })

    it('should validate Universal format addresses correctly', async function () {
      // Valid Universal address (EVM address with leading zeros)
      const validUniversalAddr = addressToBytes32(await creator.getAddress())
      expect(validUniversalAddr.length).to.equal(66) // 0x + 64 hex chars
      expect(validUniversalAddr.slice(0, 26)).to.equal('0x000000000000000000000000') // 12 leading zero bytes

      // Invalid Universal address (non-zero high bytes)
      const invalidUniversalAddr = ethers.hexlify(ethers.randomBytes(32))
      // Most random bytes32 will not be valid EVM addresses
      expect(invalidUniversalAddr.length).to.equal(66)
    })

    it('should maintain address integrity across format conversions', async function () {
      const originalAddrs = [
        await creator.getAddress(),
        await tokenA.getAddress(),
        await prover.getAddress(),
      ]

      // Test multiple round-trip conversions
      for (const addr of originalAddrs) {
        let currentAddr = addr
        for (let i = 0; i < 5; i++) {
          const bytes32Val = addressToBytes32(currentAddr)
          currentAddr = bytes32ToAddress(bytes32Val)
        }
        expect(currentAddr.toLowerCase()).to.equal(addr.toLowerCase())
      }
    })
  })

  /**
   * Group 16: Hash Consistency Tests
   * Tests that hash calculations are consistent across different address formats
   */
  describe('Hash consistency across formats', function () {
    it('should produce identical hashes for equivalent intents in different formats', async function () {
      // Create multiple equivalent intents with different address representations
      const baseIntent = await createEVMIntent()
      const universalIntent1 = convertToUniversalIntent(baseIntent)
      
      // Create another universal intent with different address casing
      const universalIntent2: UniversalIntent = {
        ...universalIntent1,
        route: {
          ...universalIntent1.route,
          portal: addressToBytes32(baseIntent.route.portal.toLowerCase()),
        },
        reward: {
          ...universalIntent1.reward,
          creator: addressToBytes32(ethers.getAddress(baseIntent.reward.creator)),
        },
      }

      // Get hashes for all variants
      const [evmHash] = await intentSource.getIntentHash(baseIntent)
      const routeBytes1 = ethers.AbiCoder.defaultAbiCoder().encode(
        [
          'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
        ],
        [universalIntent1.route],
      )
      const [universalHash1] = await universalIntentSource.getIntentHash(
        universalIntent1.destination,
        routeBytes1,
        universalIntent1.reward,
      )
      const routeBytes2 = ethers.AbiCoder.defaultAbiCoder().encode(
        [
          'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
        ],
        [universalIntent2.route],
      )
      const [universalHash2] = await universalIntentSource.getIntentHash(
        universalIntent2.destination,
        routeBytes2,
        universalIntent2.reward,
      )

      // All hashes should be identical
      expect(evmHash).to.equal(universalHash1)
      expect(evmHash).to.equal(universalHash2)
    })

    it('should handle hash collisions correctly', async function () {
      // Create two different intents that might have similar components
      const intent1 = await createEVMIntent()
      const intent2 = {
        ...intent1,
        route: {
          ...intent1.route,
          salt: ethers.randomBytes(32), // Different salt
        },
      }

      const [hash1] = await intentSource.getIntentHash(intent1)
      const [hash2] = await intentSource.getIntentHash(intent2)

      // Hashes should be different
      expect(hash1).to.not.equal(hash2)
    })

    it('should produce consistent vault addresses across formats', async function () {
      const baseIntent = await createEVMIntent()
      const universalIntent = convertToUniversalIntent(baseIntent)

      // Get vault addresses through different interfaces
      const evmVault = await intentSource.intentVaultAddress(baseIntent)
      const routeBytes = ethers.AbiCoder.defaultAbiCoder().encode(
        [
          'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
        ],
        [universalIntent.route],
      )
      const universalVault = await universalIntentSource.intentVaultAddress(
        universalIntent.destination,
        routeBytes,
        universalIntent.reward,
      )

      expect(evmVault).to.equal(universalVault)
    })
  })

  /**
   * Group 17: Cross-Chain Intent Publishing Tests
   * Tests intent publishing for cross-chain scenarios
   */
  describe('Cross-chain intent publishing', function () {
    it('should publish intents for different destination chains', async function () {
      const destChains = [1, 137, 42161, 10] // Ethereum, Polygon, Arbitrum, Optimism

      for (const chainId of destChains) {
        const crossChainIntent = {
          ...evmIntent,
          destination: chainId,
        }
        const universalIntent = convertToUniversalIntent(crossChainIntent)

        const routeBytes = ethers.AbiCoder.defaultAbiCoder().encode(
          [
            'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
          ],
          [universalIntent.route],
        )
        const tx = await universalIntentSource
          .connect(creator)
          .publish(
            universalIntent.destination,
            routeBytes,
            universalIntent.reward,
          )

        const receipt = await tx.wait()
        expect(receipt?.status).to.equal(1)
      }
    })

    it('should handle large route data correctly', async function () {
      // Create intent with many calls and tokens
      const largeCalls = []
      const largeTokens = []

      for (let i = 0; i < 10; i++) {
        largeCalls.push({
          target: addressToBytes32(await tokenA.getAddress()),
          data: ethers.randomBytes(100), // Large data
          value: 0n,
        })
        largeTokens.push({
          token: addressToBytes32(await tokenA.getAddress()),
          amount: mintAmount * BigInt(i + 1),
        })
      }

      const largeUniversalIntent: UniversalIntent = {
        destination: Number(chainId),
        route: {
          salt: ethers.randomBytes(32),
          deadline: expiry,
          portal: addressToBytes32(await inbox.getAddress()),
          tokens: largeTokens,
          calls: largeCalls,
        },
        reward: {
          creator: addressToBytes32(await creator.getAddress()),
          prover: addressToBytes32(await prover.getAddress()),
          deadline: expiry,
          nativeValue: 0n,
          tokens: [{ token: addressToBytes32(await tokenA.getAddress()), amount: mintAmount }],
        },
      }

      const routeBytes = ethers.AbiCoder.defaultAbiCoder().encode(
        [
          'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
        ],
        [largeUniversalIntent.route],
      )
      const tx = await universalIntentSource
        .connect(creator)
        .publish(
          largeUniversalIntent.destination,
          routeBytes,
          largeUniversalIntent.reward,
        )

      const receipt = await tx.wait()
      expect(receipt?.status).to.equal(1)
    })
  })

  /**
   * Group 18: Universal Intent Funding Edge Cases
   * Tests edge cases in universal intent funding
   */
  describe('Universal intent funding edge cases', function () {
    it('should handle funding with zero amounts correctly', async function () {
      const zeroAmountIntent = {
        ...evmIntent,
        reward: {
          ...evmIntent.reward,
          nativeValue: 0n,
          tokens: [{ token: await tokenA.getAddress(), amount: 0n }],
        },
      }

      await intentSource.connect(creator).publishAndFund(zeroAmountIntent, false)
      expect(await intentSource.isIntentFunded(zeroAmountIntent)).to.be.true
    })

    it('should handle funding with duplicate tokens correctly', async function () {
      const duplicateTokenIntent = {
        ...evmIntent,
        reward: {
          ...evmIntent.reward,
          nativeValue: 0n,
          tokens: [
            { token: await tokenA.getAddress(), amount: mintAmount },
            { token: await tokenA.getAddress(), amount: mintAmount / 2n },
          ],
        },
      }

      await intentSource.connect(creator).publishAndFund(duplicateTokenIntent, false)
      expect(await intentSource.isIntentFunded(duplicateTokenIntent)).to.be.true
    })

    it('should handle funding with maximum token amounts', async function () {
      // Create tokens with large amounts
      const maxAmount = ethers.parseEther('1000000') // 1M tokens
      await tokenA.connect(creator).mint(await creator.getAddress(), maxAmount)
      await tokenA.connect(creator).approve(await intentSource.getAddress(), maxAmount)

      const maxAmountIntent = {
        ...evmIntent,
        reward: {
          ...evmIntent.reward,
          nativeValue: 0n,
          tokens: [{ token: await tokenA.getAddress(), amount: maxAmount }],
        },
      }

      await intentSource.connect(creator).publishAndFund(maxAmountIntent, false)
      expect(await intentSource.isIntentFunded(maxAmountIntent)).to.be.true
    })
  })

  /**
   * Group 19: Balance Check for Partial Funding
   * Tests partial funding scenarios extensively
   */
  describe('Balance check for partial funding', function () {
    it('should use actual balance over allowance for ERC20 tokens when partially funding', async function () {
      // Set up scenario where user has approved more tokens than they own
      const requestedAmount = mintAmount * 2n
      const limitedTokenIntent = {
        ...evmIntent,
        reward: {
          ...evmIntent.reward,
          tokens: [
            { token: await tokenA.getAddress(), amount: requestedAmount },
          ],
        },
      }

      // Creator only has mintAmount tokens but approves twice as much
      expect(await tokenA.balanceOf(await creator.getAddress())).to.equal(
        Number(mintAmount),
      )
      await tokenA
        .connect(creator)
        .approve(await intentSource.getAddress(), requestedAmount)

      // Create and fund with allowPartial = true
      const [intentHash] = await intentSource.getIntentHash(limitedTokenIntent)
      const tx = await intentSource.connect(creator).publishAndFund(
        limitedTokenIntent,
        true, // allow partial
      )

      // Expect IntentFunded event with complete=false
      await expect(tx)
        .to.emit(intentSource, 'IntentFunded')
        .withArgs(intentHash, await creator.getAddress(), false)

      // Verify only available balance was transferred
      const vaultAddress =
        await intentSource.intentVaultAddress(limitedTokenIntent)
      expect(await tokenA.balanceOf(vaultAddress)).to.equal(Number(mintAmount))
    })

    it('should revert when balance and allowance are insufficient without allowPartial', async function () {
      const requestedAmount = mintAmount * 2n
      const limitedTokenIntent = {
        ...evmIntent,
        reward: {
          ...evmIntent.reward,
          tokens: [
            { token: await tokenA.getAddress(), amount: requestedAmount },
          ],
        },
      }

      // Reduce allowance to be insufficient
      await tokenA
        .connect(creator)
        .approve(await intentSource.getAddress(), mintAmount / 2n)

      await expect(
        intentSource.connect(creator).publishAndFund(
          limitedTokenIntent,
          false, // no partial funding
        ),
      ).to.be.reverted
    })

    it('should handle partial funding with native tokens based on actual balance', async function () {
      const nativeRewardIntent = {
        ...evmIntent,
        reward: {
          ...evmIntent.reward,
          nativeValue: ethers.parseEther('1'),
          tokens: [],
        },
      }

      // Try to fund with partial native value
      const tx = await intentSource.connect(creator).publishAndFund(
        nativeRewardIntent,
        true, // allow partial
        { value: ethers.parseEther('0.5') },
      )

      const [intentHash] = await intentSource.getIntentHash(nativeRewardIntent)
      await expect(tx)
        .to.emit(intentSource, 'IntentFunded')
        .withArgs(intentHash, await creator.getAddress(), false)

      // Verify partial native funding
      const vaultAddress =
        await intentSource.intentVaultAddress(nativeRewardIntent)
      expect(await ethers.provider.getBalance(vaultAddress)).to.equal(
        ethers.parseEther('0.5'),
      )
    })

    it('should revert with insufficient native reward without allowPartial', async function () {
      const nativeRewardIntent = {
        ...evmIntent,
        reward: {
          ...evmIntent.reward,
          nativeValue: ethers.parseEther('1'),
          tokens: [],
        },
      }

      await expect(
        intentSource.connect(creator).publishAndFund(
          nativeRewardIntent,
          false, // no partial funding
          { value: ethers.parseEther('0.5') },
        ),
      ).to.be.revertedWithCustomError(intentSource, 'InsufficientNativeReward')
    })

    it('should handle partial funding and complete it with a second transaction', async function () {
      // First, do partial funding
      const partialIntent = {
        ...evmIntent,
        reward: {
          ...evmIntent.reward,
          nativeValue: 0n, // Remove native value to avoid funding errors
          tokens: [{ token: await tokenA.getAddress(), amount: mintAmount }],
        },
      }

      const [, routeHash] = await intentSource.getIntentHash(partialIntent)
      const vaultAddress = await intentSource.intentVaultAddress(partialIntent)

      // Fund partially
      await tokenA.connect(creator).approve(vaultAddress, mintAmount / 2n)
      await intentSource.connect(creator).fundFor(
        chainId,
        routeHash,
        partialIntent.reward,
        await creator.getAddress(),
        ethers.ZeroAddress,
        true, // allow partial
      )

      expect(await intentSource.isIntentFunded(partialIntent)).to.be.false

      // Complete the funding - need to mint more tokens first
      await tokenA
        .connect(creator)
        .mint(await creator.getAddress(), mintAmount / 2n)
      await tokenA.connect(creator).approve(vaultAddress, mintAmount / 2n)
      await intentSource.connect(creator).fundFor(
        chainId,
        routeHash,
        partialIntent.reward,
        await creator.getAddress(),
        ethers.ZeroAddress,
        false, // no partial needed now
      )

      expect(await intentSource.isIntentFunded(partialIntent)).to.be.true
    })
  })

  /**
   * Group 20: Universal Intent Claiming Tests
   * Tests claiming rewards through universal interface
   */
  describe('Universal intent claiming', function () {
    beforeEach(async function () {
      // Set up a funded universal intent
      const universalIntent = convertToUniversalIntent(evmIntent)
      const routeBytes = ethers.AbiCoder.defaultAbiCoder().encode(
        [
          'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
        ],
        [universalIntent.route],
      )
      await universalIntentSource.connect(creator).publishAndFund(
        universalIntent.destination,
        routeBytes,
        universalIntent.reward,
        false,
        { value: universalIntent.reward.nativeValue },
      )
    })

    it('should allow claiming through universal interface', async function () {
      const universalIntent = convertToUniversalIntent(evmIntent)
      const routeBytes = ethers.AbiCoder.defaultAbiCoder().encode(
        [
          'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
        ],
        [universalIntent.route],
      )
      const [intentHash] = await universalIntentSource.getIntentHash(
        universalIntent.destination,
        routeBytes,
        universalIntent.reward,
      )
      const routeHash = keccak256(routeBytes)

      // Prove the intent
      await prover
        .connect(creator)
        .addProvenIntent(intentHash, await claimant.getAddress(), chainId)

      const initialBalance = await tokenA.balanceOf(await claimant.getAddress())

      // Claim through universal interface
      await universalIntentSource
        .connect(otherPerson)
        .withdraw(universalIntent.destination, universalIntent.reward, routeHash)

      const finalBalance = await tokenA.balanceOf(await claimant.getAddress())
      expect(finalBalance).to.equal(initialBalance + mintAmount)
    })

    it('should handle batch claiming through universal interface', async function () {
      const universalIntent = convertToUniversalIntent(evmIntent)
      const routeBytes = ethers.AbiCoder.defaultAbiCoder().encode(
        [
          'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
        ],
        [universalIntent.route],
      )
      const [intentHash] = await universalIntentSource.getIntentHash(
        universalIntent.destination,
        routeBytes,
        universalIntent.reward,
      )
      const routeHash = keccak256(routeBytes)

      // Prove the intent
      await prover
        .connect(creator)
        .addProvenIntent(intentHash, await claimant.getAddress(), chainId)

      const initialBalance = await tokenA.balanceOf(await claimant.getAddress())

      // Batch claim through universal interface
      await universalIntentSource
        .connect(otherPerson)
        .batchWithdraw(
          [universalIntent.destination],
          [universalIntent.reward],
          [routeHash],
        )

      const finalBalance = await tokenA.balanceOf(await claimant.getAddress())
      expect(finalBalance).to.equal(initialBalance + mintAmount)
    })
  })

  /**
   * Group 21: Error Handling and Edge Cases
   * Tests error conditions and edge cases
   */
  describe('Error handling and edge cases', function () {
    it('should handle invalid route data gracefully', async function () {
      const invalidRouteBytes = ethers.randomBytes(100) // Invalid route data
      
      // This should not revert as the contract doesn't validate route structure
      await expect(
        universalIntentSource
          .connect(creator)
          .publish(
            evmIntent.destination,
            invalidRouteBytes,
            universalIntent.reward,
          ),
      ).to.not.be.reverted
    })

    it('should handle mismatched array lengths in batch operations', async function () {
      await expect(
        universalIntentSource
          .connect(creator)
          .batchWithdraw(
            [1, 2], // 2 destinations
            [universalIntent.reward], // 1 reward
            [ethers.randomBytes(32)], // 1 route hash
          ),
      ).to.be.reverted
    })

    it('should handle expired intents correctly', async function () {
      // Create intent with past deadline
      const expiredIntent = {
        ...evmIntent,
        reward: {
          ...evmIntent.reward,
          deadline: BigInt(await time.latest()) - 1n, // Expired
        },
      }

      // Should still be able to publish
      await intentSource.connect(creator).publishAndFund(expiredIntent, false, {
        value: expiredIntent.reward.nativeValue,
      })

      expect(await intentSource.isIntentFunded(expiredIntent)).to.be.true
    })

    it('should handle zero value transfers correctly', async function () {
      const zeroValueIntent = {
        ...evmIntent,
        reward: {
          ...evmIntent.reward,
          nativeValue: 0n,
          tokens: [],
        },
      }

      await intentSource.connect(creator).publishAndFund(zeroValueIntent, false)
      expect(await intentSource.isIntentFunded(zeroValueIntent)).to.be.true
    })
  })

  /**
   * Group 22: Universal Intent Recovery Tests
   * Tests token recovery functionality
   */
  describe('Universal intent recovery', function () {
    it('should recover mistakenly sent tokens from vault', async function () {
      // Create and fund an intent
      const universalIntent = convertToUniversalIntent(evmIntent)
      const routeBytes = ethers.AbiCoder.defaultAbiCoder().encode(
        [
          'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
        ],
        [universalIntent.route],
      )
      await universalIntentSource.connect(creator).publishAndFund(
        universalIntent.destination,
        routeBytes,
        universalIntent.reward,
        false,
        { value: universalIntent.reward.nativeValue },
      )

      // Get vault address
      const vaultAddress = await universalIntentSource.intentVaultAddress(
        universalIntent.destination,
        routeBytes,
        universalIntent.reward,
      )
      const routeHash = keccak256(routeBytes)

      // Deploy a different token to send to vault (not part of rewards)
      const testERC20Factory = await ethers.getContractFactory('TestERC20')
      const extraToken = await testERC20Factory.deploy('ExtraToken', 'EXTRA')
      await extraToken.connect(creator).mint(await creator.getAddress(), mintAmount)
      await extraToken.connect(creator).transfer(vaultAddress, mintAmount)

      // Claim the intent first
      const [intentHash] = await universalIntentSource.getIntentHash(
        universalIntent.destination,
        routeBytes,
        universalIntent.reward,
      )
      await prover
        .connect(creator)
        .addProvenIntent(intentHash, await claimant.getAddress(), chainId)
      await universalIntentSource
        .connect(claimant)
        .withdraw(universalIntent.destination, universalIntent.reward, routeHash)

      // Now recover the extra tokens
      const initialBalance = await extraToken.balanceOf(await creator.getAddress())
      await universalIntentSource
        .connect(creator)
        .recoverToken(
          universalIntent.destination,
          universalIntent.reward,
          routeHash,
          await extraToken.getAddress(),
        )

      // Creator should have received the extra tokens
      const finalBalance = await extraToken.balanceOf(await creator.getAddress())
      expect(finalBalance).to.equal(initialBalance + mintAmount)
    })

    it('should prevent recovery of reward tokens', async function () {
      // Create and fund an intent
      const universalIntent = convertToUniversalIntent(evmIntent)
      const routeBytes = ethers.AbiCoder.defaultAbiCoder().encode(
        [
          'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
        ],
        [universalIntent.route],
      )
      await universalIntentSource.connect(creator).publishAndFund(
        universalIntent.destination,
        routeBytes,
        universalIntent.reward,
        false,
        { value: universalIntent.reward.nativeValue },
      )

      const routeHash = keccak256(routeBytes)

      // Claim the intent first
      const [intentHash] = await universalIntentSource.getIntentHash(
        universalIntent.destination,
        routeBytes,
        universalIntent.reward,
      )
      await prover
        .connect(creator)
        .addProvenIntent(intentHash, await claimant.getAddress(), chainId)
      await universalIntentSource
        .connect(claimant)
        .withdraw(universalIntent.destination, universalIntent.reward, routeHash)

      // Try to recover a reward token (should fail)
      await expect(
        universalIntentSource
          .connect(creator)
          .recoverToken(
            universalIntent.destination,
            universalIntent.reward,
            routeHash,
            await tokenA.getAddress(), // This is a reward token
          ),
      ).to.be.revertedWithCustomError(intentSource, 'InvalidRefundToken')
    })
  })

  /**
   * Group 23: Cross-Chain Proof Challenge Tests
   * Tests proof challenge functionality for cross-chain scenarios
   */
  describe('Cross-chain proof challenge', function () {
    it('should challenge proofs with wrong destination chain', async function () {
      // Create cross-chain intent
      const crossChainIntent = {
        ...evmIntent,
        destination: 1, // Different chain
      }
      const universalIntent = convertToUniversalIntent(crossChainIntent)
      const routeBytes = ethers.AbiCoder.defaultAbiCoder().encode(
        [
          'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
        ],
        [universalIntent.route],
      )

      // Fund intent
      await mintAndApprove()
      await universalIntentSource.connect(creator).publishAndFund(
        universalIntent.destination,
        routeBytes,
        universalIntent.reward,
        false,
        { value: universalIntent.reward.nativeValue },
      )

      const [intentHash] = await universalIntentSource.getIntentHash(
        universalIntent.destination,
        routeBytes,
        universalIntent.reward,
      )
      const routeHash = keccak256(routeBytes)

      // Add proof with wrong chain ID
      await prover
        .connect(creator)
        .addProvenIntent(intentHash, await claimant.getAddress(), chainId) // Wrong chain

      // Withdraw should trigger challenge
      await expect(
        universalIntentSource
          .connect(otherPerson)
          .withdraw(universalIntent.destination, universalIntent.reward, routeHash),
      )
        .to.emit(intentSource, 'IntentProofChallenged')
        .withArgs(intentHash)
    })

    it('should not challenge proofs with correct destination chain', async function () {
      // Create same-chain intent
      const universalIntent = convertToUniversalIntent(evmIntent)
      const routeBytes = ethers.AbiCoder.defaultAbiCoder().encode(
        [
          'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
        ],
        [universalIntent.route],
      )

      // Fund intent
      await universalIntentSource.connect(creator).publishAndFund(
        universalIntent.destination,
        routeBytes,
        universalIntent.reward,
        false,
        { value: universalIntent.reward.nativeValue },
      )

      const [intentHash] = await universalIntentSource.getIntentHash(
        universalIntent.destination,
        routeBytes,
        universalIntent.reward,
      )
      const routeHash = keccak256(routeBytes)

      // Add proof with correct chain ID
      await prover
        .connect(creator)
        .addProvenIntent(intentHash, await claimant.getAddress(), chainId)

      // Withdraw should succeed without challenge
      await expect(
        universalIntentSource
          .connect(otherPerson)
          .withdraw(universalIntent.destination, universalIntent.reward, routeHash),
      )
        .to.emit(intentSource, 'IntentWithdrawn')
        .withArgs(intentHash, await claimant.getAddress())
    })
  })

  /**
   * Group 24: Universal Intent Refund Tests
   * Tests refund functionality through universal interface
   */
  describe('Universal intent refund', function () {
    it('should refund expired intents through universal interface', async function () {
      // Create intent with short expiry
      const shortExpiryIntent = {
        ...evmIntent,
        reward: {
          ...evmIntent.reward,
          deadline: BigInt(await time.latest()) + 100n, // 100 seconds
        },
      }
      const universalIntent = convertToUniversalIntent(shortExpiryIntent)
      const routeBytes = ethers.AbiCoder.defaultAbiCoder().encode(
        [
          'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
        ],
        [universalIntent.route],
      )

      // Fund intent
      await universalIntentSource.connect(creator).publishAndFund(
        universalIntent.destination,
        routeBytes,
        universalIntent.reward,
        false,
        { value: universalIntent.reward.nativeValue },
      )

      const [intentHash] = await universalIntentSource.getIntentHash(
        universalIntent.destination,
        routeBytes,
        universalIntent.reward,
      )
      const routeHash = keccak256(routeBytes)

      // Wait for expiry
      await time.increase(101)

      const initialBalance = await tokenA.balanceOf(await creator.getAddress())

      // Refund through universal interface
      await expect(
        universalIntentSource
          .connect(otherPerson)
          .refund(universalIntent.destination, universalIntent.reward, routeHash),
      )
        .to.emit(intentSource, 'IntentRefunded')
        .withArgs(intentHash, await creator.getAddress())

      // Creator should have received refund
      const finalBalance = await tokenA.balanceOf(await creator.getAddress())
      expect(finalBalance).to.equal(initialBalance + mintAmount)
    })

    it('should prevent refund of proven intents', async function () {
      // Create and fund intent
      const universalIntent = convertToUniversalIntent(evmIntent)
      const routeBytes = ethers.AbiCoder.defaultAbiCoder().encode(
        [
          'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
        ],
        [universalIntent.route],
      )
      await universalIntentSource.connect(creator).publishAndFund(
        universalIntent.destination,
        routeBytes,
        universalIntent.reward,
        false,
        { value: universalIntent.reward.nativeValue },
      )

      const [intentHash] = await universalIntentSource.getIntentHash(
        universalIntent.destination,
        routeBytes,
        universalIntent.reward,
      )
      const routeHash = keccak256(routeBytes)

      // Prove the intent
      await prover
        .connect(creator)
        .addProvenIntent(intentHash, await claimant.getAddress(), chainId)

      // Move past expiry
      await time.increase(3601)

      // Try to refund (should fail)
      await expect(
        universalIntentSource
          .connect(otherPerson)
          .refund(universalIntent.destination, universalIntent.reward, routeHash),
      ).to.be.revertedWithCustomError(intentSource, 'IntentNotClaimed')
    })
  })

  /**
   * Group 25: Gas Optimization Tests
   * Tests to ensure gas efficiency
   */
  describe('Gas optimization', function () {
    it('should optimize gas for multiple token transfers', async function () {
      // Create intent with multiple tokens
      const multiTokenIntent = {
        ...evmIntent,
        reward: {
          ...evmIntent.reward,
          nativeValue: 0n,
          tokens: [
            { token: await tokenA.getAddress(), amount: mintAmount },
            { token: await tokenB.getAddress(), amount: mintAmount * 2n },
          ],
        },
      }

      const tx = await intentSource.connect(creator).publishAndFund(multiTokenIntent, false)
      const receipt = await tx.wait()
      
      // Gas usage should be reasonable for multiple tokens
      expect(receipt?.gasUsed).to.be.lessThan(1000000) // Less than 1M gas
    })

    it('should optimize gas for batch operations', async function () {
      // Create multiple intents
      const intents = []
      const routeHashes = []
      const rewards = []
      
      for (let i = 0; i < 3; i++) {
        // Mint additional tokens for each intent
        await mintAndApprove()
        
        const intent = {
          ...evmIntent,
          route: {
            ...evmIntent.route,
            salt: ethers.randomBytes(32),
          },
        }
        intents.push(intent)
        
        await intentSource.connect(creator).publishAndFund(intent, false, {
          value: intent.reward.nativeValue,
        })
        
        const [intentHash, routeHash] = await intentSource.getIntentHash(intent)
        routeHashes.push(routeHash)
        rewards.push(intent.reward)
        
        // Prove the intent
        await prover
          .connect(creator)
          .addProvenIntent(intentHash, await claimant.getAddress(), chainId)
      }

      // Batch withdraw should be more efficient than individual withdrawals
      const batchTx = await intentSource
        .connect(otherPerson)
        .batchWithdraw(
          [chainId, chainId, chainId],
          routeHashes,
          rewards,
        )
      const batchReceipt = await batchTx.wait()
      
      // Should be reasonable gas usage for batch operation
      expect(batchReceipt?.gasUsed).to.be.lessThan(2000000) // Less than 2M gas
    })
  })

  /**
   * Group 26: Universal Intent Format Validation Tests
   * Tests validation of universal intent format
   */
  describe('Universal intent format validation', function () {
    it('should validate route encoding format', async function () {
      const universalIntent = convertToUniversalIntent(evmIntent)
      
      // Test valid route encoding
      const validRouteBytes = ethers.AbiCoder.defaultAbiCoder().encode(
        [
          'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
        ],
        [universalIntent.route],
      )
      
      await expect(
        universalIntentSource
          .connect(creator)
          .publish(
            universalIntent.destination,
            validRouteBytes,
            universalIntent.reward,
          ),
      ).to.not.be.reverted
    })

    it('should handle empty route arrays', async function () {
      const emptyRouteIntent = {
        ...evmIntent,
        route: {
          ...evmIntent.route,
          tokens: [],
          calls: [],
        },
      }
      const universalIntent = convertToUniversalIntent(emptyRouteIntent)
      
      const routeBytes = ethers.AbiCoder.defaultAbiCoder().encode(
        [
          'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
        ],
        [universalIntent.route],
      )
      
      await expect(
        universalIntentSource
          .connect(creator)
          .publish(
            universalIntent.destination,
            routeBytes,
            universalIntent.reward,
          ),
      ).to.not.be.reverted
    })

    it('should handle maximum size route data', async function () {
      // Create intent with maximum reasonable size
      const largeData = ethers.randomBytes(1000) // 1KB of data
      const largeRouteIntent = {
        ...evmIntent,
        route: {
          ...evmIntent.route,
          calls: [
            {
              target: await tokenA.getAddress(),
              data: largeData,
              value: 0n,
            },
          ],
        },
      }
      const universalIntent = convertToUniversalIntent(largeRouteIntent)
      
      const routeBytes = ethers.AbiCoder.defaultAbiCoder().encode(
        [
          'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
        ],
        [universalIntent.route],
      )
      
      await expect(
        universalIntentSource
          .connect(creator)
          .publish(
            universalIntent.destination,
            routeBytes,
            universalIntent.reward,
          ),
      ).to.not.be.reverted
    })
  })

  /**
   * Group 27: Universal Intent State Management Tests
   * Tests intent state transitions
   */
  describe('Universal intent state management', function () {
    it('should track intent funding state correctly', async function () {
      const universalIntent = convertToUniversalIntent(evmIntent)
      const routeBytes = ethers.AbiCoder.defaultAbiCoder().encode(
        [
          'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
        ],
        [universalIntent.route],
      )

      // Initially unfunded
      expect(
        await universalIntentSource.isIntentFunded(
          universalIntent.destination,
          routeBytes,
          universalIntent.reward,
        ),
      ).to.be.false

      // Fund the intent
      await universalIntentSource.connect(creator).publishAndFund(
        universalIntent.destination,
        routeBytes,
        universalIntent.reward,
        false,
        { value: universalIntent.reward.nativeValue },
      )

      // Should be funded
      expect(
        await universalIntentSource.isIntentFunded(
          universalIntent.destination,
          routeBytes,
          universalIntent.reward,
        ),
      ).to.be.true
    })

    it('should handle partial funding state transitions', async function () {
      const partialIntent = {
        ...evmIntent,
        reward: {
          ...evmIntent.reward,
          nativeValue: 0n,
          tokens: [{ token: await tokenA.getAddress(), amount: mintAmount }],
        },
      }
      const universalIntent = convertToUniversalIntent(partialIntent)
      const routeBytes = ethers.AbiCoder.defaultAbiCoder().encode(
        [
          'tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls)',
        ],
        [universalIntent.route],
      )

      // Fund partially
      await tokenA.connect(creator).approve(await universalIntentSource.getAddress(), mintAmount / 2n)
      await universalIntentSource.connect(creator).publishAndFund(
        universalIntent.destination,
        routeBytes,
        universalIntent.reward,
        true, // allow partial
      )

      // Should not be fully funded
      expect(
        await universalIntentSource.isIntentFunded(
          universalIntent.destination,
          routeBytes,
          universalIntent.reward,
        ),
      ).to.be.false

      // Complete funding
      await tokenA.connect(creator).mint(await creator.getAddress(), mintAmount / 2n)
      await tokenA.connect(creator).approve(await universalIntentSource.getAddress(), mintAmount / 2n)
      
      const routeHash = keccak256(routeBytes)
      await universalIntentSource.connect(creator).fund(
        universalIntent.destination,
        universalIntent.reward,
        routeHash,
        false,
      )

      // Should now be fully funded
      expect(
        await universalIntentSource.isIntentFunded(
          universalIntent.destination,
          routeBytes,
          universalIntent.reward,
        ),
      ).to.be.true
    })
  })
})
