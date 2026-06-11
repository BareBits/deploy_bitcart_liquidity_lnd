#!/bin/bash
# Run: bash tests/update_liquidityhelper_test.sh
# Functional test for the hardened update_liquidityhelper.sh.
# Stubs: sync_plugin_code.sh (no-op), bitcart-docker update.sh (records
# calls + drives /health JSON), and /health via a file:// URL.
set -u
PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
no(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

ROOT=$(mktemp -d /tmp/upd_test.XXXXXX)
SELF="$ROOT/self"; mkdir -p "$SELF"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cp "$REPO_ROOT/update_liquidityhelper.sh" "$SELF/"
# stub sync
cat > "$SELF/sync_plugin_code.sh" <<'S'
#!/bin/bash
echo "stub-sync $*"
S
chmod +x "$SELF/sync_plugin_code.sh" "$SELF/update_liquidityhelper.sh"

DOCKER="$ROOT/docker"; mkdir -p "$DOCKER/compose"
HEALTH_JSON="$ROOT/health.json"
MARKER="$ROOT/update_calls"; COUNTER="$ROOT/update_counter"
# stub bitcart-docker update.sh — counts calls, sets health per HEALTH_MODE
cat > "$DOCKER/update.sh" <<S
#!/bin/bash
echo call >> "$MARKER"
n=\$(cat "$COUNTER" 2>/dev/null || echo 0); n=\$((n+1)); echo \$n > "$COUNTER"
wa=true
if [ "\${HEALTH_MODE:-}" = "fail_then_ok" ] && [ "\$n" -eq 1 ]; then wa=false; fi
if [ "\${HEALTH_MODE:-}" = "always_fail" ]; then wa=false; fi
cat > "$HEALTH_JSON" <<J
{"ok": true, "worker_alive": \$wa, "auto_update_enabled": true, "update_channel": "main"}
J
S
chmod +x "$DOCKER/update.sh"

# ---- fake plugin repo with an 'origin' remote on branch main ----
ORIGIN="$ROOT/origin.git"; git init -q --bare "$ORIGIN"; git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
PLUGIN="$ROOT/plugin"
git clone -q "$ORIGIN" "$PLUGIN"
( cd "$PLUGIN" && git -c init.defaultBranch=main checkout -q -B main \
  && git config user.email t@t && git config user.name t \
  && echo v1 > VERSION && git add . && git commit -q -m c1 && git push -q -u origin main )

advance_origin(){ # add a new commit to origin/main
  local d="$ROOT/dev"; rm -rf "$d"; git clone -q "$ORIGIN" "$d"; git -C "$d" checkout -q -B main origin/main
  ( cd "$d" && git config user.email t@t && git config user.name t \
    && echo "$1" > VERSION && git add . && git commit -q -m "$1" && git push -q origin main )
}
reset_state(){ rm -f "$SELF/update_state/banned" "$SELF/update_state/last_result" "$MARKER" "$COUNTER"; }
seed_health(){ printf '%s' "$1" > "$HEALTH_JSON"; }
run(){ HEALTH_URL="file://$HEALTH_JSON" HEALTH_TIMEOUT=2 HEALTH_POLL_INTERVAL=1 HEALTH_MODE="${HEALTH_MODE:-always_ok}" \
        "$SELF/update_liquidityhelper.sh" "$PLUGIN" "$DOCKER" "" >"$ROOT/out.log" 2>&1; echo $?; }
calls(){ if [ -f "$MARKER" ]; then wc -l < "$MARKER" | tr -d " "; else echo 0; fi; }
head_of(){ git -C "$PLUGIN" rev-parse HEAD; }

echo "== Scenario 1: auto-update OFF via /health → no-op =="
reset_state; seed_health '{"ok":true,"worker_alive":true,"auto_update_enabled":false,"update_channel":"main"}'
rc=$(HEALTH_MODE=always_ok run)
[ "$rc" = 0 ] && ok "exit 0" || no "exit 0 (got $rc)"
[ "$(calls)" = 0 ] && ok "no rebuild called" || no "rebuild should not run (calls=$(calls))"
grep -q "OFF" "$ROOT/out.log" && ok "logged disabled" || no "logged disabled"

echo "== Scenario 2: enabled, no new commit → core rebuild + health OK =="
reset_state; seed_health '{"ok":true,"worker_alive":true,"auto_update_enabled":true,"update_channel":"main"}'
before=$(head_of); rc=$(HEALTH_MODE=always_ok run)
[ "$rc" = 0 ] && ok "exit 0" || no "exit 0 (got $rc)"
[ "$(calls)" = 1 ] && ok "rebuilt once" || no "rebuilt once (calls=$(calls))"
[ "$(head_of)" = "$before" ] && ok "HEAD unchanged" || no "HEAD unchanged"
grep -q "OK core-only" "$SELF/update_state/last_result" && ok "result core-only" || no "result core-only ($(cat "$SELF/update_state/last_result"))"

echo "== Scenario 3: enabled, new commit, health OK → apply =="
reset_state; advance_origin v2
seed_health '{"ok":true,"worker_alive":true,"auto_update_enabled":true,"update_channel":"main"}'
cand=$(git -C "$ORIGIN" rev-parse main); rc=$(HEALTH_MODE=always_ok run)
[ "$rc" = 0 ] && ok "exit 0" || no "exit 0 (got $rc)"
[ "$(head_of)" = "$cand" ] && ok "HEAD advanced to candidate" || no "HEAD advanced"
grep -q "OK applied $cand" "$SELF/update_state/last_result" && ok "result applied" || no "result applied ($(cat "$SELF/update_state/last_result"))"

echo "== Scenario 4: enabled, new commit, fails to start → ban + rollback =="
reset_state; good=$(head_of); advance_origin v3
seed_health '{"ok":true,"worker_alive":true,"auto_update_enabled":true,"update_channel":"main"}'
cand=$(git -C "$ORIGIN" rev-parse main); rc=$(HEALTH_MODE=fail_then_ok run)
[ "$rc" = 1 ] && ok "exit 1 (failure surfaced)" || no "exit 1 (got $rc)"
[ "$(head_of)" = "$good" ] && ok "rolled back to previous good" || no "rolled back (HEAD=$(head_of) want $good)"
grep -qxF "$cand" "$SELF/update_state/banned" && ok "candidate banned" || no "candidate banned"
[ "$(calls)" = 2 ] && ok "rebuilt twice (apply+rollback)" || no "rebuilt twice (calls=$(calls))"
grep -q "ROLLBACK ok" "$SELF/update_state/last_result" && ok "result rollback ok" || no "result rollback ok ($(cat "$SELF/update_state/last_result"))"

echo "== Scenario 5: banned candidate is skipped =="
reset_state; git -C "$ORIGIN" rev-parse main > "$SELF/update_state/banned"
seed_health '{"ok":true,"worker_alive":true,"auto_update_enabled":true,"update_channel":"main"}'
rc=$(HEALTH_MODE=always_ok run)
[ "$rc" = 0 ] && ok "exit 0" || no "exit 0 (got $rc)"
[ "$(calls)" = 0 ] && ok "no rebuild for banned tip" || no "no rebuild (calls=$(calls))"
grep -q "SKIP banned" "$SELF/update_state/last_result" && ok "result skip-banned" || no "result skip-banned ($(cat "$SELF/update_state/last_result"))"

echo "== Scenario 6: env-file fallback gate (no /health) =="
reset_state; printf 'LIQUIDITYHELPER_AUTO_UPDATE_ENABLED=False\n' > "$DOCKER/compose/liquidityhelper.env"
rc=$(HEALTH_URL="" "$SELF/update_liquidityhelper.sh" "$PLUGIN" "$DOCKER" "" >"$ROOT/out.log" 2>&1; echo $?)
[ "$rc" = 0 ] && ok "exit 0" || no "exit 0 (got $rc)"
[ "$(calls)" = 0 ] && ok "no rebuild (env says off)" || no "no rebuild (calls=$(calls))"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
rm -rf "$ROOT"
[ "$FAIL" = 0 ]
