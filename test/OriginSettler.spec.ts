import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import { TestERC20, Portal, TestProver, Inbox } from '../typechain-types'
import { time, loadFixture } from '@nomicfoundation/hardhat-network-helpers'
import { keccak256, BytesLike, Provider, AbiCoder } from 'ethers'
import { encodeTransfer } from '../utils/encode'
import {
  encodeRoute,
  Call,
  TokenAmount,
  Route,
  Reward,
  Intent,
  encodeIntent,
  hashIntent,
} from '../utils/intent'
import {
  OnchainCrossChainOrderStruct,
  GaslessCrossChainOrderStruct,
  ResolvedCrossChainOrderStruct,
} from '../typechain-types/contracts/ERC7683/OriginSettler'
import {
  GaslessCrosschainOrderData,
  OnchainCrosschainOrderData,
} from '../utils/EcoERC7683'

describe('Origin Settler Test', (): void => {
  let originSettler: Portal
  let portal: Portal
  let prover: TestProver
  let inbox: Inbox
  let tokenA: TestERC20
  let tokenB: TestERC20
  let creator: SignerWithAddress
  let otherPerson: SignerWithAddress
  const mintAmount: number = 1000

  let salt: BytesLike
  let nonce: number
  let chainId: number
  let routeTokens: TokenAmount[]
  let calls: Call[]
  let expiry_open: number
  let expiry_fill: number
  const rewardNativeEth: bigint = ethers.parseEther('2')
  let rewardTokens: TokenAmount[]
  let route: Route
  let reward: Reward
  let intent: Intent
  let intentHash: BytesLike
  let onchainCrosschainOrder: OnchainCrossChainOrderStruct
  let onchainCrosschainOrderData: OnchainCrosschainOrderData
  let gaslessCrosschainOrderData: GaslessCrosschainOrderData
  let gaslessCrosschainOrder: GaslessCrossChainOrderStruct
  let signature: string

  // Use the correct ORDER_DATA_TYPEHASH from the contract
  const ORDER_DATA_TYPEHASH = ethers.keccak256(
    ethers.toUtf8Bytes(
      'OrderData(uint64 destination,bytes32 portal,uint64 deadline,bytes route,Reward reward)Reward(uint64 deadline,address creator,address prover,uint256 nativeValue,TokenAmount[] tokens)TokenAmount(address token,uint256 amount)',
    ),
  )

  async function deploySourceFixture(): Promise<{
    originSettler: Portal
    portal: Portal
    prover: TestProver
    tokenA: TestERC20
    tokenB: TestERC20
    creator: SignerWithAddress
    otherPerson: SignerWithAddress
  }> {
    const [creator, owner, otherPerson] = await ethers.getSigners()

    const portalFactory = await ethers.getContractFactory('Portal')
    const portal = await portalFactory.deploy()
    inbox = await ethers.getContractAt('Inbox', await portal.getAddress())

    // deploy prover
    prover = await (
      await ethers.getContractFactory('TestProver')
    ).deploy(await inbox.getAddress())

    // Use portal as the originSettler since OriginSettler is now abstract
    const originSettler = portal

    // deploy ERC20 test
    const erc20Factory = await ethers.getContractFactory('TestERC20')
    const tokenA = await erc20Factory.deploy('A', 'A')
    const tokenB = await erc20Factory.deploy('B', 'B')

    return {
      originSettler,
      portal,
      prover,
      tokenA,
      tokenB,
      creator,
      otherPerson,
    }
  }

  async function mintAndApprove() {
    await tokenA.connect(creator).mint(creator.address, mintAmount)
    await tokenB.connect(creator).mint(creator.address, mintAmount * 2)

    await tokenA.connect(creator).approve(originSettler, mintAmount)
    await tokenB.connect(creator).approve(originSettler, mintAmount * 2)
  }

  beforeEach(async (): Promise<void> => {
    ;({ originSettler, portal, prover, tokenA, tokenB, creator, otherPerson } =
      await loadFixture(deploySourceFixture))

    // fund the creator and approve it to create an intent
    await mintAndApprove()
  })

  // Test no longer relevant since we're using Portal directly
  // it('constructs', async () => {
  //   expect(await originSettler.PORTAL()).to.be.eq(await portal.getAddress())
  // })

  describe('performs actions', async () => {
    beforeEach(async (): Promise<void> => {
      expiry_open = (await time.latest()) + 12345
      expiry_fill = expiry_open + 12345
      chainId = 1
      routeTokens = [{ token: await tokenA.getAddress(), amount: mintAmount }]
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
      salt =
        '0x0000000000000000000000000000000000000000000000000000000000000001'
      nonce = 1
      route = {
        salt,
        deadline: expiry_fill,
        portal: await inbox.getAddress(),
        tokens: routeTokens,
        calls,
      }
      reward = {
        creator: creator.address,
        prover: await prover.getAddress(),
        deadline: expiry_fill,
        nativeValue: rewardNativeEth,
        tokens: rewardTokens,
      }
      intent = { destination: chainId, route: route, reward: reward }
      intentHash = hashIntent(intent).intentHash

      onchainCrosschainOrderData = {
        destination: chainId,
        route: {
          salt: route.salt,
          portal: ethers.zeroPadValue(route.portal, 32),
          tokens: route.tokens,
          calls: route.calls,
        },
        creator: creator.address,
        prover: await prover.getAddress(),
        nativeValue: reward.nativeValue,
        rewardTokens: reward.tokens,
      }

      onchainCrosschainOrder = {
        fillDeadline: expiry_fill,
        orderDataType: ORDER_DATA_TYPEHASH,
        orderData: AbiCoder.defaultAbiCoder().encode(
          [
            'tuple(uint64,bytes32,uint64,bytes,tuple(uint64,bytes32,bytes32,uint256,tuple(bytes32,uint256)[]))',
          ],
          [
            [
              chainId, // destination
              ethers.zeroPadValue(await inbox.getAddress(), 32), // portal
              expiry_fill, // deadline
              encodeRoute(route), // route bytes
              [
                expiry_fill, // reward.deadline
                ethers.zeroPadValue(creator.address, 32), // reward.creator
                ethers.zeroPadValue(await prover.getAddress(), 32), // reward.prover
                reward.nativeValue, // reward.nativeValue
                reward.tokens.map((t) => [
                  ethers.zeroPadValue(t.token, 32),
                  t.amount,
                ]), // reward.tokens
              ],
            ],
          ],
        ),
      }
      gaslessCrosschainOrderData = {
        destination: chainId,
        portal: ethers.zeroPadValue(await inbox.getAddress(), 32),
        routeTokens: routeTokens,
        calls: calls,
        prover: await prover.getAddress(),
        nativeValue: reward.nativeValue,
        rewardTokens: reward.tokens,
      }
      gaslessCrosschainOrder = {
        originSettler: await originSettler.getAddress(),
        user: creator.address,
        nonce: nonce,
        originChainId: Number(
          (await originSettler.runner?.provider?.getNetwork())?.chainId,
        ),
        openDeadline: expiry_open,
        fillDeadline: expiry_fill,
        orderDataType: ORDER_DATA_TYPEHASH,
        orderData: AbiCoder.defaultAbiCoder().encode(
          [
            'tuple(uint64,bytes32,uint64,bytes,tuple(uint64,bytes32,bytes32,uint256,tuple(bytes32,uint256)[]))',
          ],
          [
            [
              chainId, // destination
              ethers.zeroPadValue(await inbox.getAddress(), 32), // portal
              expiry_fill, // deadline
              encodeRoute(route), // route bytes
              [
                expiry_fill, // reward.deadline
                ethers.zeroPadValue(creator.address, 32), // reward.creator
                ethers.zeroPadValue(await prover.getAddress(), 32), // reward.prover
                reward.nativeValue, // reward.nativeValue
                reward.tokens.map((t) => [
                  ethers.zeroPadValue(t.token, 32),
                  t.amount,
                ]), // reward.tokens
              ],
            ],
          ],
        ),
      }

      const domainPieces = await originSettler.eip712Domain()
      const domain = {
        name: domainPieces[1],
        version: domainPieces[2],
        chainId: domainPieces[3],
        verifyingContract: domainPieces[4],
      }

      const types = {
        GaslessCrossChainOrder: [
          { name: 'originSettler', type: 'address' },
          { name: 'user', type: 'address' },
          { name: 'nonce', type: 'uint256' },
          { name: 'originChainId', type: 'uint256' },
          { name: 'openDeadline', type: 'uint32' },
          { name: 'fillDeadline', type: 'uint32' },
          { name: 'orderDataType', type: 'bytes32' },
          { name: 'orderDataHash', type: 'bytes32' },
        ],
      }

      const values = {
        originSettler: await originSettler.getAddress(),
        user: creator.address,
        nonce,
        originChainId: Number(
          (await originSettler.runner?.provider?.getNetwork())?.chainId,
        ),
        openDeadline: expiry_open,
        fillDeadline: expiry_fill,
        orderDataType: ORDER_DATA_TYPEHASH,
        orderDataHash: keccak256(
          AbiCoder.defaultAbiCoder().encode(
            [
              'tuple(uint64,bytes32,uint64,bytes,tuple(uint64,bytes32,bytes32,uint256,tuple(bytes32,uint256)[]))',
            ],
            [
              [
                chainId, // destination
                ethers.zeroPadValue(await inbox.getAddress(), 32), // portal
                expiry_fill, // deadline
                encodeRoute(route), // route bytes
                [
                  expiry_fill, // reward.deadline
                  ethers.zeroPadValue(creator.address, 32), // reward.creator
                  ethers.zeroPadValue(await prover.getAddress(), 32), // reward.prover
                  reward.nativeValue, // reward.nativeValue
                  reward.tokens.map((t) => [
                    ethers.zeroPadValue(t.token, 32),
                    t.amount,
                  ]), // reward.tokens
                ],
              ],
            ],
          ),
        ),
      }
      signature = await creator.signTypedData(domain, types, values)
    })

    describe('onchainCrosschainOrder', async () => {
      it('publishes and transfers via open, checks native overfund', async () => {
        const provider: Provider = originSettler.runner!.provider!
        expect(
          await portal.isIntentFunded({
            destination: chainId,
            route,
            reward: { ...reward, nativeValue: reward.nativeValue },
          }),
        ).to.be.false

        const creatorInitialNativeBalance: bigint = await provider.getBalance(
          creator.address,
        )

        await tokenA
          .connect(creator)
          .approve(await originSettler.getAddress(), mintAmount)
        await tokenB
          .connect(creator)
          .approve(await originSettler.getAddress(), 2 * mintAmount)

        await expect(
          originSettler.connect(creator).open(onchainCrosschainOrder, {
            value: rewardNativeEth * BigInt(2),
          }),
        )
          .to.emit(portal, 'IntentPublished')
          .withArgs(
            intentHash,
            chainId,
            await creator.getAddress(),
            await prover.getAddress(),
            expiry_fill,
            reward.nativeValue,
            rewardTokens.map(Object.values),
            encodeRoute(route),
          )
          .to.emit(originSettler, 'Open')
        expect(
          await portal.isIntentFunded({
            destination: chainId,
            route,
            reward: { ...reward, nativeValue: reward.nativeValue },
          }),
        ).to.be.true
        expect(
          await provider.getBalance(
            await portal.intentVaultAddress({
              destination: chainId,
              route,
              reward,
            }),
          ),
        ).to.eq(rewardNativeEth)
        expect(await provider.getBalance(creator.address)).to.be.gt(
          creatorInitialNativeBalance - BigInt(2) * rewardNativeEth,
        )
      })
      it('publishes without transferring if intent is already funded, and refunds native', async () => {
        const provider: Provider = originSettler.runner!.provider!

        const vaultAddress = await portal.intentVaultAddress({
          destination: chainId,
          route,
          reward,
        })
        await tokenA.connect(creator).transfer(vaultAddress, mintAmount)
        await tokenB.connect(creator).transfer(vaultAddress, 2 * mintAmount)
        await creator.sendTransaction({
          to: vaultAddress,
          value: reward.nativeValue,
        })

        const creatorInitialNativeBalance: bigint = await provider.getBalance(
          creator.address,
        )

        expect(
          await portal.isIntentFunded({
            destination: chainId,
            route,
            reward: { ...reward, nativeValue: reward.nativeValue },
          }),
        ).to.be.true

        expect(await tokenA.balanceOf(creator)).to.eq(0)
        expect(await tokenB.balanceOf(creator)).to.eq(0)

        await tokenA
          .connect(creator)
          .approve(await originSettler.getAddress(), mintAmount)
        await tokenB
          .connect(creator)
          .approve(await originSettler.getAddress(), 2 * mintAmount)
        await expect(
          originSettler
            .connect(creator)
            .open(onchainCrosschainOrder, { value: rewardNativeEth }),
        ).to.not.be.reverted

        expect(await provider.getBalance(vaultAddress)).to.eq(rewardNativeEth)
        expect(await provider.getBalance(creator.address)).to.be.gt(
          creatorInitialNativeBalance - rewardNativeEth,
        )
      })
      it('publishes without transferring if intent is already funded', async () => {
        const vaultAddress = await portal.intentVaultAddress({
          destination: chainId,
          route,
          reward,
        })
        await tokenA.connect(creator).transfer(vaultAddress, mintAmount)
        await tokenB.connect(creator).transfer(vaultAddress, 2 * mintAmount)
        await creator.sendTransaction({
          to: vaultAddress,
          value: reward.nativeValue,
        })

        expect(
          await portal.isIntentFunded({
            destination: chainId,
            route,
            reward: { ...reward, nativeValue: reward.nativeValue },
          }),
        ).to.be.true

        expect(await tokenA.balanceOf(creator)).to.eq(0)
        expect(await tokenB.balanceOf(creator)).to.eq(0)

        await tokenA
          .connect(creator)
          .approve(await originSettler.getAddress(), mintAmount)
        await tokenB
          .connect(creator)
          .approve(await originSettler.getAddress(), 2 * mintAmount)
        await expect(
          originSettler
            .connect(creator)
            .open(onchainCrosschainOrder, { value: rewardNativeEth }),
        ).to.not.be.reverted
      })
      it('resolves onchainCrosschainOrder', async () => {
        const resolvedOrder: ResolvedCrossChainOrderStruct =
          await originSettler.resolve(onchainCrosschainOrder)

        expect(resolvedOrder.user).to.eq(onchainCrosschainOrderData.creator)
        expect(resolvedOrder.originChainId).to.eq(
          Number((await originSettler.runner?.provider?.getNetwork())?.chainId),
        )
        expect(resolvedOrder.openDeadline).to.eq(
          onchainCrosschainOrder.fillDeadline,
        ) //for onchainCrosschainOrders openDeadline is the same as fillDeadline, since openDeadline is meaningless due to it being opened by the creator
        expect(resolvedOrder.fillDeadline).to.eq(
          onchainCrosschainOrder.fillDeadline,
        )
        expect(resolvedOrder.orderId).to.eq(intentHash)
        expect(resolvedOrder.maxSpent.length).to.eq(routeTokens.length)
        for (let i = 0; i < resolvedOrder.maxSpent.length; i++) {
          expect(resolvedOrder.maxSpent[i].token).to.eq(
            ethers.zeroPadValue(route.tokens[i].token, 32),
          )
          expect(resolvedOrder.maxSpent[i].amount).to.eq(route.tokens[i].amount)
          expect(resolvedOrder.maxSpent[i].recipient).to.eq(
            ethers.zeroPadValue(ethers.ZeroAddress, 32),
          )
          expect(resolvedOrder.maxSpent[i].chainId).to.eq(chainId)
        }

        expect(resolvedOrder.minReceived.length).to.eq(
          reward.tokens.length + (reward.nativeValue > 0 ? 1 : 0),
        )
        for (let i = 0; i < resolvedOrder.minReceived.length - 1; i++) {
          expect(resolvedOrder.minReceived[i].token).to.eq(
            ethers.zeroPadValue(reward.tokens[i].token, 32),
          )
          expect(resolvedOrder.minReceived[i].amount).to.eq(
            reward.tokens[i].amount,
          )
          expect(resolvedOrder.minReceived[i].recipient).to.eq(
            ethers.zeroPadValue(ethers.ZeroAddress, 32),
          )
          expect(resolvedOrder.minReceived[i].chainId).to.eq(chainId)
        }
        const i = resolvedOrder.minReceived.length - 1
        expect(resolvedOrder.minReceived[i].token).to.eq(
          ethers.zeroPadValue(ethers.ZeroAddress, 32),
        )
        expect(resolvedOrder.minReceived[i].amount).to.eq(reward.nativeValue)
        expect(resolvedOrder.minReceived[i].recipient).to.eq(
          ethers.zeroPadValue(ethers.ZeroAddress, 32),
        )
        expect(resolvedOrder.minReceived[i].chainId).to.eq(chainId)
        expect(resolvedOrder.fillInstructions.length).to.eq(1)
        const fillInstruction = resolvedOrder.fillInstructions[0]
        expect(fillInstruction.destination).to.eq(chainId)
        expect(fillInstruction.destinationSettler).to.eq(
          ethers.zeroPadValue(await inbox.getAddress(), 32),
        )
        expect(fillInstruction.originData).to.eq(encodeIntent(intent))
      })
    })

    describe('gaslessCrosschainOrder', async () => {
      it('creates via openFor', async () => {
        expect(
          await portal.isIntentFunded({
            destination: chainId,
            route,
            reward: { ...reward, nativeValue: reward.nativeValue },
          }),
        ).to.be.false

        await tokenA
          .connect(creator)
          .approve(await originSettler.getAddress(), mintAmount)
        await tokenB
          .connect(creator)
          .approve(await originSettler.getAddress(), 2 * mintAmount)

        await expect(
          originSettler
            .connect(otherPerson)
            .openFor(gaslessCrosschainOrder, signature, '0x', {
              value: rewardNativeEth,
            }),
        )
          .to.emit(portal, 'IntentPublished')
          .and.to.emit(originSettler, 'Open')

        expect(
          await portal.isIntentFunded({
            destination: chainId,
            route,
            reward: { ...reward, nativeValue: reward.nativeValue },
          }),
        ).to.be.true
      })
      it('errors if openFor is called when openDeadline has passed', async () => {
        await time.increaseTo(expiry_open + 1)
        await expect(
          originSettler
            .connect(otherPerson)
            .openFor(gaslessCrosschainOrder, signature, '0x', {
              value: rewardNativeEth,
            }),
        ).to.be.revertedWithCustomError(originSettler, 'OpenDeadlinePassed')
      })
      it('errors if signature does not match', async () => {
        //TODO investigate why this sometimes reverts with our custom error BadSignature and othere times with ECDSAInvalidSignature
        await expect(
          originSettler
            .connect(otherPerson)
            .openFor(
              gaslessCrosschainOrder,
              signature.replace('1', '0'),
              '0x',
              { value: rewardNativeEth },
            ),
        ).to.be.reverted
      })
      it('resolvesFor gaslessCrosschainOrder', async () => {
        const resolvedOrder: ResolvedCrossChainOrderStruct =
          await originSettler.resolveFor(gaslessCrosschainOrder, '0x')
        expect(resolvedOrder.user).to.eq(gaslessCrosschainOrder.user)
        expect(resolvedOrder.originChainId).to.eq(
          gaslessCrosschainOrder.originChainId,
        )
        expect(resolvedOrder.openDeadline).to.eq(
          gaslessCrosschainOrder.openDeadline,
        )
        expect(resolvedOrder.fillDeadline).to.eq(
          gaslessCrosschainOrder.fillDeadline,
        )
        expect(resolvedOrder.orderId).to.eq(intentHash)
        expect(resolvedOrder.maxSpent.length).to.eq(routeTokens.length)
        for (let i = 0; i < resolvedOrder.maxSpent.length; i++) {
          expect(resolvedOrder.maxSpent[i].token).to.eq(
            ethers.zeroPadValue(route.tokens[i].token, 32),
          )
          expect(resolvedOrder.maxSpent[i].amount).to.eq(route.tokens[i].amount)
          expect(resolvedOrder.maxSpent[i].recipient).to.eq(
            ethers.zeroPadValue(ethers.ZeroAddress, 32),
          )
          expect(resolvedOrder.maxSpent[i].chainId).to.eq(chainId)
        }
        expect(resolvedOrder.minReceived.length).to.eq(
          reward.tokens.length + (reward.nativeValue > 0 ? 1 : 0),
        )
        for (let i = 0; i < resolvedOrder.minReceived.length - 1; i++) {
          expect(resolvedOrder.minReceived[i].token).to.eq(
            ethers.zeroPadValue(reward.tokens[i].token, 32),
          )
          expect(resolvedOrder.minReceived[i].amount).to.eq(
            reward.tokens[i].amount,
          )
          expect(resolvedOrder.minReceived[i].recipient).to.eq(
            ethers.zeroPadValue(ethers.ZeroAddress, 32),
          )
          expect(resolvedOrder.minReceived[i].chainId).to.eq(
            gaslessCrosschainOrderData.destination,
          )
        }
        const i = resolvedOrder.minReceived.length - 1
        expect(resolvedOrder.minReceived[i].token).to.eq(
          ethers.zeroPadValue(ethers.ZeroAddress, 32),
        )
        expect(resolvedOrder.minReceived[i].amount).to.eq(reward.nativeValue)
        expect(resolvedOrder.minReceived[i].recipient).to.eq(
          ethers.zeroPadValue(ethers.ZeroAddress, 32),
        )
        expect(resolvedOrder.minReceived[i].chainId).to.eq(
          gaslessCrosschainOrderData.destination,
        )
        expect(resolvedOrder.fillInstructions.length).to.eq(1)
        const fillInstruction = resolvedOrder.fillInstructions[0]
        expect(fillInstruction.destination).to.eq(chainId)
        expect(fillInstruction.destinationSettler).to.eq(
          ethers.zeroPadValue(await inbox.getAddress(), 32),
        )
        expect(fillInstruction.originData).to.eq(encodeIntent(intent))
      })
    })
  })
})
