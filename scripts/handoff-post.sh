#!/usr/bin/env bash
# handoff-post.sh — detached post-handoff orchestrator.
#
# Runs AFTER handoff-finalize.sh emits handoff.json. Does the expensive work
# that used to burn foreground-session tokens:
#   1. Archive old threads (60d), then regen thread INDEX.md + recent.md (bash)
#   2. Regen orchestrator INDEX.md (bash)
#   3. Dispatch /learn in a fresh headless Claude session if learnings provided
#   4. Dispatch /document-release in a fresh headless Claude session if session
#      scope includes company/repo files
#   5. Background qmd cleanup + update + embed (unchanged)
#
# Each headless `claude -p` invocation gets its own fresh context — zero impact
# on the foreground session that spawned this script.
#
# Usage (called by handoff skill as `nohup handoff-post.sh ... &`):
#   scripts/handoff-post.sh <thread_path> [learnings_json_file]

set -euo pipefail

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$HQ_ROOT"

THREAD_PATH="${1:-}"
LEARNINGS_FILE="${2:-}"

LOG_DIR="/tmp"
LOG_MAIN="${LOG_DIR}/handoff-post.log"
LOG_LEARN="${LOG_DIR}/handoff-learn.log"
LOG_DOCREL="${LOG_DIR}/handoff-docrelease.log"
LOG_QMD="${LOG_DIR}/qmd-handoff.log"

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

log() { echo "[${TS}] $*" >> "$LOG_MAIN"; }

: > "$LOG_MAIN"
log "handoff-post starting (thread=${THREAD_PATH:-none}, learnings=${LEARNINGS_FILE:-none})"

# --- 1. Archive old threads (gated once per 24h) ---
if bash scripts/archive-old-threads.sh --gated >>"$LOG_MAIN" 2>&1; then
  log "archive: ok"
else
  log "archive: error (continuing)"
fi

# --- 2. Regen thread INDEX + recent (bash, no Claude) ---
if bash scripts/rebuild-threads-index.sh --both >>"$LOG_MAIN" 2>&1; then
  log "threads-index: ok"
else
  log "threads-index: error (continuing)"
fi

# --- 3. Regen orchestrator INDEX (bash, no Claude) ---
if bash scripts/rebuild-orchestrator-index.sh >>"$LOG_MAIN" 2>&1; then
  log "orchestrator-index: ok"
else
  log "orchestrator-index: error (continuing)"
fi

# --- 4. Headless /learn (if learnings captured) ---
if [[ -n "$LEARNINGS_FILE" && -s "$LEARNINGS_FILE" ]] && command -v claude >/dev/null 2>&1; then
  log "learn: dispatching headless"
  learnings_content=$(cat "$LEARNINGS_FILE")
  prompt="/learn ${learnings_content}"
  # Run with its own fresh context, don't persist session.
  CLAUDE_HEADLESS=1 claude -p "$prompt" \
    --no-session-persistence \
    --permission-mode auto \
    --output-format text \
    > "$LOG_LEARN" 2>&1 || log "learn: exited non-zero (see $LOG_LEARN)"
  log "learn: done"
else
  log "learn: skipped (no learnings or claude CLI unavailable)"
fi

# --- 5. Headless /document-release (if scope matches) ---
if [[ -n "$THREAD_PATH" && -f "$THREAD_PATH" ]] && command -v claude >/dev/null 2>&1; then
  scope_match=$(jq -r '
    [.files_touched[]? // empty] | map(select(test("^(companies|repos)/"))) | length
  ' "$THREAD_PATH" 2>/dev/null || echo 0)
  if [[ "${scope_match:-0}" -gt 0 ]]; then
    log "document-release: dispatching headless (${scope_match} scoped files)"
    CLAUDE_HEADLESS=1 claude -p "/document-release" \
      --no-session-persistence \
      --permission-mode auto \
      --output-format text \
      > "$LOG_DOCREL" 2>&1 || log "document-release: exited non-zero (see $LOG_DOCREL)"
    log "document-release: done"
  else
    log "document-release: skipped (no company/repo files in files_touched)"
  fi
else
  log "document-release: skipped (no thread path or claude CLI unavailable)"
fi

# --- 6. qmd reindex (background, fire-and-forget) ---
if command -v qmd >/dev/null 2>&1; then
  nohup bash -c 'qmd cleanup 2>/dev/null; qmd update 2>/dev/null && qmd embed 2>/dev/null' \
    > "$LOG_QMD" 2>&1 &
  log "qmd: launched PID $!"
else
  log "qmd: skipped (CLI unavailable)"
fi

log "handoff-post complete"
