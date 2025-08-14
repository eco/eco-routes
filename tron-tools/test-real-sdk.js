const { TronZapClient } = require('tronzap-sdk');
require('dotenv').config();

async function testRealSDK() {
  try {
    const client = new TronZapClient({
      apiToken: process.env.TRONZAP_API_TOKEN,
      apiSecret: process.env.TRONZAP_API_SECRET
    });
    
    console.log('Testing getServices with real credentials...');
    const services = await client.getServices();
    console.log('Services response structure:');
    console.log('Type:', typeof services);
    console.log('Keys:', Object.keys(services));
    console.log('Full response:', JSON.stringify(services, null, 2));
    
    // Test createEnergyTransaction method signature
    console.log('\nTesting createEnergyTransaction...');
    try {
      const tx = await client.createEnergyTransaction({
        address: 'TJJYsUz2F4fURzX2Rf4jDWDNdKf5Y86fnk',
        amount: 100000,
        duration: 24
      });
      console.log('Energy transaction response:', JSON.stringify(tx, null, 2));
    } catch (error) {
      console.log('Energy transaction error:', error.message);
      console.log('Error details:', error);
    }
    
  } catch (error) {
    console.error('SDK test failed:', error);
  }
}

testRealSDK();