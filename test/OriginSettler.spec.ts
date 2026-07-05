import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import {
  TestERC20,
  Portal,
  TestPolicy,
  Inbox,
  MulticallRuntime,
} from '../typechain-types'
import { time, loadFixture } from '@nomicfoundation/hardhat-network-helpers'
import { keccak256, BytesLike, Provider, AbiCoder } from 'ethers'
import { encodeTransfer } from '../utils/encode'
import {
  encodeRoute,
  encodeCalls,
  Call,
  TokenAmount,
  RewardToken,
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
  let prover: TestPolicy
  let inbox: Inbox
  let multicallRuntime: MulticallRuntime
  let tokenA: TestERC20
  let tokenB: TestERC20
  let keeper: SignerWithAddress
  let otherPerson: SignerWithAddress
  const mintAmount: bigint = 1000n

  let salt: BytesLike
  let nonce: number
  let chainId: number
  let sourceChainId: number
  let routeTokens: TokenAmount[]
  let calls: Call[]
  let expiry_open: number
  let expiry_fill: number
  const rewardNativeEth: bigint = ethers.parseEther('2')
  let rewardTokens: RewardToken[]
  let route: Route
  let reward: Reward
  let intent: Intent
  let intentHash: BytesLike
  let onchainCrosschainOrder: OnchainCrossChainOrderStruct
  let onchainCrosschainOrderData: OnchainCrosschainOrderData
  let gaslessCrosschainOrderData: GaslessCrosschainOrderData
  let gaslessCrosschainOrder: GaslessCrossChainOrderStruct
  let signature: string

  // Use the correct ORDER_DATA_TYPEHASH from the contract (v3 rate+flat Reward shape)
  const ORDER_DATA_TYPEHASH = ethers.keccak256(
    ethers.toUtf8Bytes(
      'OrderData(uint64 destination,bytes route,Reward reward,bytes32 routePortal,uint64 routeDeadline,Output[] maxSpent)Output(bytes32 token,uint256 amount,bytes32 recipient,uint256 chainId)Reward(uint64 deadline,address keeper,address prover,RewardToken[] tokens)RewardToken(address token,uint256 rate,uint256 flat)',
    ),
  )

  async function deploySourceFixture(): Promise<{
    originSettler: Portal
    portal: Portal
    prover: TestPolicy
    multicallRuntime: MulticallRuntime
    tokenA: TestERC20
    tokenB: TestERC20
    keeper: SignerWithAddress
    otherPerson: SignerWithAddress
  }> {
    const [keeper, owner, otherPerson] = await ethers.getSigners()

    const portalFactory = await ethers.getContractFactory('Portal')
    const portal = await portalFactory.deploy()
    inbox = await ethers.getContractAt('Inbox', await portal.getAddress())

    // deploy prover
    prover = await (
      await ethers.getContractFactory('TestPolicy')
    ).deploy(await inbox.getAddress())

    // deploy the default v3 route runtime
    const multicallRuntime = await (
      await ethers.getContractFactory('MulticallRuntime')
    ).deploy()

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
      multicallRuntime,
      tokenA,
      tokenB,
      keeper,
      otherPerson,
    }
  }

  async function mintAndApprove() {
    await tokenA.connect(keeper).mint(keeper.address, mintAmount)
    await tokenB.connect(keeper).mint(keeper.address, mintAmount * 2n)

    await tokenA.connect(keeper).approve(originSettler, mintAmount)
    await tokenB.connect(keeper).approve(originSettler, mintAmount * 2n)
  }

  beforeEach(async (): Promise<void> => {
    ;({
      originSettler,
      portal,
      prover,
      multicallRuntime,
      tokenA,
      tokenB,
      keeper,
      otherPerson,
    } = await loadFixture(deploySourceFixture))

    // fund the keeper and approve it to create an intent
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
      // `open()`/`openFor()` commit `source == block.chainid` (Model C) at open time, which is the
      // *actual* local network's chain id -- distinct from the fixture's arbitrary `destination` (1).
      sourceChainId = Number((await ethers.provider.getNetwork()).chainId)
      routeTokens = [{ token: await tokenA.getAddress(), amount: mintAmount }]
      calls = [
        {
          target: await tokenA.getAddress(),
          data: await encodeTransfer(keeper.address, mintAmount),
          value: 0,
        },
      ]
      // v3 reward legs (rate+flat). Native reward folds in as the last leg (token == address(0)).
      rewardTokens = [
        { token: await tokenA.getAddress(), rate: 0n, flat: mintAmount },
        { token: await tokenB.getAddress(), rate: 0n, flat: mintAmount * 2n },
        { token: ethers.ZeroAddress, rate: 0n, flat: rewardNativeEth },
      ]
      salt =
        '0x0000000000000000000000000000000000000000000000000000000000000001'
      nonce = 1
      route = {
        salt,
        deadline: expiry_fill,
        portal: await inbox.getAddress(),
        keeper: keeper.address,
        runtime: await multicallRuntime.getAddress(),
        payload: encodeCalls(calls),
        minTokens: routeTokens,
      }
      reward = {
        keeper: keeper.address,
        prover: await prover.getAddress(),
        deadline: expiry_fill,
        tokens: rewardTokens,
      }
      intent = {
        source: sourceChainId,
        destination: chainId,
        route: route,
        reward: reward,
      }
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
            'tuple(uint64,bytes,tuple(uint64,address,address,tuple(address,uint256,uint256)[]),bytes32,uint64,tuple(bytes32,uint256,bytes32,uint256)[])',
          ],
          [
            [
              chainId, // destination
              encodeRoute(route), // route bytes
              [
                reward.deadline, // reward.deadline
                reward.keeper, // reward.keeper (address, not bytes32)
                reward.prover, // reward.prover (address, not bytes32)
                reward.tokens.map((token) => [
                  token.token,
                  token.rate,
                  token.flat,
                ]), // TokenAmount[] with proper structure
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
        user: keeper.address,
        nonce: nonce,
        originChainId: Number(
          (await originSettler.runner?.provider?.getNetwork())?.chainId,
        ),
        openDeadline: expiry_open,
        fillDeadline: expiry_fill,
        orderDataType: ORDER_DATA_TYPEHASH,
        orderData: AbiCoder.defaultAbiCoder().encode(
          [
            'tuple(uint64,bytes,tuple(uint64,address,address,tuple(address,uint256,uint256)[]),bytes32,uint64,tuple(bytes32,uint256,bytes32,uint256)[])',
          ],
          [
            [
              chainId, // destination
              encodeRoute(route), // route bytes
              [
                reward.deadline, // reward.deadline
                reward.keeper, // reward.keeper (address, not bytes32)
                reward.prover, // reward.prover (address, not bytes32)
                reward.tokens.map((token) => [
                  token.token,
                  token.rate,
                  token.flat,
                ]), // TokenAmount[] with proper structure
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
        user: keeper.address,
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
              'tuple(uint64,bytes,tuple(uint64,address,address,tuple(address,uint256,uint256)[]),bytes32,uint64,tuple(bytes32,uint256,bytes32,uint256)[])',
            ],
            [
              [
                chainId, // destination
                encodeRoute(route), // route bytes
                [
                  reward.deadline, // reward.deadline
                  reward.keeper, // reward.keeper
                  reward.prover, // reward.prover
                  reward.tokens.map((token) => [
                    token.token,
                    token.rate,
                    token.flat,
                  ]), // TokenAmount[] with proper structure
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
      signature = await keeper.signTypedData(domain, types, values)
    })

    describe('onchainCrosschainOrder', async () => {
      it('publishes and transfers via open, checks native overfund', async () => {
        const provider: Provider = originSettler.runner!.provider!
        expect(
          await portal.isIntentFunded({
            source: sourceChainId,
            destination: chainId,
            route,
            reward,
          }),
        ).to.be.false

        const keeperInitialNativeBalance: bigint = await provider.getBalance(
          keeper.address,
        )

        await tokenA
          .connect(keeper)
          .approve(await originSettler.getAddress(), mintAmount)
        await tokenB
          .connect(keeper)
          .approve(await originSettler.getAddress(), 2n * mintAmount)

        await expect(
          originSettler.connect(keeper).open(onchainCrosschainOrder, {
            value: rewardNativeEth * BigInt(2),
          }),
        )
          .to.emit(portal, 'IntentPublished')
          .withArgs(
            intentHash,
            chainId,
            encodeRoute(route),
            await keeper.getAddress(),
            await prover.getAddress(),
            expiry_fill,
            rewardTokens.map(Object.values),
          )
          .to.emit(originSettler, 'Open')
        expect(
          await portal.isIntentFunded({
            source: sourceChainId,
            destination: chainId,
            route,
            reward,
          }),
        ).to.be.true
        expect(
          await provider.getBalance(
            await portal.intentAccountAddress({
              source: sourceChainId,
              destination: chainId,
              route,
              reward,
            }),
          ),
        ).to.eq(rewardNativeEth)
        expect(await provider.getBalance(keeper.address)).to.be.gt(
          keeperInitialNativeBalance - BigInt(2) * rewardNativeEth,
        )
      })
      it('publishes without transferring if intent is already funded, and refunds native', async () => {
        const provider: Provider = originSettler.runner!.provider!

        const accountAddress = await portal.intentAccountAddress({
          source: sourceChainId,
          destination: chainId,
          route,
          reward,
        })
        await tokenA.connect(keeper).transfer(accountAddress, mintAmount)
        await tokenB.connect(keeper).transfer(accountAddress, 2n * mintAmount)
        await keeper.sendTransaction({
          to: accountAddress,
          value: rewardNativeEth,
        })

        const keeperInitialNativeBalance: bigint = await provider.getBalance(
          keeper.address,
        )

        expect(
          await portal.isIntentFunded({
            source: sourceChainId,
            destination: chainId,
            route,
            reward,
          }),
        ).to.be.true

        expect(await tokenA.balanceOf(keeper)).to.eq(0)
        expect(await tokenB.balanceOf(keeper)).to.eq(0)

        await tokenA
          .connect(keeper)
          .approve(await originSettler.getAddress(), mintAmount)
        await tokenB
          .connect(keeper)
          .approve(await originSettler.getAddress(), 2n * mintAmount)
        await expect(
          originSettler
            .connect(keeper)
            .open(onchainCrosschainOrder, { value: rewardNativeEth }),
        ).to.not.be.reverted

        expect(await provider.getBalance(accountAddress)).to.eq(rewardNativeEth)
        expect(await provider.getBalance(keeper.address)).to.be.gt(
          keeperInitialNativeBalance - rewardNativeEth,
        )
      })
      it('publishes without transferring if intent is already funded', async () => {
        const accountAddress = await portal.intentAccountAddress({
          source: sourceChainId,
          destination: chainId,
          route,
          reward,
        })
        await tokenA.connect(keeper).transfer(accountAddress, mintAmount)
        await tokenB.connect(keeper).transfer(accountAddress, 2n * mintAmount)
        await keeper.sendTransaction({
          to: accountAddress,
          value: rewardNativeEth,
        })

        expect(
          await portal.isIntentFunded({
            source: sourceChainId,
            destination: chainId,
            route,
            reward,
          }),
        ).to.be.true

        expect(await tokenA.balanceOf(keeper)).to.eq(0)
        expect(await tokenB.balanceOf(keeper)).to.eq(0)

        await tokenA
          .connect(keeper)
          .approve(await originSettler.getAddress(), mintAmount)
        await tokenB
          .connect(keeper)
          .approve(await originSettler.getAddress(), 2n * mintAmount)
        await expect(
          originSettler
            .connect(keeper)
            .open(onchainCrosschainOrder, { value: rewardNativeEth }),
        ).to.not.be.reverted
      })
      it('resolves onchainCrosschainOrder', async () => {
        const resolvedOrder: ResolvedCrossChainOrderStruct =
          await originSettler.resolve(onchainCrosschainOrder)

        expect(resolvedOrder.user).to.eq(reward.keeper)
        expect(resolvedOrder.originChainId).to.eq(
          (await originSettler.runner?.provider?.getNetwork())?.chainId,
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

        expect(resolvedOrder.minReceived.length).to.eq(reward.tokens.length)
        for (let i = 0; i < resolvedOrder.minReceived.length - 1; i++) {
          expect(resolvedOrder.minReceived[i].token).to.eq(
            ethers.zeroPadValue(reward.tokens[i].token, 32),
          )
          expect(resolvedOrder.minReceived[i].amount).to.eq(
            reward.tokens[i].flat,
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
        expect(resolvedOrder.minReceived[i].amount).to.eq(reward.tokens[i].flat)
        expect(resolvedOrder.minReceived[i].recipient).to.eq(
          ethers.zeroPadValue(ethers.ZeroAddress, 32),
        )
        expect(resolvedOrder.minReceived[i].chainId).to.eq(
          (await originSettler.runner?.provider?.getNetwork())?.chainId,
        )
        expect(resolvedOrder.fillInstructions.length).to.eq(1)
        const fillInstruction = resolvedOrder.fillInstructions[0]
        expect(fillInstruction.destinationChainId).to.eq(chainId)
        expect(fillInstruction.destinationSettler).to.eq(
          onchainCrosschainOrderData.routePortal,
        )
        // originData is (source, route, rewardHash) -- Model C carries the committed `source` chain
        // id so the destination fill can re-derive the same hash.
        const rewardForEncoding = [
          reward.deadline,
          reward.keeper,
          reward.prover,
          reward.tokens.map((token) => [token.token, token.rate, token.flat]),
        ]
        const expectedOriginData = AbiCoder.defaultAbiCoder().encode(
          ['uint64', 'bytes', 'bytes32'],
          [
            sourceChainId,
            encodeRoute(route),
            keccak256(
              AbiCoder.defaultAbiCoder().encode(
                [
                  'tuple(uint64,address,address,tuple(address,uint256,uint256)[])',
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
            source: sourceChainId,
            destination: chainId,
            route,
            reward,
          }),
        ).to.be.false

        // Ensure keeper has enough tokens and approvals for gasless order
        await tokenA.connect(keeper).mint(keeper.address, mintAmount)
        await tokenB.connect(keeper).mint(keeper.address, mintAmount * 2n)
        await tokenA
          .connect(keeper)
          .approve(await originSettler.getAddress(), mintAmount)
        await tokenB
          .connect(keeper)
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
            source: sourceChainId,
            destination: chainId,
            route,
            reward,
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
        expect(resolvedOrder.minReceived.length).to.eq(reward.tokens.length)
        for (let i = 0; i < resolvedOrder.minReceived.length - 1; i++) {
          expect(resolvedOrder.minReceived[i].token).to.eq(
            ethers.zeroPadValue(reward.tokens[i].token, 32),
          )
          expect(resolvedOrder.minReceived[i].amount).to.eq(
            reward.tokens[i].flat,
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
        expect(resolvedOrder.minReceived[i].amount).to.eq(reward.tokens[i].flat)
        expect(resolvedOrder.minReceived[i].recipient).to.eq(
          ethers.zeroPadValue(ethers.ZeroAddress, 32),
        )
        expect(resolvedOrder.minReceived[i].chainId).to.eq(
          (await originSettler.runner?.provider?.getNetwork())?.chainId,
        )
        expect(resolvedOrder.fillInstructions.length).to.eq(1)
        const fillInstruction = resolvedOrder.fillInstructions[0]
        expect(fillInstruction.destinationChainId).to.eq(chainId)
        expect(fillInstruction.destinationSettler).to.eq(
          gaslessCrosschainOrderData.routePortal,
        )
        // originData is (source, route, rewardHash) -- Model C carries the committed `source` chain
        // id so the destination fill can re-derive the same hash.
        const rewardForEncoding = [
          reward.deadline,
          reward.keeper,
          reward.prover,
          reward.tokens.map((token) => [token.token, token.rate, token.flat]),
        ]
        const expectedOriginData = AbiCoder.defaultAbiCoder().encode(
          ['uint64', 'bytes', 'bytes32'],
          [
            sourceChainId,
            encodeRoute(route),
            keccak256(
              AbiCoder.defaultAbiCoder().encode(
                [
                  'tuple(uint64,address,address,tuple(address,uint256,uint256)[])',
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
