import { TronWeb } from 'tronweb'
import { ethers } from 'ethers'
import 'dotenv/config'

const tw = new TronWeb({
  fullHost: 'https://api.shasta.trongrid.io',
  privateKey: process.env.PRIVATE_KEY!,
})
const contract = 'TLUEAxif7xHqwAZwP9PCG221RgvvfzgkPA'

async function call(sig: string, retType: string): Promise<any> {
  const iface = new ethers.Interface([`function ${sig} view returns (${retType})`])
  const fnName = sig.split('(')[0]
  const r: any = await tw.transactionBuilder.triggerConstantContract(
    contract, sig, {}, [], tw.defaultAddress.hex as string,
  )
  const raw: string | undefined = r?.constant_result?.[0]
  if (!raw) { console.log(fnName + ': no result'); return }
  const decoded = iface.decodeFunctionResult(fnName, '0x' + raw)
  return decoded[0]
}

async function main() {
  const portal = await call('PORTAL()', 'address')
  console.log('PORTAL():', portal)

  const minGas = await call('MIN_GAS_LIMIT()', 'uint256')
  console.log('MIN_GAS_LIMIT():', minGas?.toString())

  const proofType = await call('getProofType()', 'string')
  console.log('getProofType():', proofType)

  // getWhitelist returns bytes32[]
  const ifaceWl = new ethers.Interface(['function getWhitelist() view returns (bytes32[])'])
  const r: any = await tw.transactionBuilder.triggerConstantContract(
    contract, 'getWhitelist()', {}, [], tw.defaultAddress.hex as string,
  )
  const raw: string = r?.constant_result?.[0]
  if (raw) {
    const dec = ifaceWl.decodeFunctionResult('getWhitelist', '0x' + raw)
    console.log('getWhitelist():', dec[0])
  }

  // Check if the intent we just proved is in provenIntents
  const intentHash = '0xf086ffeef54297f11bc06632f7e6a72e5545bf7a32196e6f37302a3d00710e0a'
  const ifacePi = new ethers.Interface([
    'function provenIntents(bytes32) view returns (tuple(address claimant, bytes32 sourceChainProver))',
  ])
  const rPi: any = await tw.transactionBuilder.triggerConstantContract(
    contract,
    'provenIntents(bytes32)',
    {},
    [{ type: 'bytes32', value: intentHash }],
    tw.defaultAddress.hex as string,
  )
  const rawPi: string = rPi?.constant_result?.[0]
  if (rawPi) {
    const dec = ifacePi.decodeFunctionResult('provenIntents', '0x' + rawPi)
    console.log('provenIntents(intentHash):', dec[0])
  }

  // Also check Tron Portal claimants mapping
  const tronPortal = 'TLp4t7Lv41iLXEqTuB4fkq7WKqUVxZxRo9'
  const ifaceCl = new ethers.Interface(['function claimants(bytes32) view returns (bytes32)'])
  const rCl: any = await tw.transactionBuilder.triggerConstantContract(
    tronPortal,
    'claimants(bytes32)',
    {},
    [{ type: 'bytes32', value: intentHash }],
    tw.defaultAddress.hex as string,
  )
  const rawCl: string = rCl?.constant_result?.[0]
  if (rawCl) {
    const dec = ifaceCl.decodeFunctionResult('claimants', '0x' + rawCl)
    console.log('Portal.claimants(intentHash):', dec[0])
  }
}

main().catch((e) => console.error((e as Error).message))
