import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'
import {
  time,
  loadFixture,
} from '@nomicfoundation/hardhat-toolbox/network-helpers'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import { LayerZeroProver, Inbox, Portal, TestERC20 } from '../typechain-types'
import { encodeTransfer } from '../utils/encode'
import { hashIntent, TokenAmount, Intent, Route } from '../utils/intent'
import { addressToBytes32, TypeCasts } from '../utils/typeCasts'
import {
  convertIntentToUniversal,
  hashUniversalIntent,
  UniversalRoute,
} from '../utils/universalIntent'

describe('LayerZeroProver Test', (): void => {
  let inbox: Inbox
  let layerZeroProver: LayerZeroProver
  let mockEndpoint: MockLayerZeroEndpoint
  let token: TestERC20
  let owner: SignerWithAddress
  let solver: SignerWithAddress
  let claimant: SignerWithAddress
  const amount: number = 1234567890
  const abiCoder = ethers.AbiCoder.defaultAbiCoder()

  // Mock LayerZero Endpoint contract reference
  let MockLayerZeroEndpoint: any
  let TestLayerZeroEndpoint: any

  // Helper function to convert UniversalRoute to Route for the fulfill function
  function universalRouteToRoute(universalRoute: UniversalRoute): Route {
    return {
      salt: universalRoute.salt,
      deadline: universalRoute.deadline,
      portal: TypeCasts.bytes32ToAddress(universalRoute.portal),
      tokens: universalRoute.tokens.map((token) => ({
        token: TypeCasts.bytes32ToAddress(token.token),
        amount: token.amount,
      })),
      calls: universalRoute.calls.map((call) => ({
        target: TypeCasts.bytes32ToAddress(call.target),
        data: call.data,
        value: call.value,
      })),
    }
  }

  async function deployLayerZeroProverFixture(): Promise<{
    inbox: Inbox
    layerZeroProver: LayerZeroProver
    mockEndpoint: any
    token: TestERC20
    owner: SignerWithAddress
    solver: SignerWithAddress
    claimant: SignerWithAddress
  }> {
    const [owner, solver, claimant] = await ethers.getSigners()

    // Deploy mock LayerZero endpoint
    MockLayerZeroEndpoint = await ethers.getContractFactory(
      'MockLayerZeroEndpoint',
    )
    const mockEndpoint = await MockLayerZeroEndpoint.deploy()

    // Deploy Portal (which includes Inbox)
    const portal = await (await ethers.getContractFactory('Portal')).deploy()
    const inbox = await ethers.getContractAt('Inbox', await portal.getAddress())

    // Deploy Test ERC20 token
    const token = await (
      await ethers.getContractFactory('TestERC20')
    ).deploy('token', 'tkn')

    // Deploy LayerZeroProver
    const layerZeroProver = await (
      await ethers.getContractFactory('LayerZeroProver')
    ).deploy(
      await mockEndpoint.getAddress(),
      await inbox.getAddress(),
      [],
      200000,
    )

    return {
      inbox,
      layerZeroProver,
      mockEndpoint,
      token,
      owner,
      solver,
      claimant,
    }
  }

  beforeEach(async (): Promise<void> => {
    ;({ inbox, layerZeroProver, mockEndpoint, token, owner, solver, claimant } =
      await loadFixture(deployLayerZeroProverFixture))
  })

  describe('1. Constructor', () => {
    it('should initialize with the correct endpoint and inbox addresses', async () => {
      expect(await layerZeroProver.ENDPOINT()).to.equal(
        await mockEndpoint.getAddress(),
      )
      expect(await layerZeroProver.PORTAL()).to.equal(await inbox.getAddress())
    })

    it('should add constructor-provided provers to the whitelist', async () => {
      const additionalProver = await owner.getAddress()
      const newLayerZeroProver = await (
        await ethers.getContractFactory('LayerZeroProver')
      ).deploy(
        await mockEndpoint.getAddress(),
        await inbox.getAddress(),
        [
          ethers.zeroPadValue(additionalProver, 32),
          ethers.zeroPadValue(await inbox.getAddress(), 32),
        ],
        200000,
      )

      // Check if the prover address is in the whitelist
      expect(
        await newLayerZeroProver.isWhitelisted(
          ethers.zeroPadValue(additionalProver, 32),
        ),
      ).to.be.true
      expect(
        await newLayerZeroProver.isWhitelisted(
          ethers.zeroPadValue(await inbox.getAddress(), 32),
        ),
      ).to.be.true
    })

    it('should revert when endpoint address is zero', async () => {
      await expect(
        (await ethers.getContractFactory('LayerZeroProver')).deploy(
          ethers.ZeroAddress,
          await inbox.getAddress(),
          [],
          200000,
        ),
      ).to.be.revertedWithCustomError(
        layerZeroProver,
        'EndpointCannotBeZeroAddress',
      )
    })

    it('should return the correct proof type', async () => {
      expect(await layerZeroProver.getProofType()).to.equal('LayerZero')
    })

    it('should have the correct default gas limit', async () => {
      expect(await layerZeroProver.DEFAULT_GAS_LIMIT()).to.equal(200000)

      // Deploy with custom gas limit
      const customGasLimit = 300000
      const customLayerZeroProver = await (
        await ethers.getContractFactory('LayerZeroProver')
      ).deploy(
        await mockEndpoint.getAddress(),
        await inbox.getAddress(),
        [],
        customGasLimit,
      )

      expect(await customLayerZeroProver.DEFAULT_GAS_LIMIT()).to.equal(
        customGasLimit,
      )
    })
  })

  describe('2. lzReceive (Handle)', () => {
    beforeEach(async () => {
      // Deploy with owner as endpoint for easier testing
      layerZeroProver = await (
        await ethers.getContractFactory('LayerZeroProver')
      ).deploy(
        owner.address,
        await inbox.getAddress(),
        [ethers.zeroPadValue(await inbox.getAddress(), 32)],
        200000,
      )
    })

    it('should revert when msg.sender is not the endpoint', async () => {
      const origin = {
        srcEid: 12345,
        sender: ethers.zeroPadValue(await inbox.getAddress(), 32),
        nonce: 1,
      }

      await expect(
        layerZeroProver
          .connect(claimant)
          .lzReceive(
            origin,
            ethers.sha256('0x'),
            '0x',
            ethers.ZeroAddress,
            '0x',
          ),
      ).to.be.revertedWithCustomError(layerZeroProver, 'UnauthorizedHandle')
    })

    it('should revert when executor is invalid', async () => {
      const origin = {
        srcEid: 12345,
        sender: ethers.zeroPadValue(await inbox.getAddress(), 32),
        nonce: 1,
      }

      await expect(
        layerZeroProver
          .connect(owner) // owner is the endpoint
          .lzReceive(origin, ethers.sha256('0x'), '0x', solver.address, '0x'),
      )
        .to.be.revertedWithCustomError(layerZeroProver, 'InvalidExecutor')
        .withArgs(solver.address)
    })

    it('should revert when sender is zero address', async () => {
      const origin = {
        srcEid: 12345,
        sender: ethers.ZeroHash,
        nonce: 1,
      }

      await expect(
        layerZeroProver
          .connect(owner) // owner is the endpoint
          .lzReceive(
            origin,
            ethers.sha256('0x'),
            '0x',
            ethers.ZeroAddress,
            '0x',
          ),
      ).to.be.revertedWithCustomError(
        layerZeroProver,
        'SenderCannotBeZeroAddress',
      )
    })

    it('should revert when sender field is not authorized', async () => {
      const origin = {
        srcEid: 12345,
        sender: ethers.zeroPadValue(solver.address, 32), // unauthorized sender
        nonce: 1,
      }
      const msgBody = abiCoder.encode(['bytes32[]', 'bytes32[]'], [[], []])

      await expect(
        layerZeroProver
          .connect(owner)
          .lzReceive(
            origin,
            ethers.sha256('0x'),
            msgBody,
            ethers.ZeroAddress,
            '0x',
          ),
      ).to.be.revertedWithCustomError(
        layerZeroProver,
        'UnauthorizedIncomingProof',
      )
    })

    it('should record a single proven intent when called correctly', async () => {
      const intentHash = ethers.sha256('0x')
      const claimantAddress = await claimant.getAddress()
      const msgBody = abiCoder.encode(
        ['bytes32[]', 'bytes32[]'],
        [[intentHash], [ethers.zeroPadValue(claimantAddress, 32)]],
      )

      const origin = {
        srcEid: 12345,
        sender: ethers.zeroPadValue(await inbox.getAddress(), 32),
        nonce: 1,
      }

      const proofDataBefore = await layerZeroProver.provenIntents(intentHash)
      expect(proofDataBefore.claimant).to.eq(ethers.ZeroAddress)

      await expect(
        layerZeroProver
          .connect(owner)
          .lzReceive(
            origin,
            ethers.sha256('0x'),
            msgBody,
            ethers.ZeroAddress,
            '0x',
          ),
      )
        .to.emit(layerZeroProver, 'IntentProven')
        .withArgs(intentHash, claimantAddress)

      const proofDataAfter = await layerZeroProver.provenIntents(intentHash)
      expect(proofDataAfter.claimant).to.eq(claimantAddress)
    })

    it('should emit an event when intent is already proven', async () => {
      const intentHash = ethers.sha256('0x')
      const claimantAddress = await claimant.getAddress()
      const msgBody = abiCoder.encode(
        ['bytes32[]', 'bytes32[]'],
        [[intentHash], [ethers.zeroPadValue(claimantAddress, 32)]],
      )

      const origin = {
        srcEid: 12345,
        sender: ethers.zeroPadValue(await inbox.getAddress(), 32),
        nonce: 1,
      }

      // First lzReceive call proves the intent
      await layerZeroProver
        .connect(owner)
        .lzReceive(
          origin,
          ethers.sha256('0x'),
          msgBody,
          ethers.ZeroAddress,
          '0x',
        )

      // Second lzReceive call should emit IntentAlreadyProven
      await expect(
        layerZeroProver
          .connect(owner)
          .lzReceive(
            origin,
            ethers.sha256('0x'),
            msgBody,
            ethers.ZeroAddress,
            '0x',
          ),
      )
        .to.emit(layerZeroProver, 'IntentAlreadyProven')
        .withArgs(intentHash)
    })

    it('should handle batch proving of multiple intents', async () => {
      const intentHash = ethers.sha256('0x')
      const otherHash = ethers.sha256('0x1337')
      const claimantAddress = await claimant.getAddress()
      const otherAddress = await solver.getAddress()

      const msgBody = abiCoder.encode(
        ['bytes32[]', 'bytes32[]'],
        [
          [intentHash, otherHash],
          [
            ethers.zeroPadValue(claimantAddress, 32),
            ethers.zeroPadValue(otherAddress, 32),
          ],
        ],
      )

      const origin = {
        srcEid: 12345,
        sender: ethers.zeroPadValue(await inbox.getAddress(), 32),
        nonce: 1,
      }

      await expect(
        layerZeroProver
          .connect(owner)
          .lzReceive(
            origin,
            ethers.sha256('0x'),
            msgBody,
            ethers.ZeroAddress,
            '0x',
          ),
      )
        .to.emit(layerZeroProver, 'IntentProven')
        .withArgs(intentHash, claimantAddress)
        .to.emit(layerZeroProver, 'IntentProven')
        .withArgs(otherHash, otherAddress)

      const proofData1 = await layerZeroProver.provenIntents(intentHash)
      expect(proofData1.claimant).to.eq(claimantAddress)
      const proofData2 = await layerZeroProver.provenIntents(otherHash)
      expect(proofData2.claimant).to.eq(otherAddress)
    })

    it('should accept executor as endpoint address', async () => {
      const intentHash = ethers.sha256('0x')
      const claimantAddress = await claimant.getAddress()
      const msgBody = abiCoder.encode(
        ['bytes32[]', 'bytes32[]'],
        [[intentHash], [ethers.zeroPadValue(claimantAddress, 32)]],
      )

      const origin = {
        srcEid: 12345,
        sender: ethers.zeroPadValue(await inbox.getAddress(), 32),
        nonce: 1,
      }

      // Should succeed when executor is the endpoint address
      await expect(
        layerZeroProver
          .connect(owner)
          .lzReceive(origin, ethers.sha256('0x'), msgBody, owner.address, '0x'),
      )
        .to.emit(layerZeroProver, 'IntentProven')
        .withArgs(intentHash, claimantAddress)
    })
  })

  describe('3. prove() function', () => {
    beforeEach(async () => {
      // Deploy LayerZeroProver with actual mock endpoint
      const chainId = 12345
      layerZeroProver = await (
        await ethers.getContractFactory('LayerZeroProver')
      ).deploy(
        await mockEndpoint.getAddress(),
        await inbox.getAddress(),
        [ethers.zeroPadValue(await inbox.getAddress(), 32)],
        200000,
      )
    })

    it('should revert on underpayment', async () => {
      // Create and fund an intent first
      const portal = await ethers.getContractAt(
        'Portal',
        await inbox.getAddress(),
      )
      const intentSource = await ethers.getContractAt(
        'IIntentSource',
        await portal.getAddress(),
      )

      // Create intent
      const salt = ethers.encodeBytes32String('test-underpayment')
      const deadline = (await time.latest()) + 3600
      const calldata = await encodeTransfer(await claimant.getAddress(), amount)

      const intent: Intent = {
        destination: Number(
          (await layerZeroProver.runner?.provider?.getNetwork())?.chainId,
        ),
        route: {
          salt: salt,
          deadline: deadline,
          portal: await inbox.getAddress(),
          tokens: [{ token: await token.getAddress(), amount: amount }],
          calls: [
            {
              target: await token.getAddress(),
              data: calldata,
              value: 0,
            },
          ],
        },
        reward: {
          creator: await owner.getAddress(),
          prover: await layerZeroProver.getAddress(),
          deadline: deadline,
          nativeValue: ethers.parseEther('0.01'),
          tokens: [] as TokenAmount[],
        },
      }

      // Convert to universal intent and get hashes
      const universalIntent = convertIntentToUniversal(intent)
      const { intentHash, rewardHash } = hashUniversalIntent(universalIntent)

      // Mint tokens and approve for funding
      await token.mint(owner.address, amount)
      await token.connect(owner).approve(await portal.getAddress(), amount)

      // Publish and fund the intent
      const tx = await intentSource
        .connect(owner)
        .publishAndFund(intent, false, {
          value: ethers.parseEther('0.01'),
        })
      await tx.wait()

      // Mint tokens for solver and approve for fulfillment
      await token.mint(solver.address, amount)
      await token.connect(solver).approve(await inbox.getAddress(), amount)

      // First fulfill the intent
      await inbox
        .connect(solver)
        .fulfill(
          intentHash,
          intent.route,
          rewardHash,
          ethers.zeroPadValue(await claimant.getAddress(), 32),
        )

      // Set up test data for proving
      const sourceChainId = 12345
      const intentHashes = [intentHash]
      const claimants = [ethers.zeroPadValue(await claimant.getAddress(), 32)]
      const sourceChainProver = await layerZeroProver.getAddress()
      const options = '0x' // Empty options
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes32', 'bytes'],
        [ethers.zeroPadValue(sourceChainProver, 32), options],
      )

      const fee = await layerZeroProver.fetchFee(
        sourceChainId,
        intentHashes,
        claimants,
        data,
      )

      await expect(
        inbox.connect(solver).prove(
          sourceChainId,
          await layerZeroProver.getAddress(),
          intentHashes,
          data,
          { value: fee - BigInt(1) }, // underpayment
        ),
      ).to.be.revertedWithCustomError(layerZeroProver, 'InsufficientFee')
    })

    it('should reject sendProof from unauthorized source', async () => {
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [ethers.zeroPadValue(await claimant.getAddress(), 32)]
      const sourceChainProver = await solver.getAddress()
      const options = '0x'
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes32', 'bytes'],
        [ethers.zeroPadValue(sourceChainProver, 32), options],
      )

      await expect(
        layerZeroProver
          .connect(solver)
          .prove(owner.address, 123, intentHashes, claimants, data),
      ).to.be.revertedWithCustomError(layerZeroProver, 'UnauthorizedProve')
    })

    it('should handle custom options in data parameter', async () => {
      const sourceChainId = 12345
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [ethers.zeroPadValue(await claimant.getAddress(), 32)]
      const sourceChainProver = await inbox.getAddress()

      // Create custom options with gas limit
      const customOptions = ethers.AbiCoder.defaultAbiCoder().encode(
        ['uint16', 'uint256'],
        [3, 300000], // Option type 3 for gas limit
      )

      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes32', 'bytes'],
        [ethers.zeroPadValue(sourceChainProver, 32), customOptions],
      )

      // Should not revert and should use custom options
      const fee = await layerZeroProver.fetchFee(
        sourceChainId,
        intentHashes,
        claimants,
        data,
      )

      expect(fee).to.be.gt(0)
    })

    it('should handle custom gas limit in data parameter', async () => {
      const sourceChainId = 12345
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [ethers.zeroPadValue(await claimant.getAddress(), 32)]
      const sourceChainProver = await inbox.getAddress()
      const options = '0x'
      const customGasLimit = 300000

      // Encode with gas limit as third parameter
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes32', 'bytes', 'uint256'],
        [ethers.zeroPadValue(sourceChainProver, 32), options, customGasLimit],
      )

      const fee = await layerZeroProver.fetchFee(
        sourceChainId,
        intentHashes,
        claimants,
        data,
      )

      // Fee should be calculated with custom gas limit
      expect(fee).to.be.gt(0)
    })

    it('should validate chain ID fits in uint32', async () => {
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [ethers.zeroPadValue(await claimant.getAddress(), 32)]
      const sourceChainProver = await inbox.getAddress()
      const options = '0x'
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes32', 'bytes'],
        [ethers.zeroPadValue(sourceChainProver, 32), options],
      )

      // Chain ID that exceeds uint32 max
      const invalidChainId = ethers.toBigInt('0x100000000')

      await expect(
        layerZeroProver.fetchFee(invalidChainId, intentHashes, claimants, data),
      ).to.be.revertedWithCustomError(layerZeroProver, 'ChainIdTooLarge')
    })

    it('should handle empty arrays gracefully', async () => {
      const sourceChainId = 123
      const intentHashes: string[] = []
      const claimants: string[] = []
      const sourceChainProver = await inbox.getAddress()
      const options = '0x'
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes32', 'bytes'],
        [ethers.zeroPadValue(sourceChainProver, 32), options],
      )

      const fee = await layerZeroProver.fetchFee(
        sourceChainId,
        intentHashes,
        claimants,
        data,
      )

      // Call through inbox
      const tx = await inbox
        .connect(owner)
        .prove(
          sourceChainId,
          await layerZeroProver.getAddress(),
          intentHashes,
          data,
          { value: fee },
        )

      await tx.wait()
      // Should succeed without errors
    })
  })

  describe('4. LayerZero-specific features', () => {
    it('should correctly implement allowInitializePath', async () => {
      layerZeroProver = await (
        await ethers.getContractFactory('LayerZeroProver')
      ).deploy(
        await mockEndpoint.getAddress(),
        await inbox.getAddress(),
        [ethers.zeroPadValue(await solver.getAddress(), 32)],
        200000,
      )

      const authorizedOrigin = {
        srcEid: 12345,
        sender: ethers.zeroPadValue(await solver.getAddress(), 32),
        nonce: 1,
      }

      const unauthorizedOrigin = {
        srcEid: 12345,
        sender: ethers.zeroPadValue(await claimant.getAddress(), 32),
        nonce: 1,
      }

      expect(await layerZeroProver.allowInitializePath(authorizedOrigin)).to.be
        .true
      expect(await layerZeroProver.allowInitializePath(unauthorizedOrigin)).to
        .be.false
    })

    it('should always return 0 for nextNonce', async () => {
      const srcEid = 12345
      const sender = ethers.zeroPadValue(await solver.getAddress(), 32)

      expect(await layerZeroProver.nextNonce(srcEid, sender)).to.equal(0)
    })

    it('should correctly encode options when not provided', async () => {
      const sourceChainId = 12345
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [ethers.zeroPadValue(await claimant.getAddress(), 32)]
      const sourceChainProver = await inbox.getAddress()
      const options = '0x' // Empty options
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes32', 'bytes'],
        [ethers.zeroPadValue(sourceChainProver, 32), options],
      )

      // When empty options are provided, default options should be created
      const fee = await layerZeroProver.fetchFee(
        sourceChainId,
        intentHashes,
        claimants,
        data,
      )

      expect(fee).to.be.gt(0)
    })

    it('should use endpoint ID as chain ID in lzReceive', async () => {
      layerZeroProver = await (
        await ethers.getContractFactory('LayerZeroProver')
      ).deploy(
        owner.address, // owner as endpoint
        await inbox.getAddress(),
        [ethers.zeroPadValue(await inbox.getAddress(), 32)],
        200000,
      )

      const intentHash = ethers.sha256('0x')
      const claimantAddress = await claimant.getAddress()
      const msgBody = abiCoder.encode(
        ['bytes32[]', 'bytes32[]'],
        [[intentHash], [ethers.zeroPadValue(claimantAddress, 32)]],
      )

      const endpointId = 42 // Custom endpoint ID
      const origin = {
        srcEid: endpointId,
        sender: ethers.zeroPadValue(await inbox.getAddress(), 32),
        nonce: 1,
      }

      await layerZeroProver
        .connect(owner)
        .lzReceive(
          origin,
          ethers.sha256('0x'),
          msgBody,
          ethers.ZeroAddress,
          '0x',
        )

      const proofData = await layerZeroProver.provenIntents(intentHash)
      expect(proofData.destinationChainID).to.equal(endpointId)
    })
  })

  describe('5. Cross-VM Claimant Compatibility', () => {
    it('should skip non-EVM claimants when processing LayerZero messages', async () => {
      // Deploy layerZeroProver with owner as endpoint for direct testing
      layerZeroProver = await (
        await ethers.getContractFactory('LayerZeroProver')
      ).deploy(
        await owner.getAddress(), // owner as endpoint
        await inbox.getAddress(),
        [ethers.zeroPadValue(await inbox.getAddress(), 32)],
        200000,
      )

      // Create test data
      const intentHash1 = ethers.keccak256('0x1234')
      const intentHash2 = ethers.keccak256('0x5678')
      const validClaimant = ethers.zeroPadValue(await claimant.getAddress(), 32)

      // Use a bytes32 claimant that doesn't represent a valid address
      const nonAddressClaimant = ethers.keccak256(
        ethers.toUtf8Bytes('non-evm-claimant-identifier'),
      )

      // Create message with both valid and invalid claimants
      const msgBody = abiCoder.encode(
        ['bytes32[]', 'bytes32[]'],
        [
          [intentHash1, intentHash2],
          [validClaimant, nonAddressClaimant],
        ],
      )

      const origin = {
        srcEid: 12345,
        sender: ethers.zeroPadValue(await inbox.getAddress(), 32),
        nonce: 1,
      }

      // Process the message
      await layerZeroProver
        .connect(owner) // owner acts as endpoint
        .lzReceive(
          origin,
          ethers.sha256('0x'),
          msgBody,
          ethers.ZeroAddress,
          '0x',
        )

      // The valid claimant should be processed
      const proofData1 = await layerZeroProver.provenIntents(intentHash1)
      expect(proofData1.claimant).to.eq(await claimant.getAddress())

      // The invalid claimant should be skipped (not processed)
      const proofData2 = await layerZeroProver.provenIntents(intentHash2)
      expect(proofData2.claimant).to.eq(ethers.ZeroAddress)
    })
  })

  describe('6. End-to-End Integration', () => {
    let testEndpoint: any

    beforeEach(async () => {
      // Create a more realistic mock endpoint for end-to-end tests
      TestLayerZeroEndpoint = await ethers.getContractFactory(
        'TestLayerZeroEndpoint',
      )
      testEndpoint = await TestLayerZeroEndpoint.deploy()

      // Deploy LayerZeroProver with test endpoint
      layerZeroProver = await (
        await ethers.getContractFactory('LayerZeroProver')
      ).deploy(
        await testEndpoint.getAddress(),
        await inbox.getAddress(),
        [ethers.zeroPadValue(await inbox.getAddress(), 32)],
        200000,
      )

      // Set the layerZeroProver as the receiver in the test endpoint
      await testEndpoint.setReceiver(await layerZeroProver.getAddress())
    })

    it('works end to end with LayerZero message bridge', async () => {
      // Get Portal and IntentSource interfaces
      const portal = await ethers.getContractAt(
        'Portal',
        await inbox.getAddress(),
      )
      const intentSource = await ethers.getContractAt(
        'IIntentSource',
        await portal.getAddress(),
      )

      await token.mint(solver.address, amount)
      await token.mint(owner.address, amount)

      // Set up intent data
      const sourceChainId = 12345
      const calldata = await encodeTransfer(await claimant.getAddress(), amount)
      const timeStamp = (await time.latest()) + 1000
      const salt = ethers.encodeBytes32String('test-e2e')
      const routeTokens = [{ token: await token.getAddress(), amount: amount }]

      const intent: Intent = {
        destination: Number(
          (await layerZeroProver.runner?.provider?.getNetwork())?.chainId,
        ),
        route: {
          salt: salt,
          deadline: timeStamp + 1000,
          portal: await inbox.getAddress(),
          tokens: routeTokens,
          calls: [
            {
              target: await token.getAddress(),
              data: calldata,
              value: 0,
            },
          ],
        },
        reward: {
          creator: await owner.getAddress(),
          prover: await layerZeroProver.getAddress(),
          deadline: timeStamp + 1000,
          nativeValue: ethers.parseEther('0.01'),
          tokens: [] as TokenAmount[],
        },
      }

      const universalIntent = convertIntentToUniversal(intent)
      const { intentHash, rewardHash } = hashUniversalIntent(universalIntent)

      // Approve tokens for funding
      await token.connect(owner).approve(await portal.getAddress(), amount)

      // Publish and fund the intent
      const publishTx = await intentSource
        .connect(owner)
        .publishAndFund(intent, false, {
          value: ethers.parseEther('0.01'),
        })
      await publishTx.wait()

      // Verify the intent is funded
      const isFunded = await intentSource.isIntentFunded(intent)
      expect(isFunded).to.be.true

      // Convert UniversalRoute to Route for fulfillAndProve
      const route = universalRouteToRoute(universalIntent.route)

      // Prepare message data
      const options = '0x'
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes32', 'bytes'],
        [ethers.zeroPadValue(await inbox.getAddress(), 32), options],
      )

      await token.connect(solver).approve(await inbox.getAddress(), amount)

      const proofDataBefore = await layerZeroProver.provenIntents(intentHash)
      expect(proofDataBefore.claimant).to.eq(ethers.ZeroAddress)

      // Get fee for fulfillment
      const fee = await layerZeroProver.fetchFee(
        sourceChainId,
        [intentHash],
        [ethers.zeroPadValue(await claimant.getAddress(), 32)],
        data,
      )

      // Fulfill the intent using LayerZero bridge
      await inbox
        .connect(solver)
        .fulfillAndProve(
          intentHash,
          route,
          rewardHash,
          ethers.zeroPadValue(await claimant.getAddress(), 32),
          await layerZeroProver.getAddress(),
          sourceChainId,
          data,
          { value: fee },
        )

      // Simulate the LayerZero message being received on the destination chain
      const msgBody = abiCoder.encode(
        ['bytes32[]', 'bytes32[]'],
        [[intentHash], [ethers.zeroPadValue(await claimant.getAddress(), 32)]],
      )

      // For the end-to-end test, we need to simulate the endpoint calling lzReceive
      const simulatedLayerZeroProver = await (
        await ethers.getContractFactory('LayerZeroProver')
      ).deploy(
        await owner.getAddress(), // owner simulates endpoint
        await inbox.getAddress(),
        [ethers.zeroPadValue(await inbox.getAddress(), 32)],
        200000,
      )

      const origin = {
        srcEid: sourceChainId,
        sender: ethers.zeroPadValue(await inbox.getAddress(), 32),
        nonce: 1,
      }

      // Handle the message and verify the intent is proven
      await expect(
        simulatedLayerZeroProver
          .connect(owner) // Owner simulates the endpoint
          .lzReceive(
            origin,
            ethers.sha256('0x'),
            msgBody,
            ethers.ZeroAddress,
            '0x',
          ),
      )
        .to.emit(simulatedLayerZeroProver, 'IntentProven')
        .withArgs(intentHash, await claimant.getAddress())

      const proofData = await simulatedLayerZeroProver.provenIntents(intentHash)
      expect(proofData.claimant).to.eq(await claimant.getAddress())
    })

    it('should work with batched LayerZero message fulfillment end-to-end', async () => {
      // Get Portal and IntentSource interfaces
      const portal = await ethers.getContractAt(
        'Portal',
        await inbox.getAddress(),
      )
      const intentSource = await ethers.getContractAt(
        'IIntentSource',
        await portal.getAddress(),
      )

      await token.mint(solver.address, 2 * amount)
      await token.mint(owner.address, 2 * amount)

      // Set up common data
      const sourceChainId = 12345
      const calldata = await encodeTransfer(await claimant.getAddress(), amount)
      const timeStamp = (await time.latest()) + 1000
      const options = '0x'
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes32', 'bytes'],
        [ethers.zeroPadValue(await inbox.getAddress(), 32), options],
      )

      // Create first intent
      let salt = ethers.encodeBytes32String('batch-test-1')
      const routeTokens: TokenAmount[] = [
        { token: await token.getAddress(), amount: amount },
      ]
      const route = {
        salt: salt,
        deadline: timeStamp + 1000,
        portal: await inbox.getAddress(),
        tokens: routeTokens,
        calls: [
          {
            target: await token.getAddress(),
            data: calldata,
            value: 0,
          },
        ],
      }
      const reward = {
        creator: await owner.getAddress(),
        prover: await layerZeroProver.getAddress(),
        deadline: timeStamp + 1000,
        nativeValue: ethers.parseEther('0.01'),
        tokens: [],
      }

      const destination = Number(
        (await layerZeroProver.runner?.provider?.getNetwork())?.chainId,
      )
      const intent0: Intent = {
        destination,
        route,
        reward,
      }
      const universalIntent0 = convertIntentToUniversal(intent0)
      const { intentHash: intentHash0, rewardHash: rewardHash0 } =
        hashUniversalIntent(universalIntent0)

      // Approve tokens and publish/fund first intent
      await token.connect(owner).approve(await portal.getAddress(), amount)
      await intentSource.connect(owner).publishAndFund(intent0, false, {
        value: ethers.parseEther('0.01'),
      })

      // Approve tokens and check initial state
      await token.connect(solver).approve(await inbox.getAddress(), amount)
      expect((await layerZeroProver.provenIntents(intentHash0)).claimant).to.eq(
        ethers.ZeroAddress,
      )

      // Fulfill first intent in batch
      await inbox
        .connect(solver)
        .fulfill(
          intentHash0,
          route,
          rewardHash0,
          ethers.zeroPadValue(await claimant.getAddress(), 32),
        )

      // Create second intent
      salt = ethers.encodeBytes32String('batch-test-2')
      const route1 = {
        salt: salt,
        deadline: timeStamp + 1000,
        portal: await inbox.getAddress(),
        tokens: routeTokens,
        calls: [
          {
            target: await token.getAddress(),
            data: calldata,
            value: 0,
          },
        ],
      }
      const reward1 = {
        creator: await owner.getAddress(),
        prover: await layerZeroProver.getAddress(),
        deadline: timeStamp + 1000,
        nativeValue: ethers.parseEther('0.01'),
        tokens: [],
      }
      const intent1: Intent = {
        destination,
        route: route1,
        reward: reward1,
      }
      const universalIntent1 = convertIntentToUniversal(intent1)
      const { intentHash: intentHash1, rewardHash: rewardHash1 } =
        hashUniversalIntent(universalIntent1)

      // Approve tokens and publish/fund second intent
      await token.connect(owner).approve(await portal.getAddress(), amount)
      await intentSource.connect(owner).publishAndFund(intent1, false, {
        value: ethers.parseEther('0.01'),
      })

      // Approve tokens and fulfill second intent in batch
      await token.connect(solver).approve(await inbox.getAddress(), amount)
      await inbox
        .connect(solver)
        .fulfill(
          intentHash1,
          route1,
          rewardHash1,
          ethers.zeroPadValue(await claimant.getAddress(), 32),
        )

      // Check intent hasn't been proven yet
      const proofDataBeforeBatch =
        await layerZeroProver.provenIntents(intentHash1)
      expect(proofDataBeforeBatch.claimant).to.eq(ethers.ZeroAddress)

      // Get fee for batch
      const batchFee = await layerZeroProver.fetchFee(
        sourceChainId,
        [intentHash0, intentHash1],
        [
          ethers.zeroPadValue(await claimant.getAddress(), 32),
          ethers.zeroPadValue(await claimant.getAddress(), 32),
        ],
        data,
      )

      // Send batch to LayerZero bridge
      await expect(
        inbox
          .connect(solver)
          .prove(
            sourceChainId,
            await layerZeroProver.getAddress(),
            [intentHash0, intentHash1],
            data,
            { value: batchFee },
          ),
      ).to.changeEtherBalance(solver, -Number(batchFee))

      // Simulate batch message handling
      const msgBody = abiCoder.encode(
        ['bytes32[]', 'bytes32[]'],
        [
          [intentHash0, intentHash1],
          [
            ethers.zeroPadValue(await claimant.getAddress(), 32),
            ethers.zeroPadValue(await claimant.getAddress(), 32),
          ],
        ],
      )

      // For the end-to-end test, simulate the endpoint
      const simulatedLayerZeroProver = await (
        await ethers.getContractFactory('LayerZeroProver')
      ).deploy(
        await owner.getAddress(),
        await inbox.getAddress(),
        [ethers.zeroPadValue(await inbox.getAddress(), 32)],
        200000,
      )

      const origin = {
        srcEid: sourceChainId,
        sender: ethers.zeroPadValue(await inbox.getAddress(), 32),
        nonce: 1,
      }

      // Simulate handling of the batch message
      await expect(
        simulatedLayerZeroProver
          .connect(owner) // Owner simulates the endpoint
          .lzReceive(
            origin,
            ethers.sha256('0x'),
            msgBody,
            ethers.ZeroAddress,
            '0x',
          ),
      )
        .to.emit(simulatedLayerZeroProver, 'IntentProven')
        .withArgs(intentHash0, await claimant.getAddress())
        .to.emit(simulatedLayerZeroProver, 'IntentProven')
        .withArgs(intentHash1, await claimant.getAddress())

      // Verify both intents were proven
      const proofData0Sim =
        await simulatedLayerZeroProver.provenIntents(intentHash0)
      expect(proofData0Sim.claimant).to.eq(await claimant.getAddress())
      const proofData1Sim =
        await simulatedLayerZeroProver.provenIntents(intentHash1)
      expect(proofData1Sim.claimant).to.eq(await claimant.getAddress())
    })
  })
})
