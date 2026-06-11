#!/bin/bash
# Standalone installer for the liquidityhelper auto-updater.
#
# For operators who already run bitcart-docker with the liquidityhelper
# plugin installed the NORMAL way (uploaded the .bitcartcc in the admin
# UI) and now want automatic updates — WITHOUT having used this repo's
# full deploy.sh. It sets up only the auto-update machinery the plugin
# can't do for itself (a plugin baked into a container image cannot
# durably update its own code — see AUTOUPDATE_DESIGN.md §1):
#
#   1. Clones the plugin SOURCE repo to /opt (the updater syncs from it).
#   2. Clones THIS deploy repo to /opt (for the updater scripts).
#   3. Installs the daily cron that runs the hardened updater.
#
# It changes nothing about your running deployment. Auto-updates stay OFF
# until you enable them (plugin UI → AUTO_UPDATE_ENABLED, or set
# LIQUIDITYHELPER_AUTO_UPDATE_ENABLED=true), so installing this is safe.
#
# One-line install (run as root / with sudo):
#   curl -fsSL https://raw.githubusercontent.com/BareBits/deploy_bitcart_liquidity_lnd/main/install_updater.sh \
#     | sudo bash -s -- --docker-dir /opt/bitcart-docker --host pay.example.com
#
# Re-runnable (idempotent): updates the clones + cron in place.
set -euo pipefail

# Base dirs (overridable for portability / testing).
OPT_DIR="${OPT_DIR:-/opt}"
CRON_DIR="${CRON_DIR:-/etc/cron.d}"

LIQUIDITYHELPER_REPO_URL="${LIQUIDITYHELPER_REPO_URL:-https://github.com/BareBits/bitcart_liquidity_lnd.git}"
DEPLOY_REPO_URL="${DEPLOY_REPO_URL:-https://github.com/BareBits/deploy_bitcart_liquidity_lnd.git}"

CHANNEL="main"
DEPLOY_NAME=""
DOCKER_DIR=""
BITCART_HOST=""

usage() {
    cat <<USAGE
Usage: install_updater.sh [options]
  --docker-dir DIR   bitcart-docker checkout (has update.sh + compose/ + .env).
                     Autodetected under /opt if omitted.
  --host HOST        Public bitcart host for the /health URL.
                     Read from <docker-dir>/.env (BITCART_HOST) if omitted.
  --channel NAME     Release channel: main (default) or testing.
  --name NAME        DEPLOY_NAME suffix, for multiple instances on one host.
  -h, --help         This help.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --docker-dir) DOCKER_DIR="$2"; shift 2 ;;
        --host)       BITCART_HOST="$2"; shift 2 ;;
        --channel)    CHANNEL="$2"; shift 2 ;;
        --name)       DEPLOY_NAME="$2"; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

log() { echo "$(date -u +%FT%TZ) install-updater: $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "must run as root (installs /etc/cron.d, clones into /opt). Re-run with sudo."

case "$CHANNEL" in main|testing) : ;; *) die "invalid --channel '$CHANNEL' (main|testing)";; esac
command -v git >/dev/null || die "git not found"

# --- Locate bitcart-docker ------------------------------------------------
if [ -z "$DOCKER_DIR" ]; then
    log "autodetecting bitcart-docker under $OPT_DIR ..."
    mapfile -t _cands < <(
        for d in "$OPT_DIR"/*/; do
            [ -f "${d}update.sh" ] && [ -d "${d}compose" ] && echo "${d%/}"
        done
    )
    if [ "${#_cands[@]}" -eq 1 ]; then
        DOCKER_DIR="${_cands[0]}"
        log "found $DOCKER_DIR"
    elif [ "${#_cands[@]}" -eq 0 ]; then
        die "no bitcart-docker dir found under $OPT_DIR; pass --docker-dir"
    else
        die "multiple candidates under $OPT_DIR (${_cands[*]}); pass --docker-dir"
    fi
fi
[ -f "$DOCKER_DIR/update.sh" ] && [ -d "$DOCKER_DIR/compose" ] \
    || die "$DOCKER_DIR doesn't look like a bitcart-docker checkout (no update.sh / compose/)"

# --- Resolve host for the /health URL ------------------------------------
if [ -z "$BITCART_HOST" ] && [ -f "$DOCKER_DIR/.env" ]; then
    BITCART_HOST="$(grep -E '^BITCART_HOST=' "$DOCKER_DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
fi
[ -n "$BITCART_HOST" ] || die "could not determine BITCART_HOST; pass --host"
log "bitcart host: $BITCART_HOST"

# --- resolve_branch: use 'testing' only if it actually exists on the repo -
resolve_branch() {
    local url="$1" default="$2"
    if [ "$CHANNEL" = "testing" ] && git ls-remote --heads "$url" testing 2>/dev/null | grep -q .; then
        echo testing
    else
        echo "$default"
    fi
}
PLUGIN_BRANCH="$(resolve_branch "$LIQUIDITYHELPER_REPO_URL" main)"
DEPLOY_BRANCH="$(resolve_branch "$DEPLOY_REPO_URL" main)"

# --- Clone/update the plugin source + this deploy repo into /opt ----------
clone_or_pull() {
    local url="$1" dir="$2" branch="$3"
    if [ -d "$dir/.git" ]; then
        log "updating $dir @ $branch"
        git -C "$dir" fetch --quiet origin "$branch"
        git -C "$dir" checkout --quiet -B "$branch" "origin/$branch"
    else
        log "cloning $url @ $branch -> $dir"
        git clone --quiet -b "$branch" "$url" "$dir"
    fi
}

PLUGIN_DIR="$OPT_DIR/$(basename "$LIQUIDITYHELPER_REPO_URL" .git)${DEPLOY_NAME:+-$DEPLOY_NAME}"
DEPLOY_DIR="$OPT_DIR/$(basename "$DEPLOY_REPO_URL" .git)${DEPLOY_NAME:+-$DEPLOY_NAME}"
clone_or_pull "$LIQUIDITYHELPER_REPO_URL" "$PLUGIN_DIR" "$PLUGIN_BRANCH"
clone_or_pull "$DEPLOY_REPO_URL" "$DEPLOY_DIR" "$DEPLOY_BRANCH"
chmod +x "$DEPLOY_DIR/update_liquidityhelper.sh" "$DEPLOY_DIR/sync_plugin_code.sh"

# --- Install the cron -----------------------------------------------------
CRON_FILE="$CRON_DIR/bitcart_updates${DEPLOY_NAME:+_$DEPLOY_NAME}"
cat > "$CRON_FILE" <<EOF
# Daily 01:30 UTC: gated, health-checked, self-rolling-back plugin+core
# update. No-op unless LIQUIDITYHELPER_AUTO_UPDATE_ENABLED=true (plugin UI
# or compose/liquidityhelper.env). Installed by install_updater.sh.
30 1 * * * root $DEPLOY_DIR/update_liquidityhelper.sh "$PLUGIN_DIR" "$DOCKER_DIR" "$BITCART_HOST" >> /var/log/liquidityhelperupdate.log 2>&1
EOF
log "installed cron: $CRON_FILE"

cat <<DONE

Done. The auto-updater is installed but DORMANT (auto-updates are off by default).

  Plugin source:  $PLUGIN_DIR  (channel: $CHANNEL)
  Updater:        $DEPLOY_DIR/update_liquidityhelper.sh
  Cron:           $CRON_FILE  (daily 01:30 UTC)

To ENABLE automatic updates, either:
  - Plugin UI: Plugins -> liquidityhelper -> Settings -> turn on auto-updates, or
  - add  LIQUIDITYHELPER_AUTO_UPDATE_ENABLED=true  to your plugin env and restart.

Run once now (respects the on/off setting):
  $DEPLOY_DIR/update_liquidityhelper.sh "$PLUGIN_DIR" "$DOCKER_DIR" "$BITCART_HOST"
DONE
