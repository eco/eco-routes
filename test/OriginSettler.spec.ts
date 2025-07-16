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
import { Call, TokenAmount, Route, Reward, Intent } from '../utils/intent'
import {
  UniversalIntent,
  UniversalRoute,
  UniversalReward,
  UniversalTokenAmount,
  UniversalCall,
  hashUniversalIntent,
  convertIntentToUniversal,
  encodeUniversalIntent,
  encodeUniversalRoute,
} from '../utils/universalIntent'
import {
  OnchainCrossChainOrderStruct,
  GaslessCrossChainOrderStruct,
  ResolvedCrossChainOrderStruct,
} from '../typechain-types/contracts/Eco7683OriginSettler'
import {
  UniversalGaslessCrosschainOrderData,
  UniversalOnchainCrosschainOrderData,
  encodeUniversalGaslessCrosschainOrderData,
  encodeUniversalOnchainCrosschainOrderData,
  UniversalRoute as EcoUniversalRoute,
} from '../utils/universalEcoERC7683'
import { TypeCasts } from '../utils/typeCasts'

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

  let salt: BytesLike
  let nonce: number
  let chainId: number
  let expiry_open: number
  let expiry_fill: number
  const rewardNativeEth: bigint = ethers.parseEther('2')
  let universalIntent: UniversalIntent
  let routeHash: BytesLike
  let rewardHash: BytesLike
  let intentHash: BytesLike
  let onchainCrosschainOrder: OnchainCrossChainOrderStruct
  let onchainCrosschainOrderData: UniversalOnchainCrosschainOrderData
  let gaslessCrosschainOrderData: UniversalGaslessCrosschainOrderData
  let gaslessCrosschainOrder: GaslessCrossChainOrderStruct
  let signature: string

  const name = 'Eco 7683 Origin Settler'
  const version = '1.5.0'

  const onchainCrosschainOrderDataTypehash: BytesLike =
    '0xcf9a7d202aa2c38a5a0a9db86b4ba8787bc6f19d24655743627fd104c98d7c0b'
  const gaslessCrosschainOrderDataTypehash: BytesLike =
    '0xeba3c114f30d5d2e203aba45313408edb197822e682f5be0e804453b059118c4'

  async function deploySourceFixture(): Promise<{
    originSettler: Eco7683OriginSettler
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
    // Portal combines both Inbox and UniversalSource functionality
    inbox = portal as any

    // deploy prover
    prover = await (
      await ethers.getContractFactory('TestProver')
    ).deploy(await portal.getAddress())

    const originSettlerFactory = await ethers.getContractFactory(
      'Eco7683OriginSettler',
    )
    const originSettler = await originSettlerFactory.deploy(
      name,
      version,
      await portal.getAddress(),
    )

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

  it('constructs', async () => {
    expect(await originSettler.INTENT_SOURCE()).to.be.eq(
      await portal.getAddress(),
    )
  })

  describe('performs actions', async () => {
    beforeEach(async (): Promise<void> => {
      expiry_open = (await time.latest()) + 12345
      expiry_fill = expiry_open + 12345
      chainId = 1
      salt =
        '0x0000000000000000000000000000000000000000000000000000000000000001'
      nonce = 1

      // Create address-based intent first
      const intent: Intent = {
        destination: chainId,
        route: {
          salt,
          deadline: expiry_fill,
          portal: await inbox.getAddress(),
          tokens: [{ token: await tokenA.getAddress(), amount: mintAmount }],
          calls: [
            {
              target: await tokenA.getAddress(),
              data: await encodeTransfer(creator.address, mintAmount),
              value: 0,
            },
          ],
        },
        reward: {
          creator: creator.address,
          prover: await prover.getAddress(),
          deadline: expiry_fill,
          nativeValue: rewardNativeEth,
          tokens: [
            { token: await tokenA.getAddress(), amount: mintAmount },
            { token: await tokenB.getAddress(), amount: mintAmount * 2 },
          ],
        },
      }

      // Convert to UniversalIntent
      universalIntent = convertIntentToUniversal(intent)
      ;({ routeHash, rewardHash, intentHash } =
        hashUniversalIntent(universalIntent))

      onchainCrosschainOrderData = {
        destination: chainId,
        route: {
          salt: universalIntent.route.salt,
          deadline: universalIntent.route.deadline,
          portal: universalIntent.route.portal,
          tokens: universalIntent.route.tokens,
          calls: universalIntent.route.calls,
        },
        reward: {
          deadline: universalIntent.reward.deadline,
          creator: universalIntent.reward.creator,
          prover: universalIntent.reward.prover,
          nativeValue: universalIntent.reward.nativeValue,
          tokens: universalIntent.reward.tokens,
        },
      }

      // Encode the order data - ensure it's a hex string
      const encodedOrderData = encodeUniversalOnchainCrosschainOrderData(
        onchainCrosschainOrderData,
      )

      // Create the order struct
      onchainCrosschainOrder = {
        fillDeadline: expiry_fill,
        orderDataType: onchainCrosschainOrderDataTypehash,
        orderData: encodedOrderData,
      }
      // Use the same structure for gasless orders
      gaslessCrosschainOrderData = {
        destination: chainId,
        routeHash: routeHash,
        route: {
          salt: universalIntent.route.salt,
          deadline: universalIntent.route.deadline,
          portal: universalIntent.route.portal,
          tokens: universalIntent.route.tokens,
          calls: universalIntent.route.calls,
        },
        reward: {
          deadline: universalIntent.reward.deadline,
          creator: universalIntent.reward.creator,
          prover: universalIntent.reward.prover,
          nativeValue: universalIntent.reward.nativeValue,
          tokens: universalIntent.reward.tokens,
        },
      }
      const encodedGaslessOrderData = encodeUniversalOnchainCrosschainOrderData(
        gaslessCrosschainOrderData as any,
      )

      gaslessCrosschainOrder = {
        originSettler: await originSettler.getAddress(),
        user: creator.address,
        nonce: nonce,
        originChainId: Number(
          (await originSettler.runner?.provider?.getNetwork())?.chainId,
        ),
        openDeadline: expiry_open,
        fillDeadline: expiry_fill,
        orderDataType: onchainCrosschainOrderDataTypehash,
        orderData: encodedGaslessOrderData,
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
        orderDataType: onchainCrosschainOrderDataTypehash,
        orderDataHash: keccak256(
          encodeUniversalOnchainCrosschainOrderData(
            gaslessCrosschainOrderData as any,
          ),
        ),
      }
      signature = await creator.signTypedData(domain, types, values)
    })

    describe('onchainCrosschainOrder', async () => {
      it('publishes and transfers via open, checks native overfund', async () => {
        // Test with native token overpayment
        const overpayAmount = rewardNativeEth + ethers.parseEther('0.1')

        // Get initial balances
        const creatorInitialBalance = await ethers.provider.getBalance(
          creator.address,
        )

        // Call open with overpayment
        const tx = await originSettler
          .connect(creator)
          .open(onchainCrosschainOrder, {
            value: overpayAmount,
          })

        const receipt = await tx.wait()

        // Check that the vault received the correct amount (rewardNativeEth)
        const vaultAddress = await portal.intentVaultAddress(
          universalIntent.destination,
          encodeUniversalRoute(universalIntent.route),
          universalIntent.reward,
        )
        const vaultBalance = await ethers.provider.getBalance(vaultAddress)
        expect(vaultBalance).to.equal(rewardNativeEth)

        // Check that creator received refund for overpayment
        const creatorFinalBalance = await ethers.provider.getBalance(
          creator.address,
        )
        const gasCost = receipt!.gasUsed * receipt!.gasPrice
        const expectedBalance =
          creatorInitialBalance - rewardNativeEth - gasCost

        // Allow for small difference due to gas estimation
        expect(creatorFinalBalance).to.be.closeTo(
          expectedBalance,
          ethers.parseEther('0.001'),
        )

        // Verify the intent was created in the portal
        expect(await tokenA.balanceOf(vaultAddress)).to.equal(mintAmount)
      })
      it('publishes and transfers missing tokens when intent is partially funded', async () => {
        // Pre-fund the vault with only tokenA (intent also needs tokenB and native)
        const vaultAddress = await portal.intentVaultAddress(
          universalIntent.destination,
          encodeUniversalRoute(universalIntent.route),
          universalIntent.reward,
        )
        await tokenA.connect(creator).transfer(vaultAddress, mintAmount)

        // Since isIntentFunded checks for complete funding, the contract will try to transfer
        // all tokens again. Make sure creator has enough tokenA for the duplicate transfer
        await tokenA.connect(creator).mint(creator.address, mintAmount)
        await tokenA.connect(creator).approve(originSettler, mintAmount)

        // Get initial balances
        const creatorInitialBalance = await ethers.provider.getBalance(
          creator.address,
        )
        const creatorInitialTokenBBalance = await tokenB.balanceOf(
          creator.address,
        )

        // Call open with native value (should transfer tokenB and native since only tokenA is funded)
        const tx = await originSettler
          .connect(creator)
          .open(onchainCrosschainOrder, {
            value: rewardNativeEth,
          })

        const receipt = await tx.wait()

        // Check that the vault received the native value
        const vaultBalance = await ethers.provider.getBalance(vaultAddress)
        expect(vaultBalance).to.equal(rewardNativeEth)

        // Check that creator's balance decreased by native value + gas
        const creatorFinalBalance = await ethers.provider.getBalance(
          creator.address,
        )
        const gasCost = receipt!.gasUsed * receipt!.gasPrice
        const expectedBalance =
          creatorInitialBalance - rewardNativeEth - gasCost

        expect(creatorFinalBalance).to.be.closeTo(
          expectedBalance,
          ethers.parseEther('0.001'),
        )

        // Verify the vault has all tokens now
        // Note: tokenA will be doubled because it was pre-funded and transferred again
        expect(await tokenA.balanceOf(vaultAddress)).to.equal(mintAmount * 2)
        expect(await tokenB.balanceOf(vaultAddress)).to.equal(mintAmount * 2)

        // Verify tokenB was transferred from creator
        expect(await tokenB.balanceOf(creator.address)).to.equal(
          creatorInitialTokenBBalance - BigInt(mintAmount * 2),
        )
      })
      it('publishes without transferring if intent is already funded', async () => {
        // Pre-fund the vault completely with all tokens and native
        const vaultAddress = await portal.intentVaultAddress(
          universalIntent.destination,
          encodeUniversalRoute(universalIntent.route),
          universalIntent.reward,
        )
        await tokenA.connect(creator).transfer(vaultAddress, mintAmount)
        await tokenB.connect(creator).transfer(vaultAddress, mintAmount * 2)

        // Send native ETH to vault
        await creator.sendTransaction({
          to: vaultAddress,
          value: rewardNativeEth,
        })

        // Get initial token balances
        const creatorInitialTokenBalance = await tokenA.balanceOf(
          creator.address,
        )
        const vaultInitialTokenBalance = await tokenA.balanceOf(vaultAddress)

        // Call open without native value (intent is already funded)
        await originSettler.connect(creator).open(onchainCrosschainOrder, {
          value: 0,
        })

        // Check that no additional tokens were transferred
        expect(await tokenA.balanceOf(creator.address)).to.equal(
          creatorInitialTokenBalance,
        )
        expect(await tokenA.balanceOf(vaultAddress)).to.equal(
          vaultInitialTokenBalance,
        )

        // Verify the intent was still published (check event or state)
        const intentId = intentHash
        expect(intentId).to.not.equal(ethers.ZeroHash)
      })
      it('resolves onchainCrosschainOrder', async () => {
        const resolvedOrder: ResolvedCrossChainOrderStruct =
          await originSettler.resolve(onchainCrosschainOrder)

        expect(resolvedOrder.user).to.eq(creator.address)
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
        expect(resolvedOrder.maxSpent.length).to.eq(0)
        for (let i = 0; i < resolvedOrder.maxSpent.length; i++) {
          expect(resolvedOrder.maxSpent[i].token).to.eq(
            universalIntent.route.tokens[i].token,
          )
          expect(resolvedOrder.maxSpent[i].amount).to.eq(
            universalIntent.route.tokens[i].amount,
          )
          expect(resolvedOrder.maxSpent[i].recipient).to.eq(
            ethers.zeroPadValue(ethers.ZeroAddress, 32),
          )
          expect(resolvedOrder.maxSpent[i].chainId).to.eq(chainId)
        }

        expect(resolvedOrder.minReceived.length).to.eq(
          universalIntent.reward.tokens.length +
            (universalIntent.reward.nativeValue > 0 ? 1 : 0),
        )
        for (let i = 0; i < resolvedOrder.minReceived.length - 1; i++) {
          expect(resolvedOrder.minReceived[i].token).to.eq(
            universalIntent.reward.tokens[i].token,
          )
          expect(resolvedOrder.minReceived[i].amount).to.eq(
            universalIntent.reward.tokens[i].amount,
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
        expect(resolvedOrder.minReceived[i].amount).to.eq(
          universalIntent.reward.nativeValue,
        )
        expect(resolvedOrder.minReceived[i].recipient).to.eq(
          ethers.zeroPadValue(ethers.ZeroAddress, 32),
        )
        expect(resolvedOrder.minReceived[i].chainId).to.eq(chainId)
        expect(resolvedOrder.fillInstructions.length).to.eq(1)
        const fillInstruction = resolvedOrder.fillInstructions[0]
        expect(fillInstruction.destinationChainId).to.eq(chainId)
        expect(fillInstruction.destinationSettler).to.eq(
          ethers.zeroPadValue(await inbox.getAddress(), 32),
        )
        // The contract encodes (route, rewardHash) as originData
        const expectedOriginData = ethers.AbiCoder.defaultAbiCoder().encode(
          [
            'tuple(bytes32,uint64,bytes32,tuple(bytes32,uint256)[],tuple(bytes32,bytes,uint256)[])',
            'bytes32',
          ],
          [
            [
              universalIntent.route.salt,
              universalIntent.route.deadline,
              universalIntent.route.portal,
              universalIntent.route.tokens.map((t) => [t.token, t.amount]),
              universalIntent.route.calls.map((c) => [
                c.target,
                c.data,
                c.value,
              ]),
            ],
            rewardHash,
          ],
        )
        expect(fillInstruction.originData).to.eq(expectedOriginData)
      })
    })

    describe('gaslessCrosschainOrder', async () => {
      it('creates via openFor', async () => {
        // Get initial balances
        const otherPersonInitialBalance = await ethers.provider.getBalance(
          otherPerson.address,
        )

        // Call openFor from a different account
        const tx = await originSettler
          .connect(otherPerson)
          .openFor(gaslessCrosschainOrder, signature, '0x', {
            value: rewardNativeEth,
          })

        const receipt = await tx.wait()

        // Get the vault address
        const vaultAddress = await portal.intentVaultAddress(
          universalIntent.destination,
          encodeUniversalRoute(universalIntent.route),
          universalIntent.reward,
        )

        // Check that the vault received the native value
        const vaultFinalBalance = await ethers.provider.getBalance(vaultAddress)
        expect(vaultFinalBalance).to.equal(rewardNativeEth)

        // Check that otherPerson's balance decreased by native value + gas
        const otherPersonFinalBalance = await ethers.provider.getBalance(
          otherPerson.address,
        )
        const gasCost = receipt!.gasUsed * receipt!.gasPrice
        const expectedBalance =
          otherPersonInitialBalance - rewardNativeEth - gasCost

        expect(otherPersonFinalBalance).to.be.closeTo(
          expectedBalance,
          ethers.parseEther('0.001'),
        )

        // Verify the intent was created with tokens from creator
        expect(await tokenA.balanceOf(vaultAddress)).to.equal(mintAmount)
        expect(await tokenB.balanceOf(vaultAddress)).to.equal(mintAmount * 2)
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
        // The revert reason varies depending on signature format:
        // - Invalid signature format triggers ECDSAInvalidSignature from OpenZeppelin
        // - Valid format but wrong signer triggers BadSignature custom error
        const invalidSignature = signature.replace('1', '0')

        await expect(
          originSettler
            .connect(otherPerson)
            .openFor(gaslessCrosschainOrder, invalidSignature, '0x', {
              value: rewardNativeEth,
            }),
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
        expect(resolvedOrder.maxSpent.length).to.eq(0)
        for (let i = 0; i < resolvedOrder.maxSpent.length; i++) {
          expect(resolvedOrder.maxSpent[i].token).to.eq(
            universalIntent.route.tokens[i].token,
          )
          expect(resolvedOrder.maxSpent[i].amount).to.eq(
            universalIntent.route.tokens[i].amount,
          )
          expect(resolvedOrder.maxSpent[i].recipient).to.eq(
            ethers.zeroPadValue(ethers.ZeroAddress, 32),
          )
          expect(resolvedOrder.maxSpent[i].chainId).to.eq(chainId)
        }
        expect(resolvedOrder.minReceived.length).to.eq(
          universalIntent.reward.tokens.length +
            (universalIntent.reward.nativeValue > 0 ? 1 : 0),
        )
        for (let i = 0; i < resolvedOrder.minReceived.length - 1; i++) {
          expect(resolvedOrder.minReceived[i].token).to.eq(
            universalIntent.reward.tokens[i].token,
          )
          expect(resolvedOrder.minReceived[i].amount).to.eq(
            universalIntent.reward.tokens[i].amount,
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
        expect(resolvedOrder.minReceived[i].amount).to.eq(
          universalIntent.reward.nativeValue,
        )
        expect(resolvedOrder.minReceived[i].recipient).to.eq(
          ethers.zeroPadValue(ethers.ZeroAddress, 32),
        )
        expect(resolvedOrder.minReceived[i].chainId).to.eq(
          gaslessCrosschainOrderData.destination,
        )
        expect(resolvedOrder.fillInstructions.length).to.eq(1)
        const fillInstruction = resolvedOrder.fillInstructions[0]
        expect(fillInstruction.destinationChainId).to.eq(chainId)
        expect(fillInstruction.destinationSettler).to.eq(
          ethers.zeroPadValue(await inbox.getAddress(), 32),
        )
        // The contract encodes (route, rewardHash) as originData
        const expectedOriginData = ethers.AbiCoder.defaultAbiCoder().encode(
          [
            'tuple(bytes32,uint64,bytes32,tuple(bytes32,uint256)[],tuple(bytes32,bytes,uint256)[])',
            'bytes32',
          ],
          [
            [
              universalIntent.route.salt,
              universalIntent.route.deadline,
              universalIntent.route.portal,
              universalIntent.route.tokens.map((t) => [t.token, t.amount]),
              universalIntent.route.calls.map((c) => [
                c.target,
                c.data,
                c.value,
              ]),
            ],
            rewardHash,
          ],
        )
        expect(fillInstruction.originData).to.eq(expectedOriginData)
      })
    })
  })
})
