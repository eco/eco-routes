import { TronWeb } from 'tronweb'
import type {
  ContractInstance,
  ContractAbiInterface,
} from 'tronweb/lib/esm/types/ABI'
import fs from 'fs'

const PRIVATE_KEY = process.env.PRIVATE_KEY
const URL = process.env.URL

const PORTAL = JSON.parse(
  fs.readFileSync('./artifacts/contracts/Portal.sol/Portal.json', 'utf8'),
)

const tronWeb = new TronWeb({
  fullHost: URL,
  privateKey: PRIVATE_KEY,
})

function deployPortal(): Promise<void> {
  console.log('deploying Portal')

  return tronWeb
    .contract()
    .new({
      abi: PORTAL.abi,
      bytecode: PORTAL.bytecode,
      feeLimit: 1000000000, // 1000 TRX
      callValue: 0,
      userFeePercentage: 100,
    })
    .then((contract: ContractInstance<ContractAbiInterface>) => {
      console.log(
        `deployed Portal at: ${tronWeb.address.fromHex(contract.address as string)}`,
      )
    })
}

deployPortal().catch(console.error)
