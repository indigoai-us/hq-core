#!/usr/bin/env bash
set -euo pipefail
TEST_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(git -C "$TEST_DIR/../../.." rev-parse --show-toplevel)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MASTER_SOURCE="${MASTER_HOOK_SOURCE_OVERRIDE:-$ROOT/.claude/hooks/master-hook.sh}"
FIXTURE="$TMP/candidate"
mkdir -p "$TMP/read-shim-bin" "$TMP/truncated-jq-bin"

prepare_fixture() {
  local fixture="$1"
  mkdir -p "$fixture/.claude/hooks" "$fixture/core/scripts/lib" \
    "$fixture/companies/indigo" "$fixture/workspace/sessions"
  cp "$MASTER_SOURCE" "$fixture/.claude/hooks/master-hook.sh"
  cp "$ROOT/.claude/hooks/hook-gate.sh" "$fixture/.claude/hooks/"
  cp "$ROOT/.claude/hooks/hook-timeout-probe.sh" "$fixture/.claude/hooks/"
  cp "$ROOT/.claude/hooks/block-company-repo-creation.sh" "$fixture/.claude/hooks/"
  cp "$ROOT/.claude/hooks/block-hq-root-git-mutation.sh" "$fixture/.claude/hooks/"
  cp "$ROOT/.claude/hooks/block-hq-root-git-mutation-flag.cjs" "$fixture/.claude/hooks/"
  cp "$ROOT/core/scripts/hook-lib.sh" "$fixture/core/scripts/"
  cp "$ROOT/core/scripts/resolve-hq-root.sh" "$fixture/core/scripts/"
  cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$fixture/core/scripts/lib/"
  jq '(.hooks.PreToolUse) |= map(.hooks |= map(select(.id == "block-company-repo-creation" or .id == "block-hq-root-git-mutation")) | select(.hooks | length > 0))' \
    "$ROOT/.claude/hooks/hook-registry.json" > "$fixture/.claude/hooks/hook-registry.json"
  cat > "$fixture/.claude/hooks/capture-dispatch-env.sh" <<'CAPTURE'
printf '%s\0%s\0%s\0%s\0' "${HQ_HOOK_TOOL_NAME-<unset>}" "${HQ_HOOK_CWD-<unset>}" "${HQ_HOOK_SESSION_ID-<unset>}" "${HQ_HOOK_COMMAND-<unset>}" > "$HQ_TEST_DISPATCH_ENV_FILE"
CAPTURE
  chmod +x "$fixture/.claude/hooks/capture-dispatch-env.sh"
  jq --arg script ".claude/hooks/capture-dispatch-env.sh" \
    '.hooks.PreToolUse += [{matcher:"Bash",hooks:[{id:"capture-dispatch-env-test",script:$script,timeout:10,gated:false,runner:"source"}]}]' \
    "$fixture/.claude/hooks/hook-registry.json" > "$TMP/registry.json"
  mv "$TMP/registry.json" "$fixture/.claude/hooks/hook-registry.json"
  git -C "$fixture" init -q
}
prepare_fixture "$FIXTURE"

# Simulate the system Bash on macOS rejecting read -N. The supported read -d
# framing remains available and delegates to the real Bash builtin.
cat > "$TMP/read-no-N.sh" <<'READSHIM'
read() {
  local argument
  for argument in "$@"; do
    if [[ "$argument" == "-N" ]]; then
      printf '%s\n' 'read: -N: invalid option' >&2
      return 2
    fi
  done
  builtin read "$@"
}
READSHIM

REAL_JQ="$(command -v jq)"
cat > "$TMP/truncated-jq-bin/jq" <<'JQ'
#!/usr/bin/env bash
if [[ "${HQ_TEST_TRUNCATE_COMMAND_EXTRACTION:-0}" == 1 ]] \
  && [[ "${1:-}" == "-j" && "${2:-}" == "--arg" && "${3:-}" == "ev" ]]; then
  # Supply valid Bash metadata but omit the command record terminator.
  printf 'Bash\037Bash\037%s\037%s\037\037%s\0' \
    "$HQ_TEST_SESSION" "$HQ_TEST_CWD" "$HQ_TEST_PREFILTER"
  exit 0
fi
exec "${HQ_TEST_REAL_JQ:?}" "$@"
JQ
chmod +x "$TMP/truncated-jq-bin/jq"

FAIL=0
PASS=0
SESSION="repogit-roundtrip-$RANDOM-$$"
run_dispatch() {
  local label="$1" template="$2" truncate="${3:-0}"
  local command_text payload prefilter rc=0
  command_text="${template//@@ROOT@@/$FIXTURE}"
  payload="$(jq -cn --arg sid "$SESSION" --arg cwd "$FIXTURE" --arg command "$command_text" \
    '{session_id:$sid,hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$cwd,tool_input:{command:$command}}')"
  prefilter="$(jq -cn --arg command "$command_text" '{command:$command}')"
  local -a run_env
  run_env=(env -u HQ_HOOK_EVENT -u HQ_HOOK_TOOL_NAME -u HQ_HOOK_COMMAND \
    -u HQ_HOOK_CWD -u HQ_HOOK_SESSION_ID -u HQ_HOOK_AGENT_ID \
    BASH_ENV="$TMP/read-no-N.sh" \
    CLAUDE_PROJECT_DIR="$FIXTURE" HQ_HOOK_DEDUPE=0 HQ_HOOK_TIMEOUT_SENTRY=0 \
    HQ_TEST_DISPATCH_ENV_FILE="$TMP/$label.env")
  if [[ "$truncate" == 1 ]]; then
    run_env+=(PATH="$TMP/truncated-jq-bin:$PATH" \
      HQ_TEST_TRUNCATE_COMMAND_EXTRACTION=1 HQ_TEST_REAL_JQ="$REAL_JQ" \
      HQ_TEST_SESSION="$SESSION" HQ_TEST_CWD="$FIXTURE" \
      HQ_TEST_PREFILTER="$prefilter")
  fi
  printf '%s' "$payload" | (
    cd "$FIXTURE"
    "${run_env[@]}" bash "$FIXTURE/.claude/hooks/master-hook.sh" PreToolUse \
      > "$TMP/$label.out" 2> "$TMP/$label.err"
  ) || rc=$?
  printf '%s\n' "$rc" > "$TMP/$label.rc"
}
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1" >&2; }
assert_deny() {
  local label="$1" marker="$2" rc
  rc="$(<"$TMP/$label.rc")"
  if [[ "$rc" == 2 ]] && grep -Fq "$marker" "$TMP/$label.err" \
    && [[ ! -s "$TMP/$label.out" ]]; then
    pass "$label denied with exit 2 and expected stderr"
  else
    fail "$label expected exit 2 and '$marker'; got exit $rc, stdout=$(<"$TMP/$label.out"), stderr=$(<"$TMP/$label.err")"
  fi
}
assert_allow() {
  local label="$1" rc
  rc="$(<"$TMP/$label.rc")"
  if [[ "$rc" == 0 && ! -s "$TMP/$label.err" && ! -s "$TMP/$label.out" ]]; then
    pass "$label allowed with no output"
  else
    fail "$label expected clean allow; got exit $rc, stderr=$(<"$TMP/$label.err")"
  fi
}

COMPANY_COMPONENT=com
COMPANY_COMPONENT+=panies
MULTILINE="$(printf 'printf ready\n git clone https://example.invalid/indigo/repo.git "@@ROOT@@/%s/indigo/repo-roundtrip"' "$COMPANY_COMPONENT")"
run_dispatch multiline-clone "$MULTILINE"
assert_deny multiline-clone "Git repositories cannot be created or populated under companies/"

CONTROL_BYTE="$(printf 'printf ready\037; git -C "@@ROOT@@" push origin main')"
run_dispatch control-byte-root-push "$CONTROL_BYTE"
assert_deny control-byte-root-push "BLOCKED: Anchor"

TRAILING_NEWLINE="$(printf 'git -C "@@ROOT@@" commit -m roundtrip\n')"
run_dispatch trailing-newline-root-commit "$TRAILING_NEWLINE"
assert_deny trailing-newline-root-commit "BLOCKED: Anchor"

run_dispatch readonly-status 'git -C /tmp/repo status'
assert_allow readonly-status

# Extraction failure must leave the command unset so the guard reparses stdin.
run_dispatch extraction-failure 'git -C "@@ROOT@@" push origin main' 1
assert_deny extraction-failure "BLOCKED: Anchor"
{
  IFS= read -r -d '' got_tool
  IFS= read -r -d '' got_cwd
  IFS= read -r -d '' got_session
  IFS= read -r -d '' got_command
} < "$TMP/extraction-failure.env"
if [[ "$got_tool" == Bash && "$got_cwd" == "$FIXTURE" \
  && "$got_session" == "$SESSION" && "$got_command" == '<unset>' ]]; then
  pass "failed command extraction leaves HQ_HOOK_COMMAND unset and preserves metadata"
else
  fail "failed extraction metadata wrong (tool=$got_tool cwd=$got_cwd session=$got_session command=$got_command)"
fi

# The parser's metadata must remain intact for commands containing newlines.
run_dispatch multiline-metadata "$MULTILINE"
{
  IFS= read -r -d '' got_tool
  IFS= read -r -d '' got_cwd
  IFS= read -r -d '' got_session
  IFS= read -r -d '' got_command
} < "$TMP/multiline-metadata.env"
expected_multiline="${MULTILINE//@@ROOT@@/$FIXTURE}"
if [[ "$got_tool" == Bash && "$got_cwd" == "$FIXTURE" \
  && "$got_session" == "$SESSION" && "$got_command" == "$expected_multiline" ]]; then
  pass "tool name, cwd, session id, and exact multiline command preserved"
else
  fail "dispatcher payload changed (tool=$got_tool cwd=$got_cwd session=$got_session command_matches=$([[ "$got_command" == "$expected_multiline" ]] && echo yes || echo no))"
fi

if (( FAIL )); then
  printf 'master-hook-repogit-command-roundtrip: %s passed, %s failed\n' "$PASS" "$FAIL" >&2
  exit 1
fi
printf 'master-hook-repogit-command-roundtrip: %s passed, 0 failed\n' "$PASS"
