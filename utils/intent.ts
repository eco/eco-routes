import { ethers } from 'hardhat'
import { getCreate2Address, keccak256, solidityPacked, AbiCoder } from 'ethers'

export type Call = {
  target: string
  data: string
  value: number | bigint
}

export type TokenAmount = {
  token: string
  amount: number | bigint
}

// v3 reward leg: rate+flat curve. A fixed reward of `amount` is `{token, rate: 0, flat: amount}`.
// Native folds in as a leg with `token == ZeroAddress`.
export type RewardToken = {
  token: string
  rate: number | bigint
  flat: number | bigint
}

export type Route = {
  salt: string
  deadline: number | bigint
  portal: string
  keeper: string
  calls: Call[]
  minTokens: TokenAmount[]
}

export type Reward = {
  keeper: string
  prover: string
  deadline: number | bigint
  tokens: RewardToken[]
}

export type Intent = {
  destination: number
  route: Route
  reward: Reward
}

const TokenAmountComponents = [
  { name: 'token', type: 'address' },
  { name: 'amount', type: 'uint256' },
]

const CallComponents = [
  { name: 'target', type: 'address' },
  { name: 'data', type: 'bytes' },
  { name: 'value', type: 'uint256' },
]

const RewardTokenComponents = [
  { name: 'token', type: 'address' },
  { name: 'rate', type: 'uint256' },
  { name: 'flat', type: 'uint256' },
]

const RouteStruct = [
  { name: 'salt', type: 'bytes32' },
  { name: 'deadline', type: 'uint64' },
  { name: 'portal', type: 'address' },
  { name: 'keeper', type: 'address' },
  {
    name: 'calls',
    type: 'tuple[]',
    components: CallComponents,
  },
  {
    name: 'minTokens',
    type: 'tuple[]',
    components: TokenAmountComponents,
  },
]

const RewardStruct = [
  { name: 'deadline', type: 'uint64' },
  { name: 'keeper', type: 'address' },
  { name: 'prover', type: 'address' },
  {
    name: 'tokens',
    type: 'tuple[]',
    components: RewardTokenComponents,
  },
]

const IntentStruct = [
  {
    name: 'destination',
    type: 'uint64',
  },
  {
    name: 'route',
    type: 'tuple',
    components: RouteStruct,
  },
  {
    name: 'reward',
    type: 'tuple',
    components: RewardStruct,
  },
]

export function encodeRoute(route: Route) {
  const abiCoder = AbiCoder.defaultAbiCoder()
  return abiCoder.encode(
    [
      {
        type: 'tuple',
        components: RouteStruct,
      },
    ],
    [route],
  )
}

export function encodeReward(reward: Reward) {
  const abiCoder = AbiCoder.defaultAbiCoder()
  return abiCoder.encode(
    [
      {
        type: 'tuple',
        components: RewardStruct,
      },
    ],
    [reward],
  )
}

export function encodeIntent(intent: Intent) {
  const abiCoder = AbiCoder.defaultAbiCoder()
  return abiCoder.encode(
    [
      {
        type: 'tuple',
        components: IntentStruct,
      },
    ],
    [intent],
  )
}

export function hashIntent(intent: Intent) {
  const routeHash = keccak256(encodeRoute(intent.route))
  const rewardHash = keccak256(encodeReward(intent.reward))

  const intentHash = keccak256(
    solidityPacked(
      ['uint64', 'bytes32', 'bytes32'],
      [intent.destination, routeHash, rewardHash],
    ),
  )

  return { routeHash, rewardHash, intentHash }
}

/**
 * Computes the v3 hash-only fulfillment commitment:
 *   fulfillmentHash = keccak256(abi.encode(intentHash, claimant, fulfilled))
 * `claimant` must be a 32-byte value (use addressToBytes32 / zeroPadValue for an EVM address).
 * `fulfilled` is the per-leg delivered amounts (empty for no-min-out intents).
 */
export function hashFulfillment(
  intentHash: string,
  claimant: string,
  fulfilled: Array<number | bigint> = [],
) {
  return keccak256(
    AbiCoder.defaultAbiCoder().encode(
      ['bytes32', 'bytes32', 'uint256[]'],
      [intentHash, claimant, fulfilled],
    ),
  )
}

export async function intentAccountAddress(
  intentSourceAddress: string,
  intent: Intent,
) {
  const { routeHash, intentHash } = hashIntent(intent)
  const intentAccountFactory = await ethers.getContractFactory('Account')
  const abiCoder = AbiCoder.defaultAbiCoder()

  return getCreate2Address(
    intentSourceAddress,
    routeHash,
    keccak256(
      solidityPacked(
        ['bytes', 'bytes'],
        [
          intentAccountFactory.bytecode,
          abiCoder.encode(
            [
              'bytes32',
              {
                type: 'tuple',
                components: RewardStruct,
              },
            ],
            [intentHash, intent.reward],
          ),
        ],
      ),
    ),
  )
}
