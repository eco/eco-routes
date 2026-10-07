import { ethers } from 'ethers'
import * as fs from 'fs'
import * as path from 'path'
import {
  buildTronLayerZeroProverInitCode,
  predictTronCreate2Address,
  tronDomainConfig,
} from '../layerzero-tron-prover'

const addr = (n: number) => '0x' + n.toString(16).padStart(40, '0')
const chain = (eid: number, extra: Record<string, unknown> = {}) => ({
  name: `chain-${eid}`,
  eid,
  confirmations: 10,
  endpointV2: addr(eid * 10 + 1),
  sendUln302: addr(eid * 10 + 2),
  receiveUln302: addr(eid * 10 + 3),
  executor: addr(eid * 10 + 4),
  dvns: {
    canary: addr(eid * 10 + 5),
    lzLabs: addr(eid * 10 + 6),
    horizen: addr(eid * 10 + 7),
  },
  ...extra,
})

const POLICY = {
  policy: {
    requiredDVNs: ['canary', 'lzLabs', 'horizen'],
    maxMessageSize: 10000,
  },
  crossVmProvers: [],
  chains: {
    '8453': chain(30184),
    '1': chain(30101, { confirmations: 32 }),
    '43114': chain(30106, { confirmations: 20, planned: true }),
    // DVNs deliberately not in address order: the constructor needs them ascending.
    '728126428': chain(30420, {
      vm: 'tron',
      confirmations: 19,
      dvns: { canary: addr(0x300), lzLabs: addr(0x100), horizen: addr(0x200) },
    }),
  },
}

const EVM_PROVER = '0xEc00FE5F9625328757A0648934EAbe9A5685a541'
const PORTAL = '0xbbe65c636a745ccb12fb0a8376f5ed089a86983a'
const BYTECODE = '0x6080604052'

const CTOR = [
  'address',
  'address',
  'bytes32[]',
  'uint256',
  'tuple(uint64 domain, uint64 chainId)[]',
  'tuple(address sendLibrary, address receiveLibrary, address executor, uint32 maxMessageSize, address[] requiredDVNs, uint64 sendConfirmations, uint64[] receiveConfirmations)',
]

const TRON = POLICY.chains['728126428']
const EXPECTED_DOMAINS = [
  { domain: 30101n, chainId: 1n },
  { domain: 30184n, chainId: 8453n },
  { domain: 30106n, chainId: 43114n },
]
const EXPECTED_LZ_CONFIG = {
  sendLibrary: TRON.sendUln302,
  receiveLibrary: TRON.receiveUln302,
  executor: TRON.executor,
  maxMessageSize: 10000n,
  requiredDVNs: [addr(0x100), addr(0x200), addr(0x300)],
  sendConfirmations: 19n,
  // Each origin's own confirmations, in domain order.
  receiveConfirmations: [32n, 10n, 20n],
}

describe('tronDomainConfig', () => {
  it('maps every EVM chain of the policy, planned ones included, eid -> chainId, ordered by chain id, never Tron', () => {
    expect(tronDomainConfig(POLICY)).toEqual(EXPECTED_DOMAINS)
  })

  it('refuses a policy without a Tron chain', () => {
    const { ['728126428']: _tron, ...evmOnly } = POLICY.chains
    expect(() => tronDomainConfig({ ...POLICY, chains: evmOnly })).toThrow(
      /Tron/,
    )
  })
})

describe('buildTronLayerZeroProverInitCode', () => {
  const build = () =>
    buildTronLayerZeroProverInitCode(BYTECODE, POLICY, {
      evmProver: EVM_PROVER,
      portal: PORTAL,
    })

  it('appends the constructor args: endpoint, portal, [evm prover], 200k, domains, pinned LZ config', () => {
    const { initCode } = build()
    expect(initCode.startsWith(BYTECODE)).toBe(true)
    const [endpoint, portal, provers, minGas, domains, lzConfig] =
      ethers.AbiCoder.defaultAbiCoder().decode(
        CTOR,
        '0x' + initCode.slice(BYTECODE.length),
      )
    expect(endpoint.toLowerCase()).toBe(TRON.endpointV2)
    expect(portal.toLowerCase()).toBe(PORTAL)
    expect(provers).toEqual([ethers.zeroPadValue(EVM_PROVER.toLowerCase(), 32)])
    expect(minGas).toBe(200000n)
    expect(
      domains.map((d: { domain: bigint; chainId: bigint }) => ({
        domain: d.domain,
        chainId: d.chainId,
      })),
    ).toEqual(EXPECTED_DOMAINS)
    expect({
      sendLibrary: lzConfig.sendLibrary.toLowerCase(),
      receiveLibrary: lzConfig.receiveLibrary.toLowerCase(),
      executor: lzConfig.executor.toLowerCase(),
      maxMessageSize: lzConfig.maxMessageSize,
      requiredDVNs: lzConfig.requiredDVNs.map((d: string) => d.toLowerCase()),
      sendConfirmations: lzConfig.sendConfirmations,
      receiveConfirmations: [...lzConfig.receiveConfirmations],
    }).toEqual(EXPECTED_LZ_CONFIG)
  })

  it('refuses a policy whose Tron chain lacks a required DVN', () => {
    const tron = { ...TRON, dvns: { canary: addr(0x300), lzLabs: addr(0x100) } }
    const policy = {
      ...POLICY,
      chains: { ...POLICY.chains, '728126428': tron },
    }
    expect(() =>
      buildTronLayerZeroProverInitCode(BYTECODE, policy, {
        evmProver: EVM_PROVER,
        portal: PORTAL,
      }),
    ).toThrow(/horizen/)
  })

  it("matches the compiled LayerZeroProver's own constructor encoding", () => {
    const artifact = path.join(
      __dirname,
      '../../../out/LayerZeroProver.sol/LayerZeroProver.json',
    )
    if (!fs.existsSync(artifact)) return // needs `forge build`
    const { abi } = JSON.parse(fs.readFileSync(artifact, 'utf8'))
    const { initCode } = build()
    const expected = new ethers.Interface(abi).encodeDeploy([
      TRON.endpointV2,
      PORTAL,
      [ethers.zeroPadValue(EVM_PROVER.toLowerCase(), 32)],
      200000n,
      EXPECTED_DOMAINS,
      EXPECTED_LZ_CONFIG,
    ])
    expect('0x' + initCode.slice(BYTECODE.length)).toBe(expected)
  })

  it.each(['evmProver', 'portal'])(
    'refuses a zero or malformed %s',
    (field) => {
      const args = {
        evmProver: EVM_PROVER,
        portal: PORTAL,
        [field]: addr(0),
      }
      expect(() =>
        buildTronLayerZeroProverInitCode(BYTECODE, POLICY, args),
      ).toThrow(field)
      const bad = {
        evmProver: EVM_PROVER,
        portal: PORTAL,
        [field]: '0x12',
      }
      expect(() =>
        buildTronLayerZeroProverInitCode(BYTECODE, POLICY, bad),
      ).toThrow(field)
    },
  )
})

describe('predictTronCreate2Address', () => {
  it("uses Tron's 0x41 CREATE2 prefix", () => {
    const factory = addr(0xfac)
    const salt = ethers.zeroPadValue('0x01', 32)
    const hash = ethers.keccak256(BYTECODE)
    const expected =
      '0x' +
      ethers.keccak256(ethers.concat(['0x41', factory, salt, hash])).slice(-40)
    expect(predictTronCreate2Address(factory, salt, BYTECODE)).toBe(expected)
  })
})
