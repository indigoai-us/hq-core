#!/usr/bin/env bash
# hq-core: public
# Regression coverage for the fail-open repo merge-hold PreToolUse shim.

set -uo pipefail

ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
HOOK="$ROOT/.claude/hooks/lanes-repo-merge-hold.sh"
GATE="$ROOT/.claude/hooks/hook-gate.sh"
MASTER="$ROOT/.claude/hooks/master-hook.sh"
REGISTRY="$ROOT/.claude/hooks/hook-registry.json"
CODEX_ADAPTER="$ROOT/.codex/hooks/hq-codex-hook-adapter.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lanes-hold-check-shim.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

for tool in bash jq mktemp; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: required test tool missing: $tool" >&2; exit 1; }
done

BIN="$TMP/bin"
mkdir -p "$BIN"
TEST_PATH="$BIN:$PATH"
pass=0
fail=0
LAST_RC=0
LAST_OUT=""
LAST_ERR=""

ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1" >&2; }

cat > "$BIN/hq" <<'SH'
#!/usr/bin/env bash
if [ "${HQ_NO_UPDATE_CHECK:-}" != "1" ]; then
  printf 'HQ_NO_UPDATE_CHECK missing\n' >&2
  exit 97
fi
printf 'called\n' >> "$HQ_HOLD_TEST_CALL_FILE"
printf '%s\0' "$@" >> "$HQ_HOLD_TEST_ARGV_FILE"
if [ -n "${HQ_HOLD_TEST_SLEEP:-}" ]; then
  exec sleep "$HQ_HOLD_TEST_SLEEP"
fi
printf '%s' "${HQ_HOLD_TEST_STDOUT:-}"
printf '%s' "${HQ_HOLD_TEST_STDERR:-}" >&2
exit "${HQ_HOLD_TEST_EXIT:-0}"
SH
chmod +x "$BIN/hq"

clear_stub_receipts() {
  : > "$TMP/calls"
  : > "$TMP/argv"
}

payload() {
  jq -nc --arg cmd "$1" --arg root "$ROOT" \
    '{session_id:"lanes-hold-check-test",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$root,tool_input:{command:$cmd}}'
}

# invoke_direct <command> [ENV=value ...]
invoke_direct() {
  local command_text="$1" rc=0 input
  shift
  clear_stub_receipts
  input="$(payload "$command_text")"
  printf '%s' "$input" \
    | env "PATH=$TEST_PATH" \
        "HQ_HOLD_TEST_CALL_FILE=$TMP/calls" \
        "HQ_HOLD_TEST_ARGV_FILE=$TMP/argv" \
        "$@" bash "$HOOK" >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
  LAST_RC="$rc"
  LAST_OUT="$(cat "$TMP/stdout")"
  LAST_ERR="$(cat "$TMP/stderr")"
}

invoke_raw() {
  local input="$1" rc=0
  shift
  clear_stub_receipts
  printf '%s' "$input" \
    | env "PATH=$TEST_PATH" \
        "HQ_HOLD_TEST_CALL_FILE=$TMP/calls" \
        "HQ_HOLD_TEST_ARGV_FILE=$TMP/argv" \
        "$@" bash "$HOOK" >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
  LAST_RC="$rc"
  LAST_OUT="$(cat "$TMP/stdout")"
  LAST_ERR="$(cat "$TMP/stderr")"
}

has_one_named_diagnostic() {
  local lines
  [ -n "$LAST_ERR" ] || return 1
  lines="$(printf '%s\n' "$LAST_ERR" | wc -l | tr -d '[:space:]')"
  [ "$lines" = 1 ] && [[ "$LAST_ERR" == lanes-repo-merge-hold:* ]]
}

HOLD_JSON='{"ok":false,"error":"repo_merge_held","repo":"acme/widgets","reason":"incident freeze","until":"2026-10-01T12:00:00Z"}'

echo '[1] non-merge commands pass without invoking hq'
invoke_direct 'git status'
if [ "$LAST_RC" = 0 ] && [ -z "$LAST_OUT" ] && [ -z "$LAST_ERR" ] && [ ! -s "$TMP/calls" ]; then
  ok 'non-merge command is silent and does not call hq'
else
  bad "non-merge command is silent and does not call hq (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
fi

echo '[1b] shell-quoted merge tokens still reach hq-cli'
invoke_direct 'gh pr m"erge" 5 -R acme/widgets --squash' \
  'HQ_HOLD_TEST_EXIT=3' "HQ_HOLD_TEST_STDOUT=$HOLD_JSON"
if [ "$LAST_RC" = 0 ] && [ -s "$TMP/calls" ] \
  && jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$LAST_OUT" >/dev/null 2>&1; then
  ok 'double-quoted token concatenation reaches hq and denies'
else
  bad "double-quoted token concatenation reaches hq and denies (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
fi

for quoted_command in \
  "gh pr m'er'ge 5 -R acme/widgets --squash" \
  'gh pr me\rge 5 -R acme/widgets --squash'; do
  invoke_direct "$quoted_command" \
    'HQ_HOLD_TEST_EXIT=3' "HQ_HOLD_TEST_STDOUT=$HOLD_JSON"
  if [ "$LAST_RC" = 0 ] && [ -s "$TMP/calls" ] \
    && jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$LAST_OUT" >/dev/null 2>&1; then
    ok "shell-escaped token reaches hq and denies ($quoted_command)"
  else
    bad "shell-escaped token reaches hq and denies ($quoted_command; rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
  fi
done

invoke_direct 'mkdir -p /tmp/every/rg/e'
if [ "$LAST_RC" = 0 ] && [ -z "$LAST_OUT" ] && [ -z "$LAST_ERR" ] && [ ! -s "$TMP/calls" ]; then
  ok 'ordered letters spread across words do not start hq'
else
  bad "ordered letters spread across words do not start hq (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
fi

echo '[1c] malformed PreToolUse payloads allow with one diagnostic'
for malformed in \
  'not-json' \
  '{"tool_name":"Bash"}' \
  '{"tool_name":"Bash","tool_input":{"command":42}}'; do
  invoke_raw "$malformed"
  if [ "$LAST_RC" = 0 ] && [ -z "$LAST_OUT" ] && has_one_named_diagnostic \
    && [ ! -s "$TMP/calls" ]; then
    ok "malformed payload allows with one diagnostic (input=$malformed)"
  else
    bad "malformed payload allows with one diagnostic (input=$malformed, rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
  fi
done

echo '[2] hq exit 3 becomes a structured Claude deny'
invoke_direct 'gh pr merge 5 -R acme/widgets --squash' \
  "HQ_HOLD_TEST_EXIT=3" "HQ_HOLD_TEST_STDOUT=$HOLD_JSON"
if [ "$LAST_RC" = 0 ] \
  && jq -e --arg repo 'acme/widgets' --arg reason 'incident freeze' --arg until '2026-10-01T12:00:00Z' '
    .hookSpecificOutput.hookEventName == "PreToolUse"
    and .hookSpecificOutput.permissionDecision == "deny"
    and (.hookSpecificOutput.permissionDecisionReason | contains($repo))
    and (.hookSpecificOutput.permissionDecisionReason | contains($reason))
    and (.hookSpecificOutput.permissionDecisionReason | contains($until))
    and (.hookSpecificOutput.permissionDecisionReason | contains("hq lanes hold show acme/widgets"))
  ' <<<"$LAST_OUT" >/dev/null; then
  ok 'exit 3 denies with repo, hold reason, until, and details command'
else
  bad "exit 3 denies with repo, hold reason, until, and details command (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
fi

echo '[2b] any valid exit-3 error denies'
REVIEW_MISSING_JSON='{"ok":false,"error":"review_record_missing","message":"review record is missing"}'
invoke_direct 'gh pr merge 5 -R acme/widgets --squash' \
  'HQ_HOLD_TEST_EXIT=3' "HQ_HOLD_TEST_STDOUT=$REVIEW_MISSING_JSON"
if [ "$LAST_RC" = 0 ] && jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("lanes-repo-merge-hold: review record is missing"))' <<<"$LAST_OUT" >/dev/null 2>&1; then
  ok 'review_record_missing exit 3 denies with its message'
else
  bad "review_record_missing exit 3 denies with its message (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
fi

UNKNOWN_ERROR_JSON='{"ok":false,"error":"review_head_mismatch"}'
invoke_direct 'gh pr merge 5 -R acme/widgets --squash' \
  'HQ_HOLD_TEST_EXIT=3' "HQ_HOLD_TEST_STDOUT=$UNKNOWN_ERROR_JSON"
if [ "$LAST_RC" = 0 ] && jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("review_head_mismatch for unknown repo"))' <<<"$LAST_OUT" >/dev/null 2>&1; then
  ok 'exit 3 without a message denies with the error and unknown-repo fallback'
else
  bad "exit 3 without a message denies with the error and unknown-repo fallback (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
fi

for invalid_exit3 in '{"ok":true,"error":"repo_merge_held"}' 'not-json'; do
  invoke_direct 'gh pr merge 5 -R acme/widgets --squash' \
    'HQ_HOLD_TEST_EXIT=3' "HQ_HOLD_TEST_STDOUT=$invalid_exit3"
  if [ "$LAST_RC" = 0 ] && [ -z "$LAST_OUT" ] && has_one_named_diagnostic \
    && [ -s "$TMP/calls" ]; then
    ok "non-conforming exit-3 output allows with one diagnostic (output=$invalid_exit3)"
  else
    bad "non-conforming exit-3 output allows with one diagnostic (output=$invalid_exit3, rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
  fi
done

echo '[3] hq exit 0 allows silently'
invoke_direct 'gh pr merge 5 -R acme/widgets --squash' \
  'HQ_HOLD_TEST_EXIT=0' 'HQ_HOLD_TEST_STDOUT={"ok":true}'
if [ "$LAST_RC" = 0 ] && [ -z "$LAST_OUT" ] && [ -z "$LAST_ERR" ] && [ -s "$TMP/calls" ]; then
  ok 'exit 0 allows silently'
else
  bad "exit 0 allows silently (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
fi

echo '[4] unexpected hq results fail open with one named diagnostic'
for code in 1 2; do
  invoke_direct 'gh pr merge 5 -R acme/widgets' "HQ_HOLD_TEST_EXIT=$code" \
    'HQ_HOLD_TEST_STDERR=simulated hq failure'
  if [ "$LAST_RC" = 0 ] && [ -z "$LAST_OUT" ] && has_one_named_diagnostic; then
    ok "exit $code allows with one named diagnostic"
  else
    bad "exit $code allows with one named diagnostic (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
  fi
done

invoke_direct 'gh pr merge 5 -R acme/widgets' 'HQ_HOLD_TEST_EXIT=1' \
  "HQ_HOLD_TEST_STDERR=unknown command: lanes hold"
if [ "$LAST_RC" = 0 ] && [ -z "$LAST_OUT" ] && has_one_named_diagnostic; then
  ok 'older hq without lanes hold allows with one named diagnostic'
else
  bad "older hq without lanes hold allows with one named diagnostic (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
fi

echo '[5] timeout and missing hq fail open'
start="$SECONDS"
invoke_direct 'gh pr merge 5 -R acme/widgets' 'HQ_HOLD_TEST_SLEEP=8'
elapsed=$((SECONDS - start))
if [ "$LAST_RC" = 0 ] && [ -z "$LAST_OUT" ] && has_one_named_diagnostic && [ "$elapsed" -lt 8 ]; then
  ok "timed-out hq allows with one named diagnostic (elapsed=${elapsed}s)"
else
  bad "timed-out hq allows within the short bound (elapsed=${elapsed}s, rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
fi

MISSING_HQ_BIN="$TMP/no-hq-bin"
mkdir -p "$MISSING_HQ_BIN"
for tool in bash jq mktemp rm cat timeout gtimeout perl; do
  path="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$path" ] && ln -sf "$path" "$MISSING_HQ_BIN/$tool"
done
invoke_direct 'gh pr merge 5 -R acme/widgets' "PATH=$MISSING_HQ_BIN"
if [ "$LAST_RC" = 0 ] && [ -z "$LAST_OUT" ] && has_one_named_diagnostic && [ ! -s "$TMP/calls" ]; then
  ok 'missing hq allows with one named diagnostic without invoking a stub'
else
  bad "missing hq allows with one named diagnostic (rc=$LAST_RC, out=$LAST_OUT, err=$LAST_ERR)"
fi

echo '[6] command text reaches hq unchanged'
exact_command=$'FOO="quoted value" gh pr merge 7 -R acme/widgets --squash &&\nprintf "%s\\n" two-lines\n\n'
invoke_direct "$exact_command" 'HQ_HOLD_TEST_EXIT=0' 'HQ_HOLD_TEST_STDOUT={"ok":true}'
printf '%s\0' lanes hold check --command "$exact_command" --json > "$TMP/expected-argv"
if [ "$LAST_RC" = 0 ] && cmp -s "$TMP/expected-argv" "$TMP/argv"; then
  ok 'quoted, compound, multiline command argument is byte-for-byte unchanged'
else
  bad 'quoted, compound, multiline command argument is byte-for-byte unchanged'
fi

echo '[7] all three hook-gate profiles enable the deny'
for profile in minimal standard strict; do
  rc=0
  clear_stub_receipts
  printf '%s' "$(payload 'gh pr m\"erge\" 5 -R acme/widgets')" \
    | env "PATH=$TEST_PATH" "HQ_HOLD_TEST_CALL_FILE=$TMP/calls" \
        "HQ_HOLD_TEST_ARGV_FILE=$TMP/argv" "HQ_HOLD_TEST_EXIT=3" \
        "HQ_HOLD_TEST_STDOUT=$HOLD_JSON" "HQ_HOOK_PROFILE=$profile" \
        "CLAUDE_PROJECT_DIR=$ROOT" HQ_HOOK_TIMEOUT_SENTRY=0 \
        bash "$GATE" lanes-repo-merge-hold "$HOOK" >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
  if [ "$rc" = 0 ] && jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$TMP/stdout" >/dev/null 2>&1 \
    && [ -s "$TMP/calls" ]; then
    ok "hook-gate profile=$profile dispatches the deny"
  else
    bad "hook-gate profile=$profile dispatches the deny (rc=$rc, out=$(cat "$TMP/stdout"))"
  fi
done

echo '[8] master-hook dispatches the registered Bash guard and Codex preserves its deny'
OTHER_IDS="$(jq -r '.hooks.PreToolUse[].hooks[].id | select(. != "lanes-repo-merge-hold")' "$REGISTRY" 2>/dev/null | sort -u | paste -sd, -)"
for quoted_command in \
  "gh pr m'er'ge 5 -R acme/widgets" \
  'gh pr me\rge 5 -R acme/widgets'; do
  rc=0
  clear_stub_receipts
  printf '%s' "$(payload "$quoted_command")" \
    | env "PATH=$TEST_PATH" "HQ_HOLD_TEST_CALL_FILE=$TMP/calls" \
        "HQ_HOLD_TEST_ARGV_FILE=$TMP/argv" "HQ_HOLD_TEST_EXIT=3" \
        "HQ_HOLD_TEST_STDOUT=$HOLD_JSON" "HQ_ROOT=$ROOT" \
        "CLAUDE_PROJECT_DIR=$ROOT" HQ_HOOK_TIMEOUT_SENTRY=0 \
        HQ_HOOK_PROFILE=minimal "HQ_DISABLED_HOOKS=$OTHER_IDS" \
        bash "$MASTER" PreToolUse >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
  if [ "$rc" = 0 ] && jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$TMP/stdout" >/dev/null 2>&1 \
    && [ -s "$TMP/calls" ]; then
    ok "master-hook raw-JSON prefilter dispatches $quoted_command"
  else
    bad "master-hook raw-JSON prefilter dispatches $quoted_command (rc=$rc, out=$(cat "$TMP/stdout"), err=$(cat "$TMP/stderr"))"
  fi
done

rc=0
clear_stub_receipts
printf '%s' "$(payload 'mkdir -p /tmp/every/rg/e')" \
  | env "PATH=$TEST_PATH" "HQ_HOLD_TEST_CALL_FILE=$TMP/calls" \
      "HQ_HOLD_TEST_ARGV_FILE=$TMP/argv" "HQ_ROOT=$ROOT" \
      "CLAUDE_PROJECT_DIR=$ROOT" HQ_HOOK_TIMEOUT_SENTRY=0 \
      HQ_HOOK_PROFILE=minimal "HQ_DISABLED_HOOKS=$OTHER_IDS" \
      bash "$MASTER" PreToolUse >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
if [ "$rc" = 0 ] && [ ! -s "$TMP/calls" ]; then
  ok 'master-hook raw-JSON prefilter skips ordered letters spread across words'
else
  bad "master-hook raw-JSON prefilter skips ordered letters spread across words (rc=$rc, out=$(cat "$TMP/stdout"), err=$(cat "$TMP/stderr"))"
fi

rc=0
clear_stub_receipts
printf '%s' "$(payload 'gh pr m\"erge\" 5 -R acme/widgets')" \
  | env "PATH=$TEST_PATH" "HQ_HOLD_TEST_CALL_FILE=$TMP/calls" \
      "HQ_HOLD_TEST_ARGV_FILE=$TMP/argv" "HQ_HOLD_TEST_EXIT=3" \
      "HQ_HOLD_TEST_STDOUT=$HOLD_JSON" "HQ_ROOT=$ROOT" \
      "CLAUDE_PROJECT_DIR=$ROOT" HQ_HOOK_TIMEOUT_SENTRY=0 \
      HQ_HOOK_PROFILE=minimal "HQ_DISABLED_HOOKS=$OTHER_IDS" \
      bash "$MASTER" PreToolUse >"$TMP/stdout" 2>"$TMP/stderr" || rc=$?
if [ "$rc" = 0 ] && jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$TMP/stdout" >/dev/null 2>&1 \
  && [ -s "$TMP/calls" ]; then
  ok 'Claude master-hook returns the registered structured deny'
else
  bad "Claude master-hook returns the registered structured deny (rc=$rc, out=$(cat "$TMP/stdout"))"
fi

CODEX_ROOT="$TMP/codex-root"
mkdir -p "$CODEX_ROOT/.codex/hooks" "$CODEX_ROOT/.claude/hooks" "$CODEX_ROOT/core/scripts/lib"
cp "$CODEX_ADAPTER" "$CODEX_ROOT/.codex/hooks/hq-codex-hook-adapter.sh"
cp "$ROOT/.claude/settings.json" "$CODEX_ROOT/.claude/settings.json"
cp "$REGISTRY" "$CODEX_ROOT/.claude/hooks/hook-registry.json"
cp "$GATE" "$CODEX_ROOT/.claude/hooks/hook-gate.sh"
cp "$HOOK" "$CODEX_ROOT/.claude/hooks/lanes-repo-merge-hold.sh"
cp "$ROOT/core/scripts/hook-lib.sh" "$CODEX_ROOT/core/scripts/hook-lib.sh"
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$CODEX_ROOT/core/scripts/lib/hook-adapter-core.sh"
cat > "$CODEX_ROOT/.claude/hooks/master-hook.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
exit 0
SH
chmod +x "$CODEX_ROOT/.codex/hooks/hq-codex-hook-adapter.sh" "$CODEX_ROOT/.claude/hooks/lanes-repo-merge-hold.sh" "$CODEX_ROOT/.claude/hooks/master-hook.sh"
codex_input="$(jq -nc --arg cmd 'gh pr m"erge" 5 -R acme/widgets' --arg root "$CODEX_ROOT" \
  '{session_id:"lanes-hold-check-codex-test",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$root,tool_input:{command:$cmd}}')"
rc=0
clear_stub_receipts
printf '%s' "$codex_input" \
  | env "PATH=$TEST_PATH" "HQ_HOLD_TEST_CALL_FILE=$TMP/calls" \
      "HQ_HOLD_TEST_ARGV_FILE=$TMP/argv" "HQ_HOLD_TEST_EXIT=3" \
      "HQ_HOLD_TEST_STDOUT=$HOLD_JSON" HQ_HOOK_TIMEOUT_SENTRY=0 \
      HQ_HOOK_PROFILE=minimal "HQ_DISABLED_HOOKS=$OTHER_IDS" \
      bash "$CODEX_ROOT/.codex/hooks/hq-codex-hook-adapter.sh" \
      >"$TMP/codex.json" 2>"$TMP/codex.stderr" || rc=$?
if [ "$rc" = 0 ] && jq -e '.hookSpecificOutput.permissionDecision == "deny" and .decision == "block"' "$TMP/codex.json" >/dev/null 2>&1 \
  && [ -s "$TMP/calls" ]; then
  ok 'Codex adapter translates the same registered shim into a block'
else
  bad "Codex adapter translates the same registered shim into a block (rc=$rc, out=$(cat "$TMP/codex.json"), err=$(cat "$TMP/codex.stderr"))"
fi

echo "lanes-hold-check-shim: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
