#!/usr/bin/env bash
# hq-core: public
# work-mesh-lib.sh — shared bash helpers for the client-side Work Mesh hooks.
#
# SOURCED, not executed. Callers: core/hooks/work-mesh-register.sh (US-003) and
# US-004's session-close hook. Every function is fail-soft: on any error it logs
# (bounded) and returns non-zero / empty rather than aborting the session. This
# file deliberately does NOT enable `set -e` — it must not change the errexit
# state of the shell that sources it. bash-3.2 compatible (macOS system bash):
# no associative arrays, no ${var,,}, no mapfile.
#
# All JSON (payloads, spool lines, structured log lines) is built with
# `jq -nc --arg` per policy hq-hook-json-build-with-jq-not-unquoted-heredoc.
# The bearer token is NEVER written to the log or spool.
#
# Environment overrides (also the test seams):
#   HQ_ROOT                     HQ root dir (default: script-relative ../..)
#   HQ_WORK_MESH_API_URL        API base (chain: →HQ_VAULT_API_URL →HQ_API_URL
#   HQ_VAULT_API_URL            →HQ_PRO_API_URL → public HQ API)
#   HQ_API_URL
#   HQ_PRO_API_URL
#   HQ_WORK_MESH_TOKEN          Bearer token; skips the token-file read
#   HQ_COGNITO_TOKENS_FILE      Token file path (default ~/.hq/cognito-tokens.json)
#   HQ_WORK_MESH_COMPANY_UID    Explicit companyUid; skips /membership/me
#   HQ_COMPANY_UID              Fallback explicit companyUid
#   HQ_WORK_MESH_GATES_TTL      Gate/uid cache TTL seconds (default 300)
#   HQ_WORK_MESH_CURL_TIMEOUT   curl --max-time seconds (default 4)
#   HQ_WORK_MESH_LOG_MAX_BYTES  Hook-log rotate cap (default 204800 = ~200KB)

# ---------------------------------------------------------------------------
# Root / path resolution
# ---------------------------------------------------------------------------
wm_hq_root() {
  if [ -n "${HQ_ROOT:-}" ]; then
    printf '%s' "$HQ_ROOT"
    return 0
  fi
  # This file lives in core/scripts/, so ../.. is the HQ root.
  local d
  d="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || return 1
  printf '%s' "$d"
}

wm_log_file()  { printf '%s/workspace/logs/work-mesh-hook.log' "$(wm_hq_root)"; }
wm_spool_file() { printf '%s/workspace/metrics/work-sessions.jsonl' "$(wm_hq_root)"; }
wm_cache_dir()  { printf '%s/workspace/work-mesh/cache' "$(wm_hq_root)"; }

wm_gates_ttl()     { printf '%s' "${HQ_WORK_MESH_GATES_TTL:-300}"; }
wm_curl_timeout()  { printf '%s' "${HQ_WORK_MESH_CURL_TIMEOUT:-4}"; }

# Path components derived from hook input, local metadata, or API responses must
# never be allowed to escape the transcript staging tree. Keep this deliberately
# stricter than wm_keyfrag(): callers writing files must reject, not rewrite,
# unexpected identifiers so two distinct server values cannot alias one path.
wm_safe_path_component() {
  local value="${1:-}"
  [ -n "$value" ] || return 1
  LC_ALL=C printf '%s\n' "$value" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'
}

# ---------------------------------------------------------------------------
# Bounded, size-capped structured logging (never contains token contents)
# ---------------------------------------------------------------------------
wm_log() {
  local msg="${1:-}"
  local logf ts line
  logf="$(wm_log_file)" || return 0
  mkdir -p "$(dirname "$logf")" 2>/dev/null || return 0
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
  line="$(jq -nc --arg ts "$ts" --arg msg "$msg" '{ts:$ts,msg:$msg}' 2>/dev/null)" || line=""
  [ -n "$line" ] || return 0
  printf '%s\n' "$line" >> "$logf" 2>/dev/null || true
  wm_log_rotate "$logf"
}

wm_log_rotate() {
  local logf="${1:-}"
  local cap size tmp keep
  cap="${HQ_WORK_MESH_LOG_MAX_BYTES:-204800}"
  [ -f "$logf" ] || return 0
  size="$(wc -c < "$logf" 2>/dev/null | tr -d '[:space:]')" || return 0
  [ -n "$size" ] || return 0
  if [ "$size" -gt "$cap" ] 2>/dev/null; then
    keep="$(( cap / 2 ))"
    tmp="$(mktemp 2>/dev/null)" || return 0
    # Keep the tail; may clip one partial leading line — acceptable for a log.
    if tail -c "$keep" "$logf" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$logf" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    else
      rm -f "$tmp" 2>/dev/null || true
    fi
  fi
}

# ---------------------------------------------------------------------------
# Spool append (single-line JSON) — audit-log.sh idiom: mkdir -p, jq -nc, >>
# ---------------------------------------------------------------------------
# Usage: wm_spool <json-line-string>
wm_spool() {
  local line="${1:-}"
  local spf
  [ -n "$line" ] || return 0
  spf="$(wm_spool_file)" || return 0
  mkdir -p "$(dirname "$spf")" 2>/dev/null || return 0
  printf '%s\n' "$line" >> "$spf" 2>/dev/null || true
}

# Build a spool line. All fields via jq --arg. Empty-valued keys are dropped so
# the schema stays lean and US-004's sweep can rely on presence.
# Usage: wm_spool_line <event> <sessionId> <slug> <companyUid> <projectId> \
#                      <binding> <category> <intentSummary> <harness> <extraKey> <extraVal>
wm_spool_build() {
  jq -nc \
    --arg ts       "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')" \
    --arg event    "${1:-}" \
    --arg session  "${2:-}" \
    --arg slug     "${3:-}" \
    --arg uid      "${4:-}" \
    --arg project  "${5:-}" \
    --arg binding  "${6:-}" \
    --arg category "${7:-}" \
    --arg intent   "${8:-}" \
    --arg harness  "${9:-}" \
    --arg ekey     "${10:-}" \
    --arg eval     "${11:-}" \
    '{
       ts: $ts,
       event: $event,
       sessionId: $session,
       companySlug: $slug,
       companyUid: $uid,
       projectId: $project,
       binding: $binding,
       category: $category,
       intentSummary: $intent,
       harness: $harness
     }
     + (if $ekey != "" then {($ekey): $eval} else {} end)
     | with_entries(select(.value != null and .value != ""))' 2>/dev/null
}

# ---------------------------------------------------------------------------
# API base + auth token
# ---------------------------------------------------------------------------
wm_api_base() {
  local base
  base="${HQ_WORK_MESH_API_URL:-${HQ_VAULT_API_URL:-${HQ_API_URL:-${HQ_PRO_API_URL:-https://hqapi.hq.computer}}}}"
  # strip trailing slashes
  while [ "${base%/}" != "$base" ]; do base="${base%/}"; done
  printf '%s' "$base"
}

# wm_base_is_secure <base> -> 0 (secure) iff the resolved base uses https, OR
# uses http to a loopback host (localhost / 127.0.0.1 / ::1) for local dev.
# ANY other scheme — notably plain http:// to a non-loopback host — is refused
# so the bearer token is NEVER transmitted in cleartext. Empty/malformed base
# is also refused. This is the TLS/scheme guard for wm_http_get/wm_http_post;
# a refusal makes the HTTP call a locally-logged no-op (never blocks the session).
wm_base_is_secure() {
  local base="${1:-}" scheme rest hostport host
  [ -n "$base" ] || return 1
  case "$base" in *://*) : ;; *) return 1 ;; esac
  scheme="${base%%://*}"
  scheme="$(printf '%s' "$scheme" | tr '[:upper:]' '[:lower:]')"
  case "$scheme" in
    https) return 0 ;;   # TLS everywhere else — always allowed
    http)  : ;;          # cleartext — allowed ONLY for a loopback host (below)
    *)     return 1 ;;   # any other scheme (ftp/file/…) — refused
  esac
  rest="${base#*://}"
  hostport="${rest%%/*}"    # strip path
  hostport="${hostport##*@}" # strip any userinfo (user:pass@host)
  case "$hostport" in
    \[*\]*)                  # bracketed IPv6, e.g. [::1]:9
      host="${hostport#\[}"
      host="${host%%\]*}"
      ;;
    *)
      host="${hostport%%:*}" # strip :port
      ;;
  esac
  host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
  case "$host" in
    localhost|127.0.0.1|::1) return 0 ;;
    *) return 1 ;;
  esac
}

# Read a usable bearer token, or print nothing (missing/expired = no-op).
# Prefers .idToken, falls back to .accessToken; validity via .expiresAt (epoch
# MILLISECONDS) > now. No refresh, no login. Never logs the token value.
wm_read_token() {
  if [ -n "${HQ_WORK_MESH_TOKEN:-}" ]; then
    printf '%s' "$HQ_WORK_MESH_TOKEN"
    return 0
  fi
  local tf now_ms tok exp
  tf="${HQ_COGNITO_TOKENS_FILE:-$HOME/.hq/cognito-tokens.json}"
  [ -f "$tf" ] || return 1
  now_ms=$(( $(date +%s 2>/dev/null || echo 0) * 1000 ))
  tok="$(jq -r '.idToken // .accessToken // empty' "$tf" 2>/dev/null)" || return 1
  exp="$(jq -r '.expiresAt // 0' "$tf" 2>/dev/null)" || return 1
  [ -n "$tok" ] || return 1
  # expiresAt is epoch-ms; require it strictly in the future.
  if [ "$exp" -gt "$now_ms" ] 2>/dev/null; then
    printf '%s' "$tok"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# TTL cache (mtime-based) — cross-platform stat
# ---------------------------------------------------------------------------
wm_file_mtime() {
  local f="${1:-}" value
  # GNU stat accepts `-f` too, but interprets it as filesystem mode and may
  # return text for `%m`. Accept a probe only when it is strictly numeric before
  # falling through to the other platform form.
  value="$(stat -f %m "$f" 2>/dev/null)" || value=""
  case "$value" in
    ''|*[!0-9]*) ;;
    *) printf '%s' "$value"; return 0 ;;
  esac
  value="$(stat -c %Y "$f" 2>/dev/null)" || value=""
  case "$value" in
    ''|*[!0-9]*) return 1 ;;
    *) printf '%s' "$value"; return 0 ;;
  esac
}

# wm_cache_fresh <file> [ttl] -> 0 if the file exists and is younger than ttl
wm_cache_fresh() {
  local f="${1:-}" ttl="${2:-$(wm_gates_ttl)}" mtime now age
  [ -f "$f" ] || return 1
  mtime="$(wm_file_mtime "$f")" || return 1
  [ -n "$mtime" ] || return 1
  now="$(date +%s 2>/dev/null || echo 0)"
  age=$(( now - mtime ))
  [ "$age" -ge 0 ] 2>/dev/null && [ "$age" -lt "$ttl" ] 2>/dev/null
}

# sanitize an arbitrary key into a safe cache filename fragment
wm_keyfrag() {
  printf '%s' "${1:-}" | tr -c 'A-Za-z0-9._-' '_'
}

# ---------------------------------------------------------------------------
# HTTP (curl) — bounded, fail-soft. Prints body to stdout; returns curl status.
# ---------------------------------------------------------------------------
# wm_http_get <base> <token> <path> -> body on stdout (empty on failure)
# The bearer token is fed to curl via stdin (-H @-) so it never appears in the
# process argument list (ps / /proc/<pid>/cmdline). Header-from-stdin degrades
# fail-soft: on a curl too old to support it the request 401s and the caller
# no-ops, same as any other auth failure.
wm_http_get() {
  local base="${1:-}" token="${2:-}" path="${3:-}"
  [ -n "$base" ] && [ -n "$token" ] || return 1
  # TLS guard: never send the bearer token over a cleartext (non-loopback http)
  # base. Refusal = locally-logged no-op (no curl), never a session block.
  if ! wm_base_is_secure "$base"; then
    wm_log "no-op: refusing insecure API base scheme (non-https, non-loopback) — token withheld"
    return 1
  fi
  printf 'Authorization: Bearer %s\n' "$token" \
    | curl -sS -m "$(wm_curl_timeout)" \
        -H @- \
        "$base$path" 2>/dev/null
}

# wm_http_post <base> <token> <path> <json-body> -> prints the numeric HTTP code
# on stdout (or "000" on transport failure). Response body is discarded (the
# server contract's threadId/similarInFlight aren't needed by the fire-and-forget
# client; the server is authoritative and idempotent).
wm_http_post() {
  local base="${1:-}" token="${2:-}" path="${3:-}" body="${4:-}"
  local code
  [ -n "$base" ] && [ -n "$token" ] || { printf '000'; return 1; }
  # TLS guard: never POST the bearer token over a cleartext (non-loopback http)
  # base. Refusal = locally-logged no-op (no curl), never a session block; the
  # "000" transport-failure code lets the caller's existing sweep backfill.
  if ! wm_base_is_secure "$base"; then
    wm_log "no-op: refusing insecure API base scheme (non-https, non-loopback) — token withheld"
    printf '000'; return 1
  fi
  # Bearer token via stdin (-H @-) to keep it out of argv; --data-binary stays
  # on argv (body is not a secret) and does not consume stdin.
  code="$(printf 'Authorization: Bearer %s\n' "$token" \
    | curl -sS -m "$(wm_curl_timeout)" -o /dev/null -w '%{http_code}' \
        -X POST \
        -H @- \
        -H "Content-Type: application/json" \
        --data-binary "$body" \
        "$base$path" 2>/dev/null)" || { printf '000'; return 1; }
  [ -n "$code" ] || code="000"
  printf '%s' "$code"
}

# ---------------------------------------------------------------------------
# slug -> companyUid resolution (cached; mirrors work-mesh.mjs resolveCompany)
# ---------------------------------------------------------------------------
# wm_uid_cached <slug> -> cached/explicit companyUid WITHOUT any network call.
wm_uid_cached() {
  local slug="${1:-}"
  [ -n "$slug" ] || return 1
  if [ -n "${HQ_WORK_MESH_COMPANY_UID:-${HQ_COMPANY_UID:-}}" ]; then
    printf '%s' "${HQ_WORK_MESH_COMPANY_UID:-$HQ_COMPANY_UID}"
    return 0
  fi
  case "$slug" in
    cmp_*|co_*) printf '%s' "$slug"; return 0 ;;
  esac
  local cf
  cf="$(wm_cache_dir)/uid-$(wm_keyfrag "$slug")"
  if wm_cache_fresh "$cf"; then
    cat "$cf" 2>/dev/null
    return 0
  fi
  return 1
}

# wm_resolve_uid <base> <token> <slug> -> companyUid (cache first, then network).
wm_resolve_uid() {
  local base="${1:-}" token="${2:-}" slug="${3:-}"
  local cached uid body cf wantlc
  cached="$(wm_uid_cached "$slug")" && [ -n "$cached" ] && { printf '%s' "$cached"; return 0; }
  [ -n "$base" ] && [ -n "$token" ] && [ -n "$slug" ] || return 1
  body="$(wm_http_get "$base" "$token" "/membership/me")" || return 1
  [ -n "$body" ] || return 1
  wantlc="$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')"
  uid="$(printf '%s' "$body" | jq -r --arg want "$wantlc" '
    (.memberships // [])
    | map(select(
        ((.companyUid  // "") | ascii_downcase) == $want or
        ((.companySlug // "") | ascii_downcase) == $want or
        ((.slug        // "") | ascii_downcase) == $want or
        ((.companyName // "") | ascii_downcase) == $want or
        ((.name        // "") | ascii_downcase) == $want
      ))
    | (.[0].companyUid // empty)
  ' 2>/dev/null)" || return 1
  [ -n "$uid" ] || return 1
  cf="$(wm_cache_dir)/uid-$(wm_keyfrag "$slug")"
  mkdir -p "$(dirname "$cf")" 2>/dev/null || true
  printf '%s' "$uid" > "$cf" 2>/dev/null || true
  printf '%s' "$uid"
}

# ---------------------------------------------------------------------------
# Consent gates (workRegistryEnabled) — cached; advisory only
# ---------------------------------------------------------------------------
# wm_gates_cached_disabled <companyUid> -> 0 ONLY if a FRESH cached gates entry
# explicitly says workRegistryEnabled=false. No network. Used by the foreground
# to skip a known-disabled company with zero per-prompt network cost.
wm_gates_cached_disabled() {
  local uid="${1:-}" cf val
  [ -n "$uid" ] || return 1
  cf="$(wm_cache_dir)/gates-$(wm_keyfrag "$uid")"
  wm_cache_fresh "$cf" || return 1
  # NB: no `// empty` — jq's `//` treats a boolean `false` as empty, which would
  # make an explicitly-disabled company read as "" and never short-circuit.
  val="$(jq -r '.workRegistryEnabled' "$cf" 2>/dev/null)" || return 1
  [ "$val" = "false" ]
}

# wm_gates_refresh <base> <token> <companyUid> -> fetches gates, writes cache,
# prints the raw gates JSON on stdout (empty on failure).
wm_gates_refresh() {
  local base="${1:-}" token="${2:-}" uid="${3:-}" body cf
  [ -n "$base" ] && [ -n "$token" ] && [ -n "$uid" ] || return 1
  body="$(wm_http_get "$base" "$token" "/v1/consent/gates?companyUid=$(wm_urlencode "$uid")")" || return 1
  [ -n "$body" ] || return 1
  # only cache a well-formed object
  printf '%s' "$body" | jq -e 'type == "object"' >/dev/null 2>&1 || return 1
  cf="$(wm_cache_dir)/gates-$(wm_keyfrag "$uid")"
  mkdir -p "$(dirname "$cf")" 2>/dev/null || true
  printf '%s' "$body" > "$cf" 2>/dev/null || true
  printf '%s' "$body"
}

# Minimal URL-encoder for a company uid (safe chars only expected, but be strict).
wm_urlencode() {
  local s="${1:-}" out="" i c
  i=0
  while [ "$i" -lt "${#s}" ]; do
    c="${s:$i:1}"
    case "$c" in
      [a-zA-Z0-9._~-]) out="$out$c" ;;
      *) out="$out$(printf '%%%02X' "'$c")" ;;
    esac
    i=$(( i + 1 ))
  done
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Registration payload builder (server contract)
# ---------------------------------------------------------------------------
# wm_payload <companyUid> <sessionId> <harness> <binding> <projectId> <category> <intentSummary>
# binding == "project" -> projectId REQUIRED and included; MUST be absent for adhoc.
# NEVER includes personUid (JWT-resolved server-side; rejected if sent).
wm_payload() {
  local uid="${1:-}" session="${2:-}" harness="${3:-}" binding="${4:-}" \
        project="${5:-}" category="${6:-}" intent="${7:-}"
  jq -nc \
    --arg uid      "$uid" \
    --arg session  "$session" \
    --arg harness  "$harness" \
    --arg binding  "$binding" \
    --arg project  "$project" \
    --arg category "$category" \
    --arg intent   "$intent" \
    '{
       companyUid: $uid,
       sessionId: $session,
       harness: $harness,
       classification: (
         {
           binding: $binding,
           category: $category,
           intentSummary: $intent
         }
         + (if $binding == "project" then {projectId: $project} else {} end)
       )
     }' 2>/dev/null
}

# ===========================================================================
# US-004 — close-time reconcile + vetted transcript handoff + sweep
# ===========================================================================
# Everything below is SOURCED by core/hooks/work-mesh-close.sh (close hook +
# SessionStart sweep). Same fail-soft contract as above: on any error, log
# (bounded, never a secret) and return non-zero / empty; never abort the shell.
#
# SECURITY INVARIANTS (see US-004 story + §11/§12 of the server contract):
#   * A transcript copy is produced ONLY after a STRUCTURAL work-record gate
#     (a US-003 registration marker for the (session, company)) — fail-closed.
#   * The copy additionally requires BOTH the company transcriptCaptureEnabled
#     gate AND the person transcriptOptIn (double consent, §12.2). Gates
#     unreachable => DO NOT copy (fail closed) but keep pending for the sweep.
#   * Redaction is a FAIL-CLOSED gate: unredacted transcript bytes are NEVER
#     written anywhere under companies/. Redaction reads the ORIGINAL transcript
#     (outside companies/) and writes redacted bytes into a temp file inside the
#     gitignored sessions/ staging area, verifies success, then atomically mvs.
#   * Multi-company (>1 registered company for a session) => NO copy for ANY
#     company (v1 exclusion); each record flagged crossCompany.
#   * Only Claude Code sessions are copied in v1; other harnesses reconcile but
#     skip the copy and are flagged transcriptUnavailable (never a silent no-op).

# --- tunables / seams -------------------------------------------------------
# Bounded transcript size budget: oversized transcripts are skip-and-flagged,
# NEVER shipped unredacted or truncated-unredacted. Default 50 MiB.
wm_transcript_budget() { printf '%s' "${HQ_WORK_MESH_TRANSCRIPT_MAX_BYTES:-52428800}"; }
# A session whose transcript was modified within this many seconds is treated as
# possibly-active by the sweep and left alone (conservative activity heuristic).
wm_active_threshold()  { printf '%s' "${HQ_WORK_MESH_ACTIVE_THRESHOLD_SEC:-900}"; }
# A sweep claim (mkdir lock) whose dir mtime is older than this is presumed
# ORPHANED by a sweep that was killed mid-flight (between claim and release) and
# is reclaimable — otherwise a single crashed sweep would wedge that (session,
# company) forever, defeating the crash-proof guarantee. Default 900s: far longer
# than any legitimate sweep (bounded by a few curl --max-time cycles per company).
wm_sweep_claim_stale_sec() { printf '%s' "${HQ_WORK_MESH_CLAIM_STALE_SEC:-900}"; }
# Claude Code transcripts live here; overridable for hermetic tests.
wm_claude_projects_dir() { printf '%s' "${HQ_WORK_MESH_CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"; }

# --- per-(session,company) marker paths (mirror the US-003 registration marker)
wm_sessions_dir()  { printf '%s/workspace/sessions/%s' "$(wm_hq_root)" "${1:-}"; }
wm_reg_marker()    { printf '%s/work-mesh-registered-%s' "$(wm_sessions_dir "$1")" "$(wm_keyfrag "$2")"; }
wm_reconciled_marker() { printf '%s/work-mesh-reconciled-%s' "$(wm_sessions_dir "$1")" "$(wm_keyfrag "$2")"; }
wm_copied_marker() { printf '%s/work-mesh-copied-%s' "$(wm_sessions_dir "$1")" "$(wm_keyfrag "$2")"; }
wm_sweep_claim()   { printf '%s/work-mesh-sweep-claim-%s' "$(wm_sessions_dir "$1")" "$(wm_keyfrag "$2")"; }

# wm_sweep_try_claim <sessionId> <slug>
#   Atomically acquire the sweep claim for (session, company). Returns 0 iff the
#   claim is now held by THIS caller — either a fresh mkdir, OR a reclaim of a
#   STALE claim left behind by a sweep that was killed between claim and release
#   (crash recovery; AC6). Returns non-zero when a LIVE sweep already owns it
#   (fresh claim mtime). Reclaim is race-safe: the stale dir is atomically
#   renamed away (rename has a single winner) before being recreated, so at most
#   one concurrent caller ever proceeds. The caller releases with `rmdir` on the
#   claim path (from wm_sweep_claim) after its work — as before.
wm_sweep_try_claim() {
  local sid="${1:-}" slug="${2:-}" claim mt now age steal
  [ -n "$sid" ] && [ -n "$slug" ] || return 1
  claim="$(wm_sweep_claim "$sid" "$slug")"
  mkdir -p "$(dirname "$claim")" 2>/dev/null || true
  # Fast path: no claim yet -> we own it.
  if mkdir "$claim" 2>/dev/null; then
    return 0
  fi
  # A claim exists. Reclaim ONLY if it is stale (a live sweep's claim is fresh).
  [ -d "$claim" ] || return 1
  mt="$(wm_file_mtime "$claim")" || return 1
  [ -n "$mt" ] || return 1
  now="$(date +%s 2>/dev/null || echo 0)"
  age=$(( now - mt ))
  [ "$age" -ge 0 ] 2>/dev/null || return 1
  [ "$age" -ge "$(wm_sweep_claim_stale_sec)" ] 2>/dev/null || return 1
  # Atomic steal: exactly one concurrent stealer wins the rename of THIS dir.
  steal="$claim.stale.$$"
  rm -rf "$steal" 2>/dev/null || true
  if mv "$claim" "$steal" 2>/dev/null; then
    rm -rf "$steal" 2>/dev/null || true
    # Recreate under our ownership. If a fresh sweep grabbed the freed slot in
    # the gap, our mkdir fails and we back off (that sweep is the single owner).
    mkdir "$claim" 2>/dev/null && return 0
    return 1
  fi
  return 1
}

# Local staging root for a company's session transcripts (gitignored + qmd-ignored).
wm_stage_dir() { printf '%s/companies/%s/sessions' "$(wm_hq_root)" "${1:-}"; }

# --- transcript discovery ---------------------------------------------------
# wm_find_transcript <sessionId> [hint_path]
# Prefers a caller-supplied path (SessionEnd stdin transcript_path); else globs
# the harness-specific ~/.claude/projects/*/<sessionId>.jsonl. A candidate must
# be a regular, non-symlinked file with the exact session filename beneath the
# canonical projects directory; hook input can never select an arbitrary local
# file for staging. Empty if none.
wm_transcript_candidate_safe() {
  local sid="${1:-}" candidate="${2:-}" pd="${3:-}" parent pdreal
  wm_safe_path_component "$sid" || return 1
  [ -n "$candidate" ] && [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
  [ "$(basename "$candidate")" = "$sid.jsonl" ] || return 1
  [ -d "$pd" ] || return 1
  pdreal="$(cd "$pd" 2>/dev/null && pwd -P)" || return 1
  parent="$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P)" || return 1
  case "$parent" in
    "$pdreal"/*) return 0 ;;
    *) return 1 ;;
  esac
}

wm_find_transcript() {
  local sid="${1:-}" hint="${2:-}" pd f
  [ -n "$sid" ] || return 0
  pd="$(wm_claude_projects_dir)"
  [ -d "$pd" ] || return 0
  if wm_transcript_candidate_safe "$sid" "$hint" "$pd"; then
    printf '%s' "$hint"
    return 0
  fi
  for f in "$pd"/*/"$sid".jsonl; do
    if wm_transcript_candidate_safe "$sid" "$f" "$pd"; then
      printf '%s' "$f"
      return 0
    fi
  done
  return 0
}

# --- registered-company discovery (structural work-record proxy) ------------
# wm_registered_slugs <sessionId> -> distinct companySlug values this session
# registered under (a US-003 'attempt'/'posted' spool line exists). The spool is
# the authoritative local record; the registration marker is written alongside
# the attempt line by the US-003 foreground.
wm_registered_slugs() {
  local sid="${1:-}" spf
  [ -n "$sid" ] || return 0
  spf="$(wm_spool_file)"
  [ -f "$spf" ] || return 0
  jq -r --arg s "$sid" '
    select(.sessionId==$s and (.event=="attempt" or .event=="posted"))
    | .companySlug // empty' "$spf" 2>/dev/null | grep -v '^$' | sort -u
}

# wm_registered_uid <sessionId> <slug> -> the companyUid last recorded on a
# spool line for (sid, slug), or empty (bg resolves via /membership/me).
wm_registered_uid() {
  local sid="${1:-}" slug="${2:-}" spf
  [ -n "$sid" ] && [ -n "$slug" ] || return 0
  spf="$(wm_spool_file)"
  [ -f "$spf" ] || return 0
  jq -r --arg s "$sid" --arg c "$slug" '
    select(.sessionId==$s and .companySlug==$c and (.companyUid // "")!="")
    | .companyUid' "$spf" 2>/dev/null | tail -n1
}

# --- personUid resolution (for the local sessions/{personUid}/ path) --------
# personUid is server-authoritative for the vault write; the client needs it
# only to lay out the local staging path. Chain: explicit env -> cache ->
# /membership/me (matched on companyUid or companySlug). Never fabricated.
wm_person_cached() {
  local slug="${1:-}" cf
  if [ -n "${HQ_WORK_MESH_PERSON_UID:-}" ]; then printf '%s' "$HQ_WORK_MESH_PERSON_UID"; return 0; fi
  [ -n "$slug" ] || return 1
  cf="$(wm_cache_dir)/person-$(wm_keyfrag "$slug")"
  if wm_cache_fresh "$cf"; then cat "$cf" 2>/dev/null; return 0; fi
  return 1
}

# wm_resolve_person <base> <token> <slug> <uid> -> prs_* personUid (cache first).
wm_resolve_person() {
  local base="${1:-}" token="${2:-}" slug="${3:-}" uid="${4:-}"
  local cached body puid cf wantslug wantuid
  cached="$(wm_person_cached "$slug")" && [ -n "$cached" ] && { printf '%s' "$cached"; return 0; }
  [ -n "$base" ] && [ -n "$token" ] || return 1
  body="$(wm_http_get "$base" "$token" "/membership/me")" || return 1
  [ -n "$body" ] || return 1
  wantslug="$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')"
  wantuid="$(printf '%s' "$uid" | tr '[:upper:]' '[:lower:]')"
  # /membership/me may return {memberships:[...]} or a bare array; handle both.
  puid="$(printf '%s' "$body" | jq -r --arg s "$wantslug" --arg u "$wantuid" '
    ((.memberships // .) | if type=="array" then . else [] end)
    | map(select(
        ((.companySlug // "") | ascii_downcase) == $s or
        ((.companyUid  // "") | ascii_downcase) == $u
      ))
    | (.[0].personUid // empty)
  ' 2>/dev/null)" || return 1
  [ -n "$puid" ] || return 1
  case "$puid" in prs_*|agt_*|crt_*) : ;; *) return 1 ;; esac
  cf="$(wm_cache_dir)/person-$(wm_keyfrag "$slug")"
  mkdir -p "$(dirname "$cf")" 2>/dev/null || true
  printf '%s' "$puid" > "$cf" 2>/dev/null || true
  printf '%s' "$puid"
}

# --- gate readers over a fetched gates JSON body ----------------------------
# jq's `//` folds boolean false to empty, so read the raw field and compare.
wm_gate_is_true() {
  local body="${1:-}" field="${2:-}" v
  [ -n "$body" ] && [ -n "$field" ] || return 1
  v="$(printf '%s' "$body" | jq -r --arg f "$field" '.[$f]' 2>/dev/null)" || return 1
  [ "$v" = "true" ]
}
wm_gate_is_false() {
  local body="${1:-}" field="${2:-}" v
  [ -n "$body" ] && [ -n "$field" ] || return 1
  v="$(printf '%s' "$body" | jq -r --arg f "$field" '.[$f]' 2>/dev/null)" || return 1
  [ "$v" = "false" ]
}

# ---------------------------------------------------------------------------
# Secrets redaction — FAIL-CLOSED streaming scrub applied on transcript copy.
# ---------------------------------------------------------------------------
# Pattern catalog is a deliberate replication of the /import-claude redactor
# (.claude/skills/import-claude/redact.sh REDACTIONS + JSON_KEYS) so the hook has
# no runtime dependency on that skill's file layout. KEEP THE TWO IN SYNC: if a
# credential pattern is added there, mirror it here (and vice-versa). Applied
# with a single streaming `sed -E` (memory-bounded — transcripts can be large).
#
# wm_redact_stream <in_file> <out_file>
#   Writes redacted bytes to <out_file>. Prints the redaction COUNT (number of
#   <REDACTED:...> tokens emitted) on stdout — never a secret. Returns 0 on a
#   verified-good redaction; non-zero (fail-closed) on any error or if the line
#   count changed (a redaction must be a pure per-line substitution).
wm_redact_stream() {
  local in="${1:-}" out="${2:-}"
  [ -n "$in" ] && [ -n "$out" ] && [ -f "$in" ] || return 1
  # Extended-regex substitutions. Order matters: specific vendor keys first,
  # broad token/JSON-value scrubs last. Each turns a secret into a labelled tag.
  if ! sed -E \
    -e 's@sk-ant-[A-Za-z0-9_-]{20,}@<REDACTED:anthropic_key>@g' \
    -e 's@github_pat_[A-Za-z0-9_]{20,}@<REDACTED:github_fine>@g' \
    -e 's@ghp_[A-Za-z0-9]{36}@<REDACTED:github_pat>@g' \
    -e 's@gho_[A-Za-z0-9]{36}@<REDACTED:github_oauth>@g' \
    -e 's@xoxb-[0-9]+-[0-9]+-[A-Za-z0-9]+@<REDACTED:slack_bot>@g' \
    -e 's@xoxp-[0-9]+-[0-9]+-[0-9]+-[A-Za-z0-9]+@<REDACTED:slack_user>@g' \
    -e 's@AKIA[0-9A-Z]{16}@<REDACTED:aws_key>@g' \
    -e 's@ASIA[0-9A-Z]{16}@<REDACTED:aws_temp_key>@g' \
    -e 's@AIza[0-9A-Za-z_-]{35}@<REDACTED:google_api>@g' \
    -e 's@sk_live_[A-Za-z0-9]{24,}@<REDACTED:stripe_live>@g' \
    -e 's@sk_test_[A-Za-z0-9]{24,}@<REDACTED:stripe_test>@g' \
    -e 's@eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}@<REDACTED:jwt>@g' \
    -e 's@Bearer[[:space:]]+[A-Za-z0-9._-]+@Bearer <REDACTED:bearer>@g' \
    -e 's@(sk-[A-Za-z0-9]{48,})@<REDACTED:anthropic_legacy>@g' \
    -e 's@sk-[A-Za-z0-9_-]{20,}@<REDACTED:openai_key>@g' \
    -e 's@("(apiKey|api_key|apiToken|authToken|auth_token|access_token|refresh_token|client_secret|clientSecret|private_key|privateKey|secret|token|password)"[[:space:]]*:[[:space:]]*")[^"]+(")@\1<REDACTED:json_secret>\3@g' \
    "$in" > "$out" 2>/dev/null; then
    rm -f "$out" 2>/dev/null || true
    return 1
  fi
  # Sanity: a redaction is line-preserving. If the transformed file lost or
  # gained lines, something went wrong — fail closed rather than ship it.
  local nin nout
  nin="$(wc -l < "$in" 2>/dev/null | tr -d '[:space:]')"
  nout="$(wc -l < "$out" 2>/dev/null | tr -d '[:space:]')"
  if [ "$nin" != "$nout" ]; then
    rm -f "$out" 2>/dev/null || true
    return 1
  fi
  # Non-empty input must yield non-empty output.
  if [ -s "$in" ] && [ ! -s "$out" ]; then
    rm -f "$out" 2>/dev/null || true
    return 1
  fi
  # Count redactions from the OUTPUT only (never touches secret material).
  local n
  n="$(grep -o '<REDACTED:' "$out" 2>/dev/null | wc -l | tr -d '[:space:]')" || n=0
  printf '%s' "${n:-0}"
  return 0
}

# ---------------------------------------------------------------------------
# Atomic, fail-closed transcript copy into the gitignored staging area.
# ---------------------------------------------------------------------------
# wm_copy_transcript <slug> <personUid> <sessionId> <transcript_path>
#   Redacts the ORIGINAL transcript into a temp file INSIDE the staging dir,
#   verifies, then atomically renames into place. On ANY failure the temp is
#   removed and NO destination file is left (caller leaves the spool pending).
#   Prints the redaction count on success; returns 0 on success, non-zero else.
wm_copy_transcript() {
  local slug="${1:-}" puid="${2:-}" sid="${3:-}" tp="${4:-}"
  [ -n "$slug" ] && [ -n "$puid" ] && [ -n "$sid" ] && [ -n "$tp" ] || return 1
  wm_safe_path_component "$slug" || return 1
  wm_safe_path_component "$puid" || return 1
  wm_safe_path_component "$sid" || return 1
  [ -f "$tp" ] || return 1
  local root stage dstdir dst tmp rc n p
  root="$(wm_hq_root)" || return 1
  stage="$root/companies/$slug/sessions"
  dstdir="$stage/$puid"
  # Do not follow attacker-controlled directory symlinks out of the HQ staging
  # tree. Check both before and after mkdir to narrow the local race window.
  for p in "$root/companies" "$root/companies/$slug" "$stage" "$dstdir"; do
    [ ! -L "$p" ] || return 1
  done
  dst="$dstdir/$sid.jsonl"
  mkdir -p "$dstdir" 2>/dev/null || return 1
  for p in "$root/companies" "$root/companies/$slug" "$stage" "$dstdir"; do
    [ ! -L "$p" ] || return 1
  done
  # Temp lives inside the same (gitignored) staging dir so the final mv is an
  # atomic same-filesystem rename and no unredacted bytes ever land elsewhere.
  tmp="$(mktemp "$dstdir/.$sid.jsonl.redacting.XXXXXX" 2>/dev/null)" || return 1
  n="$(wm_redact_stream "$tp" "$tmp")"; rc=$?
  if [ "$rc" -ne 0 ] || [ ! -s "$tmp" ]; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  if ! mv -f "$tmp" "$dst" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  printf '%s' "${n:-0}"
  return 0
}

# ---------------------------------------------------------------------------
# Outcome derivation from a Claude Code transcript (best-effort, bounded).
# ---------------------------------------------------------------------------
# wm_derive_outcome <transcript_path|""> <sessionId> <projectId|""> <branch|"">
#   Emits a WorkSessionOutcome JSON (server contract §11.5). Missing / oversized
#   / non-existent transcript => a minimal skeleton (empty arrays, 0 counts) so a
#   reconcile is NEVER blocked. files.paths is capped at 500 with the true total.
wm_derive_outcome() {
  local tp="${1:-}" sid="${2:-}" project="${3:-}" branch="${4:-}"
  local cap sz root home
  cap="$(wm_transcript_budget)"
  # HQ root + home for path relativization: emitted file paths are stripped of
  # the absolute HQ-root (then home) prefix so only repo-relative paths like
  # companies/<slug>/… remain. This removes the local username + absolute
  # machine layout from reconcile registry metadata (posted under the registry
  # consent tier, so it must not leak absolute local paths).
  root="$(wm_hq_root 2>/dev/null || echo '')"
  home="${HOME:-}"
  sz=0
  if [ -n "$tp" ] && [ -f "$tp" ]; then
    sz="$(wc -c < "$tp" 2>/dev/null | tr -d '[:space:]')"; [ -n "$sz" ] || sz=0
  fi
  if [ -z "$tp" ] || [ ! -f "$tp" ] || [ "$sz" -gt "$cap" ] 2>/dev/null; then
    jq -nc --arg sid "$sid" --arg project "$project" --arg branch "$branch" '
      {sessionId:$sid, files:{paths:[],totalCount:0,truncated:false},
       skills:[],models:[],tokens:0,durationMs:0,commits:[]}
      + (if $project!="" then {projectId:$project} else {} end)
      + (if $branch!="" then {branch:$branch} else {} end)' 2>/dev/null
    return 0
  fi
  jq -s --arg sid "$sid" --arg project "$project" --arg branch "$branch" \
        --arg root "$root" --arg home "$home" '
    # Relativize an absolute local path to the HQ root (then home) so emitted
    # registry metadata carries repo-relative paths only — no username/layout.
    def rel:
      if   ($root != "" and startswith($root + "/")) then ltrimstr($root + "/")
      elif ($home != "" and startswith($home + "/")) then ltrimstr($home + "/")
      else . end;
    def ep: (gsub("\\.[0-9]+";"") | gsub("[+-][0-9]{2}:[0-9]{2}$";"Z") | fromdateiso8601? // null);
    (map(.timestamp? // empty) | map(ep) | map(select(.!=null))) as $ts
    | ([ .[] | (.message.content? // []) | if type=="array" then .[] else empty end
         | select(.type=="tool_use" and ((.name? // "")|test("^(Write|Edit|MultiEdit|NotebookEdit)$")))
         | (.input.file_path? // empty) ] | map(select(.!="")) | map(rel) | unique) as $files
    | ([ .[] | .message.model? // empty ] | map(select(.!="")) | unique) as $models
    | ([ .[] | (.message.content? // []) | if type=="array" then .[] else empty end
         | select(.type=="tool_use" and ((.name? // "")=="Skill"))
         | (.input.command? // .input.skill? // empty) ] | map(select(.!="")) | unique) as $skills
    | ([ .[] | .message.usage? // {}
         | ((.input_tokens // 0)+(.output_tokens // 0)
            +(.cache_read_input_tokens // 0)+(.cache_creation_input_tokens // 0)) ]
        | add // 0) as $tokens
    | (if ($ts|length)>=2 then ((($ts|max)-($ts|min))*1000|floor) else 0 end) as $dur
    | {sessionId:$sid,
       files:{paths:($files[0:500]), totalCount:($files|length), truncated:(($files|length)>500)},
       skills:$skills, models:$models, tokens:$tokens, durationMs:$dur, commits:[]}
    + (if $project!="" then {projectId:$project} else {} end)
    + (if $branch!="" then {branch:$branch} else {} end)
  ' "$tp" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Reconcile payload + POST (server contract §11.9).
# ---------------------------------------------------------------------------
# wm_reconcile_payload <companyUid> <sessionId> <outcome_json> <summary> \
#                      <harness> <category> <intent> [flag_key] [flag_val]
# The optional trailing flag (e.g. transcriptUnavailable / crossCompany /
# transcriptSkipped) rides the body top-level. The server currently ignores
# unknown top-level keys (the reconcile handler reads only the fixed fields and
# validates `outcome` via validateDonePayload, which drops unknowns) — so the
# flag is forward-compatible telemetry; the AUTHORITATIVE client record of it is
# the spool line the caller writes.
wm_reconcile_payload() {
  local uid="${1:-}" sid="${2:-}" outcome="${3:-}" summary="${4:-}" \
        harness="${5:-}" category="${6:-}" intent="${7:-}" fkey="${8:-}" fval="${9:-}"
  [ -n "$outcome" ] || outcome='{}'
  jq -nc \
    --arg uid "$uid" --arg sid "$sid" --argjson outcome "$outcome" \
    --arg summary "$summary" --arg harness "$harness" \
    --arg category "$category" --arg intent "$intent" \
    --arg fkey "$fkey" --arg fval "$fval" '
    {companyUid:$uid, sessionId:$sid, outcome:$outcome}
    + (if $summary  != "" then {summary:$summary}       else {} end)
    + (if $harness  != "" then {harness:$harness}        else {} end)
    + (if $category != "" then {category:$category}      else {} end)
    + (if $intent   != "" then {intentSummary:$intent}   else {} end)
    + (if $fkey     != "" then {($fkey):$fval}           else {} end)
  ' 2>/dev/null
}
