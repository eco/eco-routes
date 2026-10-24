/**
 * Reference CCTP relay for EVM destinations (spec §5). Not production.
 *
 * It polls Iris for the attestation of every CCTP message in a source tx,
 * simulates receiveMessage on the destination chain, and prints the ecocast
 * command to submit it with the eco-ops foundry keystore. It never signs and
 * never reads a key.
 *
 *   npx tsx scripts/cctp/relay.ts --env testnet --source-domain 3 \
 *     --tx-hash 0x… --dest-rpc $BASE_SEPOLIA_RPC [--from 0x256B…1471]
 *
 * The printed ecocast command expects DEST_RPC exported in the shell, e.g.
 *   export DEST_RPC=<same url as --dest-rpc>
 */
import { createPublicClient, http, type Hex } from 'viem'
import {
  IRIS,
  TRANSMITTER,
  decodeHeader,
  fetchAttestations,
  receiveMessageCalldata,
} from './lib'

function arg(name: string, fallback?: string): string {
  const i = process.argv.indexOf(`--${name}`)
  if (i !== -1 && process.argv[i + 1]) return process.argv[i + 1]
  if (fallback !== undefined) return fallback
  throw new Error(`missing --${name}`)
}

async function main() {
  const env = arg('env', 'testnet') as keyof typeof IRIS
  if (!(env in IRIS)) throw new Error(`--env must be mainnet or testnet`)
  const sourceDomain = Number(arg('source-domain'))
  const txHash = arg('tx-hash')
  const destRpc = arg('dest-rpc')
  const from = arg('from', '0x256B70644f5D77bc8e2bb82C731Ddf747ecb1471') as Hex
  const transmitter = arg('transmitter', TRANSMITTER[env]) as Hex

  const client = createPublicClient({ transport: http(destRpc) })
  const messages = await fetchAttestations({
    irisBase: IRIS[env],
    sourceDomain,
    txHash,
  })

  for (const [i, { message, attestation }] of messages.entries()) {
    const h = decodeHeader(message)
    console.log(
      `#${i} ${h.sourceDomain} → ${h.destinationDomain} nonce ${h.nonce} finality ${h.finalityThresholdExecuted} ` +
        `recipient ${h.recipient} body ${(message.length - 2) / 2 - 148} bytes`,
    )
    const data = receiveMessageCalldata(message, attestation)
    try {
      await client.call({ to: transmitter, data, account: from })
      console.log(`  simulation OK`)
    } catch (e) {
      console.log(`  simulation FAILED: ${(e as Error).message.split('\n')[0]}`)
      continue
    }
    console.log(`  ecocast send ${transmitter} ${data} --rpc-url "$DEST_RPC"`)
  }
}

main().catch((e) => {
  console.error((e as Error).message)
  process.exitCode = 1
})
