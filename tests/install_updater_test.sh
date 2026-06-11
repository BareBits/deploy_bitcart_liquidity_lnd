#!/bin/bash
# Run: bash tests/install_updater_test.sh
# Tests install_updater.sh with stubbed git (no network) + fake root, and
# OPT_DIR/CRON_DIR redirected into a sandbox. Covers validation guards,
# autodetect, host resolution, clone+cron happy path, and idempotency.
set -u
PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
no(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT=$(mktemp -d /tmp/inst_test.XXXXXX)
OPT="$ROOT/opt"; CRON="$ROOT/cron"; BIN="$ROOT/bin"
mkdir -p "$OPT" "$CRON" "$BIN"

# Fake `id` returning root, and a `git` stub that "clones" by making a dir
# with a .git marker + the needed scripts (no network).
cat > "$BIN/id" <<'S'
#!/bin/bash
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
S
cat > "$BIN/git" <<S
#!/bin/bash
# minimal stub: support 'clone -b BR URL DIR', 'ls-remote', '-C DIR ...'
if [ "\$1" = "clone" ]; then
    dir="\${@: -1}"; mkdir -p "\$dir/.git"
    # deploy repo clone must carry the updater scripts
    case "\$*" in
      *deploy_bitcart_liquidity_lnd*) cp "$REPO/update_liquidityhelper.sh" "$REPO/sync_plugin_code.sh" "\$dir/" ;;
    esac
    exit 0
fi
if [ "\$1" = "ls-remote" ]; then exit 0; fi   # no 'testing' branch
if [ "\$1" = "-C" ]; then exit 0; fi          # fetch/checkout on existing
exit 0
S
chmod +x "$BIN/id" "$BIN/git"
export PATH="$BIN:$PATH"

# Fake bitcart-docker dir
DK="$OPT/bitcart-docker"; mkdir -p "$DK/compose"
echo "#stub" > "$DK/update.sh"; chmod +x "$DK/update.sh"
echo "BITCART_HOST=pay.example.com" > "$DK/.env"

run(){ OPT_DIR="$OPT" CRON_DIR="$CRON" bash "$REPO/install_updater.sh" "$@" >"$ROOT/out.log" 2>&1; echo $?; }

echo "== guards =="
rc=$(run --help); [ "$rc" = 0 ] && grep -q "Usage:" "$ROOT/out.log" && ok "--help" || no "--help"
rc=$(run --channel bogus --docker-dir "$DK"); [ "$rc" = 1 ] && grep -q "invalid --channel" "$ROOT/out.log" && ok "rejects bad channel" || no "rejects bad channel"
rc=$(run --docker-dir "$ROOT/nope"); [ "$rc" = 1 ] && grep -q "doesn't look like" "$ROOT/out.log" && ok "rejects non-bitcart dir" || no "rejects non-bitcart dir"

echo "== non-root guard =="
rc=$(PATH="${PATH#$BIN:}" OPT_DIR="$OPT" CRON_DIR="$CRON" bash "$REPO/install_updater.sh" --docker-dir "$DK" >"$ROOT/out.log" 2>&1; echo $?)
if [ "$(/usr/bin/id -u)" != 0 ]; then
  [ "$rc" = 1 ] && grep -q "must run as root" "$ROOT/out.log" && ok "rejects non-root" || no "rejects non-root"
else ok "skip non-root (running as root)"; fi

echo "== autodetect + host-from-.env + happy path =="
rc=$(run); [ "$rc" = 0 ] && ok "exit 0 (autodetect)" || { no "exit 0 (autodetect)"; cat "$ROOT/out.log"; }
grep -q "found $DK" "$ROOT/out.log" && ok "autodetected docker dir" || no "autodetected docker dir"
[ -d "$OPT/bitcart_liquidity_lnd/.git" ] && ok "cloned plugin source" || no "cloned plugin source"
[ -x "$OPT/deploy_bitcart_liquidity_lnd/update_liquidityhelper.sh" ] && ok "deploy scripts present+exec" || no "deploy scripts present"
CF="$CRON/bitcart_updates"
[ -f "$CF" ] && ok "cron written" || no "cron written"
grep -q "pay.example.com" "$CF" && ok "cron has host from .env" || no "cron has host"
grep -q "$OPT/deploy_bitcart_liquidity_lnd/update_liquidityhelper.sh" "$CF" && ok "cron calls updater" || no "cron calls updater"

echo "== idempotent re-run =="
rc=$(run --docker-dir "$DK" --host pay.example.com); [ "$rc" = 0 ] && ok "re-run exit 0" || no "re-run exit 0"
grep -q "updating .*bitcart_liquidity_lnd" "$ROOT/out.log" && ok "re-run updates existing clone" || no "re-run updates clone"

echo "== --name suffix =="
rc=$(run --docker-dir "$DK" --host h2 --name two)
[ -f "$CRON/bitcart_updates_two" ] && ok "named cron file" || no "named cron file"
[ -d "$OPT/bitcart_liquidity_lnd-two/.git" ] && ok "named plugin dir" || no "named plugin dir"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
rm -rf "$ROOT"
[ "$FAIL" = 0 ]
