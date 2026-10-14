#!/usr/bin/env bash
# Regression tests: /handoff environment deficiencies and system_info are stored
# in the thread file, and items with empty evidence are dropped.
set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/var/tmp}/handoff-deficiencies-test.XXXXXX")"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

repo="$TMP_ROOT/hq"
mkdir -p "$repo/core/scripts/lib" "$repo/workspace/baseline" "$repo/workspace/threads/.handoff-tmp" \
  "$repo/home" "$TMP_ROOT/bin"
for f in handoff-finalize.sh lib/session-id.sh clean-worktree-reconcile-handoff.sh \
         hq-status-summary.sh qmd-reindex-bg.sh; do
  cp "$SRC_ROOT/scripts/$f" "$repo/core/scripts/$f"
done
chmod +x "$repo/core/scripts/"*.sh
printf 'version: 1\nhqVersion: "9.8.7-test.1"\n' > "$repo/core/core.yaml"
printf '%s\n' '{"categories":[{"name":"baseline","patterns":["companies/*","workspace/*","repos/*","core/settings/*",".hq/*"]}]}' \
  > "$repo/workspace/baseline/hq-local-baseline.json"
# Stub hq CLI so hq_cli_version is deterministic.
printf '#!/bin/sh\n[ "$1" = "--version" ] && { echo "hq 1.2.3"; exit 0; }\nexit 1\n' > "$TMP_ROOT/bin/hq"
chmod +x "$TMP_ROOT/bin/hq"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.test
git -C "$repo" config user.name "Handoff Deficiencies Test"
git -C "$repo" add core workspace
git -C "$repo" commit -qm "test fixture"

def_file="$repo/workspace/threads/.handoff-tmp/deficiencies.json"
cat > "$def_file" <<'JSON'
[
  {"lever":"navigation","kind":"repo","severity":"medium","summary":"No map of scripts dir","evidence":"Searched three times for the finalizer","proposed_fix":"Add an INDEX.md"},
  {"lever":"tool-economy","kind":"local-setup","severity":"high","summary":"jq missing","evidence":"jq: command not found","proposed_fix":"brew install jq"},
  {"lever":"no-ops","kind":"hq-core","severity":"low","summary":"Blank evidence","evidence":"   ","proposed_fix":"none"},
  {"lever":"steering-bloat","kind":"hq-core","severity":"low","summary":"Missing evidence","proposed_fix":"none"}
]
JSON

out="$(cd "$repo" && HQ_ROOT="$repo" HOME="$repo/home" HQ_HANDOFF_HOST=desktop \
  PATH="$TMP_ROOT/bin:/usr/bin:/bin:$(dirname "$(command -v jq)")" \
  bash core/scripts/handoff-finalize.sh \
    --title "Handoff: deficiencies test" --summary "synthetic" --message "synthetic" \
    --files-touched-json '[]' --learnings-json '[]' --tags-json '["handoff"]' \
    --deficiencies-json "workspace/threads/.handoff-tmp/deficiencies.json" \
    --slug "deficiencies" --next-command "")" || fail "handoff-finalize exited non-zero"
thread="$repo/$(jq -r '.thread_path' <<<"$out")"
[[ -f "$thread" ]] || fail "thread file missing"

[[ "$(jq '.deficiencies | length' "$thread")" == 2 ]] || fail "expected 2 deficiencies, got $(jq -c .deficiencies "$thread")"
pass "items with blank or missing evidence are dropped"
jq -e '.deficiencies[0] == {"lever":"navigation","kind":"repo","severity":"medium","summary":"No map of scripts dir","evidence":"Searched three times for the finalizer","proposed_fix":"Add an INDEX.md"}' "$thread" >/dev/null \
  || fail "first deficiency did not round-trip"
jq -e '.deficiencies[1].kind == "local-setup" and .deficiencies[1].proposed_fix == "brew install jq"' "$thread" >/dev/null \
  || fail "second deficiency did not round-trip"
pass "deficiencies array round-trips through the thread file"

jq -e '.system_info == {"hq_version":"9.8.7-test.1","hq_cli_version":"1.2.3","host":"desktop","os":"'"$(uname -s | tr '[:upper:]' '[:lower:]')"'","hooks_enforced":false}' "$thread" >/dev/null \
  || fail "system_info mismatch: $(jq -c .system_info "$thread")"
pass "system_info stored with expected fields"
if jq -c .system_info "$thread" | grep -qE '/|@'; then fail "system_info leaks a path or email"; fi
pass "system_info has no paths or emails"

missing_rc=0
(cd "$repo" && HQ_ROOT="$repo" HOME="$repo/home" PATH="$TMP_ROOT/bin:/usr/bin:/bin:$(dirname "$(command -v jq)")" \
  bash core/scripts/handoff-finalize.sh --deficiencies-json "workspace/threads/.handoff-tmp/nope.json" \
  --next-command "" >/dev/null 2>&1) || missing_rc=$?
[[ "$missing_rc" == 3 ]] || fail "missing deficiencies file should exit 3, got $missing_rc"
pass "missing deficiencies file is a hard error"

echo "PASS: handoff-finalize-deficiencies"
