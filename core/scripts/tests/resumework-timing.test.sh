#!/usr/bin/env bash
# Measure the /resumework Bash command set with and without the master hook.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RUNS="${RESUMEWORK_TIMING_RUNS:-20}"
SESSION_ID="bench-resumework-$(date +%s)-$$"
HQ_ROOT="${HQ_ROOT:-$ROOT}"
RESUMEWORK_PREFETCH_LOG="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/handoff-sync-prefetch-${SESSION_ID}.log"
CURRENT_POINTER="$HQ_ROOT/workspace/sessions/.current"
CURRENT_BACKUP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/resumework-current-${SESSION_ID}"
CURRENT_WAS_PRESENT=0
REPORT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/resumework-timing-${SESSION_ID}.tsv"
HOOK_SAMPLES="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/resumework-hook-${SESSION_ID}.txt"
COMMAND_SAMPLES="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/resumework-command-${SESSION_ID}.txt"
HOOK_OUTPUT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/resumework-hook-output-${SESSION_ID}.txt"
HOOK_FAILURE_OUTPUT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/resumework-hook-failure-${SESSION_ID}.txt"

now_ms() {
  perl -MTime::HiRes=time -e 'printf("%d\n", time()*1000)'
}

THREAD_FIND_COMMAND="$(python3 - "$ROOT/.claude/skills/resumework/SKILL.md" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
blocks = [block for _, block in re.findall(r"(?m)^([ \t]*)```bash[ \t]*\n(.*?)^\1```[ \t]*$", text, re.DOTALL)]
step_one = next((block for block in blocks if 'arg="$ARGUMENTS"' in block), None)
if step_one is None:
    raise SystemExit("resumework timing: Step 1 Bash block not found in skill")
print(step_one.replace("$ARGUMENTS", "T-20261007-091000-resumework-timing"), end="")
PY
)"

percentile() {
  local p="$1"
  sort -n | awk -v p="$p" '{ a[NR]=$1 } END { if (!NR) { print 0; exit } i=int((NR*p+99)/100); if (i<1) i=1; print a[i] }'
}

median() {
  sort -n | awk '{ a[NR]=$1 } END { if (!NR) { print 0; exit } if (NR%2) print a[(NR+1)/2]; else print int((a[NR/2]+a[NR/2+1])/2) }'
}

commands=(
  'bash core/scripts/handoff-sync-prefetch.sh --log "$RESUMEWORK_PREFETCH_LOG"'
  "$THREAD_FIND_COMMAND"
  'bash core/scripts/hq-session.sh current >/dev/null && bash core/scripts/resume-thread-lock.sh inspect "$RESUMEWORK_THREAD_ID" >/dev/null'
  'bash core/scripts/resume-thread-lock.sh acquire "$RESUMEWORK_THREAD_ID" --session-id "$RESUMEWORK_SESSION_ID" >/dev/null'
  'git -C "$RESUMEWORK_ROOT" status --short && git -C "$RESUMEWORK_ROOT" log --oneline -3'
  'bash core/scripts/hq-session.sh set company_slug indigo && bash core/scripts/hq-session.sh set mode Resume'
)
labels=("handoff-sync-prefetch" "thread-find-ls" "session-current-lock-inspect" "lock-acquire" "git-status-log" "hq-session-set")

command -v jq >/dev/null 2>&1 || { echo "resumework timing: jq is required" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "resumework timing: perl is required" >&2; exit 2; }
[[ "$RUNS" =~ ^[0-9]+$ ]] && (( RUNS >= 20 )) || { echo "resumework timing: RUNS must be at least 20" >&2; exit 2; }

mkdir -p "$ROOT/workspace/threads" "$ROOT/workspace/threads/resume-locks" "$ROOT/workspace/sessions"
mkdir -p "$(dirname "$CURRENT_POINTER")"
if [[ -f "$CURRENT_POINTER" ]]; then
  cp "$CURRENT_POINTER" "$CURRENT_BACKUP"
  CURRENT_WAS_PRESENT=1
fi
restore_current_pointer() {
  if (( CURRENT_WAS_PRESENT )); then
    cp "$CURRENT_BACKUP" "$CURRENT_POINTER"
  else
    rm -f "$CURRENT_POINTER"
  fi
  rm -f "$CURRENT_BACKUP"
}
trap restore_current_pointer EXIT
export CLAUDE_PROJECT_DIR="$HQ_ROOT" HQ_ROOT RESUMEWORK_ROOT="$ROOT" RESUMEWORK_SESSION_ID="$SESSION_ID" RESUMEWORK_PREFETCH_LOG CLAUDE_CODE_SESSION_ID="$SESSION_ID"
bash "$ROOT/core/scripts/hq-session.sh" set company_slug indigo >/dev/null
bash "$ROOT/core/scripts/hq-session.sh" set mode Resume >/dev/null

: > "$REPORT"
: > "$HOOK_SAMPLES"
: > "$COMMAND_SAMPLES"
cycle_hooks=()
hook_failures=0
step_hook_failures=()
for ((run=1; run<=RUNS; run++)); do cycle_hooks[$run]=0; done
for step in "${!commands[@]}"; do
  hook_times=()
  command_times=()
  step_hook_failures[$step]=0
  for ((run=1; run<=RUNS; run++)); do
    export RESUMEWORK_THREAD_ID="T-${SESSION_ID}-step${step}-run${run}"
    command="${commands[$step]}"
    payload="$(jq -nc --arg s "$SESSION_ID" --arg c "$command" --arg cwd "$HQ_ROOT" '{session_id:$s,hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$cwd,tool_input:{command:$c,description:"resumework timing"}}')"
    t0="$(now_ms)"
    if printf '%s' "$payload" | bash "$ROOT/.claude/hooks/master-hook.sh" PreToolUse >"$HOOK_OUTPUT" 2>&1; then
      hook_rc=0
    else
      hook_rc=$?
      hook_failures=$((hook_failures + 1))
      step_hook_failures[$step]=$((step_hook_failures[$step] + 1))
      if [[ ! -e "$HOOK_FAILURE_OUTPUT" ]]; then cp "$HOOK_OUTPUT" "$HOOK_FAILURE_OUTPUT"; fi
    fi
    t1="$(now_ms)"
    hook_ms=$((t1-t0))
    cycle_hooks[$run]=$((cycle_hooks[$run] + hook_ms))
    t0="$(now_ms)"
    (cd "$ROOT" && bash -c "$command") >/dev/null 2>&1
    t1="$(now_ms)"
    command_ms=$((t1-t0))
    hook_times+=("$hook_ms")
    command_times+=("$command_ms")
    printf '%s\n' "$hook_ms" >> "$HOOK_SAMPLES"
    printf '%s\n' "$command_ms" >> "$COMMAND_SAMPLES"
    rm -rf "$ROOT/workspace/threads/resume-locks/${RESUMEWORK_THREAD_ID}.lock"
  done
  hook_p50="$(printf '%s\n' "${hook_times[@]}" | median)"
  hook_p95="$(printf '%s\n' "${hook_times[@]}" | percentile 95)"
  command_p50="$(printf '%s\n' "${command_times[@]}" | median)"
  command_p95="$(printf '%s\n' "${command_times[@]}" | percentile 95)"
  printf '%s\t%s\t%s\t%s\t%s\n' "${labels[$step]}" "$hook_p50" "$hook_p95" "$command_p50" "$command_p95" >> "$REPORT"
  printf 'completed timing step: %s (%s samples)\n' "${labels[$step]}" "$RUNS"
done

platform="$(uname -s 2>/dev/null || echo unknown)"
case "$platform" in MINGW*|MSYS*|CYGWIN*) platform=windows-gitbash ;; Linux) platform=linux ;; esac
printf 'resumework timing platform=%s runs=%s session=%s\n' "$platform" "$RUNS" "$SESSION_ID"
printf '%-32s %12s %12s %16s %16s\n' step hook_p50_ms hook_p95_ms command_p50_ms command_p95_ms
while IFS=$'\t' read -r label hook_p50 hook_p95 command_p50 command_p95; do
  printf '%-32s %12s %12s %16s %16s\n' "$label" "$hook_p50" "$hook_p95" "$command_p50" "$command_p95"
done < "$REPORT"
hook_cycle_p50="$(printf '%s\n' "${cycle_hooks[@]}" | median)"
hook_cycle_p95="$(printf '%s\n' "${cycle_hooks[@]}" | percentile 95)"
printf 'hook_chain_cycle_p50_ms=%s\n' "$hook_cycle_p50"
printf 'hook_chain_cycle_p95_ms=%s\n' "$hook_cycle_p95"
printf 'master_hook_nonzero_count=%s\n' "$hook_failures"
for step in "${!labels[@]}"; do
  printf 'master_hook_nonzero_%s=%s\n' "${labels[$step]}" "${step_hook_failures[$step]}"
done
if [[ -e "$HOOK_FAILURE_OUTPUT" ]]; then
  printf '%s\n' 'first_master_hook_failure_output:'
  cat "$HOOK_FAILURE_OUTPUT"
fi
thread_file_count="$(find "$ROOT/workspace/threads" -type f 2>/dev/null | wc -l | tr -d '[:space:]')"
largest_command_step="$(awk -F '\t' 'BEGIN{max=-1} {if ($5>max) {max=$5; label=$1}} END{printf "%s:%d", label, max}' "$REPORT")"
printf 'workspace_thread_files=%s\n' "$thread_file_count"
printf 'largest_command_p95_ms=%s\n' "$largest_command_step"
if [[ "$platform" == windows-gitbash && -n "${RESUMEWORK_HOOK_BUDGET_MS:-}" ]] && (( hook_cycle_p95 > RESUMEWORK_HOOK_BUDGET_MS )); then
  echo "resumework timing budget exceeded: p95=${hook_cycle_p95}ms budget=${RESUMEWORK_HOOK_BUDGET_MS}ms" >&2
  exit 1
fi
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  { echo "### /resumework timing ($platform, $RUNS runs)"; echo; echo '| Step | Hook p50 ms | Hook p95 ms | Command p50 ms | Command p95 ms |'; echo '|---|---:|---:|---:|---:|'; while IFS=$'\t' read -r label hook_p50 hook_p95 command_p50 command_p95; do printf '| %s | %s | %s | %s | %s |\n' "$label" "$hook_p50" "$hook_p95" "$command_p50" "$command_p95"; done < "$REPORT"; echo; echo "Hook-chain cycle p50: ${hook_cycle_p50} ms"; echo "Hook-chain cycle p95: ${hook_cycle_p95} ms"; echo "Master-hook non-zero exits: ${hook_failures}"; echo "Workspace thread files: ${thread_file_count}"; echo "Largest command p95: ${largest_command_step}"; } >> "$GITHUB_STEP_SUMMARY"
fi
(( hook_failures == 0 )) || { echo "master-hook returned non-zero in $hook_failures samples" >&2; exit 1; }
