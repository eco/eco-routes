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
  const mintAmount: bigint = 1000n

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
      'OrderData(uint64 destination,bytes route,Reward reward,bytes32 routePortal,uint64 routeDeadline,Output[] maxSpent)Output(bytes32 token,uint256 amount,bytes32 recipient,uint256 chainId)Reward(uint64 deadline,address creator,address prover,uint256 nativeValue,TokenAmount[] tokens)TokenAmount(address token,uint256 amount)',
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
    await tokenB.connect(creator).mint(creator.address, mintAmount * 2n)

    await tokenA.connect(creator).approve(originSettler, mintAmount)
    await tokenB.connect(creator).approve(originSettler, mintAmount * 2n)
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
        { token: await tokenB.getAddress(), amount: mintAmount * 2n },
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
        route: encodeRoute(route),
        reward: reward,
        routePortal: ethers.zeroPadValue(await inbox.getAddress(), 32),
        routeDeadline: expiry_fill,
        maxSpent: routeTokens.map((token) => ({
          token: ethers.zeroPadValue(token.token, 32),
          amount: token.amount,
          recipient: ethers.zeroPadValue(ethers.ZeroAddress, 32),
          chainId: chainId,
        })),
      }

      onchainCrosschainOrder = {
        fillDeadline: expiry_fill,
        orderDataType: ORDER_DATA_TYPEHASH,
        orderData: AbiCoder.defaultAbiCoder().encode(
          [
            'tuple(uint64,bytes,tuple(uint64,address,address,uint256,tuple(address,uint256)[]),bytes32,uint64,tuple(bytes32,uint256,bytes32,uint256)[])',
          ],
          [
            [
              chainId, // destination
              encodeRoute(route), // route bytes
              [
                reward.deadline, // reward.deadline
                reward.creator, // reward.creator (address, not bytes32)
                reward.prover, // reward.prover (address, not bytes32)
                reward.nativeValue, // reward.nativeValue
                reward.tokens.map((token) => [token.token, token.amount]), // TokenAmount[] with proper structure
              ],
              ethers.zeroPadValue(await inbox.getAddress(), 32), // routePortal
              expiry_fill, // routeDeadline
              routeTokens.map((token) => [
                ethers.zeroPadValue(token.token, 32),
                token.amount,
                ethers.zeroPadValue(ethers.ZeroAddress, 32),
                chainId,
              ]), // maxSpent
            ],
          ],
        ),
      }
      gaslessCrosschainOrderData = {
        destination: chainId,
        route: encodeRoute(route),
        reward: reward,
        routePortal: ethers.zeroPadValue(await inbox.getAddress(), 32),
        routeDeadline: expiry_fill,
        maxSpent: routeTokens.map((token) => ({
          token: ethers.zeroPadValue(token.token, 32),
          amount: token.amount,
          recipient: ethers.zeroPadValue(ethers.ZeroAddress, 32),
          chainId: chainId,
        })),
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
            'tuple(uint64,bytes,tuple(uint64,address,address,uint256,tuple(address,uint256)[]),bytes32,uint64,tuple(bytes32,uint256,bytes32,uint256)[])',
          ],
          [
            [
              chainId, // destination
              encodeRoute(route), // route bytes
              [
                reward.deadline, // reward.deadline
                reward.creator, // reward.creator (address, not bytes32)
                reward.prover, // reward.prover (address, not bytes32)
                reward.nativeValue, // reward.nativeValue
                reward.tokens.map((token) => [token.token, token.amount]), // TokenAmount[] with proper structure
              ],
              ethers.zeroPadValue(await inbox.getAddress(), 32), // routePortal
              expiry_fill, // routeDeadline
              routeTokens.map((token) => [
                ethers.zeroPadValue(token.token, 32),
                token.amount,
                ethers.zeroPadValue(ethers.ZeroAddress, 32),
                chainId,
              ]), // maxSpent
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
              'tuple(uint64,bytes,tuple(uint64,address,address,uint256,tuple(address,uint256)[]),bytes32,uint64,tuple(bytes32,uint256,bytes32,uint256)[])',
            ],
            [
              [
                chainId, // destination
                encodeRoute(route), // route bytes
                [
                  reward.deadline, // reward.deadline
                  reward.creator, // reward.creator
                  reward.prover, // reward.prover
                  reward.nativeValue, // reward.nativeValue
                  reward.tokens.map((token) => [token.token, token.amount]), // TokenAmount[] with proper structure
                ],
                ethers.zeroPadValue(await inbox.getAddress(), 32), // routePortal
                expiry_fill, // routeDeadline
                routeTokens.map((token) => [
                  ethers.zeroPadValue(token.token, 32),
                  token.amount,
                  ethers.zeroPadValue(ethers.ZeroAddress, 32),
                  chainId,
                ]), // maxSpent
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
          .approve(await originSettler.getAddress(), 2n * mintAmount)

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
        await tokenB.connect(creator).transfer(vaultAddress, 2n * mintAmount)
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
          .approve(await originSettler.getAddress(), 2n * mintAmount)
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
        await tokenB.connect(creator).transfer(vaultAddress, 2n * mintAmount)
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
          .approve(await originSettler.getAddress(), 2n * mintAmount)
        await expect(
          originSettler
            .connect(creator)
            .open(onchainCrosschainOrder, { value: rewardNativeEth }),
        ).to.not.be.reverted
      })
      it('resolves onchainCrosschainOrder', async () => {
        const resolvedOrder: ResolvedCrossChainOrderStruct =
          await originSettler.resolve(onchainCrosschainOrder)

        expect(resolvedOrder.user).to.eq(reward.creator)
        expect(resolvedOrder.originChainId).to.eq(
          Number((await originSettler.runner?.provider?.getNetwork())?.chainId),
        )
        // For onchain orders, openDeadline is block.timestamp when resolve() is called
        // since the order is immediately opened by the user
        expect(resolvedOrder.openDeadline).to.be.closeTo(
          Number(await time.latest()),
          100,
        ) // Allow small time difference due to test execution
        expect(resolvedOrder.fillDeadline).to.eq(
          expiry_fill, // Should match routeDeadline which is expiry_fill
        )
        expect(resolvedOrder.orderId).to.eq(intentHash)
        expect(resolvedOrder.maxSpent.length).to.eq(
          onchainCrosschainOrderData.maxSpent.length,
        )
        for (let i = 0; i < resolvedOrder.maxSpent.length; i++) {
          expect(resolvedOrder.maxSpent[i].token).to.eq(
            onchainCrosschainOrderData.maxSpent[i].token,
          )
          expect(resolvedOrder.maxSpent[i].amount).to.eq(
            onchainCrosschainOrderData.maxSpent[i].amount,
          )
          expect(resolvedOrder.maxSpent[i].recipient).to.eq(
            onchainCrosschainOrderData.maxSpent[i].recipient,
          )
          expect(resolvedOrder.maxSpent[i].chainId).to.eq(
            onchainCrosschainOrderData.maxSpent[i].chainId,
          )
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
            Number(
              (await originSettler.runner?.provider?.getNetwork())?.chainId,
            ),
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
          chainId, // native rewards go to destination chain
        )
        expect(resolvedOrder.fillInstructions.length).to.eq(1)
        const fillInstruction = resolvedOrder.fillInstructions[0]
        expect(fillInstruction.destinationChainId).to.eq(chainId)
        expect(fillInstruction.destinationSettler).to.eq(
          onchainCrosschainOrderData.routePortal,
        )
        // originData should be (route, rewardHash) not the full intent
        const rewardForEncoding = [
          reward.deadline,
          reward.creator,
          reward.prover,
          reward.nativeValue,
          reward.tokens.map((token) => [token.token, token.amount]),
        ]
        const expectedOriginData = AbiCoder.defaultAbiCoder().encode(
          ['bytes', 'bytes32'],
          [
            encodeRoute(route),
            keccak256(
              AbiCoder.defaultAbiCoder().encode(
                [
                  'tuple(uint64,address,address,uint256,tuple(address,uint256)[])',
                ],
                [rewardForEncoding],
              ),
            ),
          ],
        )
        expect(fillInstruction.originData).to.eq(expectedOriginData)
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

        // Ensure creator has enough tokens and approvals for gasless order
        await tokenA.connect(creator).mint(creator.address, mintAmount)
        await tokenB.connect(creator).mint(creator.address, mintAmount * 2n)
        await tokenA
          .connect(creator)
          .approve(await originSettler.getAddress(), mintAmount)
        await tokenB
          .connect(creator)
          .approve(await originSettler.getAddress(), mintAmount * 2n)

        await expect(
          originSettler
            .connect(otherPerson)
            .openFor(gaslessCrosschainOrder, signature, '0x', {
              value: rewardNativeEth, // Solver provides ETH for native rewards
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
          expiry_fill, // Should use routeDeadline from OrderData
        )
        expect(resolvedOrder.orderId).to.eq(intentHash)
        expect(resolvedOrder.maxSpent.length).to.eq(
          gaslessCrosschainOrderData.maxSpent.length,
        )
        for (let i = 0; i < resolvedOrder.maxSpent.length; i++) {
          expect(resolvedOrder.maxSpent[i].token).to.eq(
            gaslessCrosschainOrderData.maxSpent[i].token,
          )
          expect(resolvedOrder.maxSpent[i].amount).to.eq(
            gaslessCrosschainOrderData.maxSpent[i].amount,
          )
          expect(resolvedOrder.maxSpent[i].recipient).to.eq(
            gaslessCrosschainOrderData.maxSpent[i].recipient,
          )
          expect(resolvedOrder.maxSpent[i].chainId).to.eq(
            gaslessCrosschainOrderData.maxSpent[i].chainId,
          )
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
            Number(
              (await originSettler.runner?.provider?.getNetwork())?.chainId,
            ), // minReceived uses origin chain
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
          chainId, // native rewards go to destination chain
        )
        expect(resolvedOrder.fillInstructions.length).to.eq(1)
        const fillInstruction = resolvedOrder.fillInstructions[0]
        expect(fillInstruction.destinationChainId).to.eq(chainId)
        expect(fillInstruction.destinationSettler).to.eq(
          gaslessCrosschainOrderData.routePortal,
        )
        // originData should be (route, rewardHash) not the full intent
        const rewardForEncoding = [
          reward.deadline,
          reward.creator,
          reward.prover,
          reward.nativeValue,
          reward.tokens.map((token) => [token.token, token.amount]),
        ]
        const expectedOriginData = AbiCoder.defaultAbiCoder().encode(
          ['bytes', 'bytes32'],
          [
            encodeRoute(route),
            keccak256(
              AbiCoder.defaultAbiCoder().encode(
                [
                  'tuple(uint64,address,address,uint256,tuple(address,uint256)[])',
                ],
                [rewardForEncoding],
              ),
            ),
          ],
        )
        expect(fillInstruction.originData).to.eq(expectedOriginData)
      })
    })
  })
})
