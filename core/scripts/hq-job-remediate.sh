#!/usr/bin/env bash
# hq-core: public
# hq-job-remediate.sh — bounded self-remediation for Outpost scheduled jobs (US-006).
#
# Allowlist (v1):
#   - Cognito / HQ token refresh via `hq auth refresh` when available
#   - one `hq sync pull` (personal or --company)
#   - single immediate retry for transient infra (signaled via retry_recommended)
# Always-human (never auto-looped):
#   - device re-login (Claude/Codex CLI)
#   - secret share / missing vault grants
#
# Usage:
#   core/scripts/hq-job-remediate.sh --failure-class <class> [--job-id <id>] \
#     [--company <slug>] [--hq-root <dir>]
#
# Env / overrides (tests):
#   HQ_ROOT, HQ_JOB_REMEDIATE_AUTH_REFRESH_CMD, HQ_JOB_REMEDIATE_SYNC_PULL_CMD
#   HQ_JOB_REMEDIATE_DRY=1 — print plan only; do not execute side effects
#
# stdout: JSON {failure_class, attempted, actions[], retry_recommended, always_human, next_action, notes}
# Exit: 0 always on successful classify/plan (even if nothing attempted); 2 usage.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="${HQ_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

FAILURE_CLASS=""
JOB_ID=""
COMPANY=""
DRY=0

usage() {
  sed -n '3,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
  echo "hq-job-remediate: $*" >&2
  exit 2
}

log() {
  echo "hq-job-remediate: $*" >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --hq-root)
      HQ_ROOT="${2:-}"
      [ -n "$HQ_ROOT" ] || die "--hq-root requires a directory"
      shift 2
      ;;
    --failure-class)
      FAILURE_CLASS="${2:-}"
      [ -n "$FAILURE_CLASS" ] || die "--failure-class requires a value"
      shift 2
      ;;
    --job-id)
      JOB_ID="${2:-}"
      [ -n "$JOB_ID" ] || die "--job-id requires a value"
      shift 2
      ;;
    --company)
      COMPANY="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY=1
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
      die "unexpected argument: $1"
      ;;
  esac
done

[ -n "$FAILURE_CLASS" ] || die "usage: hq-job-remediate.sh --failure-class <auth|secrets|timeout|agent_error|infra>"

case "$FAILURE_CLASS" in
  auth|secrets|timeout|agent_error|infra) ;;
  *)
    die "unknown failure_class: $FAILURE_CLASS (want auth|secrets|timeout|agent_error|infra)"
    ;;
esac

# Company slug: reject flag/path injection (e.g. "foo --on-conflict overwrite").
if [ -n "$COMPANY" ] && [ "$COMPANY" != "null" ]; then
  if [[ ! "$COMPANY" =~ ^[a-z0-9]([a-z0-9_-]*[a-z0-9])?$ ]]; then
    die "invalid --company slug '$COMPANY' (want lowercase kebab/underscore)"
  fi
fi

# Test/env overrides must not contain shell metacharacters; executed as argv arrays only.
assert_safe_override_cmd() {
  local cmd="$1"
  if printf '%s' "$cmd" | grep -Eq '[;|&$`()<>]'; then
    die "unsafe remediate override command rejected"
  fi
}

run_override_or_argv() {
  local label="$1"
  shift
  if [ "$#" -eq 1 ] && [[ "$1" == *" "* ]]; then
    # Single string override like "hq auth refresh" — split into argv (no eval).
    assert_safe_override_cmd "$1"
    # shellcheck disable=SC2206
    local -a argv=($1)
    run_or_dry "$label" "${argv[@]}"
  else
    run_or_dry "$label" "$@"
  fi
}

if [ "${HQ_JOB_REMEDIATE_DRY:-}" = "1" ]; then
  DRY=1
fi

ACTIONS_JSON='[]'
ATTEMPTED=0
RETRY=0
ALWAYS_HUMAN=0
NEXT_ACTION=""
NOTES=""

append_action() {
  local a="$1"
  ACTIONS_JSON="$(jq -nc --argjson cur "$ACTIONS_JSON" --arg a "$a" '$cur + [$a]')"
}

run_or_dry() {
  local label="$1"
  shift
  append_action "$label"
  if [ "$DRY" -eq 1 ]; then
    log "dry-run: would run: $*"
    return 0
  fi
  set +e
  "$@" >>"${HQ_JOB_REMEDIATE_LOG:-/dev/null}" 2>&1
  local rc=$?
  set -e
  return "$rc"
}

# --- always-human classes ----------------------------------------------------
case "$FAILURE_CLASS" in
  secrets)
    ALWAYS_HUMAN=1
    NEXT_ACTION="share the missing secret to this Outpost (hq secrets share KEY) then re-probe"
    NOTES="secret share is always-human; no self-remediation"
    jq -nc \
      --arg failure_class "$FAILURE_CLASS" \
      --arg job_id "$JOB_ID" \
      --argjson attempted "$ATTEMPTED" \
      --argjson actions "$ACTIONS_JSON" \
      --argjson retry_recommended "$RETRY" \
      --argjson always_human "$ALWAYS_HUMAN" \
      --arg next_action "$NEXT_ACTION" \
      --arg notes "$NOTES" \
      '{
        failure_class: $failure_class,
        job_id: $job_id,
        attempted: ($attempted == 1),
        actions: $actions,
        retry_recommended: ($retry_recommended == 1),
        always_human: ($always_human == 1),
        next_action: $next_action,
        notes: $notes
      }'
    exit 0
    ;;
  auth)
    # Cognito/HQ token refresh is allowlisted; device re-login is NOT.
    ALWAYS_HUMAN=1
    NEXT_ACTION="re-login on Outpost (device code) for the job runtime CLI"
    NOTES="attempt Cognito refresh if available; never loop device re-login"

    AUTH_REFRESH_CMD="${HQ_JOB_REMEDIATE_AUTH_REFRESH_CMD:-}"
    if [ -z "$AUTH_REFRESH_CMD" ]; then
      if command -v hq >/dev/null 2>&1; then
        AUTH_REFRESH_CMD="hq auth refresh"
      elif command -v hq-auth-refresh >/dev/null 2>&1; then
        AUTH_REFRESH_CMD="hq-auth-refresh"
      fi
    fi

    if [ -n "$AUTH_REFRESH_CMD" ]; then
      ATTEMPTED=1
      if run_override_or_argv "cognito_token_refresh" "$AUTH_REFRESH_CMD"; then
        NOTES="cognito refresh ok; device re-login still required if CLI creds missing"
        # Do NOT recommend retry for auth — CLI device login is the real fix.
        RETRY=0
      else
        NOTES="cognito refresh failed or unavailable; device re-login required"
      fi
    else
      NOTES="no hq auth refresh on PATH; device re-login required"
    fi

    jq -nc \
      --arg failure_class "$FAILURE_CLASS" \
      --arg job_id "$JOB_ID" \
      --argjson attempted "$ATTEMPTED" \
      --argjson actions "$ACTIONS_JSON" \
      --argjson retry_recommended "$RETRY" \
      --argjson always_human "$ALWAYS_HUMAN" \
      --arg next_action "$NEXT_ACTION" \
      --arg notes "$NOTES" \
      '{
        failure_class: $failure_class,
        job_id: $job_id,
        attempted: ($attempted == 1),
        actions: $actions,
        retry_recommended: ($retry_recommended == 1),
        always_human: ($always_human == 1),
        next_action: $next_action,
        notes: $notes
      }'
    exit 0
    ;;
  timeout)
    ALWAYS_HUMAN=0
    NEXT_ACTION="raise timeout_seconds or split the job work"
    NOTES="timeout is not self-retried in v1 (avoid thrash)"
    jq -nc \
      --arg failure_class "$FAILURE_CLASS" \
      --arg job_id "$JOB_ID" \
      --argjson attempted 0 \
      --argjson actions "$ACTIONS_JSON" \
      --argjson retry_recommended 0 \
      --argjson always_human 0 \
      --arg next_action "$NEXT_ACTION" \
      --arg notes "$NOTES" \
      '{
        failure_class: $failure_class,
        job_id: $job_id,
        attempted: false,
        actions: $actions,
        retry_recommended: false,
        always_human: false,
        next_action: $next_action,
        notes: $notes
      }'
    exit 0
    ;;
  agent_error)
    ALWAYS_HUMAN=0
    NEXT_ACTION="inspect the job log and fix the prompt/skill"
    NOTES="agent_error is not self-remediated in v1"
    jq -nc \
      --arg failure_class "$FAILURE_CLASS" \
      --arg job_id "$JOB_ID" \
      --argjson attempted 0 \
      --argjson actions "$ACTIONS_JSON" \
      --argjson retry_recommended 0 \
      --argjson always_human 0 \
      --arg next_action "$NEXT_ACTION" \
      --arg notes "$NOTES" \
      '{
        failure_class: $failure_class,
        job_id: $job_id,
        attempted: false,
        actions: $actions,
        retry_recommended: false,
        always_human: false,
        next_action: $next_action,
        notes: $notes
      }'
    exit 0
    ;;
  infra)
    ALWAYS_HUMAN=0
    NEXT_ACTION="retry after sync; if it persists, check Outpost disk/network"
    NOTES="allowlist: cognito refresh + one hq-sync pull + single retry"

    AUTH_REFRESH_CMD="${HQ_JOB_REMEDIATE_AUTH_REFRESH_CMD:-}"
    if [ -z "$AUTH_REFRESH_CMD" ]; then
      if command -v hq >/dev/null 2>&1; then
        AUTH_REFRESH_CMD="hq auth refresh"
      elif command -v hq-auth-refresh >/dev/null 2>&1; then
        AUTH_REFRESH_CMD="hq-auth-refresh"
      fi
    fi
    if [ -n "$AUTH_REFRESH_CMD" ]; then
      ATTEMPTED=1
      run_override_or_argv "cognito_token_refresh" "$AUTH_REFRESH_CMD" || true
    fi

    SYNC_OVERRIDE="${HQ_JOB_REMEDIATE_SYNC_PULL_CMD:-}"
    ATTEMPTED=1
    if [ -n "$SYNC_OVERRIDE" ]; then
      if run_override_or_argv "hq_sync_pull" "$SYNC_OVERRIDE"; then
        RETRY=1
        NOTES="sync pull ok; recommend single immediate retry"
      else
        NOTES="sync pull failed; still recommend one infra retry"
        RETRY=1
      fi
    elif command -v hq >/dev/null 2>&1; then
      if [ -n "$COMPANY" ] && [ "$COMPANY" != "null" ]; then
        if run_or_dry "hq_sync_pull" hq sync pull --company "$COMPANY" --hq-root "$HQ_ROOT"; then
          RETRY=1
          NOTES="sync pull ok; recommend single immediate retry"
        else
          NOTES="sync pull failed; still recommend one infra retry"
          RETRY=1
        fi
      else
        if run_or_dry "hq_sync_pull" hq sync pull --personal --hq-root "$HQ_ROOT"; then
          RETRY=1
          NOTES="sync pull ok; recommend single immediate retry"
        else
          NOTES="sync pull failed; still recommend one infra retry"
          RETRY=1
        fi
      fi
    else
      append_action "hq_sync_pull_unavailable"
      RETRY=1
      NOTES="hq sync pull unavailable; recommend single infra retry anyway"
    fi

    jq -nc \
      --arg failure_class "$FAILURE_CLASS" \
      --arg job_id "$JOB_ID" \
      --argjson attempted "$ATTEMPTED" \
      --argjson actions "$ACTIONS_JSON" \
      --argjson retry_recommended "$RETRY" \
      --argjson always_human 0 \
      --arg next_action "$NEXT_ACTION" \
      --arg notes "$NOTES" \
      '{
        failure_class: $failure_class,
        job_id: $job_id,
        attempted: ($attempted == 1),
        actions: $actions,
        retry_recommended: ($retry_recommended == 1),
        always_human: false,
        next_action: $next_action,
        notes: $notes
      }'
    exit 0
    ;;
esac

die "unreachable failure_class branch"
