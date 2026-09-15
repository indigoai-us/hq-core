#!/bin/bash
# Session Cleanup Hook — kills leaked MCP server processes THIS session started.
#
# Problem: Claude Code spawns MCP servers as stdio child processes (via npx/tsx).
# When sessions end or crash, these Node.js grandchild processes are NOT killed
# because tsx/npx don't forward SIGHUP to their children. Over many sessions,
# this leaks node processes consuming 200MB+ each.
#
# SAFETY CONTRACT — read before changing anything here.
#
# HQ runs a shared multi-agent fleet: Agency workers, other operators' Claude and
# Codex sessions, and their workflow runners (`workflow-runner.mjs`,
# `ultracode-workflow.mjs`, legacy `codex-workflow.mjs`) all live on the same
# box. A Stop hook that sweeps by command-line pattern therefore kills OTHER
# OWNERS' live work. This hook used to do exactly that — `pgrep -f <pattern>`
# machine-wide, SIGTERM then SIGKILL — while its own header claimed it scoped by
# PPID. It did not; there was no scoping in the implementation at all.
#
# The rules now enforced below:
#
#   1. ONLY descendants of this session's own process tree are eligible. A match
#      that is not ours is left alone, no matter how orphaned it looks.
#   2. Patterns are anchored to the executable or script path, so a worker whose
#      PROMPT merely mentions "agent-browser" is not mistaken for the browser.
#   3. Agent workloads are never killed, even in-tree. A session that spawned
#      codex/claude/grok workers must not reap them on its own way out.
#   4. Anything skipped is reported, never silently swept.
#
# Do not reintroduce a bare `pgrep -f`/`pkill -f` sweep here. See hard policy
# `no-machine-wide-process-pattern-kills` and the 2026-07-28 incident.
#
# This runs as a Stop hook via hook-gate.sh.

set -uo pipefail

# Consume stdin (hook protocol)
cat >/dev/null

# MCP server process patterns. Anchored to a path boundary so these match the
# process that IS the server, not a process that merely names it in an argument.
# Each must be a whole argv token that is EITHER argv[0] (line start) OR a real
# path (has a `/` before the name). Prose that merely names the server — a
# worker prompt saying "install agent-browser later" — is not a match.
MCP_PATTERNS=(
  '(^|[[:space:]][^[:space:]]*/)slack-mcp/src/server\.ts([[:space:]]|$)'
  '(^|[[:space:]][^[:space:]]*/)advanced-gmail-mcp/src/server\.ts([[:space:]]|$)'
  '(^|[[:space:]][^[:space:]]*/)agent-browser([[:space:]]|$)'
  '(^|[[:space:]][^[:space:]]*/)detached-flush\.js([[:space:]]|$)'
)

# Command lines that are agent workloads. Never killed by this hook — a session
# that spawned workers must not reap them when it stops. The workflow runners
# are listed by script name because a runner's command line can legitimately
# carry an MCP pattern (e.g. a delegated prompt that names an agent-browser
# path) — without this entry the runner, and every agent it is driving, would
# be reaped at Stop.
PROTECTED_PATTERN='codex exec|codex-workflow\.mjs|ultracode-workflow\.mjs|workflow-runner\.mjs|codex-code-mode-host|agency-worker|agency-spawn-guardian|(^|/)claude( |$)|(^|/)codex( |$)|(^|/)grok( |$)'

SKIPPED_FOREIGN=0
SKIPPED_PROTECTED=0
KILLED_PIDS=()

# --- Establish this session's process tree -----------------------------------
# Walk up from this hook to collect our ancestor chain. Anything we kill must
# descend from one of these, which is what makes the cleanup ours.
ancestors_of() {
  local pid="$1" guard=0
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
    printf '%s\n' "$pid"
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    guard=$((guard + 1))
    [ "$guard" -gt 64 ] && break
  done
}

OUR_ANCESTORS=" $(ancestors_of "$$" | tr '\n' ' ') "

is_ours() {
  local pid="$1" guard=0
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
    case "$OUR_ANCESTORS" in
      *" $pid "*) return 0 ;;
    esac
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    guard=$((guard + 1))
    [ "$guard" -gt 64 ] && break
  done
  return 1
}

# --- Collect eligible PIDs ---------------------------------------------------
# Capture the process table once, then test every pattern in one awk pass. Keep
# one output record per matching pattern: that preserves the original counter
# and kill-list behaviour for the (unusual) case where a command matches more
# than one MCP pattern.
export MCP_PATTERN_1="${MCP_PATTERNS[0]}"
export MCP_PATTERN_2="${MCP_PATTERNS[1]}"
export MCP_PATTERN_3="${MCP_PATTERNS[2]}"
export MCP_PATTERN_4="${MCP_PATTERNS[3]}"
export PROTECTED_PATTERN

while read -r disposition pid; do
  [ -n "$pid" ] || continue
  case "$disposition" in
    protected)
      SKIPPED_PROTECTED=$((SKIPPED_PROTECTED + 1))
      ;;
    candidate)
      if is_ours "$pid"; then
        KILLED_PIDS+=("$pid")
      else
        SKIPPED_FOREIGN=$((SKIPPED_FOREIGN + 1))
      fi
      ;;
  esac
done < <(
  ps -eo pid=,args= 2>/dev/null | awk -v self="$$" '
    BEGIN {
      patterns[1] = ENVIRON["MCP_PATTERN_1"]
      patterns[2] = ENVIRON["MCP_PATTERN_2"]
      patterns[3] = ENVIRON["MCP_PATTERN_3"]
      patterns[4] = ENVIRON["MCP_PATTERN_4"]
      protected = ENVIRON["PROTECTED_PATTERN"]
    }
    {
      pid = $1
      cmd = $0
      sub(/^[[:space:]]*[0-9]+[[:space:]]*/, "", cmd)
      if (pid == self) next

      for (i = 1; i <= 4; i++) {
        if (cmd !~ patterns[i]) continue
        if (cmd ~ protected) print "protected", pid
        else print "candidate", pid
      }
    }
  '
)

# --- Terminate, then force-kill survivors ------------------------------------
if [ "${#KILLED_PIDS[@]}" -gt 0 ]; then
  for pid in "${KILLED_PIDS[@]}"; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 2
  for pid in "${KILLED_PIDS[@]}"; do
    # Re-verify ownership before escalating: PIDs can be recycled in the gap.
    if kill -0 "$pid" 2>/dev/null && is_ours "$pid"; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done
fi

# --- Report ------------------------------------------------------------------
# Never sweep silently. If leaked servers survive because they are no longer in
# our tree, say so rather than reaching outside the session to kill them.
if [ "$SKIPPED_FOREIGN" -gt 0 ] || [ "$SKIPPED_PROTECTED" -gt 0 ]; then
  printf 'cleanup-mcp-processes: killed %d in-session process(es); left %d outside this session and %d agent workload(s) alone.\n' \
    "${#KILLED_PIDS[@]}" "$SKIPPED_FOREIGN" "$SKIPPED_PROTECTED" >&2
fi

# Clean up stale debounce/tracking files from /tmp
find /tmp -maxdepth 1 -name 'hq-checkpoint-last-*' -mmin +60 -delete 2>/dev/null || true
find /tmp -maxdepth 1 -name 'hq-screenshot-count-*' -mmin +60 -delete 2>/dev/null || true

exit 0
