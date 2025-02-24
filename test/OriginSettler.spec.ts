import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import {
  TestERC20,
  IntentSource,
  TestProver,
  Inbox,
  Eco7683OriginSettler,
} from '../typechain-types'
import { time, loadFixture } from '@nomicfoundation/hardhat-network-helpers'
import { keccak256, BytesLike, Provider } from 'ethers'
import { encodeTransfer } from '../utils/encode'
import {
  encodeReward,
  encodeRoute,
  Call,
  TokenAmount,
  Route,
  Reward,
  Intent,
  encodeIntent,
} from '../utils/intent'
import {
  OnchainCrossChainOrderStruct,
  GaslessCrossChainOrderStruct,
  ResolvedCrossChainOrderStruct,
} from '../typechain-types/contracts/Eco7683OriginSettler'
import {
  GaslessCrosschainOrderData,
  OnchainCrosschainOrderData,
  encodeGaslessCrosschainOrderData,
  encodeOnchainCrosschainOrderData,
} from '../utils/EcoERC7683'

describe('Origin Settler Test', (): void => {
  let originSettler: Eco7683OriginSettler
  let intentSource: IntentSource
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
  let routeHash: BytesLike
  let rewardHash: BytesLike
  let intentHash: BytesLike
  let onchainCrosschainOrder: OnchainCrossChainOrderStruct
  let onchainCrosschainOrderData: OnchainCrosschainOrderData
  let gaslessCrosschainOrderData: GaslessCrosschainOrderData
  let gaslessCrosschainOrder: GaslessCrossChainOrderStruct
  let signature: string

  const name = 'Eco 7683 Origin Settler'
  const version = '1.5.0'

  const onchainCrosschainOrderDataTypehash: BytesLike =
    '0x5dd63cf8abd3430c6387c87b7d2af2290ba415b12c3f6fbc10af65f9aee8ec38'
  const gaslessCrosschainOrderDataTypehash: BytesLike =
    '0x834338e3ed54385a3fac8309f6f326a71fc399ffb7d77d7366c1e1b7c9feac6f'

  async function deploySourceFixture(): Promise<{
    originSettler: Eco7683OriginSettler
    intentSource: IntentSource
    prover: TestProver
    tokenA: TestERC20
    tokenB: TestERC20
    creator: SignerWithAddress
    otherPerson: SignerWithAddress
  }> {
    const [creator, owner, otherPerson] = await ethers.getSigners()
    // deploy prover
    prover = await (await ethers.getContractFactory('TestProver')).deploy()

    const intentSourceFactory = await ethers.getContractFactory('IntentSource')
    const intentSource = await intentSourceFactory.deploy()
    inbox = await (
      await ethers.getContractFactory('Inbox')
    ).deploy(owner.address, false, [owner.address])

    const originSettlerFactory = await ethers.getContractFactory(
      'Eco7683OriginSettler',
    )
    const originSettler = await originSettlerFactory.deploy(
      name,
      version,
      await intentSource.getAddress(),
    )

    // deploy ERC20 test
    const erc20Factory = await ethers.getContractFactory('TestERC20')
    const tokenA = await erc20Factory.deploy('A', 'A')
    const tokenB = await erc20Factory.deploy('B', 'B')

    return {
      originSettler,
      intentSource,
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
    ;({
      originSettler,
      intentSource,
      prover,
      tokenA,
      tokenB,
      creator,
      otherPerson,
    } = await loadFixture(deploySourceFixture))

    // fund the creator and approve it to create an intent
    await mintAndApprove()
  })

  it('constructs', async () => {
    expect(await originSettler.INTENT_SOURCE()).to.be.eq(
      await intentSource.getAddress(),
    )
  })

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
        source: Number(
          (await originSettler.runner?.provider?.getNetwork())?.chainId,
        ),
        destination: chainId,
        inbox: await inbox.getAddress(),
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
      intent = { route: route, reward: reward }
      routeHash = keccak256(encodeRoute(route))
      rewardHash = keccak256(encodeReward(reward))
      intentHash = keccak256(
        ethers.solidityPacked(['bytes32', 'bytes32'], [routeHash, rewardHash]),
      )

      onchainCrosschainOrderData = {
        route,
        creator: creator.address,
        prover: await prover.getAddress(),
        nativeValue: reward.nativeValue,
        tokens: reward.tokens,
      }

      onchainCrosschainOrder = {
        fillDeadline: expiry_fill,
        orderDataType: onchainCrosschainOrderDataTypehash,
        orderData: await encodeOnchainCrosschainOrderData(
          onchainCrosschainOrderData,
        ),
      }
      gaslessCrosschainOrderData = {
        destination: chainId,
        inbox: await inbox.getAddress(),
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
        orderDataType: gaslessCrosschainOrderDataTypehash,
        orderData: await encodeGaslessCrosschainOrderData(
          gaslessCrosschainOrderData,
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
        orderDataType: gaslessCrosschainOrderDataTypehash,
        orderDataHash: keccak256(
          await encodeGaslessCrosschainOrderData(gaslessCrosschainOrderData),
        ),
      }
      signature = await creator.signTypedData(domain, types, values)
    })

    describe('onchainCrosschainOrder', async () => {
      it('publishes and transfers via open, checks native overfund', async () => {
        const provider: Provider = originSettler.runner!.provider!
        expect(
          await intentSource.isIntentFunded({
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
          .to.emit(intentSource, 'IntentCreated')
          .withArgs(
            intentHash,
            salt,
            Number(
              (await intentSource.runner?.provider?.getNetwork())?.chainId,
            ),
            chainId,
            await inbox.getAddress(),
            routeTokens.map(Object.values),
            calls.map(Object.values),
            await creator.getAddress(),
            await prover.getAddress(),
            expiry_fill,
            reward.nativeValue,
            rewardTokens.map(Object.values),
          )
          .to.emit(originSettler, 'Open')
        expect(
          await intentSource.isIntentFunded({
            route,
            reward: { ...reward, nativeValue: reward.nativeValue },
          }),
        ).to.be.true
        expect(
          await provider.getBalance(
            await intentSource.intentVaultAddress({ route, reward }),
          ),
        ).to.eq(rewardNativeEth)
        expect(await provider.getBalance(creator.address)).to.be.gt(
          creatorInitialNativeBalance - BigInt(2) * rewardNativeEth,
        )
      })
      it('publishes without transferring if intent is already funded, and refunds native', async () => {
        const provider: Provider = originSettler.runner!.provider!

        const vaultAddress = await intentSource.intentVaultAddress({
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
          await intentSource.isIntentFunded({
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
        const vaultAddress = await intentSource.intentVaultAddress({
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
          await intentSource.isIntentFunded({
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
          onchainCrosschainOrderData.route.source,
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
          expect(resolvedOrder.maxSpent[i].chainId).to.eq(
            onchainCrosschainOrderData.route.destination,
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
            onchainCrosschainOrderData.route.destination,
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
          onchainCrosschainOrderData.route.destination,
        )
        expect(resolvedOrder.fillInstructions.length).to.eq(1)
        const fillInstruction = resolvedOrder.fillInstructions[0]
        expect(fillInstruction.destinationChainId).to.eq(route.destination)
        expect(fillInstruction.destinationSettler).to.eq(
          ethers.zeroPadValue(await inbox.getAddress(), 32),
        )
        expect(fillInstruction.originData).to.eq(encodeIntent(intent))
      })
    })

    describe('gaslessCrosschainOrder', async () => {
      it('creates via openFor', async () => {
        expect(
          await intentSource.isIntentFunded({
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
          .to.emit(intentSource, 'IntentCreated')
          .and.to.emit(originSettler, 'Open')

        expect(
          await intentSource.isIntentFunded({
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
          expect(resolvedOrder.maxSpent[i].chainId).to.eq(
            onchainCrosschainOrderData.route.destination,
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
        expect(fillInstruction.destinationChainId).to.eq(route.destination)
        expect(fillInstruction.destinationSettler).to.eq(
          ethers.zeroPadValue(await inbox.getAddress(), 32),
        )
        expect(fillInstruction.originData).to.eq(encodeIntent(intent))
      })
    })
  })
})
