import {
  concatHex,
  keccak256,
  pad,
  toHex,
  toFunctionSelector,
  type Hex,
} from 'viem'
import { decodeHeader, fetchAttestations, receiveMessageCalldata } from '../lib'

const sender = pad('0x1234567890123456789012345678901234567890', { size: 32 })
const recipient = pad('0x00000000000000000000000000000000000c0ffe', {
  size: 32,
})
const body = concatHex([toHex(42161n, { size: 8 }), keccak256('0x01'), sender])
const message: Hex = concatHex([
  toHex(1, { size: 4 }),
  toHex(3, { size: 4 }),
  toHex(6, { size: 4 }),
  keccak256('0x02'),
  sender,
  recipient,
  pad('0x', { size: 32 }),
  toHex(1000, { size: 4 }),
  toHex(1000, { size: 4 }),
  body,
])

describe('decodeHeader', () => {
  it('reads every CCTP V2 header field at the documented offsets', () => {
    const h = decodeHeader(message)
    expect(h.version).toBe(1)
    expect(h.sourceDomain).toBe(3)
    expect(h.destinationDomain).toBe(6)
    expect(h.sender).toBe(sender)
    expect(h.recipient).toBe(recipient)
    expect(h.minFinalityThreshold).toBe(1000)
    expect(h.finalityThresholdExecuted).toBe(1000)
    expect(h.body).toBe(body)
  })

  it('rejects a message shorter than the 148-byte header', () => {
    expect(() => decodeHeader('0x00')).toThrow(
      'shorter than the 148-byte CCTP header',
    )
  })
})

describe('receiveMessageCalldata', () => {
  it('encodes receiveMessage(bytes,bytes)', () => {
    const data = receiveMessageCalldata(message, '0xaa')
    expect(data.slice(0, 10)).toBe(
      toFunctionSelector('receiveMessage(bytes,bytes)'),
    )
  })
})

describe('fetchAttestations', () => {
  it('polls until Iris reports complete', async () => {
    const responses = [
      { status: 404, body: {} },
      {
        status: 200,
        body: {
          messages: [
            {
              status: 'pending_confirmations',
              message: '0x',
              attestation: 'PENDING',
            },
          ],
        },
      },
      {
        status: 200,
        body: {
          messages: [{ status: 'complete', message, attestation: '0xbeef' }],
        },
      },
    ]
    const urls: string[] = []
    const fetchImpl = (async (url: string) => {
      urls.push(url)
      const r = responses.shift()!
      return {
        status: r.status,
        ok: r.status === 200,
        json: async () => r.body,
      } as Response
    }) as unknown as typeof fetch

    const out = await fetchAttestations({
      irisBase: 'https://iris.test',
      sourceDomain: 3,
      txHash: '0xabc',
      fetchImpl,
      sleep: async () => {},
    })
    expect(out).toEqual([{ message, attestation: '0xbeef' }])
    expect(urls[0]).toBe(
      'https://iris.test/v2/messages/3?transactionHash=0xabc',
    )
  })

  it('times out with a clear error', async () => {
    let now = 0
    const fetchImpl = (async () =>
      ({
        status: 404,
        ok: false,
        json: async () => ({}),
      }) as Response) as unknown as typeof fetch
    await expect(
      fetchAttestations({
        irisBase: 'https://iris.test',
        sourceDomain: 3,
        txHash: '0xabc',
        timeoutMs: 10,
        pollMs: 5,
        fetchImpl,
        sleep: async (ms) => {
          now += ms
        },
        now: () => now,
      }),
    ).rejects.toThrow('Iris did not attest 0xabc on domain 3 within 10 ms')
  })
})
