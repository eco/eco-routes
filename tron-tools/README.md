# Tron Tools

A comprehensive TypeScript toolkit for Tron blockchain deployment and interaction, featuring intelligent resource management, automated energy/bandwidth rental, and robust transaction handling.

## Features

### 🌐 Network Management
- Multi-network support (Mainnet/Testnet) with automatic failover
- Network health monitoring and RPC endpoint management
- Seamless switching between environments

### 🔑 Account Management
- Secure private key handling and wallet integration
- Address format conversion (hex/base58)
- Balance and resource tracking
- Account creation and import utilities

### 📊 Resource Prediction
- AI-enhanced energy and bandwidth prediction
- Contract bytecode analysis for complexity assessment
- Historical data tracking for improved accuracy
- Confidence scoring based on operation familiarity

### 💰 Automated Resource Rental
- TronZap API integration for energy/bandwidth rental
- Optimal rental strategy calculation with bulk discounts
- Auto-rental functionality with configurable safety margins
- Cost optimization and rental history tracking

### 🔄 Transaction Management
- Robust transaction building, signing, and broadcasting
- Confirmation waiting with configurable timeouts
- Retry logic with escalating fee limits
- Pending transaction tracking and cleanup

### 🚀 Contract Deployment
- Streamlined contract deployment workflows
- CREATE2 support for deterministic addresses
- Batch deployment capabilities
- Deployment verification and tracking

## Installation

```bash
npm install @eco/tron-tools
```

## Quick Start

```typescript
import { TronToolkit, LogLevel } from '@eco/tron-tools';

// Initialize toolkit
const toolkit = new TronToolkit({
  network: 'testnet',
  logLevel: LogLevel.INFO,
  privateKey: process.env.TRON_PRIVATE_KEY
});

// Check system health
const health = await toolkit.healthCheck();
console.log('System status:', health);

// Get account balance
const balance = await toolkit.getBalance();
console.log('Balance:', balance, 'TRX');

// Predict transaction costs
const prediction = await toolkit.predictTransaction(
  'TMuA6YqfCeX8EhbfYEg5y7S4DqzSJireY9',
  undefined,
  1000000, // 1 TRX in SUN
  'transfer'
);
console.log('Cost prediction:', prediction);
```

## Configuration

Create a `.env` file with the following variables:

```env
# Network Configuration
TRON_MAINNET_RPC_URL=https://api.trongrid.io
TRON_TESTNET_RPC_URL=https://api.nileex.io
TRON_MAINNET_API_KEY=your_trongrid_api_key
TRON_TESTNET_API_KEY=your_nile_api_key

# TronZap Configuration
TRONZAP_API_KEY=your_tronzap_api_key
TRONZAP_API_URL=https://api.tronzap.io

# Private Keys
TRON_PRIVATE_KEY=your_private_key
TRON_TESTNET_PRIVATE_KEY=your_testnet_private_key

# Resource Configuration
DEFAULT_ENERGY_LIMIT=100000
DEFAULT_BANDWIDTH_LIMIT=1000
ENERGY_PRICE_SUN=420
```

## Contract Deployment

```typescript
import { TronToolkit, DeploymentConfig } from '@eco/tron-tools';

const toolkit = new TronToolkit({ network: 'testnet' });

const config: DeploymentConfig = {
  contractName: 'MyContract',
  bytecode: '0x608060405234801561001057600080fd5b50...',
  abi: [...], // Contract ABI
  constructorParams: ['param1', 'param2'],
  feeLimit: 1000000000 // 1000 TRX
};

// Deploy with automatic resource rental
const result = await toolkit.deployContract(
  config,
  undefined, // Use default private key
  true // Auto-rent resources
);

console.log('Contract deployed at:', result.contractAddress);
```

## Resource Management

```typescript
// Get current rental prices
const prices = await toolkit.getRentalPrices();

// Auto-rent optimal resources
const rental = await toolkit.autoRentResources(
  50000,  // Energy needed
  1000,   // Bandwidth needed
  'TMyAddress...',
  0.2     // 20% safety margin
);

// Calculate optimal rental strategy
const strategy = await toolkit.calculateOptimalRental(
  50000,
  1000,
  'TMyAddress...'
);
```

## Transaction Handling

```typescript
// Send TRX with confirmation
const result = await toolkit.transferTRX(
  'TDestinationAddress...',
  10 // 10 TRX
);

// Send transaction with retry logic
const config = {
  from: toolkit.getCurrentAddress(),
  to: 'TDestinationAddress...',
  value: toolkit.getTronWeb().toSun(5),
  feeLimit: 10000000
};

const retryResult = await toolkit.retryTransaction(config);
```

## Batch Operations

```typescript
// Batch deploy multiple contracts
const contracts = [
  { contractName: 'Contract1', bytecode: '0x...', abi: [...] },
  { contractName: 'Contract2', bytecode: '0x...', abi: [...] }
];

const deploymentResults = await toolkit.batchDeploy(contracts);

// Estimate batch deployment costs
const costEstimate = await toolkit.estimateBatchDeploymentCost(contracts);
```

## Examples

See the `examples/` directory for complete usage examples:

- `basic-usage.ts` - Basic toolkit initialization and operations
- `contract-deployment.ts` - Contract deployment examples
- `resource-management.ts` - Resource rental and optimization
- `batch-operations.ts` - Batch deployment and transaction handling

## Architecture

The toolkit is built with a modular architecture:

```
TronToolkit
├── NetworkManager     # Network and RPC management
├── AccountManager     # Account and key management
├── ResourcePredictor  # Energy/bandwidth prediction
├── TronZapClient     # Resource rental integration
├── TransactionManager # Transaction lifecycle management
└── ContractDeployer  # Contract deployment utilities
```

## API Reference

### TronToolkit

Main class providing high-level interface to all functionality.

#### Constructor
```typescript
new TronToolkit(config?: TronToolkitConfig)
```

#### Network Methods
- `switchNetwork(network: 'mainnet' | 'testnet'): Promise<void>`
- `getCurrentNetwork(): TronNetwork`
- `isMainnet(): boolean`
- `getNetworkHealth(): Promise<NetworkHealth>`

#### Account Methods
- `createAccount(): TronAccount`
- `importAccount(privateKey: string): TronAccount`
- `getCurrentAddress(): string`
- `getBalance(address?: string): Promise<number>`
- `getAccountResources(address?: string): Promise<AccountResources>`

#### Prediction Methods
- `predictTransaction(...): Promise<ResourceEstimate>`
- `predictContractDeployment(...): Promise<ResourceEstimate>`

#### Resource Rental Methods
- `getRentalPrices(): Promise<RentalPrices>`
- `rentEnergy(amount, address, duration?): Promise<RentalResponse>`
- `autoRentResources(...): Promise<RentalResult>`

#### Transaction Methods
- `sendTransaction(config, privateKey?): Promise<TransactionResult>`
- `sendAndConfirm(config, privateKey?, timeout?): Promise<TransactionResult>`
- `retryTransaction(config, privateKey?, retries?): Promise<TransactionResult>`

#### Deployment Methods
- `deployContract(config, privateKey?, autoRent?): Promise<DeploymentResult>`
- `batchDeploy(configs, privateKey?, autoRent?): Promise<DeploymentResult[]>`
- `predictContractAddress(deployer, salt?): Promise<string>`

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

MIT License - see LICENSE file for details.

## Support

For questions and support:
- Create an issue on GitHub
- Check the examples directory
- Review the API documentation