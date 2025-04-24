#!/bin/bash

set -euo pipefail

# === Color & Logging ===
info()    { echo -e "\033[1;34m[INFO]\033[0m $1"; }
success() { echo -e "\033[1;32m[SUCCESS]\033[0m $1"; }
error()   { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

# === Input Validation ===
[[ $# -ne 4 ]] && error "Usage: $0 <L1_CHAIN_ID> <L2_CHAIN_ID> <L1_RPC_URL> <USERNAME>"

export L1_CHAIN_ID=$1
export L2_CHAIN_ID=$2
export L1_RPC_URL=$3
export USERNAME=$4
export L1_RPC_KIND=any

WORKDIR="/data"
GETH_DIR="$WORKDIR/geth"
NODE_DIR="$WORKDIR/op-node"
DEPLOYER_DIR="$WORKDIR/.deployer"
WALLET_ENV="$WORKDIR/.wallet"

mkdir -p "$GETH_DIR" "$NODE_DIR"

# === Step 1: Move binaries ===
info "Extracting and installing binaries..."
if unzip -o op-cmd.zip >/dev/null; then
  mv op-deployer op-node op-proposer op-batcher geth /usr/local/bin/
else
  error "Failed to unzip op-cmd.zip"
fi

openssl rand -hex 32 | tr -d "\n" > "$GETH_DIR/jwt.txt"
cp "$GETH_DIR/jwt.txt" "$NODE_DIR"

# === Step 2: Install Foundry ===
info "Checking Foundry installation..."

if ! command -v forge &> /dev/null; then
  info "Foundry not found. Installing..."
  curl -L https://foundry.paradigm.xyz | bash || error "Foundry download failed"
  source ~/.bashrc
  foundryup || error "Foundry setup failed"
  info "Foundry installed successfully."
else
  info "Foundry is already installed. Skipping installation."
fi

# === Step 3: Generate Wallets ===
info "Generating wallets..."
if [[ -f "$WALLET_ENV" && -s "$WALLET_ENV" ]]; then
  info "Wallets already exist. Skipping generation."
else
  bash wallet.sh > "$WALLET_ENV" || error "Wallet generation failed"
  {
    echo "L1_CHAIN_ID=$L1_CHAIN_ID"
    echo "L2_CHAIN_ID=$L2_CHAIN_ID"
    echo "L1_RPC_URL=$L1_RPC_URL"
    echo "USERNAME=$USERNAME"
    echo "L1_RPC_KIND=$L1_RPC_KIND"
  } >> "$WALLET_ENV"
fi

source "$WALLET_ENV"

# === Step 4: Deploy with op-deployer ===
info "Initializing OP Deployer..."
op-deployer init --l1-chain-id "$L1_CHAIN_ID" --l2-chain-ids "$L2_CHAIN_ID" --workdir "$DEPLOYER_DIR" || error "Deployer init failed"

info "Injecting wallet addresses into intent.toml..."

# Map field to env variable name
declare -A field_to_env_var=(
  [baseFeeVaultRecipient]=GS_ADMIN_ADDRESS
  [l1FeeVaultRecipient]=GS_ADMIN_ADDRESS
  [sequencerFeeVaultRecipient]=GS_ADMIN_ADDRESS
  [systemConfigOwner]=GS_ADMIN_ADDRESS
  [unsafeBlockSigner]=GS_ADMIN_ADDRESS
  [batcher]=GS_BATCHER_ADDRESS
  [proposer]=GS_PROPOSER_ADDRESS
)

for field in "${!field_to_env_var[@]}"; do
  env_var_name="${field_to_env_var[$field]}"
  env_var_value="${!env_var_name}"

  if [[ -z "$env_var_value" ]]; then
    echo " Error: $env_var_name is not set."
    exit 1
  fi

  sed -i "s|^\(\s*${field}\s*=\s*\)\"[^\"]*\"|\1\"${env_var_value}\"|" "$DEPLOYER_DIR/intent.toml"
done


info "Applying deployment..."
op-deployer apply --workdir "$DEPLOYER_DIR" --l1-rpc-url "$L1_RPC_URL" --private-key "$GS_ADMIN_PRIVATE_KEY" || error "Deployment failed"

L2OUTPUTORACLEPROXY=$(grep disputeGameFactoryProxyAddress "$DEPLOYER_DIR/state.json" | awk -F '"' '{print $4}')
echo "L2OUTPUTORACLEPROXY=$L2OUTPUTORACLEPROXY" >> "$WALLET_ENV"

# === Step 5: Genesis + Rollup Config ===
op-deployer inspect genesis --workdir "$DEPLOYER_DIR" "$L2_CHAIN_ID" > "$DEPLOYER_DIR/genesis.json"
op-deployer inspect rollup --workdir "$DEPLOYER_DIR" "$L2_CHAIN_ID" > "$DEPLOYER_DIR/rollup.json"

info "Initializing geth..."
geth init --state.scheme=hash --datadir="$GETH_DIR/$USERNAME" "$DEPLOYER_DIR/genesis.json" || error "Geth init failed"

# === Step 6: Create Services ===
info "Creating systemd services..."

# Geth service
cat <<EOF > /etc/systemd/system/geth.service
[Unit]
Description=Ethereum Geth Testnet Node
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$GETH_DIR
EnvironmentFile=$WALLET_ENV
ExecStart=/usr/local/bin/geth \\
  --datadir $GETH_DIR/$USERNAME \\
  --http --http.corsdomain="*" --http.vhosts="*" --http.addr=0.0.0.0 \\
  --http.api=web3,debug,eth,txpool,net,engine,miner \\
  --ws --ws.addr=0.0.0.0 --ws.port=8546 --ws.origins="*" \\
  --ws.api=debug,eth,txpool,net,engine \\
  --syncmode=full --gcmode=archive \\
  --nodiscover --maxpeers=0 --networkid=$L2_CHAIN_ID \\
  --authrpc.vhosts="*" --authrpc.addr=0.0.0.0 --authrpc.port=8551 \\
  --authrpc.jwtsecret=$GETH_DIR/jwt.txt \\
  --rollup.disabletxpoolgossip=true
StandardOutput=append:/var/log/geth.log
StandardError=append:/var/log/geth.log
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# op-node
cat <<EOF > /etc/systemd/system/op-node.service
[Unit]
Description=Optimism Node
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$NODE_DIR
EnvironmentFile=$WALLET_ENV
ExecStart=/usr/local/bin/op-node \\
  --l2=http://localhost:8551 \\
  --l2.jwt-secret=$NODE_DIR/jwt.txt \\
  --sequencer.enabled \\
  --sequencer.l1-confs=5 \\
  --verifier.l1-confs=4 \\
  --rollup.config=$DEPLOYER_DIR/rollup.json \\
  --rpc.addr=0.0.0.0 \\
  --p2p.disable \\
  --rpc.enable-admin \\
  --p2p.sequencer.key=$GS_SEQUENCER_PRIVATE_KEY \\
  --l1=$L1_RPC_URL \\
  --l1.rpckind=$L1_RPC_KIND \\
  --l1.beacon.ignore
StandardOutput=append:/var/log/op-node.log
StandardError=append:/var/log/op-node.log
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# op-batcher
cat <<EOF > /etc/systemd/system/op-batcher.service
[Unit]
Description=Optimism Batcher
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$NODE_DIR
EnvironmentFile=$WALLET_ENV
ExecStart=/usr/local/bin/op-batcher \\
  --l2-eth-rpc=http://localhost:8545 \\
  --rollup-rpc=http://localhost:9545 \\
  --poll-interval=1s \\
  --sub-safety-margin=6 \\
  --num-confirmations=1 \\
  --safe-abort-nonce-too-low-count=3 \\
  --resubmission-timeout=30s \\
  --rpc.addr=0.0.0.0 --rpc.port=8548 \\
  --rpc.enable-admin \\
  --max-channel-duration=25 \\
  --l1-eth-rpc=$L1_RPC_URL \\
  --private-key=$GS_BATCHER_PRIVATE_KEY
StandardOutput=append:/var/log/op-batcher.log
StandardError=append:/var/log/op-batcher.log
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# op-proposer
cat <<EOF > /etc/systemd/system/op-proposer.service
[Unit]
Description=Optimism Proposer
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$NODE_DIR
EnvironmentFile=$WALLET_ENV
ExecStart=/usr/local/bin/op-proposer \\
  --poll-interval=12s \\
  --rpc.port=8560 \\
  --rollup-rpc=http://localhost:9545 \\
  --l2oo-address=$L2OUTPUTORACLEPROXY \\
  --private-key=$GS_PROPOSER_PRIVATE_KEY \\
  --l1-eth-rpc=$L1_RPC_URL
StandardOutput=append:/var/log/op-proposer.log
StandardError=append:/var/log/op-proposer.log
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# === Step 7: Start Services ===
info "Starting services..."
systemctl daemon-reexec
systemctl daemon-reload

for svc in geth op-node op-batcher op-proposer; do
  systemctl enable $svc
  systemctl start $svc || error "Failed to start $svc"
done

success "All services started successfully!"
