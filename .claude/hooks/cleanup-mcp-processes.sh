#!/bin/bash
# Session Cleanup Hook — kills orphaned MCP server processes on session end.
#
# Problem: Claude Code spawns MCP servers as stdio child processes (via npx/tsx).
# When sessions end or crash, these Node.js grandchild processes are NOT killed
# because tsx/npx don't forward SIGHUP to their children. Over many sessions,
# this leaks hundreds of node processes consuming 200MB+ each.
#
# Approach: Use the Claude session's PPID to find MCP server processes that were
# spawned by this session's process tree. Kill them gracefully (SIGTERM), then
# force-kill (SIGKILL) any survivors after 2 seconds.
#
# Known MCP servers to clean up:
#   - slack-mcp/src/server.ts (Slack)
#   - advanced-gmail-mcp/src/server.ts (Gmail)
#   - agent-browser (Chromium-based, highest memory risk)
#
# This runs as a Stop hook via hook-gate.sh.

set -euo pipefail

# Consume stdin (hook protocol)
cat >/dev/null

# MCP server process patterns to clean up
MCP_PATTERNS=(
  'slack-mcp/src/server.ts'
  'advanced-gmail-mcp/src/server.ts'
  'agent-browser'
)

KILLED=0

for pattern in "${MCP_PATTERNS[@]}"; do
  # Find matching PIDs (exclude this script's own grep)
  PIDS=$(pgrep -f "$pattern" 2>/dev/null || true)

  if [ -n "$PIDS" ]; then
    # Send SIGTERM first (graceful shutdown)
    for pid in $PIDS; do
      kill -TERM "$pid" 2>/dev/null && KILLED=$((KILLED + 1)) || true
    done
  fi
done

# Also clean up orphaned Next.js telemetry flush processes
FLUSH_PIDS=$(pgrep -f 'detached-flush.js' 2>/dev/null || true)
if [ -n "$FLUSH_PIDS" ]; then
  for pid in $FLUSH_PIDS; do
    kill -TERM "$pid" 2>/dev/null && KILLED=$((KILLED + 1)) || true
  done
fi

# Wait briefly, then force-kill any survivors
if [ $KILLED -gt 0 ]; then
  sleep 2
  for pattern in "${MCP_PATTERNS[@]}"; do
    PIDS=$(pgrep -f "$pattern" 2>/dev/null || true)
    if [ -n "$PIDS" ]; then
      for pid in $PIDS; do
        kill -KILL "$pid" 2>/dev/null || true
      done
    fi
  done

  # Force-kill surviving telemetry flushes
  FLUSH_PIDS=$(pgrep -f 'detached-flush.js' 2>/dev/null || true)
  if [ -n "$FLUSH_PIDS" ]; then
    for pid in $FLUSH_PIDS; do
      kill -KILL "$pid" 2>/dev/null || true
    done
  fi
fi

# Clean up stale debounce/tracking files from /tmp
find /tmp -maxdepth 1 -name 'hq-checkpoint-last-*' -mmin +60 -delete 2>/dev/null || true
find /tmp -maxdepth 1 -name 'hq-screenshot-count-*' -mmin +60 -delete 2>/dev/null || true

exit 0
