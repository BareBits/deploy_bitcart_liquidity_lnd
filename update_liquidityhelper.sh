#!/bin/bash
# Commit-gated refresh of the liquidityhelper Bitcart plugin source.
#
# Designed to run from cron right before bitcart-docker's update.sh. If
# the plugin repo hasn't moved since the last run it exits immediately
# (no re-sync), so an unchanged plugin adds no rebuild cost. On a new
# commit it re-syncs the plugin into bitcart-docker's compose/plugins
# tree; the following update.sh then rebuilds the backend image and —
# only when the admin (Vue) files changed — the admin image (yarn
# build), via bitcart-docker's plugin hash-diff.
#
# Usage: update_liquidityhelper.sh [plugin_src_dir] [bitcart_docker_dir]
set -euo pipefail

PLUGIN_DIR="${1:-/opt/bitcart_liquidity}"
DOCKER_DIR="${2:-/opt/bitcart-docker-lnd}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$PLUGIN_DIR"
old_head="$(git rev-parse HEAD)"
branch="$(git rev-parse --abbrev-ref HEAD)"
# Fast-forward to the tracked branch. Stay on whatever branch was checked
# out at deploy time (e.g. main or testing); never switch branches here.
git fetch --quiet origin "$branch"
git merge --ff-only "origin/$branch" >/dev/null 2>&1 || true
new_head="$(git rev-parse HEAD)"

if [ "$old_head" = "$new_head" ]; then
    echo "$(date -u +%FT%TZ) liquidityhelper: no plugin updates ($new_head)"
    exit 0
fi

echo "$(date -u +%FT%TZ) liquidityhelper: $old_head -> $new_head; re-syncing into compose/plugins"
"$SELF_DIR/sync_plugin_code.sh" "$PLUGIN_DIR" "$DOCKER_DIR"
