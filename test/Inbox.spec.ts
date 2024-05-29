import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import { ERC20Test, Inbox } from '../typechain-types'
import {
  time,
  loadFixture,
} from '@nomicfoundation/hardhat-toolbox/network-helpers'
import { DataHexString } from 'ethers/lib.commonjs/utils/data'
import { encodeTransfer } from '../utils/encode'

describe('Inbox Test', (): void => {
  let inbox: Inbox
  let erc20: ERC20Test
  let owner: SignerWithAddress
  let solver: SignerWithAddress
  let dstAddr: SignerWithAddress
  let hash32: string
  let calldata: DataHexString
  let timeStamp: number
  const nonce = ethers.encodeBytes32String('0x987')
  let erc20Address: string
  const timeDelta = 1000
  const mintAmount = 1000

  async function deployInboxFixture(): Promise<{
    inbox: Inbox
    erc20: ERC20Test
    owner: SignerWithAddress
    solver: SignerWithAddress
    dstAddr: SignerWithAddress
  }> {
    const [owner, solver, dstAddr] = await ethers.getSigners()
    const inboxFactory = await ethers.getContractFactory('Inbox')
    const inbox = await inboxFactory.deploy()

    // deploy ERC20 test
    const erc20Factory = await ethers.getContractFactory('ERC20Test')
    const erc20 = await erc20Factory.deploy('eco', 'eco', mintAmount)

    return {
      inbox,
      erc20,
      owner,
      solver,
      dstAddr,
    }
  }

  async function setBalances() {
    await erc20.connect(owner).transfer(await solver.getAddress(), mintAmount)
  }

  beforeEach(async (): Promise<void> => {
    ;({ inbox, erc20, owner, solver, dstAddr } =
      await loadFixture(deployInboxFixture))

    // fund the solver
    await setBalances()
    erc20Address = await erc20.getAddress()
    calldata = await encodeTransfer(dstAddr.address, mintAmount)
    timeStamp = (await time.latest()) + timeDelta
    const abiCoder = ethers.AbiCoder.defaultAbiCoder()
    const encodedData = abiCoder.encode(
      ['bytes32', 'address[]', 'bytes[]', 'uint256'],
      [nonce, [erc20Address], [calldata], timeStamp],
    )
    hash32 = ethers.keccak256(encodedData)
  })

  describe('when the intent is invalid', () => {
    it('should revert if the timestamp is expired', async () => {
      timeStamp -= 2 * timeDelta
      await expect(
        inbox.fulfill(
          nonce,
          [erc20Address],
          [calldata],
          timeStamp,
          dstAddr.address,
        ),
      ).to.be.revertedWithCustomError(inbox, 'IntentExpired')
    })

    it('should revert if the data is invalid', async () => {
      // empty addresses
      await expect(
        inbox.fulfill(
          nonce,
          [],
          [calldata, calldata],
          timeStamp,
          dstAddr.address,
        ),
      ).to.be.revertedWithPanic('0x32') // Array accessed at an out-of-bounds or negative index
    })
  })

  describe('when the intent is valid', () => {
    it('should revert if the call fails', async () => {
      await expect(
        inbox.fulfill(
          nonce,
          [erc20Address],
          [calldata],
          timeStamp,
          dstAddr.address,
        ),
      ).to.be.revertedWithCustomError(inbox, 'IntentCallFailed')
    })

    it('should succeed', async () => {
      expect(await inbox.fulfilled(nonce)).to.be.deep.equal([
        ethers.ZeroHash,
        ethers.ZeroAddress,
      ])
      expect(await erc20.balanceOf(solver.address)).to.equal(mintAmount)
      expect(await erc20.balanceOf(dstAddr.address)).to.equal(0)

      // transfer the tokens to the inbox so it can process the transaction
      await erc20.connect(solver).transfer(await inbox.getAddress(), mintAmount)

      // should emit an event
      await expect(
        inbox
          .connect(solver)
          .fulfill(
            nonce,
            [erc20Address],
            [calldata],
            timeStamp,
            dstAddr.address,
          ),
      )
        .to.emit(inbox, 'Fulfillment')
        .withArgs(nonce)
      // should update the fulfilled hash
      expect(await inbox.fulfilled(nonce)).to.be.deep.equal([
        hash32,
        dstAddr.address,
      ])

      // check balances
      expect(await erc20.balanceOf(solver.address)).to.equal(0)
      expect(await erc20.balanceOf(dstAddr.address)).to.equal(mintAmount)
    })

    it('should revert if the intent has already been fulfilled', async () => {
      // transfer the tokens to the inbox so it can process the transaction
      await erc20.connect(solver).transfer(await inbox.getAddress(), mintAmount)

      // should emit an event
      await expect(
        inbox
          .connect(solver)
          .fulfill(
            nonce,
            [erc20Address],
            [calldata],
            timeStamp,
            dstAddr.address,
          ),
      )
        .to.emit(inbox, 'Fulfillment')
        .withArgs(nonce)
      // should revert
      await expect(
        inbox
          .connect(solver)
          .fulfill(
            nonce,
            [erc20Address],
            [calldata],
            timeStamp,
            dstAddr.address,
          ),
      ).to.be.revertedWithCustomError(inbox, 'IntentAlreadyFulfilled')
    })
  })
})
