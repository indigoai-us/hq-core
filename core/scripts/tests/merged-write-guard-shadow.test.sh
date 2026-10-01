#!/usr/bin/env bash
# Regression suite for US-020's default-off, record-only merged write guard.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
HOOK="$ROOT/.claude/hooks/merged-write-guard-shadow.sh"
REFRESH="$ROOT/.claude/hooks/merged-write-guard-shadow-refresh.sh"
REGISTRY="$ROOT/.claude/hooks/hook-registry.json"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/merged-write-guard-shadow.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }
for tool in jq node; do command -v "$tool" >/dev/null 2>&1 || fail "required tool missing: $tool"; done
[ -f "$HOOK" ] || fail "missing hook $HOOK"
FAKE="$TMP/hq"
mkdir -p "$FAKE/.claude" "$FAKE/core" "$FAKE/repos/private/demo" "$FAKE/workspace" "$TMP/bin"
CLI="$TMP/npm-global/lib/node_modules/@indigoai-us/hq-cli"
mkdir -p "$CLI/bin" "$CLI/node_modules/@indigoai-us/hq-flags-client" "$CLI/node_modules/@indigoai-us/hq-cloud"
cat > "$CLI/package.json" <<'JSON'
{"name":"@indigoai-us/hq-cli","bin":{"hq":"bin/hq"}}
JSON
cat > "$CLI/bin/hq" <<'SH'
#!/usr/bin/env sh
exit 0
SH
chmod +x "$CLI/bin/hq"
ln -s "$CLI/bin/hq" "$TMP/bin/hq"
SYSTEM_NODE="$(command -v node)"
export SYSTEM_NODE
cat > "$TMP/bin/node" <<'SH'
#!/usr/bin/env bash
[ -z "${HQ_TEST_FLAG_CALL_MARKER:-}" ] || printf 'called\n' >> "$HQ_TEST_FLAG_CALL_MARKER"
exec "$SYSTEM_NODE" "$@"
SH
chmod +x "$TMP/bin/node"
cat > "$CLI/node_modules/@indigoai-us/hq-flags-client/package.json" <<'JSON'
{"type":"module","exports":{".":{"import":"./index.js"}}}
JSON
cat > "$CLI/node_modules/@indigoai-us/hq-flags-client/index.js" <<'JS'
export const createFlagClient = () => ({
  ready: async () => {
    if (process.env.HQ_TEST_FLAG_MODE === "error") {
      const error = new Error("VALUE_SENTINEL_DO_NOT_PRINT");
      error.name = "TestLookupError";
      throw error;
    }
    if (process.env.HQ_TEST_FLAG_MODE === "timeout") {
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
  },
  snapshot: () => ({flags:
    process.env.HQ_TEST_FLAG_MODE === "missing"
      ? {}
      : {"guards.merged-write-guard-shadow": process.env.HQ_TEST_FLAG_MODE === "true"}
  }),
  close: () => {},
});
JS
cat > "$CLI/node_modules/@indigoai-us/hq-cloud/package.json" <<'JSON'
{"type":"module","exports":{".":{"default":"./index.js"}}}
JSON
cat > "$CLI/node_modules/@indigoai-us/hq-cloud/index.js" <<'JS'
export const loadCachedTokens = () => ({idToken:"test-only-token"});
JS
chmod +x "$HOOK"
LOG="$FAKE/workspace/orchestrator/hook-state/merged-write-guard-shadow.jsonl"
mkdir -p "$(dirname "$LOG")"
case_n=0
run_hook() {
  local tool="$1" mode="$2" tool_input="$3" company_uid payload out err rc sid
  company_uid="${4:-cmp_test${mode}${RANDOM}}"; sid="${5:-us020-test}"
  case_n=$((case_n + 1))
  payload="$(jq -nc --arg tool "$tool" --arg cwd "$FAKE" --arg sid "$sid" --argjson ti "$tool_input" \
    '{session_id:$sid,hook_event_name:"PreToolUse",tool_name:$tool,cwd:$cwd,tool_input:$ti}')"
  out="$TMP/run-$case_n.out"; err="$TMP/run-$case_n.err"
  if printf '%s\n' "$payload" | env PATH="$TMP/bin:$PATH" HQ_COMPANY_UID="$company_uid" \
      HQ_TEST_FLAG_MODE="$mode" HQ_TEST_FLAG_CALL_MARKER="${TEST_NODE_MARKER:-}" \
      HQ_DISABLED_HOOKS="${HQ_DISABLED_HOOKS:-}" CLAUDE_PROJECT_DIR="$FAKE" bash "$HOOK" >"$out" 2>"$err"; then rc=0; else rc=$?; fi
  printf '%s\n' "$rc" "$out" "$err" "$company_uid"
}
run_refresh() {
  local mode="$1" company_uid out err rc sid
  company_uid="${2:-cmp_refresh${mode}${RANDOM}}"; sid="${3:-us020-test}"
  out="$TMP/refresh-$RANDOM.out"; err="$TMP/refresh-$RANDOM.err"
  if printf '{"session_id":"%s"}\n' "$sid" | env -u HQ_CLI_BIN PATH="$TMP/bin:$PATH" HQ_FLAGS_API_URL=https://flags.invalid \
      HQ_COMPANY_UID="$company_uid" HQ_TEST_FLAG_MODE="$mode" \
      HQ_TEST_FLAG_CALL_MARKER="${TEST_NODE_MARKER:-}" CLAUDE_PROJECT_DIR="$FAKE" \
      bash "$REFRESH" >"$out" 2>"$err"; then rc=0; else rc=$?; fi
  printf '%s\n' "$rc" "$out" "$err" "$company_uid"
}
expect_off() {
  local label="$1" mode="$2" tool="$3" input="$4" result rc out err uid
  result="$(run_refresh "$mode" "cmp_case${mode}98765")"
  rc="$(printf '%s\n' "$result" | sed -n '1p')"; out="$(printf '%s\n' "$result" | sed -n '2p')"
  err="$(printf '%s\n' "$result" | sed -n '3p')"
  [ "$rc" = 0 ] || fail "$label: exit $rc"
  [ ! -s "$out" ] || fail "$label: stdout must be empty"
  [ ! -s "$LOG" ] || fail "$label: default-off call wrote a shadow record"
  if [ "$mode" = error ] || [ "$mode" = timeout ]; then
    grep -Eq 'flag lookup failed \((TestLookupError|TimeoutError)\)' "$err" || fail "$label: missing safe error class; stderr=$(cat "$err")"
    ! grep -q 'VALUE_SENTINEL_DO_NOT_PRINT' "$err" || fail "$label: leaked error value"
    [ "$(wc -l < "$err" | tr -d ' ')" = 1 ] || fail "$label: expected one stderr notice"
  else
    [ ! -s "$err" ] || fail "$label: unexpected stderr"
  fi
  pass "$label stays default-off with no shadow output"
}
run_on() {
  local label="$1" tool="$2" input="$3" result rc out err uid line expected_merged expected_old
  run_refresh true "cmp_runon123" "us020-test" >/dev/null
  result="$(run_hook "$tool" true "$input" "cmp_runon123")"
  rc="$(printf '%s\n' "$result" | sed -n '1p')"; out="$(printf '%s\n' "$result" | sed -n '2p')"
  err="$(printf '%s\n' "$result" | sed -n '3p')"
  [ "$rc" = 0 ] || fail "$label: shadow hook changed exit status to $rc"
  [ ! -s "$out" ] || fail "$label: shadow hook emitted stdout"
  [ ! -s "$err" ] || fail "$label: unexpected stderr"
  [ -s "$LOG" ] || fail "$label: flag-on call did not append a record"
  [ "$(wc -l < "$LOG" | tr -d ' ')" = 1 ] || fail "$label: expected one record for this call"
  line="$(tail -n 1 "$LOG")"
  printf '%s\n' "$line" | jq -e '(.tool|type)=="string" and (.rule_id|type)=="string" and (.merged_decision=="allow" or .merged_decision=="deny") and (.legacy_decision=="allow" or .legacy_decision=="deny") and (.old_guards|type)=="object" and (has("command")|not) and (has("tool_input")|not)' >/dev/null || fail "$label: malformed or sensitive log record"
  pass "$label is record-only"
}
matrix_case() {
  local label="$1" tool="$2" input="$3" expected="$4" line
  : > "$LOG"
  run_on "$label" "$tool" "$input"
  line="$(tail -n 1 "$LOG")"
  printf '%s\n' "$line" | jq -e --arg expected "$expected" ' .legacy_decision == $expected ' >/dev/null || fail "$label: legacy combined outcome mismatch"
}

if [ "${1:-}" = "--benchmark" ]; then
  node "$ROOT/core/scripts/tests/merged-write-guard-shadow-benchmark.cjs" "$HOOK" "$FAKE" "$TMP/bin/hq" "$REFRESH"
  exit $?
fi


: > "$LOG"
echo '[1] flag lookup remains default-off'
expect_off 'explicit false' false Bash '{"command":"git status --short"}'
expect_off 'missing registry row' missing Bash '{"command":"git status --short"}'
expect_off 'lookup outage' error Bash '{"command":"git status --short"}'
expect_off 'lookup timeout' timeout Bash '{"command":"git status --short"}'

# The lookup occurs once at SessionStart. An admitted session reads its own marker without another flag request.
TEST_NODE_MARKER="$TMP/node-starts"
run_refresh true cmp_sessiontrue123 us020-enabled >/dev/null
starts_before="$(wc -l < "$TEST_NODE_MARKER" | tr -d ' ')"
run_hook Bash true '{"command":"git status --short"}' cmp_sessiontrue123 >/dev/null
starts_after="$(wc -l < "$TEST_NODE_MARKER" | tr -d ' ')"
[ "$starts_before" = "$starts_after" ] || fail 'PreToolUse performed another flag lookup'
run_refresh false cmp_sessionfalse123 us020-disabled >/dev/null
[ -f "$FAKE/workspace/orchestrator/hook-state/merged-write-guard-shadow/us020-enabled.enabled" ] || fail 'flag-off session cleared another session marker'
: > "$LOG"
run_hook Bash true '{"command":"git status --short"}' cmp_sessionfalse123 us020-disabled >/dev/null
[ ! -s "$LOG" ] || fail 'enabled session marker leaked into a different session'
unset TEST_NODE_MARKER
pass 'flag snapshot is session-scoped and PreToolUse does not recheck it'

jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash|Edit|Write|MultiEdit|apply_patch") | .hooks[] | select(.id == "merged-write-guard-shadow" and .gated == true and .script == ".claude/hooks/merged-write-guard-shadow.sh" and (has("prefilter")|not))' "$REGISTRY" >/dev/null || fail "missing session-scoped merged PreToolUse registry entry"
jq -e '.hooks.SessionStart[] | .hooks[] | select(.id == "merged-write-guard-shadow-refresh" and .script == ".claude/hooks/merged-write-guard-shadow-refresh.sh" and .gated == true)' "$REGISTRY" >/dev/null || fail "missing SessionStart hq-flags refresh"
BASE_REF="${GITHUB_BASE_REF:-main}"
if ! git -C "$ROOT" rev-parse --verify "$BASE_REF^{commit}" >/dev/null 2>&1; then
  BASE_REF="origin/$BASE_REF"
fi
BASE_COMMIT="$(git -C "$ROOT" merge-base HEAD "$BASE_REF")" || fail "could not resolve review base"
git -C "$ROOT" diff --quiet "$BASE_COMMIT" HEAD -- .claude/hooks/block-core-writes-bash.sh .claude/hooks/block-core-writes.sh core/hooks/PreToolUse/10-Edit,Write,MultiEdit--block-repo-edits-use-worktree.sh || fail "legacy guard source changed in reviewed commit"


: > "$LOG"
: > "$LOG"
echo '[2] flag-on matrix records, never blocks, and preserves old combined decisions'
run_on 'Bash protected redirect' Bash "{\"command\":\"echo x > $FAKE/core/new-file\"}"
jq -e 'select(.tool=="Bash" and .old_guards.core_bash=="deny" and .legacy_decision=="deny" and .merged_decision=="deny")' "$LOG" >/dev/null || fail 'Bash old denial was not recorded'
: > "$LOG"
HQ_DISABLED_HOOKS=block-core-writes-bash run_on 'disabled legacy guard is excluded' Bash "{\"command\":\"echo x > $FAKE/core/disabled\"}"
jq -e 'select(.old_guards.core_bash=="allow" and .legacy_decision=="allow" and .merged_decision=="allow")' "$LOG" >/dev/null || fail 'disabled legacy guard still affected shadow result'
unset HQ_DISABLED_HOOKS
: > "$LOG"
HQ_DISABLED_HOOKS=block-repo-edits-use-worktree run_on 'disabled repository guard is excluded' Write "{\"file_path\":\"$FAKE/repos/private/demo/file.md\"}"
jq -e 'select(.old_guards.repo_worktree=="allow" and .merged_decision=="allow")' "$LOG" >/dev/null || fail 'disabled repository guard still affected shadow result'
unset HQ_DISABLED_HOOKS
: > "$LOG"
run_on 'Edit protected path' Edit "{\"file_path\":\"$FAKE/core/example.md\"}"
jq -e 'select(.tool=="Edit" and .old_guards.core_native=="deny" and .merged_decision=="deny")' "$LOG" >/dev/null || fail 'native core denial was not recorded'
: > "$LOG"
run_on 'Write sanctioned worktree' Write "{\"file_path\":\"$FAKE/workspace/worktrees/demo/file.md\"}"
jq -e 'select(.old_guards.core_native=="allow" and .old_guards.repo_worktree=="allow" and .merged_decision=="allow")' "$LOG" >/dev/null || fail 'worktree allow was not recorded'
: > "$LOG"
run_on 'MultiEdit repo checkout' MultiEdit "{\"file_path\":\"$FAKE/repos/private/demo/file.md\"}"
jq -e 'select(.old_guards.repo_worktree=="deny" and .merged_decision=="deny")' "$LOG" >/dev/null || fail 'repo worktree denial was not recorded'
: > "$LOG"
run_on 'apply_patch core write' apply_patch "{\"patch\":\"*** Begin Patch\\n*** Add File: $FAKE/core/patched.md\\n+hello\\n*** End Patch\"}"
jq -e 'select(.tool=="apply_patch" and .old_guards.core_native=="deny" and .merged_decision=="deny")' "$LOG" >/dev/null || fail 'apply_patch old denial was not recorded'
: > "$LOG"
run_on 'Bash read allowed' Bash '{"command":"git status --short"}'
jq -e 'select(.old_guards.core_bash=="allow" and .merged_decision=="allow")' "$LOG" >/dev/null || fail 'read allow was not recorded'
: > "$LOG"
run_on 'Bash repo write is an independent candidate denial' Bash "{\"command\":\"echo x > $FAKE/repos/private/demo/file.md\"}"
jq -e 'select(.legacy_decision=="allow" and .merged_decision=="deny" and (.proposed_rule_ids|index("bash-repo-write")))' "$LOG" >/dev/null || fail 'stricter Bash repo write did not change the independent candidate decision'
matrix_case 'git -C add is a repo write proposal' Bash '{"command":"git -C repos/private/demo add file.md"}' allow
jq -e 'select(.merged_decision=="deny" and (.proposed_rule_ids|index("bash-repo-write")))' "$LOG" >/dev/null || fail 'git -C mutation was not proposed'
matrix_case 'repo read copied outside stays allowed' Bash '{"command":"cat repos/private/demo/file.md > /tmp/copy"}' allow
jq -e 'select(.merged_decision=="allow" and ((.proposed_rule_ids|index("bash-repo-write"))|not))' "$LOG" >/dev/null || fail 'repo read was misclassified as a repo write'
matrix_case 'repo source copied outside stays allowed' Bash '{"command":"cp repos/private/demo/file.md /tmp/copy"}' allow
jq -e 'select(.merged_decision=="allow" and ((.proposed_rule_ids|index("bash-repo-write"))|not))' "$LOG" >/dev/null || fail 'repo source operand was mistaken for a write target'
matrix_case 'later repo redirection survives earlier fetch' Bash '{"command":"git fetch; echo x > repos/private/demo/file.md"}' allow
jq -e 'select(.merged_decision=="deny" and (.proposed_rule_ids|index("bash-repo-write")))' "$LOG" >/dev/null || fail 'compound command repo write was suppressed'

matrix_case 'Bash append redirect' Bash "{\"command\":\"echo x >> $FAKE/core/append\"}" deny
matrix_case 'Bash tee write' Bash "{\"command\":\"printf x | tee $FAKE/core/tee\"}" deny
matrix_case 'Bash sed in-place write' Bash "{\"command\":\"sed -i s/a/b/ $FAKE/core/sed\"}" deny
matrix_case 'Bash cp write' Bash "{\"command\":\"cp $FAKE/source $FAKE/core/copy\"}" deny
matrix_case 'Bash mv write' Bash "{\"command\":\"mv $FAKE/source $FAKE/core/move\"}" deny
matrix_case 'Bash heredoc write' Bash "{\"command\":\"cat > $FAKE/core/heredoc <<'TXT'\\nvalue\\nTXT\"}" deny
matrix_case 'Bash python write candidate' Bash "{\"command\":\"python3 -c \\\"open('$FAKE/core/python','w').write('x')\\\"\"}" allow
matrix_case 'Bash node write candidate' Bash "{\"command\":\"node -e \\\"require('fs').writeFileSync('$FAKE/core/node','x')\\\"\"}" allow
matrix_case 'Bash subagent-style protected write' Bash "{\"command\":\"echo x > $FAKE/core/subagent\",\"agent_id\":\"worker-1\"}" deny
matrix_case 'Bash workspace worktree write allowed' Bash "{\"command\":\"echo x > $FAKE/workspace/worktrees/demo/bash\"}" allow
matrix_case 'sanctioned git fetch allowed' Bash '{"command":"git fetch origin"}' allow
matrix_case 'sanctioned git worktree add allowed' Bash "{\"command\":\"git worktree add $FAKE/workspace/worktrees/demo\"}" allow
matrix_case 'sanctioned repos sync allowed' Bash '{"command":"hq repos sync"}' allow
matrix_case 'Edit worktree allowed' Edit "{\"file_path\":\"$FAKE/workspace/worktrees/demo/edit.md\"}" allow
matrix_case 'Write worktree allowed' Write "{\"file_path\":\"$FAKE/workspace/worktrees/demo/write.md\"}" allow
matrix_case 'MultiEdit worktree allowed' MultiEdit "{\"edits\":[{\"file_path\":\"$FAKE/workspace/worktrees/demo/multi.md\"}]}" allow
matrix_case 'apply_patch worktree allowed' apply_patch "{\"patch\":\"*** Begin Patch\\n*** Add File: $FAKE/workspace/worktrees/demo/patch.md\\n+hello\\n*** End Patch\"}" allow

printf '{"tool":"Edit","merged_decision":"allow","old_guards":{"core_native":"allow","repo_worktree":"allow"}}\n{"tool":"Edit","merged_decision":"deny","old_guards":{"core_native":"allow","repo_worktree":"allow"}}\n' > "$TMP/summary.jsonl"
SUMMARY="$ROOT/core/scripts/merged-write-guard-shadow-summary.cjs"
node "$SUMMARY" "$TMP/summary.jsonl" > "$TMP/summary.out" || fail 'summary utility failed'
grep -q 'agreement rate: 1/2 (50.0%)' "$TMP/summary.out" || fail 'summary missing agreement rate'
grep -q 'disagreement.*Edit' "$TMP/summary.out" || fail 'summary omitted disagreement details'
echo 'ALL PASS: merged-write-guard-shadow'
