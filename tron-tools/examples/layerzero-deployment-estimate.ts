import { TronToolkit, LogLevel } from '../src';
import * as fs from 'fs';
import * as path from 'path';

async function estimateLayerZeroProverDeployment() {
  console.log('🚀 LayerZero Prover Deployment Resource Estimation');
  console.log('================================================');

  // Initialize toolkit for testnet
  const toolkit = new TronToolkit({
    network: 'testnet',
    logLevel: LogLevel.INFO
  });

  try {
    // Read LayerZeroProver artifact
    const artifactPath = path.join('..', 'tronbox', 'build', 'contracts', 'LayerZeroProver.json');
    const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'));
    
    console.log('📋 Contract Information:');
    console.log(`   Name: ${artifact.contractName}`);
    console.log(`   ABI Functions: ${artifact.abi.length}`);
    console.log(`   Bytecode Size: ${Math.floor(artifact.bytecode.length / 2)} bytes`);
    console.log('');

    // Find constructor in ABI
    const constructor = artifact.abi.find((item: any) => item.type === 'constructor');
    console.log('🔧 Constructor Parameters:');
    if (constructor && constructor.inputs) {
      constructor.inputs.forEach((input: any, index: number) => {
        console.log(`   ${index + 1}. ${input.name} (${input.type})`);
      });
    } else {
      console.log('   No constructor parameters');
    }
    console.log('');

    // Example constructor parameters for LayerZero Prover
    // These would need to be adjusted based on actual deployment requirements
    const constructorParams = [
      '0x1234567890123456789012345678901234567890', // portal address (example)
      [], // provers array (empty for example)
      200000 // minGasLimit
    ];

    console.log('📊 Predicting deployment resources...');
    console.log('');

    // Predict deployment resources
    const prediction = await toolkit.predictContractDeployment(
      artifact.bytecode,
      constructorParams,
      artifact.abi
    );

    console.log('⚡ Resource Prediction Results:');
    console.log('================================');
    console.log(`Energy Required: ${prediction.energy.toLocaleString()}`);
    console.log(`Bandwidth Required: ${prediction.bandwidth.toLocaleString()}`);
    console.log(`Energy Cost: ${prediction.energyCostTRX.toFixed(6)} TRX`);
    console.log(`Bandwidth Cost: ${prediction.bandwidthCostTRX.toFixed(6)} TRX`);
    console.log(`Total Estimated Cost: ${prediction.totalCostTRX.toFixed(6)} TRX`);
    console.log(`Confidence Score: ${(prediction.confidence * 100).toFixed(1)}%`);
    console.log('');

    // Convert costs to different units for better understanding
    const totalCostSUN = toolkit.getTronWeb().toSun(prediction.totalCostTRX);
    const totalCostUSD = prediction.totalCostTRX * 0.08; // Approximate TRX price (you'd want real-time data)

    console.log('💰 Cost Breakdown:');
    console.log('==================');
    console.log(`Total Cost in SUN: ${totalCostSUN.toLocaleString()}`);
    console.log(`Approximate USD Cost: $${totalCostUSD.toFixed(4)} (estimated)`);
    console.log('');

    // Check current account resources if we have a private key
    try {
      if (process.env.TRON_TESTNET_PRIVATE_KEY) {
        toolkit.setPrivateKey(process.env.TRON_TESTNET_PRIVATE_KEY);
        
        const balance = await toolkit.getBalance();
        const resources = await toolkit.getAccountResources();
        
        console.log('👤 Current Account Status:');
        console.log('==========================');
        console.log(`TRX Balance: ${balance.toFixed(6)} TRX`);
        console.log(`Available Energy: ${resources.energy.available.toLocaleString()}`);
        console.log(`Available Bandwidth: ${resources.bandwidth.available.toLocaleString()}`);
        console.log('');

        // Check if we have sufficient resources
        const needsEnergyRental = prediction.energy > resources.energy.available;
        const needsBandwidthRental = prediction.bandwidth > resources.bandwidth.available;
        const hasSufficientTRX = balance >= prediction.totalCostTRX;

        console.log('✅ Resource Sufficiency Check:');
        console.log('==============================');
        console.log(`Energy: ${needsEnergyRental ? '❌ Need to rent' : '✅ Sufficient'}`);
        console.log(`Bandwidth: ${needsBandwidthRental ? '❌ Need to rent' : '✅ Sufficient'}`);
        console.log(`TRX Balance: ${hasSufficientTRX ? '✅ Sufficient' : '❌ Insufficient'}`);
        
        if (needsEnergyRental || needsBandwidthRental) {
          console.log('');
          console.log('💡 Resource Rental Needed:');
          if (needsEnergyRental) {
            const energyDeficit = prediction.energy - resources.energy.available;
            console.log(`   - Rent ${energyDeficit.toLocaleString()} energy`);
          }
          if (needsBandwidthRental) {
            const bandwidthDeficit = prediction.bandwidth - resources.bandwidth.available;
            console.log(`   - Rent ${bandwidthDeficit.toLocaleString()} bandwidth`);
          }
        }
      }
    } catch (error) {
      console.log('ℹ️  Account information unavailable (no private key provided)');
    }

    console.log('');
    console.log('🔍 Deployment Recommendations:');
    console.log('==============================');
    
    if (prediction.confidence < 0.7) {
      console.log('⚠️  Low confidence prediction - consider adding 50% safety margin');
    } else {
      console.log('✅ High confidence prediction - 20% safety margin recommended');
    }
    
    const safetyMargin = prediction.confidence < 0.7 ? 0.5 : 0.2;
    const safeEnergy = Math.ceil(prediction.energy * (1 + safetyMargin));
    const safeBandwidth = Math.ceil(prediction.bandwidth * (1 + safetyMargin));
    
    console.log(`Recommended Energy: ${safeEnergy.toLocaleString()} (${(safetyMargin*100)}% margin)`);
    console.log(`Recommended Bandwidth: ${safeBandwidth.toLocaleString()} (${(safetyMargin*100)}% margin)`);

  } catch (error) {
    console.error('❌ Error estimating deployment:', error);
  } finally {
    toolkit.cleanup();
  }
}

// Run the estimation
if (require.main === module) {
  estimateLayerZeroProverDeployment().catch(console.error);
}