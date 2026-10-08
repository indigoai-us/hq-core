#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="${HOOK_OVERRIDE:-$ROOT/.claude/hooks/inject-policy-on-trigger.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HQ_ROOT="$TMP/hq"
mkdir -p "$HQ_ROOT/core" "$HQ_ROOT/companies/indigo" "$HQ_ROOT/personal"
ln -s "$ROOT/core/policies" "$HQ_ROOT/core/policies"
ln -s "$ROOT/companies/indigo/policies" "$HQ_ROOT/companies/indigo/policies"
ln -s "$ROOT/personal/policies" "$HQ_ROOT/personal/policies"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
run_prompt() {
  local sid="$1" prompt="$2" monitor_notice="${3:-0}" root="${4:-$HQ_ROOT}" cap="${5:-0}" hard_full="${6:-1}" input
  input="$(jq -cn --arg sid "$sid" --arg prompt "$prompt" --arg cwd "$root" \
    '{hook_event_name:"UserPromptSubmit",session_id:$sid,cwd:$cwd,prompt:$prompt}')"
  printf '%s' "$input" | env HQ_ROOT="$root" CLAUDE_PROJECT_DIR="$root" \
    HQ_POLICY_COMPANY=indigo \
    HQ_HOOK_MONITOR_EXPIRY_NOTIFICATION="$monitor_notice" \
    HQ_SESSION_POLICY_CAP="$cap" \
    HQ_POLICY_HARD_FULL_TEXT="$hard_full" \
    bash "$HOOK" 2>"$TMP/$sid.err"
}

assert_skipped() {
  local label="$1" prompt="$2" sid="$3" monitor_notice="${4:-0}" out ledger
  out="$(run_prompt "$sid" "$prompt" "$monitor_notice")"
  case "$out" in '') ;; *) fail "$label injected output: ${out:0:160}" ;; esac
  ledger="$HQ_ROOT/workspace/orchestrator/policy-trigger-state/$sid.txt"
  if [ -f "$ledger" ] && [ -s "$ledger" ]; then
    fail "$label recorded policy slugs: $(cat "$ledger")"
  fi
}

assert_skipped "task-notification block" \
  '<task-notification><task-id>1</task-id><tool-use-id>toolu_1</tool-use-id><output-file>/tmp/deploy-to-prod-output</output-file><status>completed</status></task-notification>' \
  "task-notification-$$"
assert_skipped "background Bash completion preamble" \
  'The following task has completed:
<task-notification><task-id>2</task-id><tool-use-id>toolu_2</tool-use-id><output-file>/tmp/deploy-to-prod-output</output-file><status>completed</status></task-notification>
Read the output file to retrieve the result: deploy to prod' \
  "background-bash-$$"
assert_skipped "Monitor expiry notice" '[Monitor timed out — re-arm if needed.]' "monitor-expiry-$$" 1
printf 'PASS: task notifications and Monitor expiry notices inject no policies and record no slugs\n'

ordinary="$(run_prompt "ordinary-notification-$$" 'Review task notifications and deploy to prod')"
case "$ordinary" in *'hq-vercel'*) ;; *) fail 'ordinary user prose mentioning task notifications did not inject normally' ;; esac
printf 'PASS: ordinary user prose mentioning task notifications still injects matching policies\n'

fixture="$(run_prompt "hook-settings-$$" 'Review the hook settings')"
if grep -Eiq 'supabase|vercel|linear|macos[- /]overlay|infographic' <<<"$fixture"; then
  fail 'hook-settings fixture included a Supabase, Vercel, Linear, macOS overlay, or infographic policy'
fi
printf 'PASS: hook-settings fixture excludes Supabase, Vercel, Linear, macOS overlay, and infographic policies\n'

path_prompt="$(run_prompt "path-output-$$" 'Please deploy to prod' 0 "$HQ_ROOT" 0 0)"
if ! grep -Fq 'core/policies/hq-vercel.md' <<<"$path_prompt"; then
  fail 'reminder did not print the matched policy file path'
fi
if grep -Fq 'qmd get' <<<"$path_prompt"; then
  fail "reminder still contains qmd advice: $(grep -F 'qmd get' <<<"$path_prompt" | head -1)"
fi
printf 'PASS: reminder prints the policy path and omits qmd get advice\n'
