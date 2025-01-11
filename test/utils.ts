import { Contract, ContractFactory, keccak256, Signer, AbiCoder } from 'ethers'

export type Call = {
  target: string
  data: string
  value: number
}

export type TokenAmount = {
  token: string
  amount: number
}

export type Route = {
  nonce: string
  source: number
  destination: number
  inbox: string
  calls: Call[]
}

export type Reward = {
  creator: string
  prover: string
  expiryTime: number
  nativeValue: bigint
  tokens: TokenAmount[]
}

export type Intent = {
  route: Route
  reward: Reward
}

const RouteStruct = [
  { name: 'nonce', type: 'bytes32' },
  { name: 'source', type: 'uint256' },
  { name: 'destination', type: 'uint256' },
  { name: 'inbox', type: 'address' },
  {
    name: 'calls',
    type: 'tuple[]',
    components: [
      { name: 'target', type: 'address' },
      { name: 'data', type: 'bytes' },
      { name: 'value', type: 'uint256' },
    ],
  },
]

const RewardStruct = [
  { name: 'creator', type: 'address' },
  { name: 'prover', type: 'address' },
  { name: 'expiryTime', type: 'uint256' },
  { name: 'nativeValue', type: 'uint256' },
  {
    name: 'tokens',
    type: 'tuple[]',
    components: [
      { name: 'token', type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
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

export function hashIntent(intent: Intent) {
  const routeHash = keccak256(encodeRoute(intent.route))
  const rewardHash = keccak256(encodeReward(intent.reward))

  const abiCoder = AbiCoder.defaultAbiCoder()
  const intentHash = keccak256(
    abiCoder.encode(['bytes32', 'bytes32'], [routeHash, rewardHash]),
  )

  return { routeHash, rewardHash, intentHash }
}
/**
 * Deploy a contract with the given factory from a certain address
 * Will be deployed by the given deployer address with the given params
 */
export async function deploy<F extends ContractFactory>(
  from: Signer,
  FactoryType: { new (from: Signer): F },
  params: any[] = [],
): Promise<Contract> {
  const factory = new FactoryType(from)
  const contract = await factory.deploy(...params)
  await contract.waitForDeployment()

  return contract
}
