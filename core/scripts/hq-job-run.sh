#!/usr/bin/env bash
# hq-core: public
# hq-job-run.sh — serialized Outpost scheduled-job executor (US-004 + US-006).
#
# Invoked by systemd user units (hq-job-{id}.service) or on demand:
#   core/scripts/hq-job-run.sh --job-id <id>
#   core/scripts/hq-job-run.sh <job.yaml>
#
# Behavior:
#   - Global file lock (~/.hq/jobs/run.lock) — serialized-only (US-001)
#   - Enforces job timeout_seconds (default 600; schema 60–14400)
#   - Credentials only via `hq secrets exec` (requirements.secrets[]) or
#     the box's cached CLI auth — never env vars / unit-file secrets
#   - Trust model (7A): injects ONLY requirements.secrets[] — no static prompt scan
#   - Appends stdout/stderr + exit to ~/.hq/jobs/logs/{id}/
#   - Emits a compute-meter attribution marker (scheduled vs interactive)
#   - Classifies failures (auth|secrets|timeout|agent_error|infra), writes
#     failure_class to hq-pro jobs status (kind=run), bounded self-remediate,
#     then dm-notify via hq-job-notify.sh (collapse 1/24h; never create-thread)
#   - Missing runtime CLI auth: classify auth, notify re-login, exit 0 (unit OK)
#
# Runtime dispatch (US-001 spike flags):
#   claude → claude -p … --output-format text --permission-mode bypassPermissions
#   codex  → codex exec -s workspace-write --skip-git-repo-check …
#
# Env / overrides (tests):
#   HQ_ROOT, HOME, HQ_JOB_LOCK, HQ_JOB_LOG_DIR, HQ_JOB_METER_DIR
#   HQ_JOB_TIMEOUT_BIN, HQ_JOB_FLOCK_BIN, HQ_JOB_NOW
#   HQ_JOB_PROBE_CLAUDE_CRED, HQ_JOB_PROBE_CODEX_AUTH (auth paths; shared with probe)
#   HQ_JOB_RUN_SKIP_EXEC=1  — acquire lock + write marker/logs without calling CLI
#   HQ_JOB_NOTIFY_BIN, HQ_JOB_REMEDIATE_BIN, HQ_JOB_RUN_NO_NOTIFY=1, HQ_JOB_RUN_NO_INGEST=1
#   HQ_JOB_RUN_CURL, HQ_PRO_API_URL, OUTPOST_USER_ID, OUTPOST_INSTANCE_TOKEN
#
# Exit: 0 success or intentional auth/cwd skip; 1 agent/job failure; 2 usage/config;
#       124 timeout (GNU timeout convention when available).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="${HQ_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/hook-lib.sh"
NOTIFY_BIN="${HQ_JOB_NOTIFY_BIN:-$SCRIPT_DIR/hq-job-notify.sh}"
REMEDIATE_BIN="${HQ_JOB_REMEDIATE_BIN:-$SCRIPT_DIR/hq-job-remediate.sh}"

JOB_TARGET=""
JOB_ID_ARG=""

usage() {
  sed -n '3,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
  echo "hq-job-run: $*" >&2
  exit 2
}

log() {
  echo "hq-job-run: $*" >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --hq-root)
      HQ_ROOT="${2:-}"
      [ -n "$HQ_ROOT" ] || die "--hq-root requires a directory"
      shift 2
      ;;
    --job-id)
      JOB_ID_ARG="${2:-}"
      [ -n "$JOB_ID_ARG" ] || die "--job-id requires a value"
      shift 2
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
      if [ -n "$JOB_TARGET" ]; then
        die "unexpected argument: $1"
      fi
      JOB_TARGET="$1"
      shift
      ;;
  esac
done

command -v yq >/dev/null 2>&1 || die "yq is required (mikefarah/yq)"
command -v jq >/dev/null 2>&1 || die "jq is required"

iso_now() {
  if [ -n "${HQ_JOB_NOW:-}" ]; then
    printf '%s' "$HQ_JOB_NOW"
    return
  fi
  date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u +"%Y-%m-%dT%H:%M:%S+00:00"
}

epoch_now() {
  date -u +%s 2>/dev/null || date +%s
}

claude_cred_path() {
  printf '%s' "${HQ_JOB_PROBE_CLAUDE_CRED:-${HOME}/.claude/.credentials.json}"
}

codex_auth_path() {
  printf '%s' "${HQ_JOB_PROBE_CODEX_AUTH:-${HOME}/.codex/auth.json}"
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

resolve_job_file() {
  if [ -n "$JOB_ID_ARG" ]; then
    find_job_file_by_id "$JOB_ID_ARG" || die "job id not found: $JOB_ID_ARG"
    return
  fi
  if [ -z "$JOB_TARGET" ]; then
    die "usage: hq-job-run.sh --job-id <id> | <job.yaml>"
  fi
  if [ -f "$JOB_TARGET" ]; then
    printf '%s' "$JOB_TARGET"
    return
  fi
  if [ -f "$HQ_ROOT/$JOB_TARGET" ]; then
    printf '%s' "$HQ_ROOT/$JOB_TARGET"
    return
  fi
  find_job_file_by_id "$JOB_TARGET" || die "job not found: $JOB_TARGET"
}

check_runtime_auth() {
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

build_prompt() {
  local job_file="$1"
  local prompt skill
  prompt="$(yq -r '.exec.prompt // ""' "$job_file")"
  skill="$(yq -r '.exec.skill // ""' "$job_file")"
  if [ -n "$prompt" ] && [ "$prompt" != "null" ]; then
    printf '%s' "$prompt"
    return
  fi
  if [ -n "$skill" ] && [ "$skill" != "null" ]; then
    local args_json
    args_json="$(yq -o=json -I=0 '.exec.args // {}' "$job_file" 2>/dev/null || echo '{}')"
    printf 'Execute the HQ skill "%s" unattended with these args (JSON): %s. Follow the skill instructions exactly and produce a concise completion summary.' \
      "$skill" "$args_json"
    return
  fi
  die "job missing exec.prompt and exec.skill: $job_file"
}

append_meter_marker() {
  local job_id="$1" runtime="$2" started="$3" ended="$4" exit_status="$5" duration="$6" skip_reason="${7:-}"
  local dir="${HQ_JOB_METER_DIR:-${HOME}/.hq/jobs/meters}"
  mkdir -p "$dir"
  local line
  line="$(jq -nc \
    --arg schema "hq.outpost.job-run/v1" \
    --arg kind "scheduled-job-run" \
    --arg job_id "$job_id" \
    --arg runtime "$runtime" \
    --arg started_at "$started" \
    --arg ended_at "$ended" \
    --argjson exit_status "$exit_status" \
    --argjson duration_seconds "$duration" \
    --arg outpost_id "${OUTPOST_ID:-}" \
    --arg skip_reason "$skip_reason" \
    '{
      schema: $schema,
      kind: $kind,
      job_id: $job_id,
      runtime: $runtime,
      started_at: $started_at,
      ended_at: $ended_at,
      exit_status: $exit_status,
      duration_seconds: $duration_seconds
    }
    + (if $outpost_id != "" then {outpost_id: $outpost_id} else {} end)
    + (if $skip_reason != "" then {skip_reason: $skip_reason} else {} end)')"
  printf '%s\n' "$line" >>"$dir/runs.jsonl"
  chmod 600 "$dir/runs.jsonl" 2>/dev/null || true
}

api_base() {
  local base
  base="${HQ_PRO_API_URL:-${HQ_API_URL:-${HQ_VAULT_API_URL:-https://hqapi.hq.computer}}}"
  base="${base%/}"
  printf '%s' "$base"
}

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

# Classify exit + log tail → auth|secrets|timeout|agent_error|infra
classify_failure() {
  local exit_code="$1" log_file="$2" auth_hint="${3:-}"
  if [ -n "$auth_hint" ] && [ "$auth_hint" != "ok" ]; then
    printf 'auth'
    return
  fi
  if [ "$exit_code" -eq 124 ] || [ "$exit_code" -eq 137 ]; then
    printf 'timeout'
    return
  fi
  local tail_txt=""
  if [ -n "$log_file" ] && [ -f "$log_file" ]; then
    tail_txt="$(tail -n 80 "$log_file" 2>/dev/null || true)"
  fi
  local lower
  lower="$(printf '%s' "$tail_txt" | tr '[:upper:]' '[:lower:]')"

  if printf '%s' "$lower" | grep -Eq \
    'not logged in|please log in|authentication (failed|required)|unauthorized|401|invalid.*(token|credential)|credentials? (missing|expired|invalid)|device.?code|login required'; then
    printf 'auth'
    return
  fi
  if printf '%s' "$lower" | grep -Eq \
    'secret.*(not found|missing|denied|not visible|not shared)|hq secrets.*(fail|error|denied)|missing vault|access denied.*secret'; then
    printf 'secrets'
    return
  fi
  # Avoid matching job metadata like timeout_seconds=N in the log header.
  if printf '%s' "$lower" | grep -Eq \
    '(^|[^_])timed out|command timed out|deadline exceeded|killed by timeout|exit[=:][[:space:]]*124\b'; then
    printf 'timeout'
    return
  fi
  if printf '%s' "$lower" | grep -Eq \
    'connection (refused|reset|timed out)|network is unreachable|temporary failure|econnreset|enotfound|no space left|i/o error|transport error|dns (fail|error)|http[/ ]*(502|503|504)|statusingesterror|api unreachable'; then
    printf 'infra'
    return
  fi
  if [ "$exit_code" -eq 0 ]; then
    printf ''
    return
  fi
  printf 'agent_error'
}

next_action_for_class() {
  local fc="$1" runtime="${2:-}"
  case "$fc" in
    auth)
      printf 're-login on Outpost (device code) for %s' "${runtime:-the runtime CLI}"
      ;;
    secrets)
      printf 'share the missing secret to this Outpost (hq secrets share KEY) then re-probe'
      ;;
    timeout)
      printf 'raise timeout_seconds or split the job work'
      ;;
    infra)
      printf 'check Outpost disk/network; job will self-retry once on transient infra'
      ;;
    agent_error)
      printf 'inspect the job log and fix the prompt/skill'
      ;;
    *)
      printf ''
      ;;
  esac
}

# POST kind=run ingest. Never fails the job run.
ingest_run_status() {
  local job_id="$1" run_at="$2" run_id="$3" last_exit="$4" failure_class="$5" next_actions_json="$6"
  if [ "${HQ_JOB_RUN_NO_INGEST:-}" = "1" ]; then
    log "ingest skipped (HQ_JOB_RUN_NO_INGEST=1)"
    return 0
  fi
  if ! resolve_box_identity; then
    log "run status ingest skipped — missing Outpost identity"
    return 0
  fi
  local payload fc_json
  if [ -z "$failure_class" ] || [ "$failure_class" = "null" ]; then
    fc_json='null'
  else
    fc_json="$(jq -nc --arg f "$failure_class" '$f')"
  fi
  payload="$(jq -nc \
    --arg userId "$OUTPOST_USER_ID" \
    --arg jobId "$job_id" \
    --arg run_at "$run_at" \
    --arg event_id "$run_id" \
    --arg run_id "$run_id" \
    --argjson last_exit "$last_exit" \
    --argjson failure_class "$fc_json" \
    --argjson next_actions "$next_actions_json" \
    --arg outpostId "${OUTPOST_ID:-}" \
    '{
      userId: $userId,
      jobId: $jobId,
      kind: "run",
      run_at: $run_at,
      event_id: $event_id,
      run_id: $run_id,
      last_exit: $last_exit,
      failure_class: $failure_class,
      next_actions: $next_actions
    } + (if $outpostId != "" then {outpostId: $outpostId} else {} end)')"

  local curl_bin="${HQ_JOB_RUN_CURL:-curl}"
  local url tmp_body tmp_hdr http=0
  url="$(api_base)/outpost/internal/jobs-status"
  if ! command -v "$curl_bin" >/dev/null 2>&1; then
    log "run status ingest skipped — curl not found"
    return 0
  fi
  tmp_body="$(mktemp "${TMPDIR:-/tmp}/hq-job-run-ingest-body.XXXXXX")"
  tmp_hdr="$(mktemp "${TMPDIR:-/tmp}/hq-job-run-ingest-hdr.XXXXXX")"
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
  fi
  rm -f "$tmp_body" "$tmp_hdr"
  if [ "$http" -ge 200 ] && [ "$http" -lt 300 ]; then
    log "run status ingested job=$job_id failure_class=${failure_class:-null} http=$http"
  else
    log "run status ingest failed job=$job_id http=$http (logged; not failing run)"
  fi
  return 0
}

call_notify() {
  local job_id="$1" job_name="$2" outcome="$3" summary="$4" duration="$5" log_path="$6"
  local failure_class="${7:-}" next_action="${8:-}" owner="${9:-}" notify_mode="${10:-profile}"
  if [ "${HQ_JOB_RUN_NO_NOTIFY:-}" = "1" ]; then
    log "notify skipped (HQ_JOB_RUN_NO_NOTIFY=1)"
    return 0
  fi
  if [ ! -x "$NOTIFY_BIN" ] && [ -f "$NOTIFY_BIN" ]; then
    chmod +x "$NOTIFY_BIN" 2>/dev/null || true
  fi
  if [ ! -f "$NOTIFY_BIN" ]; then
    log "notify skipped — missing $NOTIFY_BIN"
    return 0
  fi
  set +e
  bash "$NOTIFY_BIN" \
    --hq-root "$HQ_ROOT" \
    --job-id "$job_id" \
    --job-name "$job_name" \
    --outcome "$outcome" \
    --summary "$summary" \
    --duration "$duration" \
    --log-path "$log_path" \
    --failure-class "$failure_class" \
    --next-action "$next_action" \
    --owner "$owner" \
    --notify "$notify_mode" \
    >>"$log_path" 2>&1
  local nrc=$?
  set -e
  if [ "$nrc" -ne 0 ]; then
    log "notify helper exited $nrc (ignored)"
  fi
  return 0
}

call_remediate() {
  local failure_class="$1" job_id="$2" company="$3"
  if [ ! -x "$REMEDIATE_BIN" ] && [ -f "$REMEDIATE_BIN" ]; then
    chmod +x "$REMEDIATE_BIN" 2>/dev/null || true
  fi
  if [ ! -f "$REMEDIATE_BIN" ]; then
    echo '{"retry_recommended":false,"attempted":false,"notes":"remediate missing"}'
    return 0
  fi
  local out
  set +e
  out="$(
    HQ_JOB_REMEDIATE_LOG="${LOG_FILE:-/dev/null}" \
      bash "$REMEDIATE_BIN" \
        --hq-root "$HQ_ROOT" \
        --failure-class "$failure_class" \
        --job-id "$job_id" \
        --company "$company" 2>>"${LOG_FILE:-/dev/null}"
  )"
  local rrc=$?
  set -e
  if [ "$rrc" -ne 0 ] || [ -z "$out" ]; then
    echo '{"retry_recommended":false,"attempted":false,"notes":"remediate failed"}'
    return 0
  fi
  printf '%s' "$out"
}

# --- resolve job ---
JOB_FILE="$(resolve_job_file)"
[ -f "$JOB_FILE" ] || die "job file missing: $JOB_FILE"

JOB_ID="$(yq -r '.id // ""' "$JOB_FILE")"
JOB_NAME="$(yq -r '.name // .id // ""' "$JOB_FILE")"
RUNTIME="$(yq -r '.runtime // ""' "$JOB_FILE")"
TIMEOUT_SEC="$(yq -r '.timeout_seconds // 600' "$JOB_FILE")"
CWD_REL="$(yq -r '.cwd // .requirements.cwd // ""' "$JOB_FILE")"
COMPANY="$(yq -r '.requirements.company // ""' "$JOB_FILE")"
OWNER="$(yq -r '.owner // ""' "$JOB_FILE")"
NOTIFY_MODE="$(yq -r '.notify // "profile"' "$JOB_FILE")"
ENABLED="$(yq -o=json '.' "$JOB_FILE" | jq -r 'if has("enabled") then (.enabled|tostring) else "true" end')"

[ -n "$JOB_ID" ] && [ "$JOB_ID" != "null" ] || die "job missing id: $JOB_FILE"
[ -n "$RUNTIME" ] && [ "$RUNTIME" != "null" ] || die "job missing runtime: $JOB_FILE"
[ -n "$JOB_NAME" ] || JOB_NAME="$JOB_ID"
[ -n "$NOTIFY_MODE" ] && [ "$NOTIFY_MODE" != "null" ] || NOTIFY_MODE="profile"

case "$TIMEOUT_SEC" in
  ''|*[!0-9]*) TIMEOUT_SEC=600 ;;
esac
if [ "$TIMEOUT_SEC" -lt 60 ]; then TIMEOUT_SEC=60; fi
if [ "$TIMEOUT_SEC" -gt 14400 ]; then TIMEOUT_SEC=14400; fi

if [ "$ENABLED" = "false" ] || [ "$ENABLED" = "False" ] || [ "$ENABLED" = "0" ]; then
  log "skip job $JOB_ID — enabled=false"
  exit 0
fi

LOG_BASE="${HQ_JOB_LOG_DIR:-${HOME}/.hq/jobs/logs}"
LOG_DIR="$LOG_BASE/$JOB_ID"
mkdir -p "$LOG_DIR"
LOCK_PATH="${HQ_JOB_LOCK:-${HOME}/.hq/jobs/run.lock}"
mkdir -p "$(dirname "$LOCK_PATH")"

FLOCK_BIN="${HQ_JOB_FLOCK_BIN:-}"
if [ -z "$FLOCK_BIN" ]; then
  command -v flock >/dev/null 2>&1 || die "Outpost/Linux requires util-linux flock(1) for serialized job runs"
  FLOCK_BIN="$(command -v flock)"
fi
TIMEOUT_BIN="${HQ_JOB_TIMEOUT_BIN:-}"
if [ -z "$TIMEOUT_BIN" ]; then
  if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN="gtimeout"
  else
    TIMEOUT_BIN=""
  fi
fi

RUN_STAMP="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%d%H%M%S)"
LOG_FILE="$LOG_DIR/${RUN_STAMP}.log"
STATUS_FILE="$LOG_DIR/${RUN_STAMP}.status"

# Serialize all scheduled runs on this box.
exec 9>"$LOCK_PATH"
if ! "$FLOCK_BIN" -x 9; then
  die "failed to acquire global run lock: $LOCK_PATH"
fi

STARTED_AT="$(iso_now)"
STARTED_EPOCH="$(epoch_now)"
SKIP_REASON=""
EXIT_CODE=0

{
  echo "=== hq-job-run $JOB_ID ==="
  echo "started_at=$STARTED_AT"
  echo "runtime=$RUNTIME"
  echo "timeout_seconds=$TIMEOUT_SEC"
  echo "job_file=$JOB_FILE"
  echo "hq_root=$HQ_ROOT"
} >>"$LOG_FILE"

AUTH_STATUS="$(check_runtime_auth "$RUNTIME" || true)"
if [ "$AUTH_STATUS" != "ok" ]; then
  case "$AUTH_STATUS" in
    no_cli)
      SKIP_REASON="runtime CLI '$RUNTIME' not installed on PATH — skip (re-login/install on Outpost)"
      ;;
    missing)
      SKIP_REASON="runtime CLI '$RUNTIME' not authenticated on Outpost (cached credentials missing) — skip"
      ;;
    *)
      SKIP_REASON="unsupported or unknown runtime '$RUNTIME' — skip"
      ;;
  esac
  {
    echo "skip_reason=$SKIP_REASON"
    echo "auth_status=$AUTH_STATUS"
    echo "failure_class=auth"
  } >>"$LOG_FILE"
  log "$SKIP_REASON"
  ENDED_AT="$(iso_now)"
  ENDED_EPOCH="$(epoch_now)"
  DUR=$((ENDED_EPOCH - STARTED_EPOCH))
  [ "$DUR" -ge 0 ] || DUR=0
  printf 'exit=0\nskip_reason=%s\nfailure_class=auth\nstarted_at=%s\nended_at=%s\n' \
    "$SKIP_REASON" "$STARTED_AT" "$ENDED_AT" >"$STATUS_FILE"
  append_meter_marker "$JOB_ID" "$RUNTIME" "$STARTED_AT" "$ENDED_AT" 0 "$DUR" "$SKIP_REASON"

  # Bounded remediate: Cognito refresh only — never device-login loop.
  REM_OUT="$(call_remediate auth "$JOB_ID" "$COMPANY")"
  echo "remediate=$REM_OUT" >>"$LOG_FILE"
  NEXT_ACT="$(printf '%s' "$REM_OUT" | jq -r '.next_action // empty')"
  [ -n "$NEXT_ACT" ] || NEXT_ACT="$(next_action_for_class auth "$RUNTIME")"
  NA_JSON="$(jq -nc --arg a "$NEXT_ACT" 'if $a == "" then [] else [$a] end')"
  RUN_ID="run-${JOB_ID}-${RUN_STAMP}-authskip"
  ingest_run_status "$JOB_ID" "$ENDED_AT" "$RUN_ID" 1 "auth" "$NA_JSON"
  call_notify "$JOB_ID" "$JOB_NAME" "failed" "$SKIP_REASON" "$DUR" "$LOG_FILE" \
    "auth" "$NEXT_ACT" "$OWNER" "$NOTIFY_MODE"
  exit 0
fi

# Working directory — must resolve under HQ_ROOT (no absolute / no .. escape)
RUN_CWD="$HQ_ROOT"
if [ -n "$CWD_REL" ] && [ "$CWD_REL" != "null" ]; then
  case "$CWD_REL" in
    /*)
      SKIP_REASON="cwd absolute not allowed: $CWD_REL — skip"
      log "$SKIP_REASON"
      {
        echo "skip_reason=$SKIP_REASON"
        echo "failure_class=infra"
      } >>"$LOG_FILE"
      ENDED_AT="$(iso_now)"
      ENDED_EPOCH="$(epoch_now)"
      DUR=$((ENDED_EPOCH - STARTED_EPOCH))
      [ "$DUR" -ge 0 ] || DUR=0
      printf 'exit=0\nskip_reason=%s\nfailure_class=infra\nstarted_at=%s\nended_at=%s\n' \
        "$SKIP_REASON" "$STARTED_AT" "$ENDED_AT" >"$STATUS_FILE"
      append_meter_marker "$JOB_ID" "$RUNTIME" "$STARTED_AT" "$ENDED_AT" 0 "$DUR" "$SKIP_REASON"
      NEXT_ACT="fix job cwd to an HQ-root-relative path (no absolute, no '..')"
      NA_JSON="$(jq -nc --arg a "$NEXT_ACT" '[$a]')"
      RUN_ID="run-${JOB_ID}-${RUN_STAMP}-cwd"
      ingest_run_status "$JOB_ID" "$ENDED_AT" "$RUN_ID" 1 "infra" "$NA_JSON"
      call_notify "$JOB_ID" "$JOB_NAME" "blocked" "$SKIP_REASON" "$DUR" "$LOG_FILE" \
        "infra" "$NEXT_ACT" "$OWNER" "$NOTIFY_MODE"
      exit 0
      ;;
  esac
  _cwd_part=""
  _old_ifs="$IFS"
  IFS='/'
  # shellcheck disable=SC2086
  for _cwd_part in $CWD_REL; do
    if [ "$_cwd_part" = ".." ]; then
      IFS="$_old_ifs"
      SKIP_REASON="cwd contains '..': $CWD_REL — skip"
      log "$SKIP_REASON"
      {
        echo "skip_reason=$SKIP_REASON"
        echo "failure_class=infra"
      } >>"$LOG_FILE"
      ENDED_AT="$(iso_now)"
      ENDED_EPOCH="$(epoch_now)"
      DUR=$((ENDED_EPOCH - STARTED_EPOCH))
      [ "$DUR" -ge 0 ] || DUR=0
      printf 'exit=0\nskip_reason=%s\nfailure_class=infra\nstarted_at=%s\nended_at=%s\n' \
        "$SKIP_REASON" "$STARTED_AT" "$ENDED_AT" >"$STATUS_FILE"
      append_meter_marker "$JOB_ID" "$RUNTIME" "$STARTED_AT" "$ENDED_AT" 0 "$DUR" "$SKIP_REASON"
      NEXT_ACT="fix job cwd to an HQ-root-relative path without '..'"
      NA_JSON="$(jq -nc --arg a "$NEXT_ACT" '[$a]')"
      RUN_ID="run-${JOB_ID}-${RUN_STAMP}-cwd"
      ingest_run_status "$JOB_ID" "$ENDED_AT" "$RUN_ID" 1 "infra" "$NA_JSON"
      call_notify "$JOB_ID" "$JOB_NAME" "blocked" "$SKIP_REASON" "$DUR" "$LOG_FILE" \
        "infra" "$NEXT_ACT" "$OWNER" "$NOTIFY_MODE"
      exit 0
    fi
  done
  IFS="$_old_ifs"
  HQ_CANON="$(realpath -m "$HQ_ROOT" 2>/dev/null || realpath "$HQ_ROOT" 2>/dev/null || true)"
  RUN_CWD="$(realpath -m "$HQ_ROOT/$CWD_REL" 2>/dev/null || true)"
  if [ -z "$RUN_CWD" ] && [ -d "$HQ_ROOT/$CWD_REL" ]; then
    RUN_CWD="$(realpath "$HQ_ROOT/$CWD_REL" 2>/dev/null || true)"
  fi
  if [ -z "$HQ_CANON" ] || [ -z "$RUN_CWD" ]; then
    HQ_CANON="$(hq_normpath "$HQ_ROOT")"
    RUN_CWD="$(hq_normpath "$HQ_ROOT/$CWD_REL")"
  fi
  case "$RUN_CWD" in
    "$HQ_CANON"|"$HQ_CANON"/*) ;;
    *)
      SKIP_REASON="cwd escapes HQ_ROOT: $CWD_REL → $RUN_CWD — skip"
      log "$SKIP_REASON"
      {
        echo "skip_reason=$SKIP_REASON"
        echo "failure_class=infra"
      } >>"$LOG_FILE"
      ENDED_AT="$(iso_now)"
      ENDED_EPOCH="$(epoch_now)"
      DUR=$((ENDED_EPOCH - STARTED_EPOCH))
      [ "$DUR" -ge 0 ] || DUR=0
      printf 'exit=0\nskip_reason=%s\nfailure_class=infra\nstarted_at=%s\nended_at=%s\n' \
        "$SKIP_REASON" "$STARTED_AT" "$ENDED_AT" >"$STATUS_FILE"
      append_meter_marker "$JOB_ID" "$RUNTIME" "$STARTED_AT" "$ENDED_AT" 0 "$DUR" "$SKIP_REASON"
      NEXT_ACT="fix job cwd to stay under HQ root"
      NA_JSON="$(jq -nc --arg a "$NEXT_ACT" '[$a]')"
      RUN_ID="run-${JOB_ID}-${RUN_STAMP}-cwd"
      ingest_run_status "$JOB_ID" "$ENDED_AT" "$RUN_ID" 1 "infra" "$NA_JSON"
      call_notify "$JOB_ID" "$JOB_NAME" "blocked" "$SKIP_REASON" "$DUR" "$LOG_FILE" \
        "infra" "$NEXT_ACT" "$OWNER" "$NOTIFY_MODE"
      exit 0
      ;;
  esac
fi
if [ ! -d "$RUN_CWD" ]; then
  SKIP_REASON="cwd missing: $RUN_CWD — skip"
  log "$SKIP_REASON"
  {
    echo "skip_reason=$SKIP_REASON"
    echo "failure_class=infra"
  } >>"$LOG_FILE"
  ENDED_AT="$(iso_now)"
  ENDED_EPOCH="$(epoch_now)"
  DUR=$((ENDED_EPOCH - STARTED_EPOCH))
  [ "$DUR" -ge 0 ] || DUR=0
  printf 'exit=0\nskip_reason=%s\nfailure_class=infra\nstarted_at=%s\nended_at=%s\n' \
    "$SKIP_REASON" "$STARTED_AT" "$ENDED_AT" >"$STATUS_FILE"
  append_meter_marker "$JOB_ID" "$RUNTIME" "$STARTED_AT" "$ENDED_AT" 0 "$DUR" "$SKIP_REASON"
  NEXT_ACT="create missing cwd on Outpost: $RUN_CWD"
  NA_JSON="$(jq -nc --arg a "$NEXT_ACT" '[$a]')"
  RUN_ID="run-${JOB_ID}-${RUN_STAMP}-cwd"
  ingest_run_status "$JOB_ID" "$ENDED_AT" "$RUN_ID" 1 "infra" "$NA_JSON"
  call_notify "$JOB_ID" "$JOB_NAME" "blocked" "$SKIP_REASON" "$DUR" "$LOG_FILE" \
    "infra" "$NEXT_ACT" "$OWNER" "$NOTIFY_MODE"
  exit 0
fi

PROMPT_TEXT="$(build_prompt "$JOB_FILE")"

# Build secret name list for hq secrets exec allowlist injection.
SECRET_NAMES=()
SECRET_COUNT="$(yq -r '.requirements.secrets // [] | length' "$JOB_FILE")"
if [ "$SECRET_COUNT" != "null" ] && [ "${SECRET_COUNT:-0}" -gt 0 ] 2>/dev/null; then
  i=0
  while [ "$i" -lt "$SECRET_COUNT" ]; do
    sn="$(yq -r ".requirements.secrets[$i]" "$JOB_FILE")"
    i=$((i + 1))
    [ -n "$sn" ] && [ "$sn" != "null" ] || continue
    SECRET_NAMES+=("$sn")
  done
fi

run_agent() {
  local cmd_rc=0
  if [ "${HQ_JOB_RUN_SKIP_EXEC:-}" = "1" ]; then
    echo "(HQ_JOB_RUN_SKIP_EXEC=1 — not invoking runtime CLI)" >>"$LOG_FILE"
    return 0
  fi

  local -a agent_cmd
  case "$RUNTIME" in
    claude)
      agent_cmd=(claude -p "$PROMPT_TEXT" --output-format text --permission-mode bypassPermissions)
      ;;
    codex)
      # Spike-validated flags on codex-cli 0.147 (NOT --ask-for-approval never).
      agent_cmd=(codex exec -s workspace-write --skip-git-repo-check -C "$RUN_CWD" "$PROMPT_TEXT")
      ;;
    *)
      echo "unknown runtime: $RUNTIME" >>"$LOG_FILE"
      return 2
      ;;
  esac

  local -a wrap_cmd=()
  if [ -n "$TIMEOUT_BIN" ]; then
    wrap_cmd=("$TIMEOUT_BIN" --signal=TERM --kill-after=15s "${TIMEOUT_SEC}s")
  fi

  # Inject only confirmed requirements.secrets[] via hq secrets exec.
  # CLI shape: hq secrets [--company S|--personal] exec --only K1,K2 -- <cmd>
  if [ "${#SECRET_NAMES[@]}" -gt 0 ] && command -v hq >/dev/null 2>&1; then
    local only_csv=""
    local sn
    for sn in "${SECRET_NAMES[@]}"; do
      if [ -z "$only_csv" ]; then
        only_csv="$sn"
      else
        only_csv="${only_csv},${sn}"
      fi
    done
    local -a secrets_cmd=(hq secrets)
    if [ -n "$COMPANY" ] && [ "$COMPANY" != "null" ]; then
      secrets_cmd+=(--company "$COMPANY")
    else
      secrets_cmd+=(--personal)
    fi
    secrets_cmd+=(exec --only "$only_csv" --script "${BASH_SOURCE[0]}" --)
    (
      cd "$RUN_CWD"
      if [ "${#wrap_cmd[@]}" -gt 0 ]; then
        "${secrets_cmd[@]}" "${wrap_cmd[@]}" "${agent_cmd[@]}"
      else
        "${secrets_cmd[@]}" "${agent_cmd[@]}"
      fi
    ) >>"$LOG_FILE" 2>&1 || cmd_rc=$?
  else
    if [ "${#SECRET_NAMES[@]}" -gt 0 ]; then
      echo "warning: requirements.secrets set but hq CLI missing — running without secrets exec" >>"$LOG_FILE"
    fi
    (
      cd "$RUN_CWD"
      if [ "${#wrap_cmd[@]}" -gt 0 ]; then
        "${wrap_cmd[@]}" "${agent_cmd[@]}"
      else
        "${agent_cmd[@]}"
      fi
    ) >>"$LOG_FILE" 2>&1 || cmd_rc=$?
  fi
  return "$cmd_rc"
}

RETRIED=0
FAILURE_CLASS=""
NEXT_ACT=""

set +e
run_agent
EXIT_CODE=$?
set -e

finalize_timestamps() {
  ENDED_AT="$(iso_now)"
  ENDED_EPOCH="$(epoch_now)"
  DUR=$((ENDED_EPOCH - STARTED_EPOCH))
  [ "$DUR" -ge 0 ] || DUR=0
}

if [ "$EXIT_CODE" -ne 0 ]; then
  FAILURE_CLASS="$(classify_failure "$EXIT_CODE" "$LOG_FILE" "")"
  echo "failure_class=$FAILURE_CLASS" >>"$LOG_FILE"
  REM_OUT="$(call_remediate "$FAILURE_CLASS" "$JOB_ID" "$COMPANY")"
  echo "remediate=$REM_OUT" >>"$LOG_FILE"
  NEXT_ACT="$(printf '%s' "$REM_OUT" | jq -r '.next_action // empty')"
  [ -n "$NEXT_ACT" ] || NEXT_ACT="$(next_action_for_class "$FAILURE_CLASS" "$RUNTIME")"
  RETRY_REC="$(printf '%s' "$REM_OUT" | jq -r '.retry_recommended // false')"
  if [ "$RETRY_REC" = "true" ] && [ "$RETRIED" -eq 0 ]; then
    RETRIED=1
    echo "remediate_retry=1" >>"$LOG_FILE"
    log "self-remediate recommended retry for $FAILURE_CLASS — retrying once"
    set +e
    run_agent
    EXIT_CODE=$?
    set -e
    if [ "$EXIT_CODE" -ne 0 ]; then
      FAILURE_CLASS="$(classify_failure "$EXIT_CODE" "$LOG_FILE" "")"
      echo "failure_class_after_retry=$FAILURE_CLASS" >>"$LOG_FILE"
      NEXT_ACT="$(next_action_for_class "$FAILURE_CLASS" "$RUNTIME")"
    else
      FAILURE_CLASS=""
      NEXT_ACT=""
    fi
  fi
fi

finalize_timestamps

{
  echo "ended_at=$ENDED_AT"
  echo "exit=$EXIT_CODE"
  echo "duration_seconds=$DUR"
  echo "retried=$RETRIED"
  [ -n "$FAILURE_CLASS" ] && echo "failure_class=$FAILURE_CLASS"
} >>"$LOG_FILE"

printf 'exit=%s\nstarted_at=%s\nended_at=%s\nduration_seconds=%s\nfailure_class=%s\nretried=%s\n' \
  "$EXIT_CODE" "$STARTED_AT" "$ENDED_AT" "$DUR" "${FAILURE_CLASS:-}" "$RETRIED" >"$STATUS_FILE"

append_meter_marker "$JOB_ID" "$RUNTIME" "$STARTED_AT" "$ENDED_AT" "$EXIT_CODE" "$DUR" ""

RUN_ID="run-${JOB_ID}-${RUN_STAMP}"
if [ "$EXIT_CODE" -eq 0 ]; then
  NA_JSON='[]'
  ingest_run_status "$JOB_ID" "$ENDED_AT" "$RUN_ID" 0 "null" "$NA_JSON"
  SUMMARY="completed ok"
  [ "$RETRIED" -eq 1 ] && SUMMARY="completed ok after self-remediation retry"
  call_notify "$JOB_ID" "$JOB_NAME" "ok" "$SUMMARY" "$DUR" "$LOG_FILE" \
    "" "" "$OWNER" "$NOTIFY_MODE"
  log "job $JOB_ID completed ok (${DUR}s)"
  exit 0
fi

NA_JSON="$(jq -nc --arg a "$NEXT_ACT" 'if $a == "" then [] else [$a] end')"
# Cap last_exit to 0–255 for ingest; preserve real exit for process.
INGEST_EXIT="$EXIT_CODE"
if [ "$INGEST_EXIT" -lt 0 ]; then INGEST_EXIT=1; fi
if [ "$INGEST_EXIT" -gt 255 ]; then INGEST_EXIT=255; fi
ingest_run_status "$JOB_ID" "$ENDED_AT" "$RUN_ID" "$INGEST_EXIT" "$FAILURE_CLASS" "$NA_JSON"
SUMMARY="exit=$EXIT_CODE class=$FAILURE_CLASS"
call_notify "$JOB_ID" "$JOB_NAME" "failed" "$SUMMARY" "$DUR" "$LOG_FILE" \
  "$FAILURE_CLASS" "$NEXT_ACT" "$OWNER" "$NOTIFY_MODE"

log "job $JOB_ID failed exit=$EXIT_CODE class=$FAILURE_CLASS (${DUR}s) log=$LOG_FILE"
exit "$EXIT_CODE"
