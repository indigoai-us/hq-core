#!/usr/bin/env bash
# handoff-post.sh — detached post-handoff orchestrator.
#
# Runs AFTER handoff-finalize.sh emits handoff.json. Does the mechanical work
# that used to burn foreground-session tokens:
#   1. Archive old threads (60d), then regen thread INDEX.md + recent.md (bash)
#   2. Regen orchestrator INDEX.md (bash)
#   3. qmd reindex via qmd-reindex-bg.sh (single-flight; agent boxes skip)
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
HANDOFF_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HANDOFF_SCRIPT_DIR/lib/session-id.sh"

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
if hq core archive-old-threads --gated >>"$LOG_MAIN" 2>&1; then
  log "archive: ok"
else
  log "archive: error (continuing)"
fi

# --- 2. Regen thread INDEX + recent (bash, no Claude) ---
if hq core rebuild-index threads --both >>"$LOG_MAIN" 2>&1; then
  log "threads-index: ok"
else
  log "threads-index: error (continuing)"
fi

# --- 3. Regen orchestrator INDEX (bash, no Claude) ---
if hq core rebuild-index orchestrator >>"$LOG_MAIN" 2>&1; then
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
  if scope_counts=$(jq -r '
    (.files_touched // []) as $files
    | (if ($files | type) == "array" then
         [$files[] |
           if type == "string" then .
           elif type == "object" and (.path | type) == "string" then .path
           else null
           end]
       else [] end) as $paths
    | [
        ($paths | map(select(if type == "string" then test("^(companies|repos)/") else false end)) | length),
        ($paths | map(select(. == null)) | length)
      ]
    | @tsv
  ' "$THREAD_PATH" 2>/dev/null); then
    IFS=$'\t' read -r scope_match skipped_count <<< "$scope_counts"
  else
    scope_match=0
    skipped_count=0
    log "document-release: skipped (invalid thread JSON)"
  fi
  for ((skipped_index = 0; skipped_index < skipped_count; skipped_index++)); do
    log "document-release: skipped unsupported files_touched entry"
  done
  if [[ "$scope_match" -gt 0 ]]; then
    if bash "$HQ_ROOT/core/scripts/skill-installed.sh" document-release "${HQ_ACTIVE_COMPANY:-}" >/dev/null 2>>"$LOG_MAIN"; then
      log "document-release: eligible and pending runtime dispatch by handoff skill ($scope_match scoped files; no dispatch proof)"
    else
      log "document-release: skipped (skill not installed)"
    fi
  else
    log "document-release: skipped (no company/repo files in files_touched)"
  fi
else
  log "document-release: skipped (no thread path)"
fi

# --- 3b. Push company handoff mirrors promptly (best effort) ---
# Session snapshots are intentionally gitignored, so a completed mirror needs
# the sync client to make the handoff available to a second device. Keep
# finalizer company metadata and add the company bound to this session when no
# changed path identified one; never use a device-wide active-company value.
bound_session_company() {
  local session_id metadata company
  session_id="$(session_id_resolve "$HQ_ROOT")"
  [[ -n "$session_id" ]] || return 0
  metadata="$HQ_ROOT/workspace/sessions/$session_id/meta.yaml"
  [[ -r "$metadata" ]] || return 0
  company="$(awk '$1 == "company_slug:" { sub(/^[^:]+:[[:space:]]*/, ""); gsub(/^"|"$/, ""); print; exit }' "$metadata" 2>/dev/null || true)"
  [[ "$company" =~ ^[a-z][a-z0-9_-]*$ ]] || return 0
  printf '%s' "$company"
}

if [[ -n "$THREAD_PATH" && -f "$THREAD_PATH" ]] && command -v hq >/dev/null 2>&1; then
  if [[ "$THREAD_PATH" == /* ]]; then
    THREAD_FILE="$THREAD_PATH"
  else
    THREAD_FILE="$HQ_ROOT/$THREAD_PATH"
  fi
  THREAD_COMPANIES_JSON="$(jq -c '
    (.metadata.company // [])
    | (if type == "array" then . else [.] end)
    | map(select(type == "string" and test("^[a-z][a-z0-9_-]*$")))
    | unique
  ' "$THREAD_FILE" 2>/dev/null || printf '[]')"
  THREAD_PATH_COMPANIES_JSON="$(jq -c --arg hq_root "$HQ_ROOT" '
    [ ((.files_touched // []) | if type == "array" then .[] else empty end)
    | (if type == "string" then . elif type == "object" and (.path | type) == "string" then .path else "" end)
    | (if startswith($hq_root + "/") then .[(($hq_root | length) + 1):] else . end)
    | sub("^\\./"; "")
    | (try capture("^companies/(?<company>[a-z][a-z0-9_-]*)/").company catch null)
      | select(type == "string")
    ] | unique
  ' "$THREAD_FILE" 2>/dev/null || printf '[]')"
  BOUND_COMPANY="$(bound_session_company)"
  THREAD_COMPANY_COUNT="$(jq 'length' <<< "$THREAD_COMPANIES_JSON")"
  THREAD_PATH_COMPANY_COUNT="$(jq 'length' <<< "$THREAD_PATH_COMPANIES_JSON")"
  SYNC_COMPANIES_JSON='[]'
  if [[ "$THREAD_COMPANY_COUNT" -gt 1 || "$THREAD_PATH_COMPANY_COUNT" -gt 1 ]]; then
    log "workspace-sync: skipped (handoff spans multiple companies)"
  elif [[ -z "$BOUND_COMPANY" || ! -d "$HQ_ROOT/companies/$BOUND_COMPANY" ]]; then
    log "workspace-sync: skipped (no bound company for this session)"
  elif { [[ "$THREAD_COMPANY_COUNT" -eq 1 ]] && [[ "$(jq -r '.[0]' <<< "$THREAD_COMPANIES_JSON")" != "$BOUND_COMPANY" ]]; } || \
       { [[ "$THREAD_PATH_COMPANY_COUNT" -eq 1 ]] && [[ "$(jq -r '.[0]' <<< "$THREAD_PATH_COMPANIES_JSON")" != "$BOUND_COMPANY" ]]; }; then
    log "workspace-sync: skipped (handoff paths do not match the bound company)"
  else
    SYNC_COMPANIES_JSON="$(jq -cn --arg company "$BOUND_COMPANY" '[$company]')"
    THREAD_TMP="$(mktemp "$HQ_ROOT/workspace/threads/.handoff-post-XXXXXX")"
    if jq -c --argjson companies "$SYNC_COMPANIES_JSON" \
      '.metadata = (.metadata // {}) | .metadata.company = $companies' \
      "$THREAD_FILE" > "$THREAD_TMP" && mv "$THREAD_TMP" "$THREAD_FILE"; then
      :
    else
      rm -f "$THREAD_TMP"
      log "workspace-sync: skipped (could not add bound company to handoff thread)"
      SYNC_COMPANIES_JSON='[]'
    fi
  fi
  THREAD_ID="$(jq -r '.thread_id // empty' "$THREAD_FILE" 2>/dev/null || true)"
  THREAD_MIRRORABLE="false"
  case "$THREAD_FILE" in
    "$HQ_ROOT"/workspace/threads/T-*.json)
      if [[ "$THREAD_ID" =~ ^T-[A-Za-z0-9._-]+$ ]]; then THREAD_MIRRORABLE="true"; fi
      ;;
  esac
  if [[ "$THREAD_MIRRORABLE" == "true" && "$SYNC_COMPANIES_JSON" != '[]' ]]; then
    MIRROR_HOOK="$HQ_ROOT/.claude/hooks/mirror-thread-to-company.sh"
    if [[ -f "$MIRROR_HOOK" ]]; then
      jq -n --arg file_path "$THREAD_FILE" \
        '{tool_name:"Write",tool_input:{file_path:$file_path}}' | \
        bash "$MIRROR_HOOK" >>"$LOG_MAIN" 2>&1 || \
        log "workspace-sync: mirror hook failed for handoff thread"
    else
      log "workspace-sync: mirror hook unavailable for handoff thread"
    fi
  fi
  while IFS= read -r company; do
    [[ "$company" =~ ^[a-z][a-z0-9_-]*$ ]] || continue
    [[ -d "$HQ_ROOT/companies/$company/workspace" ]] || continue
    if [[ "$THREAD_MIRRORABLE" != "true" || \
          ! -f "$HQ_ROOT/companies/$company/workspace/sessions/$THREAD_ID.json" ]]; then
      log "workspace-sync: skipped (thread mirror missing for $company)"
      continue
    fi
    if hq sync push --company "$company" "companies/$company/workspace" >>"$LOG_MAIN" 2>&1; then
      log "workspace-sync: pushed companies/$company/workspace"
    else
      log "workspace-sync: failed companies/$company/workspace"
    fi
  done < <(jq -r '.[]' <<< "$SYNC_COMPANIES_JSON")
elif [[ -n "$THREAD_PATH" && -f "$THREAD_PATH" ]]; then
  log "workspace-sync: skipped (hq CLI unavailable)"
fi

# --- 4. qmd reindex (agent: skip; laptop: single-flight) ---
# handoff-finalize may already have run the helper; agent boxes no-op
# (skipped-agent). Never dual-nohup raw cleanup+update+embed on agents.
# Never invoke managed index wrappers — handoff owns no agent freshness.
# Prefer Core US-001 helper; fleet binary only if Core file is missing.
# Lock acquisition runs BEFORE the US-010 session_end spawn so a detached
# session-end hook cannot delay or interleave with finalize+post single-flight.
_QMD_BG="$HQ_ROOT/core/scripts/qmd-reindex-bg.sh"
if [[ ! -f "$_QMD_BG" ]] && [[ -x /usr/local/bin/hq-agent-qmd-reindex-bg ]]; then
  _QMD_BG=/usr/local/bin/hq-agent-qmd-reindex-bg
fi
if [[ -x "$_QMD_BG" ]] || [[ -f "$_QMD_BG" ]]; then
  _qmd_out="$(bash "$_QMD_BG" --log "$LOG_QMD" 2>/dev/null || true)"
  # Empty stdout is busy/dedupe quiet — never claim "ok".
  log "qmd: reindex-bg → ${_qmd_out:-busy-or-quiet}"
elif [[ -d /var/lib/hq-agent ]]; then
  log "qmd: skipped-agent (no helper; indexer owns freshness)"
else
  log "qmd: skipped (helper missing)"
fi

# --- 4b. Work Mesh Live: enqueue session_end (US-010) ---
# Detached + non-blocking. Presence ends via spool; daemon flushes.
# Same launch shape as the former work-mesh-close hook (nohup + disown).
# Runs AFTER qmd reindex so this path cannot perturb single-flight lock
# acquisition order or spawn count. Guarded: older checkouts skip quietly.
WM_END_HOOK="$HQ_ROOT/core/hooks/SessionEnd/35-work-mesh-session-end.sh"
if [[ -f "$WM_END_HOOK" ]]; then
  sid=""
  sid="$(session_id_resolve "$HQ_ROOT")"
  if [[ -n "$sid" ]]; then
    payload=$(printf '{"session_id":"%s"}' "$sid")
  else
    payload='{}'
  fi
  _detach_pidfile="${TMPDIR:-/tmp}/hq-handoff-session-end-$$.pid"
  _detach_script="$HQ_ROOT/core/scripts/hq-detach.sh"
  HQ_ROOT="$HQ_ROOT" CLAUDE_CODE_SESSION_ID="${sid:-}" \
    bash "$_detach_script" --handoff --pidfile "$_detach_pidfile" \
      --logfile "${LOG_DIR}/work-mesh-session-end.log" -- \
      bash -c 'printf "%s\n" "$1" | bash "$2" SessionEnd' _ "$payload" "$WM_END_HOOK" \
      || log "work-mesh-session-end: launch failed (see ${LOG_DIR}/work-mesh-session-end.log)"
  _detach_pid="$(cat "$_detach_pidfile" 2>/dev/null || true)"
  rm -f "$_detach_pidfile"
  log "work-mesh-session-end: launched PID ${_detach_pid:-unknown}"
else
  log "work-mesh-session-end: skipped (hook absent)"
fi

# --- 5. Worktree GC (gated once-per-24h, detached, fully fail-soft) ---
# HQ worktrees accumulate forever and can reach hundreds of GB. Opportunistically
# GC the provably-safe stale ones on every handoff. --gated caps this to once per
# 24h; --apply lets it actually remove (the script's own guards keep it to clean,
# old, branch-preserved, unreferenced worktrees only). Launched DETACHED because
# the safety check fetches from origin per repo — it must never block or fail the
# handoff. Guarded so an older checkout without the script simply skips it.
WT_GC="$HQ_ROOT/core/scripts/worktree-gc.sh"
if [[ -f "$WT_GC" ]]; then
  _detach_pidfile="${TMPDIR:-/tmp}/hq-handoff-worktree-gc-$$.pid"
  _detach_script="$HQ_ROOT/core/scripts/hq-detach.sh"
  HQ_ROOT="$HQ_ROOT" bash "$_detach_script" --handoff --pidfile "$_detach_pidfile" \
    --logfile "${LOG_DIR}/worktree-gc.log" -- bash "$WT_GC" --apply --gated \
    || log "worktree-gc: launch failed (see ${LOG_DIR}/worktree-gc.log)"
  _detach_pid="$(cat "$_detach_pidfile" 2>/dev/null || true)"
  rm -f "$_detach_pidfile"
  log "worktree-gc: launched PID ${_detach_pid:-unknown} (--apply --gated)"
else
  log "worktree-gc: skipped (script absent)"
fi

log "handoff-post complete"
