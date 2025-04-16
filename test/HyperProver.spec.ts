import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'
import {
  time,
  loadFixture,
} from '@nomicfoundation/hardhat-toolbox/network-helpers'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import { HyperProver, Inbox, TestERC20, TestMailbox } from '../typechain-types'
import { encodeTransfer } from '../utils/encode'
import { hashIntent, TokenAmount } from '../utils/intent'

describe('HyperProver Test', (): void => {
  let inbox: Inbox
  let dispatcher: TestMailbox
  let hyperProver: HyperProver
  let token: TestERC20
  let owner: SignerWithAddress
  let solver: SignerWithAddress
  let claimant: SignerWithAddress
  const amount: number = 1234567890
  const minBatcherReward = 12345
  const abiCoder = ethers.AbiCoder.defaultAbiCoder()

  async function deployHyperproverFixture(): Promise<{
    inbox: Inbox
    token: TestERC20
    owner: SignerWithAddress
    solver: SignerWithAddress
    claimant: SignerWithAddress
  }> {
    const [owner, solver, claimant] = await ethers.getSigners()
    dispatcher = await (
      await ethers.getContractFactory('TestMailbox')
    ).deploy(await owner.getAddress())

    const inbox = await (
      await ethers.getContractFactory('Inbox')
    ).deploy(owner.address, true, minBatcherReward, [])

    const token = await (
      await ethers.getContractFactory('TestERC20')
    ).deploy('token', 'tkn')

    return {
      inbox,
      token,
      owner,
      solver,
      claimant,
    }
  }

  beforeEach(async (): Promise<void> => {
    ;({ inbox, token, owner, solver, claimant } = await loadFixture(
      deployHyperproverFixture,
    ))
  })
  describe('on prover implements interface', () => {
    it('should return the correct proof type', async () => {
      hyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await dispatcher.getAddress(), await inbox.getAddress(), [])
      expect(await hyperProver.getProofType()).to.equal("Hyperlane")
    })
  })
  describe('invalid', async () => {
    beforeEach(async () => {
      hyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await dispatcher.getAddress(), await inbox.getAddress(), [])
    })
    it('should revert when msg.sender is not the mailbox', async () => {
      await expect(
        hyperProver
          .connect(solver)
          .handle(12345, ethers.sha256('0x'), ethers.sha256('0x')),
      ).to.be.revertedWithCustomError(hyperProver, 'UnauthorizedHandle')
    })
    it('should revert when sender field is not authorized', async () => {
      await expect(
        hyperProver
          .connect(dispatcher)
          .handle(12345, ethers.sha256('0x'), ethers.sha256('0x')),
      ).to.be.revertedWithCustomError(hyperProver, 'UnauthorizedInitiateProving')
    })
  })

  describe('valid initiateProving', async () => {
    beforeEach(async () => {
      hyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await dispatcher.getAddress(), await inbox.getAddress(), [await inbox.getAddress()])
    })
    
    it('should handle the message if it comes from an authorized source', async () => {
      const intentHash = ethers.sha256('0x')
      const claimantAddress = await claimant.getAddress()
      const msgBody = abiCoder.encode(
        ['bytes32[]', 'address[]'],
        [[intentHash], [claimantAddress]],
      )
      expect(await hyperProver.provenIntents(intentHash)).to.eq(
        ethers.ZeroAddress,
      )
      await expect(
        hyperProver
          .connect(dispatcher)
          .handle(
            12345,
            ethers.zeroPadValue(await inbox.getAddress(), 32),
            msgBody,
          ),
      )
        .to.emit(hyperProver, 'IntentProven')
        .withArgs(intentHash, claimantAddress)
      expect(await hyperProver.provenIntents(intentHash)).to.eq(claimantAddress)
    })
    
    it('should reject initiateProving from unauthorized source', async () => {
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [await claimant.getAddress()]
      const sourceChainProver = await solver.getAddress()
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes', 'address'],
        ['0x', ethers.ZeroAddress]
      )
      
      await expect(
        hyperProver
          .connect(solver)
          .initiateProving(123, intentHashes, claimants, sourceChainProver, data)
      ).to.be.revertedWithCustomError(hyperProver, 'UnauthorizedInitiateProving')
    })
    
    it('should correctly call dispatch in the initiateProving method', async () => {
      // Mock the inbox contract to allow us to test initiateProving
      const inboxWithSigner = inbox.connect(owner)
      await inboxWithSigner.setMailbox(await dispatcher.getAddress())
      
      // Set up test data
      const sourceChainId = 123
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [await claimant.getAddress()]
      const sourceChainProver = await solver.getAddress()
      const metadata = '0x1234'
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes', 'address'],
        [metadata, ethers.ZeroAddress]
      )
      
      // Before initiateProving, make sure the dispatcher hasn't been called
      expect(await dispatcher.dispatched()).to.be.false
      
      // Call initiateProving through inbox
      await inbox.connect(owner).messageBridgeSendBatch(
        sourceChainId,
        await hyperProver.getAddress(),
        intentHashes,
        await hyperProver.getAddress(),
        sourceChainProver,
        data,
        { value: 1000000 } // Send some value to cover fees
      )
      
      // Verify the mailbox was called with correct parameters
      expect(await dispatcher.dispatched()).to.be.true
      expect(await dispatcher.destinationDomain()).to.eq(sourceChainId)
      expect(await dispatcher.recipientAddress()).to.eq(
        ethers.zeroPadValue(sourceChainProver, 32)
      )
      
      // Verify message encoding is correct
      const expectedBody = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes32[]', 'address[]'],
        [intentHashes, claimants]
      )
      expect(await dispatcher.messageBody()).to.eq(expectedBody)
    })
    
    it('should correctly format parameters in processAndFormat', async () => {
      // Since processAndFormat is internal, we'll test through fetchFee
      const sourceChainId = 123
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [await claimant.getAddress()]
      const sourceChainProver = await solver.getAddress()
      const metadata = '0x1234'
      const hookAddress = ethers.ZeroAddress
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes', 'address'],
        [metadata, hookAddress]
      )
      
      // Call fetchFee which uses processAndFormat internally
      const fee = await hyperProver.fetchFee(
        sourceChainId,
        intentHashes,
        claimants,
        sourceChainProver,
        data
      )
      
      // Verify we get a valid fee (implementation dependent, so just check it's non-zero)
      expect(fee).to.be.gt(0)
    })
  })

  describe('message bridge end-to-end', async () => {
    it('works end to end with message bridge', async () => {
      await inbox.connect(owner).setMailbox(await dispatcher.getAddress())
      hyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await dispatcher.getAddress(), await inbox.getAddress(), [await inbox.getAddress()])
      await token.mint(solver.address, amount)
      const sourceChainID = 12345
      const calldata = await encodeTransfer(await claimant.getAddress(), amount)
      const timeStamp = (await time.latest()) + 1000
      const salt = ethers.encodeBytes32String('0x987')
      const routeTokens = [{ token: await token.getAddress(), amount: amount }]
      const route = {
        salt: salt,
        source: sourceChainID,
        destination: Number(
          (await hyperProver.runner?.provider?.getNetwork())?.chainId,
        ),
        inbox: await inbox.getAddress(),
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
        prover: await hyperProver.getAddress(),
        deadline: timeStamp + 1000,
        nativeValue: 1n,
        tokens: [] as TokenAmount[],
      }

      const { intentHash, rewardHash } = hashIntent({ route, reward })
      
      const metadata = '0x1234'
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes', 'address'],
        [metadata, ethers.ZeroAddress]
      )
      
      await token.connect(solver).approve(await inbox.getAddress(), amount)

      expect(await hyperProver.provenIntents(intentHash)).to.eq(
        ethers.ZeroAddress,
      )
      
      // Use messageBridge instead of hyperInstant
      const fee = await hyperProver.fetchFee(
        sourceChainID,
        [intentHash],
        [await claimant.getAddress()],
        await hyperProver.getAddress(),
        data
      )
      
      await expect(
        inbox.connect(solver).fulfillMessageBridge(
          route,
          rewardHash,
          await claimant.getAddress(),
          intentHash,
          await hyperProver.getAddress(),
          await hyperProver.getAddress(),
          data,
          { value: fee }
        )
      ).to.emit(dispatcher, 'MessageDispatched')
      
      // Simulate the message being handled on the destination chain
      const msgBody = abiCoder.encode(
        ['bytes32[]', 'address[]'],
        [[intentHash], [await claimant.getAddress()]]
      )
      
      await expect(
        hyperProver
          .connect(dispatcher)
          .handle(
            12345,
            ethers.zeroPadValue(await inbox.getAddress(), 32),
            msgBody
          )
      )
        .to.emit(hyperProver, 'IntentProven')
        .withArgs(intentHash, await claimant.getAddress())
        
      expect(await hyperProver.provenIntents(intentHash)).to.eq(
        await claimant.getAddress()
      )
    })
  })

  describe('batch proving', async () => {
    beforeEach(async () => {
      await inbox.connect(owner).setMailbox(await dispatcher.getAddress())
      hyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await dispatcher.getAddress(), await inbox.getAddress(), [await inbox.getAddress()])
    })
    
    it('should emit if intent is already proven', async () => {
      const intentHash = ethers.sha256('0x')
      const claimantAddress = await claimant.getAddress()
      const msgBody = abiCoder.encode(
        ['bytes32[]', 'address[]'],
        [[intentHash], [claimantAddress]],
      )
      await hyperProver
        .connect(dispatcher)
        .handle(
          12345,
          ethers.zeroPadValue(await inbox.getAddress(), 32),
          msgBody,
        )

      await expect(
        hyperProver
          .connect(dispatcher)
          .handle(
            12345,
            ethers.zeroPadValue(await inbox.getAddress(), 32),
            msgBody,
          ),
      )
        .to.emit(hyperProver, 'IntentAlreadyProven')
        .withArgs(intentHash)
    })
    
    it('should work with a batch', async () => {
      const intentHash = ethers.sha256('0x')
      const otherHash = ethers.sha256('0x1337')
      const claimantAddress = await claimant.getAddress()
      const otherAddress = await solver.getAddress()
      const msgBody = abiCoder.encode(
        ['bytes32[]', 'address[]'],
        [
          [intentHash, otherHash],
          [claimantAddress, otherAddress],
        ],
      )

      await expect(
        hyperProver
          .connect(dispatcher)
          .handle(
            12345,
            ethers.zeroPadValue(await inbox.getAddress(), 32),
            msgBody,
          ),
      )
        .to.emit(hyperProver, 'IntentProven')
        .withArgs(intentHash, claimantAddress)
        .to.emit(hyperProver, 'IntentProven')
        .withArgs(otherHash, otherAddress)
    })
    
    it('should work with batched message bridge fulfillment', async () => {
      await token.mint(solver.address, 2 * amount)
      const sourceChainID = 12345
      const calldata = await encodeTransfer(await claimant.getAddress(), amount)
      const timeStamp = (await time.latest()) + 1000
      let salt = ethers.encodeBytes32String('0x987')
      const routeTokens: TokenAmount[] = [
        { token: await token.getAddress(), amount: amount },
      ]
      const route = {
        salt: salt,
        source: sourceChainID,
        destination: Number(
          (await hyperProver.runner?.provider?.getNetwork())?.chainId,
        ),
        inbox: await inbox.getAddress(),
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
        prover: await hyperProver.getAddress(),
        deadline: timeStamp + 1000,
        nativeValue: 1n,
        tokens: [] as TokenAmount[],
      }

      const { intentHash: intentHash0, rewardHash: rewardHash0 } = hashIntent({
        route,
        reward,
      })
      
      const metadata = '0x1234'
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes', 'address'],
        [metadata, ethers.ZeroAddress]
      )

      await token.connect(solver).approve(await inbox.getAddress(), amount)

      expect(await hyperProver.provenIntents(intentHash0)).to.eq(
        ethers.ZeroAddress,
      )

      await expect(inbox.connect(solver).fulfillMessageBridgeBatched(
        route,
        rewardHash0,
        await claimant.getAddress(),
        intentHash0,
        await hyperProver.getAddress(),
        await hyperProver.getAddress(),
        { value: minBatcherReward }
      ))
        .to.emit(inbox, 'AddToBatch')
        .withArgs(
          intentHash0,
          sourceChainID,
          await claimant.getAddress(),
          await hyperProver.getAddress(),
          await hyperProver.getAddress()
        )

      salt = ethers.encodeBytes32String('0x1234')
      const route1 = {
        salt: salt,
        source: sourceChainID,
        destination: Number(
          (await hyperProver.runner?.provider?.getNetwork())?.chainId,
        ),
        inbox: await inbox.getAddress(),
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
        prover: await hyperProver.getAddress(),
        deadline: timeStamp + 1000,
        nativeValue: 1n,
        tokens: [],
      }
      const { intentHash: intentHash1, rewardHash: rewardHash1 } = hashIntent({
        route: route1,
        reward: reward1,
      })

      await token.connect(solver).approve(await inbox.getAddress(), amount)

      await expect(inbox.connect(solver).fulfillMessageBridgeBatched(
        route1,
        rewardHash1,
        await claimant.getAddress(),
        intentHash1,
        await hyperProver.getAddress(),
        await hyperProver.getAddress(),
        { value: minBatcherReward }
      ))
        .to.emit(inbox, 'AddToBatch')
        .withArgs(
          intentHash1,
          sourceChainID,
          await claimant.getAddress(),
          await hyperProver.getAddress(),
          await hyperProver.getAddress()
        )
      
      expect(await hyperProver.provenIntents(intentHash1)).to.eq(
        ethers.ZeroAddress,
      )

      const msgbody = abiCoder.encode(
        ['bytes32[]', 'address[]'],
        [
          [intentHash0, intentHash1],
          [await claimant.getAddress(), await claimant.getAddress()],
        ],
      )

      const fee = await hyperProver.fetchFee(
        sourceChainID,
        [intentHash0, intentHash1],
        [await claimant.getAddress(), await claimant.getAddress()],
        await hyperProver.getAddress(),
        data
      )

      await expect(
        inbox
          .connect(solver)
          .messageBridgeSendBatch(
            sourceChainID,
            await hyperProver.getAddress(),
            [intentHash0, intentHash1],
            await hyperProver.getAddress(),
            await hyperProver.getAddress(),
            data,
            { value: fee }
          )
      )
        .to.changeEtherBalance(solver, 2 * minBatcherReward - Number(fee))

      // Simulate the message being handled
      await expect(
        hyperProver
          .connect(dispatcher)
          .handle(
            12345,
            ethers.zeroPadValue(await inbox.getAddress(), 32),
            msgbody
          )
      )
        .to.emit(hyperProver, 'IntentProven')
        .withArgs(intentHash0, await claimant.getAddress())
        .to.emit(hyperProver, 'IntentProven')
        .withArgs(intentHash1, await claimant.getAddress())

      expect(await hyperProver.provenIntents(intentHash0)).to.eq(
        await claimant.getAddress()
      )
      expect(await hyperProver.provenIntents(intentHash1)).to.eq(
        await claimant.getAddress()
      )
    })
  })
})