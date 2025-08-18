const { TronZapClient } = require('tronzap-sdk');

console.log('Testing TronZap SDK configuration options...');

// Try different configuration options
try {
  const client1 = new TronZapClient({
    apiToken: 'test', 
    apiSecret: 'test',
    baseURL: 'https://api.tronzap.com'
  });
  console.log('✓ baseURL works');
} catch (error) {
  console.log('✗ baseURL failed:', error.message);
}

try {
  const client2 = new TronZapClient({
    apiToken: 'test', 
    apiSecret: 'test',
    baseUrl: 'https://api.tronzap.com'
  });
  console.log('✓ baseUrl works');
} catch (error) {
  console.log('✗ baseUrl failed:', error.message);
}

// Test getServices method signature
try {
  const client = new TronZapClient({
    apiToken: process.env.TRONZAP_API_TOKEN || 'test', 
    apiSecret: process.env.TRONZAP_API_SECRET || 'test'
  });
  
  console.log('\nTesting getServices method...');
  client.getServices().then(result => {
    console.log('getServices result structure:', Object.keys(result));
  }).catch(err => {
    console.log('getServices error (expected with test credentials):', err.message);
  });
  
} catch (error) {
  console.log('Client creation failed:', error.message);
}