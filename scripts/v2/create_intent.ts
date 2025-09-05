import { ethers } from 'hardhat'
import { parseEther, parseUnits } from 'ethers'
import {
  Intent,
  Route,
  Reward,
  hashIntent,
  encodeRoute,
} from '../../utils/intent'
import { parseAbi } from 'viem'

/**
 * Creates an intent against the Portal contract for cross-chain token transfers
 * Uses configuration from eco/routes-cli repository:
 * - Portal addresses: 0x90F0c8aCC1E083Bcb4F487f84FC349ae8d5e28D7 (both networks)
 * - Base USDC: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
 * - Optimism USDC: 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85
 */

// Network configurations
const NETWORKS = {
  base: {
    chainId: 8453,
    name: 'base',
    // Portal contract addresses from routes-cli config
    portal: '0x90F0c8aCC1E083Bcb4F487f84FC349ae8d5e28D7', // Deployed Portal contract on Base
    // Common stablecoins on Base
    usdc: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913', // USDC on Base
  },
  optimism: {
    chainId: 10,
    name: 'optimism',
    // Portal contract addresses from routes-cli config
    portal: '0x90F0c8aCC1E083Bcb4F487f84FC349ae8d5e28D7', // Deployed Portal contract on Optimism
    // Common stablecoins on Optimism
    usdc: '0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85', // USDC on Optimism (updated address)
  },
}

// Default configuration
const DEFAULT_CONFIG = {
  // Amount of USDC to transfer (0.1 USDC)
  transferAmount: parseUnits('0.1', 6), // USDC has 6 decimals
  // Token reward amount (0.01 USDC reward)
  tokenRewardAmount: parseUnits('0.01', 6), // USDC reward
  // Native reward amount in ETH (minimal amount for gas coverage)
  rewardAmount: parseEther('0.000001'),
  // Deadline (24 hours from now)
  deadline: Math.floor(Date.now() / 1000) + 24 * 60 * 60,
  // Recipient address for the token transfer (placeholder)
  recipient: '0xfc79413b46256405819A32Fb25A9B6Dd9A911559',
}
/**
 * Creates an intent for cross-chain token transfer using the Portal contract
 * @param sourceNetwork The source network ('base' or 'optimism')
 * @param destinationNetwork The destination network ('base' or 'optimism')
 * @param creatorAddress The address creating the intent
 * @param proverAddress The address of the prover contract
 */
async function createIntent(
  sourceNetwork: keyof typeof NETWORKS,
  destinationNetwork: keyof typeof NETWORKS,
  creatorAddress: string,
  proverAddress: string,
): Promise<void> {
  const source = NETWORKS[sourceNetwork]
  const destination = NETWORKS[destinationNetwork]

  console.log(`Creating intent from ${source.name} to ${destination.name}`)

  // Create ERC20 transfer call data using ethers v6 Interface
  const erc20Interface = new ethers.Interface([
    'function transfer(address to, uint256 amount) returns (bool)',
  ])

  const transferCallData = erc20Interface.encodeFunctionData('transfer', [
    DEFAULT_CONFIG.recipient,
    DEFAULT_CONFIG.transferAmount,
  ])

  // Create the route for the destination chain
  const route: Route = {
    salt: ethers.randomBytes(32), // Random salt for uniqueness
    deadline: BigInt(DEFAULT_CONFIG.deadline),
    portal: destination.portal,
    nativeAmount: 0n, // No native token transfer
    tokens: [
      {
        token: destination.usdc, // USDC on destination chain
        amount: DEFAULT_CONFIG.transferAmount,
      },
    ],
    calls: [
      {
        target: destination.usdc, // Call the USDC contract
        data: transferCallData, // Transfer function call
        value: 0n, // No ETH value for ERC20 transfer
      },
    ],
  }

  // Create the reward structure with both native and token rewards
  const reward: Reward = {
    creator: creatorAddress,
    prover: proverAddress,
    deadline: BigInt(DEFAULT_CONFIG.deadline),
    nativeAmount: DEFAULT_CONFIG.rewardAmount, // Small native reward for gas
    tokens: [
      {
        token: source.usdc, // Reward with USDC on source chain
        amount: DEFAULT_CONFIG.tokenRewardAmount,
      },
    ], // Token rewards
  }

  // Create the complete intent
  const intent: Intent = {
    destination: destination.chainId,
    route: route,
    reward: reward,
  }

  // Calculate intent hash
  const { intentHash, routeHash, rewardHash } = hashIntent(intent)

  console.log('Intent created with:')
  console.log('- Intent Hash:', intentHash)
  console.log('- Route Hash:', routeHash)
  console.log('- Reward Hash:', rewardHash)
  console.log('- Destination Chain ID:', destination.chainId)
  console.log('- Recipient Address:', DEFAULT_CONFIG.recipient)
  console.log(
    '- Transfer Amount:',
    ethers.formatUnits(DEFAULT_CONFIG.transferAmount, 6),
    'USDC',
  )
  console.log(
    '- Token Reward Amount:',
    ethers.formatUnits(DEFAULT_CONFIG.tokenRewardAmount, 6),
    'USDC',
  )
  console.log(
    '- Native Reward Amount:',
    ethers.formatEther(DEFAULT_CONFIG.rewardAmount),
    'ETH',
  )
  console.log(
    '- Deadline:',
    new Date(DEFAULT_CONFIG.deadline * 1000).toISOString(),
  )
  console.log('- Calls:', route.calls.length, 'call(s) - ERC20 transfer')

  // Connect to the source network and create the intent
  try {
    // Create the Portal ABI based on routes-cli implementation
    const portalAbi = [
      'error InsufficientFunds(bytes32 intentHash)',
      'function publishAndFund(uint64 destination, bytes route, (uint64 deadline,address creator,address prover,uint256 nativeAmount,(address token, uint256 amount)[] tokens) reward, bool allowPartial) external payable returns (bytes32 intentHash, address vault)',
      'function approve(address spender, uint256 amount) external returns (bool)',
    ]

    // Get signer and connect to Portal contract
    const [signer] = await ethers.getSigners()
    const portal = new ethers.Contract(source.portal, portalAbi, signer)

    // Encode the route as bytes using the proper encoding function
    const routeBytes = encodeRoute(route)

    console.log('Connecting to Portal contract at:', source.portal)

    // Check balances
    const balance = await ethers.provider.getBalance(signer.address)
    console.log('Account balance:', ethers.formatEther(balance), 'ETH')

    // Check and approve reward tokens if needed
    if (DEFAULT_CONFIG.tokenRewardAmount > 0n) {
      const erc20Abi = [
        'function approve(address spender, uint256 amount) external returns (bool)',
      ]
      const tokenContract = new ethers.Contract(source.usdc, erc20Abi, signer)

      console.log('Approving reward tokens...')
      const approveTx = await tokenContract.approve(
        source.portal,
        DEFAULT_CONFIG.tokenRewardAmount,
      )
      await approveTx.wait()
      console.log('Token approval confirmed')
    }

    // Estimate gas for the transaction
    try {
      const gasEstimate = await portal.publishAndFund.estimateGas(
        destination.chainId,
        routeBytes,
        reward,
        false, // allowPartial
        { value: DEFAULT_CONFIG.rewardAmount },
      )
      console.log('Estimated gas:', gasEstimate.toString())

      // Get gas price
      const gasPrice = await ethers.provider.getFeeData()
      console.log(
        'Gas price (gwei):',
        ethers.formatUnits(gasPrice.gasPrice || 0n, 'gwei'),
      )

      const totalCost =
        gasEstimate * (gasPrice.gasPrice || 0n) + DEFAULT_CONFIG.rewardAmount
      console.log(
        'Total transaction cost:',
        ethers.formatEther(totalCost),
        'ETH',
      )

      if (balance < totalCost) {
        console.log('⚠️  Insufficient balance for transaction!')
        console.log('Required:', ethers.formatEther(totalCost), 'ETH')
        console.log('Available:', ethers.formatEther(balance), 'ETH')
        console.log(
          'Shortfall:',
          ethers.formatEther(totalCost - balance),
          'ETH',
        )
        return
      }
    } catch (gasError) {
      console.log('Gas estimation failed:', gasError)
      console.log('Proceeding with transaction anyway...')
    }

    // Publish and fund the intent with the correct function signature
    console.log('Publishing intent...')
    const tx = await portal.publishAndFund(
      destination.chainId, // uint64 destination
      routeBytes, // bytes route
      reward, // Reward struct
      false, // bool allowPartial
      {
        value: DEFAULT_CONFIG.rewardAmount, // ETH for native rewards
        gasLimit: 1000000, // Increased gas limit for complex transaction
      },
    )

    console.log('Transaction hash:', tx.hash)
    console.log('Waiting for confirmation...')

    const receipt = await tx.wait()
    console.log('Intent published successfully!')
    console.log('Block number:', receipt?.blockNumber)
    console.log('Gas used:', receipt?.gasUsed?.toString())

    // Extract intent hash from logs if available
    try {
      const logs = receipt?.logs || []
      if (logs.length > 0) {
        console.log('Transaction logs:', logs.length, 'log(s) generated')
      }
    } catch (logError) {
      console.log('Could not parse transaction logs')
    }
  } catch (error) {
    console.error('Error creating intent:', error)
    throw error
  }
}

/**
 * Main function to run the script
 */
async function main() {
  // Check environment variables
  const privateKey = process.env.DEPLOYER_PRIVATE_KEY || process.env.PRIVATE_KEY
  if (!privateKey || privateKey === '0x' + '11'.repeat(32)) {
    console.log('⚠️  No private key found in environment variables!')
    console.log(
      'Please set either DEPLOYER_PRIVATE_KEY or PRIVATE_KEY in your .env file',
    )
    console.log(
      'Current DEPLOYER_PRIVATE_KEY:',
      process.env.DEPLOYER_PRIVATE_KEY ? 'Set' : 'Not set',
    )
    console.log(
      'Current PRIVATE_KEY:',
      process.env.PRIVATE_KEY ? 'Set' : 'Not set',
    )
    return
  }

  // Default addresses - these should be replaced with actual addresses
  const creatorAddress = '0xfc79413b46256405819A32Fb25A9B6Dd9A911559' // TODO: Set creator address
  const proverAddress = '0xde255Aab8e56a6Ae6913Df3a9Bbb6a9f22367f4C' // TODO: Set prover address

  // Parse command line arguments or use defaults
  const sourceNetwork =
    (process.env.SOURCE_NETWORK as keyof typeof NETWORKS) || 'base'
  const destinationNetwork =
    (process.env.DEST_NETWORK as keyof typeof NETWORKS) || 'optimism'

  console.log('Script configuration:')
  console.log('- Source Network:', sourceNetwork)
  console.log('- Destination Network:', destinationNetwork)
  console.log('- Creator Address:', creatorAddress)
  console.log('- Prover Address:', proverAddress)
  console.log(
    '- Private Key:',
    privateKey ? 'Set (0x' + privateKey.slice(2, 6) + '...)' : 'Not set',
  )
  console.log()

  if (
    creatorAddress === '0x0000000000000000000000000000000000000000' ||
    proverAddress === '0x0000000000000000000000000000000000000000' ||
    DEFAULT_CONFIG.recipient === '0x0000000000000000000000000000000000000000'
  ) {
    console.log(
      '⚠️  Please set creator, prover, and recipient addresses before running the script.',
    )
    console.log('Required addresses:')
    console.log(
      '- Creator Address:',
      creatorAddress === '0x0000000000000000000000000000000000000000'
        ? '❌ Not set'
        : '✅ Set',
    )
    console.log(
      '- Prover Address:',
      proverAddress === '0x0000000000000000000000000000000000000000'
        ? '❌ Not set'
        : '✅ Set',
    )
    console.log(
      '- Recipient Address:',
      DEFAULT_CONFIG.recipient === '0x0000000000000000000000000000000000000000'
        ? '❌ Not set'
        : '✅ Set',
    )
    console.log(
      'You can set them by modifying the DEFAULT_CONFIG in the script.',
    )
    return
  }

  await createIntent(
    sourceNetwork,
    destinationNetwork,
    creatorAddress,
    proverAddress,
  )
}

// Error handling for main function
if (require.main === module) {
  main()
    .then(() => {
      console.log('Script completed successfully')
      process.exit(0)
    })
    .catch((error) => {
      console.error('Script failed:', error)
      process.exit(1)
    })
}

export { createIntent, NETWORKS, DEFAULT_CONFIG }
