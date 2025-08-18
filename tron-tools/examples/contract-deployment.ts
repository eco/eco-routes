import { TronToolkit, DeploymentConfig } from '../src';

// Example contract ABI and bytecode (simplified ERC20-like token)
const sampleContractABI = [
  {
    "type": "constructor",
    "inputs": [
      { "name": "_name", "type": "string" },
      { "name": "_symbol", "type": "string" },
      { "name": "_initialSupply", "type": "uint256" }
    ]
  },
  {
    "type": "function",
    "name": "transfer",
    "inputs": [
      { "name": "_to", "type": "address" },
      { "name": "_value", "type": "uint256" }
    ],
    "outputs": [{ "name": "", "type": "bool" }]
  }
];

const sampleBytecode = "0x608060405234801561001057600080fd5b5060405161047a38038061047a8339818101604052606081101561003357600080fd5b8101908080516401000000008111156100..."; // Truncated for brevity

async function deploymentExample() {
  const toolkit = new TronToolkit({
    network: 'testnet',
    privateKey: process.env.TRON_TESTNET_PRIVATE_KEY
  });

  try {
    console.log('🚀 Starting contract deployment example...');

    // Prepare deployment configuration
    const deploymentConfig: DeploymentConfig = {
      contractName: 'SampleToken',
      bytecode: sampleBytecode,
      abi: sampleContractABI,
      constructorParams: [
        'Sample Token',
        'SAMPLE',
        '1000000000' // 1 billion tokens
      ],
      feeLimit: 1000000000 // 1000 TRX fee limit
    };

    // Predict deployment costs
    console.log('📊 Predicting deployment costs...');
    const costEstimate = await toolkit.predictContractDeployment(
      deploymentConfig.bytecode,
      deploymentConfig.constructorParams,
      deploymentConfig.abi
    );
    console.log('Estimated costs:', costEstimate);

    // Check if we need to rent resources
    if (toolkit.tronZapClient) {
      console.log('💡 Calculating optimal resource rental...');
      const rentalStrategy = await toolkit.calculateOptimalRental(
        costEstimate.energy,
        costEstimate.bandwidth,
        toolkit.getCurrentAddress()
      );
      console.log('Rental recommendation:', rentalStrategy);
    }

    // Deploy the contract
    console.log('⚙️  Deploying contract...');
    const deploymentResult = await toolkit.deployContract(
      deploymentConfig,
      undefined, // Use default private key
      true // Auto-rent resources
    );

    console.log('✅ Contract deployed successfully!');
    console.log('Contract address:', deploymentResult.contractAddress);
    console.log('Transaction ID:', deploymentResult.transactionId);
    console.log('Energy used:', deploymentResult.energyUsed);
    console.log('Bandwidth used:', deploymentResult.bandwidthUsed);
    console.log('Total cost:', deploymentResult.actualCost, 'TRX');

    // Verify deployment
    const contractInfo = await toolkit.getTronWeb().trx.getContract(deploymentResult.contractAddress);
    console.log('📋 Contract verification:', contractInfo ? 'SUCCESS' : 'FAILED');

  } catch (error) {
    console.error('❌ Deployment failed:', error);
  } finally {
    toolkit.cleanup();
  }
}

// Batch deployment example
async function batchDeploymentExample() {
  const toolkit = new TronToolkit({
    network: 'testnet',
    privateKey: process.env.TRON_TESTNET_PRIVATE_KEY
  });

  try {
    console.log('🚀 Starting batch deployment example...');

    const contracts: DeploymentConfig[] = [
      {
        contractName: 'Token1',
        bytecode: sampleBytecode,
        abi: sampleContractABI,
        constructorParams: ['Token One', 'TKN1', '1000000']
      },
      {
        contractName: 'Token2',
        bytecode: sampleBytecode,
        abi: sampleContractABI,
        constructorParams: ['Token Two', 'TKN2', '2000000']
      }
    ];

    // Estimate total costs
    const batchEstimate = await toolkit.estimateBatchDeploymentCost(contracts);
    console.log('📊 Batch deployment estimate:', batchEstimate);

    // Deploy all contracts
    console.log('⚙️  Deploying contracts in batch...');
    const results = await toolkit.batchDeploy(contracts);

    console.log('✅ Batch deployment completed!');
    results.forEach((result, index) => {
      console.log(`Contract ${index + 1}:`, result.contractAddress);
    });

  } catch (error) {
    console.error('❌ Batch deployment failed:', error);
  } finally {
    toolkit.cleanup();
  }
}

// Run examples if this file is executed directly
if (require.main === module) {
  const example = process.argv[2] || 'single';
  
  if (example === 'batch') {
    batchDeploymentExample().catch(console.error);
  } else {
    deploymentExample().catch(console.error);
  }
}