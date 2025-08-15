import { TronWeb } from 'tronweb'
import fs from 'fs'

const PRIVATE_KEY = process.env.PRIVATE_KEY
const URL = process.env.URL || 'http://127.0.0.1:8090'
const tronWeb = new TronWeb({
  fullHost: URL,
  privateKey: PRIVATE_KEY,
})
const OWNER = process.env.INBOX_OWNER || tronWeb.defaultAddress.hex
const IS_SOLVING_PUBLIC = process.env.INBOX_IS_SOLVING_PUBLIC === 'true'
const SOLVERS = process.env.INBOX_SOLVERS
  ? process.env.INBOX_SOLVERS.split(',')
  : []

const INTENT_SOURCE = JSON.parse(
  fs.readFileSync(
    './artifacts/contracts/IntentSource.sol/IntentSource.json',
    'utf8',
  ),
)
const INBOX = JSON.parse(
  fs.readFileSync('./artifacts/contracts/Inbox.sol/Inbox.json', 'utf8'),
)

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
    .then((contract) => {
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
      parameters: [OWNER, IS_SOLVING_PUBLIC, SOLVERS],
    })
    .then((contract) => {
      console.log(
        `deployed Inbox at: ${tronWeb.address.fromHex(contract.address as string)}`,
      )
    })
}

deployIntentSource().then(deployInbox).catch(console.error)
