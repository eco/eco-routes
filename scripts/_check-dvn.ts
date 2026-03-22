import { TronWeb } from 'tronweb'
import { ethers } from 'ethers'
import 'dotenv/config'

const tw = new TronWeb({ fullHost: 'https://api.shasta.trongrid.io', privateKey: process.env.PRIVATE_KEY! })

const DVN_FEE_PAID_TOPIC = ethers.id('DVNFeePaid(address[],address[],uint256[])').slice(2)

async function main() {
  const info: any = await tw.trx.getTransactionInfo('d412d352115ae3aab307c2e7973281fa8bfb3846480517e7a3b51c74ff0422a4')

  for (const log of info.log || []) {
    if (log.topics?.[0] === DVN_FEE_PAID_TOPIC) {
      console.log('Found DVNFeePaid event')
      const iface = new ethers.Interface(['event DVNFeePaid(address[] requiredDVNs, address[] optionalDVNs, uint256[] requiredDVNFees)'])
      const decoded = iface.decodeEventLog('DVNFeePaid', '0x' + log.data, log.topics.map((t: string) => '0x' + t))
      console.log('requiredDVNs:', decoded.requiredDVNs)
      console.log('requiredDVNFees:', decoded.requiredDVNFees.map((f: bigint) => f.toString()))
    }
  }
}

main().catch(e => console.error((e as Error).message))
