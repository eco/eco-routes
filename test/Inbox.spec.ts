import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import { TestERC20, Inbox, Portal, TestProver } from '../typechain-types'
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
import { addressToBytes32 } from '../utils/typeCasts'
import {
  UniversalIntent,
  UniversalRoute,
  UniversalReward,
  hashUniversalIntent,
  convertIntentToUniversal,
  encodeUniversalRoute,
  encodeUniversalReward,
} from '../utils/universalIntent'
import { TypeCasts } from '../utils/typeCasts'

// Helper function to convert UniversalRoute to Route for the fulfill function
function universalRouteToRoute(universalRoute: UniversalRoute): Route {
  return {
    salt: universalRoute.salt,
    deadline: universalRoute.deadline,
    portal: TypeCasts.bytes32ToAddress(universalRoute.portal),
    tokens: universalRoute.tokens.map((token) => ({
      token: TypeCasts.bytes32ToAddress(token.token),
      amount: token.amount,
    })),
    calls: universalRoute.calls.map((call) => ({
      target: TypeCasts.bytes32ToAddress(call.target),
      data: call.data,
      value: call.value,
    })),
  }
}

describe('Inbox Test', (): void => {
  let inbox: Inbox
  let erc20: TestERC20
  let owner: SignerWithAddress
  let solver: SignerWithAddress
  let dstAddr: SignerWithAddress
  let universalIntent: UniversalIntent
  let universalRoute: UniversalRoute
  let universalReward: UniversalReward
  let rewardHash: string
  let intentHash: string
  let otherHash: string
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
    const portalFactory = await ethers.getContractFactory('Portal')
    const portal = await portalFactory.deploy()
    const inbox = await ethers.getContractAt('Inbox', await portal.getAddress())
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
    universalIntent: UniversalIntent
    universalRoute: UniversalRoute
    universalReward: UniversalReward
    rewardHash: string
    intentHash: string
  }> {
    erc20Address = await erc20.getAddress()
    const _calldata = await encodeTransfer(dstAddr.address, amount)
    const _timestamp = (await time.latest()) + timeDelta

    // Create address-based intent first
    const _intent = {
      destination: Number((await owner.provider.getNetwork()).chainId),
      route: {
        salt,
        deadline: _timestamp,
        portal: await inbox.getAddress(),
        tokens: [{ token: await erc20.getAddress(), amount: amount }],
        calls: [
          {
            target: erc20Address,
            data: _calldata,
            value: 0,
          },
        ],
      },
      reward: {
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
      },
    }

    // Convert to UniversalIntent
    const universalIntent = convertIntentToUniversal(_intent)
    const { rewardHash: _rewardHash, intentHash: _intentHash } =
      hashUniversalIntent(universalIntent)

    return {
      universalIntent,
      universalRoute: universalIntent.route,
      universalReward: universalIntent.reward,
      rewardHash: _rewardHash,
      intentHash: _intentHash,
    }
  }
  beforeEach(async (): Promise<void> => {
    ;({ inbox, erc20, owner, solver, dstAddr } =
      await loadFixture(deployInboxFixture))
    ;({
      universalIntent,
      universalRoute,
      universalReward,
      rewardHash,
      intentHash,
    } = await createIntentData(mintAmount, timeDelta))
    mockProver = await (
      await ethers.getContractFactory('TestProver')
    ).deploy(await inbox.getAddress())
  })

  describe('fulfill when the intent is invalid', () => {
    it('should revert if fulfillment is attempted on an incorrect destination chain', async () => {
      // Create an intent hash for a different destination chain
      const wrongDestination = 123
      const wrongIntent: UniversalIntent = {
        destination: wrongDestination,
        route: universalRoute,
        reward: universalReward,
      }
      const { intentHash: wrongIntentHash } = hashUniversalIntent(wrongIntent)

      await expect(
        inbox
          .connect(owner)
          .fulfill(
            wrongIntentHash,
            universalRouteToRoute(universalRoute),
            rewardHash,
            TypeCasts.addressToBytes32(dstAddr.address),
          ),
      ).to.be.revertedWithCustomError(inbox, 'InvalidHash')
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
            goofyHash,
            universalRouteToRoute(universalRoute),
            rewardHash,
            TypeCasts.addressToBytes32(dstAddr.address),
          ),
      ).to.be.revertedWithCustomError(inbox, 'InvalidHash')
    })
    it('should revert via InvalidHash if all intent data was input correctly, but the intent used a different inbox on creation', async () => {
      const anotherPortal = await (
        await ethers.getContractFactory('Portal')
      ).deploy()
      const anotherInbox = await ethers.getContractAt(
        'Inbox',
        await anotherPortal.getAddress(),
      )

      const _route: UniversalRoute = {
        ...universalRoute,
        portal: TypeCasts.addressToBytes32(await anotherInbox.getAddress()),
      }

      const _intentHash = hashUniversalIntent({
        destination: Number((await owner.provider.getNetwork()).chainId),
        route: _route,
        reward: universalReward,
      }).intentHash

      await expect(
        inbox
          .connect(solver)
          .fulfill(
            _intentHash,
            universalRouteToRoute(_route),
            rewardHash,
            TypeCasts.addressToBytes32(dstAddr.address),
          ),
      ).to.be.revertedWithCustomError(inbox, 'InvalidPortal')
    })
  })

  describe('fulfill when the intent is valid', () => {
    it('should revert if claimant is zero address', async () => {
      await expect(
        inbox
          .connect(solver)
          .fulfill(
            intentHash,
            universalRouteToRoute(universalRoute),
            rewardHash,
            ethers.ZeroHash,
          ),
      ).to.be.revertedWithCustomError(inbox, 'ZeroClaimant')
    })
    it('should revert if the solver has not approved tokens for transfer', async () => {
      await expect(
        inbox
          .connect(solver)
          .fulfill(
            intentHash,
            universalRouteToRoute(universalRoute),
            rewardHash,
            TypeCasts.addressToBytes32(dstAddr.address),
          ),
      ).to.be.revertedWithCustomError(erc20, 'ERC20InsufficientAllowance')
    })
    it('should revert if the call fails', async () => {
      await erc20.connect(solver).approve(await inbox.getAddress(), mintAmount)

      const _route: UniversalRoute = {
        ...universalRoute,
        calls: [
          {
            target: TypeCasts.addressToBytes32(await erc20.getAddress()),
            data: await encodeTransfer(dstAddr.address, mintAmount * 100),
            value: 0,
          },
        ],
      }

      const _intentHash = hashUniversalIntent({
        destination: Number((await owner.provider.getNetwork()).chainId),
        route: _route,
        reward: universalReward,
      }).intentHash
      await expect(
        inbox
          .connect(solver)
          .fulfill(
            _intentHash,
            universalRouteToRoute(_route),
            rewardHash,
            TypeCasts.addressToBytes32(dstAddr.address),
          ),
      ).to.be.revertedWithCustomError(inbox, 'IntentCallFailed')
    })
    it('should revert if any of the targets is a prover', async () => {
      const _route: UniversalRoute = {
        ...universalRoute,
        calls: [
          {
            target: TypeCasts.addressToBytes32(await mockProver.getAddress()),
            data: '0x',
            value: 0,
          },
        ],
      }
      const _intentHash = hashUniversalIntent({
        destination: Number((await owner.provider.getNetwork()).chainId),
        route: _route,
        reward: universalReward,
      }).intentHash
      await erc20.connect(solver).approve(await inbox.getAddress(), mintAmount)
      await expect(
        inbox
          .connect(solver)
          .fulfill(
            _intentHash,
            universalRouteToRoute(_route),
            rewardHash,
            TypeCasts.addressToBytes32(dstAddr.address),
          ),
      ).to.be.revertedWithCustomError(inbox, 'CallToProver')
    })
    it('should revert if one of the targets is an EOA', async () => {
      await erc20.connect(solver).approve(await inbox.getAddress(), mintAmount)

      const _route: UniversalRoute = {
        ...universalRoute,
        calls: [
          {
            target: TypeCasts.addressToBytes32(solver.address),
            data: await encodeTransfer(dstAddr.address, mintAmount * 100),
            value: 0,
          },
        ],
      }
      const _intentHash = hashUniversalIntent({
        destination: Number((await owner.provider.getNetwork()).chainId),
        route: _route,
        reward: universalReward,
      }).intentHash
      await expect(
        inbox
          .connect(solver)
          .fulfill(
            _intentHash,
            universalRouteToRoute(_route),
            rewardHash,
            TypeCasts.addressToBytes32(dstAddr.address),
          ),
      )
        .to.be.revertedWithCustomError(inbox, 'CallToEOA')
        .withArgs(solver.address)
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
            intentHash,
            universalRouteToRoute(universalRoute),
            rewardHash,
            TypeCasts.addressToBytes32(dstAddr.address),
          ),
      )
        .to.emit(inbox, 'IntentFulfilled')
        .withArgs(intentHash, ethers.zeroPadValue(dstAddr.address, 32))
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
            intentHash,
            universalRouteToRoute(universalRoute),
            rewardHash,
            TypeCasts.addressToBytes32(dstAddr.address),
          ),
      ).to.not.be.reverted
      // should revert
      await expect(
        inbox
          .connect(solver)
          .fulfill(
            intentHash,
            universalRouteToRoute(universalRoute),
            rewardHash,
            TypeCasts.addressToBytes32(dstAddr.address),
          ),
      ).to.be.revertedWithCustomError(inbox, 'IntentAlreadyFulfilled')
    })
  })

  describe('prove', async () => {
    it('gets the right args', async () => {
      await erc20.connect(solver).approve(await inbox.getAddress(), mintAmount)

      const theArgs = {
        sender: solver.address,
        sourceChainId: BigInt(sourceChainID),
        data: '0x',
        value: 123456789n,
      }
      await expect(
        inbox
          .connect(solver)
          .fulfill(
            intentHash,
            universalRouteToRoute(universalRoute),
            rewardHash,
            TypeCasts.addressToBytes32(dstAddr.address),
          ),
      ).to.not.be.reverted

      const argsBefore = await mockProver.args()
      expect(argsBefore.sender).to.not.equal(theArgs.sender)

      await inbox
        .connect(solver)
        .prove(
          sourceChainID,
          await mockProver.getAddress(),
          [intentHash],
          '0x',
          { value: 123456789 },
        )
      const argsAfter = await mockProver.args()
      expect(argsAfter.sender).to.equal(theArgs.sender)
      expect(argsAfter.sourceChainId).to.equal(theArgs.sourceChainId)
      expect(argsAfter.data).to.equal(theArgs.data)
      expect(argsAfter.value).to.equal(theArgs.value)

      // Check the arrays separately
      const intentHashes = await mockProver.argIntentHashes(0)
      expect(intentHashes).to.equal(intentHash)
      const claimants = await mockProver.argClaimants(0)
      expect(claimants).to.equal(TypeCasts.addressToBytes32(dstAddr.address))
    })
  })

  describe('fulfillAndProve', async () => {
    it('works', async () => {
      await erc20.connect(solver).approve(await inbox.getAddress(), mintAmount)

      const theArgs = {
        sender: solver.address,
        sourceChainId: BigInt(sourceChainID),
        data: '0x',
        value: 0n,
      }

      const argsBefore = await mockProver.args()
      expect(argsBefore.sender).to.not.equal(theArgs.sender)

      await expect(
        inbox
          .connect(solver)
          .fulfillAndProve(
            intentHash,
            universalRouteToRoute(universalRoute),
            rewardHash,
            TypeCasts.addressToBytes32(dstAddr.address),
            await mockProver.getAddress(),
            sourceChainID,
            '0x',
          ),
      ).to.not.be.reverted

      const argsAfter = await mockProver.args()
      expect(argsAfter.sender).to.equal(theArgs.sender)
      expect(argsAfter.sourceChainId).to.equal(theArgs.sourceChainId)
      expect(argsAfter.data).to.equal(theArgs.data)
      expect(argsAfter.value).to.equal(theArgs.value)

      // Check the arrays separately
      const intentHashes = await mockProver.argIntentHashes(0)
      expect(intentHashes).to.equal(intentHash)
      const claimants = await mockProver.argClaimants(0)
      expect(claimants).to.equal(TypeCasts.addressToBytes32(dstAddr.address))
    })

    it('should handle fulfillAndProve with address claimant', async () => {
      // Use a valid EVM address for the claimant
      const validClaimant = await dstAddr.getAddress()

      await erc20.connect(solver).approve(await inbox.getAddress(), mintAmount)
      await expect(
        inbox
          .connect(solver)
          .fulfillAndProve(
            intentHash,
            universalRouteToRoute(universalRoute),
            rewardHash,
            TypeCasts.addressToBytes32(validClaimant),
            await mockProver.getAddress(),
            sourceChainID,
            '0x',
          ),
      )
        .to.emit(inbox, 'IntentFulfilled')
        .withArgs(intentHash, ethers.zeroPadValue(validClaimant, 32))

      // Verify the claimant was stored correctly
      const storedClaimant = await inbox.fulfilled(intentHash)
      expect(storedClaimant).to.equal(ethers.zeroPadValue(validClaimant, 32))
    })
  })
})
