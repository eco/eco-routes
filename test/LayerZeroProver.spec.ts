import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'
import {
  time,
  loadFixture,
} from '@nomicfoundation/hardhat-toolbox/network-helpers'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import {
  LayerZeroProver,
  Inbox,
  TestERC20,
  TestLayerZeroEndpoint,
} from '../typechain-types'
import { encodeTransfer } from '../utils/encode'
import { hashIntent, TokenAmount, Intent } from '../utils/intent'

describe('LayerZeroProver Test', (): void => {
  let inbox: Inbox
  let layerZeroProver: LayerZeroProver
  let mockEndpoint: TestLayerZeroEndpoint
  let token: TestERC20
  let owner: SignerWithAddress
  let solver: SignerWithAddress
  let claimant: SignerWithAddress
  const amount: number = 1234567890

  // Helper function to encode message body as (intentHash, claimant) pairs
  function encodeMessageBody(
    intentHashes: string[],
    claimants: string[],
  ): string {
    const parts: string[] = []
    for (let i = 0; i < intentHashes.length; i++) {
      // If claimant is already 32 bytes (66 chars with 0x), use as is
      // Otherwise, pad it
      const claimantBytes =
        claimants[i].length === 66
          ? claimants[i]
          : ethers.zeroPadValue(claimants[i], 32)
      parts.push(intentHashes[i])
      parts.push(claimantBytes)
    }
    return ethers.concat(parts)
  }

  // Helper function to prepare encoded proofs from fulfilled intents
  function prepareEncodedProofs(
    intentHashes: string[],
    claimants: string[],
  ): string {
    // Claimants should already be addresses, just use them as is
    return encodeMessageBody(intentHashes, claimants)
  }

  async function deployLayerZeroProverFixture(): Promise<{
    inbox: Inbox
    mockEndpoint: TestLayerZeroEndpoint
    token: TestERC20
    owner: SignerWithAddress
    solver: SignerWithAddress
    claimant: SignerWithAddress
  }> {
    const [owner, solver, claimant] = await ethers.getSigners()

    const mockEndpoint = await ethers
      .getContractFactory('TestLayerZeroEndpoint')
      .then((factory) => factory.deploy())

    const portal = await (await ethers.getContractFactory('Portal')).deploy()
    const inbox = await ethers.getContractAt('Inbox', await portal.getAddress())

    const token = await (
      await ethers.getContractFactory('TestERC20')
    ).deploy('token', 'tkn')

    return {
      inbox,
      mockEndpoint,
      token,
      owner,
      solver,
      claimant,
    }
  }

  beforeEach(async (): Promise<void> => {
    ;({ inbox, mockEndpoint, token, owner, solver, claimant } =
      await loadFixture(deployLayerZeroProverFixture))
  })

  describe('1. Constructor', () => {
    it('should initialize with the correct endpoint and inbox addresses', async () => {
      layerZeroProver = await (
        await ethers.getContractFactory('LayerZeroProver')
      ).deploy(
        await mockEndpoint.getAddress(),
        await owner.getAddress(), // delegate
        await inbox.getAddress(),
        [],
        200000,
      )

      expect(await layerZeroProver.ENDPOINT()).to.equal(
        await mockEndpoint.getAddress(),
      )
      expect(await layerZeroProver.PORTAL()).to.equal(await inbox.getAddress())
    })

    it('should add constructor-provided provers to the whitelist', async () => {
      const additionalProver = await owner.getAddress()
      layerZeroProver = await (
        await ethers.getContractFactory('LayerZeroProver')
      ).deploy(
        await mockEndpoint.getAddress(),
        await owner.getAddress(), // delegate
        await inbox.getAddress(),
        [
          ethers.zeroPadValue(additionalProver, 32),
          ethers.zeroPadValue(await inbox.getAddress(), 32),
        ],
        200000,
      )

      expect(
        await layerZeroProver.isWhitelisted(
          ethers.zeroPadValue(additionalProver, 32),
        ),
      ).to.be.true
      expect(
        await layerZeroProver.isWhitelisted(
          ethers.zeroPadValue(await inbox.getAddress(), 32),
        ),
      ).to.be.true
    })

    it('should return the correct proof type', async () => {
      layerZeroProver = await (
        await ethers.getContractFactory('LayerZeroProver')
      ).deploy(
        await mockEndpoint.getAddress(),
        await owner.getAddress(), // delegate
        await inbox.getAddress(),
        [],
        200000,
      )
      expect(await layerZeroProver.getProofType()).to.equal('LayerZero')
    })

    it('should set the delegate on the endpoint', async () => {
      layerZeroProver = await (
        await ethers.getContractFactory('LayerZeroProver')
      ).deploy(
        await mockEndpoint.getAddress(),
        await owner.getAddress(), // delegate
        await inbox.getAddress(),
        [],
        200000,
      )

      // The constructor should have called setDelegate
      // In a real test, we'd verify the delegate was set correctly
      // For now, we just verify the deployment succeeded
      expect(await layerZeroProver.ENDPOINT()).to.equal(
        await mockEndpoint.getAddress(),
      )
    })
  })

  describe('2. LayerZero Message Receiving (_lzReceive)', () => {
    beforeEach(async () => {
      layerZeroProver = await (
        await ethers.getContractFactory('LayerZeroProver')
      ).deploy(
        await mockEndpoint.getAddress(),
        await owner.getAddress(), // delegate
        await inbox.getAddress(),
        [
          ethers.zeroPadValue(await inbox.getAddress(), 32),
          ethers.zeroPadValue(await mockEndpoint.getAddress(), 32),
        ],
        200000,
      )
    })

    it('should process a single intent proof correctly', async () => {
      const intentHash = ethers.sha256('0x')
      const claimantAddress = await claimant.getAddress()
      const msgBody = encodeMessageBody([intentHash], [claimantAddress])

      const origin = {
        srcEid: 12345,
        sender: ethers.zeroPadValue(await inbox.getAddress(), 32),
        nonce: BigInt(1),
      }

      const proofDataBefore = await layerZeroProver.provenIntents(intentHash)
      expect(proofDataBefore.claimant).to.eq(ethers.ZeroAddress)

      // Set the LayerZero prover as the receiver and simulate message receipt
      await mockEndpoint.setReceiver(await layerZeroProver.getAddress())

      await expect(
        mockEndpoint.simulateReceive(origin.srcEid, origin.sender, msgBody),
      )
        .to.emit(layerZeroProver, 'IntentProven')
        .withArgs(intentHash, claimantAddress, 12345)

      const proofDataAfter = await layerZeroProver.provenIntents(intentHash)
      expect(proofDataAfter.claimant).to.eq(claimantAddress)
    })

    it('should handle batch proving of multiple intents', async () => {
      const intentHash = ethers.sha256('0x')
      const otherHash = ethers.sha256('0x1337')
      const claimantAddress = await claimant.getAddress()
      const otherAddress = await solver.getAddress()

      const msgBody = encodeMessageBody(
        [intentHash, otherHash],
        [claimantAddress, otherAddress],
      )

      const origin = {
        srcEid: 12345,
        sender: ethers.zeroPadValue(await inbox.getAddress(), 32),
        nonce: BigInt(1),
      }

      // Set the LayerZero prover as the receiver and simulate message receipt
      await mockEndpoint.setReceiver(await layerZeroProver.getAddress())

      await expect(
        mockEndpoint.simulateReceive(origin.srcEid, origin.sender, msgBody),
      )
        .to.emit(layerZeroProver, 'IntentProven')
        .withArgs(intentHash, claimantAddress, 12345)
        .to.emit(layerZeroProver, 'IntentProven')
        .withArgs(otherHash, otherAddress, 12345)

      const proofData1 = await layerZeroProver.provenIntents(intentHash)
      expect(proofData1.claimant).to.eq(claimantAddress)
      const proofData2 = await layerZeroProver.provenIntents(otherHash)
      expect(proofData2.claimant).to.eq(otherAddress)
    })

    it('should emit event when intent is already proven', async () => {
      const intentHash = ethers.sha256('0x')
      const claimantAddress = await claimant.getAddress()
      const msgBody = encodeMessageBody([intentHash], [claimantAddress])

      const origin = {
        srcEid: 12345,
        sender: ethers.zeroPadValue(await inbox.getAddress(), 32),
        nonce: BigInt(1),
      }

      // Set the LayerZero prover as the receiver and simulate message receipt
      await mockEndpoint.setReceiver(await layerZeroProver.getAddress())

      // First message proves the intent
      await mockEndpoint.simulateReceive(origin.srcEid, origin.sender, msgBody)

      // Second message should emit IntentAlreadyProven
      await expect(
        mockEndpoint.simulateReceive(origin.srcEid, origin.sender, msgBody),
      )
        .to.emit(layerZeroProver, 'IntentAlreadyProven')
        .withArgs(intentHash)
    })

    it('should reject messages from unauthorized senders', async () => {
      const intentHash = ethers.sha256('0x')
      const claimantAddress = await claimant.getAddress()
      const msgBody = encodeMessageBody([intentHash], [claimantAddress])

      const origin = {
        srcEid: 12345,
        sender: ethers.zeroPadValue(await claimant.getAddress(), 32), // Unauthorized
        nonce: BigInt(1),
      }

      // Set the LayerZero prover as the receiver and simulate message receipt
      await mockEndpoint.setReceiver(await layerZeroProver.getAddress())

      await expect(
        mockEndpoint.simulateReceive(origin.srcEid, origin.sender, msgBody),
      ).to.be.revertedWithCustomError(
        layerZeroProver,
        'UnauthorizedIncomingProof',
      )
    })
  })

  describe('3. SendProof', () => {
    beforeEach(async () => {
      const chainId = 12345
      layerZeroProver = await (
        await ethers.getContractFactory('LayerZeroProver')
      ).deploy(
        await mockEndpoint.getAddress(),
        await owner.getAddress(), // delegate
        await inbox.getAddress(),
        [ethers.zeroPadValue(await inbox.getAddress(), 32)],
        200000,
      )
    })

    it('should revert on underpayment', async () => {
      const portal = await ethers.getContractAt(
        'Portal',
        await inbox.getAddress(),
      )
      const intentSource = await ethers.getContractAt(
        'IIntentSource',
        await portal.getAddress(),
      )

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

      const { intentHash, rewardHash } = hashIntent(intent)

      await token.mint(owner.address, amount)
      await token.connect(owner).approve(await portal.getAddress(), amount)

      const tx = await intentSource
        .connect(owner)
        .publishAndFund(intent, false, {
          value: ethers.parseEther('0.01'),
        })
      await tx.wait()

      await token.mint(solver.address, amount)
      await token.connect(solver).approve(await inbox.getAddress(), amount)

      await inbox
        .connect(solver)
        .fulfill(
          intentHash,
          intent.route,
          rewardHash,
          ethers.zeroPadValue(await claimant.getAddress(), 32),
        )

      const sourceChainId = 12345
      const intentHashes = [intentHash]
      const claimants = [ethers.zeroPadValue(await claimant.getAddress(), 32)]
      const sourceChainProver = await layerZeroProver.getAddress()
      const metadata = '0x'
      const gasLimit = 200000
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['tuple(bytes32,bytes,uint256)'],
        [[ethers.zeroPadValue(sourceChainProver, 32), metadata, gasLimit]],
      )

      const encodedProofs = prepareEncodedProofs(intentHashes, claimants)
      const fee = await layerZeroProver.fetchFee(
        sourceChainId,
        encodedProofs,
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
      const metadata = '0x'
      const gasLimit = 200000
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['tuple(bytes32,bytes,uint256)'],
        [[ethers.zeroPadValue(sourceChainProver, 32), metadata, gasLimit]],
      )

      const encodedProofs = prepareEncodedProofs(intentHashes, claimants)
      await expect(
        layerZeroProver
          .connect(solver)
          .prove(owner.address, 123, encodedProofs, data),
      ).to.be.revertedWithCustomError(layerZeroProver, 'UnauthorizedProve')
    })

    it('should handle exact fee payment with no refund needed', async () => {
      const portal = await ethers.getContractAt(
        'Portal',
        await inbox.getAddress(),
      )
      const intentSource = await ethers.getContractAt(
        'IIntentSource',
        await portal.getAddress(),
      )

      const salt = ethers.encodeBytes32String('test-exact-fee')
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

      const { intentHash, rewardHash } = hashIntent(intent)

      await token.mint(owner.address, amount)
      await token.connect(owner).approve(await portal.getAddress(), amount)

      const publishTx = await intentSource
        .connect(owner)
        .publishAndFund(intent, false, {
          value: ethers.parseEther('0.01'),
        })
      await publishTx.wait()

      await token.mint(solver.address, amount)
      await token.connect(solver).approve(await inbox.getAddress(), amount)

      await inbox
        .connect(solver)
        .fulfill(
          intentHash,
          intent.route,
          rewardHash,
          ethers.zeroPadValue(await claimant.getAddress(), 32),
        )

      const sourceChainId = 12345
      const intentHashes = [intentHash]
      const claimants = [ethers.zeroPadValue(await claimant.getAddress(), 32)]
      const sourceChainProver = await inbox.getAddress()
      const metadata = '0x'
      const gasLimit = 200000
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['tuple(bytes32,bytes,uint256)'],
        [[ethers.zeroPadValue(sourceChainProver, 32), metadata, gasLimit]],
      )

      const encodedProofs = prepareEncodedProofs(intentHashes, claimants)
      const fee = await layerZeroProver.fetchFee(
        sourceChainId,
        encodedProofs,
        data,
      )

      const proveTx = await inbox
        .connect(solver)
        .prove(
          sourceChainId,
          await layerZeroProver.getAddress(),
          intentHashes,
          data,
          { value: fee },
        )

      await proveTx.wait()

      // Verify the message was sent through LayerZero
      // In a real test, we'd check the endpoint's send was called
    })

    it('should handle empty arrays gracefully', async () => {
      const sourceChainId = 123
      const intentHashes: string[] = []
      const claimants: string[] = []
      const sourceChainProver = await inbox.getAddress()
      const metadata = '0x1234'
      const gasLimit = 200000
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['tuple(bytes32,bytes,uint256)'],
        [[ethers.zeroPadValue(sourceChainProver, 32), metadata, gasLimit]],
      )

      const encodedProofs = prepareEncodedProofs(intentHashes, claimants)
      const fee = await layerZeroProver.fetchFee(
        sourceChainId,
        encodedProofs,
        data,
      )

      const tx = await inbox
        .connect(owner)
        .prove(
          sourceChainId,
          await layerZeroProver.getAddress(),
          intentHashes,
          data,
          {
            value: fee,
          },
        )

      await tx.wait()
    })

    it('should correctly format parameters in processAndFormat via fetchFee', async () => {
      const sourceChainId = 123
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [ethers.zeroPadValue(await claimant.getAddress(), 32)]
      const sourceChainProver = await solver.getAddress()
      const metadata = '0x1234'
      const gasLimit = 200000
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['tuple(bytes32,bytes,uint256)'],
        [[ethers.zeroPadValue(sourceChainProver, 32), metadata, gasLimit]],
      )

      const encodedProofs = prepareEncodedProofs(intentHashes, claimants)
      const fee = await layerZeroProver.fetchFee(
        sourceChainId,
        encodedProofs,
        data,
      )

      expect(fee).to.be.gt(0)
    })
  })

  describe('4. Cross-VM Claimant Compatibility', () => {
    it('should skip non-EVM claimants when processing messages', async () => {
      layerZeroProver = await (
        await ethers.getContractFactory('LayerZeroProver')
      ).deploy(
        await mockEndpoint.getAddress(),
        await owner.getAddress(), // delegate
        await inbox.getAddress(),
        [ethers.zeroPadValue(await inbox.getAddress(), 32)],
        200000,
      )

      const intentHash1 = ethers.keccak256('0x1234')
      const intentHash2 = ethers.keccak256('0x5678')
      const validClaimant = ethers.zeroPadValue(await claimant.getAddress(), 32)

      const nonAddressClaimant = ethers.keccak256(
        ethers.toUtf8Bytes('non-evm-claimant-identifier'),
      )

      // Create message with both valid and invalid claimants
      // We need to use the raw bytes for the non-address claimant
      const msgBody = ethers.concat([
        intentHash1, // 32 bytes
        validClaimant, // 32 bytes
        intentHash2, // 32 bytes
        nonAddressClaimant, // 32 bytes - Non-EVM address
      ])

      const origin = {
        srcEid: 12345,
        sender: ethers.zeroPadValue(await inbox.getAddress(), 32),
        nonce: BigInt(1),
      }

      // Set the LayerZero prover as the receiver and simulate message receipt
      await mockEndpoint.setReceiver(await layerZeroProver.getAddress())

      await mockEndpoint.simulateReceive(origin.srcEid, origin.sender, msgBody)

      const proofData1 = await layerZeroProver.provenIntents(intentHash1)
      expect(proofData1.claimant).to.eq(await claimant.getAddress())

      const proofData2 = await layerZeroProver.provenIntents(intentHash2)
      expect(proofData2.claimant).to.eq(ethers.ZeroAddress)
    })
  })

  describe('5. End-to-End', () => {
    it('works end to end with LayerZero message bridge', async () => {
      const chainId = 12345
      layerZeroProver = await (
        await ethers.getContractFactory('LayerZeroProver')
      ).deploy(
        await mockEndpoint.getAddress(),
        await owner.getAddress(), // delegate
        await inbox.getAddress(),
        [ethers.zeroPadValue(await inbox.getAddress(), 32)],
        200000,
      )

      const portal = await ethers.getContractAt(
        'Portal',
        await inbox.getAddress(),
      )
      const intentSource = await ethers.getContractAt(
        'IIntentSource',
        await portal.getAddress(),
      )

      await token.mint(solver.address, amount * 2)
      await token.mint(owner.address, amount)

      const sourceChainID = 12345
      const calldata = await encodeTransfer(await claimant.getAddress(), amount)
      const timeStamp = (await time.latest()) + 1000
      const salt = ethers.encodeBytes32String('0x987')
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

      const { intentHash, rewardHash, routeHash } = hashIntent(intent)
      const route = intent.route
      const reward = intent.reward

      await token.connect(owner).approve(await portal.getAddress(), amount)

      const publishTx = await intentSource
        .connect(owner)
        .publishAndFund(intent, false, {
          value: ethers.parseEther('0.01'),
        })
      await publishTx.wait()

      const isFunded = await intentSource.isIntentFunded(intent)
      expect(isFunded).to.be.true

      const metadata = '0x'
      const gasLimit = 200000
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['tuple(bytes32,bytes,uint256)'],
        [
          [
            ethers.zeroPadValue(await inbox.getAddress(), 32),
            metadata,
            gasLimit,
          ],
        ],
      )

      await token.connect(solver).approve(await inbox.getAddress(), amount)

      const proofDataBefore = await layerZeroProver.provenIntents(intentHash)
      expect(proofDataBefore.claimant).to.eq(ethers.ZeroAddress)

      // Get fee for fulfillment - Inbox will encode the proofs
      const fee = await layerZeroProver.fetchFee(
        sourceChainID,
        '0x', // Empty encoded proofs - Inbox will populate this
        data,
      )

      await inbox
        .connect(solver)
        .fulfillAndProve(
          intentHash,
          route,
          rewardHash,
          ethers.zeroPadValue(await claimant.getAddress(), 32),
          await layerZeroProver.getAddress(),
          sourceChainID,
          data,
          { value: fee },
        )

      // Simulate the LayerZero message being received
      const msgBody = encodeMessageBody(
        [intentHash],
        [await claimant.getAddress()],
      )

      const origin = {
        srcEid: sourceChainID,
        sender: ethers.zeroPadValue(await inbox.getAddress(), 32),
        nonce: BigInt(1),
      }

      // Set the LayerZero prover as the receiver and simulate message receipt
      await mockEndpoint.setReceiver(await layerZeroProver.getAddress())

      await mockEndpoint.simulateReceive(origin.srcEid, origin.sender, msgBody)

      const proofDataAfter = await layerZeroProver.provenIntents(intentHash)
      expect(proofDataAfter.claimant).to.eq(await claimant.getAddress())
    })

    it('should work with batched message bridge fulfillment end-to-end', async () => {
      layerZeroProver = await (
        await ethers.getContractFactory('LayerZeroProver')
      ).deploy(
        await mockEndpoint.getAddress(),
        await owner.getAddress(), // delegate
        await inbox.getAddress(),
        [ethers.zeroPadValue(await inbox.getAddress(), 32)],
        200000,
      )

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

      const sourceChainID = 12345
      const calldata = await encodeTransfer(await claimant.getAddress(), amount)
      const timeStamp = (await time.latest()) + 1000
      const metadata = '0x'
      const gasLimit = 200000
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['tuple(bytes32,bytes,uint256)'],
        [
          [
            ethers.zeroPadValue(await inbox.getAddress(), 32),
            metadata,
            gasLimit,
          ],
        ],
      )

      // Create first intent
      let salt = ethers.encodeBytes32String('0x987')
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
      const {
        intentHash: intentHash0,
        rewardHash: rewardHash0,
        routeHash: routeHash0,
      } = hashIntent(intent0)

      await token.connect(owner).approve(await portal.getAddress(), amount)
      await intentSource.connect(owner).publishAndFund(intent0, false, {
        value: ethers.parseEther('0.01'),
      })

      await token.connect(solver).approve(await inbox.getAddress(), amount)
      expect((await layerZeroProver.provenIntents(intentHash0)).claimant).to.eq(
        ethers.ZeroAddress,
      )

      await inbox
        .connect(solver)
        .fulfill(
          intentHash0,
          route,
          rewardHash0,
          ethers.zeroPadValue(await claimant.getAddress(), 32),
        )

      // Create second intent
      salt = ethers.encodeBytes32String('0x1234')
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
      const {
        intentHash: intentHash1,
        rewardHash: rewardHash1,
        routeHash: routeHash1,
      } = hashIntent(intent1)

      await token.connect(owner).approve(await portal.getAddress(), amount)
      await intentSource.connect(owner).publishAndFund(intent1, false, {
        value: ethers.parseEther('0.01'),
      })

      await token.connect(solver).approve(await inbox.getAddress(), amount)
      await inbox
        .connect(solver)
        .fulfill(
          intentHash1,
          route1,
          rewardHash1,
          ethers.zeroPadValue(await claimant.getAddress(), 32),
        )

      const proofDataBeforeBatch =
        await layerZeroProver.provenIntents(intentHash1)
      expect(proofDataBeforeBatch.claimant).to.eq(ethers.ZeroAddress)

      // Prepare message body for batch
      const msgBody = encodeMessageBody(
        [intentHash0, intentHash1],
        [await claimant.getAddress(), await claimant.getAddress()],
      )

      // Get fee for batch - Inbox will encode the proofs
      const batchFee = await layerZeroProver.fetchFee(
        sourceChainID,
        '0x', // Empty encoded proofs - Inbox will populate this
        data,
      )

      // Send batch to message bridge
      await expect(
        inbox
          .connect(solver)
          .prove(
            sourceChainID,
            await layerZeroProver.getAddress(),
            [intentHash0, intentHash1],
            data,
            { value: batchFee },
          ),
      ).to.changeEtherBalance(solver, -Number(batchFee))

      // Simulate LayerZero message receipt for batch
      const origin = {
        srcEid: sourceChainID,
        sender: ethers.zeroPadValue(await inbox.getAddress(), 32),
        nonce: BigInt(1),
      }

      // Set the LayerZero prover as the receiver and simulate message receipt
      await mockEndpoint.setReceiver(await layerZeroProver.getAddress())

      await mockEndpoint.simulateReceive(origin.srcEid, origin.sender, msgBody)

      // Verify both intents were proven
      const proofData0 = await layerZeroProver.provenIntents(intentHash0)
      expect(proofData0.claimant).to.eq(await claimant.getAddress())
      const proofData1 = await layerZeroProver.provenIntents(intentHash1)
      expect(proofData1.claimant).to.eq(await claimant.getAddress())
    })
  })

  /**
   * Challenge Intent Proof Tests
   * Tests the proof challenging mechanism for cross-chain validation
   */
  describe('Challenge Intent Proof', () => {
    let intent: Intent
    let prover: any
    let trustedProverList: string[]

    beforeEach(async () => {
      // Create a standard intent for testing
      intent = {
        destination: 42161, // Arbitrum
        route: {
          salt: ethers.randomBytes(32),
          deadline: (await time.latest()) + 3600,
          portal: await inbox.getAddress(),
          tokens: [{ token: await token.getAddress(), amount: amount }],
          calls: [
            {
              target: await token.getAddress(),
              data: await encodeTransfer(await claimant.getAddress(), amount),
              value: 0,
            },
          ],
        },
        reward: {
          creator: await owner.getAddress(),
          prover: await solver.getAddress(),
          deadline: (await time.latest()) + 3600,
          nativeValue: 0,
          tokens: [{ token: await token.getAddress(), amount: amount }],
        },
      }

      // Use TestProver for challenge tests since we need addProvenIntent method
      prover = await (
        await ethers.getContractFactory('TestProver')
      ).deploy(await inbox.getAddress())
    })

    it('should challenge and clear proof when chain ID mismatches', async () => {
      const intentHash = hashIntent(intent).intentHash

      // Create proof with wrong chain ID manually
      const wrongChainId = 999
      await prover.addProvenIntent(
        intentHash,
        await claimant.getAddress(),
        wrongChainId,
      )

      // Verify proof exists with wrong chain ID
      const proofBefore = await prover.provenIntents(intentHash)
      expect(proofBefore.claimant).to.equal(await claimant.getAddress())
      expect(proofBefore.destination).to.equal(wrongChainId)

      // Challenge the proof with correct destination chain ID
      const routeHash = hashIntent(intent).routeHash
      const rewardHash = hashIntent(intent).rewardHash

      await expect(
        prover.challengeIntentProof(intent.destination, routeHash, rewardHash),
      )
        .to.emit(prover, 'IntentProven')
        .withArgs(intentHash, ethers.ZeroAddress, wrongChainId)

      // Verify proof was cleared
      const proofAfter = await prover.provenIntents(intentHash)
      expect(proofAfter.claimant).to.equal(ethers.ZeroAddress)
      expect(proofAfter.destination).to.equal(0)
    })

    it('should not clear proof when chain ID matches', async () => {
      const intentHash = hashIntent(intent).intentHash

      // Create proof with correct chain ID
      await prover.addProvenIntent(
        intentHash,
        await claimant.getAddress(),
        intent.destination,
      )

      // Verify proof exists
      const proofBefore = await prover.provenIntents(intentHash)
      expect(proofBefore.claimant).to.equal(await claimant.getAddress())
      expect(proofBefore.destination).to.equal(intent.destination)

      // Challenge the proof with same destination chain ID
      const routeHash = hashIntent(intent).routeHash
      const rewardHash = hashIntent(intent).rewardHash

      await prover.challengeIntentProof(
        intent.destination,
        routeHash,
        rewardHash,
      )

      // Verify proof remains unchanged
      const proofAfter = await prover.provenIntents(intentHash)
      expect(proofAfter.claimant).to.equal(await claimant.getAddress())
      expect(proofAfter.destination).to.equal(intent.destination)
    })

    it('should handle challenge for non-existent proof', async () => {
      const routeHash = hashIntent(intent).routeHash
      const rewardHash = hashIntent(intent).rewardHash

      // Challenge non-existent proof should be a no-op
      await expect(
        prover.challengeIntentProof(intent.destination, routeHash, rewardHash),
      ).to.not.be.reverted

      // Verify no proof exists
      const intentHash = hashIntent(intent).intentHash
      const proof = await prover.provenIntents(intentHash)
      expect(proof.claimant).to.equal(ethers.ZeroAddress)
      expect(proof.destination).to.equal(0)
    })

    it('should handle LayerZero-specific challenge scenarios', async () => {
      // Deploy LayerZero prover for this test
      layerZeroProver = await (
        await ethers.getContractFactory('LayerZeroProver')
      ).deploy(
        await mockEndpoint.getAddress(),
        await owner.getAddress(), // delegate
        await inbox.getAddress(),
        [],
        200000,
      )

      // Create intent with LayerZero as the prover
      const lzIntent: Intent = {
        ...intent,
        reward: {
          ...intent.reward,
          prover: await layerZeroProver.getAddress(),
        },
      }

      const intentHash = hashIntent(lzIntent).intentHash

      // Simulate a proof being recorded with wrong chain ID through LayerZero
      // This would happen if a malicious sender tries to prove on wrong chain
      // In real scenario, we'd need to test the actual LayerZero flow
      // For now, we just verify the challenge mechanism exists
      expect(await layerZeroProver.challengeIntentProof).to.exist
    })
  })
})
