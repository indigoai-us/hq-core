#!/usr/bin/env bash
# handoff-post.sh — detached post-handoff orchestrator.
#
# Runs AFTER handoff-finalize.sh emits handoff.json. Does the mechanical work
# that used to burn foreground-session tokens:
#   1. Archive old threads (60d), then regen thread INDEX.md + recent.md (bash)
#   2. Regen orchestrator INDEX.md (bash)
#   3. Background qmd cleanup + update + embed
#
# Model work is intentionally not launched from this detached shell. /learn and
# /document-release follow-ups run from the handoff skill itself, so auth
# failures cannot disappear into /tmp logs.
#
# Usage (called by handoff skill as `nohup handoff-post.sh ... &`):
#   core/scripts/handoff-post.sh <thread_path> [learnings_json_file]

set -euo pipefail

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$HQ_ROOT"

THREAD_PATH="${1:-}"
LEARNINGS_FILE="${2:-}"

LOG_DIR="${HANDOFF_LOG_DIR:-/tmp}"
LOG_MAIN="${LOG_DIR}/handoff-post.log"
LOG_QMD="${LOG_DIR}/qmd-handoff.log"

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

log() { echo "[${TS}] $*" >> "$LOG_MAIN"; }

: > "$LOG_MAIN"
log "handoff-post starting (thread=${THREAD_PATH:-none}, learnings=${LEARNINGS_FILE:-none})"

# --- 1. Archive old threads (gated once per 24h) ---
if bash core/scripts/archive-old-threads.sh --gated >>"$LOG_MAIN" 2>&1; then
  log "archive: ok"
else
  log "archive: error (continuing)"
fi

# --- 2. Regen thread INDEX + recent (bash, no Claude) ---
if bash core/scripts/rebuild-threads-index.sh --both >>"$LOG_MAIN" 2>&1; then
  log "threads-index: ok"
else
  log "threads-index: error (continuing)"
fi

# --- 3. Regen orchestrator INDEX (bash, no Claude) ---
if bash core/scripts/rebuild-orchestrator-index.sh >>"$LOG_MAIN" 2>&1; then
  log "orchestrator-index: ok"
else
  log "orchestrator-index: error (continuing)"
fi

if [[ -n "$LEARNINGS_FILE" && -s "$LEARNINGS_FILE" ]]; then
  learning_count=$(jq 'if type == "array" then length else 0 end' "$LEARNINGS_FILE" 2>/dev/null || echo 0)
  if [[ "${learning_count:-0}" -gt 0 ]]; then
    log "learn: eligible and pending runtime dispatch by handoff skill (${learning_count} learning(s); no dispatch proof)"
  else
    log "learn: no learnings to dispatch"
  fi
else
  log "learn: no learnings file provided"
fi

if [[ -n "$THREAD_PATH" && -f "$THREAD_PATH" ]]; then
  scope_match=$(jq -r '
    [.files_touched[]? // empty] | map(select(test("^(companies|repos)/"))) | length
  ' "$THREAD_PATH" 2>/dev/null || echo 0)
  if [[ "${scope_match:-0}" -gt 0 ]]; then
    log "document-release: eligible and pending runtime dispatch by handoff skill (${scope_match} scoped files; no dispatch proof)"
  else
    log "document-release: skipped (no company/repo files in files_touched)"
  fi
else
  log "document-release: skipped (no thread path)"
fi

# --- 3b. Work Mesh close: reconcile the session + (gated) transcript copy ---
# US-004: fire the close hook DETACHED + non-blocking so /handoff posts the
# authoritative outcome and hands off a vetted transcript. The hook resolves the
# session from workspace/sessions/.current (no hook stdin on this path), is
# fully fail-soft, and never blocks handoff. Guarded so an older checkout
# without the hook simply skips it.
WM_CLOSE_HOOK="$HQ_ROOT/core/hooks/work-mesh-close.sh"
if [[ -f "$WM_CLOSE_HOOK" ]]; then
  HQ_ROOT="$HQ_ROOT" nohup bash "$WM_CLOSE_HOOK" close >>"${LOG_DIR}/work-mesh-close.log" 2>&1 </dev/null &
  disown 2>/dev/null || true
  log "work-mesh-close: launched PID $!"
else
  log "work-mesh-close: skipped (hook absent)"
fi

# --- 4. qmd reindex (background, fire-and-forget) ---
if command -v qmd >/dev/null 2>&1; then
  nohup bash -c 'qmd cleanup 2>/dev/null; qmd update 2>/dev/null && qmd embed 2>/dev/null' \
    > "$LOG_QMD" 2>&1 &
  log "qmd: launched PID $!"
else
  log "qmd: skipped (CLI unavailable)"
fi

log "handoff-post complete"
