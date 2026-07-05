import { hashIntent, hashReward, hashRoute } from '../hashing'
import { accountSalt } from '../addresses'
import type { Intent } from '../types'

// The SAME fixed intent as test/v3/sdk/GoldenVector.t.sol. The expected hashes below were emitted by that
// Solidity test (forge test --match-path test/v3/sdk/GoldenVector.t.sol -vv) — this asserts TS<->Solidity
// byte-parity of the hashing scheme.
const INTENT: Intent = {
  protocolVersion: 1,
  source: 8453n,
  destination: 10n,
  route: {
    salt: '0x000000000000000000000000000000000000000000000000000000000000abcd',
    deadline: 1_700_000_000n,
    portal: '0x2222222222222222222222222222222222222222',
    keeper: '0x3333333333333333333333333333333333333333',
    runtime: '0x4444444444444444444444444444444444444444',
    payload: '0xdeadbeef',
    minTokens: [
      {
        token: '0x1111111111111111111111111111111111111111',
        amount: 1_000_000n,
      },
    ],
  },
  reward: {
    deadline: 1_700_000_500n,
    keeper: '0x7777777777777777777777777777777777777777',
    prover: '0x8888888888888888888888888888888888888888',
    tokens: [
      {
        token: '0x5555555555555555555555555555555555555555',
        rate: 2_000_000_000_000_000_000n,
        flat: 500n,
      },
    ],
    // abi.encode(Hook[2]) where hook[0]={0x6666...,0xc0ffee}, hook[1]={address(0),0x}
    hooks: encodeHooksFixture(),
  },
}

const GOLDEN = {
  routeHash:
    '0x1f482c9106c98dc34320e7251b1f47a35a8209518c5dc7f86278ee951145a3ea',
  rewardHash:
    '0x5435b4137cc49f6627e966eddc3be93118edac8c4732fcff5ded126b22788b81',
  intentHash:
    '0x911a9cd64402c234a708c7a849125ab713d2edb18d4e0c02a2aa00266e0632d8',
}

// Build abi.encode(Hook[2]) exactly as the Solidity fixture does.
function encodeHooksFixture(): `0x${string}` {
  // Local import to keep the fixture self-contained.
  const { encodeAbiParameters } = require('viem')
  return encodeAbiParameters(
    [
      {
        type: 'tuple[2]',
        components: [
          { name: 'target', type: 'address' },
          { name: 'data', type: 'bytes' },
        ],
      },
    ],
    [
      [
        { target: '0x6666666666666666666666666666666666666666', data: '0xc0ffee' },
        { target: '0x0000000000000000000000000000000000000000', data: '0x' },
      ],
    ],
  )
}

describe('v3 SDK hashing golden vectors', () => {
  it('hashRoute matches Solidity', () => {
    expect(hashRoute(INTENT.route)).toBe(GOLDEN.routeHash)
  })

  it('hashReward matches Solidity', () => {
    expect(hashReward(INTENT.reward)).toBe(GOLDEN.rewardHash)
  })

  it('hashIntent matches Solidity', () => {
    expect(hashIntent(INTENT)).toBe(GOLDEN.intentHash)
  })

  it('accountSalt is deterministic and role-parameterized', () => {
    const escrow = accountSalt(GOLDEN.intentHash as `0x${string}`, INTENT.source)
    const exec = accountSalt(
      GOLDEN.intentHash as `0x${string}`,
      INTENT.destination,
    )
    expect(escrow).not.toBe(exec) // cross-chain: distinct accounts
    // same-chain collapse: same role id => same salt
    expect(accountSalt(GOLDEN.intentHash as `0x${string}`, INTENT.source)).toBe(
      escrow,
    )
  })
})
