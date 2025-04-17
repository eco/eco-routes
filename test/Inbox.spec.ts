import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import {
  TestERC20,
  Inbox,
  TestMailbox,
  TestMessageBridgeProver,
} from '../typechain-types'
import {
  time,
  loadFixture,
} from '@nomicfoundation/hardhat-toolbox/network-helpers'
import { encodeTransfer } from '../utils/encode'
import { keccak256, toBeHex } from 'ethers'
import {
  encodeReward,
  encodeRoute,
  hashIntent,
  Call,
  Route,
  Reward,
  Intent,
  TokenAmount,
} from '../utils/intent'

describe('Inbox Test', (): void => {
  let inbox: Inbox
  let mailbox: TestMailbox
  let erc20: TestERC20
  let owner: SignerWithAddress
  let solver: SignerWithAddress
  let dstAddr: SignerWithAddress
  let route: Route
  let reward: Reward
  let intent: Intent
  let routeHash: string
  let rewardHash: string
  let intentHash: string
  let otherHash: string
  let routeTokens: TokenAmount[]
  let calls: Call[]
  let otherCalls: Call[]
  let mockProver: TestMessageBridgeProver
  const salt = ethers.encodeBytes32String('0x987')
  let erc20Address: string
  const timeDelta = 1000
  const mintAmount = 1000
  const sourceChainID = 123
  const minBatcherReward = 12345
  let fee: BigInt

  async function deployInboxFixture(): Promise<{
    inbox: Inbox
    mailbox: TestMailbox
    erc20: TestERC20
    owner: SignerWithAddress
    solver: SignerWithAddress
    dstAddr: SignerWithAddress
  }> {
    const mailbox = await (
      await ethers.getContractFactory('TestMailbox')
    ).deploy(ethers.ZeroAddress)
    const [owner, solver, dstAddr] = await ethers.getSigners()
    const inboxFactory = await ethers.getContractFactory('Inbox')
    const inbox = await inboxFactory.deploy(
      owner.address,
      false,
      minBatcherReward,
      [solver.address],
    )
    // deploy ERC20 test
    const erc20Factory = await ethers.getContractFactory('TestERC20')
    const erc20 = await erc20Factory.deploy('eco', 'eco')
    await erc20.mint(solver.address, mintAmount)
    await erc20.mint(owner.address, mintAmount)

    return {
      inbox,
      mailbox,
      erc20,
      owner,
      solver,
      dstAddr,
    }
  }

  async function createIntentData(
    amount: number,
    timeDelta: number,
  ): Promise<{
    calls: Call[]
    route: Route
    reward: Reward
    intent: Intent
    routeHash: string
    rewardHash: string
    intentHash: string
  }> {
    erc20Address = await erc20.getAddress()
    const _calldata = await encodeTransfer(dstAddr.address, amount)
    const _timestamp = (await time.latest()) + timeDelta
    routeTokens = [{ token: await erc20.getAddress(), amount: amount }]
    const _calls: Call[] = [
      {
        target: erc20Address,
        data: _calldata,
        value: 0,
      },
    ]
    const _route = {
      salt,
      source: sourceChainID,
      destination: Number((await owner.provider.getNetwork()).chainId),
      inbox: await inbox.getAddress(),
      tokens: routeTokens,
      calls: _calls,
    }
    const _routeHash = keccak256(encodeRoute(_route))

    const _reward = {
      creator: solver.address,
      prover: solver.address,
      deadline: _timestamp,
      nativeValue: 0n,
      tokens: [
        {
          token: erc20Address,
          amount: amount,
        },
      ],
    }

    const _rewardHash = keccak256(encodeReward(_reward))

    const _intent = {
      route: _route,
      reward: _reward,
    }

    const _intentHash = keccak256(
      ethers.solidityPacked(['bytes32', 'bytes32'], [_routeHash, _rewardHash]),
    )

    return {
      calls: _calls,
      route: _route,
      reward: _reward,
      intent: _intent,
      routeHash: _routeHash,
      rewardHash: _rewardHash,
      intentHash: _intentHash,
    }
  }
  beforeEach(async (): Promise<void> => {
    ;({ inbox, mailbox, erc20, owner, solver, dstAddr } =
      await loadFixture(deployInboxFixture))
    ;({ calls, route, reward, intent, routeHash, rewardHash, intentHash } =
      await createIntentData(mintAmount, timeDelta))
  })
  it('initializes correctly', async () => {
    expect(await inbox.owner()).to.eq(owner.address)
    expect(await inbox.isSolvingPublic()).to.be.false
    expect(await inbox.solverWhitelist(solver)).to.be.true
    expect(await inbox.solverWhitelist(owner)).to.be.false

    const log = (
      await inbox.queryFilter(inbox.getEvent('SolverWhitelistChanged'))
    )[0]

    expect(log.args._solver).to.eq(solver.address)
    expect(log.args._canSolve).to.eq(true)
  })

  describe('restricted methods', async () => {
    it('doesnt let non-owner call onlyOwner functions', async () => {
      await expect(
        inbox.connect(solver).makeSolvingPublic(),
      ).to.be.revertedWithCustomError(inbox, 'OwnableUnauthorizedAccount')
      await expect(
        inbox.connect(solver).changeSolverWhitelist(owner.address, true),
      ).to.be.revertedWithCustomError(inbox, 'OwnableUnauthorizedAccount')
      await expect(
        inbox.connect(solver).setMinBatcherReward(54321),
      ).to.be.revertedWithCustomError(inbox, 'OwnableUnauthorizedAccount')
    })
    it('lets owner make solving public', async () => {
      expect(await inbox.isSolvingPublic()).to.be.false
      await expect(inbox.connect(owner).makeSolvingPublic()).to.emit(
        inbox,
        'SolvingIsPublic',
      )
      expect(await inbox.isSolvingPublic()).to.be.true
    })
    it('lets owner change the solver whitelist', async () => {
      expect(await inbox.solverWhitelist(solver)).to.be.true
      expect(await inbox.solverWhitelist(owner)).to.be.false
      await inbox.connect(owner).changeSolverWhitelist(solver.address, false)
      await inbox.connect(owner).changeSolverWhitelist(owner.address, true)
      expect(await inbox.solverWhitelist(solver)).to.be.false
      expect(await inbox.solverWhitelist(owner)).to.be.true
    })
    it('lets owner set minBatchReward', async () => {
      expect(await inbox.minBatcherReward()).to.eq(minBatcherReward)
      await expect(inbox.connect(owner).setMinBatcherReward(54321))
        .to.emit(inbox, 'MinBatcherRewardSet')
        .withArgs(54321)
      expect(await inbox.minBatcherReward()).to.eq(54321)
    })
  })

  describe('fulfill when the intent is invalid', () => {
    it('should revert if fulfillment is attempted on an incorrect destination chain', async () => {
      route.destination = 123
      await expect(
        inbox
          .connect(owner)
          .fulfillStorage(route, rewardHash, dstAddr.address, intentHash),
      )
        .to.be.revertedWithCustomError(inbox, 'WrongChain')
        .withArgs(123)
    })
    it('should revert if solved by someone who isnt whitelisted when solving isnt public', async () => {
      expect(await inbox.isSolvingPublic()).to.be.false
      expect(await inbox.solverWhitelist(owner.address)).to.be.false
      await expect(
        inbox
          .connect(owner)
          .fulfillStorage(route, rewardHash, dstAddr.address, intentHash),
      ).to.be.revertedWithCustomError(inbox, 'UnauthorizedSolveAttempt')
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
          .fulfillStorage(route, rewardHash, dstAddr.address, goofyHash),
      ).to.be.revertedWithCustomError(inbox, 'InvalidHash')
    })
    it('should revert via InvalidHash if all intent data was input correctly, but the intent used a different inbox on creation', async () => {
      const anotherInbox = await (
        await ethers.getContractFactory('Inbox')
      ).deploy(owner.address, false, minBatcherReward, [owner.address])

      const _route = {
        ...route,
        inbox: await anotherInbox.getAddress(),
      }

      const _intentHash = hashIntent({ route: _route, reward }).intentHash

      await expect(
        inbox
          .connect(solver)
          .fulfillStorage(_route, rewardHash, dstAddr.address, _intentHash),
      ).to.be.revertedWithCustomError(inbox, 'InvalidInbox')
    })
  })

  describe('fulfill when the intent is valid', () => {
    it('should revert if claimant is zero address', async () => {
      await expect(
        inbox
          .connect(solver)
          .fulfillStorage(route, rewardHash, ethers.ZeroAddress, intentHash),
      ).to.be.revertedWithCustomError(inbox, 'ZeroClaimant')
    })
    it('should revert if the solver has not approved tokens for transfer', async () => {
      await expect(
        inbox
          .connect(solver)
          .fulfillStorage(route, rewardHash, dstAddr.address, intentHash),
      ).to.be.revertedWithCustomError(erc20, 'ERC20InsufficientAllowance')
    })
    it('should revert if the call fails', async () => {
      await erc20.connect(solver).approve(await inbox.getAddress(), mintAmount)

      const _route = {
        ...route,
        calls: [
          {
            target: await erc20.getAddress(),
            data: await encodeTransfer(dstAddr.address, mintAmount * 100),
            value: 0,
          },
        ],
      }
      const _intentHash = hashIntent({ route: _route, reward }).intentHash
      await expect(
        inbox
          .connect(solver)
          .fulfillStorage(_route, rewardHash, dstAddr.address, _intentHash),
      ).to.be.revertedWithCustomError(inbox, 'IntentCallFailed')
    })
    it('should revert if any of the targets is a prover', async () => {
      const _route = {
        ...route,
        calls: [
          {
            target: await mockProver.getAddress(),
            data: '0x',
            value: 0,
          },
        ],
      }
      const _intentHash = hashIntent({ route: _route, reward }).intentHash
      await erc20.connect(solver).approve(await inbox.getAddress(), mintAmount)
      await expect(
        inbox
          .connect(solver)
          .fulfillStorage(_route, rewardHash, dstAddr.address, _intentHash),
      ).to.be.revertedWithCustomError(inbox, 'CallToProver')
    })
    it('should revert if one of the targets is an EOA', async () => {
      await erc20.connect(solver).approve(await inbox.getAddress(), mintAmount)

      const _route = {
        ...route,
        calls: [
          {
            target: solver.address,
            data: await encodeTransfer(dstAddr.address, mintAmount * 100),
            value: 0,
          },
        ],
      }
      const _intentHash = hashIntent({ route: _route, reward }).intentHash
      await expect(
        inbox
          .connect(solver)
          .fulfillStorage(_route, rewardHash, dstAddr.address, _intentHash),
      )
        .to.be.revertedWithCustomError(inbox, 'CallToEOA')
        .withArgs(solver.address)
    })
    it('should not revert when called by a whitelisted solver', async () => {
      expect(await inbox.solverWhitelist(solver)).to.be.true

      await erc20.connect(solver).approve(await inbox.getAddress(), mintAmount)

      await expect(
        inbox
          .connect(solver)
          .fulfillStorage(route, rewardHash, dstAddr.address, intentHash),
      ).to.not.be.reverted
    })
    it('should not revert when called by a non-whitelisted solver when solving is public', async () => {
      expect(await inbox.solverWhitelist(owner)).to.be.false
      await inbox.connect(owner).makeSolvingPublic()
      expect(await inbox.isSolvingPublic()).to.be.true

      await erc20.connect(owner).approve(await inbox.getAddress(), mintAmount)

      await expect(
        inbox
          .connect(owner)
          .fulfillStorage(route, rewardHash, dstAddr.address, intentHash),
      ).to.not.be.reverted
    })

    it('should succeed with storage proving', async () => {
      let fulfillment = await inbox.fulfilled(intentHash)
      expect(fulfillment.claimant).to.equal(ethers.ZeroAddress)

      expect(await erc20.balanceOf(solver.address)).to.equal(mintAmount)
      expect(await erc20.balanceOf(dstAddr.address)).to.equal(0)

      // transfer the tokens to the inbox so it can process the transaction
      await erc20.connect(solver).approve(await inbox.getAddress(), mintAmount)

      // should emit an event
      await expect(
        inbox
          .connect(solver)
          .fulfillStorage(route, rewardHash, dstAddr.address, intentHash),
      )
        .to.emit(inbox, 'Fulfillment')
        .withArgs(intentHash, sourceChainID, dstAddr.address)
        .to.emit(inbox, 'ToBeProven')
        .withArgs(intentHash, sourceChainID, dstAddr.address)
      // should update the fulfilled hash
      fulfillment = await inbox.fulfilled(intentHash)
      expect(fulfillment.claimant).to.equal(dstAddr.address)

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
          .fulfillStorage(route, rewardHash, dstAddr.address, intentHash),
      )
        .to.emit(inbox, 'ToBeProven')
        .withArgs(intentHash, sourceChainID, dstAddr.address)
      // should revert
      await expect(
        inbox
          .connect(solver)
          .fulfillStorage(route, rewardHash, dstAddr.address, intentHash),
      ).to.be.revertedWithCustomError(inbox, 'IntentAlreadyFulfilled')
    })
  })

  describe('message bridge proving', () => {
    beforeEach(async () => {
      mockProver = await (
        await ethers.getContractFactory('TestMessageBridgeProver')
      ).deploy([])
      expect(await mockProver.dispatched()).to.be.false

      await erc20.connect(solver).approve(await inbox.getAddress(), mintAmount)
    })

    it('should fail to fulfill message bridge if the fee is too low', async () => {
      const metadata = '0x1234'
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes', 'address'],
        [metadata, ethers.ZeroAddress],
      )

      // Get fee value
      fee = await mockProver.fetchFee(
        sourceChainID,
        [intentHash],
        [dstAddr.address],
        await mockProver.getAddress(),
        data,
      )

      expect(await mockProver.dispatched()).to.be.false
      await expect(
        inbox
          .connect(solver)
          .fulfillMessageBridge(
            route,
            rewardHash,
            dstAddr.address,
            intentHash,
            await mockProver.getAddress(),
            await mockProver.getAddress(),
            data,
            {
              value: Number(fee) - 1,
            },
          ),
      ).to.be.revertedWithCustomError(inbox, 'InsufficientFee')
      expect(await mockProver.dispatched()).to.be.false
    })

    it('should fail to fulfill message bridge batched if msg.value is less than the minimum', async () => {
      const metadata = '0x1234'
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes', 'address'],
        [metadata, ethers.ZeroAddress],
      )

      expect(await mockProver.dispatched()).to.be.false
      const fulfillment = await inbox.fulfilled(intentHash)
      expect(fulfillment.claimant).to.equal(ethers.ZeroAddress)

      await expect(
        inbox
          .connect(solver)
          .fulfillMessageBridgeBatched(
            route,
            rewardHash,
            dstAddr.address,
            intentHash,
            await mockProver.getAddress(),
            await mockProver.getAddress(),
            {
              value: (await inbox.minBatcherReward()) - BigInt(1),
            },
          ),
      ).to.be.revertedWithCustomError(inbox, 'InsufficientBatcherReward')
      expect(await mockProver.dispatched()).to.be.false
    })

    it('fulfills message bridge immediately', async () => {
      const initialBalance = await ethers.provider.getBalance(solver.address)

      const metadata = '0x1234'
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes', 'address'],
        [metadata, ethers.ZeroAddress],
      )

      fee = await mockProver.fetchFee(
        sourceChainID,
        [intentHash],
        [dstAddr.address],
        await mockProver.getAddress(),
        data,
      )

      //send exactly the fee amount
      await expect(
        inbox
          .connect(solver)
          .fulfillMessageBridge(
            route,
            rewardHash,
            dstAddr.address,
            intentHash,
            await mockProver.getAddress(),
            await mockProver.getAddress(),
            data,
            {
              value: fee,
            },
          ),
      )
        .to.emit(inbox, 'Fulfillment')
        .withArgs(intentHash, sourceChainID, dstAddr.address)

      // Verify mailbox was called with correct parameters
      expect(await mockProver.dispatched()).to.be.true
      expect(await mockProver.lastSourceChainId()).to.eq(sourceChainID)

      // Verify intent hash and claimant were correctly sent
      expect(await mockProver.lastIntentHashes(0)).to.eq(intentHash)
      expect(await mockProver.lastClaimants(0)).to.eq(dstAddr.address)
    })

    it('refunds solver when too much fee is sent', async () => {
      const metadata = '0x1234'
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes', 'address'],
        [metadata, ethers.ZeroAddress],
      )

      fee = await mockProver.fetchFee(
        sourceChainID,
        [intentHash],
        [dstAddr.address],
        await mockProver.getAddress(),
        data,
      )

      const initialSolverbalance = await ethers.provider.getBalance(
        solver.address,
      )
      const excess = ethers.parseEther('.123')

      // Using fulfillMessageBridge with excess value
      await inbox
        .connect(solver)
        .fulfillMessageBridge(
          route,
          rewardHash,
          dstAddr.address,
          intentHash,
          await mockProver.getAddress(),
          await mockProver.getAddress(),
          data,
          {
            value: fee + excess,
          },
        )

      expect(await ethers.provider.getBalance(await inbox.getAddress())).to.eq(
        0,
      )

      // Verify the solver got a refund (not checking exact amount due to gas costs)
      expect(await ethers.provider.getBalance(solver.address)).to.greaterThan(
        initialSolverbalance - excess - fee,
      )
    })

    it('should work with message bridge batched', async () => {
      let fulfillment = await inbox.fulfilled(intentHash)
      expect(fulfillment.claimant).to.equal(ethers.ZeroAddress)
      expect(fulfillment.reward).to.equal(0)

      const initBalance = await ethers.provider.getBalance(
        await inbox.getAddress(),
      )

      await expect(
        inbox
          .connect(solver)
          .fulfillMessageBridgeBatched(
            route,
            rewardHash,
            dstAddr.address,
            intentHash,
            await mockProver.getAddress(),
            await mockProver.getAddress(),
            { value: minBatcherReward * 2 },
          ),
      )
        .to.emit(inbox, 'Fulfillment')
        .withArgs(intentHash, sourceChainID, dstAddr.address)
        .to.emit(inbox, 'AddToBatch')
        .withArgs(
          intentHash,
          sourceChainID,
          dstAddr.address,
          await mockProver.getAddress(),
          await mockProver.getAddress(),
        )
      expect(await mockProver.dispatched()).to.be.false

      fulfillment = await inbox.fulfilled(intentHash)
      expect(fulfillment.claimant).to.equal(dstAddr.address)
      expect(fulfillment.reward).to.equal(2 * minBatcherReward)

      expect(await ethers.provider.getBalance(await inbox.getAddress())).to.eq(
        initBalance + BigInt(2 * minBatcherReward),
      )
    })

    context('messageBridgeSendBatch', async () => {
      it('should revert if sending a batch containing an intent that has not been fulfilled', async () => {
        const hashes: string[] = [intentHash]
        const metadata = '0x1234'
        const data = ethers.AbiCoder.defaultAbiCoder().encode(
          ['bytes', 'address'],
          [metadata, ethers.ZeroAddress],
        )

        await expect(
          inbox
            .connect(solver)
            .messageBridgeSendBatch(
              sourceChainID,
              hashes,
              await mockProver.getAddress(),
              await mockProver.getAddress(),
              data,
            ),
        )
          .to.be.revertedWithCustomError(inbox, 'IntentNotFulfilled')
          .withArgs(hashes[0])
        expect(await mockProver.dispatched()).to.be.false
      })

      it('should revert if sending a batch with too low a fee, and refund some if the msg value is greater than the fee', async () => {
        const metadata = '0x1234'
        const data = ethers.AbiCoder.defaultAbiCoder().encode(
          ['bytes', 'address'],
          [metadata, ethers.ZeroAddress],
        )

        expect(await mockProver.dispatched()).to.be.false
        await inbox
          .connect(solver)
          .fulfillMessageBridgeBatched(
            route,
            rewardHash,
            dstAddr.address,
            intentHash,
            await mockProver.getAddress(),
            await mockProver.getAddress(),
            { value: minBatcherReward },
          )
        expect(await mockProver.dispatched()).to.be.false

        fee = await mockProver.fetchFee(
          sourceChainID,
          [intentHash],
          [dstAddr.address],
          await mockProver.getAddress(),
          data,
        )

        await expect(
          inbox
            .connect(solver)
            .messageBridgeSendBatch(
              sourceChainID,
              [intentHash],
              await mockProver.getAddress(),
              await mockProver.getAddress(),
              data,
              {
                value: Number(fee) - 1,
              },
            ),
        ).to.be.revertedWithCustomError(inbox, 'InsufficientFee')

        const excess = ethers.parseEther('.123')
        const initialSolverbalance = await ethers.provider.getBalance(
          solver.address,
        )
        await expect(
          inbox
            .connect(solver)
            .messageBridgeSendBatch(
              sourceChainID,
              [intentHash],
              await mockProver.getAddress(),
              await mockProver.getAddress(),
              data,
              {
                value: fee + excess,
              },
            ),
        )
          .to.emit(inbox, 'BatchSent')
          .withArgs(intentHash, sourceChainID)
        expect(
          await ethers.provider.getBalance(await inbox.getAddress()),
        ).to.eq(0)

        // Verify solver got a refund (not checking exact amount due to gas costs)
        expect(await ethers.provider.getBalance(solver.address)).to.greaterThan(
          initialSolverbalance - fee - excess,
        )
        expect(await mockProver.dispatched()).to.be.true
      })

      it('succeeds for a single intent', async () => {
        const metadata = '0x1234'
        const data = ethers.AbiCoder.defaultAbiCoder().encode(
          ['bytes', 'address'],
          [metadata, ethers.ZeroAddress],
        )

        expect(await mockProver.dispatched()).to.be.false
        await inbox
          .connect(solver)
          .fulfillMessageBridgeBatched(
            route,
            rewardHash,
            dstAddr.address,
            intentHash,
            await mockProver.getAddress(),
            await mockProver.getAddress(),
            { value: minBatcherReward },
          )
        const initialBalance = await ethers.provider.getBalance(
          await inbox.getAddress(),
        )

        expect(await mockProver.dispatched()).to.be.false

        fee = await mockProver.fetchFee(
          sourceChainID,
          [intentHash],
          [dstAddr.address],
          await mockProver.getAddress(),
          data,
        )

        await inbox
          .connect(solver)
          .messageBridgeSendBatch(
            sourceChainID,
            [intentHash],
            await mockProver.getAddress(),
            await mockProver.getAddress(),
            data,
            {
              value: Number(fee),
            },
          ),
          expect(
            await ethers.provider.getBalance(await inbox.getAddress()),
          ).to.eq(initialBalance - BigInt(await inbox.minBatcherReward()))

        expect(await mockProver.lastSourceChainId()).to.eq(sourceChainID)

        // Verify intent hash and claimant were correctly sent
        expect(await mockProver.lastIntentHashes(0)).to.eq(intentHash)
        expect(await mockProver.lastClaimants(0)).to.eq(dstAddr.address)
        expect(await mockProver.dispatched()).to.be.true
      })

      it('succeeds for multiple intents', async () => {
        const metadata = '0x1234'
        const data = ethers.AbiCoder.defaultAbiCoder().encode(
          ['bytes', 'address'],
          [metadata, ethers.ZeroAddress],
        )

        expect(await mockProver.dispatched()).to.be.false
        const initialBalance = await ethers.provider.getBalance(
          await inbox.getAddress(),
        )

        await inbox
          .connect(solver)
          .fulfillMessageBridgeBatched(
            route,
            rewardHash,
            dstAddr.address,
            intentHash,
            await mockProver.getAddress(),
            await mockProver.getAddress(),
            { value: minBatcherReward },
          )

        const newTokenAmount = 12345
        const newTimeDelta = 1123

        ;({
          calls: otherCalls,
          route,
          reward,
          intent,
          routeHash,
          rewardHash,
          intentHash: otherHash,
        } = await createIntentData(newTokenAmount, newTimeDelta))

        await erc20.mint(solver.address, newTokenAmount)
        await erc20
          .connect(solver)
          .approve(await inbox.getAddress(), newTokenAmount)

        await inbox
          .connect(solver)
          .fulfillMessageBridgeBatched(
            route,
            rewardHash,
            dstAddr.address,
            otherHash,
            await mockProver.getAddress(),
            await mockProver.getAddress(),
            { value: minBatcherReward },
          )
        expect(await mockProver.dispatched()).to.be.false

        expect(
          await ethers.provider.getBalance(await inbox.getAddress()),
        ).to.eq(initialBalance + BigInt(2 * minBatcherReward))

        fee = await mockProver.fetchFee(
          sourceChainID,
          [intentHash, otherHash],
          [dstAddr.address, dstAddr.address],
          await mockProver.getAddress(),
          data,
        )

        await expect(
          inbox
            .connect(solver)
            .messageBridgeSendBatch(
              sourceChainID,
              [intentHash, otherHash],
              await mockProver.getAddress(),
              await mockProver.getAddress(),
              data,
              {
                value: Number(fee),
              },
            ),
        ).to.changeEtherBalance(solver, 2 * minBatcherReward - Number(fee))

        expect(await mockProver.lastSourceChainId()).to.eq(sourceChainID)

        // Verify batch intent hashes and claimants were correctly sent
        expect(await mockProver.lastIntentHashes(0)).to.eq(intentHash)
        expect(await mockProver.lastIntentHashes(1)).to.eq(otherHash)
        expect(await mockProver.lastClaimants(0)).to.eq(dstAddr.address)
        expect(await mockProver.lastClaimants(1)).to.eq(dstAddr.address)
        expect(await mockProver.dispatched()).to.be.true
      })
    })
  })
})
