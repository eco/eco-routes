import type { Address, Hex } from 'viem'

/** A `(token, amount)` pair used for `route.minTokens` (solver input floor) and `fulfilled` amounts. */
export interface TokenAmount {
  token: Address // address(0) => native
  amount: bigint
}

/** A reward leg: payout = flat + rate * provided / WAD (WAD = 1e18), capped at escrow. */
export interface RewardToken {
  token: Address // address(0) => native
  rate: bigint
  flat: bigint
}

/** A keeper-committed delegate hook (target + calldata). */
export interface Hook {
  target: Address
  data: Hex
}

export interface Route {
  salt: Hex
  deadline: bigint
  portal: Address
  keeper: Address
  runtime: Address
  payload: Hex
  minTokens: TokenAmount[]
}

export interface Reward {
  deadline: bigint
  keeper: Address
  prover: Address
  tokens: RewardToken[]
  hooks: Hex // default encoding: abi.encode(Hook[2])
}

export interface Intent {
  protocolVersion: number // uint32 — creator-declared Portal implementation version (first hashed field)
  source: bigint
  destination: bigint
  route: Route
  reward: Reward
}

/** Fixed-point scale (1e18) used as the denominator for `RewardToken.rate`. */
export const WAD = 10n ** 18n
