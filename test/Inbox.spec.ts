import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import {
  TestERC20,
  TestUSDT,
  Inbox,
  TestProver,
  Executor,
} from '../typechain-types'
import {
  time,
  loadFixture,
} from '@nomicfoundation/hardhat-toolbox/network-helpers'
import { encodeTransfer } from '../utils/encode'
import { keccak256 } from 'ethers'
import { hashIntent, Route, Reward, Intent } from '../utils/intent'
import { addressToBytes32 } from '../utils/typeCasts'

describe('Inbox Test', (): void => {
  let inbox: Inbox
  let executor: Executor
  let erc20: TestERC20
  let testUSDT: TestUSDT
  let owner: SignerWithAddress
  let solver: SignerWithAddress
  let dstAddr: SignerWithAddress
  let route: Route
  let reward: Reward
  let rewardHash: string
  let intentHash: string
  let mockProver: TestProver
  const salt = ethers.encodeBytes32String('0x987')
  let erc20Address: string
  const timeDelta = 1000
  const mintAmount = 1000
  const sourceChainID = 123

  async function deployInboxFixture(): Promise<{
    inbox: Inbox
    executor: Executor
    erc20: TestERC20
    testUSDT: TestUSDT
    owner: SignerWithAddress
    solver: SignerWithAddress
    dstAddr: SignerWithAddress
  }> {
    const [owner, solver, dstAddr] = await ethers.getSigners()
    const portalFactory = await ethers.getContractFactory('Portal')
    const portal = await portalFactory.deploy()
    const inbox = await ethers.getContractAt('Inbox', await portal.getAddress())
    const executor = await ethers.getContractAt(
      'Executor',
      await inbox.executor(),
    )

    // deploy ERC20 test
    const erc20Factory = await ethers.getContractFactory('TestERC20')
    const erc20 = await erc20Factory.deploy('eco', 'eco')
    await erc20.mint(solver.address, mintAmount)
    await erc20.mint(owner.address, mintAmount)

    // deploy TestUSDT with ERC165 support
    const testUSDTFactory = await ethers.getContractFactory('TestUSDT')
    const testUSDT = await testUSDTFactory.deploy('TestUSDT', 'TUSDT')
    await testUSDT.mint(solver.address, mintAmount)
    await testUSDT.mint(owner.address, mintAmount)

    return {
      inbox,
      executor,
      erc20,
      testUSDT,
      owner,
      solver,
      dstAddr,
    }
  }

  async function createIntentData(
    amount: number,
    timeDelta: number,
  ): Promise<{
    route: Route
    reward: Reward
    rewardHash: string
    intentHash: string
  }> {
    erc20Address = await erc20.getAddress()
    const data = await encodeTransfer(dstAddr.address, amount)
    const deadline = (await time.latest()) + timeDelta

    // Create intent directly
    const intent: Intent = {
      destination: Number((await owner.provider.getNetwork()).chainId),
      route: {
        salt,
        deadline,
        portal: await inbox.getAddress(),
        nativeAmount: 0,
        tokens: [{ token: await erc20.getAddress(), amount: amount }],
        calls: [
          {
            target: erc20Address,
            data,
            value: 0,
          },
        ],
      },
      reward: {
        creator: solver.address,
        prover: solver.address,
        deadline,
        nativeAmount: 0n,
        tokens: [
          {
            token: erc20Address,
            amount: amount,
          },
        ],
      },
    }

    // Hash the intent
    const { rewardHash, intentHash } = hashIntent(intent)

    return {
      route: intent.route,
      reward: intent.reward,
      rewardHash,
      intentHash,
    }
  }

  beforeEach(async (): Promise<void> => {
    ;({ inbox, executor, erc20, testUSDT, owner, solver, dstAddr } =
      await loadFixture(deployInboxFixture))
    ;({ route, reward, rewardHash, intentHash } = await createIntentData(
      mintAmount,
      timeDelta,
    ))

    const factory = await ethers.getContractFactory('TestProver')
    const inboxAddress = await inbox.getAddress()
    mockProver = await factory.deploy(inboxAddress)
  })

  describe('fulfill when the intent is invalid', () => {
    it('should revert if fulfillment is attempted on an incorrect destination chain', async () => {
      // Create an intent hash for a different destination chain
      const wrongDestination = 123
      const wrongIntent: Intent = {
        destination: wrongDestination,
        route: route,
        reward: reward,
      }
      const { intentHash: wrongIntentHash } = hashIntent(wrongIntent)

      await expect(
        inbox
          .connect(owner)
          .fulfill(
            wrongIntentHash,
            route,
            rewardHash,
            addressToBytes32(dstAddr.address),
          ),
      ).to.be.revertedWithCustomError(inbox, 'InvalidHash')
    })

    it('should revert if the generated hash does not match the expected hash', async () => {
      const goofyHash = keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
          ['string'],
          ["you wouldn't block a chain"],
        ),
      )
      await expect(
        inbox
          .connect(solver)
          .fulfill(
            goofyHash,
            route,
            rewardHash,
            addressToBytes32(dstAddr.address),
          ),
      ).to.be.revertedWithCustomError(inbox, 'InvalidHash')
    })
    it('should revert via InvalidHash if all intent data was input correctly, but the intent used a different inbox on creation', async () => {
      const anotherPortal = await (
        await ethers.getContractFactory('Portal')
      ).deploy()
      const anotherInbox = await ethers.getContractAt(
        'Inbox',
        await anotherPortal.getAddress(),
      )

      const _route: Route = {
        ...route,
        portal: await anotherInbox.getAddress(),
      }

      const _intentHash = hashIntent({
        destination: Number((await owner.provider.getNetwork()).chainId),
        route: _route,
        reward: reward,
      }).intentHash

      await expect(
        inbox
          .connect(solver)
          .fulfill(
            _intentHash,
            _route,
            rewardHash,
            addressToBytes32(dstAddr.address),
          ),
      ).to.be.revertedWithCustomError(inbox, 'InvalidPortal')
    })
  })

  describe('fulfill when the intent is valid', () => {
    it('should revert if claimant is zero address', async () => {
      await expect(
        inbox
          .connect(solver)
          .fulfill(intentHash, route, rewardHash, ethers.ZeroHash),
      ).to.be.revertedWithCustomError(inbox, 'ZeroClaimant')
    })

    it('should revert if the solver has not approved tokens for transfer', async () => {
      await expect(
        inbox
          .connect(solver)
          .fulfill(
            intentHash,
            route,
            rewardHash,
            addressToBytes32(dstAddr.address),
          ),
      ).to.be.revertedWithCustomError(erc20, 'ERC20InsufficientAllowance')
    })

    it('should revert if the call fails', async () => {
      await erc20.connect(solver).approve(await inbox.getAddress(), mintAmount)

      const _route: Route = {
        ...route,
        calls: [
          {
            target: await erc20.getAddress(),
            data: await encodeTransfer(dstAddr.address, mintAmount * 100),
            value: 0,
          },
        ],
      }

      const _intentHash = hashIntent({
        destination: Number((await owner.provider.getNetwork()).chainId),
        route: _route,
        reward: reward,
      }).intentHash
      await expect(
        inbox
          .connect(solver)
          .fulfill(
            _intentHash,
            _route,
            rewardHash,
            addressToBytes32(dstAddr.address),
          ),
      ).to.be.revertedWithCustomError(executor, 'CallFailed')
    })

    it('should revert if one of the targets is an EOA', async () => {
      await erc20.connect(solver).approve(await inbox.getAddress(), mintAmount)

      const _route: Route = {
        ...route,
        calls: [
          {
            target: solver.address,
            data: await encodeTransfer(dstAddr.address, mintAmount * 100),
            value: 0,
          },
        ],
      }
      const intentHash = hashIntent({
        destination: Number((await owner.provider.getNetwork()).chainId),
        route: _route,
        reward: reward,
      }).intentHash
      await expect(
        inbox
          .connect(solver)
          .fulfill(
            intentHash,
            _route,
            rewardHash,
            addressToBytes32(dstAddr.address),
          ),
      )
        .to.be.revertedWithCustomError(executor, 'CallToEOA')
        .withArgs(solver.address)
    })

    it('should succeed with storage proving', async () => {
      let claimant = await inbox.claimants(intentHash)
      expect(claimant).to.equal(ethers.ZeroHash)

      expect(await erc20.balanceOf(solver.address)).to.equal(mintAmount)
      expect(await erc20.balanceOf(dstAddr.address)).to.equal(0)

      // transfer the tokens to the inbox so it can process the transaction
      await erc20.connect(solver).approve(await inbox.getAddress(), mintAmount)

      // should emit an event
      await expect(
        inbox
          .connect(solver)
          .fulfill(
            intentHash,
            route,
            rewardHash,
            addressToBytes32(dstAddr.address),
          ),
      )
        .to.emit(inbox, 'IntentFulfilled')
        .withArgs(intentHash, ethers.zeroPadValue(dstAddr.address, 32))
      // should update the fulfilled hash
      claimant = await inbox.claimants(intentHash)
      expect(claimant).to.equal(ethers.zeroPadValue(dstAddr.address, 32))

      // check balances
      expect(await erc20.balanceOf(solver.address)).to.equal(0)
      expect(await erc20.balanceOf(dstAddr.address)).to.equal(mintAmount)
    })

    it('should revert if the intent has already been fulfilled', async () => {
      // transfer the tokens to the inbox so it can process the transaction
      await erc20.connect(solver).approve(await inbox.getAddress(), mintAmount)

      // should emit an event
      await expect(
        inbox
          .connect(solver)
          .fulfill(
            intentHash,
            route,
            rewardHash,
            addressToBytes32(dstAddr.address),
          ),
      ).to.not.be.reverted
      // should revert
      await expect(
        inbox
          .connect(solver)
          .fulfill(
            intentHash,
            route,
            rewardHash,
            addressToBytes32(dstAddr.address),
          ),
      ).to.be.revertedWithCustomError(inbox, 'IntentAlreadyFulfilled')
    })

    it('should revert if msg.value is insufficient for route.nativeAmount', async () => {
      const ethAmount = ethers.parseEther('1.0')
      const insufficientAmount = ethers.parseEther('0.5')

      // Create intent with ETH amount
      const _route: Route = {
        ...route,
        nativeAmount: ethAmount,
        calls: [
          {
            target: dstAddr.address,
            data: '0x',
            value: ethAmount,
          },
        ],
      }

      const intentHash = hashIntent({
        destination: Number((await owner.provider.getNetwork()).chainId),
        route: _route,
        reward: reward,
      }).intentHash

      await erc20.connect(solver).approve(await inbox.getAddress(), mintAmount)

      // Should revert with insufficient native amount
      await expect(
        inbox
          .connect(solver)
          .fulfill(
            intentHash,
            _route,
            rewardHash,
            addressToBytes32(dstAddr.address),
            { value: insufficientAmount },
          ),
      ).to.be.revertedWithCustomError(inbox, 'InsufficientNativeAmount')
        .withArgs(insufficientAmount, ethAmount)

      // Should also revert with zero native amount when expecting ETH
      await expect(
        inbox
          .connect(solver)
          .fulfill(
            intentHash,
            _route,
            rewardHash,
            addressToBytes32(dstAddr.address),
          ),
      ).to.be.revertedWithCustomError(inbox, 'InsufficientNativeAmount')
        .withArgs(0, ethAmount)
    })

    it('should send ETH if one of the targets is an EOA', async () => {
      const ethAmount = ethers.parseEther('1.0')

      // Create intent with ETH transfer to EOA
      const _route: Route = {
        ...route,
        nativeAmount: ethAmount, // Update nativeAmount to match the call value
        calls: [
          {
            target: dstAddr.address,
            data: '0x', // Empty data for ETH transfer
            value: ethAmount,
          },
        ],
      }

      const intentHash = hashIntent({
        destination: Number((await owner.provider.getNetwork()).chainId),
        route: _route,
        reward: reward,
      }).intentHash

      await erc20.connect(solver).approve(await inbox.getAddress(), mintAmount)

      // Check initial balance
      const initialBalance = await ethers.provider.getBalance(dstAddr.address)

      // Should succeed with ETH transfer to EOA
      await expect(
        inbox
          .connect(solver)
          .fulfill(
            intentHash,
            _route,
            rewardHash,
            addressToBytes32(dstAddr.address),
            { value: ethAmount },
          ),
      )
        .to.emit(inbox, 'IntentFulfilled')
        .withArgs(intentHash, addressToBytes32(dstAddr.address))

      // Check ETH was transferred
      const finalBalance = await ethers.provider.getBalance(dstAddr.address)
      expect(finalBalance - initialBalance).to.equal(ethAmount)
    })

    it('should succeed when calling a contract with ERC165 support', async () => {
      // Create intent using TestUSDT which supports ERC165
      const transferCalldata = testUSDT.interface.encodeFunctionData(
        'transfer',
        [dstAddr.address, mintAmount],
      )

      const _route: Route = {
        ...route,
        tokens: [
          {
            token: await testUSDT.getAddress(),
            amount: mintAmount,
          },
        ],
        calls: [
          {
            target: await testUSDT.getAddress(),
            data: transferCalldata,
            value: 0,
          },
        ],
      }

      const _intentHash = hashIntent({
        destination: Number((await owner.provider.getNetwork()).chainId),
        route: _route,
        reward: reward,
      }).intentHash

      await testUSDT
        .connect(solver)
        .approve(await inbox.getAddress(), mintAmount)

      // Check initial balances
      expect(await testUSDT.balanceOf(solver.address)).to.equal(mintAmount)
      expect(await testUSDT.balanceOf(dstAddr.address)).to.equal(0)

      // Should succeed with ERC165 supported contract
      await expect(
        inbox
          .connect(solver)
          .fulfill(
            _intentHash,
            _route,
            rewardHash,
            addressToBytes32(dstAddr.address),
          ),
      )
        .to.emit(inbox, 'IntentFulfilled')
        .withArgs(_intentHash, addressToBytes32(dstAddr.address))

      // Check tokens were transferred
      expect(await testUSDT.balanceOf(solver.address)).to.equal(0)
      expect(await testUSDT.balanceOf(dstAddr.address)).to.equal(mintAmount)
    })
  })

  describe('prove', async () => {
    it('gets the right args', async () => {
      await erc20.connect(solver).approve(await inbox.getAddress(), mintAmount)

      // Calculate expected encoded data (claimant + intentHash)
      const claimantBytes32 = addressToBytes32(dstAddr.address)
      const expectedData = '0x' + claimantBytes32.slice(2) + intentHash.slice(2)

      const theArgs = {
        sender: solver.address,
        sourceChainId: BigInt(sourceChainID),
        data: '0x', // The additional data parameter, not the encoded proofs
        value: 123456789n,
      }
      await expect(
        inbox
          .connect(solver)
          .fulfill(
            intentHash,
            route,
            rewardHash,
            addressToBytes32(dstAddr.address),
          ),
      ).to.not.be.reverted

      const argsBefore = await mockProver.args()
      expect(argsBefore.sender).to.not.equal(theArgs.sender)

      await inbox
        .connect(solver)
        .prove(
          await mockProver.getAddress(),
          sourceChainID,
          [intentHash],
          '0x',
          { value: 123456789 },
        )
      const argsAfter = await mockProver.args()
      expect(argsAfter.sender).to.equal(theArgs.sender)
      expect(argsAfter.sourceChainId).to.equal(theArgs.sourceChainId)
      expect(argsAfter.data).to.equal(theArgs.data)
      expect(argsAfter.value).to.equal(theArgs.value)

      // Check the arrays separately
      const intentHashes = await mockProver.argIntentHashes(0)
      expect(intentHashes).to.equal(intentHash)
      const claimants = await mockProver.argClaimants(0)
      expect(claimants).to.equal(addressToBytes32(dstAddr.address))
    })
  })

  describe('fulfillAndProve', async () => {
    it('works', async () => {
      await erc20.connect(solver).approve(await inbox.getAddress(), mintAmount)

      // Calculate expected encoded data (claimant + intentHash)
      const claimantBytes32 = addressToBytes32(dstAddr.address)
      const expectedData = '0x' + claimantBytes32.slice(2) + intentHash.slice(2)

      const theArgs = {
        sender: solver.address,
        sourceChainId: BigInt(sourceChainID),
        data: '0x', // The additional data parameter, not the encoded proofs
        value: 0n,
      }

      const argsBefore = await mockProver.args()
      expect(argsBefore.sender).to.not.equal(theArgs.sender)

      await expect(
        inbox
          .connect(solver)
          .fulfillAndProve(
            intentHash,
            route,
            rewardHash,
            addressToBytes32(dstAddr.address),
            await mockProver.getAddress(),
            sourceChainID,
            '0x',
          ),
      ).to.not.be.reverted

      const argsAfter = await mockProver.args()
      expect(argsAfter.sender).to.equal(theArgs.sender)
      expect(argsAfter.sourceChainId).to.equal(theArgs.sourceChainId)
      expect(argsAfter.data).to.equal(theArgs.data)
      expect(argsAfter.value).to.equal(theArgs.value)

      // Check the arrays separately
      const intentHashes = await mockProver.argIntentHashes(0)
      expect(intentHashes).to.equal(intentHash)
      const claimants = await mockProver.argClaimants(0)
      expect(claimants).to.equal(addressToBytes32(dstAddr.address))
    })

    it('should handle fulfillAndProve with address claimant', async () => {
      // Use a valid EVM address for the claimant
      const validClaimant = await dstAddr.getAddress()

      await erc20.connect(solver).approve(await inbox.getAddress(), mintAmount)
      await expect(
        inbox
          .connect(solver)
          .fulfillAndProve(
            intentHash,
            route,
            rewardHash,
            addressToBytes32(validClaimant),
            await mockProver.getAddress(),
            sourceChainID,
            '0x',
          ),
      )
        .to.emit(inbox, 'IntentFulfilled')
        .withArgs(intentHash, ethers.zeroPadValue(validClaimant, 32))

      // Verify the claimant was stored correctly
      const storedClaimant = await inbox.claimants(intentHash)
      expect(storedClaimant).to.equal(ethers.zeroPadValue(validClaimant, 32))
    })
  })
})
