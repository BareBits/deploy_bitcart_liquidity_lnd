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

# Email notifications. These set Bitcart's installation-wide SMTP (Server
# Management -> Policies); the liquidity plugin then notifies store owners
# through Bitcart's own email. Set the address with BITCART_SMTP_FROM_EMAIL
# (defaults to BITCART_SMTP_USERNAME).
#export BITCART_SMTP_SERVER=''
#export BITCART_SMTP_PORT=''
#export BITCART_SMTP_TLS='' # TRUE or FALSE (STARTTLS)
#export BITCART_SMTP_SSL='' # TRUE or FALSE (implicit SSL/TLS)
#export BITCART_SMTP_USERNAME=''
#export BITCART_SMTP_PASSWORD=''
#export BITCART_SMTP_FROM_EMAIL=''

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

# --- Deployment name (multi-instance) --------------------------------
# DEPLOY_NAME lets several Bitcart deployments coexist on one host. When
# set it names the docker compose project (via setup.sh --name) plus this
# script's per-instance docker checkout, container lookups, and cron file.
# When empty (default) behaviour is unchanged: a single instance managed
# by systemd. NAME_PREFIX matches the container-name prefix compose uses
# for a named project (e.g. "<name>-backend-1").
DEPLOY_NAME="${DEPLOY_NAME:-}"
NAME_PREFIX="${DEPLOY_NAME:+${DEPLOY_NAME}-}"
# Reverse proxy mode (setup.sh's default is nginx-https). Read here so the
# post-start API base URL matches how the API is exposed — with no bundled
# nginx (BITCART_REVERSEPROXY=none) the backend is reached directly.
REVERSEPROXY="${BITCART_REVERSEPROXY:-nginx-https}"

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
: "${LIQUIDITYHELPER_REPO_URL:=https://github.com/BareBits/bitcart_liquidity_lnd.git}"
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
# gRPC port pool, sized to match the p2p pool. Exported with its range end
# so a named instance can pick a non-colliding base; the generated
# compose's gRPC port mapping derives from these. (Previously only the
# p2p base/range was exported, so a custom gRPC base did not take effect.)
: "${BTCLND_BASE_GRPC_PORT:=10009}"
export BTCLND_GRPC_PORT_RANGE_END=$((BTCLND_BASE_GRPC_PORT + BTCLND_P2P_POOL_SIZE - 1))
export BTCLND_BASE_GRPC_PORT

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
BITCART_DOCKER_DIR="$(basename "$BITCART_DOCKER_REPO_URL" .git)${DEPLOY_NAME:+-$DEPLOY_NAME}"
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
if [ -n "$DEPLOY_NAME" ]; then
    # Named deployment: own compose project, no systemd — lifecycle is
    # managed by the caller (e.g. an orchestrator / docker compose).
    ./setup.sh --name "$DEPLOY_NAME" --no-startup-register
else
    ./setup.sh
fi

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
#
# Non-SMTP plugin settings are configured by exporting their
# LIQUIDITYHELPER_* vars in the installer — they are forwarded verbatim by
# the loop below, and config.py parses the types. SMTP is NOT a plugin
# setting anymore: the plugin notifies store owners through Bitcart's own
# installation-wide SMTP, which the post-start step below sets from
# BITCART_SMTP_*.
LH_ENV_FILE="$DOCKER_DIR/compose/liquidityhelper.env"
{
    printf 'LIQUIDITYHELPER_CASHOUT_LIGHTNING_ADDRESS=%s\n' "$CASHOUT_LIGHTNING_ADDRESS"
    printf 'LIQUIDITYHELPER_ADMIN_EMAIL=%s\n' "$BITCART_ADMIN_EMAIL"
    printf 'LIQUIDITYHELPER_ADMIN_PASSWORD=%s\n' "$BITCART_ADMIN_PASSWORD"
} > "$LH_ENV_FILE"

# Forward any operator-set LIQUIDITYHELPER_*-prefixed env vars verbatim so
# the single-line installer (or an operator) can configure ANY plugin
# setting at deploy time — config.py applies them as settings overrides.
# The deploy itself sets NO liquidity mode, so a bare deploy leaves the
# plugin in its default (liquidity management disabled); the documented
# single-line command opts into automatic channel management by exporting
# LIQUIDITYHELPER_LIQUIDITY_DISABLED=False +
# LIQUIDITYHELPER_AUTOMATIC_CHANNEL_CREATION_ENABLED=True. Exclude the
# deploy's own repo-pin vars, which are not plugin settings.
while IFS= read -r _lhvar; do
    case "$_lhvar" in
        LIQUIDITYHELPER_REPO_URL|LIQUIDITYHELPER_REPO_BRANCH) continue ;;
    esac
    printf '%s=%s\n' "$_lhvar" "${!_lhvar}" >> "$LH_ENV_FILE"
done < <(compgen -e | grep '^LIQUIDITYHELPER_' || true)
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

# --- Post-start settle ------------------------------------------------
# On first boot the plugin's startup/worker hooks can run before the
# backend gunicorn is accepting connections, so the admin/token bootstrap
# fails. The plugin retries this on its own (bitcart_liquidity_lnd), but
# we also (a) wait here so the deploy doesn't return on a half-started
# stack, and (b) as a fallback — e.g. an older plugin build without the
# retry — restart the WORKER ONLY once the API is up so the bootstrap
# re-runs against the (already-up) backend. We deliberately do not restart
# the backend too: that would put the backend back into its not-ready
# window and re-create the very race we're recovering from. The token row
# (app_id=plugin:liquidityhelper) is the signal that the admin + token
# were created.
# API base for the post-start steps. With an external/no reverse proxy the
# public nginx (port 80) is absent, so talk to the backend directly — its
# API is served WITHOUT the /api prefix that nginx adds in front.
if [ "$REVERSEPROXY" = "nginx" ] || [ "$REVERSEPROXY" = "nginx-https" ]; then
    API_BASE="http://localhost/api"
else
    API_BASE="http://localhost:${BITCART_BACKEND_PORT:-8000}"
fi

echo "Waiting for the backend API to accept connections..."
api_ready=false
for _ in $(seq 1 60); do
    if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$API_BASE/cryptos" 2>/dev/null)" = "200" ]; then
        api_ready=true; break
    fi
    sleep 5
done
if [ "$api_ready" = true ]; then
    echo "Backend API is up; waiting for the plugin to bootstrap the admin + token..."
    db_cid="$(docker ps -qf name=${NAME_PREFIX}database)"
    token_present=false
    for _ in $(seq 1 24); do  # up to ~2 min
        if [ "$(docker exec "$db_cid" psql -U postgres -d bitcart -tAc \
                "select 1 from tokens where app_id='plugin:liquidityhelper' limit 1" \
                2>/dev/null | tr -d '[:space:]')" = "1" ]; then
            token_present=true; break
        fi
        sleep 5
    done
    if [ "$token_present" = true ]; then
        echo "Plugin bootstrapped (admin user + token present)."
    else
        echo "Plugin token still absent — restarting the worker only (backend stays up) to re-run the bootstrap against the ready API."
        docker restart "$(docker ps -qf name=${NAME_PREFIX}worker)" >/dev/null 2>&1 || true
        # The worker re-runs worker_setup on start; with the backend already
        # accepting connections the bootstrap now succeeds. Wait for the
        # token so the SMTP step below has an admin to authenticate as.
        for _ in $(seq 1 24); do  # up to ~2 min
            if [ "$(docker exec "$db_cid" psql -U postgres -d bitcart -tAc \
                    "select 1 from tokens where app_id='plugin:liquidityhelper' limit 1" \
                    2>/dev/null | tr -d '[:space:]')" = "1" ]; then
                token_present=true; break
            fi
            sleep 5
        done
        if [ "$token_present" = true ]; then
            echo "Plugin bootstrapped (admin user + token present)."
        else
            echo "WARNING: plugin token still absent after a worker restart. The admin may need a manual 'docker restart \$(docker ps -qf name=worker)' once the backend is fully up — check 'docker logs \$(docker ps -qf name=worker)'."
        fi
    fi
else
    echo "WARNING: backend API did not come up within the wait window. The plugin may need a manual restart once it does — check 'docker logs \$(docker ps -qf name=backend)'."
fi

# --- Bitcart installation-wide SMTP -----------------------------------
# Set Bitcart's server Policy email settings from BITCART_SMTP_*, so the
# whole installation — and the liquidity plugin's store-owner
# notifications — can send email. Done over the API as the admin; the POST
# merges (only email_settings is changed). Skipped if BITCART_SMTP_* aren't
# provided. JSON is built with python3 to escape values safely.
if [ -n "${BITCART_SMTP_SERVER:-}" ] && [ -n "${BITCART_SMTP_USERNAME:-}" ] && [ -n "${BITCART_SMTP_PASSWORD:-}" ]; then
    echo "Configuring Bitcart installation-wide SMTP (server policy)..."
    # auth_mode: implicit SSL takes precedence over STARTTLS; neither -> none.
    _smtp_mode=none
    case "${BITCART_SMTP_TLS:-}" in TRUE|true|1|YES|yes|ON|on) _smtp_mode=starttls ;; esac
    case "${BITCART_SMTP_SSL:-}" in TRUE|true|1|YES|yes|ON|on) _smtp_mode=ssl/tls ;; esac
    export _SMTP_MODE="$_smtp_mode"
    export _SMTP_FROM="${BITCART_SMTP_FROM_EMAIL:-$BITCART_SMTP_USERNAME}"
    # Get a full_control admin token (retry — the API/admin may still be
    # settling, e.g. after a restart above).
    _tok=""
    for _ in $(seq 1 12); do
        _tok=$(curl -s --max-time 15 -X POST "$API_BASE/token" \
            -H 'Content-Type: application/json' \
            -d "$(python3 -c "import json,os; print(json.dumps({'email':os.environ['BITCART_ADMIN_EMAIL'],'password':os.environ['BITCART_ADMIN_PASSWORD'],'permissions':['full_control']}))")" \
            2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token') or d.get('id') or '')" 2>/dev/null)
        [ -n "$_tok" ] && break
        sleep 5
    done
    if [ -n "$_tok" ]; then
        _payload=$(python3 -c "import json,os; print(json.dumps({'email_settings':{'host':os.environ['BITCART_SMTP_SERVER'],'port':int(os.environ.get('BITCART_SMTP_PORT') or 587),'user':os.environ['BITCART_SMTP_USERNAME'],'password':os.environ['BITCART_SMTP_PASSWORD'],'address':os.environ['_SMTP_FROM'],'auth_mode':os.environ['_SMTP_MODE']}}))")
        _code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST "$API_BASE/manage/policies" \
            -H 'Content-Type: application/json' -H "Authorization: Bearer $_tok" -d "$_payload")
        if [ "$_code" = "200" ]; then
            echo "Bitcart installation-wide SMTP configured."
        else
            echo "WARNING: setting the Bitcart SMTP policy returned HTTP $_code. Configure it in Server Management -> Policies."
        fi
    else
        echo "WARNING: could not obtain an admin token; Bitcart SMTP policy not set. Configure it in Server Management -> Policies."
    fi
fi

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
cat > "/etc/cron.d/bitcart_updates${DEPLOY_NAME:+_$DEPLOY_NAME}" <<EOF
# Daily 01:30 UTC: refresh the liquidity plugin (commit-gated), then
# update bitcart (which rebuilds the plugin images when the re-sync
# changed them).
30 1 * * * root $DEPLOY_DIR/update_liquidityhelper.sh "$PLUGIN_DIR" "$DOCKER_DIR" >> /var/log/liquidityhelperupdate.log 2>&1 && cd $DOCKER_DIR && ./update.sh >> /var/log/bitcartupdate.log 2>&1
EOF

echo ""
echo "Done. Bitcart is deployed with the liquidityhelper plugin baked in."
echo ""
echo "  Admin UI:        https://$BITCART_HOST/  (Plugins -> liquidityhelper)"
echo "  Plugin settings: $LH_ENV_FILE  (LIQUIDITYHELPER_* env)"
echo "  Daily updates:   /etc/cron.d/bitcart_updates"
echo ""
echo "Useful commands:"
echo "  Backend logs:    docker logs -f \$(docker ps -qf name=${NAME_PREFIX}backend)"
echo "  Refresh plugin:  $DEPLOY_DIR/update_liquidityhelper.sh $PLUGIN_DIR $DOCKER_DIR && (cd $DOCKER_DIR && ./update.sh)"
