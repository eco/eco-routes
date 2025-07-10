import { Contract, ContractFactory, Signer } from 'ethers'

/**
 * Deploy a contract with the given factory from a certain address
 * Will be deployed by the given deployer address with the given params
 */
export async function deploy<F extends ContractFactory>(
  from: Signer,
  FactoryType: { new (from: Signer): F },
  params: any[] = [],
): Promise<Contract> {
  const factory = new FactoryType(from)
  const contract = await factory.deploy(...params)
  await contract.waitForDeployment()

  return contract
}
