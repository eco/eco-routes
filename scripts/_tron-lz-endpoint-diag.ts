/**
 * _tron-lz-endpoint-diag.ts
 * Queries the Tron Shasta LZ endpoint to check send library config for Base Sepolia EID.
 */

import { TronWeb } from 'tronweb'
import { ethers } from 'ethers'
import 'dotenv/config'

const TRON_LZ_ENDPOINT_HEX20 = '0x1b356f3030ce0c1ef9d3e1e250bf0bb11d81b2d1'
const TRON_LZ_PROVER_HEX20   = '0x732e4c4a3d81627e0d343889af186cfc96b76c0b'
const BASE_SEPOLIA_EID = 40245

const ENDPOINT_ABI = [
  'function getDefaultSendLibrary(uint32 eid) view returns (address)',
  'function getSendLibrary(address sender, uint32 eid) view returns (address lib)',
  'function isDefaultSendLibrary(address sender, uint32 eid) view returns (bool)',
  'function getConfig(address oapp, address lib, uint32 eid, uint32 configType) view returns (bytes)',
  'function defaultReceiveLibrary(uint32 eid) view returns (address)',
]

async function main() {
  const pk = process.env.PRIVATE_KEY!
  const tw = new TronWeb({ fullHost: 'https://api.shasta.trongrid.io', privateKey: pk })

  const endpointBase58 = tw.address.fromHex('41' + TRON_LZ_ENDPOINT_HEX20.slice(2)) as string
  console.log('Tron LZ Endpoint base58:', endpointBase58)

  const iface = new ethers.Interface(ENDPOINT_ABI)
  const abiCoder = ethers.AbiCoder.defaultAbiCoder()

  async function viewCall(sig: string, args: any[]): Promise<any> {
    const calldata = iface.encodeFunctionData(sig.split('(')[0], args)
    const r: any = await tw.transactionBuilder.triggerConstantContract(
      endpointBase58,
      sig,
      { rawParameter: calldata.slice(10) },
      [],
      tw.defaultAddress.hex as string,
    )
    const raw: string = r?.constant_result?.[0]
    if (!raw) return null
    try {
      return iface.decodeFunctionResult(sig.split('(')[0], '0x' + raw)
    } catch {
      return '0x' + raw
    }
  }

  const defaultLib = await viewCall('getDefaultSendLibrary(uint32)', [BASE_SEPOLIA_EID])
  console.log('defaultSendLib for EID 40245:', defaultLib?.[0] ?? defaultLib)

  const sendLib = await viewCall('getSendLibrary(address,uint32)', [TRON_LZ_PROVER_HEX20, BASE_SEPOLIA_EID])
  console.log('sendLib (prover → EID 40245):', sendLib?.[0] ?? sendLib)

  const isDefault = await viewCall('isDefaultSendLibrary(address,uint32)', [TRON_LZ_PROVER_HEX20, BASE_SEPOLIA_EID])
  console.log('isDefaultSendLibrary:', isDefault?.[0] ?? isDefault)

  // CONFIG_TYPE_ULN = 2
  const lib = sendLib?.[0] ?? defaultLib?.[0]
  if (lib && lib !== '0x0000000000000000000000000000000000000000') {
    const libBase58 = tw.address.fromHex('41' + (lib as string).slice(2)) as string
    console.log('Send library base58:', libBase58)

    // ULN config type = 2
    const uln = await viewCall('getConfig(address,address,uint32,uint32)', [TRON_LZ_PROVER_HEX20, lib, BASE_SEPOLIA_EID, 2])
    console.log('ULN config (raw):', uln?.[0] ?? uln)

    // Executor config type = 1
    const exec = await viewCall('getConfig(address,address,uint32,uint32)', [TRON_LZ_PROVER_HEX20, lib, BASE_SEPOLIA_EID, 1])
    console.log('Executor config (raw):', exec?.[0] ?? exec)
  }
}

main().catch(e => console.error((e as Error).message))
