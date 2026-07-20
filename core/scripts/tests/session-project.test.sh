#!/usr/bin/env bash
# Smoke tests for native session project helper.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HELPER="$ROOT/core/scripts/session-project.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file() {
  [ -f "$1" ] || fail "missing file: $1"
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$label: missing '$needle' in $haystack"
}

mkdir -p "$TMP/personal/projects/native-project-journaling"
cat > "$TMP/personal/projects/native-project-journaling/prd.json" <<'JSON'
{
  "name": "native-project-journaling",
  "description": "Automatically journal native Claude and Codex executions into project folders and prd.json files.",
  "metadata": {
    "goal": "Native plan mode project capture"
  },
  "userStories": []
}
JSON

reuse_out=$(HQ_ROOT="$TMP" "$HELPER" ensure \
  --scope hq-core \
  --title "Native Codex executions automatically journal project prd files" \
  --prompt "native claude/codex executions automatically journal without startwork prd run-project" \
  --session-id test-reuse)

assert_contains "$reuse_out" '"reused": true' "related project reuse"
assert_contains "$reuse_out" 'personal/projects/native-project-journaling' "reuse path"

new_out=$(HQ_ROOT="$TMP" "$HELPER" ensure \
  --scope hq-core \
  --title "Totally Separate Durable Workstream" \
  --prompt "totally separate durable workstream for a new native session" \
  --session-id test-new \
  --reuse-threshold 99)

assert_contains "$new_out" '"reused": false' "new project creation"
assert_file "$TMP/personal/projects/totally-separate-durable-workstream/prd.json"
assert_file "$TMP/personal/projects/totally-separate-durable-workstream/README.md"

printf '## Plan\n\n- Do the thing.\n' | HQ_ROOT="$TMP" "$HELPER" ingest-plan >/tmp/session-project-plan-path.txt
plan_rel="$(cat /tmp/session-project-plan-path.txt)"
assert_file "$TMP/$plan_rel"

python3 - "$TMP/personal/projects/totally-separate-durable-workstream/prd.json" <<'PY' || fail "native plan not recorded"
import json
import sys
data = json.load(open(sys.argv[1]))
plans = data.get("metadata", {}).get("nativePlans", [])
assert plans and plans[-1]["path"].endswith("-native-plan.md")
PY

# Regression: a conflicted pointer is not a project path. It must fail closed
# rather than creating a directory tree whose names contain merge markers.
mkdir -p "$TMP/.claude/state"
printf '<<<<<<< HEAD\npersonal/projects/one\n=======\npersonal/projects/two\n>>>>>>> topic\n' \
  > "$TMP/.claude/state/active-session-project"
set +e
bad_pointer_out=$(printf '## Plan\n' | HQ_ROOT="$TMP" "$HELPER" ingest-plan 2>&1)
bad_pointer_status=$?
set -e
[[ "$bad_pointer_status" -ne 0 ]] || fail "conflicted active pointer was accepted"
assert_contains "$bad_pointer_out" "invalid active project pointer" "conflicted pointer rejection"
[[ ! -e "$TMP/<<<<<<< HEAD" ]] || fail "conflicted pointer created a filesystem path"
grep -qxF '.claude/state/active-session-project merge=binary' "$ROOT/.gitattributes" \
  || fail "active project pointer lacks binary merge protection"

echo "session-project smoke: ok"
