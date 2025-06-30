import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import { TestERC20, TestUSDT, Inbox, TestProver } from '../typechain-types'
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

describe('Inbox Test', (): void => {
  let inbox: Inbox
  let erc20: TestERC20
  let erc20Usdt: TestUSDT
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
    erc20Usdt: TestUSDT
    owner: SignerWithAddress
    solver: SignerWithAddress
    dstAddr: SignerWithAddress
  }> {
    const [owner, solver, dstAddr] = await ethers.getSigners()
    const inboxFactory = await ethers.getContractFactory('Inbox')
    const inbox = await inboxFactory.deploy()
    // deploy ERC20 test
    const erc20Factory = await ethers.getContractFactory('TestERC20')
    const testUSDTFactory = await ethers.getContractFactory('TestUSDT')
    const erc20 = await erc20Factory.deploy('eco', 'eco')
    const erc20Usdt = await testUSDTFactory.deploy('eco', 'eco')
    await erc20.mint(solver.address, mintAmount)
    await erc20.mint(owner.address, mintAmount)

    return {
      inbox,
      erc20,
      erc20Usdt,
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
    ;({ inbox, erc20, erc20Usdt, owner, solver, dstAddr } =
      await loadFixture(deployInboxFixture))
    ;({ route, reward, rewardHash, intentHash } = await createIntentData(
      mintAmount,
      timeDelta,
    ))
    mockProver = await (
      await ethers.getContractFactory('TestProver')
    ).deploy(await inbox.getAddress())
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
            ethers.zeroPadValue(dstAddr.address, 32),
            intentHash,
            ethers.ZeroAddress,
          ),
      )
        .to.be.revertedWithCustomError(inbox, 'WrongChain')
        .withArgs(123)
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
            ethers.zeroPadValue(dstAddr.address, 32),
            goofyHash,
            ethers.ZeroAddress,
          ),
      ).to.be.revertedWithCustomError(inbox, 'InvalidHash')
    })
    it('should revert via InvalidHash if all intent data was input correctly, but the intent used a different inbox on creation', async () => {
      const anotherInbox = await (
        await ethers.getContractFactory('Inbox')
      ).deploy()

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
            ethers.zeroPadValue(dstAddr.address, 32),
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
            ethers.ZeroHash,
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
            ethers.zeroPadValue(dstAddr.address, 32),
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
            ethers.zeroPadValue(dstAddr.address, 32),
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
            ethers.zeroPadValue(dstAddr.address, 32),
            _intentHash,
            ethers.ZeroAddress,
          ),
      ).to.be.revertedWithCustomError(inbox, 'CallToProver')
    })
    it('should continue if any of the targets supports EIP165 and returns false', async () => {
      const _route = {
        ...route,
        calls: [
          {
            target: await erc20Usdt.getAddress(),
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
      ).to.not.be.revertedWithCustomError(inbox, 'CallToProver')
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
            ethers.zeroPadValue(dstAddr.address, 32),
            _intentHash,
            ethers.ZeroAddress,
          ),
      )
        .to.be.revertedWithCustomError(inbox, 'CallToEOA')
        .withArgs(solver.address)
    })

    it('should send ETH if one of the targets is an EOA', async () => {
      const ethAmount = 10000
      const _route: Route = {
        ...route,
        tokens: [],
        calls: [
          {
            target: dstAddr.address,
            data: '0x',
            value: ethAmount,
          },
        ],
      }

      // Send ETH to Inbox
      const tx = await owner.sendTransaction({
        to: await inbox.getAddress(),
        value: ethAmount,
      })
      await tx.wait()

      const { intentHash: _intentHash, rewardHash: _rewardHash } = hashIntent({
        route: _route,
        reward,
      })

      await expect(
        inbox
          .connect(solver)
          .fulfill(
            _route,
            _rewardHash,
            dstAddr.address,
            _intentHash,
            ethers.ZeroAddress,
          ),
      )
        .to.emit(inbox, 'Fulfillment')
        .withArgs(
          _intentHash,
          sourceChainID,
          ethers.ZeroAddress,
          dstAddr.address,
        )
    })

    it('should succeed with storage proving', async () => {
      let claimant = await inbox.fulfilled(intentHash)
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
            route,
            rewardHash,
            ethers.zeroPadValue(dstAddr.address, 32),
            intentHash,
            ethers.ZeroAddress,
          ),
      )
        .to.emit(inbox, 'Fulfillment')
        .withArgs(
          intentHash,
          sourceChainID,
          ethers.ZeroAddress,
          ethers.zeroPadValue(dstAddr.address, 32),
        )
      // should update the fulfilled hash
      claimant = await inbox.fulfilled(intentHash)
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
            route,
            rewardHash,
            ethers.zeroPadValue(dstAddr.address, 32),
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
            ethers.zeroPadValue(dstAddr.address, 32),
            intentHash,
            ethers.ZeroAddress,
          ),
      ).to.be.revertedWithCustomError(inbox, 'IntentAlreadyFulfilled')
    })
  })

  describe('initiateProving', async () => {
    it('gets the right args', async () => {
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
            ethers.zeroPadValue(dstAddr.address, 32),
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

  describe('fulfillAndProve', async () => {
    it('works', async () => {
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
            ethers.zeroPadValue(dstAddr.address, 32),
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

    it('should handle fulfillAndProve with non-address bytes32 claimant for cross-VM compatibility', async () => {
      // arbitrary claimant which doesn't fit into a evm address
      const nonAddressClaimant = ethers.keccak256(ethers.toUtf8Bytes("non-evm-claimant-identifier"))

      await erc20.connect(solver).approve(await inbox.getAddress(), mintAmount)
      await expect(
        inbox
          .connect(solver)
          .fulfillAndProve(
            route,
            rewardHash,
            nonAddressClaimant,
            intentHash,
            await mockProver.getAddress(),
            intentHash,
          ),
      )
        .to.emit(inbox, 'Fulfillment')
        .withArgs(
          intentHash,
          sourceChainID,
          await mockProver.getAddress(),
          nonAddressClaimant,
        )

      // Verify the non-address claimant was stored correctly
      const storedClaimant = await inbox.fulfilled(intentHash)
      expect(storedClaimant).to.equal(nonAddressClaimant)
    })
  })
})
