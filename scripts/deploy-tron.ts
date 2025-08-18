import { TronWeb } from 'tronweb'
import type {
  ContractInstance,
  ContractAbiInterface,
} from 'tronweb/lib/esm/types/ABI'
import fs from 'fs'

const PRIVATE_KEY = process.env.PRIVATE_KEY
const URL = process.env.URL

const INTENT_SOURCE = JSON.parse(
  fs.readFileSync(
    './artifacts/contracts/IntentSource.sol/IntentSource.json',
    'utf8',
  ),
)
const INBOX = JSON.parse(
  fs.readFileSync('./artifacts/contracts/Inbox.sol/Inbox.json', 'utf8'),
)

const tronWeb = new TronWeb({
  fullHost: URL,
  privateKey: PRIVATE_KEY,
})

async function deployIntentSource(): Promise<void> {
  console.log('deploying IntentSource')

  return tronWeb
    .contract()
    .new({
      abi: INTENT_SOURCE.abi,
      bytecode: INTENT_SOURCE.bytecode,
      feeLimit: 1000000000, // 1000 TRX
      callValue: 0,
      userFeePercentage: 100,
    })
    .then((contract: ContractInstance<ContractAbiInterface>) => {
      console.log(
        `deployed IntentSource at: ${tronWeb.address.fromHex(contract.address as string)}`,
      )
    })
}

async function deployInbox(): Promise<void> {
  console.log('deploying Inbox')

  return tronWeb
    .contract()
    .new({
      abi: INBOX.abi,
      bytecode: INBOX.bytecode,
      feeLimit: 1000000000, // 1000 TRX
      callValue: 0,
      userFeePercentage: 100,
    })
    .then((contract: ContractInstance<ContractAbiInterface>) => {
      console.log(
        `deployed Inbox at: ${tronWeb.address.fromHex(contract.address as string)}`,
      )
    })
}

deployIntentSource().then(deployInbox).catch(console.error)
