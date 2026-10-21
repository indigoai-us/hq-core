#!/usr/bin/env bash
# Regression: the registry prefilter must see `git` at the start of a line.
#
# The prefilter text was built from `.tool_input | tojson`, where a newline is
# the two characters `\n`. The git guards' boundary regex
# `(^|[^A-Za-z0-9_-])(git|gh)` then saw `ngit`, so `true` + newline +
# `git -C "<HQ>" push origin main` skipped block-hq-root-git-mutation and
# block-company-repo-creation in master-hook and in the shared adapter core.
set -euo pipefail
TEST_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(git -C "$TEST_DIR/../../.." rev-parse --show-toplevel)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIXTURE="$TMP/hq"

mkdir -p "$FIXTURE/.claude/hooks" "$FIXTURE/core/scripts/lib" \
  "$FIXTURE/companies/example-co" "$FIXTURE/workspace/sessions"
cp "$ROOT/.claude/hooks/master-hook.sh" "$FIXTURE/.claude/hooks/"
cp "$ROOT/.claude/hooks/hook-gate.sh" "$FIXTURE/.claude/hooks/"
cp "$ROOT/.claude/hooks/hook-timeout-probe.sh" "$FIXTURE/.claude/hooks/"
cp "$ROOT/.claude/hooks/block-company-repo-creation.sh" "$FIXTURE/.claude/hooks/"
cp "$ROOT/.claude/hooks/block-hq-root-git-mutation.sh" "$FIXTURE/.claude/hooks/"
cp "$ROOT/.claude/hooks/block-hq-root-git-mutation-flag.cjs" "$FIXTURE/.claude/hooks/"
cp "$ROOT/core/scripts/hook-lib.sh" "$FIXTURE/core/scripts/"
cp "$ROOT/core/scripts/resolve-hq-root.sh" "$FIXTURE/core/scripts/"
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$FIXTURE/core/scripts/lib/"
jq '(.hooks.PreToolUse) |= map(.hooks |= map(select(.id == "block-company-repo-creation" or .id == "block-hq-root-git-mutation")) | select(.hooks | length > 0))' \
  "$ROOT/.claude/hooks/hook-registry.json" > "$FIXTURE/.claude/hooks/hook-registry.json"
git -C "$FIXTURE" init -q

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1" >&2; }

COMPANY_COMPONENT=com
COMPANY_COMPONENT+=panies
NL=$'\n'
TAB=$'\t'
ROOT_PUSH="true${NL}git -C \"$FIXTURE\" push origin main"
TAB_ROOT_PUSH="true${NL}${TAB}git -C \"$FIXTURE\" commit -m x"
CRLF_ROOT_PUSH="true"$'\r\n'"git -C \"$FIXTURE\" push origin main"
COMPANY_INIT="true${NL}git init \"$FIXTURE/$COMPANY_COMPONENT/example-co/repo\""
READONLY="true${NL}git -C /tmp/repo status"

payload_for() {
  jq -cn --arg cwd "$FIXTURE" --arg command "$1" \
    '{session_id:"prefilter-line-start",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$cwd,tool_input:{command:$command}}'
}

# A NUL in another tool_input string must not reach master-hook's framed
# metadata record: read -N drops raw NUL bytes, and an earlier NUL framing
# would end the record early and make the rest of the decoded text the
# command the guards check.
nul_payload_for() {
  jq -cn --arg cwd "$FIXTURE" --arg command "$1" \
    '{session_id:"prefilter-line-start",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$cwd,tool_input:{command:$command,description:("x" + ([0] | implode) + "true")}}'
}

# master-hook: full dispatch through the registry prefilter.
run_master() {
  local label="$1" command_text="$2" rc=0 payload
  if [[ "${3:-}" == nul ]]; then
    payload="$(nul_payload_for "$command_text")"
  else
    payload="$(payload_for "$command_text")"
  fi
  printf '%s' "$payload" | (
    cd "$FIXTURE"
    env -u HQ_HOOK_EVENT -u HQ_HOOK_TOOL_NAME -u HQ_HOOK_COMMAND \
      -u HQ_HOOK_CWD -u HQ_HOOK_SESSION_ID -u HQ_HOOK_AGENT_ID \
      CLAUDE_PROJECT_DIR="$FIXTURE" HQ_HOOK_DEDUPE=0 HQ_HOOK_TIMEOUT_SENTRY=0 \
      HQ_HOOK_TRACE=1 \
      bash "$FIXTURE/.claude/hooks/master-hook.sh" PreToolUse \
      > "$TMP/$label.out" 2> "$TMP/$label.err"
  ) || rc=$?
  printf '%s\n' "$rc" > "$TMP/$label.rc"
}
expect_master_deny() {
  local label="$1" command_text="$2" marker="$3" rc
  run_master "$label" "$command_text" "${4:-}"
  rc="$(<"$TMP/$label.rc")"
  if [[ "$rc" == 2 ]] && grep -Fq "$marker" "$TMP/$label.err" \
    && ! grep -Eq 'skip (block-hq-root-git-mutation|block-company-repo-creation) \(prefilter\)' "$TMP/$label.err"; then
    pass "master-hook $label denied"
  else
    fail "master-hook $label expected exit 2 and '$marker'; got exit $rc, stderr=$(<"$TMP/$label.err")"
  fi
}
expect_master_deny line-start-root-push "$ROOT_PUSH" "BLOCKED: Anchor"
expect_master_deny tab-line-start-root-commit "$TAB_ROOT_PUSH" "BLOCKED: Anchor"
expect_master_deny crlf-line-start-root-push "$CRLF_ROOT_PUSH" "BLOCKED: Anchor"
expect_master_deny line-start-company-init "$COMPANY_INIT" \
  "Git repositories cannot be created or populated under companies/"
expect_master_deny nul-in-description-root-push "git -C \"$FIXTURE\" push origin main" \
  "BLOCKED: Anchor" nul

run_master line-start-readonly "$READONLY"
if [[ "$(<"$TMP/line-start-readonly.rc")" == 0 ]]; then
  pass "master-hook line-start-readonly allowed"
else
  fail "master-hook line-start-readonly expected allow; stderr=$(<"$TMP/line-start-readonly.err")"
fi

# Adapter core: the shared prefilter text must match both guards' regexes.
# shellcheck source=/dev/null
. "$FIXTURE/core/scripts/lib/hook-adapter-core.sh"
expect_adapter_match() {
  local label="$1" command_text="$2" fields hook_id re
  fields="$(hqad_prefilter_payload_fields PreToolUse "$(payload_for "$command_text")")"
  eval "set -- $fields"
  for hook_id in block-hq-root-git-mutation block-company-repo-creation; do
    re="$(jq -r --arg id "$hook_id" '.hooks.PreToolUse[].hooks[] | select(.id == $id) | .prefilter.re' \
      "$FIXTURE/.claude/hooks/hook-registry.json")"
    if [[ -n "$re" ]] && [[ "$3" =~ $re ]]; then
      pass "adapter $label matches $hook_id prefilter"
    else
      fail "adapter $label: $hook_id prefilter did not match text: $3"
    fi
  done
}
expect_adapter_match line-start-root-push "$ROOT_PUSH"
expect_adapter_match tab-line-start-root-commit "$TAB_ROOT_PUSH"
expect_adapter_match line-start-company-init "$COMPANY_INIT"

fields="$(hqad_prefilter_payload_fields PreToolUse "$(nul_payload_for "$ROOT_PUSH")")"
eval "set -- $fields"
if [[ "$#" -eq 3 && "$3" == *"push origin main x true"* ]]; then
  pass "adapter NUL in description keeps three fields and the full text"
else
  fail "adapter NUL in description: got $# fields, text: ${3:-}"
fi

# Latency: the prefilter flattens newlines in the decoded command. A gsub
# there grows with the square of the line count (10,000 lines took 15 s in
# master-hook), and a hook that passes its timeout does not block, so every
# guard would be skipped. Both builders must stay linear.
#
# long_payload <file> <JSON-escaped command>: a 10,000-line command is too
# long for a jq --arg on Windows (the command line limit is 32 KB), and
# native jq.exe may drop CR when it reads text from stdin. So jq writes the
# payload around a marker and the shell splices in the escaped command.
long_payload() {
  local tpl
  tpl="$(payload_for '@@CMD@@')"
  printf '%s%s%s\n' "${tpl%%@@CMD@@*}" "$2" "${tpl#*@@CMD@@}" > "$1"
}
LONG_PAYLOAD="$TMP/long-payload.json"
SHORT_PAYLOAD="$TMP/short-payload.json"
printf -v LONG_JSON_CMD 'echo %d\\n' {1..10000}
long_payload "$LONG_PAYLOAD" "$LONG_JSON_CMD"
payload_for "echo 1" > "$SHORT_PAYLOAD"
elapsed() {
  local TIMEFORMAT=%R
  { time "$@" > /dev/null 2>&1 || true; } 2>&1
}
time_adapter() {
  hqad_prefilter_payload_fields PreToolUse "$(<"$1")" > /dev/null
}
time_master() {
  (
    cd "$FIXTURE"
    env -u HQ_HOOK_EVENT -u HQ_HOOK_TOOL_NAME -u HQ_HOOK_COMMAND \
      -u HQ_HOOK_CWD -u HQ_HOOK_SESSION_ID -u HQ_HOOK_AGENT_ID \
      CLAUDE_PROJECT_DIR="$FIXTURE" HQ_HOOK_DEDUPE=0 HQ_HOOK_TIMEOUT_SENTRY=0 \
      "${MASTER_BASH:-bash}" "$FIXTURE/.claude/hooks/master-hook.sh" PreToolUse < "$1"
  )
}
under() { awk -v t="$1" -v max="$2" 'BEGIN { exit !(t + 0 < max + 0) }'; }
# fastest <command...>: the lowest of three timings. A busy machine can stall
# any single run. A quadratic step is slow on every run, so it still fails.
fastest() {
  local best="" t i
  for i in 1 2 3; do
    t="$(elapsed "$@")"
    if [[ -z "$best" ]] || under "$t" "$best"; then
      best="$t"
    fi
  done
  printf '%s\n' "$best"
}

adapter_secs="$(elapsed time_adapter "$LONG_PAYLOAD")"
if under "$adapter_secs" 1; then
  pass "adapter prefilter text for a 10,000-line command in ${adapter_secs}s (< 1s)"
else
  fail "adapter prefilter text for a 10,000-line command took ${adapter_secs}s (limit 1s)"
fi

# master-hook: compare with a one-line command so process start-up cost on
# slow runners does not count against the limit.
short_secs="$(fastest time_master "$SHORT_PAYLOAD")"
long_secs="$(fastest time_master "$LONG_PAYLOAD")"
extra_secs="$(awk -v l="$long_secs" -v s="$short_secs" 'BEGIN { printf "%.3f", l - s }')"
if under "$extra_secs" 1; then
  pass "master-hook 10,000-line command adds ${extra_secs}s over one line (${long_secs}s vs ${short_secs}s, < 1s)"
else
  fail "master-hook 10,000-line command adds ${extra_secs}s over one line (${long_secs}s vs ${short_secs}s, limit 1s)"
fi

# The same command with CRLF line ends. master-hook turns each CRLF back into
# LF after `jq -j` (native Windows jq.exe writes LF as CRLF), and that collapse
# must stay linear too: ${//} took over a minute for 5,000 pairs on bash 3.2.
# Bash 4+ and bash 3.2 take different branches, so run under each bash this
# machine has.
CRLF_PAYLOAD="$TMP/crlf-payload.json"
printf -v CRLF_JSON_CMD 'echo %d\\r\\n' {1..10000}
long_payload "$CRLF_PAYLOAD" "$CRLF_JSON_CMD"
if [[ "$(<"$CRLF_PAYLOAD")" == *'echo 9999\r\necho 10000\r\n'* ]]; then
  pass "CRLF latency payload keeps its CRLF line ends"
else
  fail "CRLF latency payload lost its CRLF line ends"
fi
MASTER_BASHES=(bash)
if [[ -x /bin/bash && "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" != "$(bash -c 'echo "${BASH_VERSINFO[0]}"')" ]]; then
  MASTER_BASHES+=(/bin/bash)
fi
for MASTER_BASH in "${MASTER_BASHES[@]}"; do
  base_secs="$(fastest time_master "$SHORT_PAYLOAD")"
  crlf_secs="$(fastest time_master "$CRLF_PAYLOAD")"
  extra_secs="$(awk -v l="$crlf_secs" -v s="$base_secs" 'BEGIN { printf "%.3f", l - s }')"
  if under "$extra_secs" 1; then
    pass "master-hook on $MASTER_BASH: 10,000-line CRLF command adds ${extra_secs}s over one line (${crlf_secs}s vs ${base_secs}s, < 1s)"
  else
    fail "master-hook on $MASTER_BASH: 10,000-line CRLF command adds ${extra_secs}s over one line (${crlf_secs}s vs ${base_secs}s, limit 1s)"
  fi
done
unset MASTER_BASH

printf 'prefilter-line-start-git: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
