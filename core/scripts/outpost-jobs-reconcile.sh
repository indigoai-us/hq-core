#!/usr/bin/env bash
# hq-core: public
# outpost-jobs-reconcile.sh — registry YAML → systemd user timers (US-004).
#
# Reads personal/jobs/*.yaml and companies/*/jobs/*.yaml from the box HQ tree,
# validates each with jobs-validate.sh, and materializes disposable units:
#   ~/.config/systemd/user/hq-job-{id}.service
#   ~/.config/systemd/user/hq-job-{id}.timer
# with Persistent=true and RandomizedDelaySec. Timers are armed only when
# hq-pro jobs status readiness=ready (box cache from probe ingest, or live
# GET when available). Disabled/deleted jobs have units removed.
#
# Company-scoped jobs materialize only when job.owner matches this Outpost's
# owner identity (creator's box only in v1).
#
# Usage:
#   core/scripts/outpost-jobs-reconcile.sh [options]
#   core/scripts/outpost-jobs-reconcile.sh --after-sync   # post-sync entrypoint
#
# Options:
#   --hq-root DIR       HQ tree root (default: HQ_ROOT or repo root above core/)
#   --dry-run           Write units to unit dir / print plan; skip systemctl
#   --no-probe          Do not probe non-ready jobs
#   --probe-only        Probe non-ready jobs then exit (no unit changes)
#   --ensure-hook       Install personal/hooks/Stop/90-outpost-jobs-reconcile.sh
#   --after-sync        Alias for default reconcile + probe path (sync Stop hook)
#   -h, --help
#
# Env / overrides (tests):
#   HQ_ROOT, HOME, HQ_JOB_UNIT_DIR, HQ_JOB_SYSTEMCTL, HQ_JOB_STATUS_CACHE_DIR
#   HQ_JOB_OWNER_EMAIL, HQ_JOB_OWNER_UID, OUTPOST_USER_ID, OUTPOST_ID
#   HQ_JOB_RANDOMIZE_SEC (default 60), HQ_JOB_RECONCILE_STATE
#   HQ_PRO_API_URL / HQ_API_URL / HQ_VAULT_API_URL, HQ_ACCESS_TOKEN (optional GET)
#
# Exit: 0 success; 1 partial failures; 2 usage/config.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="${HQ_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
VALIDATE="$SCRIPT_DIR/jobs-validate.sh"
RUNNER="$SCRIPT_DIR/hq-job-run.sh"
PROBE="$SCRIPT_DIR/hq-job-probe.sh"

DRY_RUN=0
NO_PROBE=0
PROBE_ONLY=0
ENSURE_HOOK=0
AFTER_SYNC=0

usage() {
  sed -n '3,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
  echo "outpost-jobs-reconcile: $*" >&2
  exit 2
}

log() {
  echo "outpost-jobs-reconcile: $*" >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --hq-root)
      HQ_ROOT="${2:-}"
      [ -n "$HQ_ROOT" ] || die "--hq-root requires a directory"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --no-probe)
      NO_PROBE=1
      shift
      ;;
    --probe-only)
      PROBE_ONLY=1
      shift
      ;;
    --ensure-hook)
      ENSURE_HOOK=1
      shift
      ;;
    --after-sync)
      AFTER_SYNC=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      die "unexpected argument: $1"
      ;;
  esac
done

command -v yq >/dev/null 2>&1 || die "yq is required (mikefarah/yq)"
command -v jq >/dev/null 2>&1 || die "jq is required"
[ -x "$VALIDATE" ] || [ -f "$VALIDATE" ] || die "missing jobs-validate.sh"
[ -f "$RUNNER" ] || die "missing hq-job-run.sh"
[ -f "$PROBE" ] || die "missing hq-job-probe.sh"

UNIT_DIR="${HQ_JOB_UNIT_DIR:-${HOME}/.config/systemd/user}"
STATUS_CACHE_DIR="${HQ_JOB_STATUS_CACHE_DIR:-${HOME}/.hq/jobs/status-cache}"
STATE_DIR="${HQ_JOB_RECONCILE_STATE:-${HOME}/.hq/jobs/reconcile}"
SYSTEMCTL_BIN="${HQ_JOB_SYSTEMCTL:-systemctl}"
RANDOMIZE_SEC="${HQ_JOB_RANDOMIZE_SEC:-60}"
mkdir -p "$UNIT_DIR" "$STATUS_CACHE_DIR" "$STATE_DIR"

iso_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u +"%Y-%m-%dT%H:%M:%S+00:00"
}

api_base() {
  local base
  base="${HQ_PRO_API_URL:-${HQ_API_URL:-${HQ_VAULT_API_URL:-https://hqapi.hq.computer}}}"
  printf '%s' "${base%/}"
}

# --- owner identity (company jobs: creator's Outpost only) -------------------

resolve_box_owners() {
  # Emits newline-separated owner identity tokens this box may claim.
  local tokens=""
  add_token() {
    local t="$1"
    [ -n "$t" ] && [ "$t" != "null" ] || return 0
    case $'\n'"$tokens"$'\n' in
      *$'\n'"$t"$'\n'*) ;;
      *) tokens="${tokens:+${tokens}$'\n'}${t}" ;;
    esac
  }

  add_token "${HQ_JOB_OWNER_EMAIL:-}"
  add_token "${HQ_JOB_OWNER_UID:-}"
  add_token "${OUTPOST_USER_ID:-}"

  if command -v hq >/dev/null 2>&1; then
    local who
    who="$(hq whoami --json 2>/dev/null || hq whoami 2>/dev/null || true)"
    if [ -n "$who" ]; then
      local email uid
      email="$(printf '%s' "$who" | jq -r '.email // .user.email // empty' 2>/dev/null || true)"
      uid="$(printf '%s' "$who" | jq -r '.personUid // .person_uid // .uid // empty' 2>/dev/null || true)"
      if [ -z "$email" ]; then
        email="$(printf '%s' "$who" | sed -n 's/.*Email:[[:space:]]*//Ip;s/.*email[[:space:]]*[:=][[:space:]]*//Ip' | head -1 | tr -d '[:space:]')"
      fi
      add_token "$email"
      add_token "$uid"
    fi
  fi

  # Common on-box identity files.
  if [ -f /etc/outpost/codex-identity.env ]; then
    # shellcheck disable=SC1091
    . /etc/outpost/codex-identity.env 2>/dev/null || true
    add_token "${OUTPOST_USER_ID:-}"
    add_token "${OUTPOST_OWNER_EMAIL:-}"
    add_token "${OWNER_EMAIL:-}"
  fi

  printf '%s' "$tokens"
}

owner_matches() {
  local job_owner="$1"
  local box_owners="$2"
  [ -n "$job_owner" ] || return 1
  local t
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if [ "$t" = "$job_owner" ]; then
      return 0
    fi
    # Case-insensitive email compare
    if printf '%s' "$t" | grep -qi '@' \
      && [ "$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$job_owner" | tr '[:upper:]' '[:lower:]')" ]; then
      return 0
    fi
  done <<EOF
$box_owners
EOF
  return 1
}

# --- readiness cache ---------------------------------------------------------

status_cache_path() {
  printf '%s/%s.json' "$STATUS_CACHE_DIR" "$1"
}

read_cached_readiness() {
  local id="$1" path
  path="$(status_cache_path "$id")"
  if [ -f "$path" ]; then
    yq -r '.readiness // "unknown"' "$path" 2>/dev/null || echo unknown
    return
  fi
  # Fall back to probe last-attempt marker when it recorded a successful ingest.
  local probe_marker="${HOME}/.hq/jobs/probes/${id}/last-attempt.json"
  if [ -f "$probe_marker" ]; then
    local reported
    reported="$(jq -r '.reported_readiness // empty' "$probe_marker" 2>/dev/null || true)"
    if [ -n "$reported" ] && [ "$reported" != "null" ]; then
      printf '%s' "$reported"
      return
    fi
  fi
  printf 'unknown'
}

write_status_cache() {
  local id="$1" readiness="$2" source="${3:-reconcile}"
  local path
  path="$(status_cache_path "$id")"
  jq -nc \
    --arg job_id "$id" \
    --arg readiness "$readiness" \
    --arg updated_at "$(iso_now)" \
    --arg source "$source" \
    '{job_id:$job_id,readiness:$readiness,updated_at:$updated_at,source:$source}' \
    >"$path"
  chmod 600 "$path" 2>/dev/null || true
}

# Optional live GET when HQ_ACCESS_TOKEN is present (laptop JWT on box is rare).
fetch_live_readiness() {
  local id="$1"
  [ -n "${HQ_ACCESS_TOKEN:-}" ] || return 1
  local url curl_bin http body tmp
  url="$(api_base)/outpost/jobs/status/${id}"
  curl_bin="${HQ_JOB_PROBE_CURL:-curl}"
  command -v "$curl_bin" >/dev/null 2>&1 || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/hq-job-status.XXXXXX")"
  http=0
  set +e
  "$curl_bin" -sS -m 15 \
    -H "authorization: Bearer ${HQ_ACCESS_TOKEN}" \
    -H "accept: application/json" \
    -o "$tmp" \
    -w '%{http_code}' \
    "$url" >"${tmp}.code"
  set -e
  http="$(cat "${tmp}.code" 2>/dev/null || echo 0)"
  body="$(cat "$tmp" 2>/dev/null || true)"
  rm -f "$tmp" "${tmp}.code"
  if [ "$http" -ge 200 ] && [ "$http" -lt 300 ]; then
    local r
    r="$(printf '%s' "$body" | jq -r '.status.readiness // .readiness // empty' 2>/dev/null || true)"
    if [ -n "$r" ]; then
      write_status_cache "$id" "$r" "api-get"
      printf '%s' "$r"
      return 0
    fi
  fi
  return 1
}

job_readiness() {
  local id="$1" r
  if r="$(fetch_live_readiness "$id")"; then
    printf '%s' "$r"
    return
  fi
  read_cached_readiness "$id"
}

# --- cron → systemd OnCalendar -----------------------------------------------

# Map cron DOW (0/7=Sun … 6=Sat) to systemd weekday names.
cron_dow_to_systemd() {
  local field="$1"
  case "$field" in
    '*'|'*/1') printf ''; return ;;
  esac
  local out="" part IFS=','
  # shellcheck disable=SC2086
  set -f
  set -- $field
  set +f
  for part in "$@"; do
    local mapped
    mapped="$(cron_dow_token_to_systemd "$part")" || return 1
    [ -n "$mapped" ] || continue
    out="${out:+$out,}$mapped"
  done
  printf '%s' "$out"
}

cron_dow_token_to_systemd() {
  local tok="$1"
  # ranges like 1-5 or Mon-Fri
  if printf '%s' "$tok" | grep -Eq '^[0-7]+-[0-7]+$'; then
    local a b
    a="${tok%-*}"; b="${tok#*-}"
    printf '%s..%s' "$(cron_dow_num_to_name "$a")" "$(cron_dow_num_to_name "$b")"
    return
  fi
  case "$(printf '%s' "$tok" | tr '[:upper:]' '[:lower:]')" in
    sun|0|7) printf 'Sun' ;;
    mon|1) printf 'Mon' ;;
    tue|2) printf 'Tue' ;;
    wed|3) printf 'Wed' ;;
    thu|4) printf 'Thu' ;;
    fri|5) printf 'Fri' ;;
    sat|6) printf 'Sat' ;;
    mon..fri|1-5) printf 'Mon..Fri' ;;
    *) return 1 ;;
  esac
}

cron_dow_num_to_name() {
  case "$1" in
    0|7) printf 'Sun' ;;
    1) printf 'Mon' ;;
    2) printf 'Tue' ;;
    3) printf 'Wed' ;;
    4) printf 'Thu' ;;
    5) printf 'Fri' ;;
    6) printf 'Sat' ;;
    *) return 1 ;;
  esac
}

pad2() {
  local n="$1"
  if [ "${#n}" -eq 1 ]; then
    printf '0%s' "$n"
  else
    printf '%s' "$n"
  fi
}

# Convert a single cron field that is a fixed number or */n or a-b into
# systemd calendar fragment for hour/minute. Returns empty for '*'.
cron_time_field() {
  local field="$1" width="$2"  # width unused; kept for clarity
  case "$field" in
    '*') printf ''; return ;;
    */*)
      local step="${field#*/}"
      printf '*/%s' "$step"
      return
      ;;
    *-*)
      printf '%s' "$field"
      return
      ;;
    *)
      if printf '%s' "$field" | grep -Eq '^[0-9]+$'; then
        pad2 "$field"
        return
      fi
      printf '%s' "$field"
      ;;
  esac
}

cron_to_oncalendar() {
  # stdin unused; args: minute hour dom month dow → prints OnCalendar value
  local minute="$1" hour="$2" dom="$3" month="$4" dow="$5"
  local dow_s date_s time_s h m

  dow_s="$(cron_dow_to_systemd "$dow" || true)"

  # Date part: year-month-day → *-month-day
  local mon_s day_s
  case "$month" in
    '*') mon_s='*' ;;
    *) mon_s="$(pad2 "$month" 2>/dev/null || printf '%s' "$month")" ;;
  esac
  case "$dom" in
    '*') day_s='*' ;;
    *) day_s="$(pad2 "$dom" 2>/dev/null || printf '%s' "$dom")" ;;
  esac
  date_s="*-${mon_s}-${day_s}"

  m="$(cron_time_field "$minute" 2)"
  h="$(cron_time_field "$hour" 2)"
  [ -n "$m" ] || m='00'
  [ -n "$h" ] || h='*'
  # Normalize pure numbers already padded; handle hour=*
  if [ "$h" = '*' ]; then
    time_s="*:${m}:00"
  elif printf '%s' "$h" | grep -q '/'; then
    # e.g. */6 → 0/6
    local step="${h#*/}"
    time_s="0/${step}:${m}:00"
  else
    time_s="${h}:${m}:00"
  fi

  if [ -n "$dow_s" ]; then
    printf '%s %s %s' "$dow_s" "$date_s" "$time_s"
  else
    printf '%s %s' "$date_s" "$time_s"
  fi
}

# --- unit writers ------------------------------------------------------------

unit_service_path() { printf '%s/hq-job-%s.service' "$UNIT_DIR" "$1"; }
unit_timer_path() { printf '%s/hq-job-%s.timer' "$UNIT_DIR" "$1"; }

write_service_unit() {
  local id="$1" path
  path="$(unit_service_path "$id")"
  local runner_abs
  runner_abs="$(cd "$(dirname "$RUNNER")" && pwd)/$(basename "$RUNNER")"
  cat >"$path" <<EOF
# Generated by outpost-jobs-reconcile.sh — disposable derived state. Do not edit.
[Unit]
Description=HQ Outpost scheduled job: ${id}
Documentation=file://${HQ_ROOT}/core/knowledge/public/hq-core/outpost-jobs-spec.md
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=HQ_ROOT=${HQ_ROOT}
ExecStart=${runner_abs} --hq-root ${HQ_ROOT} --job-id ${id}
Nice=10

[Install]
WantedBy=default.target
EOF
}

write_timer_unit() {
  local id="$1" oncal="$2" tz="$3" path
  path="$(unit_timer_path "$id")"
  cat >"$path" <<EOF
# Generated by outpost-jobs-reconcile.sh — disposable derived state. Do not edit.
[Unit]
Description=HQ Outpost scheduled job timer: ${id}
Documentation=file://${HQ_ROOT}/core/knowledge/public/hq-core/outpost-jobs-spec.md

[Timer]
Timezone=${tz}
OnCalendar=${oncal}
Persistent=true
RandomizedDelaySec=${RANDOMIZE_SEC}
Unit=hq-job-${id}.service

[Install]
WantedBy=timers.target
EOF
}

systemctl_user() {
  if [ "$DRY_RUN" -eq 1 ]; then
    log "dry-run systemctl --user $*"
    return 0
  fi
  if [ "$SYSTEMCTL_BIN" = ":" ] || [ "$SYSTEMCTL_BIN" = "true" ]; then
    return 0
  fi
  if ! command -v "$SYSTEMCTL_BIN" >/dev/null 2>&1; then
    log "systemctl not available — units written but not enabled ($*)"
    return 0
  fi
  "$SYSTEMCTL_BIN" --user "$@"
}

enable_timer() {
  local id="$1"
  systemctl_user daemon-reload || true
  systemctl_user enable --now "hq-job-${id}.timer" || true
}

disable_remove_units() {
  local id="$1"
  systemctl_user disable --now "hq-job-${id}.timer" 2>/dev/null || true
  systemctl_user stop "hq-job-${id}.service" 2>/dev/null || true
  rm -f "$(unit_service_path "$id")" "$(unit_timer_path "$id")"
}

units_fingerprint() {
  local id="$1"
  local sp tp
  sp="$(unit_service_path "$id")"
  tp="$(unit_timer_path "$id")"
  if [ ! -f "$sp" ] || [ ! -f "$tp" ]; then
    printf ''
    return
  fi
  # Content hash for idempotency compare
  cat "$sp" "$tp" | shasum -a 256 2>/dev/null | awk '{print $1}' \
    || cat "$sp" "$tp" | cksum | awk '{print $1}'
}

# --- registry scan -----------------------------------------------------------

collect_job_files() {
  {
    # Only top-level registry YAMLs — skip sync conflict sidecars and quarantine dirs.
    find "$HQ_ROOT/personal/jobs" -maxdepth 1 \( -name '*.yaml' -o -name '*.yml' \) -type f 2>/dev/null || true
    find "$HQ_ROOT/companies" -path '*/jobs/*' -maxdepth 3 \( -name '*.yaml' -o -name '*.yml' \) -type f 2>/dev/null || true
  } | grep -Ev '\.conflict-|/\.conflicts/' | sort -u
}

is_company_job_path() {
  case "$1" in
    */companies/*/jobs/*) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_sync_hook() {
  local hook_dir="$HQ_ROOT/personal/hooks/Stop"
  local hook_path="$hook_dir/90-outpost-jobs-reconcile.sh"
  mkdir -p "$hook_dir"
  cat >"$hook_path" <<EOF
#!/usr/bin/env bash
# Auto-installed by outpost-jobs-reconcile.sh --ensure-hook (US-004).
# hq-sync-runner executes personal/hooks/Stop/* after each sync cycle.
set -u
HQ_ROOT="\${OUTPOST_HQ_ROOT:-\${HQ_ROOT:-/home/ec2-user/hq}}"
RECONCILE="\$HQ_ROOT/core/scripts/outpost-jobs-reconcile.sh"
if [ -x "\$RECONCILE" ] || [ -f "\$RECONCILE" ]; then
  bash "\$RECONCILE" --hq-root "\$HQ_ROOT" --after-sync >>"\${HOME}/.hq/jobs/reconcile/after-sync.log" 2>&1 || true
fi
EOF
  chmod +x "$hook_path"
  log "installed sync Stop hook: $hook_path"
}

# --- main reconcile ----------------------------------------------------------

BOX_OWNERS="$(resolve_box_owners)"
DESIRED_IDS=""
ERRORS=0
ARMED=0
SKIPPED=0
REMOVED=0
PROBE_RAN=0

if [ "$ENSURE_HOOK" -eq 1 ]; then
  ensure_sync_hook
fi

# First pass: probe jobs that are not ready (unless --no-probe).
if [ "$NO_PROBE" -eq 0 ]; then
  while IFS= read -r jf; do
    [ -n "$jf" ] || continue
    if ! bash "$VALIDATE" "$jf" >/dev/null 2>&1; then
      continue
    fi
    jid="$(yq -r '.id // ""' "$jf")"
    [ -n "$jid" ] || continue
    if is_company_job_path "$jf"; then
      jowner="$(yq -r '.owner // ""' "$jf")"
      if ! owner_matches "$jowner" "$BOX_OWNERS"; then
        continue
      fi
    fi
    readiness="$(job_readiness "$jid")"
    if [ "$readiness" != "ready" ]; then
      log "probe $jid (cached readiness=$readiness)"
      set +e
      bash "$PROBE" --hq-root "$HQ_ROOT" "$jf" >/tmp/hq-job-probe-out.$$ 2>/tmp/hq-job-probe-err.$$
      prc=$?
      set -e
      PROBE_RAN=$((PROBE_RAN + 1))
      # Refresh cache from probe JSON stdout when present.
      if [ -f /tmp/hq-job-probe-out.$$ ]; then
        pready="$(jq -r '.readiness // empty' /tmp/hq-job-probe-out.$$ 2>/dev/null || true)"
        if [ -n "$pready" ]; then
          # Only cache definitive ready/blocked from a successful ingest path.
          ingest="$(jq -r '.ingest // empty' /tmp/hq-job-probe-out.$$ 2>/dev/null || true)"
          if [ "$ingest" = "ok" ] || [ "$ingest" = "dry_run" ]; then
            write_status_cache "$jid" "$pready" "probe"
          elif [ "$pready" = "blocked" ]; then
            write_status_cache "$jid" "blocked" "probe-local"
          fi
        fi
      fi
      rm -f /tmp/hq-job-probe-out.$$ /tmp/hq-job-probe-err.$$
      if [ "$prc" -ge 2 ] && [ "$prc" -ne 3 ]; then
        ERRORS=$((ERRORS + 1))
      fi
    fi
  done < <(collect_job_files)
fi

if [ "$PROBE_ONLY" -eq 1 ]; then
  log "probe-only done (probed=$PROBE_RAN errors=$ERRORS)"
  [ "$ERRORS" -eq 0 ] || exit 1
  exit 0
fi

# Second pass: materialize / remove units.
while IFS= read -r jf; do
  [ -n "$jf" ] || continue

  if ! bash "$VALIDATE" "$jf" >/dev/null 2>&1; then
    log "skip invalid job YAML: $jf"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  jid="$(yq -r '.id // ""' "$jf")"
  jname="$(yq -r '.name // ""' "$jf")"
  jowner="$(yq -r '.owner // ""' "$jf")"
  enabled="$(yq -o=json '.' "$jf" | jq -r 'if has("enabled") then (.enabled|tostring) else "true" end')"
  schedule="$(yq -r '.schedule // ""' "$jf")"
  tz="$(yq -r '.timezone // "UTC"' "$jf")"

  if is_company_job_path "$jf"; then
    if ! owner_matches "$jowner" "$BOX_OWNERS"; then
      log "skip company job $jid — owner '$jowner' does not match this Outpost"
      SKIPPED=$((SKIPPED + 1))
      # Ensure we do not leave a stale timer if ownership changed.
      if [ -f "$(unit_timer_path "$jid")" ]; then
        disable_remove_units "$jid"
        REMOVED=$((REMOVED + 1))
      fi
      continue
    fi
  fi

  if [ "$enabled" = "false" ] || [ "$enabled" = "False" ] || [ "$enabled" = "0" ]; then
    log "remove units for disabled job $jid"
    if [ -f "$(unit_timer_path "$jid")" ] || [ -f "$(unit_service_path "$jid")" ]; then
      disable_remove_units "$jid"
      REMOVED=$((REMOVED + 1))
    fi
    continue
  fi

  readiness="$(job_readiness "$jid")"
  if [ "$readiness" != "ready" ]; then
    log "skip arming $jid — readiness=$readiness (need ready)"
    SKIPPED=$((SKIPPED + 1))
    if [ -f "$(unit_timer_path "$jid")" ]; then
      disable_remove_units "$jid"
      REMOVED=$((REMOVED + 1))
      log "stopped timer for non-ready job $jid"
    fi
    continue
  fi

  # Parse 5-field cron
  set -f
  # shellcheck disable=SC2086
  set -- $schedule
  set +f
  if [ "$#" -ne 5 ]; then
    log "skip $jid — schedule not 5-field cron: $schedule"
    ERRORS=$((ERRORS + 1))
    continue
  fi
  oncal="$(cron_to_oncalendar "$1" "$2" "$3" "$4" "$5")" || {
    log "skip $jid — cannot convert cron to OnCalendar: $schedule"
    ERRORS=$((ERRORS + 1))
    continue
  }

  DESIRED_IDS="${DESIRED_IDS:+${DESIRED_IDS}$'\n'}${jid}"

  # Write to temp then compare for idempotency.
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/hq-job-unit.XXXXXX")"
  OLD_UNIT_DIR="$UNIT_DIR"
  UNIT_DIR="$tmp_dir"
  write_service_unit "$jid"
  write_timer_unit "$jid" "$oncal" "$tz"
  UNIT_DIR="$OLD_UNIT_DIR"

  new_hash="$(cat "$tmp_dir/hq-job-${jid}.service" "$tmp_dir/hq-job-${jid}.timer" | shasum -a 256 2>/dev/null | awk '{print $1}' \
    || cat "$tmp_dir/hq-job-${jid}.service" "$tmp_dir/hq-job-${jid}.timer" | cksum | awk '{print $1}')"
  old_hash="$(units_fingerprint "$jid")"

  if [ "$new_hash" = "$old_hash" ] && [ -n "$old_hash" ]; then
    log "noop $jid — units unchanged ($jname)"
    rm -rf "$tmp_dir"
    # Ensure timer still enabled
    enable_timer "$jid"
    ARMED=$((ARMED + 1))
    continue
  fi

  cp "$tmp_dir/hq-job-${jid}.service" "$(unit_service_path "$jid")"
  cp "$tmp_dir/hq-job-${jid}.timer" "$(unit_timer_path "$jid")"
  rm -rf "$tmp_dir"
  enable_timer "$jid"
  log "armed $jid OnCalendar=$oncal Timezone=$tz readiness=ready"
  ARMED=$((ARMED + 1))
done < <(collect_job_files)

# Remove units for jobs no longer in the desired set (deleted from registry).
for unit_file in "$UNIT_DIR"/hq-job-*.timer; do
  [ -e "$unit_file" ] || continue
  base="$(basename "$unit_file" .timer)"
  uid="${base#hq-job-}"
  found=0
  while IFS= read -r d; do
    [ "$d" = "$uid" ] && found=1 && break
  done <<EOF
$DESIRED_IDS
EOF
  if [ "$found" -eq 0 ]; then
    log "remove orphaned units for deleted/unarmed job $uid"
    disable_remove_units "$uid"
    REMOVED=$((REMOVED + 1))
  fi
done

SUMMARY="$(jq -nc \
  --argjson armed "$ARMED" \
  --argjson skipped "$SKIPPED" \
  --argjson removed "$REMOVED" \
  --argjson probed "$PROBE_RAN" \
  --argjson errors "$ERRORS" \
  --arg dry_run "$DRY_RUN" \
  --arg at "$(iso_now)" \
  '{armed:$armed,skipped:$skipped,removed:$removed,probed:$probed,errors:$errors,dry_run:($dry_run=="1"),at:$at}')"
printf '%s\n' "$SUMMARY" | tee "$STATE_DIR/last-reconcile.json" >/dev/null
log "done armed=$ARMED skipped=$SKIPPED removed=$REMOVED probed=$PROBE_RAN errors=$ERRORS"

[ "$ERRORS" -eq 0 ] || exit 1
exit 0
