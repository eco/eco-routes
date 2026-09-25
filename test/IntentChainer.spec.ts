import { expect } from 'chai'
import { ethers, network } from 'hardhat'
import { time } from '@nomicfoundation/hardhat-toolbox/network-helpers'
import { encodeRoute, hashIntent } from '../utils/intent'

describe('IntentChainer transaction rollback', () => {
  for (const publish of [true, false]) {
    it(`rolls back the full Portal fulfillment and receipt logs (publish=${publish})`, async () => {
      const [creator, solver] = await ethers.getSigners()
      const portal = await (
        await ethers.getContractFactory('Portal')
      ).deploy(ethers.ZeroAddress)
      const chainer = await (
        await ethers.getContractFactory('IntentChainer')
      ).deploy()
      const token = await (
        await ethers.getContractFactory('FeeOnPushToken')
      ).deploy(await chainer.getAddress())
      const portalAddress = await portal.getAddress()
      const chainerAddress = await chainer.getAddress()
      const tokenAddress = await token.getAddress()
      const amount = 1000n
      const prefunding = 2n * amount
      const deadline = (await time.latest()) + 3600
      const destination = Number((await ethers.provider.getNetwork()).chainId)
      const childRoute = {
        salt: ethers.id('unique child'),
        deadline,
        portal: portalAddress,
        nativeAmount: 0,
        tokens: [],
        calls: [],
      }
      const childReward = {
        deadline,
        creator: creator.address,
        prover: creator.address,
        nativeAmount: 0n,
        tokens: [{ token: tokenAddress, amount }],
      }
      const childBytes = encodeRoute(childRoute)
      const order = {
        publish,
        portal: portalAddress,
        token: tokenAddress,
        destination,
        template: {
          vaults: [],
          route: { segments: [childBytes], items: [] },
        },
        reward: {
          ...childReward,
          tokens: [{ token: tokenAddress, amount: 0 }],
        },
        scale: ethers.parseEther('1'),
        minAmountIn: amount,
      }
      const vault = await portal.intentVaultAddress(
        destination,
        childBytes,
        childReward,
      )
      const { intentHash: childHash } = hashIntent({
        destination,
        route: childRoute,
        reward: childReward,
      })
      // Preserve an actual pre-transaction chainer balance; also exercise rollback of the
      // parent's token pull and route transfer before the outbound fee is encountered.
      await token.mint(chainerAddress, amount)
      await token.mint(vault, prefunding)
      await token.mint(solver.address, amount)
      await token.connect(solver).approve(portalAddress, amount)
      const parentRoute = {
        ...childRoute,
        salt: ethers.id('unique parent'),
        tokens: [{ token: tokenAddress, amount }],
        calls: [
          {
            target: tokenAddress,
            data: token.interface.encodeFunctionData('transfer', [
              creator.address,
              amount,
            ]),
            value: 0,
          },
          {
            target: chainerAddress,
            data: chainer.interface.encodeFunctionData('chain', [order]),
            value: 0,
          },
        ],
      }
      const { intentHash, rewardHash } = hashIntent({
        destination,
        route: parentRoute,
        reward: childReward,
      })
      const claimant = ethers.zeroPadValue(solver.address, 32)
      const executor = await ethers.getContractAt(
        'Executor',
        await portal.executor(),
      )
      const shortfall = chainer.interface.encodeErrorResult('PushShortfall', [
        vault,
        amount,
        amount - 1n,
      ])
      const chainCall = parentRoute.calls[1]
      await expect(
        portal
          .connect(solver)
          .fulfill.staticCall(intentHash, parentRoute, rewardHash, claimant),
      )
        .to.be.revertedWithCustomError(executor, 'CallFailed')
        .withArgs(
          [chainCall.target, chainCall.data, chainCall.value],
          shortfall,
        )

      const supplyBefore = await token.totalSupply()
      const blockBefore = await ethers.provider.getBlockNumber()
      // Submit a genuinely mined failing transaction, not merely eth_call. Disabling
      // automining lets us obtain its hash even though execution will revert.
      await network.provider.send('evm_setAutomine', [false])
      let transactionHash: string
      try {
        const tx = await portal
          .connect(solver)
          .fulfill(intentHash, parentRoute, rewardHash, claimant, {
            gasLimit: 3_000_000,
          })
        transactionHash = tx.hash
        await network.provider.send('evm_mine')
      } finally {
        await network.provider.send('evm_setAutomine', [true])
      }
      const receipt =
        await ethers.provider.getTransactionReceipt(transactionHash)
      expect(receipt).not.to.equal(null)
      expect(receipt!.status).to.equal(0)
      expect(receipt!.logs).to.deep.equal([])
      expect(await token.balanceOf(chainerAddress)).to.equal(amount)
      expect(await token.balanceOf(vault)).to.equal(prefunding)
      expect(await token.balanceOf(solver.address)).to.equal(amount)
      expect(await token.balanceOf(creator.address)).to.equal(0)
      expect(await token.balanceOf(await portal.executor())).to.equal(0)
      expect(await token.totalSupply()).to.equal(supplyBefore)
      expect(await portal.claimants(intentHash)).to.equal(ethers.ZeroHash)
      expect(await portal.getRewardStatus(childHash)).to.equal(0)
      expect(
        await portal.queryFilter(
          portal.filters.IntentPublished(),
          blockBefore + 1,
          receipt!.blockNumber,
        ),
      ).to.deep.equal([])
      expect(
        await chainer.queryFilter(
          chainer.filters.IntentChained(),
          blockBefore + 1,
          receipt!.blockNumber,
        ),
      ).to.deep.equal([])
    })
  }
})
