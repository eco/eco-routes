#!/bin/bash

# I used `nvm install 22.14.0` for this one

set -e  # Exit on error
set -u  # Error on undefined variables

echo "Do you want to deploy to testnets or mainnet?"
echo "1) Testnets (Optimism Sepolia and Base Sepolia)"
echo "2) Mainnets (Optimism and Base)"
read -p "Enter choice (1 or 2): " NETWORK_CHOICE

case $NETWORK_CHOICE in
    1)
        export HARDHAT_NETWORK_OPTIMISM="optimismSepolia"
        export HARDHAT_NETWORK_BASE="baseSepolia"
    
        echo "Deploying to testnets (Optimism Sepolia and Base Sepolia)..."
        ;;
    2)
        export HARDHAT_NETWORK_OPTIMISM="optimism"
        export HARDHAT_NETWORK_BASE="base"
        echo "Deploying to mainnets (Optimism and Base)..."
        ;;
    *)
        echo "Invalid choice. Please enter 1 or 2"
        exit 1
        ;;
esac


echo "deploying intent source on $HARDHAT_NETWORK_OPTIMISM..."
npx hardhat run scripts/polymer/deployIntentSource.ts --network $HARDHAT_NETWORK_OPTIMISM | tee deploy.log
optimism_intent_source=$(grep "intent source deployed at:" deploy.log | awk '{print $5}')
if [ -z "$optimism_intent_source" ]; then
    echo "Failed to deploy intent source on $HARDHAT_NETWORK_OPTIMISM"
    exit 1
fi
echo "successfully deployed intent source on $HARDHAT_NETWORK_OPTIMISM"

echo "deploying intent source on $HARDHAT_NETWORK_BASE..."
npx hardhat run scripts/polymer/deployIntentSource.ts --network $HARDHAT_NETWORK_BASE | tee deploy.log
base_intent_source=$(grep "intent source deployed at:" deploy.log | awk '{print $5}')
if [ -z "$base_intent_source" ]; then
    echo "Failed to deploy intent source on $HARDHAT_NETWORK_BASE"
    exit 1
fi
echo "successfully deployed intent source on $HARDHAT_NETWORK_BASE"

echo "waiting 5 seconds for nonces to settle..."
sleep 5

echo "deploying inbox on $HARDHAT_NETWORK_OPTIMISM..."
npx hardhat run scripts/polymer/deployInbox.ts --network $HARDHAT_NETWORK_OPTIMISM | tee deploy.log
optimism_inbox=$(grep "inbox deployed at:" deploy.log | awk '{print $4}')
if [ -z "$optimism_inbox" ]; then
    echo "Failed to deploy inbox on $HARDHAT_NETWORK_OPTIMISM"
    exit 1
fi
echo "successfully deployed $HARDHAT_NETWORK_OPTIMISM inbox"

echo "deploying inbox on $HARDHAT_NETWORK_BASE..."
npx hardhat run scripts/polymer/deployInbox.ts --network $HARDHAT_NETWORK_BASE | tee deploy.log
base_inbox=$(grep "inbox deployed at:" deploy.log | awk '{print $4}')
if [ -z "$base_inbox" ]; then
    echo "Failed to deploy inbox on $HARDHAT_NETWORK_BASE"
    exit 1
fi
echo "successfully deployed $HARDHAT_NETWORK_BASE inbox"

echo "waiting 5 seconds for nonces to settle..."
sleep 5

echo "deploying polymer prover on $HARDHAT_NETWORK_OPTIMISM (using $HARDHAT_NETWORK_BASE inbox)..."
export INBOX_ADDRESS="$base_inbox"
npx hardhat run scripts/polymer/deployPolymerProver.ts --network $HARDHAT_NETWORK_OPTIMISM | tee deploy.log
optimism_prover=$(grep "polymer prover deployed at:" deploy.log | awk '{print $5}')
if [ -z "$optimism_prover" ]; then
    echo "Failed to deploy prover on $HARDHAT_NETWORK_OPTIMISM"
    exit 1
fi
echo "successfully deployed $HARDHAT_NETWORK_OPTIMISM prover"

echo "deploying polymer prover on $HARDHAT_NETWORK_BASE (using $HARDHAT_NETWORK_OPTIMISM inbox)..."
export INBOX_ADDRESS="$optimism_inbox"
npx hardhat run scripts/polymer/deployPolymerProver.ts --network $HARDHAT_NETWORK_BASE | tee deploy.log
base_prover=$(grep "polymer prover deployed at:" deploy.log | awk '{print $5}')
if [ -z "$base_prover" ]; then
    echo "Failed to deploy prover on $HARDHAT_NETWORK_BASE"
    exit 1
fi
echo "successfully deployed $HARDHAT_NETWORK_BASE prover"

echo "deployed addresses:"
echo "$HARDHAT_NETWORK_OPTIMISM intent source: $optimism_intent_source"
echo "$HARDHAT_NETWORK_BASE intent source: $base_intent_source"
echo "$HARDHAT_NETWORK_OPTIMISM inbox: $optimism_inbox"
echo "$HARDHAT_NETWORK_BASE inbox: $base_inbox"
echo "$HARDHAT_NETWORK_OPTIMISM prover: $optimism_prover"
echo "$HARDHAT_NETWORK_BASE prover: $base_prover"

cat > scripts/polymer/deployed.json << EOF
{
  "network": "$NETWORK_CHOICE",
  "optimism_intent_source": "$optimism_intent_source",
  "optimism_inbox": "$optimism_inbox",
  "optimism_prover": "$optimism_prover",
  "base_intent_source": "$base_intent_source",
  "base_inbox": "$base_inbox",
  "base_prover": "$base_prover"
}
EOF

unset INBOX_ADDRESS
unset HARDHAT_NETWORK_OPTIMISM
unset HARDHAT_NETWORK_BASE


