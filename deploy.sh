#!/bin/bash
# Must be run as root

# Exit on error
set -e

: "${BITCART_HOST?Error: BITCART_HOST environment variable is not set}"
: "${BITCART_ADMIN_EMAIL?Error: BITCART_ADMIN_EMAIL environment variable is not set}"
: "${BITCART_ADMIN_PASSWORD?Error: BITCART_ADMIN_PASSWORD environment variable is not set}"
: "${CASHOUT_LIGHTNING_ADDRESS?Error: CASHOUT_LIGHTNING_ADDRESS environment variable is not set}"

# Resolve this deploy checkout's directory NOW, before any `cd` below
# changes the working directory. BASH_SOURCE[0] may be relative (e.g.
# "./deploy.sh"), so it must be resolved from the original CWD.
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Some environment vars you need to set prior to calling the script
# Critical settings, must be included
#export BITCART_HOST=myhost.mywebsite.com
#export BITCART_ADMIN_EMAIL=somebody@website.com
#export BITCART_ADMIN_PASSWORD=mypassword

# Required for email notifications. These map onto the liquidity plugin's
# SMTP_* settings (see the plugin env file built below).
#export BITCART_SMTP_SERVER=''
#export BITCART_SMTP_PORT=''
#export BITCART_SMTP_TLS='' # TRUE or FALSE
#export BITCART_SMTP_SSL='' # TRUE or FALSE
#export BITCART_SMTP_USERNAME=''
#export BITCART_SMTP_PASSWORD=''

# git is needed immediately (branch probing + cloning the repos below).
command -v git >/dev/null 2>&1 || { apt-get update && apt-get install -y git; }

# --- Release channel / branch selection ------------------------------
# BRANCH picks which line of development to deploy across ALL BareBits
# forks: "main" (default — the stable pinned branches) or "testing".
# When BRANCH=testing, each fork uses its own `testing` branch IF that
# branch exists on that repo, otherwise it falls back to the repo's
# default. This lets a testing branch exist on only some repos. Per-repo
# *_REPO_BRANCH overrides set before this script still win.
BRANCH="${BRANCH:-main}"

resolve_branch() {
    # resolve_branch <repo_url> <default_branch>
    # Echoes "testing" when BRANCH=testing and the repo actually has a
    # testing branch; otherwise echoes the default. Always returns 0.
    local url="$1" default="$2"
    if [ "$BRANCH" = "testing" ] && git ls-remote --heads "$url" testing 2>/dev/null | grep -q .; then
        printf 'testing'
    else
        printf '%s' "$default"
    fi
}

# Source repos for the bitcart-docker source-build path. Override any of
# these to deploy from a different fork or branch. Note: the SDK source
# is pinned in the bitcart fork's pyproject.toml, not here.
: "${BITCART_REPO_URL:=https://github.com/BareBits/bitcart.git}"
: "${BITCART_REPO_BRANCH:=$(resolve_branch "$BITCART_REPO_URL" lnd-integration)}"
: "${BITCART_ADMIN_REPO_URL:=https://github.com/BareBits/bitcart-admin.git}"
: "${BITCART_ADMIN_REPO_BRANCH:=$(resolve_branch "$BITCART_ADMIN_REPO_URL" lnd-integration)}"
: "${BITCART_DOCKER_REPO_URL:=https://github.com/BareBits/bitcart-docker-lnd.git}"
: "${BITCART_DOCKER_REPO_BRANCH:=$(resolve_branch "$BITCART_DOCKER_REPO_URL" master)}"
: "${LIQUIDITYHELPER_REPO_URL:=https://github.com/BareBits/bitcart_liquidity.git}"
: "${LIQUIDITYHELPER_REPO_BRANCH:=$(resolve_branch "$LIQUIDITYHELPER_REPO_URL" main)}"
export BITCART_REPO_URL BITCART_REPO_BRANCH
export BITCART_ADMIN_REPO_URL BITCART_ADMIN_REPO_BRANCH

# Enable the source-build path in bitcart-docker — clones the forks above
# at deploy time and rebuilds the bitcart/* :stable images locally.
export BITCART_SOURCE_BUILD=true

# Coin daemons. btc = electrum-based, btclnd = LND neutrino-based.
# Both run alongside each other. The liquidity plugin auto-prefers the
# LND (btclnd) wallet whenever Bitcart advertises it (it does here), so
# no wallet-type setting is needed — see the plugin's
# _detect_preferred_wallet_currency().
export BITCART_CRYPTOS=btc,btclnd
export BTC_LIGHTNING=True
export BTC_LIGHTNING_LISTEN=0.0.0.0:9735
# used to include tor here but no longer do because it broke setup process
export BITCART_ADDITIONAL_COMPONENTS=btc-ln
export BTC_LIGHTNING_GOSSIP=true
export BITCARTGEN_DOCKER_IMAGE=bitcart/docker-compose-generator:local
# Do not publish the btc daemon's port 5000 to the host — Docker bypasses
# ufw, so a published port is internet-reachable regardless of firewall
# rules. The bitcart backend talks to the daemon over the docker network
# at http://bitcoin:5000, so external publishing serves no purpose.
#export BITCART_BITCOIN_EXPOSE=true
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

# install prerequisites
apt-get update && apt-get install -y git htop iotop python3-venv rsync
mkdir -p /opt

# clone or update bitcart-docker. We do NOT build yet — the liquidity
# plugin is baked into compose/plugins below first, then setup.sh builds
# everything in one pass.
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
DOCKER_DIR="/opt/$BITCART_DOCKER_DIR"

# clone or update the liquidity plugin source
cd /opt
LIQUIDITYHELPER_DIR="$(basename "$LIQUIDITYHELPER_REPO_URL" .git)"
if [ -d "$LIQUIDITYHELPER_DIR/.git" ]; then
    echo "existing $LIQUIDITYHELPER_DIR found, pulling @ $LIQUIDITYHELPER_REPO_BRANCH"
    cd "$LIQUIDITYHELPER_DIR"
    git fetch origin "$LIQUIDITYHELPER_REPO_BRANCH"
    git checkout "$LIQUIDITYHELPER_REPO_BRANCH"
    git pull --ff-only
    cd ..
else
    echo "cloning $LIQUIDITYHELPER_REPO_URL @ $LIQUIDITYHELPER_REPO_BRANCH"
    git clone -b "$LIQUIDITYHELPER_REPO_BRANCH" "$LIQUIDITYHELPER_REPO_URL" "$LIQUIDITYHELPER_DIR"
fi
PLUGIN_DIR="/opt/$LIQUIDITYHELPER_DIR"

# DEPLOY_DIR was resolved at the top of this script (before any cd).
chmod +x "$DEPLOY_DIR/sync_plugin_code.sh" "$DEPLOY_DIR/update_liquidityhelper.sh"

# Build + start the base bitcart stack FIRST, with an empty
# compose/plugins tree. setup.sh records the current (empty) plugin hash
# in .deploy; the plugin is layered on AFTER, so bitcart-docker's
# install_plugins sees a changed compose/plugins hash and actually bakes
# it. If the plugin is already present before setup.sh, setup.sh's early
# save_deploy_config records the populated hash, install_plugins (run by
# start.sh, a fresh process that re-reads .deploy) finds no change, and
# the plugin layer is silently skipped.
cd "$DOCKER_DIR"
./setup.sh

# Bake the plugin in: sync the engine + admin module into compose/plugins,
# write the runtime env file + the compose component that wires it into
# the backend + worker containers, then regenerate compose and start.
# start.sh -> install_plugins now sees the changed plugin hash and builds
# the backend (engine) and admin (Vue) plugin layers on top of the base
# images, then restarts. No source rebuild — this is the fast path.
"$DEPLOY_DIR/sync_plugin_code.sh" "$PLUGIN_DIR" "$DOCKER_DIR"

# Plugin runtime config, delivered as LIQUIDITYHELPER_*-prefixed env vars
# loaded into the backend + worker containers via the auto-discovered
# docker component written below. config.py reads these (the prefix is
# required) with precedence: plugin-UI > env > user_config.py > defaults.
# On a fresh install the plugin also bootstraps the first Bitcart admin
# from ADMIN_EMAIL/ADMIN_PASSWORD.
lh_bool() { case "${1^^}" in TRUE|1|YES|ON) printf True;; *) printf False;; esac; }
LH_ENV_FILE="$DOCKER_DIR/compose/liquidityhelper.env"
{
    printf 'LIQUIDITYHELPER_CASHOUT_LIGHTNING_ADDRESS=%s\n' "$CASHOUT_LIGHTNING_ADDRESS"
    printf 'LIQUIDITYHELPER_ADMIN_EMAIL=%s\n' "$BITCART_ADMIN_EMAIL"
    printf 'LIQUIDITYHELPER_ADMIN_PASSWORD=%s\n' "$BITCART_ADMIN_PASSWORD"
    printf 'LIQUIDITYHELPER_SMTP_FROM_EMAIL=%s\n' "$BITCART_ADMIN_EMAIL"
    printf 'LIQUIDITYHELPER_SMTP_TO_EMAIL=%s\n' "$BITCART_ADMIN_EMAIL"
    [ -n "${BITCART_SMTP_SERVER:-}" ]   && printf 'LIQUIDITYHELPER_SMTP_SERVER=%s\n' "$BITCART_SMTP_SERVER"
    [ -n "${BITCART_SMTP_PORT:-}" ]     && printf 'LIQUIDITYHELPER_SMTP_PORT=%s\n' "$BITCART_SMTP_PORT"
    [ -n "${BITCART_SMTP_USERNAME:-}" ] && printf 'LIQUIDITYHELPER_SMTP_USERNAME=%s\n' "$BITCART_SMTP_USERNAME"
    [ -n "${BITCART_SMTP_PASSWORD:-}" ] && printf 'LIQUIDITYHELPER_SMTP_PASSWORD=%s\n' "$BITCART_SMTP_PASSWORD"
    printf 'LIQUIDITYHELPER_SMTP_TLS=%s\n' "$(lh_bool "${BITCART_SMTP_TLS:-}")"
    printf 'LIQUIDITYHELPER_SMTP_SSL=%s\n' "$(lh_bool "${BITCART_SMTP_SSL:-}")"
} > "$LH_ENV_FILE"
chmod 600 "$LH_ENV_FILE"

# Auto-discovered compose component: bitcart-docker's generator scans
# compose/plugins/docker/*/components/*.yml and merges them into the
# generated compose. This one attaches the env file above to the backend
# and worker services. The env_file path is relative to the generated
# compose file (compose/generated.yml), i.e. compose/liquidityhelper.env.
LH_COMPONENT_DIR="$DOCKER_DIR/compose/plugins/docker/liquidityhelper/components"
mkdir -p "$LH_COMPONENT_DIR"
cat > "$LH_COMPONENT_DIR/liquidityhelper.yml" <<'YML'
# Injects the liquidityhelper plugin's runtime settings (written by
# deploy.sh to compose/liquidityhelper.env) into the backend and worker
# containers. Auto-merged into compose/generated.yml by bitcart-docker's
# generator (get_plugin_components).
services:
  backend:
    env_file:
      - liquidityhelper.env
  worker:
    env_file:
      - liquidityhelper.env
YML

# Regenerate the compose (now including the env-file component) and start.
# install_plugins bakes the plugin layers because the compose/plugins hash
# now differs from the clean setup above.
./build.sh
./start.sh
cd /opt

# setup automatic updates.
# bitcart-docker's update.sh git-pulls the source repos, runs
# `docker compose pull` for non-source-built images (postgres, redis,
# nginx, store, etc.), and rebuilds the locally-tagged :stable images via
# build-custom-images.sh.
# update_liquidityhelper.sh refreshes the plugin source first, but is
# commit-gated: it only re-syncs into compose/plugins when the plugin
# repo actually moved. The subsequent update.sh then rebuilds the
# plugin's backend image and — only when the admin files changed — the
# admin image (yarn build), via bitcart-docker's plugin hash-diff. So an
# unchanged plugin adds no rebuild cost.
cat > /etc/cron.d/bitcart_updates <<EOF
# Daily 01:30 UTC: refresh the liquidity plugin (commit-gated), then
# update bitcart (which rebuilds the plugin images when the re-sync
# changed them).
30 1 * * * root $DEPLOY_DIR/update_liquidityhelper.sh >> /var/log/liquidityhelperupdate.log 2>&1 && cd $DOCKER_DIR && ./update.sh >> /var/log/bitcartupdate.log 2>&1
EOF

echo ""
echo "Done. Bitcart is deployed with the liquidityhelper plugin baked in."
echo ""
echo "  Admin UI:        https://$BITCART_HOST/  (Plugins -> liquidityhelper)"
echo "  Plugin settings: $LH_ENV_FILE  (LIQUIDITYHELPER_* env)"
echo "  Daily updates:   /etc/cron.d/bitcart_updates"
echo ""
echo "Useful commands:"
echo "  Backend logs:    docker logs -f \$(docker ps -qf name=backend)"
echo "  Refresh plugin:  $DEPLOY_DIR/update_liquidityhelper.sh && (cd $DOCKER_DIR && ./update.sh)"
