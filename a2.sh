#!/bin/bash

set -euo pipefail

# Configuration
LOG_FILE="deploy_op_cmd_$(date +%Y%m%d_%H%M%S).log"
CHAIN_ID="${1:-}"
CHAIN_NAME="${2:-}"
ARBITRUM_VOLUME="${CHAIN_NAME}"
BASE_DIR="/data/raas"

DEPLOYER_KEY=0xf745a9e657effb6eb53b6558e78afa75ebd5063840f5340ba31417e19f116af9
BATCH_POSTER_KEY=0x44ab94407502fa3c53af07d90bdd26d53ecf8ca819d06b7c6eafd18caa5ee31f
VALIDATOR_KEY=0xe323c8254a07f97f6dbf2b3d7fd641a233a62a511eeb6287a19bb681a640a6f0
DEPLOYER_ADD=0x9a0451A6fADDACb2f10A0Fcf8bc45A809BaB7a8A

# Function to log messages
log_message() {
    local message="$1"
    local status="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$status] $message" | tee -a "$LOG_FILE"
}

# Function to execute commands
execute_command() {
    local description="$1"
    local cmd="$2"
    log_message "$description" "INFO"
    if eval "$cmd" >> "$LOG_FILE" 2>&1; then
        log_message "$description completed successfully." "SUCCESS"
    else
        log_message "$description failed. Check $LOG_FILE for details." "ERROR"
        exit 1
    fi
}

# Validation
if [[ -z "$CHAIN_ID" || -z "$CHAIN_NAME" ]]; then
    log_message "Usage: $0 <CHAIN_ID> <CHAIN_NAME>" "ERROR"
    exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
    log_message "This script must be run as root." "ERROR"
    exit 1
fi

cd "$BASE_DIR"
log_message "Starting deployment for $BASE_DIR with CHAIN_ID=$CHAIN_ID and CHAIN_NAME=$CHAIN_NAME" "INFO"

# Step 1: Contracts setup
execute_command "Configuring contracts/.env" \
"cd $BASE_DIR/contracts && cp -f ../.env.example .env && \
 sed -i '/^ORBIT_DEPLOYMENT_TRANSACTION_HASH/d' .env && \
 sed -i 's|^CHAIN_ID=.*|CHAIN_ID=${CHAIN_ID}|' .env && \
 sed -i 's|^DEPLOYER_PRIVATE_KEY=.*|DEPLOYER_PRIVATE_KEY=${DEPLOYER_KEY}|' .env && \
 sed -i 's|^BATCH_POSTER_PRIVATE_KEY=.*|BATCH_POSTER_PRIVATE_KEY=${BATCH_POSTER_KEY}|' .env && \
 sed -i 's|^VALIDATOR_PRIVATE_KEY=.*|VALIDATOR_PRIVATE_KEY=${VALIDATOR_KEY}|' .env"

# Step 2: Install contract dependencies
execute_command "Installing contract dependencies" \
"cd $BASE_DIR/contracts && yarn install && yarn add @arbitrum/orbit-sdk viem@^1.20.0"

# Step 3: Deploy contracts
log_message "Running yarn dev for contract deployment" "INFO"
cd $BASE_DIR/contracts
if output=$(yarn dev 2>&1); then
    echo "$output" >> "$LOG_FILE"
    tx_hash=$(echo "$output" | grep -oP '0x[a-fA-F0-9]{64}' | head -n 1)
    if [[ -z "$tx_hash" ]]; then
        log_message "No deployment transaction hash found in output!" "ERROR"
        exit 1
    fi
    log_message "Deployment TX: $tx_hash" "SUCCESS"
else
    log_message "yarn dev failed" "ERROR"
    exit 1
fi

# Step 4: Prepare setup
execute_command "Preparing prepare/.env configuration" \
"cd ../prepare && cp -f ../.env.example .env && \
 sed -i 's|^ORBIT_DEPLOYMENT_TRANSACTION_HASH=.*|ORBIT_DEPLOYMENT_TRANSACTION_HASH=${tx_hash}|' .env && \
 sed -i 's|^CHAIN_ID=.*|CHAIN_ID=${CHAIN_ID}|' .env && \
 sed -i 's|^DEPLOYER_PRIVATE_KEY=.*|DEPLOYER_PRIVATE_KEY=${DEPLOYER_KEY}|' .env && \
 sed -i 's|^BATCH_POSTER_PRIVATE_KEY=.*|BATCH_POSTER_PRIVATE_KEY=${BATCH_POSTER_KEY}|' .env && \
 sed -i 's|^VALIDATOR_PRIVATE_KEY=.*|VALIDATOR_PRIVATE_KEY=${VALIDATOR_KEY}|' .env"

execute_command "Installing prepare dependencies and patching RPC" \
"cd ../prepare && yarn install && yarn add @arbitrum/orbit-sdk viem@^1.20.0 && yarn dev && \
 sed -i 's|\"url\": \"https://rpc.sepolia.org\"|\"url\": \"http://101.44.25.36:8545\"|' node-config.json"

execute_command "Updating root .env" \
"sed -i 's|^CHAIN_ID=.*|CHAIN_ID=${CHAIN_ID}|' .env && \
 sed -i 's|^ARBITRUM_VOLUME=.*|ARBITRUM_VOLUME=${ARBITRUM_VOLUME}|' .env"

execute_command "Starting services with docker-compose" "docker-compose up -d"

# Step 6: Post-deployment configs
log_message "Waiting for services to settle..." "INFO"
sleep 200

IP=$(hostname -I | awk '{print $1}')
execute_command "Final .env patch with live IP" \
"cd $BASE_DIR/token-bridge &&  cp -f .env.example .env && \
 sed -i 's|^ORBIT_CHAIN_RPC=.*|ORBIT_CHAIN_RPC=http://${IP}:8449|' .env && \
 sed -i 's|^ORBIT_CHAIN_ID=.*|ORBIT_CHAIN_ID=${CHAIN_ID}|' .env && \
 sed -i 's|^ORBIT_NETWORK_NAME=.*|ORBIT_NETWORK_NAME=${CHAIN_NAME}|' .env && \
 sed -i 's|^ORBIT_CHAIN_LABEL=.*|ORBIT_CHAIN_LABEL=${CHAIN_NAME}|' .env && \
 sed -i 's|^ROLLUP_ADDRESS=.*|ROLLUP_ADDRESS=${DEPLOYER_ADD}|' .env && \
 sed -i 's|^ROLLUP_OWNER_PRIVATE_KEY=.*|ROLLUP_OWNER_PRIVATE_KEY=${DEPLOYER_KEY}|' .env"

# Step 7: Token bridge setup
execute_command "Setting up token-bridge" \
"cd $BASE_DIR/token-bridge && yarn install && yarn add @arbitrum/orbit-sdk viem@^1.20.0 && yarn dev"

log_message "Deployment completed successfully on node: $HOSTNAME" "SUCCESS"
echo "Done. See $LOG_FILE for full logs."
