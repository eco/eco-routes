import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import {
  TestERC20,
  Portal,
  TestProver,
  Inbox,
  Eco7683OriginSettler,
} from '../typechain-types'
import { time, loadFixture } from '@nomicfoundation/hardhat-network-helpers'
import { keccak256, BytesLike, Provider } from 'ethers'
import { encodeTransfer } from '../utils/encode'
import { Call, TokenAmount, Route, Reward, Intent, hashIntent, encodeRoute, encodeIntent } from '../utils/intent'
import { addressToBytes32, bytes32ToAddress, TypeCasts } from '../utils/typeCasts'
import {
  OnchainCrossChainOrderStruct,
  GaslessCrossChainOrderStruct,
  ResolvedCrossChainOrderStruct,
} from '../typechain-types/contracts/Eco7683OriginSettler'

describe('Origin Settler Test', (): void => {
  let originSettler: Eco7683OriginSettler
  let portal: Portal
  let prover: TestProver
  let inbox: Inbox
  let tokenA: TestERC20
  let tokenB: TestERC20
  let creator: SignerWithAddress
  let otherPerson: SignerWithAddress
  const mintAmount: number = 1000
  const minBatcherReward = 12345

  /**
   * Deploys the origin settler test fixtures
   */
  const deployOriginSettlerFixture = async (): Promise<{
    originSettler: Eco7683OriginSettler
    portal: Portal
    prover: TestProver
    inbox: Inbox
    tokenA: TestERC20
    tokenB: TestERC20
    creator: SignerWithAddress
    otherPerson: SignerWithAddress
  }> => {
    const [creator, otherPerson] = await ethers.getSigners()

    // Deploy the portal (which is also the inbox)
    const Portal = await ethers.getContractFactory('Portal')
    const portal = await Portal.deploy()
    const inbox = await ethers.getContractAt('Inbox', await portal.getAddress())

    // Deploy the test prover
    const TestProver = await ethers.getContractFactory('TestProver')
    const prover = await TestProver.deploy(await inbox.getAddress())

    // Deploy test tokens
    const TestERC20 = await ethers.getContractFactory('TestERC20')
    const tokenA = await TestERC20.deploy('TokenA', 'TKA')
    const tokenB = await TestERC20.deploy('TokenB', 'TKB')

    // Deploy the origin settler
    const OriginSettler = await ethers.getContractFactory('Eco7683OriginSettler')
    const originSettler = await OriginSettler.deploy(
      'EcoOriginSettler',
      '1.0.0',
      await portal.getAddress(),
    )

    // Mint tokens to creator
    await tokenA.mint(creator.address, mintAmount)
    await tokenB.mint(creator.address, mintAmount)

    return {
      originSettler,
      portal,
      prover,
      inbox,
      tokenA,
      tokenB,
      creator,
      otherPerson,
    }
  }

  describe('General Flow', (): void => {
    beforeEach(async (): Promise<void> => {
      ;({ originSettler, portal, prover, inbox, tokenA, tokenB, creator, otherPerson } =
        await loadFixture(deployOriginSettlerFixture))
    })

    describe('Gasless Cross-Chain Order', (): void => {
      let sampleCall: Call
      let route: Route
      let reward: Reward
      let intent: Intent
      let intentHash: string
      let rewardHash: string
      let routeHash: string
      let tokens: TokenAmount[]
      let minimalReward: Reward
      let signedOrder: GaslessCrossChainOrderStruct

      beforeEach(async (): Promise<void> => {
        // Create a sample call
        sampleCall = {
          target: await tokenA.getAddress(),
          data: await encodeTransfer(otherPerson.address, 100),
          value: 0,
        }

        // Create tokens array
        tokens = [{ token: await tokenA.getAddress(), amount: 100 }]

        // Create route
        route = {
          salt: ethers.encodeBytes32String('salt'),
          deadline: (await time.latest()) + 1000,
          portal: await portal.getAddress(),
          tokens,
          calls: [sampleCall],
        }

        // Create minimal reward
        minimalReward = {
          deadline: (await time.latest()) + 1000,
          creator: creator.address,
          prover: await prover.getAddress(),
          nativeValue: 0,
          tokens: [],
        }

        // Create reward with batcher reward
        reward = {
          deadline: (await time.latest()) + 1000,
          creator: creator.address,
          prover: await prover.getAddress(),
          nativeValue: 0,
          tokens,
        }

        // Create intent
        intent = {
          destination: 1,
          route,
          reward,
        }

        // Calculate hashes
        const hashes = hashIntent(intent)
        intentHash = hashes.intentHash
        rewardHash = hashes.rewardHash
        routeHash = hashes.routeHash

        // Create the order struct with bytes32 types
        const order = {
          chainId: 1,
          creator: addressToBytes32(creator.address),
          route: {
            salt: route.salt,
            deadline: route.deadline,
            portal: addressToBytes32(route.portal),
            tokens: route.tokens.map((t) => ({
              token: addressToBytes32(t.token),
              amount: t.amount,
            })),
            calls: route.calls.map((c) => ({
              target: addressToBytes32(c.target),
              data: c.data,
              value: c.value,
            })),
          },
          reward: {
            deadline: reward.deadline,
            creator: addressToBytes32(reward.creator),
            prover: addressToBytes32(reward.prover),
            nativeValue: reward.nativeValue,
            tokens: reward.tokens.map((t) => ({
              token: addressToBytes32(t.token),
              amount: t.amount,
            })),
          },
          nonce: ethers.encodeBytes32String('nonce'),
        }

        // Encode order data
        const orderData = ethers.AbiCoder.defaultAbiCoder().encode(
          [
            'tuple(uint64 chainId, bytes32 creator, tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls) route, tuple(uint64 deadline, bytes32 creator, bytes32 prover, uint256 nativeValue, tuple(bytes32 token, uint256 amount)[] tokens) reward, bytes32 nonce)',
          ],
          [order],
        )

        // Hash the order data
        const orderHash = keccak256(orderData)

        // Sign the order
        const signature = await creator.signMessage(ethers.getBytes(orderHash))

        // Create signed order struct
        signedOrder = {
          order: orderData,
          signature,
        }
      })

      it('should open a gasless order', async (): Promise<void> => {
        // Approve tokens to settler
        await tokenA.connect(creator).approve(await originSettler.getAddress(), 100)

        // Open the order
        await expect(originSettler.connect(otherPerson).open(signedOrder))
          .to.emit(originSettler, 'Open')
          .withArgs(intentHash, [intentHash])

        // Verify the intent was published
        const isIntentFunded = await portal.isIntentFunded(intent)
        expect(isIntentFunded).to.be.true
      })

      it('should batch multiple gasless orders', async (): Promise<void> => {
        // Create second order
        const sampleCall2 = {
          target: await tokenB.getAddress(),
          data: await encodeTransfer(otherPerson.address, 50),
          value: 0,
        }

        const route2: Route = {
          salt: ethers.encodeBytes32String('salt2'),
          deadline: (await time.latest()) + 1000,
          portal: await portal.getAddress(),
          tokens: [{ token: await tokenB.getAddress(), amount: 50 }],
          calls: [sampleCall2],
        }

        const intent2: Intent = {
          destination: 1,
          route: route2,
          reward,
        }

        const hashes2 = hashIntent(intent2)
        const intentHash2 = hashes2.intentHash

        // Create order struct for second order
        const order2 = {
          chainId: 1,
          creator: addressToBytes32(creator.address),
          route: {
            salt: route2.salt,
            deadline: route2.deadline,
            portal: addressToBytes32(route2.portal),
            tokens: route2.tokens.map((t) => ({
              token: addressToBytes32(t.token),
              amount: t.amount,
            })),
            calls: route2.calls.map((c) => ({
              target: addressToBytes32(c.target),
              data: c.data,
              value: c.value,
            })),
          },
          reward: {
            deadline: reward.deadline,
            creator: addressToBytes32(reward.creator),
            prover: addressToBytes32(reward.prover),
            nativeValue: reward.nativeValue,
            tokens: reward.tokens.map((t) => ({
              token: addressToBytes32(t.token),
              amount: t.amount,
            })),
          },
          nonce: ethers.encodeBytes32String('nonce2'),
        }

        // Encode and sign second order
        const orderData2 = ethers.AbiCoder.defaultAbiCoder().encode(
          [
            'tuple(uint64 chainId, bytes32 creator, tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls) route, tuple(uint64 deadline, bytes32 creator, bytes32 prover, uint256 nativeValue, tuple(bytes32 token, uint256 amount)[] tokens) reward, bytes32 nonce)',
          ],
          [order2],
        )
        const orderHash2 = keccak256(orderData2)
        const signature2 = await creator.signMessage(ethers.getBytes(orderHash2))

        const signedOrder2: GaslessCrossChainOrderStruct = {
          order: orderData2,
          signature: signature2,
        }

        // Approve tokens
        await tokenA.connect(creator).approve(await originSettler.getAddress(), 100)
        await tokenB.connect(creator).approve(await originSettler.getAddress(), 50)

        // Open both orders in batch
        await expect(
          originSettler.connect(otherPerson).open([signedOrder, signedOrder2]),
        )
          .to.emit(originSettler, 'Open')
          .withArgs(intentHash, [intentHash, intentHash2])

        // Verify both intents were published
        expect(await portal.isIntentFunded(intent)).to.be.true
        expect(await portal.isIntentFunded(intent2)).to.be.true
      })

      it('should revert if signature is invalid', async (): Promise<void> => {
        // Create an invalid signature
        const invalidSignedOrder: GaslessCrossChainOrderStruct = {
          order: signedOrder.order,
          signature: await otherPerson.signMessage(ethers.getBytes(keccak256(signedOrder.order))),
        }

        // Try to open with invalid signature
        await expect(
          originSettler.connect(otherPerson).open(invalidSignedOrder),
        ).to.be.revertedWithCustomError(originSettler, 'InvalidSignature')
      })

      it('should revert if batcher reward is insufficient', async (): Promise<void> => {
        // Create intent with insufficient batcher reward
        const insufficientReward: Reward = {
          deadline: (await time.latest()) + 1000,
          creator: creator.address,
          prover: await prover.getAddress(),
          nativeValue: minBatcherReward - 1,
          tokens: [],
        }

        const insufficientIntent: Intent = {
          destination: 1,
          route,
          reward: insufficientReward,
        }

        // Create order struct
        const insufficientOrder = {
          chainId: 1,
          creator: addressToBytes32(creator.address),
          route: {
            salt: route.salt,
            deadline: route.deadline,
            portal: addressToBytes32(route.portal),
            tokens: route.tokens.map((t) => ({
              token: addressToBytes32(t.token),
              amount: t.amount,
            })),
            calls: route.calls.map((c) => ({
              target: addressToBytes32(c.target),
              data: c.data,
              value: c.value,
            })),
          },
          reward: {
            deadline: insufficientReward.deadline,
            creator: addressToBytes32(insufficientReward.creator),
            prover: addressToBytes32(insufficientReward.prover),
            nativeValue: insufficientReward.nativeValue,
            tokens: insufficientReward.tokens.map((t) => ({
              token: addressToBytes32(t.token),
              amount: t.amount,
            })),
          },
          nonce: ethers.encodeBytes32String('nonce'),
        }

        // Encode and sign
        const orderData = ethers.AbiCoder.defaultAbiCoder().encode(
          [
            'tuple(uint64 chainId, bytes32 creator, tuple(bytes32 salt, uint64 deadline, bytes32 portal, tuple(bytes32 token, uint256 amount)[] tokens, tuple(bytes32 target, bytes data, uint256 value)[] calls) route, tuple(uint64 deadline, bytes32 creator, bytes32 prover, uint256 nativeValue, tuple(bytes32 token, uint256 amount)[] tokens) reward, bytes32 nonce)',
          ],
          [insufficientOrder],
        )
        const orderHash = keccak256(orderData)
        const signature = await creator.signMessage(ethers.getBytes(orderHash))

        const insufficientSignedOrder: GaslessCrossChainOrderStruct = {
          order: orderData,
          signature,
        }

        // Try to open with insufficient reward
        await expect(
          originSettler.connect(otherPerson).open(insufficientSignedOrder),
        ).to.be.revertedWithCustomError(originSettler, 'InsufficientBatcherReward')
      })
    })

    describe('Onchain Cross-Chain Order', (): void => {
      let sampleCall: Call
      let route: Route
      let reward: Reward
      let intent: Intent
      let intentHash: string
      let rewardHash: string
      let routeHash: string
      let tokens: TokenAmount[]

      beforeEach(async (): Promise<void> => {
        // Create a sample call
        sampleCall = {
          target: await tokenA.getAddress(),
          data: await encodeTransfer(otherPerson.address, 100),
          value: 0,
        }

        // Create tokens array
        tokens = [{ token: await tokenA.getAddress(), amount: 100 }]

        // Create route
        route = {
          salt: ethers.encodeBytes32String('salt'),
          deadline: (await time.latest()) + 1000,
          portal: await portal.getAddress(),
          tokens,
          calls: [sampleCall],
        }

        // Create reward
        reward = {
          deadline: (await time.latest()) + 1000,
          creator: creator.address,
          prover: await prover.getAddress(),
          nativeValue: 0,
          tokens: [],
        }

        // Create intent
        intent = {
          destination: 1,
          route,
          reward,
        }

        // Calculate hashes
        const hashes = hashIntent(intent)
        intentHash = hashes.intentHash
        rewardHash = hashes.rewardHash
        routeHash = hashes.routeHash
      })

      it('should open an onchain order', async (): Promise<void> => {
        // Create onchain order struct
        const onchainOrder: OnchainCrossChainOrderStruct = {
          fillDeadline: (await time.latest()) + 1000,
          orderData: encodeIntent(intent),
        }

        // Approve tokens
        await tokenA.connect(creator).approve(await originSettler.getAddress(), 100)

        // Open the order with batcher fee
        await expect(
          originSettler.connect(creator).openFor(onchainOrder, { value: minBatcherReward }),
        )
          .to.emit(originSettler, 'Open')
          .withArgs(intentHash, [intentHash])

        // Verify the intent was published
        expect(await portal.isIntentFunded(intent)).to.be.true
      })

      it('should batch multiple onchain orders', async (): Promise<void> => {
        // Create second intent
        const sampleCall2 = {
          target: await tokenB.getAddress(),
          data: await encodeTransfer(otherPerson.address, 50),
          value: 0,
        }

        const route2: Route = {
          salt: ethers.encodeBytes32String('salt2'),
          deadline: (await time.latest()) + 1000,
          portal: await portal.getAddress(),
          tokens: [{ token: await tokenB.getAddress(), amount: 50 }],
          calls: [sampleCall2],
        }

        const intent2: Intent = {
          destination: 1,
          route: route2,
          reward,
        }

        const hashes2 = hashIntent(intent2)
        const intentHash2 = hashes2.intentHash

        // Create onchain orders
        const onchainOrder1: OnchainCrossChainOrderStruct = {
          fillDeadline: (await time.latest()) + 1000,
          orderData: encodeIntent(intent),
        }

        const onchainOrder2: OnchainCrossChainOrderStruct = {
          fillDeadline: (await time.latest()) + 1000,
          orderData: encodeIntent(intent2),
        }

        // Approve tokens
        await tokenA.connect(creator).approve(await originSettler.getAddress(), 100)
        await tokenB.connect(creator).approve(await originSettler.getAddress(), 50)

        // Open both orders with batcher fee
        await expect(
          originSettler
            .connect(creator)
            .openFor([onchainOrder1, onchainOrder2], { value: minBatcherReward * 2 }),
        )
          .to.emit(originSettler, 'Open')
          .withArgs(intentHash, [intentHash, intentHash2])

        // Verify both intents were published
        expect(await portal.isIntentFunded(intent)).to.be.true
        expect(await portal.isIntentFunded(intent2)).to.be.true
      })

      it('should revert if batcher fee is insufficient', async (): Promise<void> => {
        const onchainOrder: OnchainCrossChainOrderStruct = {
          fillDeadline: (await time.latest()) + 1000,
          orderData: encodeIntent(intent),
        }

        await tokenA.connect(creator).approve(await originSettler.getAddress(), 100)

        // Try to open with insufficient fee
        await expect(
          originSettler.connect(creator).openFor(onchainOrder, { value: minBatcherReward - 1 }),
        ).to.be.revertedWithCustomError(originSettler, 'InsufficientBatcherFee')
      })

      it('should revert if batcher fee exceeds maximum', async (): Promise<void> => {
        const onchainOrder: OnchainCrossChainOrderStruct = {
          fillDeadline: (await time.latest()) + 1000,
          orderData: encodeIntent(intent),
        }

        await tokenA.connect(creator).approve(await originSettler.getAddress(), 100)

        // Try to open with excessive fee
        await expect(
          originSettler.connect(creator).openFor(onchainOrder, { value: maxBatcherFee + 1 }),
        ).to.be.revertedWithCustomError(originSettler, 'ExcessiveBatcherFee')
      })
    })

    describe('Resolved Cross-Chain Order', (): void => {
      it('should resolve orders correctly', async (): Promise<void> => {
        // Create a simple intent
        const route: Route = {
          salt: ethers.encodeBytes32String('salt'),
          deadline: (await time.latest()) + 1000,
          portal: await portal.getAddress(),
          tokens: [{ token: await tokenA.getAddress(), amount: 100 }],
          calls: [
            {
              target: await tokenA.getAddress(),
              data: await encodeTransfer(otherPerson.address, 100),
              value: 0,
            },
          ],
        }

        const reward: Reward = {
          deadline: (await time.latest()) + 1000,
          creator: creator.address,
          prover: await prover.getAddress(),
          nativeValue: minBatcherReward,
          tokens: [],
        }

        const intent: Intent = {
          destination: 1,
          route,
          reward,
        }

        // Create onchain order
        const onchainOrder: OnchainCrossChainOrderStruct = {
          fillDeadline: (await time.latest()) + 1000,
          orderData: encodeIntent(intent),
        }

        // Resolve the order
        const resolvedOrder: ResolvedCrossChainOrderStruct =
          await originSettler.resolve(onchainOrder)

        // Verify resolved fields
        expect(resolvedOrder.minReceived).to.deep.equal([
          await tokenA.getAddress(),
          ethers.toBigInt(100),
        ])
        expect(resolvedOrder.fillDeadline).to.equal(onchainOrder.fillDeadline)
      })
    })
  })

  describe('Batcher Rewards', (): void => {
    beforeEach(async (): Promise<void> => {
      ;({ originSettler, portal, prover, inbox, tokenA, tokenB, creator, otherPerson } =
        await loadFixture(deployOriginSettlerFixture))
    })

    it('should allow batcher to claim rewards', async (): Promise<void> => {
      // Create and open an order with batcher reward
      const route: Route = {
        salt: ethers.encodeBytes32String('salt'),
        deadline: (await time.latest()) + 1000,
        portal: await portal.getAddress(),
        tokens: [{ token: await tokenA.getAddress(), amount: 100 }],
        calls: [
          {
            target: await tokenA.getAddress(),
            data: await encodeTransfer(otherPerson.address, 100),
            value: 0,
          },
        ],
      }

      const reward: Reward = {
        deadline: (await time.latest()) + 1000,
        creator: creator.address,
        prover: await prover.getAddress(),
        nativeValue: minBatcherReward,
        tokens: [],
      }

      const intent: Intent = {
        destination: 1,
        route,
        reward,
      }

      const onchainOrder: OnchainCrossChainOrderStruct = {
        fillDeadline: (await time.latest()) + 1000,
        orderData: encodeIntent(intent),
      }

      // Approve tokens and open order
      await tokenA.connect(creator).approve(await originSettler.getAddress(), 100)
      await originSettler.connect(creator).openFor(onchainOrder, { value: minBatcherReward })

      // Check batcher balance before claim
      const balanceBefore = await ethers.provider.getBalance(otherPerson.address)

      // Claim rewards as batcher
      await originSettler.connect(otherPerson).claimBatcherRewards(otherPerson.address)

      // Check balance increased by minBatcherReward (minus gas)
      const balanceAfter = await ethers.provider.getBalance(otherPerson.address)
      expect(balanceAfter).to.be.gt(balanceBefore)
    })

    it('should track batcher rewards correctly across multiple orders', async (): Promise<void> => {
      // Create multiple orders
      const numOrders = 3
      const orders: OnchainCrossChainOrderStruct[] = []

      for (let i = 0; i < numOrders; i++) {
        const route: Route = {
          salt: ethers.encodeBytes32String(`salt${i}`),
          deadline: (await time.latest()) + 1000,
          portal: await portal.getAddress(),
          tokens: [{ token: await tokenA.getAddress(), amount: 10 }],
          calls: [
            {
              target: await tokenA.getAddress(),
              data: await encodeTransfer(otherPerson.address, 10),
              value: 0,
            },
          ],
        }

        const reward: Reward = {
          deadline: (await time.latest()) + 1000,
          creator: creator.address,
          prover: await prover.getAddress(),
          nativeValue: minBatcherReward,
          tokens: [],
        }

        const intent: Intent = {
          destination: 1,
          route,
          reward,
        }

        orders.push({
          fillDeadline: (await time.latest()) + 1000,
          orderData: encodeIntent(intent),
        })
      }

      // Approve tokens and open all orders
      await tokenA.connect(creator).approve(await originSettler.getAddress(), 30)
      await originSettler
        .connect(creator)
        .openFor(orders, { value: minBatcherReward * numOrders })

      // Check total rewards
      const totalRewards = await originSettler.batcherRewards(creator.address)
      expect(totalRewards).to.equal(minBatcherReward * numOrders)
    })
  })

  describe('Edge Cases', (): void => {
    beforeEach(async (): Promise<void> => {
      ;({ originSettler, portal, prover, inbox, tokenA, tokenB, creator, otherPerson } =
        await loadFixture(deployOriginSettlerFixture))
    })

    it('should handle orders with native value correctly', async (): Promise<void> => {
      // Create route with native value call
      const route: Route = {
        salt: ethers.encodeBytes32String('salt'),
        deadline: (await time.latest()) + 1000,
        portal: await portal.getAddress(),
        tokens: [],
        calls: [
          {
            target: otherPerson.address,
            data: '0x',
            value: ethers.parseEther('1'),
          },
        ],
      }

      const reward: Reward = {
        deadline: (await time.latest()) + 1000,
        creator: creator.address,
        prover: await prover.getAddress(),
        nativeValue: minBatcherReward,
        tokens: [],
      }

      const intent: Intent = {
        destination: 1,
        route,
        reward,
      }

      const onchainOrder: OnchainCrossChainOrderStruct = {
        fillDeadline: (await time.latest()) + 1000,
        orderData: encodeIntent(intent),
      }

      // Open order with native value + batcher fee
      await expect(
        originSettler.connect(creator).openFor(onchainOrder, {
          value: ethers.parseEther('1') + BigInt(minBatcherReward),
        }),
      )
        .to.emit(originSettler, 'Open')
        .withArgs(hashIntent(intent).intentHash, [hashIntent(intent).intentHash])
    })

    it('should revert on expired orders', async (): Promise<void> => {
      // Create expired route
      const route: Route = {
        salt: ethers.encodeBytes32String('salt'),
        deadline: (await time.latest()) - 1000, // Expired
        portal: await portal.getAddress(),
        tokens: [{ token: await tokenA.getAddress(), amount: 100 }],
        calls: [
          {
            target: await tokenA.getAddress(),
            data: await encodeTransfer(otherPerson.address, 100),
            value: 0,
          },
        ],
      }

      const reward: Reward = {
        deadline: (await time.latest()) + 1000,
        creator: creator.address,
        prover: await prover.getAddress(),
        nativeValue: 0,
        tokens: [],
      }

      const intent: Intent = {
        destination: 1,
        route,
        reward,
      }

      const onchainOrder: OnchainCrossChainOrderStruct = {
        fillDeadline: (await time.latest()) + 1000,
        orderData: encodeIntent(intent),
      }

      await tokenA.connect(creator).approve(await originSettler.getAddress(), 100)

      // Should revert when trying to publish expired intent
      await expect(
        originSettler.connect(creator).openFor(onchainOrder, { value: minBatcherReward }),
      ).to.be.reverted
    })
  })
})