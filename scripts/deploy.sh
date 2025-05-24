#!/bin/bash

# Omniliquid Move Modules Deployment Script
# This script deploys all Omniliquid modules to the Sui network

set -e

# Configuration
NETWORK=${1:-testnet}  # testnet, devnet, or mainnet
GAS_BUDGET=100000000   # 0.1 SUI

echo "🚀 Deploying Omniliquid to $NETWORK..."

# Check if sui CLI is installed
if ! command -v sui &> /dev/null; then
    echo "❌ Sui CLI not found. Please install it first."
    exit 1
fi

# Build the project
echo "📦 Building Move modules..."
sui move build

# Deploy the modules
echo "🔨 Deploying modules to $NETWORK..."
DEPLOY_OUTPUT=$(sui client publish --gas-budget $GAS_BUDGET --json)

if [ $? -ne 0 ]; then
    echo "❌ Deployment failed!"
    exit 1
fi

echo "✅ Deployment successful!"

# Extract important addresses from deployment output
PACKAGE_ID=$(echo $DEPLOY_OUTPUT | jq -r '.objectChanges[] | select(.type == "published") | .packageId')

echo "📋 Deployment Summary:"
echo "====================="
echo "Package ID: $PACKAGE_ID"
echo "Network: $NETWORK"

# Extract shared object IDs
MARKET_STATE_ID=$(echo $DEPLOY_OUTPUT | jq -r '.objectChanges[] | select(.objectType | contains("MarketState")) | .objectId')
VAULT_STATE_ID=$(echo $DEPLOY_OUTPUT | jq -r '.objectChanges[] | select(.objectType | contains("VaultState")) | .objectId')
STAKING_POOL_ID=$(echo $DEPLOY_OUTPUT | jq -r '.objectChanges[] | select(.objectType | contains("StakingPool")) | .objectId')
PRICE_ORACLE_ID=$(echo $DEPLOY_OUTPUT | jq -r '.objectChanges[] | select(.objectType | contains("PriceOracle")) | .objectId')

echo ""
echo "🔑 Shared Object IDs:"
echo "Market State: $MARKET_STATE_ID"
echo "Vault State: $VAULT_STATE_ID"
echo "Staking Pool: $STAKING_POOL_ID"
echo "Price Oracle: $PRICE_ORACLE_ID"

# Create environment file for frontend
echo ""
echo "📝 Creating environment configuration..."

ENV_FILE=".env.${NETWORK}"
cat > $ENV_FILE << EOF
# Omniliquid $NETWORK Configuration
# Generated on $(date)

NEXT_PUBLIC_SUI_NETWORK=$NETWORK

# Package IDs
NEXT_PUBLIC_MARKET_PACKAGE_ID=$PACKAGE_ID
NEXT_PUBLIC_VAULT_PACKAGE_ID=$PACKAGE_ID
NEXT_PUBLIC_STAKING_PACKAGE_ID=$PACKAGE_ID
NEXT_PUBLIC_TOKEN_PACKAGE_ID=$PACKAGE_ID

# Shared Object IDs
NEXT_PUBLIC_MARKET_STATE_ID=$MARKET_STATE_ID
NEXT_PUBLIC_VAULT_STATE_ID=$VAULT_STATE_ID
NEXT_PUBLIC_STAKING_POOL_ID=$STAKING_POOL_ID
NEXT_PUBLIC_PRICE_ORACLE_ID=$PRICE_ORACLE_ID
EOF

echo "Environment file created: $ENV_FILE"

# Initialize markets
echo ""
echo "🏪 Initializing default markets..."

# Get admin capabilities
ADMIN_CAPS=$(echo $DEPLOY_OUTPUT | jq -r '.objectChanges[] | select(.objectType | contains("AdminCap")) | .objectId')

# Add BTC market
echo "Adding BTC market..."
sui client call \
    --package $PACKAGE_ID \
    --module trading \
    --function add_market \
    --args $MARKET_STATE_ID $ADMIN_CAPS '"BTC"' 50 1000000 1000000000000 \
    --gas-budget $GAS_BUDGET

# Add ETH market
echo "Adding ETH market..."
sui client call \
    --package $PACKAGE_ID \
    --module trading \
    --function add_market \
    --args $MARKET_STATE_ID $ADMIN_CAPS '"ETH"' 50 1000000 1000000000000 \
    --gas-budget $GAS_BUDGET

# Add SOL market
echo "Adding SOL market..."
sui client call \
    --package $PACKAGE_ID \
    --module trading \
    --function add_market \
    --args $MARKET_STATE_ID $ADMIN_CAPS '"SOL"' 20 1000000 1000000000000 \
    --gas-budget $GAS_BUDGET

echo ""
echo "🎉 Omniliquid deployment completed successfully!"
echo ""
echo "Next steps:"
echo "1. Update your frontend .env file with the generated configuration"
echo "2. Set up price oracles with external price feeds"
echo "3. Configure trading parameters as needed"
echo "4. Test the integration with your frontend"
echo ""
echo "⚠️  Important: Keep your admin capabilities secure!"
echo "Admin Cap IDs: $ADMIN_CAPS"