#!/usr/bin/env bash
set -euo pipefail
TEST_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(git -C "$TEST_DIR/../../.." rev-parse --show-toplevel)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MASTER_SOURCE="${MASTER_HOOK_SOURCE_OVERRIDE:-$ROOT/.claude/hooks/master-hook.sh}"
FIXTURE="$TMP/candidate"
mkdir -p "$TMP/read-shim-bin" "$TMP/truncated-jq-bin" "$TMP/crlf-jq-bin"

prepare_fixture() {
  local fixture="$1"
  mkdir -p "$fixture/.claude/hooks" "$fixture/core/scripts/lib" \
    "$fixture/companies/example-co" "$fixture/workspace/sessions"
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
  printf 'Bash\037Bash\037%s\037%s\037\037\037%s\036' \
    "$HQ_TEST_SESSION" "$HQ_TEST_CWD" "$HQ_TEST_PREFILTER"
  exit 0
fi
exec "${HQ_TEST_REAL_JQ:?}" "$@"
JQ
chmod +x "$TMP/truncated-jq-bin/jq"

# Native Windows jq.exe writes stdout in text mode: each LF in its output
# becomes CRLF. On macOS and Linux this wrapper reproduces that, so the
# large-command fallback is tested the way Windows runs it. On Windows the
# real jq.exe already does it and the wrapper is not used.
cat > "$TMP/crlf-jq-bin/jq" <<'JQ'
#!/usr/bin/env bash
set -o pipefail
"${HQ_TEST_REAL_JQ:?}" "$@" | perl -pe 's/\n/\r\n/g'
JQ
chmod +x "$TMP/crlf-jq-bin/jq"
NATIVE_CRLF=0
if [[ "$(printf '"a\\nb"' | jq -j . | od -An -c | tr -d ' \n')" == 'a\r\nb' ]]; then
  NATIVE_CRLF=1
fi

FAIL=0
PASS=0
SESSION="repogit-roundtrip-$RANDOM-$$"
# Build hook JSON without putting the command text on jq's argv.
# Windows CreateProcess rejects an argument list over 32767 bytes (jq exits
# 126, "Argument list too long"), so the 40 KB case never reached the hook.
# The command bytes stay in a file. Git Bash rewrites Unix-looking arguments
# of native jq.exe, so the --rawfile path is a native Windows path when
# cygpath exists and that path is excluded from MSYS conversion. The command
# text itself is file contents, not an argument, and is not rewritten.
jq_exact() {
  local rawfile="$1"
  shift
  if command -v cygpath >/dev/null 2>&1; then
    rawfile="$(cygpath -w "$rawfile")"
    MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1 jq --rawfile command "$rawfile" "$@"
  else
    jq --rawfile command "$rawfile" "$@"
  fi
}
run_dispatch() {
  local label="$1" template="$2" truncate="${3:-0}" dispatch_cwd="${4:-$FIXTURE}" crlf="${5:-0}"
  local command_text payload prefilter rc=0 command_file
  command_text="${template//@@ROOT@@/$FIXTURE}"
  command_file="$TMP/$label.command"
  printf '%s' "$command_text" > "$command_file"
  payload="$(jq_exact "$command_file" -cn --arg sid "$SESSION" --arg cwd "$dispatch_cwd" \
    '{session_id:$sid,hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$cwd,tool_input:{command:$command}}')"
  prefilter="$(jq_exact "$command_file" -cn '{command:$command}')"
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
  if [[ "$crlf" == 1 && "$NATIVE_CRLF" == 0 ]]; then
    run_env+=(PATH="$TMP/crlf-jq-bin:$PATH" HQ_TEST_REAL_JQ="$REAL_JQ")
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
MULTILINE="$(printf 'printf ready\n git clone https://example.invalid/example-co/repo.git "@@ROOT@@/%s/example-co/repo-roundtrip"' "$COMPANY_COMPONENT")"
# Payload cwd must be a different git repo than the fixture HQ root. An
# unanchored clone is denied by block-hq-root-git-mutation first when that
# cwd's toplevel is the HQ root, and the companies/ guard never runs. On
# macOS, mktemp (/var) and git toplevel (/private/var) disagree, so the
# unanchored guard used to allow by accident. A separate repo makes the
# companies/ denial the one both platforms assert.
mkdir -p "$TMP/elsewhere"
git -C "$TMP/elsewhere" init -q
run_dispatch multiline-clone "$MULTILINE" 0 "$TMP/elsewhere"
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

# Oversized Bash commands must not be exported (Windows env-var cap); the
# guard still blocks by reparsing stdin.
PADDING="$(printf "%040000d" 0)"
LARGE="printf '%s' $PADDING >/dev/null; git -C \"@@ROOT@@\" push origin main"
run_dispatch large-command "$LARGE"
assert_deny large-command "BLOCKED: Anchor"
{
  IFS= read -r -d '' got_tool
  IFS= read -r -d '' got_cwd
  IFS= read -r -d '' got_session
  IFS= read -r -d '' got_command
} < "$TMP/large-command.env"
if [[ "$got_tool" == Bash && "$got_command" == '<unset>' ]]; then
  pass "oversized command leaves HQ_HOOK_COMMAND unset"
else
  fail "oversized command exported (${#got_command} chars)"
fi

# The cap counts bytes. 16,000 emoji are under 16,384 characters, but Windows
# counts 32,000 UTF-16 units, and the variable would not fit next to its name.
# Run master-hook under a UTF-8 locale so a character count would differ.
UTF8_LOCALE=""
for candidate in C.UTF-8 en_US.UTF-8; do
  if [[ "$(LC_ALL="$candidate" bash -c 's=$'"'"'\xe2\x82\xac'"'"'; printf %s "${#s}"' 2>/dev/null)" == 1 ]]; then
    UTF8_LOCALE="$candidate"
    break
  fi
done
EMOJI="$(printf '%16000s' '')"
EMOJI="${EMOJI// /$'\xf0\x9f\x98\x80'}"
if [[ -n "$UTF8_LOCALE" ]]; then
  LC_ALL="$UTF8_LOCALE" run_dispatch multibyte-command "printf '%s' $EMOJI >/dev/null; git -C \"@@ROOT@@\" push origin main"
else
  printf 'no UTF-8 locale found; multibyte case runs under the C locale\n'
  run_dispatch multibyte-command "printf '%s' $EMOJI >/dev/null; git -C \"@@ROOT@@\" push origin main"
fi
assert_deny multibyte-command "BLOCKED: Anchor"
{
  IFS= read -r -d '' got_tool
  IFS= read -r -d '' got_cwd
  IFS= read -r -d '' got_session
  IFS= read -r -d '' got_command
} < "$TMP/multibyte-command.env"
if [[ "$got_tool" == Bash && "$got_command" == '<unset>' ]]; then
  pass "multibyte command over the byte cap leaves HQ_HOOK_COMMAND unset"
else
  fail "multibyte command under 16384 characters but over the byte cap was exported"
fi

# Over the cap, the guards reparse stdin. jq.exe's output there is CRLF, so a
# multiline command used to reach them as `cd <path>\r` and `init\r`. It was
# allowed while the same command under the cap was denied. The cd sits on its
# own line so the CR lands where it changes the match.
LARGE_PREFIX="printf '%s' ${PADDING:0:20000} >/dev/null"$'\n'
ROOT_COMMIT='cd "@@ROOT@@"'$'\n'' git commit -m x'
COMPANY_INIT='cd "@@ROOT@@/'"$COMPANY_COMPONENT"'/example-co"'$'\n'' git init'
for crlf in 0 1; do
  for size in small large; do
    prefix=""
    [[ "$size" == large ]] && prefix="$LARGE_PREFIX"
    run_dispatch "root-commit-$size-crlf$crlf" "$prefix$ROOT_COMMIT" 0 "$TMP/elsewhere" "$crlf"
    assert_deny "root-commit-$size-crlf$crlf" "BLOCKED"
    run_dispatch "company-init-$size-crlf$crlf" "$prefix$COMPANY_INIT" 0 "$TMP/elsewhere" "$crlf"
    assert_deny "company-init-$size-crlf$crlf" "Git repositories cannot be created or populated under $COMPANY_COMPONENT/"
  done
done

# A payload over 16 KB takes several read -N blocks on stdin and on the jq
# output. The command must come through byte for byte. Unit separators are
# six characters each in JSON, so this payload is over 16 KB while the
# command stays under the export cap and reaches the hooks in HQ_HOOK_COMMAND.
printf -v US_RUN '%3000s' ''
US_RUN="${US_RUN// /$'\037'}"
printf -v NL_RUN '%2000s' ''
NL_RUN="${NL_RUN// /$'\n'}"
FILE_PATH_COMMAND="printf a"$'\t'"b"$'\r'"c ${US_RUN} ${NL_RUN} done"$'\n'
for crlf in 0 1; do
  run_dispatch "file-path-roundtrip-crlf$crlf" "$FILE_PATH_COMMAND" 0 "$FIXTURE" "$crlf"
  payload_chars="$(jq_exact "$TMP/file-path-roundtrip-crlf$crlf.command" -cn --arg sid "$SESSION" --arg cwd "$FIXTURE" \
    '{session_id:$sid,hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$cwd,tool_input:{command:$command}} | tojson | length')"
  {
    IFS= read -r -d '' got_tool
    IFS= read -r -d '' got_cwd
    IFS= read -r -d '' got_session
    IFS= read -r -d '' got_command
  } < "$TMP/file-path-roundtrip-crlf$crlf.env"
  if (( payload_chars > 16384 )) && [[ "$got_tool" == Bash && "$got_cwd" == "$FIXTURE" \
    && "$got_session" == "$SESSION" && "$got_command" == "$FILE_PATH_COMMAND" ]]; then
    pass "payload over 16 KB (${payload_chars} chars, crlf=$crlf) keeps the exact command and metadata"
  else
    fail "payload over 16 KB (${payload_chars} chars, crlf=$crlf) changed (tool=$got_tool cwd=$got_cwd session=$got_session command_matches=$([[ "$got_command" == "$FILE_PATH_COMMAND" ]] && echo yes || echo no))"
  fi
done

# RS (0x1e) frames the jq output. One inside the command must not end the
# command early, and one in a metadata field must not end the metadata
# record: the guards must still see the push and the real cwd.
RS_COMMAND="printf a"$'\036'"b; git -C \"@@ROOT@@\" push origin main"$'\036'
for crlf in 0 1; do
  run_dispatch "rs-command-crlf$crlf" "$RS_COMMAND" 0 "$FIXTURE" "$crlf"
  assert_deny "rs-command-crlf$crlf" "BLOCKED: Anchor"
  {
    IFS= read -r -d '' got_tool
    IFS= read -r -d '' got_cwd
    IFS= read -r -d '' got_session
    IFS= read -r -d '' got_command
  } < "$TMP/rs-command-crlf$crlf.env"
  expected_rs="${RS_COMMAND//@@ROOT@@/$FIXTURE}"
  if [[ "$got_tool" == Bash && "$got_cwd" == "$FIXTURE" \
    && "$got_session" == "$SESSION" && "$got_command" == "$expected_rs" ]]; then
    pass "command with RS bytes (crlf=$crlf) keeps the exact command and metadata"
  else
    fail "command with RS bytes (crlf=$crlf) changed (tool=$got_tool cwd=$got_cwd session=$got_session command_matches=$([[ "$got_command" == "$expected_rs" ]] && echo yes || echo no))"
  fi
done

# A JSON \u0000 in the command: jq cuts the command at it, as the read -d
# framing did, and read -N never sees a raw NUL. The text before it reaches
# the hooks; the metadata stays intact. Git Bash would rewrite the
# Unix-looking cwd argument of native jq.exe to a Windows path, so the
# argument is excluded from MSYS conversion, as in jq_exact.
NUL_PAYLOAD="$(MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1 jq -cn --arg sid "$SESSION" --arg cwd "$FIXTURE" \
  --arg before "git -C \"$FIXTURE\" push origin main" \
  '{session_id:$sid,hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$cwd,tool_input:{command:($before + "\u0000; echo after")}}')"
printf '%s' "$NUL_PAYLOAD" | (
  cd "$FIXTURE"
  env -u HQ_HOOK_EVENT -u HQ_HOOK_TOOL_NAME -u HQ_HOOK_COMMAND \
    -u HQ_HOOK_CWD -u HQ_HOOK_SESSION_ID -u HQ_HOOK_AGENT_ID \
    CLAUDE_PROJECT_DIR="$FIXTURE" HQ_HOOK_DEDUPE=0 HQ_HOOK_TIMEOUT_SENTRY=0 \
    HQ_TEST_DISPATCH_ENV_FILE="$TMP/nul-command.env" \
    bash "$FIXTURE/.claude/hooks/master-hook.sh" PreToolUse \
    > "$TMP/nul-command.out" 2> "$TMP/nul-command.err"
) && printf '0\n' > "$TMP/nul-command.rc" || printf '%s\n' "$?" > "$TMP/nul-command.rc"
assert_deny nul-command "BLOCKED: Anchor"
{
  IFS= read -r -d '' got_tool
  IFS= read -r -d '' got_cwd
  IFS= read -r -d '' got_session
  IFS= read -r -d '' got_command
} < "$TMP/nul-command.env"
if [[ "$got_tool" == Bash && "$got_cwd" == "$FIXTURE" && "$got_session" == "$SESSION" \
  && "$got_command" == "git -C \"$FIXTURE\" push origin main" ]]; then
  pass "command with a NUL is cut at the NUL and keeps its metadata"
else
  fail "command with a NUL changed (tool=$got_tool cwd=$got_cwd session=$got_session command=$got_command)"
fi

if (( FAIL )); then
  printf 'master-hook-repogit-command-roundtrip: %s passed, %s failed\n' "$PASS" "$FAIL" >&2
  exit 1
fi
printf 'master-hook-repogit-command-roundtrip: %s passed, 0 failed\n' "$PASS"
