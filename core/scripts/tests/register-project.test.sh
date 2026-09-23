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
if [ "$1" = "mesh" ] && [ "$2" = "project" ] && [ "$3" = "ensure" ] && [ "${4:-}" = "--help" ]; then
  if [ "${HQ_FAKE_NO_ENSURE:-}" = "1" ]; then
    echo "unknown command" >&2
    exit 1
  fi
  exit 0
fi
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

mkdir -p "$TMP/hq/companies/acme/projects/beta"
cat > "$TMP/hq/companies/acme/projects/beta/prd.json" <<'JSON'
{"name":"Beta","userStories":[{"id":"US-002","title":"Open","status":"queued"}]}
JSON
: > "$HQ_FAKE_LOG"
set +e
old_out="$(HQ_FAKE_NO_ENSURE=1 bash "$SCRIPT" acme beta 2>"$TMP/old.err")"
old_status=$?
set -e
[ "$old_status" -ne 0 ] || fail "old cli exited 0: $old_out"
[ "$(tr -d '\n' < "$TMP/old.err")" = "hq-cli 5.139.0 or newer is required; acme/beta stays local until then" ] || fail "old cli message: $(cat "$TMP/old.err")"
[ ! -s "$HQ_FAKE_LOG" ] || fail "old cli called ensure: $(cat "$HQ_FAKE_LOG")"
python3 - <<PY
import json
board = json.load(open("$TMP/hq/companies/acme/board.json"))
row = next(p for p in board["projects"] if p["id"] == "beta")
assert row.get("pending_registration") is True, row
assert "threadId" not in row, row
PY

for name in p1 p2 p3 p4; do
  mkdir -p "$TMP/hq/companies/acme/projects/$name"
  cat > "$TMP/hq/companies/acme/projects/$name/prd.json" <<JSON
{"name":"$name","userStories":[{"id":"US-001","title":"Open","status":"queued"}]}
JSON
done
python3 - <<PY
import json
board = json.load(open("$TMP/hq/companies/acme/board.json"))
for row in board["projects"]:
    if row.get("id") == "beta":
        row["pending_registration"] = False
for name in ("p1", "p2", "p3", "p4"):
    board["projects"].append({"id": name, "pending_registration": True, "prd_path": f"companies/acme/projects/{name}/prd.json"})
json.dump(board, open("$TMP/hq/companies/acme/board.json", "w"))
PY
: > "$HQ_FAKE_LOG"
retry_out="$(bash "$SCRIPT" --retry-pending acme)"
printf '%s\n' "$retry_out" | grep -q 'registered acme/p1 ' || fail "retry missed p1: $retry_out"
printf '%s\n' "$retry_out" | grep -q 'registered acme/p2 ' || fail "retry missed p2: $retry_out"
printf '%s\n' "$retry_out" | grep -q 'registered acme/p3 ' || fail "retry missed p3: $retry_out"
printf '%s\n' "$retry_out" | grep -q 'registered acme/p4 ' && fail "retry exceeded 3: $retry_out"
ensure_calls="$(grep -c 'mesh project ensure ' "$HQ_FAKE_LOG" || true)"
[ "$ensure_calls" = "3" ] || fail "ensure call count: $ensure_calls"
python3 - <<PY
import json
board = json.load(open("$TMP/hq/companies/acme/board.json"))
by_id = {p["id"]: p for p in board["projects"]}
for name in ("p1", "p2", "p3"):
    assert by_id[name].get("pending_registration") in (None, False), by_id[name]
    assert by_id[name]["threadId"] == "thr_alpha", by_id[name]
assert by_id["p4"].get("pending_registration") is True, by_id["p4"]
PY

: > "$HQ_FAKE_LOG"
HQ_FAKE_NO_ENSURE=1 bash "$SCRIPT" --retry-pending acme >/dev/null
[ ! -s "$HQ_FAKE_LOG" ] || fail "retry without ensure called hq"

HOOK="$ROOT/core/hooks/SessionStart/35-work-mesh-session-start.sh"
grep -q -- '--retry-pending' "$HOOK" || fail "session start does not retry pending registration"
grep -q 'nohup bash' "$HOOK" || fail "session start retry is not detached"
if grep -n 'register-project.sh" --retry-pending' "$HOOK" | grep -v 'HQ_REGISTER_PENDING_SCRIPT' | grep -q .; then
  fail "session start still invokes register-project in the foreground"
fi

# A slow retry must not delay the hook, and a second start must not start another.
PENDING_DIR="$TMP/pending"
MARK="$TMP/retry-mark"
: >"$MARK"
cat > "$TMP/sleeper.sh" <<'EOF'
#!/usr/bin/env bash
printf 'start\n' >> "${HQ_RETRY_MARK:?}"
printf 'retry-out\n'
sleep 3
printf 'done\n' >> "${HQ_RETRY_MARK:?}"
EOF
chmod +x "$TMP/sleeper.sh"
run_start() {
  env -u HQ_DISABLED_HOOKS -u HQ_WORK_MESH_DISABLED \
    HOME="$TMP/home" \
    HQ_ROOT="$ROOT" \
    HQ_SESSION_ID="us039retry" \
    HQ_SPAWN_COMPANY="acme" \
    HQ_WORK_MESH_RECONCILE_STUB=1 \
    HQ_REGISTER_PENDING_SCRIPT="$TMP/sleeper.sh" \
    HQ_REGISTER_PENDING_DIR="$PENDING_DIR" \
    HQ_RETRY_MARK="$MARK" \
    bash "$HOOK" <<<"{\"session_id\":\"us039retry\"}" >/dev/null
}
t0=$(date +%s)
run_start
t1=$(date +%s)
[ $((t1 - t0)) -le 2 ] || fail "session start waited on retry ($((t1 - t0))s)"
[ -d "$PENDING_DIR/acme.lock" ] || fail "retry lock was not taken"
run_start
starts=$(grep -c '^start$' "$MARK" || true)
[ "$starts" = "1" ] || fail "second session start launched another retry: $starts"
waited=0
while [ "$waited" -lt 8 ]; do
  if grep -q '^done$' "$MARK" && [ ! -d "$PENDING_DIR/acme.lock" ]; then
    break
  fi
  sleep 1
  waited=$((waited + 1))
done
grep -q '^done$' "$MARK" || fail "detached retry did not finish: $(cat "$MARK")"
[ ! -d "$PENDING_DIR/acme.lock" ] || fail "retry lock was not released"
grep -q 'retry-out' "$PENDING_DIR/acme.log" || fail "retry log missing stdout: $(cat "$PENDING_DIR/acme.log" 2>/dev/null || true)"

echo "ok"
