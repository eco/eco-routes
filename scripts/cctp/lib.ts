import { encodeFunctionData, hexToNumber, sliceHex, size, type Hex } from 'viem'

export const IRIS = {
  mainnet: 'https://iris-api.circle.com',
  testnet: 'https://iris-api-sandbox.circle.com',
} as const

export const TRANSMITTER = {
  mainnet: '0x81D40F21F12A8F0E3252Bccb954D722d4c464B64',
  testnet: '0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275',
} as const

export type CctpHeader = {
  version: number
  sourceDomain: number
  destinationDomain: number
  nonce: Hex
  sender: Hex
  recipient: Hex
  destinationCaller: Hex
  minFinalityThreshold: number
  finalityThresholdExecuted: number
  body: Hex
}

const HEADER_BYTES = 148

/** CCTP V2 header offsets (circlefin MessageV2): see spec §5. */
export function decodeHeader(message: Hex): CctpHeader {
  if (size(message) < HEADER_BYTES) {
    throw new Error(
      `message is ${size(message)} bytes, shorter than the 148-byte CCTP header`,
    )
  }
  const u32 = (start: number) =>
    hexToNumber(sliceHex(message, start, start + 4))
  const b32 = (start: number) => sliceHex(message, start, start + 32)
  return {
    version: u32(0),
    sourceDomain: u32(4),
    destinationDomain: u32(8),
    nonce: b32(12),
    sender: b32(44),
    recipient: b32(76),
    destinationCaller: b32(108),
    minFinalityThreshold: u32(140),
    finalityThresholdExecuted: u32(144),
    body:
      size(message) === HEADER_BYTES ? '0x' : sliceHex(message, HEADER_BYTES),
  }
}

const RECEIVE_ABI = [
  {
    type: 'function',
    name: 'receiveMessage',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'message', type: 'bytes' },
      { name: 'attestation', type: 'bytes' },
    ],
    outputs: [{ name: 'success', type: 'bool' }],
  },
] as const

export function receiveMessageCalldata(message: Hex, attestation: Hex): Hex {
  return encodeFunctionData({
    abi: RECEIVE_ABI,
    functionName: 'receiveMessage',
    args: [message, attestation],
  })
}

type IrisMessage = {
  status: string
  message: Hex
  attestation: Hex | 'PENDING'
}

export async function fetchAttestations(opts: {
  irisBase: string
  sourceDomain: number
  txHash: string
  pollMs?: number
  timeoutMs?: number
  fetchImpl?: typeof fetch
  sleep?: (ms: number) => Promise<void>
  now?: () => number
}): Promise<{ message: Hex; attestation: Hex }[]> {
  const pollMs = opts.pollMs ?? 2_000
  const timeoutMs = opts.timeoutMs ?? 30 * 60_000
  const doFetch = opts.fetchImpl ?? fetch
  const sleep =
    opts.sleep ??
    ((ms: number) => new Promise((resolve) => setTimeout(resolve, ms)))
  const now = opts.now ?? Date.now
  const url = `${opts.irisBase}/v2/messages/${opts.sourceDomain}?transactionHash=${opts.txHash}`
  const deadline = now() + timeoutMs

  while (now() <= deadline) {
    const res = await doFetch(url)
    if (res.ok) {
      const json = (await res.json()) as { messages?: IrisMessage[] }
      const messages = json.messages ?? []
      if (
        messages.length > 0 &&
        messages.every(
          (m) => m.status === 'complete' && m.attestation !== 'PENDING',
        )
      ) {
        return messages.map((m) => ({
          message: m.message,
          attestation: m.attestation as Hex,
        }))
      }
    } else if (res.status !== 404) {
      throw new Error(`Iris returned HTTP ${res.status} for ${url}`)
    }
    await sleep(pollMs)
  }
  throw new Error(
    `Iris did not attest ${opts.txHash} on domain ${opts.sourceDomain} within ${timeoutMs} ms`,
  )
}
