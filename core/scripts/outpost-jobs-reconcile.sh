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
if [ "${1:-}" = "--company-machine" ]; then
  shift
  exec node "$SCRIPT_DIR/lib/company-jobs.mjs" reconcile "$@"
fi
if [ "${HQ_MACHINE_AUTH_REQUIRED:-}" = "1" ]; then
  echo 'company jobs require --company-machine <config>' >&2
  exit 2
fi
HQ_ROOT="${HQ_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
VALIDATE="$SCRIPT_DIR/jobs-validate.sh"
PROBE="$SCRIPT_DIR/hq-job-probe.sh"

DRY_RUN=0
NO_PROBE=0
PROBE_ONLY=0
ENSURE_HOOK=0

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

# The shell script is also bundled inside hq-cli. Its own SCRIPT_DIR then
# points into the npm package, while job units must always target the live
# scaffold forwarder so they survive CLI upgrades and Node switches.
RUNNER="$HQ_ROOT/core/scripts/hq-job-run.sh"

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
      # The person (or the human an Outpost session acts for, reported even
      # under the box's machine identity) by Cognito id and email, so a job
      # owner written either way matches this box.
      add_token "$(printf '%s' "$who" | jq -r '.sub // empty' 2>/dev/null || true)"
      add_token "$(printf '%s' "$who" | jq -r '.delegatedEmail // empty' 2>/dev/null || true)"
      add_token "$(printf '%s' "$who" | jq -r '.delegatedSub // empty' 2>/dev/null || true)"
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
#
# Supported cron syntax, per field: '*', N, A-B, */S, A-B/S, A/S (A through the
# field maximum), and comma lists of those (e.g. 1,5-7). Day-of-week accepts
# 0-7 (0 and 7 are Sunday) and sun..sat names. Anything else (month names,
# L, W, #, @-macros, out-of-range values, reversed ranges, a restricted
# day-of-month together with a restricted day-of-week, whose cron OR meaning
# systemd cannot express) makes cron_to_oncalendar print a reason on stderr
# and return 1. The converter never widens a schedule to make it fit.

cron_err() { printf 'cron_to_oncalendar: %s\n' "$*" >&2; }

cron_is_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

pad2() {
  local n="$1"
  if [ "${#n}" -eq 1 ]; then
    printf '0%s' "$n"
  else
    printf '%s' "$n"
  fi
}

# cron_value <token> <lo> <hi> <label> → prints the decimal value or fails.
cron_value() {
  local tok="$1" lo="$2" hi="$3" label="$4" v
  if ! cron_is_uint "$tok" || [ "${#tok}" -gt 2 ]; then
    cron_err "unsupported $label value '$tok'"
    return 1
  fi
  v=$((10#$tok))
  if [ "$v" -lt "$lo" ] || [ "$v" -gt "$hi" ]; then
    cron_err "$label value $v outside $lo-$hi"
    return 1
  fi
  printf '%s' "$v"
}

# cron_step <token> <label> → prints a positive step or fails.
cron_step() {
  local tok="$1" label="$2"
  if ! cron_is_uint "$tok" || [ "${#tok}" -gt 2 ] || [ "$((10#$tok))" -lt 1 ]; then
    cron_err "unsupported $label step '$tok'"
    return 1
  fi
  printf '%s' "$((10#$tok))"
}

# Convert one numeric cron field (minute, hour, day-of-month, month) into the
# matching systemd calendar component. '*' stays '*'.
#   N -> NN, A-B -> AA..BB, */S -> LO/S, A-B/S -> AA..BB/S, A/S -> AA/S
cron_field_to_systemd() {
  local field="$1" lo="$2" hi="$3" label="$4"
  local out="" part base step a b IFS=','
  if [ "$field" = '*' ]; then
    printf '*'
    return 0
  fi
  case "$field" in
    ''|,*|*,|*,,*)
      cron_err "malformed $label field '$field'"
      return 1
      ;;
  esac
  set -f
  # shellcheck disable=SC2086
  set -- $field
  set +f
  for part in "$@"; do
    step=""
    base="$part"
    case "$part" in
      */*/*)
        cron_err "malformed $label field '$field'"
        return 1
        ;;
      */*)
        base="${part%/*}"
        step="$(cron_step "${part#*/}" "$label")" || return 1
        ;;
    esac
    case "$base" in
      '*')
        if [ -z "$step" ]; then
          cron_err "'*' inside a $label list '$field'"
          return 1
        fi
        out="${out:+$out,}$(pad2 "$lo")/${step}"
        ;;
      *-*)
        a="$(cron_value "${base%%-*}" "$lo" "$hi" "$label")" || return 1
        b="$(cron_value "${base#*-}" "$lo" "$hi" "$label")" || return 1
        if [ "$a" -gt "$b" ]; then
          cron_err "reversed $label range '$base'"
          return 1
        fi
        out="${out:+$out,}$(pad2 "$a")..$(pad2 "$b")${step:+/$step}"
        ;;
      *)
        a="$(cron_value "$base" "$lo" "$hi" "$label")" || return 1
        out="${out:+$out,}$(pad2 "$a")${step:+/$step}"
        ;;
    esac
  done
  printf '%s' "$out"
}

# Map a cron day-of-week token (0-7 or sun..sat) to 0-7; 0 and 7 are Sunday.
cron_dow_value() {
  local tok
  tok="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$tok" in
    sun) printf '0' ;;
    mon) printf '1' ;;
    tue) printf '2' ;;
    wed) printf '3' ;;
    thu) printf '4' ;;
    fri) printf '5' ;;
    sat) printf '6' ;;
    *) cron_value "$tok" 0 7 day-of-week || return 1 ;;
  esac
}

# cron_dow_run <first> <last> <length> → Mon | Mon,Tue | Mon..Wed
cron_dow_run() {
  local first="$1" last="$2" len="$3"
  local n out="" seen=0
  if [ "$len" -ge 3 ]; then
    printf '%s..%s' "$first" "$last"
    return 0
  fi
  if [ "$len" -eq 1 ]; then
    printf '%s' "$first"
    return 0
  fi
  for n in Mon Tue Wed Thu Fri Sat Sun; do
    [ "$n" = "$first" ] && seen=1
    if [ "$seen" -eq 1 ]; then
      out="${out:+$out,}$n"
      [ "$n" = "$last" ] && break
    fi
  done
  printf '%s' "$out"
}

# Map cron DOW (0/7=Sun … 6=Sat) to systemd weekday names. Prints '' when
# every day matches. Days are emitted Monday-first (systemd's own order), with
# runs of three or more collapsed to A..B, so 1-5 → Mon..Fri and 0,6 → Sat,Sun.
cron_dow_to_systemd() {
  local field="$1"
  local part base step a b i d IFS=','
  local days=" "
  case "$field" in
    '*'|'*/1') printf ''; return 0 ;;
    ''|,*|*,|*,,*)
      cron_err "malformed day-of-week field '$field'"
      return 1
      ;;
  esac
  set -f
  # shellcheck disable=SC2086
  set -- $field
  set +f
  for part in "$@"; do
    step=1
    base="$part"
    case "$part" in
      */*/*)
        cron_err "malformed day-of-week field '$field'"
        return 1
        ;;
      */*)
        base="${part%/*}"
        step="$(cron_step "${part#*/}" day-of-week)" || return 1
        ;;
    esac
    case "$base" in
      '*') a=0; b=6 ;;
      *-*)
        a="$(cron_dow_value "${base%%-*}")" || return 1
        b="$(cron_dow_value "${base#*-}")" || return 1
        if [ "$a" -gt "$b" ]; then
          cron_err "reversed day-of-week range '$base'"
          return 1
        fi
        ;;
      *)
        a="$(cron_dow_value "$base")" || return 1
        # A/S runs from A to the end of the week, as in Vixie cron.
        if [ "$part" != "$base" ]; then b=6; else b="$a"; fi
        ;;
    esac
    i="$a"
    while [ "$i" -le "$b" ]; do
      d=$((i % 7))
      case "$days" in
        *" $d "*) ;;
        *) days="$days$d " ;;
      esac
      i=$((i + step))
    done
  done
  # Monday-first order matches systemd, so every collapsed run is ascending.
  local out="" run_start="" run_prev="" run_len=0 count=0 name
  IFS=' '
  for d in 1 2 3 4 5 6 0; do
    case "$d" in
      1) name=Mon ;; 2) name=Tue ;; 3) name=Wed ;; 4) name=Thu ;;
      5) name=Fri ;; 6) name=Sat ;; 0) name=Sun ;;
    esac
    if case "$days" in *" $d "*) true ;; *) false ;; esac; then
      count=$((count + 1))
      if [ -z "$run_start" ]; then run_start="$name"; run_len=0; fi
      run_prev="$name"
      run_len=$((run_len + 1))
    elif [ -n "$run_start" ]; then
      out="${out:+$out,}$(cron_dow_run "$run_start" "$run_prev" "$run_len")"
      run_start=""
    fi
  done
  if [ -n "$run_start" ]; then
    out="${out:+$out,}$(cron_dow_run "$run_start" "$run_prev" "$run_len")"
  fi
  if [ "$count" -eq 7 ]; then
    printf ''
  else
    printf '%s' "$out"
  fi
}

cron_to_oncalendar() {
  # stdin unused; args: minute hour dom month dow → prints OnCalendar value.
  # Returns 1 (reason on stderr) for any cron form it cannot map exactly.
  local minute="$1" hour="$2" dom="$3" month="$4" dow="$5"
  local dow_s mon_s day_s h m

  if [ "$#" -ne 5 ]; then
    cron_err "expected 5 fields, got $#"
    return 1
  fi
  case "$dow" in
    '*'|'*/1') ;;
    *)
      if [ "$dom" != '*' ]; then
        cron_err "day-of-month '$dom' with day-of-week '$dow' matches either day in cron; systemd cannot express that"
        return 1
      fi
      ;;
  esac

  dow_s="$(cron_dow_to_systemd "$dow")" || return 1
  mon_s="$(cron_field_to_systemd "$month" 1 12 month)" || return 1
  day_s="$(cron_field_to_systemd "$dom" 1 31 day-of-month)" || return 1
  h="$(cron_field_to_systemd "$hour" 0 23 hour)" || return 1
  # Personal timers have always shipped a wildcard minute as 00 (`* 9 * * *`
  # is once at 09:00); that narrows, never widens. Company jobs expand '*'
  # only in lib/company-jobs.mjs.
  if [ "$minute" = '*' ]; then
    m='00'
  else
    m="$(cron_field_to_systemd "$minute" 0 59 minute)" || return 1
  fi

  if [ -n "$dow_s" ]; then
    printf '%s *-%s-%s %s:%s:00' "$dow_s" "$mon_s" "$day_s" "$h" "$m"
  else
    printf '*-%s-%s %s:%s:00' "$mon_s" "$day_s" "$h" "$m"
  fi
}

# --- unit writers ------------------------------------------------------------

unit_service_path() { printf '%s/hq-job-%s.service' "$UNIT_DIR" "$1"; }
unit_timer_path() { printf '%s/hq-job-%s.timer' "$UNIT_DIR" "$1"; }

normalize_service_path() {
  local remaining="$1" entry existing normalized="" has_more seen entry_count=0 index
  local -a entries=()
  while :; do
    if [[ "$remaining" == *:* ]]; then
      entry="${remaining%%:*}"
      remaining="${remaining#*:}"
      has_more=1
    else
      entry="$remaining"
      remaining=""
      has_more=0
    fi
    case "$entry" in
      /*)
        seen=0
        for ((index = 0; index < entry_count; index++)); do
          existing="${entries[index]}"
          if [ "$existing" = "$entry" ]; then
            seen=1
            break
          fi
        done
        if [ "$seen" -eq 0 ]; then
          entries+=("$entry")
          entry_count=$((entry_count + 1))
        fi
        ;;
    esac
    [ "$has_more" -eq 1 ] || break
  done
  if [ "$entry_count" -gt 0 ]; then
    local IFS=:
    normalized="${entries[*]}"
  fi
  printf '%s' "$normalized"
}

unit_service_path_value() {
  local service_path hq_bin npm_prefix hq_bin_dir
  service_path="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
  service_path="$(normalize_service_path "$service_path")"
  hq_bin=""
  if [ -n "$service_path" ]; then
    hq_bin="$(PATH="$service_path" type -P hq 2>/dev/null || true)"
  fi
  if [ -z "$hq_bin" ] && PATH="$service_path" command -v npm >/dev/null 2>&1; then
    npm_prefix="$(PATH="$service_path" npm prefix -g 2>/dev/null || true)"
    if [ -n "$npm_prefix" ] && [ -x "$npm_prefix/bin/hq" ]; then
      hq_bin="$npm_prefix/bin/hq"
    fi
  fi
  if [ -n "$hq_bin" ] && [ -x "$hq_bin" ]; then
    hq_bin_dir="$(cd "$(dirname "$hq_bin")" 2>/dev/null && pwd -P || true)"
    if [ -n "$hq_bin_dir" ]; then
      case ":$service_path:" in
        *":$hq_bin_dir:"*) ;;
        *) service_path="$hq_bin_dir:$service_path" ;;
      esac
    fi
  fi
  printf '%s' "$service_path"
}

systemd_quote() {
  local value="$1"
  value="${value//%/%%}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '"%s"' "$value"
}

write_service_unit() {
  local id="$1" path service_path
  path="$(unit_service_path "$id")"
  service_path="$(unit_service_path_value)"
  local runner_abs
  # Keep the selected root verbatim so ExecStart names the same root as
  # --hq-root and HQ_ROOT below. Re-deriving it through cd/pwd collapses
  # a doubled slash (macOS TMPDIR ends in "/") and the paths then disagree.
  case "$RUNNER" in
    /*) runner_abs="$RUNNER" ;;
    *) runner_abs="$(cd "$(dirname "$RUNNER")" && pwd)/$(basename "$RUNNER")" ;;
  esac
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
Environment=$(systemd_quote "PATH=$service_path")
ExecStart=${runner_abs} --hq-root ${HQ_ROOT} --job-id ${id}
Nice=10

[Install]
WantedBy=default.target
EOF
}

write_timer_unit() {
  local id="$1" oncal="$2" path
  path="$(unit_timer_path "$id")"
  cat >"$path" <<EOF
# Generated by outpost-jobs-reconcile.sh — disposable derived state. Do not edit.
[Unit]
Description=HQ Outpost scheduled job timer: ${id}
Documentation=file://${HQ_ROOT}/core/knowledge/public/hq-core/outpost-jobs-spec.md

[Timer]
OnCalendar=${oncal}
Persistent=true
RandomizedDelaySec=${RANDOMIZE_SEC}
Unit=hq-job-${id}.service

[Install]
WantedBy=timers.target
EOF
}

# A system unit with User=ec2-user (outpost-jobs-reconcile.service) or a cron
# job runs without a login session, so XDG_RUNTIME_DIR and
# DBUS_SESSION_BUS_ADDRESS are unset and `systemctl --user` fails with
# "Failed to connect to bus: No medium found". When the user manager is
# running (linger enabled), its runtime dir is /run/user/<uid>; point
# systemctl at it. Called once from the main shell (not inside a command
# substitution) so the exports reach every later systemctl call.
ensure_user_bus_env() {
  local uid runtime_dir user_name
  uid="$(id -u 2>/dev/null || true)"
  [ -n "$uid" ] || return 0
  if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    runtime_dir="${HQ_JOB_USER_RUNTIME_BASE:-/run/user}/$uid"
    if [ -d "$runtime_dir" ]; then
      export XDG_RUNTIME_DIR="$runtime_dir"
      log "XDG_RUNTIME_DIR was unset; using $runtime_dir for systemctl --user"
    else
      user_name="$(id -un 2>/dev/null || printf '%s' "$uid")"
      log "user runtime dir $runtime_dir is missing — the systemd user manager is not running for $user_name; enable linger: sudo loginctl enable-linger $user_name"
      return 0
    fi
  fi
  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -e "$XDG_RUNTIME_DIR/bus" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
  fi
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
    log "systemctl command is unavailable — units not enabled ($*)"
    return 127
  fi
  "$SYSTEMCTL_BIN" --user "$@"
}

systemctl_reason() {
  local output="$1" reason
  reason="$(printf '%s' "$output" | tr '\r\n\t' '   ' | cut -c1-240)"
  printf '%s' "${reason:-systemctl user manager probe failed without an error message}"
}

enable_timer() {
  local id="$1"
  local output reason rc=0

  # Keep explicit test no-ops and dry-runs side-effect free; real hosts must
  # have a reachable user manager before a timer can be reported as armed.
  if [ "$DRY_RUN" -ne 1 ] && [ "$SYSTEMCTL_BIN" != ":" ] && [ "$SYSTEMCTL_BIN" != "true" ]; then
    output="$(systemctl_user show-environment 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      reason="$(systemctl_reason "$output")"
      log "not-scheduled job $id reason=$reason"
      return "$rc"
    fi
  fi

  systemctl_user daemon-reload || true
  rc=0
  output="$(systemctl_user enable --now "hq-job-${id}.timer" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    log "systemctl enable timer failed for job $id exit=$rc: ${output:-no error message}"
    reason="$(systemctl_reason "$output")"
    log "not-scheduled job $id reason=$reason"
    return "$rc"
  fi
  if [ -n "$output" ]; then
    printf '%s\n' "$output" >&2
  fi
  return 0
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
LOG="\${HOME}/.hq/jobs/reconcile/after-sync.log"
if [ -x "\$RECONCILE" ] || [ -f "\$RECONCILE" ]; then
  # A failed reconcile must not fail the sync cycle, but it must be visible:
  # jobs with errors are left unarmed until the next successful pass.
  if ! bash "\$RECONCILE" --hq-root "\$HQ_ROOT" --after-sync >>"\$LOG" 2>&1; then
    echo "outpost-jobs-reconcile: after-sync reconcile reported errors — some jobs are not scheduled; see \$LOG" >&2
    echo "outpost-jobs-reconcile: after-sync reconcile reported errors" >>"\$LOG"
  fi
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

if [ "$DRY_RUN" -ne 1 ] && [ "$SYSTEMCTL_BIN" != ":" ] && [ "$SYSTEMCTL_BIN" != "true" ]; then
  ensure_user_bus_env
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

  job_id_hint="$(yq -r '.id // ""' "$jf" 2>/dev/null || true)"
  tz="$(yq -r '.timezone // ""' "$jf" 2>/dev/null || true)"
  if [ -n "$tz" ] && [[ ! "$tz" =~ ^[A-Za-z0-9/_+-]+$ ]]; then
    log "skip ${job_id_hint:-unknown} — invalid timezone contains unsafe characters"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  if ! bash "$VALIDATE" "$jf" >/dev/null 2>&1; then
    log "skip invalid job YAML: $jf"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  jid="$job_id_hint"
  jname="$(yq -r '.name // ""' "$jf")"
  jowner="$(yq -r '.owner // ""' "$jf")"
  enabled="$(yq -o=json '.' "$jf" | jq -r 'if has("enabled") then (.enabled|tostring) else "true" end')"
  schedule="$(yq -r '.schedule // ""' "$jf")"
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
  if [ -n "$tz" ]; then
    case " $oncal " in
      *" $tz "*) ;;
      *) oncal="$oncal $tz" ;;
    esac
  fi

  DESIRED_IDS="${DESIRED_IDS:+${DESIRED_IDS}$'\n'}${jid}"

  # Write to temp then compare for idempotency.
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/hq-job-unit.XXXXXX")"
  OLD_UNIT_DIR="$UNIT_DIR"
  UNIT_DIR="$tmp_dir"
  write_service_unit "$jid"
  write_timer_unit "$jid" "$oncal"
  UNIT_DIR="$OLD_UNIT_DIR"

  new_hash="$(cat "$tmp_dir/hq-job-${jid}.service" "$tmp_dir/hq-job-${jid}.timer" | shasum -a 256 2>/dev/null | awk '{print $1}' \
    || cat "$tmp_dir/hq-job-${jid}.service" "$tmp_dir/hq-job-${jid}.timer" | cksum | awk '{print $1}')"
  old_hash="$(units_fingerprint "$jid")"

  if [ "$new_hash" = "$old_hash" ] && [ -n "$old_hash" ]; then
    log "noop $jid — units unchanged ($jname)"
    rm -rf "$tmp_dir"
    # Ensure timer still enabled
    if enable_timer "$jid"; then
      ARMED=$((ARMED + 1))
    else
      SKIPPED=$((SKIPPED + 1))
      ERRORS=$((ERRORS + 1))
    fi
    continue
  fi

  cp "$tmp_dir/hq-job-${jid}.service" "$(unit_service_path "$jid")"
  cp "$tmp_dir/hq-job-${jid}.timer" "$(unit_timer_path "$jid")"
  rm -rf "$tmp_dir"
  if enable_timer "$jid"; then
    log "armed $jid OnCalendar=$oncal readiness=ready"
    ARMED=$((ARMED + 1))
  else
    SKIPPED=$((SKIPPED + 1))
    ERRORS=$((ERRORS + 1))
  fi
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
