import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import { TestERC20, Inbox, TestProver } from '../typechain-types'
import {
  time,
  loadFixture,
} from '@nomicfoundation/hardhat-toolbox/network-helpers'
import { encodeTransfer } from '../utils/encode'
import { keccak256 } from 'ethers'
import {
  encodeReward,
  encodeRoute,
  hashIntent,
  Call,
  Route,
  Reward,
  TokenAmount,
} from '../utils/intent'
import { mock } from 'node:test'

describe('Inbox Test', (): void => {
  let inbox: Inbox
  let erc20: TestERC20
  let owner: SignerWithAddress
  let solver: SignerWithAddress
  let dstAddr: SignerWithAddress
  let route: Route
  let reward: Reward
  let rewardHash: string
  let intentHash: string
  let otherHash: string
  let routeTokens: TokenAmount[]
  let mockProver: TestProver
  const salt = ethers.encodeBytes32String('0x987')
  let erc20Address: string
  const timeDelta = 1000
  const mintAmount = 1000
  const sourceChainID = 123
  let fee: BigInt

  async function deployInboxFixture(): Promise<{
    inbox: Inbox
    erc20: TestERC20
    owner: SignerWithAddress
    solver: SignerWithAddress
    dstAddr: SignerWithAddress
  }> {
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
    route: Route
    reward: Reward
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

    const _intentHash = keccak256(
      ethers.solidityPacked(['bytes32', 'bytes32'], [_routeHash, _rewardHash]),
    )

    return {
      route: _route,
      reward: _reward,
      rewardHash: _rewardHash,
      intentHash: _intentHash,
    }
  }
  beforeEach(async (): Promise<void> => {
    ;({ inbox, erc20, owner, solver, dstAddr } =
      await loadFixture(deployInboxFixture))
    ;({ route, reward, rewardHash, intentHash } = await createIntentData(
      mintAmount,
      timeDelta,
    ))
    mockProver = await (
      await ethers.getContractFactory('TestProver')
    ).deploy(await inbox.getAddress())
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
  })

  describe('fulfill when the intent is invalid', () => {
    it('should revert if fulfillment is attempted on an incorrect destination chain', async () => {
      route.destination = 123
      await expect(
        inbox
          .connect(owner)
          .fulfill(
            route,
            rewardHash,
            dstAddr.address,
            intentHash,
            ethers.ZeroAddress,
          ),
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
          .fulfill(
            route,
            rewardHash,
            dstAddr.address,
            intentHash,
            ethers.ZeroAddress,
          ),
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
          .fulfill(
            route,
            rewardHash,
            dstAddr.address,
            goofyHash,
            ethers.ZeroAddress,
          ),
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
          .fulfill(
            _route,
            rewardHash,
            dstAddr.address,
            _intentHash,
            ethers.ZeroAddress,
          ),
      ).to.be.revertedWithCustomError(inbox, 'InvalidInbox')
    })
  })

  describe('fulfill when the intent is valid', () => {
    it('should revert if claimant is zero address', async () => {
      await expect(
        inbox
          .connect(solver)
          .fulfill(
            route,
            rewardHash,
            ethers.ZeroAddress,
            intentHash,
            ethers.ZeroAddress,
          ),
      ).to.be.revertedWithCustomError(inbox, 'ZeroClaimant')
    })
    it('should revert if the solver has not approved tokens for transfer', async () => {
      await expect(
        inbox
          .connect(solver)
          .fulfill(
            route,
            rewardHash,
            dstAddr.address,
            intentHash,
            ethers.ZeroAddress,
          ),
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
          .fulfill(
            _route,
            rewardHash,
            dstAddr.address,
            _intentHash,
            ethers.ZeroAddress,
          ),
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
          .fulfill(
            _route,
            rewardHash,
            dstAddr.address,
            _intentHash,
            ethers.ZeroAddress,
          ),
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
          .fulfill(
            _route,
            rewardHash,
            dstAddr.address,
            _intentHash,
            ethers.ZeroAddress,
          ),
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
          .fulfill(
            route,
            rewardHash,
            dstAddr.address,
            intentHash,
            ethers.ZeroAddress,
          ),
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
          .fulfill(
            route,
            rewardHash,
            dstAddr.address,
            intentHash,
            ethers.ZeroAddress,
          ),
      ).to.not.be.reverted
    })

    it('should succeed with storage proving', async () => {
      let claimant = await inbox.fulfilled(intentHash)
      expect(claimant).to.equal(ethers.ZeroAddress)

      expect(await erc20.balanceOf(solver.address)).to.equal(mintAmount)
      expect(await erc20.balanceOf(dstAddr.address)).to.equal(0)

      // transfer the tokens to the inbox so it can process the transaction
      await erc20.connect(solver).approve(await inbox.getAddress(), mintAmount)

      // should emit an event
      await expect(
        inbox
          .connect(solver)
          .fulfill(
            route,
            rewardHash,
            dstAddr.address,
            intentHash,
            ethers.ZeroAddress,
          ),
      )
        .to.emit(inbox, 'Fulfillment')
        .withArgs(
          intentHash,
          sourceChainID,
          ethers.ZeroAddress,
          dstAddr.address,
        )
      // should update the fulfilled hash
      claimant = await inbox.fulfilled(intentHash)
      expect(claimant).to.equal(dstAddr.address)

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
            route,
            rewardHash,
            dstAddr.address,
            intentHash,
            ethers.ZeroAddress,
          ),
      ).to.not.be.reverted
      // should revert
      await expect(
        inbox
          .connect(solver)
          .fulfill(
            route,
            rewardHash,
            dstAddr.address,
            intentHash,
            ethers.ZeroAddress,
          ),
      ).to.be.revertedWithCustomError(inbox, 'IntentAlreadyFulfilled')
    })
  })

  describe('fulfillAndProve', async () => {
    it('works', async () => {
      expect(await inbox.solverWhitelist(solver)).to.be.true

      await erc20.connect(solver).approve(await inbox.getAddress(), mintAmount)

      const theArgs = [
        '0x70997970C51812dc3A010C7d01b50e0d17dc79C8',
        123n,
        intentHash,
        123456789n,
      ]

      expect(await mockProver.args()).to.not.deep.equal(theArgs)

      await expect(
        inbox
          .connect(solver)
          .fulfillAndProve(
            route,
            rewardHash,
            dstAddr.address,
            intentHash,
            await mockProver.getAddress(),
            intentHash,
          ),
      ).to.not.be.reverted

      await inbox
        .connect(solver)
        .initiateProving(
          route.source,
          [intentHash],
          await mockProver.getAddress(),
          intentHash,
          { value: 123456789 },
        )
      expect(await mockProver.args()).to.deep.equal(theArgs)
    })
  })

  describe('initiateProving', async () => {
    it('gets the right args', async () => {
      expect(await inbox.solverWhitelist(solver)).to.be.true

      await erc20.connect(solver).approve(await inbox.getAddress(), mintAmount)

      const theArgs = [
        '0x70997970C51812dc3A010C7d01b50e0d17dc79C8',
        123n,
        intentHash,
        123456789n,
      ]
      await expect(
        inbox
          .connect(solver)
          .fulfill(
            route,
            rewardHash,
            dstAddr.address,
            intentHash,
            await mockProver.getAddress(),
          ),
      ).to.not.be.reverted

      expect(await mockProver.args()).to.not.deep.equal(theArgs)

      await inbox
        .connect(solver)
        .initiateProving(
          route.source,
          [intentHash],
          await mockProver.getAddress(),
          intentHash,
          { value: 123456789 },
        )
      expect(await mockProver.args()).to.deep.equal(theArgs)
    })
  })

  //   describe('message bridge proving', () => {
  //     beforeEach(async () => {
  //       expect(await mockProver.dispatched()).to.be.false

  //       await erc20.connect(solver).approve(await inbox.getAddress(), mintAmount)
  //     })

  //     it('should fail to fulfill message bridge if the fee is too low', async () => {
  //       const metadata = '0x1234'
  //       const data = ethers.AbiCoder.defaultAbiCoder().encode(
  //         ['bytes', 'address'],
  //         [metadata, ethers.ZeroAddress],
  //       )

  //       // Get fee value
  //       fee = await mockProver.fetchFee(
  //         sourceChainID,
  //         [intentHash],
  //         [dstAddr.address],
  //         await mockProver.getAddress(),
  //         data,
  //       )

  //       expect(await mockProver.dispatched()).to.be.false
  //       await expect(
  //         inbox
  //           .connect(solver)
  //           .fulfillMessageBridge(
  //             route,
  //             rewardHash,
  //             dstAddr.address,
  //             intentHash,
  //             await mockProver.getAddress(),
  //             await mockProver.getAddress(),
  //             data,
  //             {
  //               value: Number(fee) - 1,
  //             },
  //           ),
  //       ).to.be.revertedWithCustomError(inbox, 'InsufficientFee')
  //       expect(await mockProver.dispatched()).to.be.false
  //     })

  //     it('fulfills message bridge immediately', async () => {
  //       const initialBalance = await ethers.provider.getBalance(solver.address)

  //       const metadata = '0x1234'
  //       const data = ethers.AbiCoder.defaultAbiCoder().encode(
  //         ['bytes', 'address'],
  //         [metadata, ethers.ZeroAddress],
  //       )

  //       fee = await mockProver.fetchFee(
  //         sourceChainID,
  //         [intentHash],
  //         [dstAddr.address],
  //         await mockProver.getAddress(),
  //         data,
  //       )

  //       //send exactly the fee amount
  //       await expect(
  //         inbox
  //           .connect(solver)
  //           .fulfillMessageBridge(
  //             route,
  //             rewardHash,
  //             dstAddr.address,
  //             intentHash,
  //             await mockProver.getAddress(),
  //             await mockProver.getAddress(),
  //             data,
  //             {
  //               value: fee,
  //             },
  //           ),
  //       )
  //         .to.emit(inbox, 'Fulfillment')
  //         .withArgs(intentHash, sourceChainID, dstAddr.address)

  //       // Verify mailbox was called with correct parameters
  //       expect(await mockProver.dispatched()).to.be.true
  //       expect(await mockProver.lastSourceChainId()).to.eq(sourceChainID)

  //       // Verify intent hash and claimant were correctly sent
  //       expect(await mockProver.lastIntentHashes(0)).to.eq(intentHash)
  //       expect(await mockProver.lastClaimants(0)).to.eq(dstAddr.address)
  //     })

  //     it('refunds solver when too much fee is sent', async () => {
  //       const metadata = '0x1234'
  //       const data = ethers.AbiCoder.defaultAbiCoder().encode(
  //         ['bytes', 'address'],
  //         [metadata, ethers.ZeroAddress],
  //       )

  //       fee = await mockProver.fetchFee(
  //         sourceChainID,
  //         [intentHash],
  //         [dstAddr.address],
  //         await mockProver.getAddress(),
  //         data,
  //       )

  //       const initialSolverbalance = await ethers.provider.getBalance(
  //         solver.address,
  //       )
  //       const excess = ethers.parseEther('.123')

  //       // Using fulfillMessageBridge with excess value
  //       await inbox
  //         .connect(solver)
  //         .fulfillMessageBridge(
  //           route,
  //           rewardHash,
  //           dstAddr.address,
  //           intentHash,
  //           await mockProver.getAddress(),
  //           await mockProver.getAddress(),
  //           data,
  //           {
  //             value: fee + excess,
  //           },
  //         )

  //       expect(await ethers.provider.getBalance(await inbox.getAddress())).to.eq(
  //         0,
  //       )

  //       // Verify the solver got a refund (not checking exact amount due to gas costs)
  //       expect(await ethers.provider.getBalance(solver.address)).to.greaterThan(
  //         initialSolverbalance - excess - fee,
  //       )
  //     })

  //     it('should work with message bridge batched', async () => {
  //       let claimant = await inbox.fulfilled(intentHash)
  //       expect(claimant).to.equal(ethers.ZeroAddress)

  //       await expect(
  //         inbox
  //           .connect(solver)
  //           .fulfillMessageBridgeBatched(
  //             route,
  //             rewardHash,
  //             dstAddr.address,
  //             intentHash,
  //             await mockProver.getAddress(),
  //             await mockProver.getAddress(),
  //           ),
  //       )
  //         .to.emit(inbox, 'Fulfillment')
  //         .withArgs(intentHash, sourceChainID, dstAddr.address)
  //         .to.emit(inbox, 'AddToBatch')
  //         .withArgs(
  //           intentHash,
  //           sourceChainID,
  //           dstAddr.address,
  //           await mockProver.getAddress(),
  //           await mockProver.getAddress(),
  //         )
  //       expect(await mockProver.dispatched()).to.be.false

  //       claimant = await inbox.fulfilled(intentHash)
  //       expect(claimant).to.equal(dstAddr.address)
  //     })

  //     context('sendFulfilled', async () => {
  //       it('should revert if sending a batch containing an intent that has not been fulfilled', async () => {
  //         const hashes: string[] = [intentHash]
  //         const metadata = '0x1234'
  //         const data = ethers.AbiCoder.defaultAbiCoder().encode(
  //           ['bytes', 'address'],
  //           [metadata, ethers.ZeroAddress],
  //         )

  //         await expect(
  //           inbox
  //             .connect(solver)
  //             .sendFulfilled(
  //               sourceChainID,
  //               hashes,
  //               await mockProver.getAddress(),
  //               await mockProver.getAddress(),
  //               data,
  //             ),
  //         )
  //           .to.be.revertedWithCustomError(inbox, 'IntentNotFulfilled')
  //           .withArgs(hashes[0])
  //         expect(await mockProver.dispatched()).to.be.false
  //       })

  //       it('should revert if sending a batch with too low a fee, and refund some if the msg value is greater than the fee', async () => {
  //         const metadata = '0x1234'
  //         const data = ethers.AbiCoder.defaultAbiCoder().encode(
  //           ['bytes', 'address'],
  //           [metadata, ethers.ZeroAddress],
  //         )

  //         expect(await mockProver.dispatched()).to.be.false
  //         await inbox
  //           .connect(solver)
  //           .fulfillMessageBridgeBatched(
  //             route,
  //             rewardHash,
  //             dstAddr.address,
  //             intentHash,
  //             await mockProver.getAddress(),
  //             await mockProver.getAddress(),
  //           )
  //         expect(await mockProver.dispatched()).to.be.false

  //         fee = await mockProver.fetchFee(
  //           sourceChainID,
  //           [intentHash],
  //           [dstAddr.address],
  //           await mockProver.getAddress(),
  //           data,
  //         )

  //         await expect(
  //           inbox
  //             .connect(solver)
  //             .sendFulfilled(
  //               sourceChainID,
  //               [intentHash],
  //               await mockProver.getAddress(),
  //               await mockProver.getAddress(),
  //               data,
  //               {
  //                 value: Number(fee) - 1,
  //               },
  //             ),
  //         ).to.be.revertedWithCustomError(inbox, 'InsufficientFee')

  //         const excess = ethers.parseEther('.123')
  //         const initialSolverbalance = await ethers.provider.getBalance(
  //           solver.address,
  //         )
  //         await expect(
  //           inbox
  //             .connect(solver)
  //             .sendFulfilled(
  //               sourceChainID,
  //               [intentHash],
  //               await mockProver.getAddress(),
  //               await mockProver.getAddress(),
  //               data,
  //               {
  //                 value: fee + excess,
  //               },
  //             ),
  //         )
  //           .to.emit(inbox, 'BatchSent')
  //           .withArgs(intentHash, sourceChainID)
  //         expect(
  //           await ethers.provider.getBalance(await inbox.getAddress()),
  //         ).to.eq(0)

  //         // Verify solver got a refund (not checking exact amount due to gas costs)
  //         expect(await ethers.provider.getBalance(solver.address)).to.greaterThan(
  //           initialSolverbalance - fee - excess,
  //         )
  //         expect(await mockProver.dispatched()).to.be.true
  //       })

  //       it('succeeds for a single intent', async () => {
  //         const metadata = '0x1234'
  //         const data = ethers.AbiCoder.defaultAbiCoder().encode(
  //           ['bytes', 'address'],
  //           [metadata, ethers.ZeroAddress],
  //         )

  //         expect(await mockProver.dispatched()).to.be.false
  //         await inbox
  //           .connect(solver)
  //           .fulfillMessageBridgeBatched(
  //             route,
  //             rewardHash,
  //             dstAddr.address,
  //             intentHash,
  //             await mockProver.getAddress(),
  //             await mockProver.getAddress(),
  //           )
  //         const initialBalance = await ethers.provider.getBalance(
  //           await inbox.getAddress(),
  //         )

  //         expect(await mockProver.dispatched()).to.be.false

  //         fee = await mockProver.fetchFee(
  //           sourceChainID,
  //           [intentHash],
  //           [dstAddr.address],
  //           await mockProver.getAddress(),
  //           data,
  //         )

  //         await inbox
  //           .connect(solver)
  //           .sendFulfilled(
  //             sourceChainID,
  //             [intentHash],
  //             await mockProver.getAddress(),
  //             await mockProver.getAddress(),
  //             data,
  //             {
  //               value: Number(fee),
  //             },
  //           )

  //         expect(await mockProver.lastSourceChainId()).to.eq(sourceChainID)

  //         // Verify intent hash and claimant were correctly sent
  //         expect(await mockProver.lastIntentHashes(0)).to.eq(intentHash)
  //         expect(await mockProver.lastClaimants(0)).to.eq(dstAddr.address)
  //         expect(await mockProver.dispatched()).to.be.true
  //       })

  //       it('succeeds for multiple intents', async () => {
  //         const metadata = '0x1234'
  //         const data = ethers.AbiCoder.defaultAbiCoder().encode(
  //           ['bytes', 'address'],
  //           [metadata, ethers.ZeroAddress],
  //         )

  //         expect(await mockProver.dispatched()).to.be.false

  //         await inbox
  //           .connect(solver)
  //           .fulfillMessageBridgeBatched(
  //             route,
  //             rewardHash,
  //             dstAddr.address,
  //             intentHash,
  //             await mockProver.getAddress(),
  //             await mockProver.getAddress(),
  //           )

  //         const newTokenAmount = 12345
  //         const newTimeDelta = 1123

  //         ;({
  //           route,
  //           reward,
  //           rewardHash,
  //           intentHash: otherHash,
  //         } = await createIntentData(newTokenAmount, newTimeDelta))

  //         await erc20.mint(solver.address, newTokenAmount)
  //         await erc20
  //           .connect(solver)
  //           .approve(await inbox.getAddress(), newTokenAmount)

  //         await inbox
  //           .connect(solver)
  //           .fulfillMessageBridgeBatched(
  //             route,
  //             rewardHash,
  //             dstAddr.address,
  //             otherHash,
  //             await mockProver.getAddress(),
  //             await mockProver.getAddress(),
  //           )
  //         expect(await mockProver.dispatched()).to.be.false

  //         fee = await mockProver.fetchFee(
  //           sourceChainID,
  //           [intentHash, otherHash],
  //           [dstAddr.address, dstAddr.address],
  //           await mockProver.getAddress(),
  //           data,
  //         )

  //         await expect(
  //           inbox
  //             .connect(solver)
  //             .sendFulfilled(
  //               sourceChainID,
  //               [intentHash, otherHash],
  //               await mockProver.getAddress(),
  //               await mockProver.getAddress(),
  //               data,
  //               {
  //                 value: Number(fee),
  //               },
  //             ),
  //         ).to.changeEtherBalance(solver, -Number(fee))

  //         expect(await mockProver.lastSourceChainId()).to.eq(sourceChainID)

  //         // Verify batch intent hashes and claimants were correctly sent
  //         expect(await mockProver.lastIntentHashes(0)).to.eq(intentHash)
  //         expect(await mockProver.lastIntentHashes(1)).to.eq(otherHash)
  //         expect(await mockProver.lastClaimants(0)).to.eq(dstAddr.address)
  //         expect(await mockProver.lastClaimants(1)).to.eq(dstAddr.address)
  //         expect(await mockProver.dispatched()).to.be.true
  //       })
  //     })
  //   })
})
