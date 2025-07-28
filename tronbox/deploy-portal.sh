#!/bin/bash

# Set the private key environment variable
export PRIVATE_KEY_TRON=CB933CFBBE4FDB37DC2E1C8B1943142FCEB533554971DD408C6E3B09D33C67C5

echo "🚀 Deploying Portal contract to Shasta testnet..."
echo "Using private key: ${PRIVATE_KEY_TRON:0:10}..."

# Run the migration
tronbox migrate --network shasta --from 5 --to 5

echo "✅ Deployment script completed!" 