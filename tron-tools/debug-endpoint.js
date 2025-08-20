const TronWeb = require('tronweb');
const { config } = require('dotenv');

config({ path: '../.env' });

async function debugEndpoint() {
  try {
    const tronWeb = new TronWeb({
      fullHost: 'https://api.trongrid.io',
      privateKey: process.env.TRON_PRIVATE_KEY
    });

    const endpointAddr = 'TAy9xwjYjBBN6kutzrZJaAZJHCAejjK1V9';
    const proverAddr = 'TLZnJetQTgaLNwf8Aos7SeUZ9WL4FxTZZS';
    
    console.log('=== DEBUGGING LAYERZERO ENDPOINT ===');
    console.log('Endpoint:', endpointAddr);
    console.log('Prover:', proverAddr);
    console.log('Caller:', tronWeb.defaultAddress.base58);

    // Check if contract exists
    console.log('\n1. Checking contract existence...');
    const contractInfo = await tronWeb.trx.getContract(endpointAddr);
    console.log('Contract exists:', !!contractInfo);

    // Load contract
    console.log('\n2. Loading contract...');
    const contract = await tronWeb.contract().at(endpointAddr);
    console.log('Contract loaded successfully');

    // Try to call a simple view function
    console.log('\n3. Testing view functions...');
    try {
      // These are common LayerZero endpoint methods
      const methods = ['eid', 'nativeToken', 'delegates'];
      for (const method of methods) {
        try {
          if (contract[method]) {
            const result = await contract[method]().call();
            console.log(`${method}():`, result);
          }
        } catch (e) {
          console.log(`${method}(): ERROR -`, e.message);
        }
      }
    } catch (error) {
      console.log('View function test failed:', error.message);
    }

    // Check delegate status
    console.log('\n4. Checking delegate...');
    try {
      const delegate = await contract.delegates(proverAddr).call();
      console.log('Delegate for prover:', delegate);
    } catch (error) {
      console.log('Delegate check failed:', error.message);
    }

  } catch (error) {
    console.log('Debug failed:', error.message);
  }
}

debugEndpoint();