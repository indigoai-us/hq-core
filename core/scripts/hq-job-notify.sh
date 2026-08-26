#!/usr/bin/env bash
# hq-core: public
# hq-job-notify.sh — dm-only remediation alerts for Outpost scheduled jobs (US-006).
#
# Delivers via schedule-alerts profile with v1 channel=dm only (`hq dm` to owner).
# If profile channel is slack|email|outpost-session, still deliver dm and log
# channel_unimplemented. Never targets the original /schedule create session.
#
# Escalation collapse:
#   - first failure → DM immediately
#   - consecutive failures → at most one failure DM per 24h per job
#   - recovery after failures → recovered DM
#   - success after success → ok DM (every successful run)
#
# Notify delivery failure is logged and never fails the caller (exit 0).
#
# Usage:
#   core/scripts/hq-job-notify.sh \
#     --job-id <id> --job-name <name> --outcome <ok|failed|blocked> \
#     --summary <one-line> --duration <sec> --log-path <path> \
#     [--failure-class <class>] [--next-action <text>] \
#     [--owner <email|prs_*>] [--notify <dm|none|profile>] \
#     [--hq-root <dir>]
#
# Env / overrides (tests):
#   HQ_ROOT, HOME, HQ_JOB_ALERT_DIR, HQ_JOB_NOTIFY_DM_BIN, HQ_JOB_NOTIFY_NOW_EPOCH
#   HQ_JOB_NOTIFY_COLLAPSE_SEC (default 86400)
#
# Exit: 0 always (delivery errors logged only); 2 usage.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="${HQ_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

JOB_ID=""
JOB_NAME=""
OUTCOME=""
SUMMARY=""
DURATION=""
LOG_PATH=""
FAILURE_CLASS=""
NEXT_ACTION=""
OWNER=""
NOTIFY_MODE=""

usage() {
  sed -n '3,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
  echo "hq-job-notify: $*" >&2
  exit 2
}

log() {
  echo "hq-job-notify: $*" >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --hq-root)
      HQ_ROOT="${2:-}"
      [ -n "$HQ_ROOT" ] || die "--hq-root requires a directory"
      shift 2
      ;;
    --job-id)
      JOB_ID="${2:-}"
      [ -n "$JOB_ID" ] || die "--job-id requires a value"
      shift 2
      ;;
    --job-name)
      JOB_NAME="${2:-}"
      shift 2
      ;;
    --outcome)
      OUTCOME="${2:-}"
      [ -n "$OUTCOME" ] || die "--outcome requires a value"
      shift 2
      ;;
    --summary)
      SUMMARY="${2:-}"
      shift 2
      ;;
    --duration)
      DURATION="${2:-}"
      shift 2
      ;;
    --log-path)
      LOG_PATH="${2:-}"
      shift 2
      ;;
    --failure-class)
      FAILURE_CLASS="${2:-}"
      shift 2
      ;;
    --next-action)
      NEXT_ACTION="${2:-}"
      shift 2
      ;;
    --owner)
      OWNER="${2:-}"
      shift 2
      ;;
    --notify)
      NOTIFY_MODE="${2:-}"
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
      die "unexpected argument: $1"
      ;;
  esac
done

[ -n "$JOB_ID" ] || die "usage: hq-job-notify.sh --job-id <id> --outcome <ok|failed|blocked> ..."
case "$OUTCOME" in
  ok|failed|blocked) ;;
  *) die "--outcome must be ok|failed|blocked" ;;
esac

[ -n "$JOB_NAME" ] || JOB_NAME="$JOB_ID"
[ -n "$SUMMARY" ] || SUMMARY="$OUTCOME"
[ -n "$DURATION" ] || DURATION="0"
[ -n "$LOG_PATH" ] || LOG_PATH=""

COLLAPSE_SEC="${HQ_JOB_NOTIFY_COLLAPSE_SEC:-86400}"
ALERT_BASE="${HQ_JOB_ALERT_DIR:-${HOME}/.hq/jobs/alerts}"
STATE_DIR="$ALERT_BASE/$JOB_ID"
mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/state.json"
DELIVERY_LOG="$STATE_DIR/delivery.log"

epoch_now() {
  if [ -n "${HQ_JOB_NOTIFY_NOW_EPOCH:-}" ]; then
    printf '%s' "$HQ_JOB_NOTIFY_NOW_EPOCH"
    return
  fi
  date -u +%s 2>/dev/null || date +%s
}

iso_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u +"%Y-%m-%dT%H:%M:%S+00:00"
}

read_state() {
  if [ -f "$STATE_FILE" ]; then
    cat "$STATE_FILE"
  else
    echo '{}'
  fi
}

write_state() {
  local json="$1"
  printf '%s\n' "$json" >"$STATE_FILE"
  chmod 600 "$STATE_FILE" 2>/dev/null || true
}

# Resolve notify mode + profile channel.
PROFILE_CHANNEL="dm"
PROFILE_PATH="$HQ_ROOT/personal/settings/schedule-alerts.yaml"
if [ -z "$NOTIFY_MODE" ] || [ "$NOTIFY_MODE" = "null" ]; then
  NOTIFY_MODE="profile"
fi

case "$NOTIFY_MODE" in
  none)
    log "notify=none — skipping delivery for job $JOB_ID"
    echo '{"delivered":false,"reason":"notify_none"}'
    exit 0
    ;;
  dm)
    PROFILE_CHANNEL="dm"
    ;;
  profile)
    if [ -f "$PROFILE_PATH" ] && command -v yq >/dev/null 2>&1; then
      PROFILE_CHANNEL="$(yq -r '.channel // "dm"' "$PROFILE_PATH" 2>/dev/null || echo dm)"
    else
      PROFILE_CHANNEL="dm"
    fi
    ;;
  *)
    log "unknown notify mode '$NOTIFY_MODE' — falling back to dm"
    PROFILE_CHANNEL="dm"
    ;;
esac

CHANNEL_UNIMPLEMENTED=0
case "$PROFILE_CHANNEL" in
  dm|"")
    PROFILE_CHANNEL="dm"
    ;;
  slack|email|outpost-session)
    CHANNEL_UNIMPLEMENTED=1
    log "channel_unimplemented=$PROFILE_CHANNEL — delivering dm fallback"
    PROFILE_CHANNEL="dm"
    ;;
  *)
    log "channel_unimplemented=$PROFILE_CHANNEL — delivering dm fallback"
    CHANNEL_UNIMPLEMENTED=1
    PROFILE_CHANNEL="dm"
    ;;
esac

# Resolve owner (recipient). Prefer explicit --owner, else job owner left to caller.
if [ -z "$OWNER" ] || [ "$OWNER" = "null" ]; then
  if command -v hq >/dev/null 2>&1; then
    OWNER="$(hq whoami 2>/dev/null | awk -F': ' '/^email:/{print $2; exit}' || true)"
  fi
fi
# personUid / bare UUID is not a dm target — resolve to an email when possible.
case "$OWNER" in
  *@*) ;;
  ''|null) ;;
  *)
    if command -v hq >/dev/null 2>&1; then
      _email="$(hq whoami 2>/dev/null | tr ' ' '\n' | grep -E '^[^[:space:]]+@[^[:space:]]+$' | head -1 || true)"
      if [ -n "$_email" ]; then
        log "resolved owner uid/name to email for dm"
        OWNER="$_email"
      fi
    fi
    ;;
esac
if [ -z "$OWNER" ]; then
  log "no owner recipient — cannot dm (logged only); never fails the job"
  echo '{"delivered":false,"reason":"missing_owner"}' | tee -a "$DELIVERY_LOG" >/dev/null
  # Still update local state so collapse logic stays coherent.
  :
fi

NOW_EPOCH="$(epoch_now)"
PREV="$(read_state)"
PREV_OUTCOME="$(printf '%s' "$PREV" | jq -r '.last_outcome // empty')"
PREV_FAIL_DM="$(printf '%s' "$PREV" | jq -r '.last_failure_dm_epoch // 0')"
case "$PREV_FAIL_DM" in
  ''|*[!0-9]*) PREV_FAIL_DM=0 ;;
esac

SEND_KIND=""   # ok | failed | recovered | suppressed
case "$OUTCOME" in
  ok)
    if [ "$PREV_OUTCOME" = "failed" ] || [ "$PREV_OUTCOME" = "blocked" ]; then
      SEND_KIND="recovered"
    else
      SEND_KIND="ok"
    fi
    ;;
  failed|blocked)
    if [ "$PREV_OUTCOME" = "failed" ] || [ "$PREV_OUTCOME" = "blocked" ]; then
      elapsed=$((NOW_EPOCH - PREV_FAIL_DM))
      if [ "$PREV_FAIL_DM" -gt 0 ] && [ "$elapsed" -lt "$COLLAPSE_SEC" ]; then
        SEND_KIND="suppressed"
      else
        SEND_KIND="failed"
      fi
    else
      SEND_KIND="failed"
    fi
    ;;
esac

STATUS_WORD="$OUTCOME"
case "$SEND_KIND" in
  recovered) STATUS_WORD="recovered" ;;
  suppressed)
    log "collapse: suppressing failure dm for job $JOB_ID (within ${COLLAPSE_SEC}s window)"
    NEW_STATE="$(jq -nc \
      --arg outcome "$OUTCOME" \
      --argjson now "$NOW_EPOCH" \
      --argjson last_dm "$PREV_FAIL_DM" \
      --arg updated "$(iso_now)" \
      --arg fc "$FAILURE_CLASS" \
      '{
        last_outcome: $outcome,
        last_failure_dm_epoch: $last_dm,
        last_updated_at: $updated,
        last_failure_class: $fc,
        last_delivery: "suppressed"
      }')"
    write_state "$NEW_STATE"
    jq -nc \
      --arg reason "collapsed_24h" \
      --argjson channel_unimplemented "$CHANNEL_UNIMPLEMENTED" \
      '{delivered:false, reason:$reason, channel_unimplemented:($channel_unimplemented==1)}'
    exit 0
    ;;
esac

# Build message body (no create-thread targeting — hq dm only).
CLASS_PART=""
if [ -n "$FAILURE_CLASS" ] && [ "$FAILURE_CLASS" != "null" ]; then
  CLASS_PART=" class=$FAILURE_CLASS"
fi
ACTION_PART=""
if [ -n "$NEXT_ACTION" ]; then
  ACTION_PART=" next: $NEXT_ACTION"
fi

case "$SEND_KIND" in
  ok)
    HEADLINE="Scheduled job '${JOB_NAME}' ok (${DURATION}s)"
    ;;
  recovered)
    HEADLINE="Scheduled job '${JOB_NAME}' recovered (${DURATION}s)"
    ;;
  failed)
    HEADLINE="Scheduled job '${JOB_NAME}' ${STATUS_WORD}${CLASS_PART} (${DURATION}s)"
    ;;
  *)
    HEADLINE="Scheduled job '${JOB_NAME}' ${STATUS_WORD} (${DURATION}s)"
    ;;
esac

DETAILS="$(printf 'job=%s\nstatus=%s\nclassification=%s\nsummary=%s\nduration_seconds=%s\nlog=%s%s\n' \
  "$JOB_ID" "$STATUS_WORD" "${FAILURE_CLASS:-none}" "$SUMMARY" "$DURATION" "${LOG_PATH:-none}" "$ACTION_PART")"

DELIVERED=0
DELIVER_RC=0
DM_BIN="${HQ_JOB_NOTIFY_DM_BIN:-}"
if [ -z "$DM_BIN" ]; then
  if command -v hq >/dev/null 2>&1; then
    DM_BIN="hq"
  fi
fi

if [ -z "$OWNER" ]; then
  log "skip dm send — missing owner"
  DELIVER_RC=1
elif [ -z "$DM_BIN" ]; then
  log "skip dm send — hq CLI not found"
  DELIVER_RC=1
else
  set +e
  if [ "$DM_BIN" = "hq" ]; then
    hq dm "$OWNER" "$HEADLINE" --details "$DETAILS" >>"$DELIVERY_LOG" 2>&1
    DELIVER_RC=$?
  else
    # Custom binary: invoked as <bin> <owner> <headline> <details>
    "$DM_BIN" "$OWNER" "$HEADLINE" "$DETAILS" >>"$DELIVERY_LOG" 2>&1
    DELIVER_RC=$?
  fi
  set -e
  if [ "$DELIVER_RC" -eq 0 ]; then
    DELIVERED=1
    log "dm delivered to $OWNER kind=$SEND_KIND job=$JOB_ID"
  else
    log "dm delivery failed rc=$DELIVER_RC job=$JOB_ID (logged; not failing run)"
  fi
fi

FAIL_DM_EPOCH="$PREV_FAIL_DM"
if [ "$SEND_KIND" = "failed" ] && [ "$DELIVERED" -eq 1 ]; then
  FAIL_DM_EPOCH="$NOW_EPOCH"
elif [ "$SEND_KIND" = "ok" ] || [ "$SEND_KIND" = "recovered" ]; then
  FAIL_DM_EPOCH=0
fi

NEW_STATE="$(jq -nc \
  --arg outcome "$OUTCOME" \
  --argjson now "$NOW_EPOCH" \
  --argjson last_dm "$FAIL_DM_EPOCH" \
  --arg updated "$(iso_now)" \
  --arg fc "$FAILURE_CLASS" \
  --arg kind "$SEND_KIND" \
  --argjson delivered "$DELIVERED" \
  '{
    last_outcome: $outcome,
    last_failure_dm_epoch: $last_dm,
    last_updated_at: $updated,
    last_failure_class: $fc,
    last_delivery: $kind,
    last_delivered: ($delivered == 1)
  }')"
write_state "$NEW_STATE"

jq -nc \
  --argjson delivered "$DELIVERED" \
  --arg kind "$SEND_KIND" \
  --arg owner "$OWNER" \
  --argjson channel_unimplemented "$CHANNEL_UNIMPLEMENTED" \
  --argjson deliver_rc "$DELIVER_RC" \
  '{
    delivered: ($delivered == 1),
    kind: $kind,
    owner: $owner,
    channel_unimplemented: ($channel_unimplemented == 1),
    deliver_rc: $deliver_rc
  }'
exit 0
