#!/usr/bin/env bash
# bench-hooks.sh — measure the wall-clock cost of HQ's Claude Code hook layer
# for one synthetic tool call, exactly as the harness would dispatch it.
#
# Replays a synthetic event through every hook registered in
# .claude/settings.json (and settings.local.json unless --no-local) whose
# event and matcher apply, timing each registration and the total.
#
# Runs on macOS, Linux, and Windows Git Bash. Needs bash, jq, perl.
# Each registration is run under the same timeout the harness would apply
# (the "timeout" field in settings, default 30 s), so a hung hook shows up as
# its timeout value rather than stalling the benchmark.
#
# Usage:
#   bash core/scripts/bench-hooks.sh                     # PreToolUse+PostToolUse, tool=Bash, 3 runs
#   bash core/scripts/bench-hooks.sh --tool Write --runs 5
#   bash core/scripts/bench-hooks.sh --events PreToolUse --no-local --json out.json
#   bash core/scripts/bench-hooks.sh --events UserPromptSubmit
#
# Output: a table (registration, median ms, min ms, max ms) per event, then a
# summary line with the total median ms per simulated tool call. With --json
# the same data is written as JSON for before/after comparisons.
#
# The synthetic session id is prefixed "bench-" so hook ledgers written under
# workspace/ can be identified and cleaned; they do not touch real sessions.

set -u

ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
TOOL="Bash"
EVENTS="PreToolUse,PostToolUse"
RUNS=3
USE_LOCAL=1
JSON_OUT=""
QUIET=0
CMD_TEXT='echo bench'

while [ $# -gt 0 ]; do
  case "$1" in
    --tool) TOOL="$2"; shift 2 ;;
    --event|--events) EVENTS="$2"; shift 2 ;;
    --runs) RUNS="$2"; shift 2 ;;
    --no-local) USE_LOCAL=0; shift ;;
    --json) JSON_OUT="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    --command) CMD_TEXT="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

for dep in jq perl; do
  command -v "$dep" >/dev/null 2>&1 || { echo "bench-hooks: missing dependency: $dep" >&2; exit 2; }
done

now_ms() { perl -MTime::HiRes=time -e 'printf("%d\n", time()*1000)'; }

platform="$(uname -s 2>/dev/null || echo unknown)"
case "$platform" in
  MINGW*|MSYS*|CYGWIN*) platform_label="windows-gitbash" ;;
  Darwin) platform_label="macos" ;;
  Linux) platform_label="linux" ;;
  *) platform_label="$platform" ;;
esac

SESSION_ID="bench-$(date +%s)-$$"
export CLAUDE_PROJECT_DIR="$ROOT"

settings_files=("$ROOT/.claude/settings.json")
if [ "$USE_LOCAL" = 1 ] && [ -f "$ROOT/.claude/settings.local.json" ]; then
  settings_files+=("$ROOT/.claude/settings.local.json")
fi

# Build the synthetic event payload for an event name.
event_payload() {
  local ev="$1"
  case "$ev" in
    PreToolUse)
      jq -nc --arg s "$SESSION_ID" --arg ev "$ev" --arg t "$TOOL" --arg c "$CMD_TEXT" --arg cwd "$ROOT" \
        '{session_id:$s, hook_event_name:$ev, tool_name:$t, cwd:$cwd,
          tool_input: (if $t=="Bash" then {command:$c, description:"bench"}
                       elif $t=="Read" then {file_path:($cwd+"/README.md")}
                       else {file_path:($cwd+"/workspace/bench-scratch.md"), content:"bench"} end)}' ;;
    PostToolUse)
      jq -nc --arg s "$SESSION_ID" --arg ev "$ev" --arg t "$TOOL" --arg c "$CMD_TEXT" --arg cwd "$ROOT" \
        '{session_id:$s, hook_event_name:$ev, tool_name:$t, cwd:$cwd,
          tool_input: (if $t=="Bash" then {command:$c, description:"bench"}
                       else {file_path:($cwd+"/workspace/bench-scratch.md"), content:"bench"} end),
          tool_response: (if $t=="Bash" then {stdout:"bench\n", stderr:"", interrupted:false}
                          else {filePath:($cwd+"/workspace/bench-scratch.md"), success:true} end)}' ;;
    UserPromptSubmit)
      jq -nc --arg s "$SESSION_ID" --arg ev "$ev" --arg cwd "$ROOT" \
        '{session_id:$s, hook_event_name:$ev, cwd:$cwd, prompt:"bench: what time is it"}' ;;
    *)
      jq -nc --arg s "$SESSION_ID" --arg ev "$ev" --arg cwd "$ROOT" \
        '{session_id:$s, hook_event_name:$ev, cwd:$cwd}' ;;
  esac
}

# List "label<TAB>command" for hooks matching event + tool across settings files.
registrations() {
  local ev="$1" f
  for f in "${settings_files[@]}"; do
    jq -r --arg ev "$ev" --arg t "$TOOL" --arg src "$(basename "$f")" '
      (.hooks[$ev] // [])[] as $entry
      | ($entry.matcher // "") as $m
      | select($m == "" or $m == "*" or ($t | test("^(" + $m + ")$")))
      | $entry.hooks[]
      | [ ( .command
            | sub("^bash \"\\$CLAUDE_PROJECT_DIR/.claude/hooks/hook-gate.sh\" "; "")
            | sub("^bash \"\\$CLAUDE_PROJECT_DIR/.claude/hooks/"; "")
            | sub(" \"\\$CLAUDE_PROJECT_DIR.*$"; "")
            | sub("\"$"; "")
          ) + " [" + $src + "]",
          .command, (.timeout // 30) ] | @tsv' "$f"
  done
}

median() { # reads numbers on stdin
  sort -n | awk '{a[NR]=$1} END{ if(NR==0){print 0} else if(NR%2){print a[(NR+1)/2]} else {print int((a[NR/2]+a[NR/2+1])/2)} }'
}

results_json="[]"
grand_total=0
printf 'bench-hooks  platform=%s  tool=%s  runs=%d  root=%s\n' "$platform_label" "$TOOL" "$RUNS" "$ROOT"
[ "$USE_LOCAL" = 1 ] && [ -f "$ROOT/.claude/settings.local.json" ] && echo "including .claude/settings.local.json"
echo

IFS=',' read -r -a ev_list <<<"$EVENTS"
for ev in "${ev_list[@]}"; do
  payload="$(event_payload "$ev")"
  ev_total=0
  count=0
  [ "$QUIET" = 1 ] || printf '== %s (tool=%s)\n%-70s %8s %8s %8s\n' "$ev" "$TOOL" "registration" "med ms" "min ms" "max ms"
  while IFS=$'\t' read -r label cmd tmo; do
    [ -n "$cmd" ] || continue
    tmo="${tmo:-30}"
    times=""
    for _ in $(seq 1 "$RUNS"); do
      t0="$(now_ms)"
      # Enforce the same per-hook timeout the harness applies (perl alarm is portable).
      ( printf '%s' "$payload" | perl -e 'alarm shift; exec "bash", "-c", shift' "$tmo" "$cmd" ) >/dev/null 2>&1
      t1="$(now_ms)"
      times="$times$((t1 - t0))"$'\n'
    done
    med="$(printf '%s' "$times" | median)"
    mn="$(printf '%s' "$times" | sort -n | head -1)"
    mx="$(printf '%s' "$times" | sort -n | tail -1)"
    ev_total=$((ev_total + med))
    count=$((count + 1))
    [ "$QUIET" = 1 ] || printf '%-70s %8d %8d %8d\n' "$label" "$med" "$mn" "$mx"
    results_json="$(jq -c --arg ev "$ev" --arg l "$label" --argjson med "$med" --argjson mn "$mn" --argjson mx "$mx" \
      '. + [{event:$ev, registration:$l, median_ms:$med, min_ms:$mn, max_ms:$mx}]' <<<"$results_json")"
  done < <(registrations "$ev")
  printf '%-70s %8d   (%d registrations)\n\n' "$ev total (sum of medians)" "$ev_total" "$count"
  grand_total=$((grand_total + ev_total))
done

echo "TOTAL hook overhead per simulated $TOOL tool call: ${grand_total} ms  [$platform_label]"

if [ -n "$JSON_OUT" ]; then
  jq -n --arg p "$platform_label" --arg t "$TOOL" --arg ev "$EVENTS" --argjson runs "$RUNS" \
     --argjson total "$grand_total" --argjson rows "$results_json" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     '{platform:$p, tool:$t, events:$ev, runs:$runs, total_median_ms:$total, generated_at:$at, registrations:$rows}' \
     > "$JSON_OUT"
  echo "wrote $JSON_OUT"
fi

# Clean bench ledgers so they do not accumulate.
find "$ROOT/workspace/orchestrator" -name "${SESSION_ID}*" -type f -delete 2>/dev/null || true
rm -f "$ROOT/workspace/bench-scratch.md" 2>/dev/null || true
