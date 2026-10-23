#!/usr/bin/env bash
# hq-core: public
# master-hook-pretooluse-latency-budget.test.sh — wall-clock budget for a
# typical PreToolUse through the full master-hook fan-out (feedback
# 4db60cce: 10-13 s hook events near the 30 s deadline).
#
# Copies this checkout's .claude/ and core/ into a temp HQ root, then fires a
# Read and a non-outbound Bash PreToolUse through master-hook.sh. One warm-up
# run per payload is discarded; the median of the next HQ_HOOK_BUDGET_RUNS
# (default 5) must stay at or under HQ_HOOK_PRETOOL_BUDGET_MS (default 2000).
# Both knobs exist for slow machines; do not raise the default to make a
# regression pass. Per the local-CI policy this is a local benchmark; it is
# not wired into pull-request CI.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
BUDGET_MS="${HQ_HOOK_PRETOOL_BUDGET_MS:-2000}"
RUNS="${HQ_HOOK_BUDGET_RUNS:-5}"
case "$BUDGET_MS" in ''|*[!0-9]*) echo "FAIL: HQ_HOOK_PRETOOL_BUDGET_MS must be an integer" >&2; exit 1 ;; esac
case "$RUNS" in ''|*[!0-9]*|0) echo "FAIL: HQ_HOOK_BUDGET_RUNS must be a positive integer" >&2; exit 1 ;; esac
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable" >&2; exit 0; }
command -v rsync >/dev/null 2>&1 || { echo "SKIP: rsync unavailable" >&2; exit 0; }
TEST_BASH="${HQ_TEST_BASH:-$(command -v bash)}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mh-latency-budget.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
FIX="$TMP/hq"
mkdir -p "$FIX/companies" "$FIX/workspace" "$FIX/repos/private/demo" "$TMP/home"
rsync -a --exclude node_modules "$ROOT/.claude" "$ROOT/core" "$FIX/"
printf 'companies: {}\n' > "$FIX/companies/manifest.yaml"
(cd "$FIX/repos/private/demo" && git init -q 2>/dev/null) || true
: > "$TMP/transcript.jsonl"

now_ms() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    local t="${EPOCHREALTIME/[.,]/}"
    printf '%s' "$((10#$t / 1000))"
  else
    perl -MTime::HiRes=time -e 'printf "%d", time * 1000'
  fi
}

fire() { # <payload> -> elapsed ms on stdout
  local start end
  start="$(now_ms)"
  printf '%s' "$1" | env -i HOME="$TMP/home" PATH="$PATH" TMPDIR="$TMP" BASH_ENV=/dev/null \
    CLAUDE_PROJECT_DIR="$FIX" HQ_ROOT="$FIX" \
    "$TEST_BASH" "$FIX/.claude/hooks/master-hook.sh" PreToolUse >/dev/null 2>&1
  end="$(now_ms)"
  printf '%s\n' "$((end - start))"
}

payload() { # <tool> <tool_input-json> <n>
  jq -nc --arg cwd "$FIX" --arg t "$TMP/transcript.jsonl" --arg tool "$1" --argjson input "$2" --arg id "toolu_budget_$3" \
    '{session_id:"latency-budget",transcript_path:$t,cwd:$cwd,hook_event_name:"PreToolUse",tool_use_id:$id,tool_name:$tool,tool_input:$input}'
}

failures=0
check() { # <label> <tool> <tool_input-json>
  local label="$1" i samples=() median
  fire "$(payload "$2" "$3" warm-$label)" >/dev/null
  for i in $(seq 1 "$RUNS"); do
    samples+=("$(fire "$(payload "$2" "$3" "$label-$i")")")
  done
  median="$(printf '%s\n' "${samples[@]}" | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}')"
  if [ "$median" -le "$BUDGET_MS" ]; then
    printf 'ok   %s PreToolUse median %sms (budget %sms; runs: %s)\n' "$label" "$median" "$BUDGET_MS" "${samples[*]}"
  else
    printf 'FAIL %s PreToolUse median %sms over budget %sms (runs: %s)\n' "$label" "$median" "$BUDGET_MS" "${samples[*]}"
    failures=$((failures + 1))
  fi
}

check Read Read "$(jq -nc --arg p "$FIX/core/core.yaml" '{file_path:$p}')"
check Bash Bash '{"command":"git -C repos/private/demo status --short","description":"status"}'

[ "$failures" -eq 0 ]
