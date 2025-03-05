import { ethers } from 'hardhat'
import hre from 'hardhat'

async function main() {
  const crossL2Prover = '0xcDa03d74DEc5B24071D1799899B2e0653C24e5Fa'
  const supportedChainIds = [10, 84532, 8453, 11155420]

  const inboxAddress = process.env.INBOX_ADDRESS
  if (!inboxAddress) {
    throw new Error(
      'no INBOX_ADDRESS env var found, set it before running the script',
    )
  }

  const [deployer] = await ethers.getSigners()
  const nonce = await deployer.getNonce()
  console.log('deploying polymer prover with nonce:', nonce)
  const proverFactory = await ethers.getContractFactory('PolymerProver')
  const polymerProver = await proverFactory.deploy(
    crossL2Prover,
    inboxAddress,
    supportedChainIds,
  )
  await polymerProver.waitForDeployment()
  const proverAddr = await polymerProver.getAddress()
  console.log('polymer prover deployed at:', proverAddr)

  await new Promise(resolve => setTimeout(resolve, 5000));

  await hre.run('verify:verify', {
    address: proverAddr,
    constructorArguments: [crossL2Prover, inboxAddress, supportedChainIds],
  })
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
