import { ethers } from 'ethers'
import * as fs from 'fs'
import * as path from 'path'
import { TronWeb } from 'tronweb'
import {
  AGGREGATOR_MEMBER_PROOF_TYPES,
  AGGREGATOR_PROVER_CONSTRUCTOR_TYPES,
  HYPER_PROVER_CONSTRUCTOR_TYPES,
  NEXT_GEN,
  POLYMER_PROVER_CONSTRUCTOR_TYPES,
  SOLANA_CHAIN_ID,
  aggregatorProverConstructorArgs,
  aggregatorProverReadback,
  hyperProverConstructorArgs,
  hyperProverReadback,
  identityDomainConfig,
  leftPad,
  nextGenHyperProverArgs,
  nextGenPolymerProverArgs,
  parseTronAddress,
  polymerProverConstructorArgs,
  polymerProverReadback,
  readbackMatches,
  requireAddressWhitelist,
  requireLiveMembers,
  toTronBase58,
  contractHasCode,
  EMPTY_CODE_HASH,
} from '../next-gen-tron-provers'

const coder = ethers.AbiCoder.defaultAbiCoder()
const addr = (n: number) => '0x' + n.toString(16).padStart(40, '0')

const PORTAL_TRON_B58 = 'TDYD42VmbScmqYkqG97aLgRN74Dqq9Fuva'
const CROSS_L2_B58 = 'TNKCTuonyurjAXBYpZtSZEo7WdFUKW9cbN'
const EVM_HYPER_WORD =
  '0x000000000000000000000000ec03abb6de97b153cc31724cd8da9aa897d1b075'
const EVM_POLYMER_WORD =
  '0x000000000000000000000000ec03e87e167c14b8c89fe5f80db62b29a5138fc4'
const EVM_LANES = [
  1n,
  10n,
  130n,
  137n,
  143n,
  480n,
  999n,
  2020n,
  5042n,
  8453n,
  9745n,
  42161n,
]
// A 32-byte Solana key (base58 decodes to full-width bytes): never a valid Tron whitelist entry.
const SOLANA_KEY_WORD =
  '0x9a3f1c2b7e8d4f60a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718'

/** Encodes constructor args from the compiled ABI, or undefined before `forge build`. */
function encodeDeploy(name: string, values: unknown[]): string | undefined {
  const artifact = path.join(__dirname, `../../../out/${name}.sol/${name}.json`)
  if (!fs.existsSync(artifact)) return undefined // needs `forge build`
  const { abi } = JSON.parse(fs.readFileSync(artifact, 'utf8'))
  return new ethers.Interface(abi).encodeDeploy(values)
}

describe('Tron address helpers', () => {
  it('parses base58check, 41-hex and 0x hex to the same lowercase hex20', () => {
    const hex = '0x27262594c6088865ac3e7ac20f401af3bd379b1b'
    expect(parseTronAddress(PORTAL_TRON_B58)).toBe(hex)
    expect(parseTronAddress('41' + hex.slice(2).toUpperCase())).toBe(hex)
    expect(parseTronAddress(hex.toUpperCase().replace('0X', '0x'))).toBe(hex)
    expect('0x' + TronWeb.address.toHex(PORTAL_TRON_B58).slice(2)).toBe(hex)
  })

  it('round-trips to base58 exactly as TronWeb does', () => {
    for (const hex of [
      NEXT_GEN.portalTron,
      NEXT_GEN.tronCrossL2ProverV2,
      addr(1),
    ]) {
      expect(toTronBase58(hex)).toBe(
        TronWeb.address.fromHex('41' + hex.slice(2)),
      )
      expect(parseTronAddress(toTronBase58(hex))).toBe(hex)
    }
  })

  it('rejects a base58 address with a bad checksum', () => {
    const last = PORTAL_TRON_B58.slice(-1)
    const typo = PORTAL_TRON_B58.slice(0, -1) + (last === 'a' ? 'b' : 'a')
    expect(() => parseTronAddress(typo, 'member 0')).toThrow(
      /member 0.*invalid base58check checksum/,
    )
  })

  it('rejects the zero address, short hex and non-Tron strings', () => {
    expect(() => parseTronAddress(addr(0))).toThrow(/zero address/)
    expect(() => parseTronAddress('0x1234')).toThrow(/not a Tron address/)
    expect(() => parseTronAddress('0x' + 'ab'.repeat(32))).toThrow(
      /not a Tron address/,
    )
    expect(() => parseTronAddress('hello')).toThrow(/not a Tron address/)
  })

  it('left-pads a 20-byte address (bytes32(uint256(uint160(a)))), never right-pads', () => {
    expect(leftPad(NEXT_GEN.evmHyperProver)).toBe(EVM_HYPER_WORD)
    expect(leftPad(NEXT_GEN.evmPolymerProver)).toBe(EVM_POLYMER_WORD)
  })

  it('pins the next-gen constants to the addresses in the brief', () => {
    expect(toTronBase58(NEXT_GEN.portalTron)).toBe(PORTAL_TRON_B58)
    expect(toTronBase58(NEXT_GEN.tronCrossL2ProverV2)).toBe(CROSS_L2_B58)
    expect(ethers.getAddress(NEXT_GEN.tronMailbox)).toBe(
      '0x6d5BeE57A58E282150c236ed8985550492a69788',
    )
    expect(NEXT_GEN.hyperDomainChainIds).toEqual(EVM_LANES)
  })
})

describe('whitelist and domain validation', () => {
  it('refuses a Solana key in a whitelist (not a left-padded address)', () => {
    expect(() =>
      requireAddressWhitelist('provers', [EVM_HYPER_WORD, SOLANA_KEY_WORD]),
    ).toThrow(/not a left-padded 20-byte address/)
  })

  it('refuses a right-padded address, duplicates, zero and empty sets', () => {
    const rightPadded = ethers.zeroPadBytes(NEXT_GEN.evmHyperProver, 32)
    expect(() => requireAddressWhitelist('w', [rightPadded])).toThrow(
      /left-padded/,
    )
    expect(() =>
      requireAddressWhitelist('w', [EVM_HYPER_WORD, EVM_HYPER_WORD]),
    ).toThrow(/duplicate/)
    expect(() => requireAddressWhitelist('w', [ethers.ZeroHash])).toThrow(
      /zero/,
    )
    expect(() => requireAddressWhitelist('w', [])).toThrow(/1 to 20/)
  })

  it('refuses a Solana or Tron domain, duplicates and zero', () => {
    expect(() => identityDomainConfig([1n, SOLANA_CHAIN_ID])).toThrow(/Solana/)
    expect(() => identityDomainConfig([1n, 728126428n])).toThrow(/Tron/)
    expect(() => identityDomainConfig([1n, 1n])).toThrow(/duplicate/)
    expect(() => identityDomainConfig([0n])).toThrow(/valid uint64/)
  })
})

describe('Tron HyperProver constructor', () => {
  const args = nextGenHyperProverArgs()
  const domains = EVM_LANES.map((c) => ({ domain: c, chainId: c }))

  it('encodes (Mailbox, PortalTron, [pad(EVM HyperProver)], identity map of the 12 EVM lanes)', () => {
    const [mailbox, portal, provers, decoded] = coder.decode(
      HYPER_PROVER_CONSTRUCTOR_TYPES,
      args.encoded,
    )
    expect(mailbox).toBe('0x6d5BeE57A58E282150c236ed8985550492a69788')
    expect(portal.toLowerCase()).toBe(NEXT_GEN.portalTron)
    expect(provers).toEqual([EVM_HYPER_WORD])
    expect(
      decoded.map((d: { domain: bigint; chainId: bigint }) => ({
        domain: d.domain,
        chainId: d.chainId,
      })),
    ).toEqual(domains)
  })

  it("matches the compiled HyperProver's own constructor encoding", () => {
    const expected = encodeDeploy('HyperProver', [
      '0x6d5BeE57A58E282150c236ed8985550492a69788',
      NEXT_GEN.portalTron,
      [EVM_HYPER_WORD],
      domains,
    ])
    if (expected) expect(args.encoded).toBe(expected)
  })

  it('refuses a Solana lane in the domain map', () => {
    expect(() =>
      hyperProverConstructorArgs({
        mailbox: NEXT_GEN.tronMailbox,
        portal: NEXT_GEN.portalTron,
        trustedProvers: [NEXT_GEN.evmHyperProver],
        domainChainIds: [...EVM_LANES, SOLANA_CHAIN_ID],
      }),
    ).toThrow(/Solana/)
  })

  it('reads back PORTAL, MAILBOX, the exact whitelist, every lane, and Solana/Tron unset', () => {
    const self = addr(0xabc)
    const checks = hyperProverReadback(self, args)
    const byLabel = Object.fromEntries(checks.map((c) => [c.label, c]))
    expect(byLabel['PORTAL()'].expected).toBe(NEXT_GEN.portalTron)
    expect(byLabel['MAILBOX()'].expected).toBe(NEXT_GEN.tronMailbox)
    expect(byLabel['getWhitelist()'].expected).toEqual([EVM_HYPER_WORD])
    expect(byLabel['isWhitelisted(self) false'].args).toEqual([leftPad(self)])
    expect(byLabel['chainIdByDomain(1399811149) unset'].expected).toBe(0n)
    expect(byLabel['chainIdByDomain(728126428) unset'].expected).toBe(0n)
    expect(
      checks.filter(
        (c) => c.signature === 'chainIdByDomain(uint64)' && c.expected !== 0n,
      ),
    ).toHaveLength(12)
  })
})

describe('Tron PolymerProver constructor (6 args)', () => {
  const args = nextGenPolymerProverArgs()

  it('encodes (PortalTron, CrossL2ProverV2, 2048, 2, 1399811149, [pad(EVM PolymerProver)])', () => {
    const decoded = coder.decode(POLYMER_PROVER_CONSTRUCTOR_TYPES, args.encoded)
    expect(decoded[0].toLowerCase()).toBe(NEXT_GEN.portalTron)
    expect(toTronBase58(decoded[1].toLowerCase())).toBe(CROSS_L2_B58)
    expect(decoded[2]).toBe(2048n)
    expect(decoded[3]).toBe(2n)
    expect(decoded[4]).toBe(1399811149n)
    expect([...decoded[5]]).toEqual([EVM_POLYMER_WORD])
  })

  it("matches the compiled PolymerProver's own constructor encoding", () => {
    const expected = encodeDeploy('PolymerProver', [
      NEXT_GEN.portalTron,
      NEXT_GEN.tronCrossL2ProverV2,
      2048n,
      2n,
      1399811149n,
      [EVM_POLYMER_WORD],
    ])
    if (expected) expect(args.encoded).toBe(expected)
  })

  it('refuses zero Solana ids and an out-of-range maxLogDataSize, as the constructor does', () => {
    const base = {
      portal: NEXT_GEN.portalTron,
      crossL2ProverV2: NEXT_GEN.tronCrossL2ProverV2,
      maxLogDataSize: 2048n,
      solanaPolymerChainId: 2n,
      solanaChainId: SOLANA_CHAIN_ID,
      trustedProvers: [NEXT_GEN.evmPolymerProver],
    }
    expect(() =>
      polymerProverConstructorArgs({ ...base, solanaPolymerChainId: 0n }),
    ).toThrow(/solanaPolymerChainId/)
    expect(() =>
      polymerProverConstructorArgs({ ...base, solanaChainId: 0n }),
    ).toThrow(/solanaChainId/)
    expect(() =>
      polymerProverConstructorArgs({ ...base, maxLogDataSize: 32769n }),
    ).toThrow(/maxLogDataSize/)
  })

  it('reads back every immutable and the exact whitelist', () => {
    const checks = polymerProverReadback(addr(0xdef), args)
    const expected = Object.fromEntries(
      checks.map((c) => [c.label, c.expected]),
    )
    expect(expected['CROSS_L2_PROVER_V2()']).toBe(NEXT_GEN.tronCrossL2ProverV2)
    expect(expected['MAX_LOG_DATA_SIZE()']).toBe(2048n)
    expect(expected['SOLANA_POLYMER_CHAIN_ID()']).toBe(2n)
    expect(expected['SOLANA_CHAIN_ID()']).toBe(1399811149n)
    expect(expected['getWhitelist()']).toEqual([EVM_POLYMER_WORD])
  })
})

describe('Tron AggregatorProver constructor', () => {
  const hyper = toTronBase58(addr(0x1111))
  const polymer = toTronBase58(addr(0x2222))
  const layerzero = '0x' + '33'.repeat(20)

  it('encodes the members in priority order, left-padded, from base58 or hex', () => {
    const args = aggregatorProverConstructorArgs([hyper, polymer, layerzero])
    const [members] = coder.decode(
      AGGREGATOR_PROVER_CONSTRUCTOR_TYPES,
      args.encoded,
    )
    expect([...members]).toEqual([
      leftPad(addr(0x1111)),
      leftPad(addr(0x2222)),
      leftPad(layerzero),
    ])
    const expected = encodeDeploy('AggregatorProver', [[...members]])
    if (expected) expect(args.encoded).toBe(expected)
    expect(aggregatorProverReadback(args)[0].expected).toEqual([
      addr(0x1111),
      addr(0x2222),
      layerzero,
    ])
  })

  it('refuses duplicates, more than 8 members and a bad checksum', () => {
    expect(() => aggregatorProverConstructorArgs([hyper, hyper])).toThrow(
      /duplicate/,
    )
    expect(() =>
      aggregatorProverConstructorArgs(
        Array.from({ length: 9 }, (_, i) => addr(i + 1)),
      ),
    ).toThrow(/1 to 8/)
    const typo = hyper.slice(0, -1) + (hyper.endsWith('a') ? 'b' : 'a')
    expect(() => aggregatorProverConstructorArgs([typo])).toThrow(/checksum/)
  })

  describe('requireLiveMembers', () => {
    const members = [addr(0x1111), addr(0x2222), layerzero]
    const expected = {
      portal: NEXT_GEN.portalTron,
      proofTypes: AGGREGATOR_MEMBER_PROOF_TYPES,
    }
    const types: Record<string, string> = {
      [addr(0x1111)]: 'Hyperlane',
      [addr(0x2222)]: 'Polymer',
      [layerzero]: 'LayerZero',
    }
    const probe = (
      overrides: Partial<Parameters<typeof requireLiveMembers>[1]> = {},
    ) => ({
      hasCode: jest.fn(async () => true),
      portal: jest.fn(async () => NEXT_GEN.portalTron),
      proofType: jest.fn(async (m: string) => types[m]),
      ...overrides,
    })

    it('accepts live members bound to PortalTron in Hyperlane > Polymer > LayerZero order', async () => {
      await expect(
        requireLiveMembers(members, probe(), expected),
      ).resolves.toBeUndefined()
    })

    it('refuses when a member has no code, before any other probe', async () => {
      const p = probe({
        hasCode: jest.fn(async (m: string) => m !== layerzero),
      })
      await expect(requireLiveMembers(members, p, expected)).rejects.toThrow(
        new RegExp(
          `no code on Tron: ${toTronBase58(layerzero)}.*MemberHasNoCode`,
        ),
      )
      expect(p.portal).not.toHaveBeenCalled()
    })

    it('refuses a member bound to another Portal', async () => {
      const p = probe({
        portal: jest.fn(async (m: string) =>
          m === addr(0x2222) ? addr(0x9999) : NEXT_GEN.portalTron,
        ),
      })
      await expect(requireLiveMembers(members, p, expected)).rejects.toThrow(
        /PORTAL\(\) is 0x0+9999/,
      )
    })

    it('refuses members out of priority order', async () => {
      const swapped = [addr(0x2222), addr(0x1111), layerzero]
      await expect(
        requireLiveMembers(swapped, probe(), expected),
      ).rejects.toThrow(/priority 0 reports getProofType\(\) "Polymer"/)
    })
  })
})

describe('contractHasCode', () => {
  it('counts a contract created by another contract, which Tron returns with code_hash only', () => {
    // Shape of /wallet/getcontract for TEcoHmv6… (deployed through the CREATE2 factory).
    expect(
      contractHasCode({
        code_hash:
          '9a1f0a1fb0d1bfb4c09b4b0b2b3ca8b3c1a2ae5d16a2a3de2f9a0e7c4b6f5d21',
      }),
    ).toBe(true)
  })

  it('counts a directly deployed contract, which carries its bytecode', () => {
    expect(contractHasCode({ bytecode: '6080604052' })).toBe(true)
  })

  it('refuses an account with no contract, and the empty-code hash', () => {
    expect(contractHasCode({})).toBe(false)
    expect(contractHasCode(undefined)).toBe(false)
    expect(contractHasCode({ code_hash: EMPTY_CODE_HASH })).toBe(false)
    expect(
      contractHasCode({ code_hash: '0x' + EMPTY_CODE_HASH.toUpperCase() }),
    ).toBe(false)
  })
})

describe('readbackMatches', () => {
  it('compares decoded ethers values case-insensitively, arrays included', () => {
    const [list] = coder.decode(
      ['bytes32[]'],
      coder.encode(['bytes32[]'], [[EVM_HYPER_WORD]]),
    )
    expect(
      readbackMatches(list, [EVM_HYPER_WORD.toUpperCase().replace('0X', '0x')]),
    ).toBe(true)
    expect(readbackMatches(list, [EVM_POLYMER_WORD])).toBe(false)
    expect(readbackMatches(2048n, 2048n)).toBe(true)
    expect(readbackMatches(2048n, 2049n)).toBe(false)
  })
})
