#!/bin/bash
# Hardened auto-updater for the liquidityhelper Bitcart plugin.
#
# This is the host-side half of the auto-update system (see the plugin
# repo's AUTOUPDATE_DESIGN.md, §6). It runs from cron, entirely OUTSIDE
# the bitcart containers, so it survives any plugin crash by construction
# — a plugin that fails to import cannot break this script, which is the
# whole point: a broken release can still be replaced by the next one.
#
# What it does, in order:
#   1. Single-flights via a lockfile.
#   2. Reads the EFFECTIVE config (auto-update on/off + channel) by
#      querying the plugin's /health endpoint, falling back to the
#      compose env file when the plugin is unreachable.
#   3. GATE: if automatic updates are OFF (the default), it does nothing.
#      Detection + operator email are the plugin's job in that mode.
#   4. Fetches the channel branch, picks the tip as the candidate, and
#      skips it if it's on the ban-list (a release that previously failed
#      to start). Only a NEWER, non-banned commit is ever applied.
#   5. Applies: checks out the candidate, syncs it into compose/plugins,
#      and rebuilds+restarts via bitcart-docker's update.sh.
#   6. HEALTH-GATES the result by polling /health until the plugin reports
#      it actually started (worker tick loop alive).
#   7. On failed start: BANS the candidate, ROLLS BACK to the previous
#      good commit (rebuild from source — decoupled from bitcart-docker's
#      image internals), and re-checks. Records the outcome.
#
# IMPORTANT POLICY: AUTO_UPDATE_ENABLED gates ALL automatic updates on
# this host (plugin AND the chained bitcart-core update.sh). Off by
# default — existing deployments must opt in by setting
# LIQUIDITYHELPER_AUTO_UPDATE_ENABLED=true. This is deliberate: no
# surprise rebuilds/restarts on a fund-moving node unless the operator
# asked for them.
#
# Usage: update_liquidityhelper.sh [plugin_src_dir] [bitcart_docker_dir] [bitcart_host]
#   bitcart_host  used to build the /health URL; falls back to $BITCART_HOST
#                 env, then to $HEALTH_URL env if set directly.
set -euo pipefail

PLUGIN_DIR="${1:-/opt/bitcart_liquidity_lnd}"
DOCKER_DIR="${2:-/opt/bitcart-docker-lnd}"
BITCART_HOST_ARG="${3:-${BITCART_HOST:-}}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LH_ENV_FILE="$DOCKER_DIR/compose/liquidityhelper.env"
STATE_DIR="$SELF_DIR/update_state"
BANNED_FILE="$STATE_DIR/banned"
RESULT_FILE="$STATE_DIR/last_result"
LOCK_FILE="$STATE_DIR/update.lock"

# How long to wait for the plugin to come up after a rebuild+restart
# before declaring a failed start. The rebuild itself takes minutes;
# after restart the worker ticks within seconds, so 5 min is ample.
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"
HEALTH_POLL_INTERVAL="${HEALTH_POLL_INTERVAL:-10}"

mkdir -p "$STATE_DIR"

log() { echo "$(date -u +%FT%TZ) liquidityhelper-update: $*"; }

# Build the health URL. Prefer an explicit HEALTH_URL env; else derive
# from the bitcart host. Empty when we have neither — health-gating then
# degrades to "best effort" (see health_ok / apply).
HEALTH_URL="${HEALTH_URL:-}"
if [ -z "$HEALTH_URL" ] && [ -n "$BITCART_HOST_ARG" ]; then
    HEALTH_URL="https://${BITCART_HOST_ARG}/api/plugins/liquidityhelper/health"
fi

# ---------------------------------------------------------------------------
# Config + small helpers
# ---------------------------------------------------------------------------

# Read a LIQUIDITYHELPER_* value from the compose env file (KEY=value,
# unquoted). Echoes empty if absent.
env_file_value() {
    local key="$1"
    [ -f "$LH_ENV_FILE" ] || return 0
    grep -E "^${key}=" "$LH_ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Pull a flat JSON string field's value: json_str <json> <key>
json_str() {
    printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
        | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/'
}
# Pull a flat JSON bool/number/keyword field: json_word <json> <key>
json_word() {
    printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*[A-Za-z0-9._-]*" \
        | head -1 | sed -E 's/.*:[[:space:]]*//'
}

# Resolve effective ENABLED + CHANNEL. Source of truth: the plugin's
# /health (honours live UI toggles); fall back to the compose env file
# when the plugin is down (DESIGN §6).
ENABLED=""
CHANNEL=""
read_effective_config() {
    local resp=""
    if [ -n "$HEALTH_URL" ]; then
        resp="$(curl -fsS --max-time 10 "$HEALTH_URL" 2>/dev/null || true)"
    fi
    if [ -n "$resp" ]; then
        ENABLED="$(json_word "$resp" auto_update_enabled)"
        CHANNEL="$(json_str  "$resp" update_channel)"
        log "config from /health: enabled=${ENABLED:-?} channel=${CHANNEL:-?}"
    fi
    # Fall back to the compose env file for anything /health didn't give us.
    [ -z "$ENABLED" ] && ENABLED="$(env_file_value LIQUIDITYHELPER_AUTO_UPDATE_ENABLED)"
    [ -z "$CHANNEL" ] && CHANNEL="$(env_file_value LIQUIDITYHELPER_UPDATE_CHANNEL)"
    # Normalise.
    ENABLED="$(printf '%s' "${ENABLED:-false}" | tr '[:upper:]' '[:lower:]')"
    CHANNEL="${CHANNEL:-main}"
    # Whitelist the channel → branch; anything else falls back to whatever
    # branch is currently checked out (never interpolate arbitrary input).
    case "$CHANNEL" in
        main|testing) : ;;
        *)
            local cur
            cur="$(git -C "$PLUGIN_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
            log "unknown channel '$CHANNEL'; falling back to current branch '$cur'"
            CHANNEL="$cur"
            ;;
    esac
}

is_banned() { [ -f "$BANNED_FILE" ] && grep -qxF "$1" "$BANNED_FILE"; }
ban()       { echo "$1" >> "$BANNED_FILE"; log "BANNED commit $1"; }

record_result() { echo "$(date -u +%FT%TZ) $*" > "$RESULT_FILE"; }

# Poll /health until the plugin reports it started (ok && worker_alive),
# or the timeout elapses. Returns 0 = healthy, 1 = failed/timed out.
# If we have no HEALTH_URL we can't verify — treat as healthy but warn,
# so a misconfigured host doesn't wedge into permanent rollback loops.
health_ok() {
    if [ -z "$HEALTH_URL" ]; then
        log "WARNING: no HEALTH_URL — cannot verify plugin start; assuming OK"
        return 0
    fi
    local deadline=$(( SECONDS + HEALTH_TIMEOUT )) resp=""
    while [ "$SECONDS" -lt "$deadline" ]; do
        resp="$(curl -fsS --max-time 10 "$HEALTH_URL" 2>/dev/null || true)"
        if [ -n "$resp" ] \
           && [ "$(json_word "$resp" ok)" = "true" ] \
           && [ "$(json_word "$resp" worker_alive)" = "true" ]; then
            return 0
        fi
        sleep "$HEALTH_POLL_INTERVAL"
    done
    return 1
}

# Sync the current plugin source into compose/plugins and rebuild+restart
# via bitcart-docker's update.sh (which also pulls bitcart core). Both
# steps are required for new code to take effect.
rebuild() {
    "$SELF_DIR/sync_plugin_code.sh" "$PLUGIN_DIR" "$DOCKER_DIR"
    ( cd "$DOCKER_DIR" && ./update.sh )
}

# ---------------------------------------------------------------------------
# Main, under a non-blocking lock so overlapping cron runs can't collide.
# ---------------------------------------------------------------------------
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "another update run holds the lock; exiting"
    exit 0
fi

read_effective_config

if [ "$ENABLED" != "true" ]; then
    log "automatic updates are OFF (LIQUIDITYHELPER_AUTO_UPDATE_ENABLED); nothing to do"
    exit 0
fi

cd "$PLUGIN_DIR"
old_branch="$(git rev-parse --abbrev-ref HEAD)"
old_head="$(git rev-parse HEAD)"

git fetch --quiet origin "$CHANNEL"
candidate="$(git rev-parse "origin/$CHANNEL")"

# Case A: no new plugin commit on the channel. Still rebuild so bitcart
# CORE updates keep flowing (parity with the old daily cron), then
# health-check. No plugin rollback here — nothing plugin-side changed.
if [ "$candidate" = "$old_head" ] && [ "$CHANNEL" = "$old_branch" ]; then
    log "no plugin update on '$CHANNEL' ($old_head); running core update + health check"
    rebuild
    if health_ok; then
        log "core update healthy"
        record_result "OK core-only $old_head channel=$CHANNEL"
    else
        log "ERROR: plugin unhealthy after core update — NOT auto-reverting core (out of scope). Investigate."
        record_result "FAIL core-update-unhealthy head=$old_head channel=$CHANNEL"
        exit 1
    fi
    exit 0
fi

# Case B: a candidate exists. Refuse it if it's banned (a prior bad
# release). We stay on the current good commit until a NEWER, non-banned
# commit lands.
if is_banned "$candidate"; then
    log "candidate $candidate on '$CHANNEL' is BANNED; staying on $old_head"
    record_result "SKIP banned-candidate $candidate channel=$CHANNEL"
    exit 0
fi

log "applying $old_branch@$old_head -> $CHANNEL@$candidate"
# Force the local channel branch to the candidate tip. Deploys carry no
# local commits (sync copies OUT of the repo), so this is safe.
git checkout --quiet -B "$CHANNEL" "$candidate"

rebuild

if health_ok; then
    log "update to $candidate healthy"
    record_result "OK applied $candidate channel=$CHANNEL from=$old_head"
    exit 0
fi

# Failed to start → ban + roll back to the previous good commit and
# rebuild from that source (decoupled from bitcart-docker image tags).
log "ERROR: plugin failed to start on $candidate — rolling back to $old_head"
ban "$candidate"
git checkout --quiet -B "$old_branch" "$old_head"
rebuild

if health_ok; then
    log "ROLLBACK to $old_head succeeded (banned $candidate)"
    record_result "ROLLBACK ok to=$old_head banned=$candidate channel=$CHANNEL"
else
    log "CRITICAL: rollback to $old_head also unhealthy — manual intervention needed"
    record_result "CRITICAL rollback-unhealthy to=$old_head banned=$candidate channel=$CHANNEL"
fi
exit 1
