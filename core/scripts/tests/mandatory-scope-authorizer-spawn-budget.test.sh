#!/usr/bin/env bash
set -euo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
DEFAULT_ROOT=$(git -C "$TEST_DIR/../../.." rev-parse --show-toplevel)
ROOT=${HOOK_ROOT_OVERRIDE:-$DEFAULT_ROOT}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)
FIXTURE=$TMP/hq-root
SHIMS=$TMP/shims
COUNT_FILE=$TMP/count
ORIGINAL_PATH=$PATH
mkdir -p "$FIXTURE/.claude/hooks" "$FIXTURE/core/scripts/lib" "$FIXTURE/core/scripts" "$FIXTURE/companies/indigo/settings" "$FIXTURE/companies/otherco/settings" "$FIXTURE/companies/_template" "$FIXTURE/personal" "$FIXTURE/workspace/sessions/sess-bound" "$FIXTURE/workspace/sessions/sess-unbound" "$FIXTURE/workspace"
for path in .claude/hooks/mandatory-scope-authorizer.sh core/scripts/lib/session-authz.sh core/scripts/lib/session-scope-capability.sh core/scripts/lib/session-id.sh core/scripts/hook-lib.sh; do mkdir -p "$FIXTURE/$(dirname "$path")"; cp "$ROOT/$path" "$FIXTURE/$path"; done
printf 'companies:\n  indigo:\n  otherco:\n' > "$FIXTURE/companies/manifest.yaml"
touch "$FIXTURE/companies/indigo/settings/.keep" "$FIXTURE/companies/otherco/settings/.keep" "$FIXTURE/personal/note.md" "$FIXTURE/workspace/note.md"
printf '{"session_id":"sess-bound","company_slug":"indigo"}\n' > "$FIXTURE/workspace/sessions/sess-bound/scope-capability.json"
printf 'session_id: sess-unbound\n' > "$FIXTURE/workspace/sessions/sess-unbound/meta.yaml"
mkdir -p "$SHIMS"
for name in cat jq dirname awk grep head realpath readlink find sort; do
  real=$(type -P "$name" || true); [ -n "$real" ] || continue
  { printf '#!/usr/bin/env bash\n'; printf 'printf "%%s\\n" %q >> "$HQ_TEST_COUNT_FILE"\n' "$name"; if [ "$name" = jq ]; then printf 'case "$*" in *company_slugs*) printf "read\\n" >> "${HQ_TEST_SCOPE_READ_FILE:-/dev/null}" ;; esac\n'; fi; printf 'exec %q "$@"\n' "$real"; } > "$SHIMS/$name"
  chmod +x "$SHIMS/$name"
done
PASS=0; FAIL=0
EXPECT_CROSS_COMPANY_HASH=${EXPECT_CROSS_COMPANY_HASH:-97dc903130d1c59ebaf9872cc26bda91d896981bf03d4fec2de7bbdfbfb01293}
EXPECT_SHELL_EXPANDED_HASH=${EXPECT_SHELL_EXPANDED_HASH:-ff539fd71a9cb0e2131326c0ef4658cc86aae87e27c3be1d47e0534b0dc11de0}
EXPECT_QUOTED_PATH_HASH=${EXPECT_QUOTED_PATH_HASH:-24e44c82aff54cf8ff18d690d7eab7108b17d3604abae1b13551df5515875f51}
EXPECT_MULTILINE_HASH=${EXPECT_MULTILINE_HASH:-97dc903130d1c59ebaf9872cc26bda91d896981bf03d4fec2de7bbdfbfb01293}
EXPECT_UNBOUND_WRITE_HASH=${EXPECT_UNBOUND_WRITE_HASH:-4e2c1ae815f93944036da12ef72b9130ec56b6c4a7ab783d128ae27bd6bcbd7d}
run_hook() {
  tool=$1; sid=$2; file=$3; command=$4; label=$5
  : > "$COUNT_FILE"
  payload=$(jq -cn --arg cwd "$FIXTURE" --arg tool "$tool" --arg sid "$sid" --arg path "$file" --arg command "$command" '{tool_name:$tool,session_id:$sid,cwd:$cwd,tool_input:{file_path:$path,command:$command}}')
  rc=0
  printf '%s' "$payload" | env HQ_HOOK_TOOL_NAME="$tool" HQ_HOOK_SESSION_ID="$sid" HQ_HOOK_CWD="$FIXTURE" HQ_HOOK_AGENT_ID="" HQ_HOOK_AGENT_TYPE="" HQ_TEST_COUNT_FILE="$COUNT_FILE" CLAUDE_PROJECT_DIR="$FIXTURE" PATH="$SHIMS:$ORIGINAL_PATH" /bin/bash "$FIXTURE/.claude/hooks/mandatory-scope-authorizer.sh" > "$TMP/$label.out" 2> "$TMP/$label.err" || rc=$?
  printf '%s\n' "$rc" > "$TMP/$label.rc"
}
assert_budget() {
  label=$1; budget=$2; count=$(wc -l < "$COUNT_FILE" | tr -d ' ')
  if (( count <= budget )); then PASS=$((PASS+1)); printf 'PASS %s external_commands=%s budget=%s\n' "$label" "$count" "$budget"
  else FAIL=$((FAIL+1)); printf 'FAIL %s external_commands=%s budget=%s helpers=%s\n' "$label" "$count" "$budget" "$(tr '\n' ',' < "$COUNT_FILE")" >&2; fi
}
hash_output() {
  sed "s|$FIXTURE|<FIXTURE>|g" "$TMP/$1.err" | sha256sum | cut -d' ' -f1
}
assert_deny() {
  label=$1; expected=$2; rc=$(cat "$TMP/$label.rc"); actual=$(hash_output "$label")
  if [ "$rc" = 2 ] && [ ! -s "$TMP/$label.out" ] && { [ -z "$expected" ] || [ "$actual" = "$expected" ]; }; then PASS=$((PASS+1)); printf 'PASS %s exit=%s stderr_sha256=%s\n' "$label" "$rc" "$actual"
  else FAIL=$((FAIL+1)); printf 'FAIL %s exit=%s expected_sha=%s actual_sha=%s\n' "$label" "$rc" "$expected" "$actual" >&2; fi
}
run_hook Bash sess-bound '' 'printf ready' bash-no-company-path
[ "$(cat "$TMP/bash-no-company-path.rc")" = 0 ] || FAIL=$((FAIL+1)); assert_budget bash-no-company-path 2
run_hook Read sess-bound "$FIXTURE/workspace/note.md" '' read-workspace
[ "$(cat "$TMP/read-workspace.rc")" = 0 ] || FAIL=$((FAIL+1)); assert_budget read-workspace 2
run_hook Write sess-bound "$FIXTURE/personal/note.md" '' write-personal
[ "$(cat "$TMP/write-personal.rc")" = 0 ] || FAIL=$((FAIL+1)); assert_budget write-personal 2
run_hook Bash sess-bound '' 'cat companies/otherco/settings/secret.yaml' deny-cross-company
assert_deny deny-cross-company "$EXPECT_CROSS_COMPANY_HASH"
run_hook Bash sess-bound '' 'co=otherco; cat companies/$co/settings/x' deny-shell-expanded
assert_deny deny-shell-expanded "$EXPECT_SHELL_EXPANDED_HASH"
run_hook Bash sess-bound '' "cat 'companies/otherco/settings/secret.yaml'" deny-quoted-path
assert_deny deny-quoted-path "$EXPECT_QUOTED_PATH_HASH"
run_hook Bash sess-bound '' $'printf ready\ncat companies/otherco/settings/secret.yaml' deny-multiline
assert_deny deny-multiline "$EXPECT_MULTILINE_HASH"
run_hook Write sess-unbound "$FIXTURE/companies/indigo/settings/secret.yaml" '' deny-unbound-write
assert_deny deny-unbound-write "$EXPECT_UNBOUND_WRITE_HASH"
MASTER=$TMP/master-root
mkdir -p "$MASTER/.claude/hooks" "$MASTER/core/scripts/lib" "$MASTER/core/scripts" "$MASTER/companies/indigo/settings" "$MASTER/workspace" "$MASTER/personal"
for path in .claude/hooks/master-hook.sh .claude/hooks/hook-timeout-probe.sh .claude/hooks/hook-timeout-watchdog.sh .claude/hooks/hook-gate.sh .claude/hooks/mandatory-scope-authorizer.sh core/scripts/resolve-hq-root.sh core/scripts/hook-lib.sh core/scripts/lib/hook-adapter-core.sh core/scripts/lib/session-authz.sh core/scripts/lib/session-scope-capability.sh core/scripts/lib/session-id.sh; do mkdir -p "$MASTER/$(dirname "$path")"; cp "$ROOT/$path" "$MASTER/$path"; done
cat > "$MASTER/.claude/hooks/hook-registry.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Write","hooks":[{"id":"mandatory-scope-authorizer","script":".claude/hooks/mandatory-scope-authorizer.sh","timeout":30,"gated":true,"runner":"source"}]}]}}
JSON
printf 'hqVersion: test\n' > "$MASTER/core/core.yaml"; touch "$MASTER/companies/indigo/settings/.keep"
printf '{"tool_name":"Write","session_id":"e2e-unbound","cwd":"%s","tool_input":{"file_path":"%s/companies/indigo/settings/secret.yaml"}}' "$MASTER" "$MASTER" > "$TMP/master-payload.json"
rc=0
cat "$TMP/master-payload.json" | env -u HQ_HOOK_EVENT -u HQ_HOOK_TOOL_NAME -u HQ_HOOK_SESSION_ID -u HQ_HOOK_CWD -u HQ_HOOK_AGENT_ID -u HQ_FLAGS_API_URL -u HQ_COMPANY_UID CLAUDE_PROJECT_DIR="$MASTER" BASH_ENV=/dev/null bash "$MASTER/.claude/hooks/master-hook.sh" PreToolUse > "$TMP/master.out" 2> "$TMP/master.err" || rc=$?
if [ "$rc" = 2 ] && grep -q 'Cross-company scope violation' "$TMP/master.err"; then PASS=$((PASS+1)); printf 'PASS real-master-hook-no-injected-fields\n'; else FAIL=$((FAIL+1)); printf 'FAIL real-master-hook-no-injected-fields exit=%s\n' "$rc" >&2; fi
# A routine tool event must not parse the lock set; that data is consumed only at SessionStart.
mkdir -p "$MASTER/workspace/sessions/e2e-bound"
printf 'session_id: e2e-bound\ncompany_slug: indigo\n' > "$MASTER/workspace/sessions/e2e-bound/meta.yaml"
printf '{"session_id":"e2e-bound","company_slug":"indigo"}\n' > "$MASTER/workspace/sessions/e2e-bound/scope-capability.json"
printf '{"tool_name":"Read","session_id":"e2e-bound","cwd":"%s","tool_input":{"file_path":"%s/companies/indigo/settings/.keep"}}' "$MASTER" "$MASTER" > "$TMP/master-bound-payload.json"
: > "$TMP/scope-read-count"
rc=0
cat "$TMP/master-bound-payload.json" | env -u HQ_HOOK_EVENT -u HQ_HOOK_TOOL_NAME -u HQ_HOOK_SESSION_ID -u HQ_HOOK_CWD -u HQ_HOOK_AGENT_ID -u HQ_FLAGS_API_URL -u HQ_COMPANY_UID HQ_TEST_SCOPE_READ_FILE="$TMP/scope-read-count" CLAUDE_PROJECT_DIR="$MASTER" BASH_ENV=/dev/null PATH="$SHIMS:$ORIGINAL_PATH" bash "$MASTER/.claude/hooks/master-hook.sh" PreToolUse > "$TMP/master-bound.out" 2> "$TMP/master-bound.err" || rc=$?
if [ "$rc" = 0 ] && [ ! -s "$TMP/scope-read-count" ]; then PASS=$((PASS+1)); printf 'PASS master-hook-pretooluse-skips-lock-set-read\n'; else FAIL=$((FAIL+1)); printf 'FAIL master-hook-pretooluse-lock-set-read exit=%s reads=%s\n' "$rc" "$(wc -l < "$TMP/scope-read-count" | tr -d ' ')" >&2; fi
if (( FAIL > 0 )); then printf 'mandatory-scope-authorizer-spawn-budget: %s passed, %s failed\n' "$PASS" "$FAIL" >&2; exit 1; fi
printf 'mandatory-scope-authorizer-spawn-budget: %s passed, %s failed\n' "$PASS" "$FAIL"
