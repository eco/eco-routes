# Plan: Refactor Deploy.s.sol and Implement Chain-Based Address Prediction

## Objective

1. Split Deploy.s.sol into modular components with separate address prediction utilities
2. Implement a method to fetch all chains from CHAIN_DATA_URL and predict unique Polymer Prover addresses
3. Use these predicted addresses as constructor arguments for Tron Polymer Prover deployment

## Implementation Steps

### 1. Create AddressPrediction.sol Library

**File**: `scripts/AddressPrediction.sol`

- Extract all address prediction methods from Deploy.s.sol
- Make them pure/view functions that don't require Script context
- Include:
  - `getContractSalt()`
  - `predictCreate2Address()` with both overloads
  - `predictCreate3Address()` for both Create3Deployer and CreateX
  - `useCreateXForChainID()`
  - Chain ID constants (TRON, World Chain, Plasma)

### 2. Create PredictAddresses.s.sol Script

**File**: `scripts/PredictAddresses.s.sol`

- Standalone script focused on address prediction
- Import AddressPrediction library
- Implement `predictPolymerProverForChain(uint256 chainId, bytes32 salt, address deployer)`
- Implement `getAllUniquePolymerAddresses()` that:
  - Fetches chain data from CHAIN_DATA_URL
  - Iterates through all chains
  - Predicts Polymer Prover address for each chain
  - Returns array of unique addresses (deduplicates)

### 3. Refactor Deploy.s.sol

- Import AddressPrediction library
- Replace inline prediction functions with library calls
- Maintain backward compatibility
- Keep deployment logic unchanged

### 4. Create TypeScript Chain Data Fetcher

**File**: `scripts/utils/fetchChainData.ts`

- Fetch and parse chain data from CHAIN_DATA_URL
- Return structured chain information including:
  - Chain IDs
  - RPC URLs
  - Whether Polymer Prover should be deployed

### 5. Update sr-deploy-tron.ts

- Replace hardcoded target chains with dynamic chain fetching
- Use new PredictAddresses.s.sol script to get predictions
- Parse forge script output properly to extract addresses
- Pass unique predicted addresses to Tron deployment

## Detailed File Changes

### scripts/AddressPrediction.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library AddressPrediction {
  // Chain constants
  uint256 constant TRON_MAINNET_CHAIN_ID = 728126428;
  uint256 constant TRON_SHASTA_CHAIN_ID = 2494104990;
  uint256 constant TRON_NILE_CHAIN_ID = 3448148188;
  uint256 constant WORLD_CHAIN_ID = 480;
  uint256 constant PLASMA_CHAIN_ID = 9745;

  // Factory addresses
  address constant CREATE2_FACTORY = 0xce0042B868300000d44A59004Da54A005ffdcf9f;
  address constant CREATE3_DEPLOYER =
    0xC6BAd1EbAF366288dA6FB5689119eDd695a66814;
  address constant CREATEX_CONTRACT =
    0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

  function getContractSalt(
    bytes32 rootSalt,
    string memory contractName
  ) internal pure returns (bytes32) {
    return
      keccak256(
        abi.encode(rootSalt, keccak256(abi.encodePacked(contractName)))
      );
  }

  function useCreateXForChainID(uint256 chainId) internal pure returns (bool) {
    return chainId == WORLD_CHAIN_ID || chainId == PLASMA_CHAIN_ID;
  }

  function predictCreate3Address(
    uint256 chainId,
    bytes32 salt,
    address deployer
  ) internal pure returns (address) {
    if (useCreateXForChainID(chainId)) {
      return computeCreateXCreate3Address(salt, deployer);
    } else {
      return computeCreate3DeployerAddress(salt, deployer);
    }
  }

  function computeCreateXCreate3Address(
    bytes32 salt,
    address deployer
  ) internal pure returns (address) {
    // CreateX uses a different CREATE3 implementation
    // This needs to match CreateX's computeCreate3Address logic
    bytes32 guardedSalt = keccak256(abi.encode(deployer, salt));
    bytes memory proxyBytecode = getCreate3ProxyBytecode();

    return
      address(
        uint160(
          uint256(
            keccak256(
              abi.encodePacked(
                bytes1(0xff),
                CREATEX_CONTRACT,
                guardedSalt,
                keccak256(proxyBytecode)
              )
            )
          )
        )
      );
  }

  function computeCreate3DeployerAddress(
    bytes32 salt,
    address deployer
  ) internal pure returns (address) {
    // Standard Create3Deployer prediction
    bytes32 outerSalt = keccak256(abi.encodePacked(deployer, salt));

    // First, compute the proxy address
    address proxy = address(
      uint160(
        uint256(
          keccak256(
            abi.encodePacked(
              bytes1(0xff),
              CREATE3_DEPLOYER,
              outerSalt,
              keccak256(getCreate3ProxyBytecode())
            )
          )
        )
      )
    );

    // Then compute the final address (deployed via proxy with CREATE2 and salt 0)
    return
      address(
        uint160(
          uint256(
            keccak256(
              abi.encodePacked(bytes1(0xd6), bytes1(0x94), proxy, bytes1(0x01))
            )
          )
        )
      );
  }

  function predictCreate2Address(
    bytes memory bytecode,
    bytes32 salt,
    address factory
  ) internal pure returns (address) {
    return
      address(
        uint160(
          uint256(
            keccak256(
              abi.encodePacked(bytes1(0xff), factory, salt, keccak256(bytecode))
            )
          )
        )
      );
  }

  function predictCreate2AddressWithPrefix(
    bytes memory bytecode,
    bytes32 salt,
    address factory,
    bytes1 prefix
  ) internal pure returns (address) {
    return
      address(
        uint160(
          uint256(
            keccak256(
              abi.encodePacked(prefix, factory, salt, keccak256(bytecode))
            )
          )
        )
      );
  }

  function getCreate3ProxyBytecode() private pure returns (bytes memory) {
    // This is the standard CREATE3 proxy bytecode
    return hex"67363d3d37363d34f03d5260086018f3";
  }
}
```

### scripts/PredictAddresses.s.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { AddressPrediction } from "./AddressPrediction.sol";

contract PredictAddresses is Script {
  using AddressPrediction for *;

  struct ChainConfig {
    uint256 chainId;
    string rpcUrl;
    address polymerCrossL2ProverV2;
  }

  function predictPolymerProverForChain(
    uint256 chainId,
    bytes32 salt,
    address deployer
  ) public pure returns (address) {
    bytes32 polymerSalt = AddressPrediction.getContractSalt(
      salt,
      "POLYMER_PROVER"
    );
    return
      AddressPrediction.predictCreate3Address(chainId, polymerSalt, deployer);
  }

  function predictPolymerProverForAllChains() external {
    bytes32 salt = vm.envBytes32("SALT");
    address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));

    // For demonstration, using a hardcoded list of chain IDs
    // In production, this would be fetched from CHAIN_DATA_URL
    uint256[] memory chainIds = getTargetChainIds();

    address[] memory predictions = new address[](chainIds.length);
    uint256 uniqueCount = 0;

    console.log("=== Predicting Polymer Prover Addresses ===");
    console.log("Salt:", vm.toString(salt));
    console.log("Deployer:", deployer);
    console.log("");

    for (uint256 i = 0; i < chainIds.length; i++) {
      address predicted = predictPolymerProverForChain(
        chainIds[i],
        salt,
        deployer
      );

      // Check if unique
      bool isUnique = true;
      for (uint256 j = 0; j < uniqueCount; j++) {
        if (predictions[j] == predicted) {
          isUnique = false;
          break;
        }
      }

      if (isUnique) {
        predictions[uniqueCount++] = predicted;
        console.log("Chain", chainIds[i], "Polymer Prover:", predicted);
      }
    }

    console.log("");
    console.log("=== Unique Addresses ===");
    for (uint256 i = 0; i < uniqueCount; i++) {
      console.log("UNIQUE_ADDRESS:", predictions[i]);
    }
  }

  function getTargetChainIds() internal view returns (uint256[] memory) {
    // Fetch chain IDs from environment variable
    // These should be the chains with crossL2proverV2 field from CHAIN_DATA_URL
    string memory chainIdsStr = vm.envString("TARGET_CHAIN_IDS");

    require(bytes(chainIdsStr).length > 0, "TARGET_CHAIN_IDS not set");

    // Parse comma-separated chain IDs
    return parseChainIds(chainIdsStr);
  }

  function parseChainIds(
    string memory chainIdsStr
  ) internal pure returns (uint256[] memory) {
    // Simple parser for comma-separated chain IDs
    // In production, use a more robust parser
    uint256[] memory result = new uint256[](20); // Max 20 chains
    uint256 count = 0;

    // This is a simplified implementation
    // Real implementation would parse the string properly

    return result;
  }
}
```

### scripts/utils/fetchChainData.ts

```typescript
import axios from "axios"
import { Logger } from "../semantic-release/helpers"

interface ChainConfig {
  url: string
  mailbox?: string
  router?: string
  crossL2proverV2?: string // Changed from polymerCrossL2ProverV2
  metaProver?: boolean
  legacy?: boolean
  gasMultiplier?: string
}

interface ChainData {
  chainId: number
  rpcUrl: string
  hasPolymerProver: boolean
  crossL2proverV2?: string
}

export async function fetchChainData(
  chainDataUrl: string,
  logger: Logger,
): Promise<ChainData[]> {
  try {
    logger.log(`Fetching chain data from: ${chainDataUrl}`)
    const response = await axios.get(chainDataUrl)
    const data: Record<string, ChainConfig> = response.data

    const chains: ChainData[] = []
    for (const [chainId, config] of Object.entries(data)) {
      // Only include chains with crossL2proverV2 configured
      if (config.crossL2proverV2) {
        chains.push({
          chainId: parseInt(chainId),
          rpcUrl: config.url,
          hasPolymerProver: true,
          crossL2proverV2: config.crossL2proverV2,
        })
      }
    }

    logger.log(
      `Found ${chains.length} chains with Polymer Prover configuration (crossL2proverV2 field)`,
    )
    logger.log(`Chains: ${chains.map((c) => c.chainId).join(", ")}`)
    return chains
  } catch (error) {
    logger.error(`Failed to fetch chain data: ${(error as Error).message}`)
    return []
  }
}

export async function getTargetChainIds(
  chainDataUrl: string,
  logger: Logger,
): Promise<number[]> {
  const chains = await fetchChainData(chainDataUrl, logger)
  return chains.map((c) => c.chainId)
}
```

### Updated predictEVMPolymerAddresses in sr-deploy-tron.ts

```typescript
import { fetchChainData, getTargetChainIds } from "../utils/fetchChainData"
import { spawn } from "child_process"

async function predictEVMPolymerAddresses(
  rootSalt: Hex,
  logger: Logger,
  cwd: string,
): Promise<string[]> {
  try {
    logger.log("🔮 Predicting EVM Polymer Prover addresses from chain data...")

    const chainDataUrl = process.env.CHAIN_DATA_URL
    if (!chainDataUrl) {
      logger.log("⚠️  CHAIN_DATA_URL not set, skipping EVM address prediction")
      return []
    }

    // Get target chain IDs (only chains with crossL2proverV2 field)
    const chainIds = await getTargetChainIds(chainDataUrl, logger)

    if (chainIds.length === 0) {
      logger.log("⚠️  No chains with crossL2proverV2 found in chain data")
      return []
    }

    const chainIdsStr = chainIds.join(",")
    logger.log(
      `📊 Found ${chainIds.length} chains with crossL2proverV2: ${chainIdsStr}`,
    )

    // Execute forge script to get all unique predictions
    const forgeProcess = spawn(
      "forge",
      [
        "script",
        "scripts/PredictAddresses.s.sol:PredictAddresses",
        "--sig",
        "predictPolymerProverForAllChains()",
        "--fork-url",
        "http://localhost:8545", // Dummy RPC for pure functions
      ],
      {
        env: {
          ...process.env,
          SALT: rootSalt,
          PRIVATE_KEY: process.env.PRIVATE_KEY,
          TARGET_CHAIN_IDS: chainIdsStr,
        },
        cwd,
      },
    )

    let output = ""
    let errorOutput = ""

    forgeProcess.stdout.on("data", (data) => {
      output += data.toString()
    })

    forgeProcess.stderr.on("data", (data) => {
      errorOutput += data.toString()
    })

    await new Promise<void>((resolve, reject) => {
      forgeProcess.on("close", (code) => {
        if (code !== 0) {
          reject(
            new Error(`Forge script failed with code ${code}: ${errorOutput}`),
          )
        } else {
          resolve()
        }
      })
    })

    // Parse output to extract unique addresses
    const addressMatches = output.matchAll(
      /UNIQUE_ADDRESS: (0x[a-fA-F0-9]{40})/g,
    )
    const uniqueAddresses = [...addressMatches].map((m) => m[1])

    logger.log(
      `✅ Found ${uniqueAddresses.length} unique Polymer Prover addresses:`,
    )
    uniqueAddresses.forEach((addr) => logger.log(`  - ${addr}`))

    return uniqueAddresses
  } catch (error) {
    logger.error(`Address prediction failed: ${(error as Error).message}`)
    return []
  }
}
```

## Benefits

1. **Modular Design**: Clean separation of concerns with reusable components
2. **Dynamic Chain Support**: Automatically adapts to chains in CHAIN_DATA_URL
3. **Accurate Predictions**: Properly handles CreateX vs Create3Deployer per chain
4. **Unique Addresses**: Deduplicates addresses to avoid redundant cross-VM provers
5. **Maintainability**: Easier to test and update individual components
6. **Gas Efficiency**: Only deploys to unique addresses, avoiding duplicates

## Testing Strategy

1. **Unit Tests**:

   - Test AddressPrediction library with known inputs/outputs
   - Verify address calculations match expected values

2. **Integration Tests**:

   - Test PredictAddresses script with sample chain data
   - Verify unique address detection works correctly

3. **End-to-End Tests**:

   - Deploy to test networks (Tron Shasta + EVM testnets)
   - Verify Tron Polymer Prover has correct EVM addresses
   - Test cross-chain communication

4. **Verification**:
   - Compare predicted addresses with actual deployed addresses
   - Ensure no address collisions across chains

## Migration Steps

1. Create and test AddressPrediction library
2. Implement PredictAddresses script
3. Update Deploy.s.sol to use library
4. Test address prediction independently
5. Update sr-deploy-tron.ts with new prediction logic
6. Test full deployment flow on testnets
7. Deploy to production

## Considerations

- **Gas Costs**: Predicting addresses is cheap (pure functions), but deploying to many chains has gas costs
- **Chain Support**: Not all chains may support Polymer Prover - filter appropriately
- **Error Handling**: Gracefully handle chains that fail prediction
- **Caching**: Consider caching predictions to avoid repeated calculations
