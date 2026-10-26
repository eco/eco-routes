/**
 * rent-energy-mainnet.ts
 *
 * Rents Tron mainnet energy to the deployer via JustLend DAO Energy Rental
 * (permissionless, on-chain: proxy TU2MJ5Veik1LRAgjeSzEdvmDYx7mefJZvd).
 * Ported from the Tron Polymer E2E branch for the next-generation Tron prover deploys
 * (deploy-tron-next-gen-prover.ts prints the TARGET_ENERGY to rent).
 * Modes:
 *   --quote            print live pricing, no transaction (default)
 *   --execute          send rentResource (guarded by MAX_PREPAY_TRX)
 *   --return           returnResource for the full order, reclaiming deposit
 * Env: PRIVATE_KEY (not needed for --quote with --address <T…>), TRON_RPC_URL?,
 *      TRON_PRO_API_KEY?, TARGET_ENERGY? (default 10_000_000), RENT_HOURS? (default 2),
 *      MAX_PREPAY_TRX? (default 800)
 *
 * Pricing (docs.justlend.org, verified 2026-07-09):
 *   prepay  = trxAmount * max(rentalRate, stableRate) * (duration + 86400 + liqThreshold) + fee
 *   refund >= trxAmount * rate * (21600 + liqThreshold) + fee
 *   fee     = max(20 TRX, 0.01% of delegated TRX)
 */
import { TronWeb } from 'tronweb'
import { ethers } from 'ethers'

const RENTAL_B58 = 'TU2MJ5Veik1LRAgjeSzEdvmDYx7mefJZvd'
const ENERGY = 1 // resourceType: 0 bandwidth, 1 energy

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

/** Signs with PRIVATE_KEY; a --quote run may instead name the account with --address. */
function tronWeb(quoteOnly: boolean): TronWeb {
  const pk = process.env.PRIVATE_KEY || ''
  const i = process.argv.indexOf('--address')
  const address = i === -1 ? undefined : process.argv[i + 1]
  if (!pk && !(quoteOnly && address)) {
    throw new Error('PRIVATE_KEY required (or --quote --address <T…>)')
  }
  const opts: any = {
    fullHost: process.env.TRON_RPC_URL || 'https://api.trongrid.io',
  }
  if (pk) opts.privateKey = pk.replace(/^0x/, '')
  if (process.env.TRON_PRO_API_KEY) {
    opts.headers = { 'TRON-PRO-API-KEY': process.env.TRON_PRO_API_KEY }
  }
  const tw = new TronWeb(opts)
  if (!pk && address) tw.setAddress(address)
  return tw
}

/** retry on TronGrid anonymous rate limiting (429 suspends the caller for 5s) */
async function withRetry<T>(label: string, fn: () => Promise<T>): Promise<T> {
  for (let i = 0; ; i++) {
    try {
      return await fn()
    } catch (e: any) {
      const is429 =
        e?.response?.status === 429 || /429|rate exceeded/i.test(String(e))
      if (!is429 || i >= 5) throw e
      const wait = 6000 + i * 3000
      console.log(`  ${label}: rate-limited, retrying in ${wait / 1000}s…`)
      await sleep(wait)
    }
  }
}

async function constantCall(
  tw: TronWeb,
  selector: string,
  params: { type: string; value: string }[],
): Promise<string> {
  const r: any = await tw.transactionBuilder.triggerConstantContract(
    RENTAL_B58,
    selector,
    {},
    params,
    tw.defaultAddress.base58 as string,
  )
  if (!r?.result?.result || !r.constant_result?.[0])
    throw new Error(`${selector} failed: ${JSON.stringify(r).slice(0, 300)}`)
  return '0x' + r.constant_result[0]
}

async function quote(tw: TronWeb) {
  const me = tw.defaultAddress.base58 as string
  const targetEnergy = Number(process.env.TARGET_ENERGY || 10_000_000)
  const hours = Number(process.env.RENT_HOURS || 2)

  // chain-wide totals; an unactivated account returns {}, so fall back to a
  // known-active address (the rental contract itself) for the global fields
  let res: any = await withRetry('getAccountResources', () =>
    tw.trx.getAccountResources(me),
  )
  if (!res?.TotalEnergyLimit) {
    res = await withRetry('getAccountResources(rental)', () =>
      tw.trx.getAccountResources(RENTAL_B58),
    )
  }
  const energyPerTrx = res.TotalEnergyLimit / res.TotalEnergyWeight
  const trxAmountSun =
    BigInt(Math.ceil(targetEnergy / energyPerTrx)) * 1_000_000n

  const rateHex = await withRetry('_rentalRate', () =>
    constantCall(tw, '_rentalRate(uint256,uint256)', [
      { type: 'uint256', value: trxAmountSun.toString() },
      { type: 'uint256', value: String(ENERGY) },
    ]),
  )
  const rate = BigInt(rateHex)

  const durationSec = BigInt(Math.round(hours * 3600))
  // fee: max(20 TRX, 0.01% of the delegated TRX amount) — conservative reading
  const fee = (() => {
    const pct = trxAmountSun / 10_000n
    const min = 20_000_000n
    return pct > min ? pct : min
  })()
  // 25% buffer stands in for stableRate>rate and liquidateThreshold drift;
  // excess prepay is deposit and comes back via returnResource.
  const prepay =
    (((trxAmountSun * rate * (durationSec + 86_400n)) / 10n ** 18n) * 125n) /
      100n +
    fee
  const refundMin = (trxAmountSun * rate * 21_600n) / 10n ** 18n + fee

  const balance = BigInt(
    await withRetry('getBalance', () => tw.trx.getBalance(me)),
  )
  console.log(`deployer:           ${me} (${Number(balance) / 1e6} TRX)`)
  console.log(`energy/TRX:         ${energyPerTrx.toFixed(4)}`)
  console.log(`target energy:      ${targetEnergy}`)
  console.log(
    `delegation:         ${Number(trxAmountSun) / 1e6} TRX (sun ${trxAmountSun})`,
  )
  console.log(`rate (1e18/s):      ${rate}`)
  console.log(`prepay (msg.value): ${Number(prepay) / 1e6} TRX`)
  console.log(
    `refund at least:    ${Number(refundMin) / 1e6} TRX  (net worst case ${Number(prepay - refundMin) / 1e6} TRX)`,
  )
  return { trxAmountSun, prepay, balance, me }
}

async function sendAndWait(
  tw: TronWeb,
  selector: string,
  params: { type: string; value: string }[],
  callValueSun: bigint,
) {
  const r: any = await tw.transactionBuilder.triggerSmartContract(
    RENTAL_B58,
    selector,
    { feeLimit: 300_000_000, callValue: Number(callValueSun) },
    params,
    tw.defaultAddress.hex as string,
  )
  if (!r?.result?.result)
    throw new Error(`build failed: ${JSON.stringify(r).slice(0, 300)}`)
  const signed = await tw.trx.sign(r.transaction)
  const b: any = await tw.trx.sendRawTransaction(signed)
  if (!b.result) throw new Error(`broadcast failed: ${JSON.stringify(b)}`)
  console.log(`txid: ${b.txid}`)
  for (let i = 0; i < 30; i++) {
    await sleep(3000)
    const info: any = await tw.trx.getTransactionInfo(b.txid)
    if (info?.id) {
      if (info.receipt?.result && info.receipt.result !== 'SUCCESS')
        throw new Error(`tx failed: ${JSON.stringify(info)}`)
      return b.txid as string
    }
  }
  throw new Error('tx confirmation timed out')
}

async function main() {
  const mode = process.argv.includes('--execute')
    ? 'execute'
    : process.argv.includes('--return')
      ? 'return'
      : 'quote'
  const tw = tronWeb(mode === 'quote')
  const me = tw.defaultAddress.base58 as string

  if (mode === 'return') {
    const infoHex = await constantCall(
      tw,
      'getRentInfo(address,address,uint256)',
      [
        { type: 'address', value: me },
        { type: 'address', value: me },
        { type: 'uint256', value: String(ENERGY) },
      ],
    )
    const [deposit] = ethers.AbiCoder.defaultAbiCoder().decode(
      ['uint256', 'uint256'],
      infoHex,
    )
    console.log(`current deposit: ${Number(deposit) / 1e6} TRX`)
    const rentalsHex = await constantCall(
      tw,
      'rentals(address,address,uint256)',
      [
        { type: 'address', value: me },
        { type: 'address', value: me },
        { type: 'uint256', value: String(ENERGY) },
      ],
    )
    // struct RentalInfo { uint256 amount; uint256 securityDeposit; uint256 rentIndex; }
    const amount = BigInt('0x' + rentalsHex.slice(2, 66))
    console.log(`returning delegation: ${Number(amount) / 1e6} TRX`)
    if (amount === 0n) throw new Error('no active rental order found')
    await sendAndWait(
      tw,
      'returnResource(address,uint256,uint256)',
      [
        { type: 'address', value: me },
        { type: 'uint256', value: amount.toString() },
        { type: 'uint256', value: String(ENERGY) },
      ],
      0n,
    )
    console.log('returned — deposit refund lands in the wallet balance')
    return
  }

  const q = await quote(tw)
  if (mode === 'quote') return

  const maxPrepay =
    BigInt(Number(process.env.MAX_PREPAY_TRX || 800)) * 1_000_000n
  if (q.prepay > maxPrepay)
    throw new Error(
      `prepay ${Number(q.prepay) / 1e6} TRX exceeds MAX_PREPAY_TRX — raise the cap explicitly or lower TARGET_ENERGY`,
    )
  if (q.balance < q.prepay + 50_000_000n)
    throw new Error('insufficient TRX for prepay + bandwidth margin')

  await sendAndWait(
    tw,
    'rentResource(address,uint256,uint256)',
    [
      { type: 'address', value: q.me },
      { type: 'uint256', value: q.trxAmountSun.toString() },
      { type: 'uint256', value: String(ENERGY) },
    ],
    q.prepay,
  )

  const res: any = await tw.trx.getAccountResources(q.me)
  const avail = (res.EnergyLimit || 0) - (res.EnergyUsed || 0)
  console.log(`energy available now: ${avail}`)
  if (avail < Number(process.env.TARGET_ENERGY || 10_000_000))
    throw new Error(
      'energy below target after rent — inspect the order on tronscan',
    )
}

main().catch((e) => {
  console.error(e instanceof Error ? e.message : e)
  process.exitCode = 1
})
