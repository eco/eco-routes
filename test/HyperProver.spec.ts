import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'
import {
  time,
  loadFixture,
} from '@nomicfoundation/hardhat-toolbox/network-helpers'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import { HyperProver, Inbox, TestERC20, TestMailbox } from '../typechain-types'
import { encodeTransfer } from '../utils/encode'
import { hashIntent, TokenAmount, MinimalRoute, Intent } from '../utils/intent'
import {
  MessageBridgeMessage,
  encodeMessageBridgeMessage,
} from '../utils/MessageBridge'

describe.only('HyperProver Test', (): void => {
  let inbox: Inbox
  let mailbox: TestMailbox
  let hyperProver: HyperProver
  let token: TestERC20
  let owner: SignerWithAddress
  let solver: SignerWithAddress
  let claimant: SignerWithAddress
  let intent: Intent
  let intentHash: string
  let rewardHash: string
  let destinationChainID: number
  let messageBridgeMessage: MessageBridgeMessage
  const amount: number = 1234567890
  const abiCoder = ethers.AbiCoder.defaultAbiCoder()

  async function deployHyperproverFixture(): Promise<{
    inbox: Inbox
    mailbox: TestMailbox
    token: TestERC20
    owner: SignerWithAddress
    solver: SignerWithAddress
    claimant: SignerWithAddress
  }> {
    const [owner, solver, claimant] = await ethers.getSigners()
    const mailbox = await (
      await ethers.getContractFactory('TestMailbox')
    ).deploy(await owner.getAddress())

    const inbox = await (await ethers.getContractFactory('Inbox')).deploy()

    const token = await (
      await ethers.getContractFactory('TestERC20')
    ).deploy('token', 'tkn')

    return {
      inbox,
      mailbox,
      token,
      owner,
      solver,
      claimant,
    }
  }

  beforeEach(async (): Promise<void> => {
    ;({ inbox, mailbox, token, owner, solver, claimant } = await loadFixture(
      deployHyperproverFixture,
    ))
  })

  describe('1. Constructor', () => {
    it('should initialize with the correct mailbox and inbox addresses', async () => {
      hyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await mailbox.getAddress(), await inbox.getAddress(), [])

      expect(await hyperProver.MAILBOX()).to.equal(await mailbox.getAddress())
      expect(await hyperProver.INBOX()).to.equal(await inbox.getAddress())
    })

    it('should add constructor-provided provers to the whitelist', async () => {
      const additionalProver = await owner.getAddress()
      hyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await mailbox.getAddress(), await inbox.getAddress(), [
        additionalProver,
        await hyperProver.getAddress(),
      ])

      // Check if the prover address is in the whitelist
      expect(await hyperProver.isWhitelisted(additionalProver)).to.be.true
      // Check if the hyperProver itself is also whitelisted
      expect(await hyperProver.isWhitelisted(await hyperProver.getAddress())).to
        .be.true
    })

    it('should return the correct proof type', async () => {
      // use owner as mailbox so we can test handle
      hyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await mailbox.getAddress(), await inbox.getAddress(), [])
      expect(await hyperProver.getProofType()).to.equal('Hyperlane')
    })
  })

  describe('2. Handle', () => {
    beforeEach(async () => {
      hyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(owner.address, await inbox.getAddress(), [
        await inbox.getAddress(),
      ])

      // Set up common data
      const network = await ethers.provider.getNetwork()
      const sourceChainID = Number(network.chainId)
      destinationChainID = 12345
      const calldata = await encodeTransfer(await claimant.getAddress(), amount)
      const timeStamp = (await time.latest()) + 1000
      const metadata = '0x1234'
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes32', 'bytes', 'address'],
        [
          ethers.zeroPadValue(await hyperProver.getAddress(), 32),
          metadata,
          ethers.ZeroAddress,
        ],
      )

      // Create first intent
      let salt = ethers.encodeBytes32String('0x987')
      const routeTokens: TokenAmount[] = [
        { token: await token.getAddress(), amount: amount },
      ]
      const route = {
        salt: salt,
        source: sourceChainID,
        destination: destinationChainID,
        inbox: await inbox.getAddress(),
        tokens: routeTokens,
        calls: [
          {
            target: await token.getAddress(),
            data: calldata,
            value: 0,
          },
        ],
      }
      const reward = {
        creator: await owner.getAddress(),
        prover: await hyperProver.getAddress(),
        deadline: timeStamp + 1000,
        nativeValue: 1n,
        tokens: [] as TokenAmount[],
      }

      const { intentHash: IH, rewardHash: RH } = hashIntent({
        route,
        reward,
      })
      intentHash = IH
      rewardHash = RH

      const minimalRoute: MinimalRoute = {
        salt,
        tokens: route.tokens,
        calls: route.calls,
      }

      // Generate claimant address
      const claimantAddress = await claimant.getAddress()

      messageBridgeMessage = {
        inbox: await inbox.getAddress(),
        minimalRoutes: [minimalRoute],
        rewardHashes: [rewardHash],
        claimants: [claimantAddress],
      }

      const msgBody = encodeMessageBridgeMessage(messageBridgeMessage)
    })

    it('should revert when msg.sender is not the mailbox', async () => {
      await expect(
        hyperProver
          .connect(claimant)
          .handle(12345, ethers.sha256('0x'), ethers.sha256('0x')),
      ).to.be.revertedWithCustomError(hyperProver, 'UnauthorizedHandle')
    })

    it('should revert when sender field is not authorized', async () => {
      await expect(
        hyperProver
          .connect(owner)
          .handle(
            12345,
            ethers.zeroPadValue(owner.address, 32),
            ethers.sha256('0x'),
          ),
      ).to.be.revertedWithCustomError(hyperProver, 'UnauthorizedIncomingProof')
    })

    it('should record a single proven intent when called correctly', async () => {
      //   // Create a minimal route

      //   // Set up common data
      //   const network = await ethers.provider.getNetwork()
      //   const sourceChainID = Number(network.chainId)
      //   const destinationChainID = 12345
      //   const calldata = await encodeTransfer(await claimant.getAddress(), amount)
      //   const timeStamp = (await time.latest()) + 1000
      //   const metadata = '0x1234'
      //   const data = ethers.AbiCoder.defaultAbiCoder().encode(
      //     ['bytes32', 'bytes', 'address'],
      //     [
      //       ethers.zeroPadValue(await hyperProver.getAddress(), 32),
      //       metadata,
      //       ethers.ZeroAddress,
      //     ],
      //   )

      //   // Create first intent
      //   let salt = ethers.encodeBytes32String('0x987')
      //   const routeTokens: TokenAmount[] = [
      //     { token: await token.getAddress(), amount: amount },
      //   ]
      //   const route = {
      //     salt: salt,
      //     source: sourceChainID,
      //     destination: destinationChainID,
      //     inbox: await inbox.getAddress(),
      //     tokens: routeTokens,
      //     calls: [
      //       {
      //         target: await token.getAddress(),
      //         data: calldata,
      //         value: 0,
      //       },
      //     ],
      //   }
      //   const reward = {
      //     creator: await owner.getAddress(),
      //     prover: await hyperProver.getAddress(),
      //     deadline: timeStamp + 1000,
      //     nativeValue: 1n,
      //     tokens: [] as TokenAmount[],
      //   }

      //   const { intentHash: intentHash0, rewardHash: rewardHash0 } = hashIntent({
      //     route,
      //     reward,
      //   })

      //   const minimalRoute: MinimalRoute = {
      //     salt,
      //     tokens: route.tokens,
      //     calls: route.calls,
      //   }

      //   // Generate claimant address
      //   const claimantAddress = await claimant.getAddress()

      //   const messageBridgeMessage: MessageBridgeMessage = {
      //     inbox: await inbox.getAddress(),
      //     minimalRoutes: [minimalRoute],
      //     rewardHashes: [rewardHash0],
      //     claimants: [claimantAddress],
      //   }

      const msgBody = encodeMessageBridgeMessage(messageBridgeMessage)

      // Verify the intent hasn't been proven yet
      expect(await hyperProver.provenIntents(intentHash)).to.eq(
        ethers.ZeroAddress,
      )

      // Call handle with the new message format
      await expect(
        hyperProver
          .connect(owner)
          .handle(
            destinationChainID,
            ethers.zeroPadValue(await inbox.getAddress(), 32),
            msgBody,
          ),
      )
        .to.emit(hyperProver, 'IntentProven')
        .withArgs(intentHash, claimant.address)

      // Verify the intent is now proven
      expect(await hyperProver.provenIntents(intentHash)).to.eq(
        claimant.address,
      )
    })

    it('should emit an event when intent is already proven', async () => {
      // Create a minimal route
      const salt = ethers.encodeBytes32String('test-salt')
      const destinationChainId = 12345
      const minimalRoute = {
        salt,
        tokens: [{ token: ethers.ZeroAddress, amount: 0 }],
        calls: [{ target: ethers.ZeroAddress, data: '0x', value: 0 }],
      }

      // Create a reward hash
      const rewardHash = ethers.keccak256('0x1234')

      // Generate claimant address
      const claimantAddress = await claimant.getAddress()

      // Calculate expected intent hash
      const network = await ethers.provider.getNetwork()
      const route = {
        salt: minimalRoute.salt,
        source: Number(network.chainId),
        destination: destinationChainId,
        inbox: await inbox.getAddress(),
        tokens: minimalRoute.tokens,
        calls: minimalRoute.calls,
      }
      const intentHash = ethers.keccak256(
        ethers.solidityPacked(
          ['bytes32', 'bytes32'],
          [
            ethers.keccak256(
              ethers.AbiCoder.defaultAbiCoder().encode(
                [
                  'tuple(bytes32,uint256,uint256,address,tuple(address,uint256)[],tuple(address,bytes,uint256)[])',
                ],
                [route],
              ),
            ),
            rewardHash,
          ],
        ),
      )

      // Create the message body in new format
      const msgBody = abiCoder.encode(
        [
          'address',
          'tuple(bytes32,tuple(address,uint256)[],tuple(address,bytes,uint256)[])[]',
          'bytes32[]',
          'address[]',
        ],
        [
          await inbox.getAddress(),
          [minimalRoute],
          [rewardHash],
          [claimantAddress],
        ],
      )

      // First handle call proves the intent
      await hyperProver
        .connect(owner)
        .handle(
          destinationChainId,
          ethers.zeroPadValue(await inbox.getAddress(), 32),
          msgBody,
        )

      // Second handle call should emit IntentAlreadyProven
      await expect(
        hyperProver
          .connect(owner)
          .handle(
            destinationChainId,
            ethers.zeroPadValue(await inbox.getAddress(), 32),
            msgBody,
          ),
      )
        .to.emit(hyperProver, 'IntentAlreadyProven')
        .withArgs(intentHash)


      const msgBody = encodeMessageBridgeMessage(messageBridgeMessage)

      // Verify the intent hasn't been proven yet
      expect(await hyperProver.provenIntents(intentHash)).to.eq(
        ethers.ZeroAddress,
      )

      // Call handle with the new message format
      await expect(
        hyperProver
          .connect(owner)
          .handle(
            destinationChainID,
            ethers.zeroPadValue(await inbox.getAddress(), 32),
            msgBody,
          ),
      )
        .to.emit(hyperProver, 'IntentProven')
        .withArgs(intentHash, claimant.address)

      // Verify the intent is now proven
      expect(await hyperProver.provenIntents(intentHash)).to.eq(
        claimant.address,
      )
    })

    it('should handle batch proving of multiple intents', async () => {
      // Create two minimal routes with different salts
      const destinationChainId = 12345
      const salt1 = ethers.encodeBytes32String('test-salt-1')
      const salt2 = ethers.encodeBytes32String('test-salt-2')

      const minimalRoute1 = {
        salt: salt1,
        tokens: [{ token: ethers.ZeroAddress, amount: 0 }],
        calls: [{ target: ethers.ZeroAddress, data: '0x', value: 0 }],
      }

      const minimalRoute2 = {
        salt: salt2,
        tokens: [{ token: ethers.ZeroAddress, amount: 100 }],
        calls: [{ target: ethers.ZeroAddress, data: '0x', value: 0 }],
      }

      // Create reward hashes
      const rewardHash1 = ethers.keccak256('0x1234')
      const rewardHash2 = ethers.keccak256('0x5678')

      // Get claimant addresses
      const claimantAddress = await claimant.getAddress()
      const otherAddress = await solver.getAddress()

      // Calculate expected intent hashes
      const network = await ethers.provider.getNetwork()

      const route1 = {
        salt: minimalRoute1.salt,
        source: Number(network.chainId),
        destination: destinationChainId,
        inbox: await inbox.getAddress(),
        tokens: minimalRoute1.tokens,
        calls: minimalRoute1.calls,
      }

      const route2 = {
        salt: minimalRoute2.salt,
        source: Number(network.chainId),
        destination: destinationChainId,
        inbox: await inbox.getAddress(),
        tokens: minimalRoute2.tokens,
        calls: minimalRoute2.calls,
      }

      const intentHash1 = ethers.keccak256(
        ethers.solidityPacked(
          ['bytes32', 'bytes32'],
          [
            ethers.keccak256(
              ethers.AbiCoder.defaultAbiCoder().encode(
                [
                  'tuple(bytes32,uint256,uint256,address,tuple(address,uint256)[],tuple(address,bytes,uint256)[])',
                ],
                [route1],
              ),
            ),
            rewardHash1,
          ],
        ),
      )

      const intentHash2 = ethers.keccak256(
        ethers.solidityPacked(
          ['bytes32', 'bytes32'],
          [
            ethers.keccak256(
              ethers.AbiCoder.defaultAbiCoder().encode(
                [
                  'tuple(bytes32,uint256,uint256,address,tuple(address,uint256)[],tuple(address,bytes,uint256)[])',
                ],
                [route2],
              ),
            ),
            rewardHash2,
          ],
        ),
      )

      // Create the message body with both intents
      const msgBody = abiCoder.encode(
        [
          'address',
          'tuple(bytes32,tuple(address,uint256)[],tuple(address,bytes,uint256)[])[]',
          'bytes32[]',
          'address[]',
        ],
        [
          await inbox.getAddress(),
          [minimalRoute1, minimalRoute2],
          [rewardHash1, rewardHash2],
          [claimantAddress, otherAddress],
        ],
      )

      // Handle the batch proving
      await expect(
        hyperProver
          .connect(owner)
          .handle(
            destinationChainId,
            ethers.zeroPadValue(await inbox.getAddress(), 32),
            msgBody,
          ),
      )
        .to.emit(hyperProver, 'IntentProven')
        .withArgs(intentHash1, claimantAddress)
        .to.emit(hyperProver, 'IntentProven')
        .withArgs(intentHash2, otherAddress)

      // Verify both intents are proven
      expect(await hyperProver.provenIntents(intentHash1)).to.eq(
        claimantAddress,
      )
      expect(await hyperProver.provenIntents(intentHash2)).to.eq(otherAddress)
    })
  })

  describe('3. initiateProving', () => {
    beforeEach(async () => {
      // use owner as inbox so we can test initiateProving
      const chainId = 12345 // Use test chainId
      hyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await mailbox.getAddress(), owner.address, [
        await inbox.getAddress(),
        await hyperProver.getAddress(),
      ])
    })

    it('should revert on underpayment', async () => {
      // Set up test data
      const sourceChainId = 123
      const salt = ethers.encodeBytes32String('0x987')
      const minimalRoutes = [
        {
          salt,
          tokens: [{ token: ethers.ZeroAddress, amount: 0 }],
          calls: [{ target: ethers.ZeroAddress, data: '0x', value: 0 }],
        },
      ]
      const rewardHashes = [ethers.keccak256('0x1234')]
      const claimants = [await claimant.getAddress()]
      const sourceChainProver = await hyperProver.getAddress()
      const metadata = '0x1234'
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        // ['sourceChainProver', 'metadata', 'hookAddress'],
        ['bytes32', 'bytes', 'address'],
        [
          ethers.zeroPadValue(sourceChainProver, 32),
          metadata,
          ethers.ZeroAddress,
        ],
      )

      // Before initiateProving, make sure the mailbox hasn't been called
      expect(await mailbox.dispatchedWithRelayer()).to.be.false

      const fee = await hyperProver.fetchFee(
        sourceChainId,
        minimalRoutes,
        rewardHashes,
        claimants,
        data,
      )
      const initBalance = await solver.provider.getBalance(solver.address)
      await expect(
        hyperProver.connect(owner).prove(
          solver.address,
          sourceChainId,
          minimalRoutes,
          rewardHashes,
          claimants,
          data,
          { value: fee - BigInt(1) }, // high number beacuse
        ),
      ).to.be.revertedWithCustomError(hyperProver, 'InsufficientFee')
    })

    it('should reject initiateProving from unauthorized source', async () => {
      const salt = ethers.encodeBytes32String('0x987')
      const minimalRoutes = [
        {
          salt,
          tokens: [{ token: ethers.ZeroAddress, amount: 0 }],
          calls: [{ target: ethers.ZeroAddress, data: '0x', value: 0 }],
        },
      ]
      const rewardHashes = [ethers.keccak256('0x1234')]
      const claimants = [await claimant.getAddress()]
      const sourceChainProver = await solver.getAddress()
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes32', 'bytes', 'address'],
        [ethers.zeroPadValue(sourceChainProver, 32), '0x', ethers.ZeroAddress],
      )

      await expect(
        hyperProver
          .connect(solver)
          .prove(
            owner.address,
            123,
            minimalRoutes,
            rewardHashes,
            claimants,
            data,
          ),
      ).to.be.revertedWithCustomError(hyperProver, 'UnauthorizedProve')
    })

    it('should handle exact fee payment with no refund needed', async () => {
      // Set up test data
      const sourceChainId = 123
      const salt = ethers.encodeBytes32String('0x987')
      const minimalRoutes = [
        {
          salt,
          tokens: [{ token: ethers.ZeroAddress, amount: 0 }],
          calls: [{ target: ethers.ZeroAddress, data: '0x', value: 0 }],
        },
      ]
      const rewardHashes = [ethers.keccak256('0x1234')]
      const claimants = [await claimant.getAddress()]
      const sourceChainProver = await hyperProver.getAddress()
      const metadata = '0x1234'
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes32', 'bytes', 'address'],
        [
          ethers.zeroPadValue(sourceChainProver, 32),
          metadata,
          ethers.ZeroAddress,
        ],
      )

      const fee = await hyperProver.fetchFee(
        sourceChainId,
        minimalRoutes,
        rewardHashes,
        claimants,
        data,
      )

      // Track balances before and after
      const solverBalanceBefore = await solver.provider.getBalance(
        solver.address,
      )

      // Call with exact fee (no refund needed)
      await hyperProver.connect(owner).prove(
        solver.address,
        sourceChainId,
        minimalRoutes,
        rewardHashes,
        claimants,
        data,
        { value: fee }, // Exact fee amount
      )

      // Should dispatch successfully without refund
      expect(await mailbox.dispatchedWithRelayer()).to.be.true

      // Balance should be unchanged since no refund was needed
      const solverBalanceAfter = await solver.provider.getBalance(
        solver.address,
      )
      expect(solverBalanceBefore).to.equal(solverBalanceAfter)
    })

    it('should handle custom hook address correctly', async () => {
      // Set up test data
      const sourceChainId = 123
      const salt = ethers.encodeBytes32String('0x987')
      const minimalRoutes = [
        {
          salt,
          tokens: [{ token: ethers.ZeroAddress, amount: 0 }],
          calls: [{ target: ethers.ZeroAddress, data: '0x', value: 0 }],
        },
      ]
      const rewardHashes = [ethers.keccak256('0x1234')]
      const claimants = [await claimant.getAddress()]
      const sourceChainProver = await hyperProver.getAddress()
      const metadata = '0x1234'
      const customHookAddress = await solver.getAddress() // Use solver as custom hook for testing
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes32', 'bytes', 'address'],
        [
          ethers.zeroPadValue(sourceChainProver, 32),
          metadata,
          customHookAddress,
        ],
      )

      const fee = await hyperProver.fetchFee(
        sourceChainId,
        minimalRoutes,
        rewardHashes,
        claimants,
        data,
      )

      // Call with custom hook
      await hyperProver
        .connect(owner)
        .prove(
          solver.address,
          sourceChainId,
          minimalRoutes,
          rewardHashes,
          claimants,
          data,
          {
            value: fee,
          },
        )

      // Verify dispatch was called (we can't directly check hook address as
      // TestMailbox doesn't expose that property)
      expect(await mailbox.dispatchedWithRelayer()).to.be.true
    })

    it('should handle empty arrays gracefully', async () => {
      // Set up test data with empty arrays
      const sourceChainId = 123
      const minimalRoutes: { salt: string; tokens: any[]; calls: any[] }[] = []
      const rewardHashes: string[] = []
      const claimants: string[] = []
      const sourceChainProver = await hyperProver.getAddress()
      const metadata = '0x1234'
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes32', 'bytes', 'address'],
        [
          ethers.zeroPadValue(sourceChainProver, 32),
          metadata,
          ethers.ZeroAddress,
        ],
      )

      const fee = await hyperProver.fetchFee(
        sourceChainId,
        minimalRoutes,
        rewardHashes,
        claimants,
        data,
      )

      // Should process empty arrays without error
      await expect(
        hyperProver
          .connect(owner)
          .prove(
            solver.address,
            sourceChainId,
            minimalRoutes,
            rewardHashes,
            claimants,
            data,
            {
              value: fee,
            },
          ),
      ).to.not.be.reverted

      // Should dispatch successfully
      expect(await mailbox.dispatchedWithRelayer()).to.be.true
    })

    it('should correctly format parameters in processAndFormat via fetchFee', async () => {
      // Since processAndFormat is internal, we'll test through fetchFee
      const sourceChainId = 123
      const salt = ethers.encodeBytes32String('0x987')
      const minimalRoutes = [
        {
          salt,
          tokens: [{ token: ethers.ZeroAddress, amount: 0 }],
          calls: [{ target: ethers.ZeroAddress, data: '0x', value: 0 }],
        },
      ]
      const rewardHashes = [ethers.keccak256('0x1234')]
      const claimants = [await claimant.getAddress()]
      const sourceChainProver = await solver.getAddress()
      const metadata = '0x1234'
      const hookAddress = ethers.ZeroAddress
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes32', 'bytes', 'address'],
        [ethers.zeroPadValue(sourceChainProver, 32), metadata, hookAddress],
      )

      // Call fetchFee which uses processAndFormat internally
      const fee = await hyperProver.fetchFee(
        sourceChainId,
        minimalRoutes,
        rewardHashes,
        claimants,
        data,
      )

      // Verify we get a valid fee (implementation dependent, so just check it's non-zero)
      expect(fee).to.be.gt(0)
    })

    it('should correctly call dispatch in the prove method', async () => {
      // Set up test data
      const sourceChainId = 123
      const salt = ethers.encodeBytes32String('0x987')
      const minimalRoutes = [
        {
          salt,
          tokens: [{ token: ethers.ZeroAddress, amount: 0 }],
          calls: [{ target: ethers.ZeroAddress, data: '0x', value: 0 }],
        },
      ]
      const rewardHashes = [ethers.keccak256('0x1234')]
      const claimants = [await claimant.getAddress()]
      const sourceChainProver = await hyperProver.getAddress()
      const metadata = '0x1234'
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        // ['sourceChainProver', 'metadata', 'hookAddress'],
        ['bytes32', 'bytes', 'address'],
        [
          ethers.zeroPadValue(sourceChainProver, 32),
          metadata,
          ethers.ZeroAddress,
        ],
      )

      // Before proving, make sure the mailbox hasn't been called
      expect(await mailbox.dispatchedWithRelayer()).to.be.false

      await expect(
        hyperProver.connect(owner).prove(
          owner.address,
          sourceChainId,
          minimalRoutes,
          rewardHashes,
          claimants,
          data,
          { value: 10000000000000 }, // Send some value to cover fees
        ),
      )
        .to.emit(hyperProver, 'BatchSent')
        .withArgs([expect.any(String)], sourceChainId)

      // Verify the mailbox was called with correct parameters
      expect(await mailbox.dispatchedWithRelayer()).to.be.true
      expect(await mailbox.destinationDomain()).to.eq(sourceChainId)
      expect(await mailbox.recipientAddress()).to.eq(
        ethers.zeroPadValue(sourceChainProver, 32),
      )

      // Verify message encoding is correct - Now the message body includes the inbox, minimalRoutes, rewardHashes, and claimants
      const expectedBody = ethers.AbiCoder.defaultAbiCoder().encode(
        [
          'address',
          'tuple(bytes32,tuple(address,uint256)[],tuple(address,bytes,uint256)[])[][][]',
          'bytes32[]',
          'address[]',
        ],
        [await inbox.getAddress(), minimalRoutes, rewardHashes, claimants],
      )
      expect(await mailbox.messageBody()).to.eq(expectedBody)
    })

    it('should gracefully return funds to sender if they overpay', async () => {
      // Set up test data
      const sourceChainId = 123
      const salt = ethers.encodeBytes32String('0x987')
      const minimalRoutes = [
        {
          salt,
          tokens: [{ token: ethers.ZeroAddress, amount: 0 }],
          calls: [{ target: ethers.ZeroAddress, data: '0x', value: 0 }],
        },
      ]
      const rewardHashes = [ethers.keccak256('0x1234')]
      const claimants = [await claimant.getAddress()]
      const sourceChainProver = await hyperProver.getAddress()
      const metadata = '0x1234'
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        // ['sourceChainProver', 'metadata', 'hookAddress'],
        ['bytes32', 'bytes', 'address'],
        [
          ethers.zeroPadValue(sourceChainProver, 32),
          metadata,
          ethers.ZeroAddress,
        ],
      )

      // Before proving, make sure the mailbox hasn't been called
      expect(await mailbox.dispatchedWithRelayer()).to.be.false

      const fee = await hyperProver.fetchFee(
        sourceChainId,
        minimalRoutes,
        rewardHashes,
        claimants,
        data,
      )
      const initBalance = await solver.provider.getBalance(solver.address)
      await expect(
        hyperProver.connect(owner).prove(
          solver.address,
          sourceChainId,
          minimalRoutes,
          rewardHashes,
          claimants,
          data,
          { value: fee * BigInt(10) }, // high number beacuse
        ),
      ).to.not.be.reverted
      expect(
        (await owner.provider.getBalance(solver.address)) >
          initBalance - fee * BigInt(10),
      ).to.be.true
    })
  })

  describe('4. End-to-End', () => {
    it('works end to end with message bridge', async () => {
      const chainId = 12345 // Use test chainId
      hyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await mailbox.getAddress(), await inbox.getAddress(), [
        await inbox.getAddress(),
        await hyperProver.getAddress(),
      ])
      await token.mint(solver.address, amount)

      // Set up intent data
      const sourceChainID = 12345
      const calldata = await encodeTransfer(await claimant.getAddress(), amount)
      const timeStamp = (await time.latest()) + 1000
      const salt = ethers.encodeBytes32String('0x987')
      const routeTokens = [{ token: await token.getAddress(), amount: amount }]
      const route = {
        salt: salt,
        source: sourceChainID,
        destination: Number(
          (await hyperProver.runner?.provider?.getNetwork())?.chainId,
        ),
        inbox: await inbox.getAddress(),
        tokens: routeTokens,
        calls: [
          {
            target: await token.getAddress(),
            data: calldata,
            value: 0,
          },
        ],
      }
      const reward = {
        creator: await owner.getAddress(),
        prover: await hyperProver.getAddress(),
        deadline: timeStamp + 1000,
        nativeValue: 1n,
        tokens: [] as TokenAmount[],
      }

      const { intentHash, rewardHash } = hashIntent({ route, reward })

      // Prepare message data
      const metadata = '0x1234'
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes32', 'bytes', 'address'],
        [
          ethers.zeroPadValue(await hyperProver.getAddress(), 32),
          metadata,
          ethers.ZeroAddress,
        ],
      )

      await token.connect(solver).approve(await inbox.getAddress(), amount)

      expect(await hyperProver.provenIntents(intentHash)).to.eq(
        ethers.ZeroAddress,
      )

      // Create minimal route for the intent
      const minimalRoute = {
        salt: salt,
        tokens: routeTokens,
        calls: route.calls,
      }

      // Get fee for fulfillment
      const fee = await hyperProver.fetchFee(
        sourceChainID,
        [minimalRoute],
        [rewardHash],
        [await claimant.getAddress()],
        data,
      )

      // Fulfill the intent using message bridge
      await inbox
        .connect(solver)
        .fulfillAndProve(
          route,
          rewardHash,
          await claimant.getAddress(),
          intentHash,
          await hyperProver.getAddress(),
          data,
          { value: fee },
        )

      //the testMailbox's dispatch method directly calls the hyperProver's handle method
      expect(await hyperProver.provenIntents(intentHash)).to.eq(
        await claimant.getAddress(),
      )

      //but lets simulate it fully anyway

      // Simulate the message being handled on the destination chain
      const msgBody = abiCoder.encode(
        ['bytes32[]', 'address[]'],
        [[intentHash], [await claimant.getAddress()]],
      )

      // For the end-to-end test, we need to simulate the mailbox
      // by deploying a new hyperProver with owner as the mailbox
      const simulatedHyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await owner.getAddress(), await inbox.getAddress(), [
        await inbox.getAddress(),
      ])

      // Handle the message and verify the intent is proven
      await expect(
        simulatedHyperProver
          .connect(owner) // Owner simulates the mailbox
          .handle(
            12345,
            ethers.zeroPadValue(await inbox.getAddress(), 32),
            msgBody,
          ),
      )
        .to.emit(simulatedHyperProver, 'IntentProven')
        .withArgs(intentHash, await claimant.getAddress())

      expect(await simulatedHyperProver.provenIntents(intentHash)).to.eq(
        await claimant.getAddress(),
      )
    })

    it('should work with batched message bridge fulfillment end-to-end', async () => {
      hyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await mailbox.getAddress(), await inbox.getAddress(), [
        await inbox.getAddress(),
        await hyperProver.getAddress(),
      ])

      // Set up token and mint
      await token.mint(solver.address, 2 * amount)

      // Set up common data
      const sourceChainID = 12345
      const calldata = await encodeTransfer(await claimant.getAddress(), amount)
      const timeStamp = (await time.latest()) + 1000
      const metadata = '0x1234'
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes32', 'bytes', 'address'],
        [
          ethers.zeroPadValue(await hyperProver.getAddress(), 32),
          metadata,
          ethers.ZeroAddress,
        ],
      )

      // Create first intent
      let salt = ethers.encodeBytes32String('0x987')
      const routeTokens: TokenAmount[] = [
        { token: await token.getAddress(), amount: amount },
      ]
      const route = {
        salt: salt,
        source: sourceChainID,
        destination: Number(
          (await hyperProver.runner?.provider?.getNetwork())?.chainId,
        ),
        inbox: await inbox.getAddress(),
        tokens: routeTokens,
        calls: [
          {
            target: await token.getAddress(),
            data: calldata,
            value: 0,
          },
        ],
      }
      const reward = {
        creator: await owner.getAddress(),
        prover: await hyperProver.getAddress(),
        deadline: timeStamp + 1000,
        nativeValue: 1n,
        tokens: [] as TokenAmount[],
      }

      const { intentHash: intentHash0, rewardHash: rewardHash0 } = hashIntent({
        route,
        reward,
      })

      // Approve tokens and check initial state
      await token.connect(solver).approve(await inbox.getAddress(), amount)
      expect(await hyperProver.provenIntents(intentHash0)).to.eq(
        ethers.ZeroAddress,
      )

      // Fulfill first intent in batch
      await inbox
        .connect(solver)
        .fulfill(
          route,
          rewardHash0,
          await claimant.getAddress(),
          intentHash0,
          await hyperProver.getAddress(),
        )

      // Create second intent
      salt = ethers.encodeBytes32String('0x1234')
      const route1 = {
        salt: salt,
        source: sourceChainID,
        destination: Number(
          (await hyperProver.runner?.provider?.getNetwork())?.chainId,
        ),
        inbox: await inbox.getAddress(),
        tokens: routeTokens,
        calls: [
          {
            target: await token.getAddress(),
            data: calldata,
            value: 0,
          },
        ],
      }
      const reward1 = {
        creator: await owner.getAddress(),
        prover: await hyperProver.getAddress(),
        deadline: timeStamp + 1000,
        nativeValue: 1n,
        tokens: [],
      }
      const { intentHash: intentHash1, rewardHash: rewardHash1 } = hashIntent({
        route: route1,
        reward: reward1,
      })

      // Approve tokens and fulfill second intent in batch
      await token.connect(solver).approve(await inbox.getAddress(), amount)
      await inbox
        .connect(solver)
        .fulfill(
          route1,
          rewardHash1,
          await claimant.getAddress(),
          intentHash1,
          await hyperProver.getAddress(),
        )

      // Check intent hasn't been proven yet
      expect(await hyperProver.provenIntents(intentHash1)).to.eq(
        ethers.ZeroAddress,
      )

      // Prepare message body for batch
      const msgbody = abiCoder.encode(
        ['bytes32[]', 'address[]'],
        [
          [intentHash0, intentHash1],
          [await claimant.getAddress(), await claimant.getAddress()],
        ],
      )

      // Create minimal routes for both intents
      const minimalRoute0 = {
        salt: route.salt,
        tokens: route.tokens,
        calls: route.calls,
      }

      const minimalRoute1 = {
        salt: route1.salt,
        tokens: route1.tokens,
        calls: route1.calls,
      }

      // Get fee for batch
      const fee = await hyperProver.fetchFee(
        sourceChainID,
        [minimalRoute0, minimalRoute1],
        [rewardHash0, rewardHash1],
        [await claimant.getAddress(), await claimant.getAddress()],
        data,
      )

      // Send batch to message bridge - the initiateProving should be updated to match the new Inbox interface
      // This test will need to be updated according to how Inbox.initiateProving has changed as well
      await expect(
        inbox
          .connect(solver)
          .initiateProving(
            sourceChainID,
            [minimalRoute0, minimalRoute1],
            [rewardHash0, rewardHash1],
            [await claimant.getAddress(), await claimant.getAddress()],
            await hyperProver.getAddress(),
            data,
            { value: fee },
          ),
      ).to.changeEtherBalance(solver, -Number(fee))

      //the testMailbox's dispatch method directly calls the hyperProver's handle method
      expect(await hyperProver.provenIntents(intentHash0)).to.eq(
        await claimant.getAddress(),
      )
      expect(await hyperProver.provenIntents(intentHash1)).to.eq(
        await claimant.getAddress(),
      )

      //but lets simulate it fully anyway

      // For the end-to-end test, we need to simulate the mailbox
      // by deploying a new hyperProver with owner as the mailbox
      const simulatedHyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await owner.getAddress(), await inbox.getAddress(), [
        await inbox.getAddress(),
      ])

      // Simulate handling of the batch message
      await expect(
        simulatedHyperProver
          .connect(owner) // Owner simulates the mailbox
          .handle(
            12345,
            ethers.zeroPadValue(await inbox.getAddress(), 32),
            msgbody,
          ),
      )
        .to.emit(simulatedHyperProver, 'IntentProven')
        .withArgs(intentHash0, await claimant.getAddress())
        .to.emit(simulatedHyperProver, 'IntentProven')
        .withArgs(intentHash1, await claimant.getAddress())

      // Verify both intents were proven
      expect(await simulatedHyperProver.provenIntents(intentHash0)).to.eq(
        await claimant.getAddress(),
      )
      expect(await simulatedHyperProver.provenIntents(intentHash1)).to.eq(
        await claimant.getAddress(),
      )
    })
  })
})
