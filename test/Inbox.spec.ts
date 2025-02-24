import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import { TestERC20, Inbox, TestMailbox, TestProver } from '../typechain-types'
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
  let mockHyperProver: TestProver
  const salt = ethers.encodeBytes32String('0x987')
  let erc20Address: string
  const timeDelta = 1000
  const mintAmount = 1000
  const sourceChainID = 123

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
    const inbox = await inboxFactory.deploy(owner.address, false, [
      solver.address,
    ])
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
        inbox.connect(solver).setMailbox(await mailbox.getAddress()),
      ).to.be.revertedWithCustomError(inbox, 'OwnableUnauthorizedAccount')
    })
    it('lets owner make solving public', async () => {
      expect(await inbox.isSolvingPublic()).to.be.false
      await inbox.connect(owner).makeSolvingPublic()
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

    it('lets owner set mailbox, but only when it is the zero addreses', async () => {
      expect(await inbox.mailbox()).to.eq(ethers.ZeroAddress)
      expect(await inbox.connect(owner).setMailbox(await mailbox.getAddress()))
        .to.emit(inbox, 'MailboxSet')
        .withArgs(await mailbox.getAddress())
      expect(await inbox.mailbox()).to.eq(await mailbox.getAddress())
      await inbox.connect(owner).setMailbox(solver.address)
      expect(await inbox.mailbox()).to.eq(await mailbox.getAddress())
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
      ).deploy(owner.address, false, [owner.address])

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
    it('should revert if any of the targets is the mailbox', async () => {
      await inbox.connect(owner).setMailbox(await mailbox.getAddress())
      const _route = {
        ...route,
        calls: [
          {
            target: await mailbox.getAddress(),
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
      ).to.be.revertedWithCustomError(inbox, 'CallToMailbox')
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
        ).to.be.revertedWithCustomError(inbox, 'CallToEOA')
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

    it('should succeed with non-hyper proving', async () => {
      expect(await inbox.fulfilled(intentHash)).to.equal(ethers.ZeroAddress)
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
      expect(await inbox.fulfilled(intentHash)).to.equal(dstAddr.address)

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
  describe('hyper proving', () => {
    beforeEach(async () => {
      mockHyperProver = await (
        await ethers.getContractFactory('TestProver')
      ).deploy()
      await inbox.connect(owner).setMailbox(await mailbox.getAddress())
      expect(await mailbox.dispatched()).to.be.false

      await erc20.connect(solver).approve(await inbox.getAddress(), mintAmount)
    })
    it('fetches the fee', async () => {
      expect(
        await inbox.fetchFee(
          sourceChainID,
          ethers.zeroPadBytes(await mockHyperProver.getAddress(), 32),
          calls[0].data,
          calls[0].data,
          ethers.ZeroAddress,
        ),
      ).to.eq(toBeHex(`100000`, 32))
    })
    it('fails to fulfill hyper instant if the fee is too low', async () => {
      expect(await mailbox.dispatched()).to.be.false
      await expect(
        inbox
          .connect(solver)
          .fulfillHyperInstant(
            route,
            rewardHash,
            dstAddr.address,
            intentHash,
            await mockHyperProver.getAddress(),
            {
              value:
                Number(
                  await inbox.fetchFee(
                    sourceChainID,
                    ethers.zeroPadBytes(await mockHyperProver.getAddress(), 32),
                    calls[0].data,
                    calls[0].data,
                    ethers.ZeroAddress,
                  ),
                ) - 1,
            },
          ),
      ).to.be.revertedWithCustomError(inbox, 'InsufficientFee')
      expect(await mailbox.dispatched()).to.be.false
    })
    it('fulfills hyper instant', async () => {
      const initialBalance = await ethers.provider.getBalance(solver.address)

      const feeAmount = await inbox.fetchFee(
        sourceChainID,
        ethers.zeroPadBytes(await mockHyperProver.getAddress(), 32),
        calls[0].data,
        calls[0].data,
        ethers.ZeroAddress,
      )
      //send too much fee
      await expect(
        inbox
          .connect(solver)
          .fulfillHyperInstant(
            route,
            rewardHash,
            dstAddr.address,
            intentHash,
            await mockHyperProver.getAddress(),
            {
              value: feeAmount + ethers.parseEther('.1'),
            },
          ),
      )
        .to.emit(inbox, 'Fulfillment')
        .withArgs(intentHash, sourceChainID, dstAddr.address)
        .to.emit(inbox, 'HyperInstantFulfillment')
        .withArgs(intentHash, sourceChainID, dstAddr.address)
      //does extra fee come back?
      expect(
        (await ethers.provider.getBalance(solver.address)) >
          initialBalance - feeAmount - ethers.parseEther('.1'),
      ).to.be.true

      expect(await mailbox.destinationDomain()).to.eq(sourceChainID)
      expect(await mailbox.recipientAddress()).to.eq(
        ethers.zeroPadValue(await mockHyperProver.getAddress(), 32),
      )
      expect(await mailbox.messageBody()).to.eq(
        ethers.AbiCoder.defaultAbiCoder().encode(
          ['bytes32[]', 'address[]'],
          [[intentHash], [dstAddr.address]],
        ),
      )
      expect(await mailbox.dispatched()).to.be.true
    })
    it('fulfills hyper instant with relayer', async () => {
      const relayerAddress = ethers.Wallet.createRandom().address
      await expect(
        inbox
          .connect(solver)
          .fulfillHyperInstantWithRelayer(
            route,
            rewardHash,
            dstAddr.address,
            intentHash,
            await mockHyperProver.getAddress(),
            calls[0].data,
            relayerAddress,
            {
              value: Number(
                await inbox.fetchFee(
                  sourceChainID,
                  ethers.zeroPadBytes(await mockHyperProver.getAddress(), 32),
                  calls[0].data,
                  calls[0].data,
                  relayerAddress,
                ),
              ),
            },
          ),
      )
        .to.emit(inbox, 'Fulfillment')
        .withArgs(intentHash, sourceChainID, dstAddr.address)
        .to.emit(inbox, 'HyperInstantFulfillment')
        .withArgs(intentHash, sourceChainID, dstAddr.address)

      expect(await mailbox.destinationDomain()).to.eq(sourceChainID)
      expect(await mailbox.recipientAddress()).to.eq(
        ethers.zeroPadValue(await mockHyperProver.getAddress(), 32),
      )
      expect(await mailbox.messageBody()).to.eq(
        ethers.AbiCoder.defaultAbiCoder().encode(
          ['bytes32[]', 'address[]'],
          [[intentHash], [dstAddr.address]],
        ),
      )
      expect(await mailbox.metadata()).to.eq(calls[0].data)
      expect(await mailbox.relayer()).to.eq(relayerAddress)
      expect(await mailbox.dispatchedWithRelayer()).to.be.true
    })

    it('fulfills hyper batch', async () => {
      await expect(
        inbox
          .connect(solver)
          .fulfillHyperBatched(
            route,
            rewardHash,
            dstAddr.address,
            intentHash,
            await mockHyperProver.getAddress(),
          ),
      )
        .to.emit(inbox, 'Fulfillment')
        .withArgs(intentHash, sourceChainID, dstAddr.address)
        .to.emit(inbox, 'AddToBatch')
        .withArgs(
          intentHash,
          sourceChainID,
          dstAddr.address,
          await mockHyperProver.getAddress(),
        )

      expect(await mailbox.dispatched()).to.be.false
    })
    it('refunds solver when too much fee is sent', async () => {
      const fee = await inbox.fetchFee(
        sourceChainID,
        ethers.zeroPadBytes(await mockHyperProver.getAddress(), 32),
        calls[0].data,
        calls[0].data,
        ethers.ZeroAddress,
      )
      const initialSolverbalance = await ethers.provider.getBalance(
        solver.address,
      )
      const excess = ethers.parseEther('.123')
      await inbox
        .connect(solver)
        .fulfillHyperInstant(
          route,
          rewardHash,
          dstAddr.address,
          intentHash,
          await mockHyperProver.getAddress(),
          {
            value: fee + excess,
          },
        )
      expect(await ethers.provider.getBalance(await inbox.getAddress())).to.eq(
        0,
      )
      // not bothered about the gas accounting, if its more than this then there was a refund, going to assume its the right amount.
      expect(await ethers.provider.getBalance(solver.address)).to.greaterThan(
        initialSolverbalance - excess,
      )
    })
    context('sendBatch', async () => {
      it('should revert if sending a batch containing an intent that has not been fulfilled', async () => {
        const hashes: string[] = [intentHash]
        await expect(
          inbox
            .connect(solver)
            .sendBatch(
              sourceChainID,
              await mockHyperProver.getAddress(),
              hashes,
            ),
        )
          .to.be.revertedWithCustomError(inbox, 'IntentNotFulfilled')
          .withArgs(hashes[0])
        expect(await mailbox.dispatched()).to.be.false
      })
      it('should revert if sending a batch with too low a fee, and refund some if the msg value is greater than the fee', async () => {
        expect(await mailbox.dispatched()).to.be.false
        await inbox
          .connect(solver)
          .fulfillHyperBatched(
            route,
            rewardHash,
            dstAddr.address,
            intentHash,
            await mockHyperProver.getAddress(),
          )
        expect(await mailbox.dispatched()).to.be.false
        await expect(
          inbox
            .connect(solver)
            .sendBatch(
              sourceChainID,
              await mockHyperProver.getAddress(),
              [intentHash],
              {
                value:
                  Number(
                    await inbox.fetchFee(
                      sourceChainID,
                      ethers.zeroPadBytes(
                        await mockHyperProver.getAddress(),
                        32,
                      ),
                      calls[0].data,
                      calls[0].data,
                      ethers.ZeroAddress,
                    ),
                  ) - 1,
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
            .sendBatch(
              sourceChainID,
              await mockHyperProver.getAddress(),
              [intentHash],
              {
                value:
                  Number(
                    await inbox.fetchFee(
                      sourceChainID,
                      ethers.zeroPadBytes(
                        await mockHyperProver.getAddress(),
                        32,
                      ),
                      calls[0].data,
                      calls[0].data,
                      ethers.ZeroAddress,
                    ),
                  ) + 1,
              },
            ),
        ).to.not.be.reverted
        expect(
          await ethers.provider.getBalance(await inbox.getAddress()),
        ).to.eq(0)
        expect(await ethers.provider.getBalance(solver.address)).to.greaterThan(
          initialSolverbalance - excess,
        )
        expect(await mailbox.dispatched()).to.be.true
      })
      it('succeeds for a single intent', async () => {
        expect(await mailbox.dispatched()).to.be.false
        await inbox
          .connect(solver)
          .fulfillHyperBatched(
            route,
            rewardHash,
            dstAddr.address,
            intentHash,
            await mockHyperProver.getAddress(),
          )
        expect(await mailbox.dispatched()).to.be.false
        await expect(
          inbox
            .connect(solver)
            .sendBatch(
              sourceChainID,
              await mockHyperProver.getAddress(),
              [intentHash],
              {
                value: Number(
                  await inbox.fetchFee(
                    sourceChainID,
                    ethers.zeroPadBytes(await mockHyperProver.getAddress(), 32),
                    calls[0].data,
                    calls[0].data,
                    ethers.ZeroAddress,
                  ),
                ),
              },
            ),
        )
          .to.emit(inbox, 'BatchSent')
          .withArgs(intentHash, sourceChainID)
        expect(await mailbox.destinationDomain()).to.eq(sourceChainID)
        expect(await mailbox.recipientAddress()).to.eq(
          ethers.zeroPadValue(await mockHyperProver.getAddress(), 32),
        )
        expect(await mailbox.messageBody()).to.eq(
          ethers.AbiCoder.defaultAbiCoder().encode(
            ['bytes32[]', 'address[]'],
            [[intentHash], [dstAddr.address]],
          ),
        )
        expect(await mailbox.dispatched()).to.be.true
      })
      it('succeeds for a single intent with relayer', async () => {
        const relayerAddress = ethers.Wallet.createRandom().address
        expect(await mailbox.dispatched()).to.be.false
        await inbox
          .connect(solver)
          .fulfillHyperBatched(
            route,
            rewardHash,
            dstAddr.address,
            intentHash,
            await mockHyperProver.getAddress(),
          )
        expect(await mailbox.dispatched()).to.be.false
        await expect(
          inbox
            .connect(solver)
            .sendBatchWithRelayer(
              sourceChainID,
              await mockHyperProver.getAddress(),
              [intentHash],
              calls[0].data,
              relayerAddress,
              {
                value: Number(
                  await inbox.fetchFee(
                    sourceChainID,
                    ethers.zeroPadBytes(await mockHyperProver.getAddress(), 32),
                    calls[0].data,
                    calls[0].data,
                    ethers.ZeroAddress,
                  ),
                ),
              },
            ),
        ).to.not.be.reverted
        expect(await mailbox.destinationDomain()).to.eq(sourceChainID)
        expect(await mailbox.recipientAddress()).to.eq(
          ethers.zeroPadValue(await mockHyperProver.getAddress(), 32),
        )
        expect(await mailbox.messageBody()).to.eq(
          ethers.AbiCoder.defaultAbiCoder().encode(
            ['bytes32[]', 'address[]'],
            [[intentHash], [dstAddr.address]],
          ),
        )
        expect(await mailbox.metadata()).to.eq(calls[0].data)
        expect(await mailbox.relayer()).to.eq(relayerAddress)
        expect(await mailbox.dispatchedWithRelayer()).to.be.true
      })
      it('succeeds for multiple intents', async () => {
        expect(await mailbox.dispatched()).to.be.false
        await inbox
          .connect(solver)
          .fulfillHyperBatched(
            route,
            rewardHash,
            dstAddr.address,
            intentHash,
            await mockHyperProver.getAddress(),
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
          .fulfillHyperBatched(
            route,
            rewardHash,
            dstAddr.address,
            otherHash,
            await mockHyperProver.getAddress(),
          )
        expect(await mailbox.dispatched()).to.be.false

        await expect(
          inbox
            .connect(solver)
            .sendBatch(
              sourceChainID,
              await mockHyperProver.getAddress(),
              [intentHash, otherHash],
              {
                value: Number(
                  await inbox.fetchFee(
                    sourceChainID,
                    ethers.zeroPadBytes(await mockHyperProver.getAddress(), 32),
                    otherCalls[0].data,
                    otherCalls[0].data,
                    ethers.ZeroAddress,
                  ),
                ),
              },
            ),
        ).to.not.be.reverted
        expect(await mailbox.destinationDomain()).to.eq(sourceChainID)
        expect(await mailbox.recipientAddress()).to.eq(
          ethers.zeroPadValue(await mockHyperProver.getAddress(), 32),
        )
        expect(await mailbox.messageBody()).to.eq(
          ethers.AbiCoder.defaultAbiCoder().encode(
            ['bytes32[]', 'address[]'],
            [
              [intentHash, otherHash],
              [dstAddr.address, dstAddr.address],
            ],
          ),
        )
        expect(await mailbox.dispatched()).to.be.true
      })
    })
  })
})
