#!/bin/bash
# Sync the liquidityhelper plugin source into bitcart-docker's
# compose/plugins tree so the next build bakes it into the backend +
# admin images. Idempotent; safe to re-run.
#
# Usage: sync_plugin_code.sh <plugin_src_dir> <bitcart_docker_dir>
#   plugin_src_dir      e.g. /opt/bitcart_liquidity_lnd
#   bitcart_docker_dir  e.g. /opt/bitcart-docker-lnd
set -euo pipefail

PLUGIN_SRC="${1:?usage: sync_plugin_code.sh <plugin_src_dir> <bitcart_docker_dir>}"
DOCKER_DIR="${2:?usage: sync_plugin_code.sh <plugin_src_dir> <bitcart_docker_dir>}"

# Backend module path is enforced by the plugin (plugin.py loads as
# modules.@barebits.liquidityhelper); the admin Nuxt module path is
# enforced by bitcart-admin's globby discovery (modules/@barebits/...).
BACKEND_DEST="$DOCKER_DIR/compose/plugins/backend/@barebits/liquidityhelper"
ADMIN_DEST="$DOCKER_DIR/compose/plugins/admin/@barebits/liquidityhelper"
mkdir -p "$BACKEND_DEST" "$ADMIN_DEST"

# Backend: the engine code (config.py, liquidityhelper.py, classes.py,
# plugin.py, bitcart_plugin/, lnd_proto/, loop_proto/, templates/,
# manifest.json, requirements.txt, ...). Exclude the admin Vue tree
# (synced separately), VCS / venv / tests, and build + runtime artefacts.
rsync -a --delete \
    --exclude='.git' \
    --exclude='admin' \
    --exclude='docker_helpers' \
    --exclude='tests' \
    --exclude='.venv' --exclude='venv' \
    --exclude='__pycache__' --exclude='*.pyc' --exclude='.pytest_cache' \
    --exclude='.idea' \
    --exclude='loop_bin' --exclude='loop_proto_src' \
    --exclude='*.log' --exclude='*.log.*' --exclude='decisions.log' \
    --exclude='*.sqlite' --exclude='*.db' \
    --exclude='user_config.py' \
    "$PLUGIN_SRC/" "$BACKEND_DEST/"

# Admin: the Nuxt module (pages/components/config + package.json).
rsync -a --delete \
    --exclude='node_modules' \
    "$PLUGIN_SRC/admin/modules/@barebits/liquidityhelper/" "$ADMIN_DEST/"

echo "synced liquidityhelper -> $BACKEND_DEST and $ADMIN_DEST"
