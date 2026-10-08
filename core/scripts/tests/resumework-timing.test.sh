#!/usr/bin/env bash
# Measure the /resumework Bash command set with and without the master hook.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# Keep standalone timing at 20 samples; the benchmark opts into 5 for hosted runner limits.
RUNS="${RESUMEWORK_TIMING_RUNS:-20}"
MIN_RUNS="${RESUMEWORK_TIMING_MIN_RUNS:-20}"
SESSION_ID="${RESUMEWORK_TIMING_SESSION_ID:-bench-resumework-$(date +%s)-$$}"
# Each operational Bash code block is a separate Bash tool call and therefore
# starts another master-hook process. Four includes the confirmed re-resume path.
HOOK_CALL_LIMIT=4
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

check_hook_call_count() {
  python3 - "$ROOT/.claude/skills/resumework/SKILL.md" "$HOOK_CALL_LIMIT" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
limit = int(sys.argv[2])
text = path.read_text(encoding="utf-8")
try:
    process = text.split("## Process", 1)[1].split("\n## Rules", 1)[0]
except IndexError:
    raise SystemExit("resumework hook count: Process section not found")
calls = re.findall(
    r"(?m)^[ ]{0,3}```bash[ \t]*\r?\n.*?^[ ]{0,3}```[ \t]*$",
    process,
    re.DOTALL,
)
count = len(calls)
if count == 0 or count > limit:
    raise SystemExit(
        f"resumework hook count: Process has {count} Bash tool-call blocks; limit is {limit}"
    )
required = (
    "handoff-sync-prefetch.sh",
    "find workspace/threads",
    "resume-thread-lock.sh inspect",
    "resume-thread-lock.sh acquire",
    "handoff-open-steps.sh list --limit 10",
    "git -C /absolute/path/to/repo status --short",
    "hq-session.sh set mode \"Resume\"",
)
missing = [token for token in required if token not in process]
if missing:
    raise SystemExit(
        "resumework hook count: required operations missing from Process: "
        + ", ".join(missing)
    )
print(f"PASS: resumework Bash tool-call blocks={count} limit={limit}")
PY
}

check_hook_call_count
if [[ "${1:-}" == "--check-hook-count" ]]; then
  exit 0
fi

now_ms() {
  perl -MTime::HiRes=time -e 'printf("%d\n", time()*1000)'
}

THREAD_FIND_COMMAND="$(python3 - "$ROOT/.claude/skills/resumework/SKILL.md" <<'PYBLOCK'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
process = text.split("## Process", 1)[1].split("\n## Rules", 1)[0]
blocks = [block for _, block in re.findall(r"(?m)^([ \t]*)```bash[ \t]*\n(.*?)^\1```[ \t]*$", process, re.DOTALL)]
block = next((block for block in blocks if 'arg="$ARGUMENTS"' in block), None)
if block is None:
    raise SystemExit("resumework timing: thread-resolution Bash block not found")
print(block.replace("$ARGUMENTS", "\"$RESUMEWORK_THREAD_ID\""), end="")
PYBLOCK
)"
LOCK_COMMAND="$(python3 - "$ROOT/.claude/skills/resumework/SKILL.md" <<'PYBLOCK'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
process = text.split("## Process", 1)[1].split("\n## Rules", 1)[0]
blocks = [block for _, block in re.findall(r"(?m)^([ \t]*)```bash[ \t]*\n(.*?)^\1```[ \t]*$", process, re.DOTALL)]
block = next((block for block in blocks if 'thread_file="<resolved-thread-file>"' in block), None)
if block is None:
    raise SystemExit("resumework timing: lock Bash block not found")
block = block.replace('thread_file="<resolved-thread-file>"', 'thread_file="$ROOT/workspace/threads/$RESUMEWORK_THREAD_ID.json"')
print(block, end="")
PYBLOCK
)"
METADATA_COMMAND="$(python3 - "$ROOT/.claude/skills/resumework/SKILL.md" <<'PYBLOCK'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
process = text.split("## Process", 1)[1].split("\n## Rules", 1)[0]
blocks = [block for _, block in re.findall(r"(?m)^([ \t]*)```bash[ \t]*\n(.*?)^\1```[ \t]*$", process, re.DOTALL)]
block = next((block for block in blocks if "git -C /absolute/path/to/repo branch --show-current" in block), None)
if block is None:
    raise SystemExit("resumework timing: metadata Bash block not found")
block = block.replace("/absolute/path/to/repo", "$ROOT").replace('"{co}"', '"indigo"')
print(block, end="")
PYBLOCK
)"

percentile() {
  local p="$1"
  sort -n | awk -v p="$p" '{ a[NR]=$1 } END { if (!NR) { print 0; exit } i=int((NR*p+99)/100); if (i<1) i=1; print a[i] }'
}

median() {
  sort -n | awk '{ a[NR]=$1 } END { if (!NR) { print 0; exit } if (NR%2) print a[(NR+1)/2]; else print int((a[NR/2]+a[NR/2+1])/2) }'
}

commands=("$THREAD_FIND_COMMAND" "$LOCK_COMMAND" "$METADATA_COMMAND")
labels=("thread-resolution-prefetch" "lock-inspect-acquire-open-steps" "git-session-metadata")

command -v jq >/dev/null 2>&1 || { echo "resumework timing: jq is required" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "resumework timing: perl is required" >&2; exit 2; }
[[ "$RUNS" =~ ^[0-9]+$ && "$MIN_RUNS" =~ ^[0-9]+$ ]] && (( MIN_RUNS >= 5 && RUNS >= MIN_RUNS )) || { echo "resumework timing: RUNS must be at least MIN_RUNS (minimum allowed is 5)" >&2; exit 2; }

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
    if (( step < 2 )); then
      printf '%s\n' '{}' > "$ROOT/workspace/threads/${RESUMEWORK_THREAD_ID}.json"
    fi
    command="${commands[$step]}"
    payload="$(jq -nc --arg s "$SESSION_ID" --arg c "$command" --arg cwd "$HQ_ROOT" '{session_id:$s,hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$cwd,tool_input:{command:$c,description:"resumework timing"}}')"
    t0="$(now_ms)"
    if ! printf '%s' "$payload" | bash "$ROOT/.claude/hooks/master-hook.sh" PreToolUse >"$HOOK_OUTPUT" 2>&1; then
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
    if (( step < 2 )); then python3 - "$ROOT/workspace/threads/${RESUMEWORK_THREAD_ID}.json" <<'PYBLOCK'
import pathlib
import sys
pathlib.Path(sys.argv[1]).unlink(missing_ok=True)
PYBLOCK
    fi
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
