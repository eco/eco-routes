import { keccak256, encodePacked, Hex, hexToBytes, bytesToHex } from 'viem'

/**
 * Generates a contract salt that matches the Solidity getContractSalt function
 * @param rootSalt The root salt value
 * @param contractName The contract name string
 * @param preserveCreateXPermissions Whether to preserve CreateX permissions (default: false)
 * @returns The generated contract salt
 */
export function getContractSalt(rootSalt: Hex, contractName: string): Hex {
  // Hash the contract name (matches Solidity: keccak256(abi.encodePacked(contractName)))
  const contractHash = keccak256(encodePacked(['string'], [contractName]))
  // Matches Solidity: keccak256(abi.encode(rootSalt, contractHash))
  return keccak256(
    encodePacked(['bytes32', 'bytes32'], [rootSalt, contractHash]),
  )
}

/**
 * Generates a HyperProver salt that matches the Solidity implementation
 * This function specifically generates the salt for HyperProver contracts
 * @param rootSalt The root salt value
 * @param preserveCreateXPermissions Whether to preserve CreateX permissions
 * @returns The generated HyperProver salt
 */
export function getHyperProverSalt(rootSalt: Hex): Hex {
  return getContractSalt(rootSalt, 'HYPER_PROVER')
}
