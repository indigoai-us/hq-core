#!/usr/bin/env bash
# hq-core: public
# work-mesh-register.sh — client-side, fire-and-forget Work Mesh registration.
#
# Fires on every SessionStart / UserPromptSubmit (via the thin shims in
# core/hooks/{SessionStart,UserPromptSubmit}/) AND is spawned directly by
# core/scripts/hq-session.sh when a session binds/rebinds company_slug. There is
# no discrete "company changed" event — master-hook re-resolves per event and
# this hook self-dedupes with a per-(session,company) marker.
#
# Contract (US-003):
#   * Fully silent on stdout — master-hook captures stdout, so ANY output would
#     leak into the transcript. All diagnostics go to the bounded hook log.
#   * The foreground path does NO blocking network call: it resolves the
#     company, writes the dedupe marker + a spool "attempt" line, then spawns a
#     detached background job (redirected off the captured stdout pipe so the
#     master-hook command-substitution returns immediately) and exits <1s.
#   * Mesh outage / missing-or-expired token / timeout = locally-logged no-op.
#     The session is NEVER blocked or slowed.
#
# bash-3.2 compatible. Always exits 0 (fail-soft).

set -uo pipefail

# --- bootstrap: locate HQ root + shared lib (honor HQ_ROOT for sandboxed tests)
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
HQ_ROOT_BOOT="${HQ_ROOT:-$(cd "$HOOK_DIR/../.." 2>/dev/null && pwd)}"
[ -n "$HQ_ROOT_BOOT" ] || exit 0
export HQ_ROOT="$HQ_ROOT_BOOT"
LIB="$HQ_ROOT_BOOT/core/scripts/work-mesh-lib.sh"
[ -f "$LIB" ] || exit 0
# shellcheck source=core/scripts/work-mesh-lib.sh
. "$LIB" 2>/dev/null || exit 0

# jq is mandatory for structured JSON; without it we cannot safely do anything.
command -v jq >/dev/null 2>&1 || exit 0

# Global kill switches (mirror work-mesh.mjs + hook disable convention).
case "${HQ_WORK_MESH_DISABLED:-}" in
  1|true|TRUE|yes|YES|on|ON) exit 0 ;;
esac
case ",${HQ_DISABLED_HOOKS:-}," in
  *,work-mesh-register,*) exit 0 ;;
esac

# ---------------------------------------------------------------------------
# meta.yaml reader (same idiom as hq-session.sh get)
# ---------------------------------------------------------------------------
wm_meta_get() {
  local root="$1" sid="$2" key="$3" meta
  meta="$root/workspace/sessions/$sid/meta.yaml"
  [ -f "$meta" ] || return 0
  awk -v k="$key" '$1==k":"{ sub(/^[^:]+:[[:space:]]*/,""); gsub(/^"|"$/,""); print; exit }' "$meta" 2>/dev/null
}

# ---------------------------------------------------------------------------
# cwd -> company slug inference. meta.yaml company_slug takes precedence and is
# resolved by the caller; this is only consulted when meta has no company.
#   1. cwd under {root}/companies/<slug>/...  -> <slug>
#   2. cwd under {root}/repos/... matched against companies/manifest.yaml
# Ambiguous / unparseable -> print nothing (silent no-op).
# ---------------------------------------------------------------------------
wm_infer_slug_from_cwd() {
  local root="$1" cwd="$2" rel slug manifest
  [ -n "$cwd" ] || return 0
  case "$cwd" in
    "$root"/*) rel="${cwd#"$root"/}" ;;
    "$root")   return 0 ;;
    *)         return 0 ;;
  esac

  case "$rel" in
    companies/*)
      slug="${rel#companies/}"
      slug="${slug%%/*}"
      case "$slug" in
        ""|.|..) return 0 ;;
        *) printf '%s' "$slug"; return 0 ;;
      esac
      ;;
  esac

  case "$rel" in
    repos/*)
      manifest="$root/companies/manifest.yaml"
      [ -f "$manifest" ] || return 0
      # Map the manifest's per-company repo entries to whichever one the cwd
      # falls under. Company keys are 2-space-indented "  <slug>:"; repo entries
      # are list items "    - repos/...". First match wins (best-effort).
      awk -v rel="$rel" '
        /^  [A-Za-z0-9_-]+:[ \t]*$/ { co=$1; sub(/:$/,"",co); next }
        /^[ \t]*-[ \t]+repos\// {
          r=$0; sub(/^[ \t]*-[ \t]+/,"",r); sub(/[ \t]+$/,"",r);
          if (r != "" && (rel == r || index(rel, r "/") == 1)) { print co; exit }
        }
      ' "$manifest" 2>/dev/null
      return 0
      ;;
  esac
  return 0
}

# ===========================================================================
# Background phase — spawned detached by the foreground. Reads WM_* from env.
# Does the actual token read, uid/gates resolution, and the bounded POST.
# ===========================================================================
wm_run_background() {
  local root="${WM_ROOT:-$HQ_ROOT}"
  local sid="${WM_SID:-}"
  local slug="${WM_SLUG:-}"
  local uid="${WM_UID:-}"
  local project="${WM_PROJECT:-}"
  local binding="${WM_BINDING:-adhoc}"
  local category="${WM_CATEGORY:-adhoc}"
  local intent="${WM_INTENT:-}"
  local harness="${WM_HARNESS:-claude-code}"

  local base token body enabled payload code
  base="$(wm_api_base)"

  if ! token="$(wm_read_token)" || [ -z "$token" ]; then
    wm_log "no-op: no valid Cognito token (missing/expired) for slug=$slug"
    wm_spool "$(wm_spool_build skipped "$sid" "$slug" "$uid" "$project" "$binding" "$category" "$intent" "$harness" reason no_token)"
    return 0
  fi

  if [ -z "$uid" ]; then
    uid="$(wm_resolve_uid "$base" "$token" "$slug")" || uid=""
  fi
  if [ -z "$uid" ]; then
    wm_log "no-op: could not resolve companyUid for slug=$slug"
    wm_spool "$(wm_spool_build skipped "$sid" "$slug" "$uid" "$project" "$binding" "$category" "$intent" "$harness" reason no_uid)"
    return 0
  fi

  # Refresh gates cache (also warms the foreground short-circuit). Advisory: if
  # explicitly disabled, skip the POST; if unreachable, proceed (server wins).
  body="$(wm_gates_refresh "$base" "$token" "$uid")" || body=""
  if [ -n "$body" ]; then
    # NB: do NOT use `.workRegistryEnabled // empty` — jq's `//` treats a boolean
    # `false` as empty, so an explicit false would read as "" and never skip.
    enabled="$(printf '%s' "$body" | jq -r '.workRegistryEnabled' 2>/dev/null || echo '')"
    if [ "$enabled" = "false" ]; then
      wm_log "skip: workRegistryEnabled=false for uid=$uid (slug=$slug)"
      wm_spool "$(wm_spool_build skipped "$sid" "$slug" "$uid" "$project" "$binding" "$category" "$intent" "$harness" reason registry_disabled)"
      return 0
    fi
  fi

  payload="$(wm_payload "$uid" "$sid" "$harness" "$binding" "$project" "$category" "$intent")"
  if [ -z "$payload" ]; then
    wm_log "no-op: failed to build payload for uid=$uid (slug=$slug)"
    return 0
  fi

  code="$(wm_http_post "$base" "$token" "/v1/work-mesh/work-sessions" "$payload")" || code="000"
  case "$code" in
    200|201)
      wm_log "registered work-session uid=$uid slug=$slug (HTTP $code)"
      wm_spool "$(wm_spool_build posted "$sid" "$slug" "$uid" "$project" "$binding" "$category" "$intent" "$harness" httpStatus "$code")"
      ;;
    403)
      wm_log "server declined uid=$uid slug=$slug (HTTP 403 — registry disabled or cross-tenant)"
      wm_spool "$(wm_spool_build declined "$sid" "$slug" "$uid" "$project" "$binding" "$category" "$intent" "$harness" httpStatus "$code")"
      ;;
    *)
      wm_log "post failed uid=$uid slug=$slug (HTTP $code) — locally-logged no-op, US-004 sweep backfills"
      wm_spool "$(wm_spool_build error "$sid" "$slug" "$uid" "$project" "$binding" "$category" "$intent" "$harness" httpStatus "$code")"
      ;;
  esac
  return 0
}

# ===========================================================================
# Foreground phase — fast, no blocking network. Resolves, dedupes, spools the
# attempt, spawns the background job, and returns.
# ===========================================================================
wm_run_foreground() {
  local input sid cwd slug marker uid project binding category intent harness self logf

  input="$(cat 2>/dev/null || printf '{}')"
  sid="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || printf '')"
  cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || printf '')"

  # Without a session id we cannot maintain the per-(session,company) marker.
  [ -n "$sid" ] || return 0
  # Hook input is external to this script. Reject unsafe identifiers before
  # using the session id to read metadata or construct a marker path.
  if ! wm_safe_path_component "$sid"; then
    wm_log "no-op: unsafe session path component refused"
    return 0
  fi

  # Resolve company: meta.yaml company_slug wins; else cwd inference.
  slug="$(wm_meta_get "$HQ_ROOT" "$sid" company_slug)"
  [ -n "$slug" ] || slug="$(wm_infer_slug_from_cwd "$HQ_ROOT" "$cwd")"
  [ -n "$slug" ] || return 0
  if ! wm_safe_path_component "$slug"; then
    wm_log "no-op: unsafe company path component refused"
    return 0
  fi

  # One registration per (session, company): marker short-circuits re-posts.
  marker="$HQ_ROOT/workspace/sessions/$sid/work-mesh-registered-$(wm_keyfrag "$slug")"
  [ -f "$marker" ] && return 0

  # Advisory foreground short-circuit: if we already know (fresh cache) this
  # company's registry is disabled, skip fully — no marker, no spool, no spawn,
  # zero network. Self-heals when the cache TTL lapses.
  uid="$(wm_uid_cached "$slug")" || uid=""
  if [ -n "$uid" ] && wm_gates_cached_disabled "$uid"; then
    wm_log "skip: workRegistryEnabled=false (cached) for slug=$slug"
    return 0
  fi

  # Classification inputs (agent-suppliable via env; deterministic defaults).
  project="${HQ_WORK_MESH_PROJECT_ID:-}"
  [ -n "$project" ] || project="$(wm_meta_get "$HQ_ROOT" "$sid" project)"
  if [ -n "$project" ]; then binding="project"; else binding="adhoc"; fi

  category="${HQ_WORK_MESH_CATEGORY:-}"
  [ -n "$category" ] || category="adhoc"

  intent="${HQ_WORK_MESH_INTENT_SUMMARY:-}"
  [ -n "$intent" ] || intent="session bound to $slug"
  intent="${intent:0:280}"

  harness="${HQ_WORK_MESH_HARNESS:-claude-code}"

  # Write the marker at ATTEMPT time (before the network) so a mesh outage does
  # not cause a per-prompt retry storm; the spool + US-004 sweep cover backfill.
  mkdir -p "$(dirname "$marker")" 2>/dev/null || true
  : > "$marker" 2>/dev/null || true

  # Spool the attempt BEFORE the network attempt (exists even if API is down).
  wm_spool "$(wm_spool_build attempt "$sid" "$slug" "$uid" "$project" "$binding" "$category" "$intent" "$harness" '' '')"

  # Resolve an absolute path to self for the detached re-exec.
  self="${BASH_SOURCE[0]}"
  case "$self" in
    /*) : ;;
    *)  self="$(cd "$(dirname "$self")" 2>/dev/null && pwd)/$(basename "$self")" ;;
  esac

  logf="$(wm_log_file)"
  mkdir -p "$(dirname "$logf")" 2>/dev/null || true

  # Detach the background job. Redirect stdout+stderr to the log and stdin from
  # /dev/null so it does NOT hold master-hook's captured stdout pipe — that lets
  # the parent command-substitution return immediately.
  HQ_ROOT="$HQ_ROOT" \
  WM_ROOT="$HQ_ROOT" WM_SID="$sid" WM_SLUG="$slug" WM_UID="$uid" \
  WM_PROJECT="$project" WM_BINDING="$binding" WM_CATEGORY="$category" \
  WM_INTENT="$intent" WM_HARNESS="$harness" \
    nohup bash "$self" __bg__ >>"$logf" 2>&1 </dev/null &
  disown 2>/dev/null || true

  return 0
}

# ---------------------------------------------------------------------------
# Dispatch: __bg__ -> background phase; anything else (event name) -> foreground
# ---------------------------------------------------------------------------
if [ "${1:-}" = "__bg__" ]; then
  wm_run_background || true
  exit 0
fi

wm_run_foreground || true
exit 0
