#!/usr/bin/env bash
# hq-core: public
# work-mesh-close.sh — client-side, fire-and-forget close-time reconcile +
# vetted transcript handoff, plus the SessionStart late-reconcile sweep (US-004).
#
# Two entry modes (chosen by $1); a third + fourth are the detached bg phases:
#   close        Foreground close. Resolve the session + its registered
#                companies, spool a close 'attempt', spawn the detached bg
#                reconcile+copy, and return <1s. Fired by the SessionEnd leaf
#                (core/hooks/SessionEnd/35-work-mesh-close.sh) and, detached,
#                by core/scripts/handoff-post.sh. /checkpoint is deliberately
#                NOT wired — the sweep covers anything a checkpoint misses.
#   sweep        Foreground sweep. Spawn the detached bg sweep and return <1s.
#                Fired by the SessionStart leaf (36-work-mesh-sweep.sh).
#   __close_bg__ Detached: per-company reconcile + (structurally-gated,
#                double-consent, fail-closed-redacted) transcript copy.
#   __sweep_bg__ Detached: scan the spool for registered sessions lacking a
#                reconcile/copy whose session is no longer active; claim each
#                atomically; late-reconcile + copy; quarantine gate-off pendings.
#
# SECURITY: the transcript copy is produced ONLY after a STRUCTURAL work-record
# gate (a US-003 registration marker), under DOUBLE consent (company capture +
# person opt-in), with FAIL-CLOSED redaction, and NEVER for multi-company or
# non-Claude sessions in v1. See work-mesh-lib.sh for the invariants.
#
# bash-3.2 compatible. Always exits 0 (fail-soft). Silent on stdout.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
HQ_ROOT_BOOT="${HQ_ROOT:-$(cd "$HOOK_DIR/../.." 2>/dev/null && pwd)}"
[ -n "$HQ_ROOT_BOOT" ] || exit 0
export HQ_ROOT="$HQ_ROOT_BOOT"
LIB="$HQ_ROOT_BOOT/core/scripts/work-mesh-lib.sh"
[ -f "$LIB" ] || exit 0
# shellcheck source=core/scripts/work-mesh-lib.sh
. "$LIB" 2>/dev/null || exit 0

command -v jq >/dev/null 2>&1 || exit 0

case "${HQ_WORK_MESH_DISABLED:-}" in
  1|true|TRUE|yes|YES|on|ON) exit 0 ;;
esac
case ",${HQ_DISABLED_HOOKS:-}," in
  *,work-mesh-close,*) exit 0 ;;
esac

# ---------------------------------------------------------------------------
# meta.yaml reader (same idiom as work-mesh-register.sh)
# ---------------------------------------------------------------------------
wmc_meta_get() {
  local root="$1" sid="$2" key="$3" meta
  meta="$root/workspace/sessions/$sid/meta.yaml"
  [ -f "$meta" ] || return 0
  awk -v k="$key" '$1==k":"{ sub(/^[^:]+:[[:space:]]*/,""); gsub(/^"|"$/,""); print; exit }' "$meta" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Absolute path to self for the detached re-exec.
# ---------------------------------------------------------------------------
wmc_self() {
  local self="${BASH_SOURCE[0]}"
  case "$self" in
    /*) : ;;
    *)  self="$(cd "$(dirname "$self")" 2>/dev/null && pwd)/$(basename "$self")" ;;
  esac
  printf '%s' "$self"
}

# Quarantine (remove) any locally-staged transcript for (slug, sid) across all
# personUid dirs — used when a company/person gate is found OFF. Never touches
# anything outside the gitignored companies/<slug>/sessions/ staging area.
wmc_quarantine() {
  local slug="$1" sid="$2" stage f
  wm_safe_path_component "$slug" || return 0
  wm_safe_path_component "$sid" || return 0
  stage="$(wm_stage_dir "$slug")"
  [ -d "$stage" ] || return 0
  for f in "$stage"/*/"$sid".jsonl "$stage"/*/".$sid.jsonl.redacting."*; do
    [ -e "$f" ] && rm -f "$f" 2>/dev/null || true
  done
}

# ===========================================================================
# Core routine — reconcile + optional copy for ONE (sessionId, companySlug).
# Shared by __close_bg__ and __sweep_bg__. Idempotent + fail-soft. Uses marker
# files (reconciled/copied) as the terminal/retry signal so the sweep can tell
# a completed record from a pending one, offline-safe.
#   $1 root  $2 sid  $3 slug  $4 transcript  $5 isMulti(0/1)
#   $6 harness  $7 project  $8 category  $9 intent  $10 summary
# ===========================================================================
wmc_reconcile_and_copy_one() {
  local root="$1" sid="$2" slug="$3" tp="$4" ismulti="$5"
  local harness="$6" project="$7" category="$8" intent="$9" summary="${10}"
  local base token uid gates outcome payload code puid rc n
  local rmark cmark tflag=""
  if ! wm_safe_path_component "$sid" || ! wm_safe_path_component "$slug"; then
    wm_log "close: unsafe session/company path component refused"
    return 0
  fi
  rmark="$(wm_reconciled_marker "$sid" "$slug")"
  cmark="$(wm_copied_marker "$sid" "$slug")"
  base="$(wm_api_base)"

  # No token -> locally-logged no-op; leave everything pending for the sweep.
  if ! token="$(wm_read_token)" || [ -z "$token" ]; then
    wm_log "close: no valid token for sid=$sid slug=$slug (pending)"
    wm_spool "$(wm_spool_build reconcile-pending "$sid" "$slug" "$uid" "$project" "" "$category" "$intent" "$harness" reason no_token)"
    return 0
  fi

  # Resolve companyUid (spool-recorded first, then /membership/me).
  uid="$(wm_registered_uid "$sid" "$slug")"
  [ -n "$uid" ] || uid="$(wm_resolve_uid "$base" "$token" "$slug")" || uid=""
  if [ -z "$uid" ]; then
    wm_log "close: could not resolve uid for slug=$slug sid=$sid (pending)"
    wm_spool "$(wm_spool_build reconcile-pending "$sid" "$slug" "" "$project" "" "$category" "$intent" "$harness" reason no_uid)"
    return 0
  fi

  # Fetch gates once (governs both the reconcile registry gate and the copy
  # double-consent). Advisory when unreachable; authoritative when explicit.
  gates="$(wm_gates_refresh "$base" "$token" "$uid")" || gates=""

  # Registry gate OFF -> do not reconcile; terminal (won't retry). Quarantine
  # any staged copy so it never syncs.
  if [ -n "$gates" ] && wm_gate_is_false "$gates" workRegistryEnabled; then
    wm_log "close: workRegistryEnabled=false uid=$uid slug=$slug (terminal skip)"
    wm_spool "$(wm_spool_build reconcile-skipped "$sid" "$slug" "$uid" "$project" "" "$category" "$intent" "$harness" reason registry_disabled)"
    wmc_quarantine "$slug" "$sid"
    : > "$rmark" 2>/dev/null || true
    : > "$cmark" 2>/dev/null || true
    return 0
  fi

  # Determine the transcript-availability flag that rides the reconcile record.
  if [ "$ismulti" = "1" ]; then
    tflag="crossCompany"
  elif [ "$harness" != "claude-code" ] || [ -z "$tp" ] || [ ! -f "$tp" ]; then
    tflag="transcriptUnavailable"
  fi

  # Derive the outcome (best-effort, bounded). crossCompany/no-transcript still
  # reconcile with a minimal skeleton (never a silent no-op).
  if [ "$ismulti" = "1" ]; then
    outcome="$(wm_derive_outcome "" "$sid" "$project" "")"
  else
    outcome="$(wm_derive_outcome "$tp" "$sid" "$project" "")"
  fi
  [ -n "$outcome" ] || outcome="$(wm_derive_outcome "" "$sid" "$project" "")"

  # Oversized transcript: flag size-budget on the reconcile (copy is skipped
  # below); the derivation already fell back to the minimal skeleton.
  if [ "$ismulti" != "1" ] && [ -n "$tp" ] && [ -f "$tp" ]; then
    local sz cap; sz="$(wc -c < "$tp" 2>/dev/null | tr -d '[:space:]')"; [ -n "$sz" ] || sz=0
    cap="$(wm_transcript_budget)"
    [ "$sz" -gt "$cap" ] 2>/dev/null && tflag="transcriptSkipped"
  fi

  payload="$(wm_reconcile_payload "$uid" "$sid" "$outcome" "$summary" "$harness" "$category" "$intent" "$tflag" "${tflag:+set}")"
  if [ -z "$payload" ]; then
    wm_log "close: failed to build reconcile payload uid=$uid slug=$slug"
    return 0
  fi

  code="$(wm_http_post "$base" "$token" "/v1/work-mesh/work-sessions/reconcile" "$payload")" || code="000"
  case "$code" in
    200|201)
      local rk rv
      if [ -n "$tflag" ]; then rk="$tflag"; rv="set"; else rk="httpStatus"; rv="$code"; fi
      wm_log "close: reconciled uid=$uid slug=$slug (HTTP $code)${tflag:+ flag=$tflag}"
      wm_spool "$(wm_spool_build reconciled "$sid" "$slug" "$uid" "$project" "" "$category" "$intent" "$harness" "$rk" "$rv")"
      : > "$rmark" 2>/dev/null || true
      ;;
    *)
      wm_log "close: reconcile failed uid=$uid slug=$slug (HTTP $code) — sweep backfills"
      wm_spool "$(wm_spool_build reconcile-error "$sid" "$slug" "$uid" "$project" "" "$category" "$intent" "$harness" httpStatus "$code")"
      return 0
      ;;
  esac

  # ---- Transcript copy gate (all conditions fail-closed) ------------------
  # Multi-company (v1 exclusion): no copy for ANY company.
  if [ "$ismulti" = "1" ]; then
    wm_spool "$(wm_spool_build copy-skipped "$sid" "$slug" "$uid" "$project" "" "$category" "$intent" "$harness" reason cross_company)"
    : > "$cmark" 2>/dev/null || true
    return 0
  fi
  # Non-Claude harness OR no transcript on disk (harness-specific v1 scope).
  if [ "$harness" != "claude-code" ] || [ -z "$tp" ] || [ ! -f "$tp" ]; then
    wm_spool "$(wm_spool_build copy-skipped "$sid" "$slug" "$uid" "$project" "" "$category" "$intent" "$harness" reason transcript_unavailable)"
    : > "$cmark" 2>/dev/null || true
    return 0
  fi
  # Structural work-record gate: a US-003 registration marker MUST exist.
  if [ ! -f "$(wm_reg_marker "$sid" "$slug")" ]; then
    wm_log "close: no registration marker for sid=$sid slug=$slug — refusing copy"
    wm_spool "$(wm_spool_build copy-skipped "$sid" "$slug" "$uid" "$project" "" "$category" "$intent" "$harness" reason no_work_record)"
    : > "$cmark" 2>/dev/null || true
    return 0
  fi
  # Size budget.
  local sz2 cap2; sz2="$(wc -c < "$tp" 2>/dev/null | tr -d '[:space:]')"; [ -n "$sz2" ] || sz2=0
  cap2="$(wm_transcript_budget)"
  if [ "$sz2" -gt "$cap2" ] 2>/dev/null; then
    wm_spool "$(wm_spool_build copy-skipped "$sid" "$slug" "$uid" "$project" "" "$category" "$intent" "$harness" reason size_budget)"
    : > "$cmark" 2>/dev/null || true
    return 0
  fi
  # Double consent. Gates unreachable => fail closed (no copy), keep pending.
  if [ -z "$gates" ]; then
    wm_spool "$(wm_spool_build copy-pending "$sid" "$slug" "$uid" "$project" "" "$category" "$intent" "$harness" reason gates_unreachable)"
    return 0
  fi
  if ! wm_gate_is_true "$gates" transcriptCaptureEnabled || ! wm_gate_is_true "$gates" transcriptOptIn; then
    wm_log "close: transcript consent OFF uid=$uid slug=$slug (terminal skip + quarantine)"
    wm_spool "$(wm_spool_build copy-skipped "$sid" "$slug" "$uid" "$project" "" "$category" "$intent" "$harness" reason gates_off)"
    wmc_quarantine "$slug" "$sid"
    : > "$cmark" 2>/dev/null || true
    return 0
  fi
  # Resolve personUid for the local path; unresolvable => keep pending.
  puid="$(wm_resolve_person "$base" "$token" "$slug" "$uid")" || puid=""
  if [ -z "$puid" ]; then
    wm_spool "$(wm_spool_build copy-pending "$sid" "$slug" "$uid" "$project" "" "$category" "$intent" "$harness" reason person_unresolved)"
    return 0
  fi
  # Atomic, fail-closed redacted copy.
  n="$(wm_copy_transcript "$slug" "$puid" "$sid" "$tp")"; rc=$?
  if [ "$rc" -ne 0 ]; then
    wm_log "close: redaction FAILED (fail-closed) sid=$sid slug=$slug — pending, no copy"
    wm_spool "$(wm_spool_build copy-error "$sid" "$slug" "$uid" "$project" "" "$category" "$intent" "$harness" reason redaction_failed)"
    return 0
  fi
  wm_log "close: transcript copied sid=$sid slug=$slug redactions=${n:-0}"
  wm_spool "$(wm_spool_build copied "$sid" "$slug" "$uid" "$project" "" "$category" "$intent" "$harness" redactionCount "${n:-0}")"
  : > "$cmark" 2>/dev/null || true
  return 0
}

# ===========================================================================
# __close_bg__ — reconcile + copy every registered company for one session.
# ===========================================================================
wmc_close_bg() {
  local root="${WM_ROOT:-$HQ_ROOT}" sid="${WM_SID:-}" hint="${WM_HINT:-}"
  local harness="${WM_HARNESS:-claude-code}" project="${WM_PROJECT:-}"
  local category="${WM_CATEGORY:-adhoc}" intent="${WM_INTENT:-}" summary="${WM_SUMMARY:-}"
  [ -n "$sid" ] || return 0
  wm_safe_path_component "$sid" || { wm_log "close: unsafe session path component refused"; return 0; }

  local slugs n_slugs ismulti tp slug
  slugs="$(wm_registered_slugs "$sid")"
  [ -n "$slugs" ] || { wm_log "close: sid=$sid has no registered company — nothing to reconcile"; return 0; }
  n_slugs="$(printf '%s\n' "$slugs" | grep -c . )"
  if [ "$n_slugs" -gt 1 ] 2>/dev/null; then ismulti=1; else ismulti=0; fi
  tp="$(wm_find_transcript "$sid" "$hint")"
  [ -n "$summary" ] || summary="work session $sid reconciled"

  printf '%s\n' "$slugs" | while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    wm_safe_path_component "$slug" || { wm_log "close: unsafe company path component refused"; continue; }
    # Idempotent: a reconciled+copied (terminal) record is a no-op.
    if [ -f "$(wm_reconciled_marker "$sid" "$slug")" ] && [ -f "$(wm_copied_marker "$sid" "$slug")" ]; then
      continue
    fi
    wmc_reconcile_and_copy_one "$root" "$sid" "$slug" "$tp" "$ismulti" \
      "$harness" "$project" "$category" "$intent" "$summary" || true
  done
  return 0
}

# ===========================================================================
# __sweep_bg__ — late-reconcile spooled sessions no longer active.
# ===========================================================================
wmc_sweep_bg() {
  local root="${WM_ROOT:-$HQ_ROOT}"
  local spf cur now thresh sids sid slugs slug tp mtime age ismulti n_slugs claim
  spf="$(wm_spool_file)"
  [ -f "$spf" ] || return 0
  cur=""
  [ -f "$root/workspace/sessions/.current" ] && cur="$(cat "$root/workspace/sessions/.current" 2>/dev/null | tr -d '[:space:]')"
  now="$(date +%s 2>/dev/null || echo 0)"
  thresh="$(wm_active_threshold)"

  sids="$(jq -r 'select(.event=="attempt" or .event=="posted") | .sessionId // empty' "$spf" 2>/dev/null | grep -v '^$' | sort -u)"
  [ -n "$sids" ] || return 0

  printf '%s\n' "$sids" | while IFS= read -r sid; do
    [ -n "$sid" ] || continue
    wm_safe_path_component "$sid" || { wm_log "sweep: unsafe session path component refused"; continue; }
    [ "$sid" = "$cur" ] && continue   # never sweep the live session

    slugs="$(wm_registered_slugs "$sid")"
    [ -n "$slugs" ] || continue
    n_slugs="$(printf '%s\n' "$slugs" | grep -c . )"
    if [ "$n_slugs" -gt 1 ] 2>/dev/null; then ismulti=1; else ismulti=0; fi

    # Conservative activity heuristic: a fresh transcript mtime => possibly a
    # concurrent live session; leave it for its own close hook.
    tp="$(wm_find_transcript "$sid" "")"
    if [ -n "$tp" ] && [ -f "$tp" ]; then
      mtime="$(wm_file_mtime "$tp")"
      if [ -n "$mtime" ]; then
        age=$(( now - mtime ))
        [ "$age" -ge 0 ] 2>/dev/null && [ "$age" -lt "$thresh" ] 2>/dev/null && continue
      fi
    fi

    printf '%s\n' "$slugs" | while IFS= read -r slug; do
      [ -n "$slug" ] || continue
      wm_safe_path_component "$slug" || { wm_log "sweep: unsafe company path component refused"; continue; }
      # Already terminal (reconciled + copied) => no-op.
      if [ -f "$(wm_reconciled_marker "$sid" "$slug")" ] && [ -f "$(wm_copied_marker "$sid" "$slug")" ]; then
        continue
      fi
      # Atomic claim so concurrent sweeps do exactly one reconcile/copy. A stale
      # claim orphaned by a killed sweep is reclaimed (crash recovery, AC6) so a
      # single mid-sweep crash cannot wedge this (sid, slug) forever.
      if ! wm_sweep_try_claim "$sid" "$slug"; then
        continue   # a LIVE sweep owns this (sid, slug)
      fi
      claim="$(wm_sweep_claim "$sid" "$slug")"
      wmc_reconcile_and_copy_one "$root" "$sid" "$slug" "$tp" "$ismulti" \
        "claude-code" "$(wmc_meta_get "$root" "$sid" project)" "adhoc" "" \
        "work session $sid reconciled (sweep)" || true
      rmdir "$claim" 2>/dev/null || true
    done
  done
  return 0
}

# ===========================================================================
# Foreground close — resolve, spool an attempt, spawn the detached bg, return.
# ===========================================================================
wmc_close_foreground() {
  local input sid hint slugs harness project category intent summary self logf

  input="$(cat 2>/dev/null || printf '{}')"
  sid="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || printf '')"
  hint="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || printf '')"

  # Handoff path has no hook stdin -> fall back to the current session pointer.
  if [ -z "$sid" ] && [ -f "$HQ_ROOT/workspace/sessions/.current" ]; then
    sid="$(cat "$HQ_ROOT/workspace/sessions/.current" 2>/dev/null | tr -d '[:space:]')"
  fi
  [ -n "$sid" ] || return 0
  wm_safe_path_component "$sid" || { wm_log "close: unsafe session path component refused"; return 0; }

  # Only sessions that actually registered as work sessions get reconciled.
  slugs="$(wm_registered_slugs "$sid")"
  [ -n "$slugs" ] || return 0

  project="${HQ_WORK_MESH_PROJECT_ID:-$(wmc_meta_get "$HQ_ROOT" "$sid" project)}"
  category="${HQ_WORK_MESH_CATEGORY:-adhoc}"
  intent="${HQ_WORK_MESH_INTENT_SUMMARY:-}"
  harness="${HQ_WORK_MESH_HARNESS:-claude-code}"
  summary="${HQ_WORK_MESH_SUMMARY:-}"

  wm_spool "$(wm_spool_build close-attempt "$sid" "$(printf '%s\n' "$slugs" | head -n1)" "" "$project" "" "$category" "$intent" "$harness" '' '')"

  self="$(wmc_self)"
  logf="$(wm_log_file)"
  mkdir -p "$(dirname "$logf")" 2>/dev/null || true

  # HQ_ROOT is already exported (bootstrap), so it is inherited by the child;
  # only the WM_* context needs to be passed explicitly on the exec line.
  WM_ROOT="$HQ_ROOT" WM_SID="$sid" WM_HINT="$hint" \
  WM_HARNESS="$harness" WM_PROJECT="$project" WM_CATEGORY="$category" \
  WM_INTENT="$intent" WM_SUMMARY="$summary" \
    nohup bash "$self" __close_bg__ >>"$logf" 2>&1 </dev/null &
  disown 2>/dev/null || true
  return 0
}

# ===========================================================================
# Foreground sweep — spawn the detached bg sweep and return.
# ===========================================================================
wmc_sweep_foreground() {
  # Drain any hook stdin so the master-hook command-substitution returns.
  cat >/dev/null 2>&1 || true
  local self logf
  self="$(wmc_self)"
  logf="$(wm_log_file)"
  mkdir -p "$(dirname "$logf")" 2>/dev/null || true
  # HQ_ROOT is already exported (bootstrap) and inherited by the child.
  WM_ROOT="$HQ_ROOT" \
    nohup bash "$self" __sweep_bg__ >>"$logf" 2>&1 </dev/null &
  disown 2>/dev/null || true
  return 0
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "${1:-}" in
  __close_bg__) wmc_close_bg     || true; exit 0 ;;
  __sweep_bg__) wmc_sweep_bg     || true; exit 0 ;;
  sweep)        wmc_sweep_foreground || true; exit 0 ;;
  *)            wmc_close_foreground || true; exit 0 ;;
esac
