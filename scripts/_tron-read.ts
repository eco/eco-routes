import { TronWeb } from 'tronweb'
import { ethers } from 'ethers'

const tw = new TronWeb({ fullHost: 'https://api.shasta.trongrid.io', privateKey: process.env.PRIVATE_KEY! })
const portal = 'TE7yYVXoBhz12b2Hp7qD11tKasaHGP6iSg'

async function call(sig: string, retType: string) {
  const iface = new ethers.Interface([`function ${sig} view returns (${retType})`])
  const fnName = sig.split('(')[0]
  const r = await tw.transactionBuilder.triggerConstantContract(
    portal, sig, {}, [], tw.defaultAddress.hex as string
  )
  const raw = (r as any).constant_result?.[0]
  if (!raw) { console.log(fnName + ': no result'); return }
  const decoded = iface.decodeFunctionResult(fnName, '0x' + raw)
  console.log(fnName + ':', decoded[0].toString())
}

async function main() {
  await call('CHAIN_ID()', 'uint64')
  await call('CREATE2_PREFIX()', 'bytes1')
  await call('VAULT_IMPLEMENTATION()', 'address')
}
main().catch(e => console.error((e as Error).message))
