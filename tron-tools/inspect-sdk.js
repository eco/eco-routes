const { TronZapClient } = require('tronzap-sdk');

console.log('TronZap SDK methods:');
console.log(Object.getOwnPropertyNames(TronZapClient.prototype).filter(name => name !== 'constructor'));

// Try to create an instance to see what methods it has
try {
  const client = new TronZapClient({ apiToken: 'test', apiSecret: 'test' });
  console.log('\nMethods available on instance:');
  console.log(Object.getOwnPropertyNames(Object.getPrototypeOf(client)).filter(name => name !== 'constructor'));
} catch (error) {
  console.log('Error creating instance:', error.message);
}