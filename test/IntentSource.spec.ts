import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import { TestERC20, IntentSource, TestProver, Inbox } from '../typechain-types'
import { time, loadFixture } from '@nomicfoundation/hardhat-network-helpers'
import { keccak256, BytesLike } from 'ethers'
import { encodeIdentifier, encodeTransfer } from '../utils/encode'
import {
  encodeReward,
  encodeRoute,
  hashIntent,
  Call,
  TokenAmount,
  Route,
  Reward,
  Intent,
} from './utils'

describe('Intent Source Test', (): void => {
  let intentSource: IntentSource
  let prover: TestProver
  let inbox: Inbox
  let tokenA: TestERC20
  let tokenB: TestERC20
  let creator: SignerWithAddress
  let claimant: SignerWithAddress
  let otherPerson: SignerWithAddress
  const mintAmount: number = 1000

  let nonce: BytesLike
  let chainId: number
  let calls: Call[]
  let expiry: number
  const rewardNativeEth: bigint = ethers.parseEther('2')
  let rewardTokens: TokenAmount[]
  let route: Route
  let reward: Reward
  let intent: Intent
  let routeHash: BytesLike
  let rewardHash: BytesLike
  let intentHash: BytesLike

  async function deploySourceFixture(): Promise<{
    intentSource: IntentSource
    prover: TestProver
    tokenA: TestERC20
    tokenB: TestERC20
    creator: SignerWithAddress
    claimant: SignerWithAddress
    otherPerson: SignerWithAddress
  }> {
    const [creator, owner, claimant, otherPerson] = await ethers.getSigners()
    // deploy prover
    prover = await (await ethers.getContractFactory('TestProver')).deploy()

    const intentSourceFactory = await ethers.getContractFactory('IntentSource')
    const intentSource = await intentSourceFactory.deploy()
    inbox = await (
      await ethers.getContractFactory('Inbox')
    ).deploy(owner.address, false, [owner.address])

    // deploy ERC20 test
    const erc20Factory = await ethers.getContractFactory('TestERC20')
    const tokenA = await erc20Factory.deploy('A', 'A')
    const tokenB = await erc20Factory.deploy('B', 'B')

    return {
      intentSource,
      prover,
      tokenA,
      tokenB,
      creator,
      claimant,
      otherPerson,
    }
  }

  async function mintAndApprove() {
    await tokenA.connect(creator).mint(creator.address, mintAmount)
    await tokenB.connect(creator).mint(creator.address, mintAmount * 2)

    await tokenA.connect(creator).approve(intentSource, mintAmount)
    await tokenB.connect(creator).approve(intentSource, mintAmount * 2)
  }

  beforeEach(async (): Promise<void> => {
    ;({ intentSource, prover, tokenA, tokenB, creator, claimant, otherPerson } =
      await loadFixture(deploySourceFixture))

    // fund the creator and approve it to create an intent
    await mintAndApprove()
  })

  describe('intent creation', async () => {
    beforeEach(async (): Promise<void> => {
      expiry = (await time.latest()) + 123
      chainId = 1
      calls = [
        {
          target: await tokenA.getAddress(),
          data: await encodeTransfer(creator.address, mintAmount),
          value: 0,
        },
      ]
      rewardTokens = [
        { token: await tokenA.getAddress(), amount: mintAmount },
        { token: await tokenB.getAddress(), amount: mintAmount * 2 },
      ]
      nonce = await encodeIdentifier(
        0,
        (await ethers.provider.getNetwork()).chainId,
      )
      route = {
        nonce: nonce,
        source: Number(
          (await intentSource.runner?.provider?.getNetwork())?.chainId,
        ),
        destination: chainId,
        inbox: await inbox.getAddress(),
        calls: calls,
      }
      reward = {
        creator: creator.address,
        prover: await prover.getAddress(),
        expiryTime: expiry,
        nativeValue: 0n,
        tokens: rewardTokens,
      }
      routeHash = keccak256(encodeRoute(route))
      rewardHash = keccak256(encodeReward(reward))
      intentHash = keccak256(
        ethers.solidityPacked(['bytes32', 'bytes32'], [routeHash, rewardHash]),
      )
    })
    it('creates properly with erc20 rewards', async () => {
      await intentSource.connect(creator).publishIntent({ route, reward }, true)

      expect(await intentSource.validateIntent({ route, reward })).to.be.true
    })
    it('creates properly with native token rewards', async () => {
      await intentSource
        .connect(creator)
        .publishIntent(
          { route, reward: { ...reward, nativeValue: rewardNativeEth } },
          true,
          { value: rewardNativeEth },
        )
      expect(
        await intentSource.validateIntent({
          route,
          reward: { ...reward, nativeValue: rewardNativeEth },
        }),
      ).to.be.true
    })
    it('increments counter and locks up tokens', async () => {
      const initialBalanceA = await tokenA.balanceOf(
        await intentSource.getAddress(),
      )
      const initialBalanceB = await tokenA.balanceOf(
        await intentSource.getAddress(),
      )
      const initialBalanceNative = await ethers.provider.getBalance(
        await intentSource.getAddress(),
      )

      const intent = {
        route,
        reward: { ...reward, nativeValue: rewardNativeEth },
      }

      await intentSource
        .connect(creator)
        .publishIntent(intent, true, { value: rewardNativeEth })

      expect(
        await tokenA.balanceOf(await intentSource.intentVaultAddress(intent)),
      ).to.eq(Number(initialBalanceA) + rewardTokens[0].amount)
      expect(
        await tokenB.balanceOf(await intentSource.intentVaultAddress(intent)),
      ).to.eq(Number(initialBalanceB) + rewardTokens[1].amount)
      expect(
        await ethers.provider.getBalance(
          await intentSource.intentVaultAddress(intent),
        ),
      ).to.eq(initialBalanceNative + rewardNativeEth)
    })
    it('emits events', async () => {
      const intent = {
        route,
        reward: { ...reward, nativeValue: rewardNativeEth },
      }
      const { intentHash } = hashIntent(intent)

      await expect(
        intentSource
          .connect(creator)
          .publishIntent(intent, true, { value: rewardNativeEth }),
      )
        .to.emit(intentSource, 'IntentCreated')
        .withArgs(
          intentHash,
          nonce,
          chainId,
          await inbox.getAddress(),
          calls.map(Object.values),
          await creator.getAddress(),
          await prover.getAddress(),
          expiry,
          rewardNativeEth,
          rewardTokens.map(Object.values),
        )
    })
  })
  describe('claiming rewards', async () => {
    beforeEach(async (): Promise<void> => {
      expiry = (await time.latest()) + 123
      nonce = await encodeIdentifier(
        0,
        (await ethers.provider.getNetwork()).chainId,
      )
      chainId = 1
      calls = [
        {
          target: await tokenA.getAddress(),
          data: await encodeTransfer(creator.address, mintAmount),
          value: 0,
        },
      ]
      rewardTokens = [
        { token: await tokenA.getAddress(), amount: mintAmount },
        { token: await tokenB.getAddress(), amount: mintAmount * 2 },
      ]

      route = {
        nonce: nonce,
        source: Number(
          (await intentSource.runner?.provider?.getNetwork())?.chainId,
        ),
        destination: chainId,
        inbox: await inbox.getAddress(),
        calls: calls,
      }

      reward = {
        creator: creator.address,
        prover: await prover.getAddress(),
        expiryTime: expiry,
        nativeValue: rewardNativeEth,
        tokens: rewardTokens,
      }

      routeHash = keccak256(encodeRoute(route))
      rewardHash = keccak256(encodeReward(reward))
      intentHash = keccak256(
        ethers.solidityPacked(['bytes32', 'bytes32'], [routeHash, rewardHash]),
      )

      intent = { route, reward }

      await intentSource
        .connect(creator)
        .publishIntent(intent, true, { value: rewardNativeEth })
    })
    context('before expiry, no proof', () => {
      it('cant be withdrawn', async () => {
        await expect(
          intentSource.connect(otherPerson).withdrawRewards(routeHash, reward),
        ).to.be.revertedWithCustomError(intentSource, `UnauthorizedWithdrawal`)
      })
    })
    context('before expiry, proof', () => {
      beforeEach(async (): Promise<void> => {
        await prover
          .connect(creator)
          .addProvenIntent(intentHash, await claimant.getAddress())
      })
      it('gets withdrawn to claimant', async () => {
        const initialBalanceA = await tokenA.balanceOf(
          await claimant.getAddress(),
        )
        const initialBalanceB = await tokenB.balanceOf(
          await claimant.getAddress(),
        )

        const initialBalanceNative = await ethers.provider.getBalance(
          await claimant.getAddress(),
        )

        expect(await intentSource.validateIntent(intent)).to.be.true

        await intentSource
          .connect(otherPerson)
          .withdrawRewards(routeHash, reward)

        expect(await intentSource.validateIntent(intent)).to.be.false
        expect(await tokenA.balanceOf(await claimant.getAddress())).to.eq(
          Number(initialBalanceA) + reward.tokens[0].amount,
        )
        expect(await tokenB.balanceOf(await claimant.getAddress())).to.eq(
          Number(initialBalanceB) + reward.tokens[1].amount,
        )
        expect(
          await ethers.provider.getBalance(await claimant.getAddress()),
        ).to.eq(initialBalanceNative + rewardNativeEth)
      })
      it('emits event', async () => {
        await expect(
          intentSource.connect(otherPerson).withdrawRewards(routeHash, reward),
        )
          .to.emit(intentSource, 'Withdrawal')
          .withArgs(intentHash, await claimant.getAddress())
      })
      it('does not allow repeat withdrawal', async () => {
        await intentSource
          .connect(otherPerson)
          .withdrawRewards(routeHash, reward)
        await expect(
          intentSource.connect(otherPerson).withdrawRewards(routeHash, reward),
        ).to.be.revertedWithCustomError(intentSource, 'NothingToWithdraw')
      })
    })
    context('after expiry, no proof', () => {
      beforeEach(async (): Promise<void> => {
        await time.increaseTo(expiry)
      })
      it('gets withdrawn to creator', async () => {
        const initialBalanceA = await tokenA.balanceOf(
          await creator.getAddress(),
        )
        const initialBalanceB = await tokenB.balanceOf(
          await creator.getAddress(),
        )
        expect(await intentSource.validateIntent(intent)).to.be.true

        await intentSource
          .connect(otherPerson)
          .withdrawRewards(routeHash, reward)

        expect(await intentSource.validateIntent(intent)).to.be.false
        expect(await tokenA.balanceOf(await creator.getAddress())).to.eq(
          Number(initialBalanceA) + reward.tokens[0].amount,
        )
        expect(await tokenB.balanceOf(await creator.getAddress())).to.eq(
          Number(initialBalanceB) + reward.tokens[1].amount,
        )
      })
    })
    context('after expiry, proof', () => {
      beforeEach(async (): Promise<void> => {
        await prover
          .connect(creator)
          .addProvenIntent(intentHash, await claimant.getAddress())
        await time.increaseTo(expiry)
      })
      it('gets withdrawn to claimant', async () => {
        const initialBalanceA = await tokenA.balanceOf(
          await claimant.getAddress(),
        )
        const initialBalanceB = await tokenB.balanceOf(
          await claimant.getAddress(),
        )
        expect(await intentSource.validateIntent(intent)).to.be.true

        await intentSource
          .connect(otherPerson)
          .withdrawRewards(routeHash, reward)

        expect(await intentSource.validateIntent(intent)).to.be.false
        expect(await tokenA.balanceOf(await claimant.getAddress())).to.eq(
          Number(initialBalanceA) + reward.tokens[0].amount,
        )
        expect(await tokenB.balanceOf(await claimant.getAddress())).to.eq(
          Number(initialBalanceB) + reward.tokens[1].amount,
        )
      })
    })
  })
  describe('batch withdrawal', async () => {
    describe('fails if', () => {
      beforeEach(async (): Promise<void> => {
        expiry = (await time.latest()) + 123
        nonce = await encodeIdentifier(
          0,
          (await ethers.provider.getNetwork()).chainId,
        )
        chainId = 1
        calls = [
          {
            target: await tokenA.getAddress(),
            data: await encodeTransfer(creator.address, mintAmount),
            value: 0,
          },
        ]
        rewardTokens = [
          { token: await tokenA.getAddress(), amount: mintAmount },
          { token: await tokenB.getAddress(), amount: mintAmount * 2 },
        ]
        route = {
          nonce: nonce,
          source: Number(
            (await intentSource.runner?.provider?.getNetwork())?.chainId,
          ),
          destination: chainId,
          inbox: await inbox.getAddress(),
          calls: calls,
        }
        reward = {
          creator: creator.address,
          prover: await prover.getAddress(),
          expiryTime: expiry,
          nativeValue: rewardNativeEth,
          tokens: rewardTokens,
        }
        ;({ intentHash, routeHash, rewardHash } = hashIntent({ route, reward }))
        intent = { route, reward }

        await intentSource
          .connect(creator)
          .publishIntent(intent, true, { value: rewardNativeEth })
      })
      it('bricks if called before expiry by IntentCreator', async () => {
        await expect(
          intentSource
            .connect(otherPerson)
            .batchWithdraw([routeHash], [reward]),
        ).to.be.revertedWithCustomError(intentSource, 'UnauthorizedWithdrawal')
      })
    })
    describe('single intent, complex', () => {
      beforeEach(async (): Promise<void> => {
        expiry = (await time.latest()) + 123
        nonce = await encodeIdentifier(
          0,
          (await ethers.provider.getNetwork()).chainId,
        )
        chainId = 1
        calls = [
          {
            target: await tokenA.getAddress(),
            data: await encodeTransfer(creator.address, mintAmount),
            value: 0,
          },
        ]
        rewardTokens = [
          { token: await tokenA.getAddress(), amount: mintAmount },
          { token: await tokenB.getAddress(), amount: mintAmount * 2 },
        ]
        route = {
          nonce: nonce,
          source: Number(
            (await intentSource.runner?.provider?.getNetwork())?.chainId,
          ),
          destination: chainId,
          inbox: await inbox.getAddress(),
          calls: calls,
        }
        reward = {
          creator: creator.address,
          prover: await prover.getAddress(),
          expiryTime: expiry,
          nativeValue: rewardNativeEth,
          tokens: rewardTokens,
        }
        intent = { route, reward }
        ;({ intentHash, routeHash, rewardHash } = hashIntent(intent))

        await intentSource
          .connect(creator)
          .publishIntent(intent, true, { value: rewardNativeEth })
      })
      it('before expiry to claimant', async () => {
        const initialBalanceNative = await ethers.provider.getBalance(
          await claimant.getAddress(),
        )
        expect(await intentSource.validateIntent(intent)).to.be.true
        expect(await tokenA.balanceOf(await claimant.getAddress())).to.eq(0)
        expect(await tokenB.balanceOf(await claimant.getAddress())).to.eq(0)
        expect(
          await tokenA.balanceOf(await intentSource.intentVaultAddress(intent)),
        ).to.eq(mintAmount)
        expect(
          await tokenB.balanceOf(await intentSource.intentVaultAddress(intent)),
        ).to.eq(mintAmount * 2)
        expect(
          await ethers.provider.getBalance(
            await intentSource.intentVaultAddress(intent),
          ),
        ).to.eq(rewardNativeEth)

        await prover
          .connect(creator)
          .addProvenIntent(intentHash, await claimant.getAddress())
        await intentSource
          .connect(otherPerson)
          .batchWithdraw([routeHash], [reward])

        expect(await intentSource.validateIntent(intent)).to.be.false
        expect(await tokenA.balanceOf(await claimant.getAddress())).to.eq(
          mintAmount,
        )
        expect(await tokenB.balanceOf(await claimant.getAddress())).to.eq(
          mintAmount * 2,
        )
        expect(await tokenA.balanceOf(await intentSource.getAddress())).to.eq(0)
        expect(await tokenB.balanceOf(await intentSource.getAddress())).to.eq(0)

        expect(
          await ethers.provider.getBalance(await intentSource.getAddress()),
        ).to.eq(0)

        expect(
          await ethers.provider.getBalance(await claimant.getAddress()),
        ).to.eq(initialBalanceNative + rewardNativeEth)
      })
      it('after expiry to creator', async () => {
        await time.increaseTo(expiry)
        const initialBalanceNative = await ethers.provider.getBalance(
          await creator.getAddress(),
        )
        expect(await intentSource.validateIntent(intent)).to.be.true
        expect(await tokenA.balanceOf(await creator.getAddress())).to.eq(0)
        expect(await tokenB.balanceOf(await creator.getAddress())).to.eq(0)

        await prover
          .connect(otherPerson)
          .addProvenIntent(intentHash, await creator.getAddress())
        await intentSource
          .connect(otherPerson)
          .batchWithdraw([routeHash], [reward])

        expect(await intentSource.validateIntent(intent)).to.be.false
        expect(await tokenA.balanceOf(await creator.getAddress())).to.eq(
          mintAmount,
        )
        expect(await tokenB.balanceOf(await creator.getAddress())).to.eq(
          mintAmount * 2,
        )
        expect(
          await ethers.provider.getBalance(await creator.getAddress()),
        ).to.eq(initialBalanceNative + rewardNativeEth)
      })
    })
    describe('multiple intents, each with a single reward token', () => {
      beforeEach(async (): Promise<void> => {
        expiry = (await time.latest()) + 123
        nonce = await encodeIdentifier(
          0,
          (await ethers.provider.getNetwork()).chainId,
        )
        chainId = 1
        calls = [
          {
            target: await tokenA.getAddress(),
            data: await encodeTransfer(creator.address, mintAmount),
            value: 0,
          },
        ]
      })
      it('same token', async () => {
        let tx
        let nonce = route.nonce
        const routeHashes: BytesLike[] = []
        const rewards: Reward[] = []
        for (let i = 0; i < 3; i++) {
          route = {
            ...route,
            nonce: (nonce = keccak256(nonce)),
          }
          rewards.push({
            ...reward,
            nativeValue: 0n,
            tokens: [
              { token: await tokenA.getAddress(), amount: mintAmount / 10 },
            ],
          })
          routeHashes.push(
            hashIntent({ route, reward: rewards.at(-1)! }).routeHash,
          )

          tx = await intentSource
            .connect(creator)
            .publishIntent({ route, reward: rewards.at(-1)! }, true)
          tx = await tx.wait()
        }
        const logs = await intentSource.queryFilter(
          intentSource.getEvent('IntentCreated'),
        )
        const hashes = logs.map((log) => log.args.hash)

        expect(await tokenA.balanceOf(await claimant.getAddress())).to.eq(0)

        for (let i = 0; i < 3; i++) {
          await prover
            .connect(creator)
            .addProvenIntent(hashes[i], await claimant.getAddress())
        }
        await intentSource
          .connect(otherPerson)
          .batchWithdraw(routeHashes, rewards)

        expect(await tokenA.balanceOf(await claimant.getAddress())).to.eq(
          (mintAmount / 10) * 3,
        )
      })
      it('multiple tokens', async () => {
        let tx
        let nonce = route.nonce
        const routeHashes: BytesLike[] = []
        const rewards: Reward[] = []
        for (let i = 0; i < 3; i++) {
          route = {
            ...route,
            nonce: (nonce = keccak256(nonce)),
          }
          rewards.push({
            ...reward,
            nativeValue: 0n,
            tokens: [
              { token: await tokenA.getAddress(), amount: mintAmount / 10 },
            ],
          })
          routeHashes.push(
            hashIntent({ route, reward: rewards.at(-1)! }).routeHash,
          )

          tx = await intentSource
            .connect(creator)
            .publishIntent({ route, reward: rewards.at(-1)! }, true)
          tx = await tx.wait()
        }
        for (let i = 0; i < 3; i++) {
          route = {
            ...route,
            nonce: (nonce = keccak256(nonce)),
          }
          rewards.push({
            ...reward,
            nativeValue: 0n,
            tokens: [
              {
                token: await tokenB.getAddress(),
                amount: (mintAmount * 2) / 10,
              },
            ],
          })
          routeHashes.push(
            hashIntent({ route, reward: rewards.at(-1)! }).routeHash,
          )

          tx = await intentSource
            .connect(creator)
            .publishIntent({ route, reward: rewards.at(-1)! }, true)
          tx = await tx.wait()
        }
        const logs = await intentSource.queryFilter(
          intentSource.getEvent('IntentCreated'),
        )
        const hashes = logs.map((log) => log.args.hash)

        expect(await tokenA.balanceOf(await claimant.getAddress())).to.eq(0)
        expect(await tokenB.balanceOf(await claimant.getAddress())).to.eq(0)

        for (let i = 0; i < 6; i++) {
          await prover
            .connect(creator)
            .addProvenIntent(hashes[i], await claimant.getAddress())
        }
        await intentSource
          .connect(otherPerson)
          .batchWithdraw(routeHashes, rewards)

        expect(await tokenA.balanceOf(await claimant.getAddress())).to.eq(
          (mintAmount / 10) * 3,
        )
        expect(await tokenB.balanceOf(await claimant.getAddress())).to.eq(
          ((mintAmount * 2) / 10) * 3,
        )
      })
      it('multiple tokens plus native', async () => {
        let tx
        let nonce = route.nonce
        const routeHashes: BytesLike[] = []
        const rewards: Reward[] = []
        for (let i = 0; i < 3; i++) {
          route = {
            ...route,
            nonce: (nonce = keccak256(nonce)),
          }
          rewards.push({
            ...reward,
            nativeValue: 0n,
            tokens: [
              { token: await tokenA.getAddress(), amount: mintAmount / 10 },
            ],
          })
          routeHashes.push(
            hashIntent({ route, reward: rewards.at(-1)! }).routeHash,
          )

          tx = await intentSource.connect(creator).publishIntent(
            {
              route,
              reward: rewards.at(-1)!,
            },
            true,
          )
          tx = await tx.wait()
        }
        for (let i = 0; i < 3; i++) {
          route = {
            ...route,
            nonce: (nonce = keccak256(nonce)),
          }
          rewards.push({
            ...reward,
            nativeValue: 0n,
            tokens: [
              {
                token: await tokenB.getAddress(),
                amount: (mintAmount * 2) / 10,
              },
            ],
          })
          routeHashes.push(
            hashIntent({ route, reward: rewards.at(-1)! }).routeHash,
          )

          tx = await intentSource.connect(creator).publishIntent(
            {
              route,
              reward: rewards.at(-1)!,
            },
            true,
          )
          tx = await tx.wait()
        }
        for (let i = 0; i < 3; i++) {
          route = {
            ...route,
            nonce: (nonce = keccak256(nonce)),
          }
          rewards.push({
            ...reward,
            nativeValue: rewardNativeEth,
            tokens: [],
          })
          routeHashes.push(
            hashIntent({ route, reward: rewards.at(-1)! }).routeHash,
          )

          tx = await intentSource
            .connect(creator)
            .publishIntent({ route, reward: rewards.at(-1)! }, true, {
              value: rewardNativeEth,
            })
          tx = await tx.wait()
        }
        const logs = await intentSource.queryFilter(
          intentSource.getEvent('IntentCreated'),
        )
        const hashes = logs.map((log) => log.args.hash)

        expect(await tokenA.balanceOf(await claimant.getAddress())).to.eq(0)
        expect(await tokenB.balanceOf(await claimant.getAddress())).to.eq(0)

        const initialBalanceNative = await ethers.provider.getBalance(
          await claimant.getAddress(),
        )

        for (let i = 0; i < 9; i++) {
          await prover
            .connect(creator)
            .addProvenIntent(hashes[i], await claimant.getAddress())
        }

        await intentSource
          .connect(otherPerson)
          .batchWithdraw(routeHashes, rewards)

        expect(await tokenA.balanceOf(await claimant.getAddress())).to.eq(
          (mintAmount / 10) * 3,
        )
        expect(await tokenB.balanceOf(await claimant.getAddress())).to.eq(
          ((mintAmount * 2) / 10) * 3,
        )
        expect(
          await ethers.provider.getBalance(await claimant.getAddress()),
        ).to.eq(initialBalanceNative + BigInt(3) * rewardNativeEth)
      })
    })
    it('works in the case of multiple intents, each with multiple reward tokens', async () => {
      expiry = (await time.latest()) + 123
      nonce = await encodeIdentifier(
        0,
        (await ethers.provider.getNetwork()).chainId,
      )
      chainId = 1
      calls = [
        {
          target: await tokenA.getAddress(),
          data: await encodeTransfer(creator.address, mintAmount),
          value: 0,
        },
      ]
      route = {
        nonce: nonce,
        source: Number(
          (await intentSource.runner?.provider?.getNetwork())?.chainId,
        ),
        destination: chainId,
        inbox: await inbox.getAddress(),
        calls: calls,
      }
      let tx
      let routeHashes: BytesLike[] = []
      let rewards: Reward[] = []
      for (let i = 0; i < 5; i++) {
        route = {
          ...route,
          nonce: (nonce = keccak256(nonce)),
        }
        rewards.push({
          ...reward,
          nativeValue: 0n,
          tokens: [
            {
              token: await tokenA.getAddress(),
              amount: mintAmount / 10,
            },
          ],
        })
        routeHashes.push(
          hashIntent({ route, reward: rewards.at(-1)! }).routeHash,
        )

        tx = await intentSource.connect(creator).publishIntent(
          {
            route,
            reward: rewards.at(-1)!,
          },
          true,
        )
        tx = await tx.wait()
      }
      for (let i = 0; i < 5; i++) {
        route = {
          ...route,
          nonce: (nonce = keccak256(nonce)),
        }
        rewards.push({
          ...reward,
          tokens: [
            {
              token: await tokenA.getAddress(),
              amount: mintAmount / 10,
            },
            {
              token: await tokenB.getAddress(),
              amount: (mintAmount * 2) / 10,
            },
          ],
        })
        routeHashes.push(
          hashIntent({ route, reward: rewards.at(-1)! }).routeHash,
        )

        tx = await intentSource.connect(creator).publishIntent(
          {
            route,
            reward: rewards.at(-1)!,
          },
          true,
          { value: rewardNativeEth },
        )
        await tx.wait()
      }
      const logs = await intentSource.queryFilter(
        intentSource.getEvent('IntentCreated'),
      )
      const hashes = logs.map((log) => log.args.hash)

      expect(await tokenA.balanceOf(await claimant.getAddress())).to.eq(0)
      expect(await tokenB.balanceOf(await claimant.getAddress())).to.eq(0)

      const initialBalanceNative = await ethers.provider.getBalance(
        await claimant.getAddress(),
      )

      for (let i = 0; i < hashes.length; i++) {
        await prover
          .connect(creator)
          .addProvenIntent(hashes[i], await claimant.getAddress())
      }
      await intentSource
        .connect(otherPerson)
        .batchWithdraw(routeHashes, rewards)

      expect(await tokenA.balanceOf(await claimant.getAddress())).to.eq(
        mintAmount,
      )
      expect(await tokenB.balanceOf(await claimant.getAddress())).to.eq(
        mintAmount,
      )
      expect(
        await ethers.provider.getBalance(await claimant.getAddress()),
      ).to.eq(initialBalanceNative + BigInt(5) * rewardNativeEth)
    })
  })
})
