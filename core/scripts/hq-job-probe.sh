#!/usr/bin/env bash
# hq-core: public
# hq-job-probe.sh — Outpost requirements probe → hq-pro jobs status (US-008).
#
# On the Outpost, deterministically checks a job's requirements checklist and
# POSTs readiness to POST /outpost/internal/jobs-status. Never rewrites job YAML.
#
# Usage:
#   core/scripts/hq-job-probe.sh [options] <job.yaml|job-id>
#   core/scripts/hq-job-probe.sh [options] --all
#
# Options:
#   --hq-root DIR     HQ tree root (default: HQ_ROOT or repo root above core/)
#   --dry-run         Run checks + print JSON; skip ingest
#   --no-ingest       Alias of --dry-run
#   --json            Force JSON on stdout (default)
#   -h, --help        Show this help
#
# Checks (per requirements / job fields):
#   - runtime CLI auth: claude → ~/.claude/.credentials.json; codex → ~/.codex/auth.json
#   - requirements.secrets[] visible via `hq secrets list` (names only; never values)
#   - optional cwd exists (HQ-root-relative or absolute)
#   - company path present when requirements.company / company scope set
#
# Ingest auth (box identity — same trust model as disk-status / relay-status):
#   Header: x-outpost-instance-token
#   Body:   userId + jobId + kind=probe + readiness + probed_at + next_actions + checks
#   Identity from (first match):
#     1. OUTPOST_USER_ID + OUTPOST_INSTANCE_TOKEN (+ optional OUTPOST_ID)
#     2. /etc/outpost/codex-identity.env (OUTPOST_USER_ID / OUTPOST_INSTANCE_TOKEN)
#     3. USER_ID= / INSTANCE_TOKEN= / OUTPOST_ID= lines in /usr/local/bin/outpost-runner.sh
#   API base: HQ_PRO_API_URL → HQ_API_URL → HQ_VAULT_API_URL → https://hqapi.hq.computer
#
# StatusIngestError (unreachable / 5xx / retryable body):
#   Bounded backoff retries; writes ~/.hq/jobs/probes/{id}/last-attempt.json;
#   never reports readiness=ready solely because ingest failed; surfaces
#   next_action "status ingest failed — retry probe".
#
# Env (tests / overrides):
#   HQ_ROOT, HOME, HQ_PRO_API_URL, OUTPOST_USER_ID, OUTPOST_INSTANCE_TOKEN, OUTPOST_ID
#   HQ_JOB_PROBE_CLAUDE_CRED, HQ_JOB_PROBE_CODEX_AUTH
#   HQ_JOB_PROBE_STATE_DIR, HQ_JOB_PROBE_MAX_ATTEMPTS, HQ_JOB_PROBE_BACKOFF_BASE_SEC
#   HQ_JOB_PROBE_SLEEP (set to ":" to no-op sleep), HQ_JOB_PROBE_NOW (ISO timestamp)
#   HQ_JOB_PROBE_CURL (curl binary override), HQ_JOB_PROBE_RUNNER (outpost-runner path)
#
# Exit: 0 ready+ingested (or dry-run ready); 1 blocked; 2 usage/config; 3 StatusIngestError

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="${HQ_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/hook-lib.sh"

DRY_RUN=0
PROBE_ALL=0
TARGET=""

usage() {
  sed -n '3,48p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
  echo "hq-job-probe: $*" >&2
  exit 2
}

log() {
  echo "hq-job-probe: $*" >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --hq-root)
      HQ_ROOT="${2:-}"
      [ -n "$HQ_ROOT" ] || die "--hq-root requires a directory"
      shift 2
      ;;
    --dry-run|--no-ingest)
      DRY_RUN=1
      shift
      ;;
    --all)
      PROBE_ALL=1
      shift
      ;;
    --json)
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      if [ -n "$TARGET" ]; then
        die "unexpected argument: $1"
      fi
      TARGET="$1"
      shift
      ;;
  esac
done

command -v yq >/dev/null 2>&1 || die "yq is required (mikefarah/yq)"
command -v jq >/dev/null 2>&1 || die "jq is required"

iso_now() {
  if [ -n "${HQ_JOB_PROBE_NOW:-}" ]; then
    printf '%s' "$HQ_JOB_PROBE_NOW"
    return
  fi
  date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u +"%Y-%m-%dT%H:%M:%S+00:00"
}

probe_sleep() {
  local secs="${1:-1}"
  # HQ_JOB_PROBE_SLEEP=':'|true → no-op for tests. Never eval arbitrary env (review CRITICAL 4).
  if [ "${HQ_JOB_PROBE_SLEEP:-}" = ":" ] || [ "${HQ_JOB_PROBE_SLEEP:-}" = "true" ]; then
    return 0
  fi
  if [[ "$secs" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    sleep "$secs" 2>/dev/null || true
  fi
}

api_base() {
  local base
  base="${HQ_PRO_API_URL:-${HQ_API_URL:-${HQ_VAULT_API_URL:-https://hqapi.hq.computer}}}"
  base="${base%/}"
  printf '%s' "$base"
}

# Load box identity into OUTPOST_USER_ID / OUTPOST_INSTANCE_TOKEN / OUTPOST_ID.
resolve_box_identity() {
  if [ -n "${OUTPOST_USER_ID:-}" ] && [ -n "${OUTPOST_INSTANCE_TOKEN:-}" ]; then
    return 0
  fi

  local envf="/etc/outpost/codex-identity.env"
  if [ -f "$envf" ]; then
    # shellcheck disable=SC1090
    . "$envf" 2>/dev/null || true
    if [ -n "${OUTPOST_USER_ID:-}" ] && [ -n "${OUTPOST_INSTANCE_TOKEN:-}" ]; then
      return 0
    fi
  fi

  local runner="${HQ_JOB_PROBE_RUNNER:-/usr/local/bin/outpost-runner.sh}"
  if [ -f "$runner" ]; then
    OUTPOST_USER_ID="${OUTPOST_USER_ID:-$(sed -n 's/^USER_ID="\(.*\)"$/\1/p' "$runner" 2>/dev/null | head -1)}"
    OUTPOST_INSTANCE_TOKEN="${OUTPOST_INSTANCE_TOKEN:-$(sed -n 's/^INSTANCE_TOKEN="\(.*\)"$/\1/p' "$runner" 2>/dev/null | head -1)}"
    OUTPOST_ID="${OUTPOST_ID:-$(sed -n 's/^OUTPOST_ID="\(.*\)"$/\1/p' "$runner" 2>/dev/null | head -1)}"
  fi

  if [ -n "${OUTPOST_USER_ID:-}" ] && [ -n "${OUTPOST_INSTANCE_TOKEN:-}" ]; then
    return 0
  fi
  return 1
}

find_job_file_by_id() {
  local id="$1" f found=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ "$(yq -r '.id // ""' "$f" 2>/dev/null)" = "$id" ]; then
      if [ -n "$found" ]; then
        die "duplicate job id '$id' in registry: $found and $f"
      fi
      found="$f"
    fi
  done < <(
    {
      find "$HQ_ROOT/personal/jobs" \( -name '*.yaml' -o -name '*.yml' \) -type f 2>/dev/null || true
      find "$HQ_ROOT/companies" -path '*/jobs/*' \( -name '*.yaml' -o -name '*.yml' \) -type f 2>/dev/null || true
    } | sort
  )
  [ -n "$found" ] || return 1
  printf '%s' "$found"
}

collect_all_job_files() {
  {
    find "$HQ_ROOT/personal/jobs" \( -name '*.yaml' -o -name '*.yml' \) -type f 2>/dev/null || true
    find "$HQ_ROOT/companies" -path '*/jobs/*' \( -name '*.yaml' -o -name '*.yml' \) -type f 2>/dev/null || true
  } | sort
}

claude_cred_path() {
  printf '%s' "${HQ_JOB_PROBE_CLAUDE_CRED:-${HOME}/.claude/.credentials.json}"
}

codex_auth_path() {
  printf '%s' "${HQ_JOB_PROBE_CODEX_AUTH:-${HOME}/.codex/auth.json}"
}

check_runtime_auth() {
  # prints ok|missing|no_cli ; uses global RUNTIME
  local runtime="$1"
  case "$runtime" in
    claude)
      if ! command -v claude >/dev/null 2>&1; then
        printf 'no_cli'
        return 1
      fi
      if [ -s "$(claude_cred_path)" ]; then
        printf 'ok'
        return 0
      fi
      printf 'missing'
      return 1
      ;;
    codex)
      if ! command -v codex >/dev/null 2>&1; then
        printf 'no_cli'
        return 1
      fi
      if [ -s "$(codex_auth_path)" ]; then
        printf 'ok'
        return 0
      fi
      printf 'missing'
      return 1
      ;;
    *)
      printf 'unknown_runtime'
      return 1
      ;;
  esac
}

# List visible secret NAMES only (never values). stdout: one name per line.
list_secret_names() {
  local company="${1:-}"
  local out rc=0
  if [ -n "$company" ]; then
    out="$(hq secrets list --company "$company" 2>/dev/null)" || rc=$?
  else
    out="$(hq secrets list --personal 2>/dev/null)" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  # Skip banner / header rows; emit first whitespace-delimited field when it
  # looks like a vault key name (UPPER_SNAKE / alnum._:-).
  printf '%s\n' "$out" | awk '
    BEGIN { ignore = 1 }
    /^NAME([[:space:]]|$)/ { ignore = 0; next }
    ignore { next }
    /^[[:space:]]*$/ { next }
    /^Secrets / { next }
    {
      name = $1
      if (name ~ /^[A-Za-z][A-Za-z0-9._:\/-]{0,127}$/) print name
    }
  '
}

secret_name_visible() {
  local needle="$1"
  local names_file="$2"
  grep -Fxq -- "$needle" "$names_file" 2>/dev/null
}

state_dir_for_job() {
  local id="$1"
  local base="${HQ_JOB_PROBE_STATE_DIR:-${HOME}/.hq/jobs/probes}"
  printf '%s/%s' "$base" "$id"
}

write_attempt_marker() {
  local id="$1" payload="$2"
  local dir
  dir="$(state_dir_for_job "$id")"
  mkdir -p "$dir"
  printf '%s\n' "$payload" >"$dir/last-attempt.json"
  # Never chmod secrets; marker is non-secret forensics.
  chmod 600 "$dir/last-attempt.json" 2>/dev/null || true
}

# Box-local readiness cache for reconciler (US-004). Written only after a
# successful ingest (or dry-run) so timers never arm on a failed ingest.
write_status_cache() {
  local id="$1" readiness="$2" source="${3:-probe-ingest}"
  local base="${HQ_JOB_STATUS_CACHE_DIR:-${HOME}/.hq/jobs/status-cache}"
  mkdir -p "$base"
  jq -nc \
    --arg job_id "$id" \
    --arg readiness "$readiness" \
    --arg updated_at "$(iso_now)" \
    --arg source "$source" \
    '{job_id:$job_id,readiness:$readiness,updated_at:$updated_at,source:$source}' \
    >"$base/${id}.json"
  chmod 600 "$base/${id}.json" 2>/dev/null || true
}

# POST probe ingest with bounded backoff. Sets INGEST_OK, INGEST_HTTP, INGEST_BODY.
ingest_probe() {
  local payload="$1"
  local max_attempts base_sec attempt delay http body curl_bin url tmp_body tmp_hdr
  max_attempts="${HQ_JOB_PROBE_MAX_ATTEMPTS:-3}"
  base_sec="${HQ_JOB_PROBE_BACKOFF_BASE_SEC:-1}"
  curl_bin="${HQ_JOB_PROBE_CURL:-curl}"
  url="$(api_base)/outpost/internal/jobs-status"

  INGEST_OK=0
  INGEST_HTTP=0
  INGEST_BODY=""
  INGEST_RETRYABLE=0

  if ! command -v "$curl_bin" >/dev/null 2>&1 && [ "$curl_bin" = "curl" ]; then
    if ! command -v curl >/dev/null 2>&1; then
      INGEST_BODY='{"error":true,"code":"StatusIngestError","step":"config","message":"curl not found","retryable":true}'
      INGEST_RETRYABLE=1
      return 1
    fi
  fi

  attempt=1
  while [ "$attempt" -le "$max_attempts" ]; do
    tmp_body="$(mktemp "${TMPDIR:-/tmp}/hq-job-probe-body.XXXXXX")"
    tmp_hdr="$(mktemp "${TMPDIR:-/tmp}/hq-job-probe-hdr.XXXXXX")"
    http=0
    set +e
    "$curl_bin" -sS -m 20 -X POST "$url" \
      -H "content-type: application/json" \
      -H "x-outpost-instance-token: ${OUTPOST_INSTANCE_TOKEN}" \
      --data "$payload" \
      -D "$tmp_hdr" \
      -o "$tmp_body"
    local curl_rc=$?
    set -e
    if [ "$curl_rc" -eq 0 ]; then
      http="$(awk 'BEGIN{c=0} /^HTTP\//{c=$2} END{print c+0}' "$tmp_hdr" 2>/dev/null || echo 0)"
      body="$(cat "$tmp_body" 2>/dev/null || true)"
    else
      http=0
      body="$(printf '{"error":true,"code":"StatusIngestError","step":"lookup","message":"curl failed rc=%s (API unreachable)","retryable":true}' "$curl_rc")"
    fi
    rm -f "$tmp_body" "$tmp_hdr"

    INGEST_HTTP="$http"
    INGEST_BODY="$body"

    if [ "$http" -ge 200 ] && [ "$http" -lt 300 ]; then
      INGEST_OK=1
      INGEST_RETRYABLE=0
      return 0
    fi

    # Retry on transport failure, 5xx, or explicit retryable StatusIngestError.
    local retry=0
    if [ "$http" -eq 0 ] || [ "$http" -ge 500 ]; then
      retry=1
    elif printf '%s' "$body" | jq -e '.retryable == true' >/dev/null 2>&1; then
      retry=1
    elif printf '%s' "$body" | jq -e '.code == "StatusIngestError" and (.step == "persist" or .step == "lookup" or .step == "config")' >/dev/null 2>&1; then
      retry=1
    fi
    INGEST_RETRYABLE="$retry"

    if [ "$retry" -ne 1 ] || [ "$attempt" -ge "$max_attempts" ]; then
      break
    fi
    delay=$((base_sec * (1 << (attempt - 1))))
    log "ingest attempt $attempt/$max_attempts failed (http=$http); backoff ${delay}s"
    probe_sleep "$delay"
    attempt=$((attempt + 1))
  done

  INGEST_OK=0
  return 1
}

probe_one_file() {
  local job_file="$1"
  [ -f "$job_file" ] || die "job file not found: $job_file"

  local id name runtime req_runtime company cwd_rel
  id="$(yq -r '.id // ""' "$job_file")"
  name="$(yq -r '.name // ""' "$job_file")"
  runtime="$(yq -r '.runtime // ""' "$job_file")"
  req_runtime="$(yq -r '.requirements.runtime // ""' "$job_file")"
  company="$(yq -r '.requirements.company // ""' "$job_file")"
  cwd_rel="$(yq -r '.requirements.cwd // .cwd // ""' "$job_file")"

  [ -n "$id" ] || die "job missing id: $job_file"
  if [ -n "$req_runtime" ]; then
    runtime="$req_runtime"
  fi
  [ -n "$runtime" ] || die "job missing runtime: $job_file"

  local probed_at event_id
  probed_at="$(iso_now)"
  event_id="probe-${probed_at}-${id}"

  # bash 3.2 + set -u: keep action/missing lists as newline strings, not arrays
  local next_actions_nl=""
  local auth_status secrets_status cwd_status company_status
  local blocked=0
  local secrets_missing_json="[]"
  local names_tmp
  local _action_line

  # --- runtime auth ---
  auth_status="$(check_runtime_auth "$runtime" || true)"
  case "$auth_status" in
    ok) ;;
    no_cli)
      blocked=1
      _action_line="install ${runtime} CLI on Outpost and re-login"
      next_actions_nl="${next_actions_nl:+${next_actions_nl}$'\n'}${_action_line}"
      ;;
    missing)
      blocked=1
      _action_line="device re-login for ${runtime} on Outpost (cached credentials missing)"
      next_actions_nl="${next_actions_nl:+${next_actions_nl}$'\n'}${_action_line}"
      ;;
    *)
      blocked=1
      _action_line="unsupported runtime '${runtime}' — fix job requirements.runtime"
      next_actions_nl="${next_actions_nl:+${next_actions_nl}$'\n'}${_action_line}"
      auth_status="unknown_runtime"
      ;;
  esac

  # --- secrets (names only via hq secrets list) ---
  secrets_status="ok"
  names_tmp="$(mktemp "${TMPDIR:-/tmp}/hq-job-probe-secrets.XXXXXX")"
  local list_rc=0
  list_secret_names "$company" >"$names_tmp" || list_rc=$?
  if [ "$list_rc" -ne 0 ]; then
    blocked=1
    secrets_status="list_failed"
    if [ -n "$company" ]; then
      _action_line="hq secrets list --company ${company} failed on Outpost — check hq login / vault access"
    else
      _action_line="hq secrets list --personal failed on Outpost — check hq login / vault access"
    fi
    next_actions_nl="${next_actions_nl:+${next_actions_nl}$'\n'}${_action_line}"
  else
    local missing_names_nl=""
    local secret_count
    secret_count="$(yq -r '.requirements.secrets // [] | length' "$job_file")"
    if [ "$secret_count" != "null" ] && [ "${secret_count:-0}" -gt 0 ] 2>/dev/null; then
      local i secret_name
      i=0
      while [ "$i" -lt "$secret_count" ]; do
        secret_name="$(yq -r ".requirements.secrets[$i]" "$job_file")"
        i=$((i + 1))
        [ -n "$secret_name" ] && [ "$secret_name" != "null" ] || continue
        if ! secret_name_visible "$secret_name" "$names_tmp"; then
          if [ -z "$missing_names_nl" ]; then
            missing_names_nl="$secret_name"
          else
            missing_names_nl="${missing_names_nl}"$'\n'"${secret_name}"
          fi
        fi
      done
    fi
    if [ -n "$missing_names_nl" ]; then
      blocked=1
      secrets_status="missing"
      local sn
      while IFS= read -r sn; do
        [ -n "$sn" ] || continue
        _action_line="hq secrets share ${sn} (grant Outpost owner visibility; names only — never paste values)"
        next_actions_nl="${next_actions_nl:+${next_actions_nl}$'\n'}${_action_line}"
      done <<EOF
$missing_names_nl
EOF
      secrets_missing_json="$(printf '%s\n' "$missing_names_nl" | jq -R . | jq -s -c .)"
    fi
  fi
  rm -f "$names_tmp"

  # --- cwd (HQ-root-relative only; no absolute / no .. escape) ---
  cwd_status="ok"
  if [ -n "$cwd_rel" ] && [ "$cwd_rel" != "null" ]; then
    local cwd_abs cwd_part cwd_bad=0
    case "$cwd_rel" in
      /*)
        blocked=1
        cwd_status="invalid"
        next_actions_nl="${next_actions_nl:+$next_actions_nl$'\n'}fix cwd to HQ-root-relative path (absolute not allowed)"
        cwd_bad=1
        ;;
    esac
    if [ "$cwd_bad" -eq 0 ]; then
      local IFS='/'
      # shellcheck disable=SC2086
      for cwd_part in $cwd_rel; do
        if [ "$cwd_part" = ".." ]; then
          blocked=1
          cwd_status="invalid"
          next_actions_nl="${next_actions_nl:+$next_actions_nl$'\n'}fix cwd — remove '..' path components"
          cwd_bad=1
          break
        fi
      done
      unset IFS
    fi
    if [ "$cwd_bad" -eq 0 ]; then
      # Portable resolve: GNU realpath -m, BSD realpath (existing paths), else hq_normpath.
      local hq_canon=""
      hq_canon="$(realpath -m "$HQ_ROOT" 2>/dev/null || realpath "$HQ_ROOT" 2>/dev/null || true)"
      cwd_abs="$(realpath -m "$HQ_ROOT/$cwd_rel" 2>/dev/null || true)"
      if [ -z "$cwd_abs" ] && [ -d "$HQ_ROOT/$cwd_rel" ]; then
        cwd_abs="$(realpath "$HQ_ROOT/$cwd_rel" 2>/dev/null || true)"
      fi
      if [ -z "$hq_canon" ] || [ -z "$cwd_abs" ]; then
        hq_canon="$(hq_normpath "$HQ_ROOT")"
        cwd_abs="$(hq_normpath "$HQ_ROOT/$cwd_rel")"
      fi
      case "$cwd_abs" in
        "$hq_canon"|"$hq_canon"/*) ;;
        *)
          blocked=1
          cwd_status="invalid"
          next_actions_nl="${next_actions_nl:+$next_actions_nl$'\n'}fix cwd — must resolve under HQ root"
          cwd_bad=1
          ;;
      esac
    fi
    if [ "$cwd_bad" -eq 0 ]; then
      if [ ! -d "$cwd_abs" ]; then
        blocked=1
        cwd_status="missing"
        next_actions_nl="${next_actions_nl:+$next_actions_nl$'\n'}create cwd on Outpost HQ tree: ${cwd_rel}"
      fi
    fi
  else
    cwd_status="skipped"
  fi

  # --- company path ---
  company_status="ok"
  if [ -n "$company" ] && [ "$company" != "null" ]; then
    if [ ! -d "$HQ_ROOT/companies/$company" ]; then
      blocked=1
      company_status="missing"
      next_actions+=("company path missing on Outpost: companies/${company} — sync or join company")
    fi
  else
    company_status="skipped"
  fi

  local readiness="ready"
  if [ "$blocked" -eq 1 ]; then
    readiness="blocked"
  fi

  local actions_json
  if [ -z "$next_actions_nl" ]; then
    actions_json='[]'
  else
    actions_json="$(printf '%s\n' "$next_actions_nl" | awk 'NF && !seen[$0]++' | jq -R . | jq -s -c .)"
  fi

  local checks_json
  checks_json="$(jq -nc \
    --arg runtime "$runtime" \
    --arg auth "$auth_status" \
    --arg secrets "$secrets_status" \
    --argjson missing "$secrets_missing_json" \
    --arg cwd "$cwd_status" \
    --arg company "$company_status" \
    --arg company_slug "$company" \
    '{
      runtime: $runtime,
      auth: $auth,
      secrets: {status: $secrets, missing: $missing},
      cwd: $cwd,
      company: (if $company_slug == "" then {status: $company} else {status: $company, slug: $company_slug} end)
    }')"

  local user_id="${OUTPOST_USER_ID:-}"
  local outpost_id="${OUTPOST_ID:-}"

  # Build ingest payload (snake_case fields accepted by US-009 handler).
  local payload
  payload="$(jq -nc \
    --arg userId "$user_id" \
    --arg jobId "$id" \
    --arg readiness "$readiness" \
    --arg probed_at "$probed_at" \
    --arg event_id "$event_id" \
    --arg outpostId "$outpost_id" \
    --argjson next_actions "$actions_json" \
    --argjson checks "$checks_json" \
    '{
      userId: $userId,
      jobId: $jobId,
      kind: "probe",
      readiness: $readiness,
      probed_at: $probed_at,
      event_id: $event_id,
      next_actions: $next_actions,
      checks: $checks
    } + (if $outpostId != "" then {outpostId: $outpostId} else {} end)')"

  local result_ingest="skipped"
  local result_http=0
  local ingest_error=0

  if [ "$DRY_RUN" -eq 1 ]; then
    result_ingest="dry_run"
    write_status_cache "$id" "$readiness" "probe-dry-run"
  else
    if ! resolve_box_identity; then
      # Cannot authenticate to hq-pro — treat as StatusIngestError path.
      ingest_error=1
      result_ingest="StatusIngestError"
      local marker
      marker="$(jq -nc \
        --arg job_id "$id" \
        --arg probed_at "$probed_at" \
        --arg local_readiness "$readiness" \
        --arg message "missing Outpost identity (OUTPOST_USER_ID / OUTPOST_INSTANCE_TOKEN)" \
        --argjson checks "$checks_json" \
        --argjson next_actions "$(jq -nc --argjson a "$actions_json" '$a + ["status ingest failed — retry probe"]')" \
        '{
          job_id: $job_id,
          probed_at: $probed_at,
          local_readiness: $local_readiness,
          ingest: {ok: false, code: "StatusIngestError", step: "config", message: $message, retryable: true},
          reported_readiness: null,
          next_actions: $next_actions,
          checks: $checks
        }')"
      write_attempt_marker "$id" "$marker"
      # Never claim ready when ingest cannot run.
      readiness="unknown"
      actions_json="$(jq -nc --argjson a "$actions_json" '
        ($a + ["status ingest failed — retry probe"]) as $x
        | reduce $x[] as $i ([]; if index($i) then . else . + [$i] end)
      ')"
    else
      # Refresh payload with resolved userId
      payload="$(jq -nc \
        --arg userId "$OUTPOST_USER_ID" \
        --arg jobId "$id" \
        --arg readiness "$readiness" \
        --arg probed_at "$probed_at" \
        --arg event_id "$event_id" \
        --arg outpostId "${OUTPOST_ID:-}" \
        --argjson next_actions "$actions_json" \
        --argjson checks "$checks_json" \
        '{
          userId: $userId,
          jobId: $jobId,
          kind: "probe",
          readiness: $readiness,
          probed_at: $probed_at,
          event_id: $event_id,
          next_actions: $next_actions,
          checks: $checks
        } + (if $outpostId != "" then {outpostId: $outpostId} else {} end)')"

      local intended_readiness="$readiness"
      if ingest_probe "$payload"; then
        result_ingest="ok"
        result_http="$INGEST_HTTP"
        local marker_ok
        marker_ok="$(jq -nc \
          --arg job_id "$id" \
          --arg probed_at "$probed_at" \
          --arg local_readiness "$intended_readiness" \
          --argjson http "$INGEST_HTTP" \
          --argjson checks "$checks_json" \
          --argjson next_actions "$actions_json" \
          '{
            job_id: $job_id,
            probed_at: $probed_at,
            local_readiness: $local_readiness,
            ingest: {ok: true, http: $http},
            reported_readiness: $local_readiness,
            next_actions: $next_actions,
            checks: $checks
          }')"
        write_attempt_marker "$id" "$marker_ok"
        write_status_cache "$id" "$intended_readiness" "probe-ingest"
      else
        ingest_error=1
        result_ingest="StatusIngestError"
        result_http="$INGEST_HTTP"
        # Leave prior API readiness unchanged (we did not successfully write).
        # Never report ready solely because ingest failed.
        local fail_actions body_raw
        fail_actions="$(jq -nc --argjson a "$actions_json" '$a + ["status ingest failed — retry probe"]')"
        body_raw="${INGEST_BODY:-}"
        [ -n "$body_raw" ] || body_raw="{}"
        # Prefer --arg + fromjson so nested JSON cannot break ${:-{}} brace parsing.
        local marker_fail
        marker_fail="$(jq -nc \
          --arg job_id "$id" \
          --arg probed_at "$probed_at" \
          --arg local_readiness "$intended_readiness" \
          --argjson http "$INGEST_HTTP" \
          --arg body "$body_raw" \
          --argjson checks "$checks_json" \
          --argjson next_actions "$fail_actions" \
          --argjson retryable "${INGEST_RETRYABLE:-1}" \
          '{
            job_id: $job_id,
            probed_at: $probed_at,
            local_readiness: $local_readiness,
            ingest: {
              ok: false,
              code: "StatusIngestError",
              http: $http,
              retryable: ($retryable == 1),
              body: (try ($body | fromjson) catch {raw: $body})
            },
            reported_readiness: null,
            next_actions: $next_actions,
            checks: $checks
          }')"
        write_attempt_marker "$id" "$marker_fail"
        readiness="unknown"
        actions_json="$fail_actions"
      fi
    fi
  fi

  local result
  result="$(jq -nc \
    --arg job_id "$id" \
    --arg name "$name" \
    --arg job_file "$job_file" \
    --arg readiness "$readiness" \
    --arg probed_at "$probed_at" \
    --arg ingest "$result_ingest" \
    --argjson http "$result_http" \
    --argjson checks "$checks_json" \
    --argjson next_actions "$actions_json" \
    --argjson dry_run "$DRY_RUN" \
    '{
      job_id: $job_id,
      name: $name,
      job_file: $job_file,
      readiness: $readiness,
      probed_at: $probed_at,
      ingest: $ingest,
      http: $http,
      dry_run: ($dry_run == 1),
      checks: $checks,
      next_actions: $next_actions
    }')"

  printf '%s\n' "$result"

  if [ "$ingest_error" -eq 1 ]; then
    return 3
  fi
  if [ "$blocked" -eq 1 ]; then
    return 1
  fi
  return 0
}

# --- main ---

if [ "$PROBE_ALL" -eq 1 ]; then
  [ -z "$TARGET" ] || die "--all does not take a job argument"
  overall=0
  any=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    any=1
    rc=0
    probe_one_file "$f" || rc=$?
    if [ "$rc" -gt "$overall" ]; then
      overall="$rc"
    fi
  done < <(collect_all_job_files)
  [ "$any" -eq 1 ] || die "no job YAML found under personal/jobs or companies/*/jobs in $HQ_ROOT"
  exit "$overall"
fi

[ -n "$TARGET" ] || die "usage: hq-job-probe.sh [--dry-run] <job.yaml|job-id> | --all"

JOB_FILE=""
if [ -f "$TARGET" ]; then
  JOB_FILE="$TARGET"
elif [ -f "$HQ_ROOT/$TARGET" ]; then
  JOB_FILE="$HQ_ROOT/$TARGET"
else
  JOB_FILE="$(find_job_file_by_id "$TARGET")" || die "job id not found in registry: $TARGET"
fi

rc=0
probe_one_file "$JOB_FILE" || rc=$?
exit "$rc"
