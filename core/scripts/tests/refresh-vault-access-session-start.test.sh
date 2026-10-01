#!/usr/bin/env bash
# hq-core: public
# Verify SessionStart refreshes only stale manifests and never waits on hq.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
REGISTRY="$ROOT/.claude/hooks/hook-registry.json"
SESSION_SCRIPT="$(jq -r '[.hooks.SessionStart[] | .hooks[] | select(.id == "refresh-vault-access")][0].script // empty' "$REGISTRY")"
EXPECTED="core/scripts/refresh-vault-access-session-start.sh"
[ "$SESSION_SCRIPT" = "$EXPECTED" ] || {
  echo "FAIL: SessionStart uses '$SESSION_SCRIPT', expected '$EXPECTED'" >&2
  exit 1
}
[ -x "$ROOT/$SESSION_SCRIPT" ] || {
  echo "FAIL: SessionStart wrapper is not executable: $SESSION_SCRIPT" >&2
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HQ_ROOT="$TMP/hq"
mkdir -p "$HQ_ROOT/core/scripts" "$HQ_ROOT/.claude" "$HQ_ROOT/.hq" "$TMP/bin"
cp "$ROOT/core/scripts/refresh-vault-access.sh" "$HQ_ROOT/core/scripts/refresh-vault-access.sh"

cat > "$TMP/bin/hq" <<'HQ'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HQ_CALLS"
case "$*" in
  whoami)
    sleep 3
    printf 'Signed in as test@example.com\n'
    ;;
  'files shared-with-me')
    printf 'COMPANY PATH PERMISSION SOURCE\nacme reports/* write direct\n'
    ;;
  'members --company acme list')
    printf 'test@example.com member\n'
    : > "$HQ_DONE"
    ;;
  *) exit 2 ;;
esac
HQ
chmod +x "$TMP/bin/hq"

run_session_refresh() {
  local log="$1" done="$2"
  HQ_CALLS="$log" HQ_DONE="$done" PATH="$TMP/bin:$PATH" \
    CLAUDE_PROJECT_DIR="$HQ_ROOT" bash "$ROOT/$SESSION_SCRIPT"
}

echo "[1] stale manifest starts detached refresh and returns before hq finishes"
HQ_LOG="$TMP/stale-hq.log"
HQ_DONE="$TMP/stale-done"
printf '{"version":1}\n' > "$HQ_ROOT/.hq/vault-access.json"
touch -t 202001010000 "$HQ_ROOT/.hq/vault-access.json"
START="$(date +%s)"
run_session_refresh "$HQ_LOG" "$HQ_DONE"
ELAPSED=$(( $(date +%s) - START ))
[ "$ELAPSED" -lt 3 ] || {
  echo "FAIL: SessionStart waited ${ELAPSED}s for hq refresh" >&2
  exit 1
}
attempt=0
while [ "$attempt" -lt 8 ]; do
  [ -f "$HQ_DONE" ] && break
  attempt=$((attempt + 1))
  sleep 1
done
[ -f "$HQ_DONE" ] || { echo "FAIL: detached refresh did not finish" >&2; exit 1; }
[ -s "$HQ_LOG" ] || { echo "FAIL: stale manifest did not invoke hq" >&2; exit 1; }
echo "  ok: stale manifest refresh ran asynchronously (${ELAPSED}s startup)"

echo "[2] fresh manifest skips hq entirely"
HQ_LOG="$TMP/fresh-hq.log"
HQ_DONE="$TMP/fresh-done"
printf '{"version":1}\n' > "$HQ_ROOT/.hq/vault-access.json"
touch "$HQ_ROOT/.hq/vault-access.json"
run_session_refresh "$HQ_LOG" "$HQ_DONE"
sleep 0.2
[ ! -s "$HQ_LOG" ] || { echo "FAIL: fresh manifest invoked hq" >&2; exit 1; }
[ ! -e "$HQ_DONE" ] || { echo "FAIL: fresh manifest started a refresh" >&2; exit 1; }
echo "  ok: fresh manifest skipped refresh"
