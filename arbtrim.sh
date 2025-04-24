#!/bin/bash

set -euo pipefail

# Configuration
LOG_FILE="deploy_op_cmd_$(date +%Y%m%d_%H%M%S).log"
CHAIN_ID="$1"
CHAIN_NAME="$2"
ARBITRUM_VOLUME="$2"

# Function to log messages
log_message() {
    local message="$1"
    local status="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$status] $message" | tee -a "$LOG_FILE"
}

# Function to execute commands with error handling
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

# Validate inputs
if [ -z "$CHAIN_ID" ] || [ -z "$CHAIN_NAME" ]; then
    log_message "CHAIN_ID and CHAIN_NAME must be provided. Usage: $0 <CHAIN_ID> <CHAIN_NAME>" "ERROR"
    exit 1
fi

# Ensure script is run with root privileges
if [ "$(id -u)" != "0" ]; then
    log_message "This script must be run as root." "ERROR"
    exit 1
fi

# Start deployment
log_message "Starting deployment for op-cmd with CHAIN_ID=$CHAIN_ID and CHAIN_NAME=$CHAIN_NAME" "INFO"

# Step 1: Install Node.js and Yarn (skip if already installed)
if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1 && command -v yarn >/dev/null 2>&1; then
    log_message "Node.js, npm, and Yarn are already installed. Skipping installation." "INFO"
else
    execute_command "Installing Node.js and Yarn" \
        "apt-get update && apt-get install -y nodejs npm && npm install --global yarn"
fi

# Step 2: Clone op-cmd repository (skip if already cloned)
if [ -d "op-cmd" ]; then
    log_message "op-cmd repository already exists. Skipping clone." "INFO"
else
    execute_command "Cloning op-cmd repository" \
        "git clone https://github.com/ajaykumar1007/op-cmd.git"
fi
# Step 3: Configure contracts/.env

execute_command "Navigating to contracts directory and configuring .env" \
"cd op-cmd/contracts && cp ../.env.example .env && \
 sed -i '/^ORBIT_DEPLOYMENT_TRANSACTION_HASH/d' .env && \
 sed -i 's|^CHAIN_ID=.*|CHAIN_ID=${CHAIN_ID}|' .env && \
 sed -i 's|^DEPLOYER_PRIVATE_KEY=.*|DEPLOYER_PRIVATE_KEY=0xf745a9e657effb6eb53b6558e78afa75ebd506384040ba31417e19f116af9|' .env && \
 sed -i 's|^BATCH_POSTER_PRIVATE_KEY=.*|BATCH_POSTER_PRIVATE_KEY=0x44ab94407502fa3c53af07d90bdd26dcf8ca819d06b7c6eafd18caa5ee31f|' .env && \
 sed -i 's|^VALIDATOR_PRIVATE_KEY=.*|VALIDATOR_PRIVATE_KEY=0xe323c8254a07f97f6dbf2b3d7fd641a23a511eeb6287a19bb681a640a6f0|' .env"


# Step 4: Install contract dependencies
execute_command "Installing contract dependencies" \
    "yarn install && yarn add @arbitrum/orbit-sdk viem@^1.20.0"

# Step 5: Run yarn dev and capture transaction hash
log_message "Running yarn dev to deploy contracts" "INFO"
if output=$(yarn dev 2>&1); then
    echo "$output" >> "$LOG_FILE"
    tx_hash=$(echo "$output" | grep -oP '0x[a-fA-F0-9]{64}' | head -n 1)
    if [ -z "$tx_hash" ]; then
        log_message "Transaction hash not found in yarn dev output." "ERROR"
        exit 1
    fi
    log_message "Transaction hash extracted: $tx_hash" "SUCCESS"
else
    log_message "yarn dev failed. Check $LOG_FILE for details." "ERROR"
    echo "$output" >> "$LOG_FILE"
    exit 1
fi

# Step 6: Configure prepare/.env
execute_command "Navigating to prepare directory and configuring .env" \
"cd ../prepare && cp ../.env.example .env && \
 sed -i 's|^ORBIT_DEPLOYMENT_TRANSACTION_HASH=.*|ORBIT_DEPLOYMENT_TRANSACTION_HASH=${tx_hash}|' .env && \
 sed -i 's|^CHAIN_ID=.*|CHAIN_ID=${CHAIN_ID}|' .env && \
 sed -i 's|^DEPLOYER_PRIVATE_KEY=.*|DEPLOYER_PRIVATE_KEY=0xf745a9e657effb6eb53b6558e78afa75ebd5063840f5340ba31417e19f116af9|' .env && \
 sed -i 's|^BATCH_POSTER_PRIVATE_KEY=.*|BATCH_POSTER_PRIVATE_KEY=0x44ab94407502fa3c53af07d90bdd26d53ecf8ca819d06b7c6eafd18caa5ee31f|' .env && \
 sed -i 's|^VALIDATOR_PRIVATE_KEY=.*|VALIDATOR_PRIVATE_KEY=0xe323c8254a07f97f6dbf2b3d7fd641a233a62a511eeb6287a19bb681a640a6f0|' .env"


# Step 7: Install prepare dependencies
execute_command "Installing prepare dependencies" \
    "yarn install && yarn add @arbitrum/orbit-sdk viem@^1.20.0 && yarn dev"
     sed -i 's|"url": "https://rpc.sepolia.org"|"url": "http://101.44.25.36:8545"|' node-config.json
# Step 8: Navigate back to root directory
execute_command "Navigating back to root directory" \
    "cd ../"

# Step 9: Pull Nitro node Docker image
execute_command "Pulling latest Nitro node Docker image" \
    "docker pull offchainlabs/nitro-node:v3.5.1-8f247fd"

# Step 10: Update root .env
execute_command "Updating root .env with CHAIN_ID, ARBITRUM_VOLUME, and private keys" \
  "sed -i 's|^CHAIN_ID=.*|CHAIN_ID=${CHAIN_ID}|' .env && \
   sed -i 's|^ARBITRUM_VOLUME=.*|ARBITRUM_VOLUME=${ARBITRUM_VOLUME}|' .env"

# Step 11: Start services with docker-compose
execute_command "Starting services with docker-compose" \
    "docker-compose up -d"

# Final success message
log_message "All deployment steps completed successfully for op-cmd." "SUCCESS"
echo "Deployment completed. Logs are available in $LOG_FILE."
