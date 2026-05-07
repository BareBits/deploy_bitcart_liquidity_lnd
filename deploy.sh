#!/bin/bash
# Must be run as root

# Exit on error
set -e

: "${BITCART_HOST?Error: BITCART_HOST environment variable is not set}"
: "${BITCART_ADMIN_EMAIL?Error: BITCART_ADMIN_EMAIL environment variable is not set}"
: "${BITCART_ADMIN_PASSWORD?Error: BITCART_ADMIN_PASSWORD environment variable is not set}"
: "${CASHOUT_LIGHTNING_ADDRESS?Error: CASHOUT_LIGHTNING_ADDRESS environment variable is not set}"

# Some environment vars you need to set prior to calling the script
# Critical settings, must be included
#export BITCART_HOST=myhost.mywebsite.com
#export BITCART_ADMIN_EMAIL=somebody@website.com
#export BITCART_ADMIN_PASSWORD=mypassword

# Required for email notificiations
#export SMTP_SERVER=''
#export SMTP_PORT=''
#export SMTP_TLS='' # True or False
#export SMTP_SSL='' # True or False
#export SMTP_USERNAME=''
#export SMTP_PASSWORD=''

# Source repos for the bitcart-docker source-build path. Override any of
# these to deploy from a different fork or branch. Note: the SDK source
# is pinned in the bitcart fork's pyproject.toml, not here.
: "${BITCART_REPO_URL:=https://github.com/BareBits/bitcart.git}"
: "${BITCART_REPO_BRANCH:=lnd-integration}"
: "${BITCART_ADMIN_REPO_URL:=https://github.com/BareBits/bitcart-admin.git}"
: "${BITCART_ADMIN_REPO_BRANCH:=lnd-integration}"
: "${BITCART_DOCKER_REPO_URL:=https://github.com/BareBits/bitcart-docker-lnd.git}"
: "${BITCART_DOCKER_REPO_BRANCH:=master}"
: "${LIQUIDITYHELPER_REPO_URL:=https://github.com/BareBits/bitcart_liquidity.git}"
: "${LIQUIDITYHELPER_REPO_BRANCH:=main}"
export BITCART_REPO_URL BITCART_REPO_BRANCH
export BITCART_ADMIN_REPO_URL BITCART_ADMIN_REPO_BRANCH

# Enable the source-build path in bitcart-docker — clones the forks above
# at deploy time and rebuilds the bitcart/* :stable images locally.
export BITCART_SOURCE_BUILD=true

# Coin daemons. btc = electrum-based, btclnd = LND neutrino-based.
# Both run alongside each other.
export BITCART_CRYPTOS=btc,btclnd
export BTC_LIGHTNING=True
export BTC_LIGHTNING_LISTEN=0.0.0.0:9735
# used to include tor here but no longer do because it broke setup process
export BITCART_ADDITIONAL_COMPONENTS=btc-ln
export BTC_LIGHTNING_GOSSIP=true
export BITCARTGEN_DOCKER_IMAGE=bitcart/docker-compose-generator:local
export BITCART_BITCOIN_EXPOSE=true
export BTC_DEBUG=true
export ALLOW_INCOMING_CHANNELS=true

# BTCLND daemon configuration. All env-overridable.
: "${BTCLND_NETWORK:=mainnet}"
: "${BTCLND_DEBUG:=false}"
: "${BTCLND_TOR:=auto}"
: "${BTCLND_NEUTRINO_PEERS:=}"
: "${BTCLND_LND_EXTRA_ARGS:=}"
: "${BTCLND_EXTERNAL_IP:=}"
: "${BTCLND_LND_BINARY:=}"
# BTCLND p2p port pool. Defaults give 20 wallets at 9755-9774, skipping
# 9735 which the electrum btc daemon already publishes. To enlarge the
# pool, raise BTCLND_P2P_POOL_SIZE; the firewall rule and the docker
# port mapping are derived below so they stay aligned.
: "${BTCLND_BASE_P2P_PORT:=9755}"
: "${BTCLND_P2P_POOL_SIZE:=20}"
export BTCLND_P2P_PORT_RANGE_END=$((BTCLND_BASE_P2P_PORT + BTCLND_P2P_POOL_SIZE - 1))
export BTCLND_NETWORK BTCLND_DEBUG BTCLND_TOR BTCLND_NEUTRINO_PEERS
export BTCLND_LND_EXTRA_ARGS BTCLND_EXTERNAL_IP BTCLND_LND_BINARY
export BTCLND_BASE_P2P_PORT

export SMTP_FROM_EMAIL=$BITCART_ADMIN_EMAIL
export SMTP_TO_EMAIL=$BITCART_ADMIN_EMAIL

chmod +x run.sh
chmod +x update_liquidityhelper.sh

# enable automatic updates
apt install unattended-upgrades -y
echo unattended-upgrades unattended-upgrades/enable_auto_updates boolean true | debconf-set-selections
dpkg-reconfigure -f noninteractive unattended-upgrades

# configure firewall
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 3000/tcp
ufw allow 4000/tcp
ufw allow 8000/tcp
# lightning (electrum btc daemon)
ufw allow 9735/tcp
# lightning (BTCLND wallets — one port per LND instance, see BTCLND_*_PORT vars above)
ufw allow "$BTCLND_BASE_P2P_PORT:$BTCLND_P2P_PORT_RANGE_END/tcp"
# electrum
ufw deny 5000/tcp
ufw reload

# install bitcart
apt-get update && apt-get install -y git htop iotop python3-venv rsync
mkdir -p /opt
cd /opt
BITCART_DOCKER_DIR="$(basename "$BITCART_DOCKER_REPO_URL" .git)"
if [ -d "$BITCART_DOCKER_DIR" ]; then
    echo "existing $BITCART_DOCKER_DIR folder found, pulling instead of cloning."
    cd "$BITCART_DOCKER_DIR"
    git fetch origin "$BITCART_DOCKER_REPO_BRANCH"
    git checkout "$BITCART_DOCKER_REPO_BRANCH"
    git pull --ff-only
    cd ..
else
    echo "cloning $BITCART_DOCKER_REPO_URL @ $BITCART_DOCKER_REPO_BRANCH"
    git clone -b "$BITCART_DOCKER_REPO_BRANCH" "$BITCART_DOCKER_REPO_URL" "$BITCART_DOCKER_DIR"
fi
cd "$BITCART_DOCKER_DIR"
./setup.sh
cd ..

# install liquidityhelper
cd /opt
LIQUIDITYHELPER_DIR="$(basename "$LIQUIDITYHELPER_REPO_URL" .git)"
if [ -d "$LIQUIDITYHELPER_DIR" ]; then
    echo "existing $LIQUIDITYHELPER_DIR folder found, pulling instead of cloning."
    cd "$LIQUIDITYHELPER_DIR"
    git pull --ff-only
    cd ..
else
    echo "cloning $LIQUIDITYHELPER_REPO_URL @ $LIQUIDITYHELPER_REPO_BRANCH"
    git clone -b "$LIQUIDITYHELPER_REPO_BRANCH" "$LIQUIDITYHELPER_REPO_URL" "$LIQUIDITYHELPER_DIR"
fi

# set variables
cd "$LIQUIDITYHELPER_DIR"
touch user_config.py

# manual variables
echo "SMTP_TO_EMAIL='$BITCART_ADMIN_EMAIL'">>user_config.py
echo "SMTP_FROM_EMAIL='$BITCART_ADMIN_EMAIL'">>user_config.py

if [[ "$BITCART_SMTP_SSL" == "TRUE" ]]; then
    echo "SMTP_SSL=True">>user_config.py
else
    echo "SMTP_SSL=False">>user_config.py
fi
if [[ "$BITCART_SMTP_TLS" == "TRUE" ]]; then
    echo "SMTP_TLS=True">>user_config.py
else
    echo "SMTP_TLS=False">>user_config.py
fi

# automatic vars:
skip=("BITCART_SMTP_TLS" "BITCART_SMTP_SSL") # skip these vars
for var in $(compgen -v BITCART_); do
    # Strip the BITCART_ prefix from the variable name
    key="${var#BITCART_}"
    if [[ " ${skip[*]} " == *" ${var} "* ]]; then
        continue
    fi
    # Write the key=value pair to the file
    echo "${key}=${!var}" >> user_config.py
done

python3 -m venv .venv
source .venv/bin/activate
which python
pip install -r requirements.txt

# setup automatic run of liquidityhelper
set -euo pipefail

UNIT_FILE="/etc/systemd/system/liquidityhelper.service"

echo "Creating systemd unit file at ${UNIT_FILE}..."

cat > "${UNIT_FILE}" << 'EOF'
[Unit]
Description=LiquidityHelper
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/opt/deploy_bitcart_liquidity_lnd/run.sh

# Restart behaviour
Restart=always
RestartSec=60

# Give up after 10 retries (StartLimitBurst) within a 700s window
# Window = RestartSec * (StartLimitBurst + 1) = 60 * 11 = 660s, using 700s for headroom
StartLimitIntervalSec=700
StartLimitBurst=10

[Install]
WantedBy=multi-user.target
EOF

echo "Reloading systemd daemon..."
systemctl daemon-reload
echo "Waiting for bitcart to start..."
sleep 60
echo "Enabling service to start at boot..."
systemctl enable liquidityhelper.service
systemctl start liquidityhelper.service

echo ""
echo "Done. Service 'liquidityhelper' is installed and enabled."
echo ""
echo "Useful commands:"
echo "  Start now:    systemctl start liquidityhelper"
echo "  Check status: systemctl status liquidityhelper"
echo "  View logs:    journalctl -u liquidityhelper -f"
echo "  Disable:      systemctl disable liquidityhelper"


# setup automatic updates.
# bitcart-docker's update.sh git-pulls the source repos, runs
# `docker compose pull` for non-source-built images (postgres, redis,
# nginx, store, etc.), and then rebuilds the locally-tagged :stable
# images via build-custom-images.sh. That single command covers
# everything dockcheck would have done plus the source rebuild — no
# separate dockcheck cron is needed.
cat > /etc/cron.d/bitcart_updates <<EOF
# Daily 01:30 UTC: pull non-source images and rebuild source images.
30 1 * * * root cd /opt/$BITCART_DOCKER_DIR && ./update.sh > /var/log/bitcartupdate.log 2>&1
# Monthly: refresh liquidityhelper from git
1 1 1 * * root /opt/deploy_bitcart_liquidity_lnd/update_liquidityhelper.sh > /var/log/liquidityhelperupdate.log 2>&1
EOF


