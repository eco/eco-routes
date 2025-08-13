import { TronToolkit, LogLevel } from '../src';

async function basicExample() {
  // Initialize toolkit for testnet
  const toolkit = new TronToolkit({
    network: 'testnet',
    logLevel: LogLevel.INFO,
    privateKey: process.env.TRON_TESTNET_PRIVATE_KEY
  });

  try {
    // Check system health
    console.log('🔍 Checking system health...');
    const health = await toolkit.healthCheck();
    console.log('Health:', health);

    // Check account balance
    console.log('💰 Account balance:', await toolkit.getBalance(), 'TRX');

    // Get account resources
    const resources = await toolkit.getAccountResources();
    console.log('⚡ Resources:', resources);

    // Predict transaction costs
    console.log('📊 Predicting transaction costs...');
    const prediction = await toolkit.predictTransaction(
      'TMuA6YqfCeX8EhbfYEg5y7S4DqzSJireY9', // Random address
      undefined,
      1000000, // 1 TRX in SUN
      'transfer'
    );
    console.log('Prediction:', prediction);

  } catch (error) {
    console.error('Error:', error);
  } finally {
    toolkit.cleanup();
  }
}

// Run example if this file is executed directly
if (require.main === module) {
  basicExample().catch(console.error);
}