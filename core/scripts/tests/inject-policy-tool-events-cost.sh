#!/usr/bin/env bash
# Measure median user+system CPU for a Bash PreToolUse + PostToolUse pair.
set -euo pipefail

BASELINE_ROOT=""
CANDIDATE_ROOT=""
REPEATS=50
while [ "$#" -gt 0 ]; do
  case "$1" in
    --baseline-root) BASELINE_ROOT="$2"; shift ;;
    --candidate-root) CANDIDATE_ROOT="$2"; shift ;;
    --repeats) REPEATS="$2"; shift ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
  shift
done
[ -n "$BASELINE_ROOT" ] && [ -n "$CANDIDATE_ROOT" ] || {
  echo 'usage: inject-policy-tool-events-cost.sh --baseline-root PATH --candidate-root PATH [--repeats N]' >&2
  exit 64
}
case "$REPEATS" in ''|*[!0-9]*|0) echo 'repeats must be a positive integer' >&2; exit 64 ;; esac
for root in "$BASELINE_ROOT" "$CANDIDATE_ROOT"; do
  [ -x "$root/.claude/hooks/inject-policy-on-trigger.sh" ] || {
    printf 'injector not found under %s\n' "$root" >&2
    exit 66
  }
done
[ -x /usr/bin/time ] || { echo '/usr/bin/time is required' >&2; exit 69; }
command -v jq >/dev/null 2>&1 || { echo 'jq is required' >&2; exit 69; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hp17-cost.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
RUN="$$-$(date +%s)"

median() {
  LC_ALL=C sort -g "$1" | awk '{v[NR]=$1} END {if (NR % 2) printf "%.6f\n", v[(NR+1)/2]; else printf "%.6f\n", (v[NR/2]+v[NR/2+1])/2}'
}

measure_set() {
  label="$1" root="$2"
  values="$TMP/$label.cpu"
  : > "$values"
  i=1
  while [ "$i" -le "$REPEATS" ]; do
    pair_cpu=0
    for event in PreToolUse PostToolUse; do
      sid="hp17-cost-$RUN-$label-$i-$event"
      payload="$TMP/$label-$i-$event.json"
      timing="$TMP/$label-$i-$event.time"
      jq -cn --arg sid "$sid" --arg event "$event" --arg cwd "$root" \
        '{session_id:$sid,hook_event_name:$event,tool_name:"Bash",cwd:$cwd,tool_input:{command:"ls -la"},tool_response:{stdout:"total 0",stderr:"",exit_code:0}}' > "$payload"
      /usr/bin/time -f '%U %S' -o "$timing" \
        env HQ_ROOT="$root" CLAUDE_PROJECT_DIR="$root" HQ_HARNESS=claude \
        bash "$root/.claude/hooks/inject-policy-on-trigger.sh" < "$payload" >/dev/null
      read -r user_time system_time < "$timing"
      pair_cpu="$(awk -v previous="$pair_cpu" -v u="$user_time" -v s="$system_time" 'BEGIN {printf "%.6f", previous+u+s}')"
    done
    printf '%s\n' "$pair_cpu" >> "$values"
    i=$((i + 1))
  done
  printf '%s median user+sys CPU seconds per event pair (%s pairs): %s\n' \
    "$label" "$REPEATS" "$(median "$values")"
}

echo "host: $(uname -s) $(uname -m), bash ${BASH_VERSION}"
echo "load at start: $(uptime | sed 's/^.*load average: //')"
measure_set baseline "$BASELINE_ROOT"
measure_set candidate "$CANDIDATE_ROOT"
echo "load at end: $(uptime | sed 's/^.*load average: //')"
