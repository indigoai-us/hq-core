#!/usr/bin/env bash
# US-038 — register-project.sh with a fake hq on PATH.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/core/scripts/register-project.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TMP/bin" "$TMP/home" "$TMP/hq/companies/acme/projects/alpha" \
  "$TMP/hq/companies/acme/projects/done-one" \
  "$TMP/hq/companies/acme/projects/stale" \
  "$TMP/hq/companies/acme/projects/cached" \
  "$TMP/home/.hq/work-mesh/cache/projects/cmp_acme"

cat > "$TMP/bin/hq" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HQ_FAKE_LOG}"
if [ "${HQ_FAKE_FAIL:-}" = "1" ]; then
  echo "fake ensure failed" >&2
  exit 3
fi
printf '%s\n' '{"projectId":"alpha","threadId":"thr_alpha","channelId":"chn_alpha","version":1,"stories":[{"id":"US-001"}]}'
EOF
chmod +x "$TMP/bin/hq" "$SCRIPT"

export PATH="$TMP/bin:$PATH"
export HOME="$TMP/home"
export HQ_ROOT="$TMP/hq"
export HQ_COMPANY_UID="cmp_acme"
export HQ_FAKE_LOG="$TMP/hq-calls.log"
: > "$HQ_FAKE_LOG"

cat > "$TMP/hq/companies/acme/projects/alpha/prd.json" <<'JSON'
{"name":"Alpha","userStories":[{"id":"US-001","title":"Open","status":"queued"}]}
JSON
cat > "$TMP/hq/companies/acme/projects/done-one/prd.json" <<'JSON'
{"name":"Done","userStories":[{"id":"US-001","title":"Finished","status":"done"}]}
JSON
cat > "$TMP/hq/companies/acme/projects/stale/prd.json" <<'JSON'
{"name":"Stale","userStories":[{"id":"US-001","title":"Old","status":"queued"}]}
JSON
cat > "$TMP/hq/companies/acme/projects/cached/prd.json" <<'JSON'
{"name":"Cached","userStories":[{"id":"US-001","title":"On board","status":"queued"}]}
JSON
echo '{"projectId":"cached"}' > "$TMP/home/.hq/work-mesh/cache/projects/cmp_acme/cached.json"
python3 - <<PY
import os, time
path = "$TMP/hq/companies/acme/projects/stale"
old = time.time() - 40 * 86400
os.utime(path, (old, old))
PY

line="$(bash "$SCRIPT" acme alpha)"
[ "$line" = "registered acme/alpha thread=thr_alpha channel=chn_alpha" ] || fail "register line: $line"
grep -q 'mesh project ensure alpha --company acme' "$HQ_FAKE_LOG" || fail "ensure was not called"
python3 - <<PY
import json
board = json.load(open("$TMP/hq/companies/acme/board.json"))
row = next(p for p in board["projects"] if p["id"] == "alpha")
assert row["threadId"] == "thr_alpha", row
assert row["channelId"] == "chn_alpha", row
PY

audit="$(bash "$SCRIPT" --audit acme)"
printf '%s\n' "$audit" | grep -qx alpha || fail "audit missing alpha: $audit"
printf '%s\n' "$audit" | grep -qx done-one || fail "audit missing done-one: $audit"
printf '%s\n' "$audit" | grep -qx stale || fail "audit missing stale: $audit"
printf '%s\n' "$audit" | grep -qx cached && fail "audit listed cached project"

: > "$HQ_FAKE_LOG"
before="$(cat "$TMP/hq/companies/acme/board.json")"
dry="$(bash "$SCRIPT" --backfill acme --only-active)"
[ "$dry" = "$(printf '%s\n' "would register acme/alpha" "would register acme/cached")" ] || fail "dry-run: $dry"
[ ! -s "$HQ_FAKE_LOG" ] || fail "dry-run called hq"
[ "$(cat "$TMP/hq/companies/acme/board.json")" = "$before" ] || fail "dry-run changed board.json"

echo "ok"
