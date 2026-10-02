#!/usr/bin/env bash
# Regression for the Codex hook workdir gap (openai/codex#32360).
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/codex-explicit-path.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

FIXTURE="$TMP/hq"
FIXTURE_CO=indigo
PROJECT="$FIXTURE/companies/$FIXTURE_CO/projects/p1"
mkdir -p "$PROJECT/backend" "$PROJECT/tests" "$PROJECT/my dir" "$FIXTURE/companies"
touch "$PROJECT/backend/file" "$PROJECT/patterns.txt"
git -C "$FIXTURE" init -q
mkdir -p "$FIXTURE/.codex/hooks" "$FIXTURE/.claude/hooks" "$FIXTURE/core/scripts/lib"

if [ "${CODEX_EXPLICIT_PATH_GUARD_BASELINE:-}" = "1" ]; then
  git -C "$ROOT" show origin/main:.codex/hooks/hq-codex-hook-adapter.sh > "$FIXTURE/.codex/hooks/hq-codex-hook-adapter.sh"
else
  cp "$ROOT/.codex/hooks/hq-codex-hook-adapter.sh" "$FIXTURE/.codex/hooks/"
fi
cp "$ROOT/.claude/hooks/hook-gate.sh" "$FIXTURE/.claude/hooks/"
cp "$ROOT/core/scripts/hook-lib.sh" "$FIXTURE/core/scripts/"
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$FIXTURE/core/scripts/lib/"
if [ -f "$ROOT/.codex/hooks/codex-explicit-path-guard.cjs" ]; then
  cp "$ROOT/.codex/hooks/codex-explicit-path-guard.cjs" "$FIXTURE/.codex/hooks/"
fi
if [ -f "$ROOT/.codex/hooks/codex-explicit-path-flag.cjs" ]; then
  cp "$ROOT/.codex/hooks/codex-explicit-path-flag.cjs" "$FIXTURE/.codex/hooks/"
fi
chmod +x "$FIXTURE/.codex/hooks/hq-codex-hook-adapter.sh" "$FIXTURE/.claude/hooks/hook-gate.sh"
ADAPTER="$FIXTURE/.codex/hooks/hq-codex-hook-adapter.sh"

# A fake installed CLI returns the test-selected hq-flags value without a
# network call or real credentials.
CLI="$TMP/cli"
mkdir -p "$CLI/bin" "$CLI/node_modules/@indigoai-us/hq-flags-client" \
  "$CLI/node_modules/@indigoai-us/hq-cloud" "$TMP/bin"
printf '%s\n' '{"name":"@indigoai-us/hq-cli"}' > "$CLI/package.json"
printf '#!/usr/bin/env sh\nexit 0\n' > "$CLI/bin/hq"
chmod +x "$CLI/bin/hq"
ln -s "$CLI/bin/hq" "$TMP/bin/hq"
printf '%s\n' '{"type":"module","exports":{".":{"import":"./index.js"}}}' \
  > "$CLI/node_modules/@indigoai-us/hq-flags-client/package.json"
cat > "$CLI/node_modules/@indigoai-us/hq-flags-client/index.js" <<'JS'
export const createFlagClient = () => ({
  ready: async () => {},
  snapshot: () => ({ flags: {
    "hooks.codex-explicit-path-guard": process.env.HQ_TEST_EXPLICIT_PATH_FLAG === "true",
  } }),
  close: () => {},
});
JS
printf '%s\n' '{"type":"module","exports":{".":{"import":"./index.js"}}}' \
  > "$CLI/node_modules/@indigoai-us/hq-cloud/package.json"
printf '%s\n' 'export const loadCachedTokens = () => ({ idToken: "test-only-token" });' \
  > "$CLI/node_modules/@indigoai-us/hq-cloud/index.js"

write_transcript() {
  local path="$1" command="$2" workdir="$3"
  jq -nc --arg cmd "$command" \
    '{type:"response_item",payload:{type:"function_call",name:"exec_command",arguments:({cmd:$cmd,workdir:"companies/indigo/projects/older"}|tojson)}}' > "$path"
  jq -nc --arg cmd "$command" --arg wd "$workdir" \
    '{type:"response_item",payload:{type:"function_call",name:"shell",arguments:({cmd:$cmd,workdir:$wd}|tojson)}}' >> "$path"
}

run_adapter() {
  local command="$1" transcript="${2:-}" enabled="${3:-true}" payload out err rc=0
  payload="$(jq -nc --arg cwd "$FIXTURE" --arg cmd "$command" --arg transcript "$transcript" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$cwd,tool_input:{command:$cmd}}
      + (if $transcript == "" then {} else {transcript_path:$transcript} end)')"
  OUT="$TMP/out"
  ERR="$TMP/err"
  printf '%s' "$payload" | (
    cd /
    env -u HQ_ROOT PATH="$TMP/bin:$PATH" HQ_CLI_BIN="$CLI/bin/hq" \
      HQ_FLAGS_API_URL=https://flags.invalid HQ_COMPANY_UID=cmp_test123 \
      HQ_COMPANY_SLUG=indigo HQ_TEST_EXPLICIT_PATH_FLAG="$enabled" \
      HQ_DISABLED_HOOKS="detect-secrets,block-env-dump,block-core-writes-bash,enforce-vault-write-access,block-on-active-run,inject-policy-on-trigger,block-unsafe-package-install,block-qmd-model-download,mandatory-scope-authorizer,block-hq-root-git-mutation" \
      bash "$ADAPTER"
  ) >"$OUT" 2>"$ERR" || rc=$?
  return "$rc"
}

# Codex 0.159+ code mode records shell calls as a custom_tool_call "exec" whose
# input is JavaScript calling tools.exec_command({...}).
write_code_mode_transcript() {
  local path="$1" command="$2" workdir="$3" call
  call="$(jq -nc --arg cmd "$command" --arg wd "$workdir" '{cmd:$cmd,workdir:$wd,yield_time_ms:10000,max_output_tokens:10000}')"
  jq -nc --arg input "const r = await tools.exec_command(${call});
text(JSON.stringify(r));
" '{type:"response_item",payload:{type:"custom_tool_call",id:"ctc_1",status:"completed",call_id:"call_1",name:"exec",input:$input}}' > "$path"
}


PASS=0
FAIL=0
denied() {
  local label="$1" command="$2" transcript="$3" expected="$4" rc=0
  run_adapter "$command" "$transcript" true || rc=$?
  if [ "$rc" -eq 0 ] && jq -e --arg expected "$expected" \
    '.hookSpecificOutput.permissionDecision == "deny" and
     (.hookSpecificOutput.permissionDecisionReason | contains($expected))' "$OUT" >/dev/null; then
    PASS=$((PASS + 1)); printf 'ok %s\n' "$label"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL %s (rc=%s output=%s stderr=%s)\n' "$label" "$rc" "$(cat "$OUT")" "$(cat "$ERR")" >&2
  fi
}
allowed() {
  local label="$1" command="$2" transcript="${3:-}" enabled="${4:-true}" rc=0
  run_adapter "$command" "$transcript" "$enabled" || rc=$?
  if [ "$rc" -eq 0 ] && ! jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$OUT" >/dev/null 2>&1; then
    PASS=$((PASS + 1)); printf 'ok %s\n' "$label"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL %s (rc=%s output=%s stderr=%s)\n' "$label" "$rc" "$(cat "$OUT")" "$(cat "$ERR")" >&2
  fi
}

TRANSCRIPT="$TMP/transcript.jsonl"
write_transcript "$TRANSCRIPT" 'ls backend tests' "$PROJECT"
denied 'relative ls paths rewritten from latest exec workdir' 'ls backend tests' "$TRANSCRIPT" \
  "companies/$FIXTURE_CO/projects/p1/backend companies/$FIXTURE_CO/projects/p1/tests"

write_transcript "$TRANSCRIPT" "ls 'my dir'" "$PROJECT"
denied 'quoted relative operand is rewritten with POSIX quoting' "ls 'my dir'" "$TRANSCRIPT" \
  "'companies/$FIXTURE_CO/projects/p1/my dir'"

write_transcript "$TRANSCRIPT" "rg 'foo|bar' backend" "$PROJECT"
denied 'quoted regex operator stays literal while path is rewritten' "rg 'foo|bar' backend" "$TRANSCRIPT" \
  "companies/$FIXTURE_CO/projects/p1/backend"

write_transcript "$TRANSCRIPT" 'grep -e needle backend/file' "$PROJECT"
denied 'grep -e pattern leaves positional file as path' 'grep -e needle backend/file' "$TRANSCRIPT" \
  "companies/$FIXTURE_CO/projects/p1/backend/file"

write_transcript "$TRANSCRIPT" 'grep -f patterns.txt backend/file' "$PROJECT"
denied 'grep -f pattern file and positional file are rewritten' 'grep -f patterns.txt backend/file' "$TRANSCRIPT" \
  "companies/$FIXTURE_CO/projects/p1/patterns.txt companies/$FIXTURE_CO/projects/p1/backend/file"

write_transcript "$TRANSCRIPT" 'ls --color backend' "$PROJECT"
denied 'ls color option does not consume the path' 'ls --color backend' "$TRANSCRIPT" \
  "companies/$FIXTURE_CO/projects/p1/backend"

write_transcript "$TRANSCRIPT" 'ls --hyperlink backend' "$PROJECT"
denied 'ls hyperlink option does not consume the path' 'ls --hyperlink backend' "$TRANSCRIPT" \
  "companies/$FIXTURE_CO/projects/p1/backend"

write_transcript "$TRANSCRIPT" 'git status' "$PROJECT"
denied 'unanchored git gets project -C rewrite' 'git status' "$TRANSCRIPT" \
  "git -C companies/$FIXTURE_CO/projects/p1 status"

denied 'missing transcript shows placeholder guidance' 'ls backend tests' '' \
  'Codex does not pass the tool workdir to PreToolUse hooks (openai/codex#32360)'
if [[ "$(cat "$OUT")" == *'<project-dir>/backend <project-dir>/tests'* \
   && "$(cat "$OUT")" == *'git -C <project-dir> status'* ]]; then
  PASS=$((PASS + 1)); echo 'ok no-transcript message includes both rewrite forms'
else
  FAIL=$((FAIL + 1)); echo 'FAIL no-transcript message omitted placeholder forms' >&2
fi

write_transcript "$TRANSCRIPT" 'ls backend' "$PROJECT"
jq -nc --arg cmd 'ls backend' \
  '{type:"response_item",payload:{type:"function_call",name:"shell",arguments:({cmd:$cmd}|tojson)}}' >> "$TRANSCRIPT"
denied 'newest matching call without workdir clears stale transcript directory' 'ls backend' "$TRANSCRIPT" \
  '<project-dir>/backend'
if [[ "$(cat "$OUT")" == *"companies/$FIXTURE_CO/projects/p1/backend"* ]]; then
  FAIL=$((FAIL + 1)); echo 'FAIL stale workdir was reused' >&2
else
  PASS=$((PASS + 1)); echo 'ok stale workdir was not reused'
fi

write_code_mode_transcript "$TRANSCRIPT" 'ls backend tests' "$PROJECT"
denied 'code-mode exec record supplies the workdir for ls' 'ls backend tests' "$TRANSCRIPT" \
  "companies/$FIXTURE_CO/projects/p1/backend companies/$FIXTURE_CO/projects/p1/tests"

write_code_mode_transcript "$TRANSCRIPT" 'git status --short' "$PROJECT"
denied 'code-mode exec record supplies the workdir for git' 'git status --short' "$TRANSCRIPT" \
  "git -C companies/$FIXTURE_CO/projects/p1 status --short"


allowed 'paths that exist from HQ root are untouched' 'ls companies' '' true
allowed 'absolute path operands are untouched' "ls $TMP" '' true
allowed 'git -C is already explicitly anchored' 'git -C x status' '' true
write_transcript "$TMP/root-transcript" 'ls missing' "$FIXTURE"
allowed 'root workdir does not create an identical rewrite' 'ls missing' "$TMP/root-transcript" true
allowed 'compound shell command fails open' 'ls backend && pwd' "$TRANSCRIPT" true
allowed 'glob operand fails open' 'ls *.md' "$TRANSCRIPT" true
allowed 'flag-off behavior is unchanged' 'ls backend tests' "$TRANSCRIPT" false

printf 'codex-explicit-path-guard: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
