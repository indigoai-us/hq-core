#!/usr/bin/env bash
# hq-core: public
# hq-pr-create.sh - `gh pr create` with the HQ-Fingerprint footer.
#
# Usage: bash core/scripts/hq-pr-create.sh [gh pr create args...]
#
# Every argument is passed to `gh pr create` unchanged. When
# `${HQ_FINGERPRINT_BIN:-hq} fingerprint self --json --offline` returns a
# fingerprint within 2 s, the PR body gains a final section: a blank line,
# `---`, and `HQ-Fingerprint: <value>`. The body may come from --body, --body=,
# -b, --body-file, --body-file=, -F (a path or `-` for stdin), or be absent
# (then --body carries only the footer). A body that already has a line
# starting with `HQ-Fingerprint:` is left alone. With no fingerprint, or when
# the setting is off, this execs `gh pr create "$@"` unchanged.
#
# The setting is read from personal/settings/fingerprint.yaml, then
# core/settings/fingerprint.yaml (`enabled: true|false`). A missing file or key
# means enabled. gh output is printed unchanged; the PR URL stays on the last
# line. Bash 3.2 safe, no jq.

set -uo pipefail

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd -P)}"

_hq_prc_yaml_scalar() { # file key
  local line=""
  [ -f "$1" ] || return 1
  line="$(grep -E "^$2:[[:space:]]*" "$1" 2>/dev/null | head -n 1)" || return 1
  [ -n "$line" ] || return 1
  printf '%s' "${line#*:}" | sed -E 's/[[:space:]]*#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//'
}

_hq_prc_enabled() {
  local v=""
  v="$(_hq_prc_yaml_scalar "$HQ_ROOT/personal/settings/fingerprint.yaml" enabled)" \
    || v="$(_hq_prc_yaml_scalar "$HQ_ROOT/core/settings/fingerprint.yaml" enabled)" \
    || v=""
  v="$(printf '%s' "$v" | tr -d "\"'" | tr '[:upper:]' '[:lower:]')"
  case "$v" in
    false|no|off|0) return 1 ;;
  esac
  return 0
}

# Cache for the builder result, so repeated calls in one session do not boot
# node. Keyed on the session id plus the hq binary path and mtime; an empty
# result is cached too; entries expire after 24 h.
# GNU stat goes first: GNU reads `stat -f %m` as a filesystem query on two
# operands, prints that report to stdout and exits 1, so a BSD-first chain
# leaks text into the cache key and the age arithmetic. BSD stat rejects -c
# without output. Prints a decimal epoch or nothing.
_hq_prc_mtime() { # path
  local m=""
  m="$(stat -c %Y "$1" 2>/dev/null)" || m=""
  case "$m" in ''|*[!0-9]*) m="$(stat -f %m "$1" 2>/dev/null)" || m="" ;; esac
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$m"
}

# Prints the first valid session id in the environment, or `none`. Same order
# and charset as core/scripts/lib/session-id.sh and the fingerprint helper.
_hq_prc_session_id() {
  local var="" val=""
  for var in HQ_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID \
             CODEX_SESSION_ID CODEX_THREAD_ID GROK_SESSION_ID; do
    val="${!var:-}"
    val="${val//[[:space:]]/}"
    [ -n "$val" ] || continue
    case "$val" in
      .|..|*[!A-Za-z0-9._-]*) continue ;;
    esac
    printf '%s\n' "$val"
    return 0
  done
  printf 'none\n'
}

_hq_prc_cache_file() { # resolved-bin
  local dir="${HQ_FINGERPRINT_CACHE_DIR:-${TMPDIR:-/tmp}/hq-fingerprint-cache-$(id -u 2>/dev/null)}"
  local sid=""
  sid="$(_hq_prc_session_id)"
  local key=""
  key="$(printf '%s|%s|%s' "$sid" "$1" "$(_hq_prc_mtime "$1")" | cksum | tr -d ' \t')" || return 1
  mkdir -p "$dir" 2>/dev/null && chmod 700 "$dir" 2>/dev/null || return 1
  printf '%s/fp-%s' "$dir" "$key"
}

# Prints the fingerprint value, or nothing on any failure. Same builder call
# shape as the US-003 hook stage, capped at 2 s.
hq_fingerprint_value() {
  local bin="${HQ_FINGERPRINT_BIN:-hq}" limit="${HQ_FINGERPRINT_TIMEOUT_SECS:-2}"
  local tmp="" pid="" waited=0 max_ms=0 out="" value="" path="" cache="" age=0
  _hq_prc_enabled || return 0
  case "$limit" in ''|*[!0-9]*) limit=2 ;; esac
  # shellcheck disable=SC2086
  path="$(command -v ${bin%% *} 2>/dev/null)" || return 0
  [ -n "$path" ] || return 0
  cache="$(_hq_prc_cache_file "$path")" || cache=""
  if [ -n "$cache" ] && [ -f "$cache" ]; then
    age=$(($(date +%s) - $(_hq_prc_mtime "$cache" || echo 0)))
    if [ "$age" -ge 0 ] && [ "$age" -lt 86400 ]; then
      cat "$cache" 2>/dev/null
      return 0
    fi
  fi
  max_ms=$((limit * 1000))
  tmp="$(mktemp "${TMPDIR:-/tmp}/hq-pr-fp.XXXXXX" 2>/dev/null)" || return 0
  # Called inside $( ), so these traps belong to that subshell. The global
  # keeps the path visible to the EXIT trap after this function returns.
  _hq_prc_fp_tmp="$tmp"
  trap 'rm -f "${_hq_prc_fp_tmp:-}"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  # The builder runs in its own process group (set -m) so the 2 s cut kills
  # hq and any node it started.
  set -m
  # shellcheck disable=SC2086
  ( exec $bin fingerprint self --json --offline >"$tmp" 2>/dev/null </dev/null ) &
  pid=$!
  set +m
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$max_ms" ]; then
      kill -KILL -- -"$pid" 2>/dev/null || {
        pkill -KILL -P "$pid" 2>/dev/null
        kill -KILL "$pid" 2>/dev/null
      }
      wait "$pid" 2>/dev/null || true
      rm -f "$tmp"
      [ -z "$cache" ] || : >"$cache" 2>/dev/null
      return 0
    fi
    sleep 0.02
    waited=$((waited + 20))
  done
  if ! wait "$pid" 2>/dev/null; then
    rm -f "$tmp"
    [ -z "$cache" ] || : >"$cache" 2>/dev/null
    return 0
  fi
  out="$(tr -d '\r\n' <"$tmp" 2>/dev/null)" || out=""
  rm -f "$tmp"
  value="$(printf '%s' "$out" | sed -n -E 's/.*"fingerprint"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')" || value=""
  case "$value" in
    hqfp[0-9]*:*) ;;
    *) value="" ;;
  esac
  case "$value" in
    *[!A-Za-z0-9:._@+/=-]*) value="" ;;
  esac
  [ -z "$cache" ] || printf '%s' "$value" >"$cache" 2>/dev/null
  printf '%s' "$value"
}

orig=("$@")
FP="$(hq_fingerprint_value)"
# The PostToolUse hook pr-fingerprint-footer.sh reuses this lookup only.
if [ "${HQ_PR_CREATE_FINGERPRINT_ONLY:-}" = 1 ]; then
  printf '%s' "$FP"
  exit 0
fi

# Hand gh the arguments exactly as given.
passthrough() {
  exec gh pr create ${orig[@]+"${orig[@]}"}
}

[ -n "$FP" ] || passthrough

# Split argv into the body source and everything else. Arguments after a bare
# `--` are not parsed. The body flag is passed first so it stays ahead of `--`.
# A repeated body flag of one kind follows gh: the last value wins and the
# earlier ones are dropped. Mixing --body and --body-file is a gh usage error,
# so that argv goes to gh unchanged for gh to report.
body_kind=""   # "", text, file
body_val=""
mixed=0
rest=()
parsing=1
set_body() { # kind value
  if [ -n "$body_kind" ] && [ "$body_kind" != "$1" ]; then
    mixed=1
  fi
  body_kind="$1"
  body_val="$2"
}
while [ "$#" -gt 0 ]; do
  a="$1"
  shift
  if [ "$parsing" -eq 0 ]; then
    rest+=("$a")
    continue
  fi
  case "$a" in
    --)
      parsing=0
      rest+=("$a")
      ;;
    --body|-b)
      [ "$#" -gt 0 ] || passthrough
      set_body text "$1"; shift
      ;;
    --body=*) set_body text "${a#--body=}" ;;
    -b=*) set_body text "${a#-b=}" ;;
    -b?*) set_body text "${a#-b}" ;;
    --body-file|-F)
      [ "$#" -gt 0 ] || passthrough
      set_body file "$1"; shift
      ;;
    --body-file=*) set_body file "${a#--body-file=}" ;;
    -F=*) set_body file "${a#-F=}" ;;
    -F?*) set_body file "${a#-F}" ;;
    *)
      rest+=("$a")
      ;;
  esac
done
[ "$mixed" -eq 0 ] || passthrough

body=""
case "$body_kind" in
  text) body="$body_val" ;;
  file)
    if [ "$body_val" = "-" ]; then
      body="$(cat; printf x)"
      body="${body%x}"
    elif [ -f "$body_val" ]; then
      body="$(cat -- "$body_val" && printf x)" || passthrough
      body="${body%x}"
    else
      passthrough
    fi
    ;;
esac

if printf '%s\n' "$body" | grep -q '^HQ-Fingerprint:'; then
  if [ "$body_kind" = file ] && [ "$body_val" = "-" ]; then
    # stdin is consumed; hand gh the text instead.
    exec gh pr create --body "$body" ${rest[@]+"${rest[@]}"}
  fi
  passthrough
fi

# Drop trailing newlines, then add the footer section.
while [ "${body%$'\n'}" != "$body" ]; do body="${body%$'\n'}"; done
footer="---"$'\n'"HQ-Fingerprint: $FP"
if [ -n "$body" ]; then
  body="$body"$'\n\n'"$footer"
else
  body=$'\n'"$footer"
fi

if [ "$body_kind" = file ]; then
  # gh runs as a child (no exec) so the EXIT trap removes the temp body file.
  tmp=""
  trap 'rm -f "${tmp:-}"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  tmp="$(mktemp "${TMPDIR:-/tmp}/hq-pr-body.XXXXXX")" || passthrough
  printf '%s\n' "$body" >"$tmp"
  gh pr create --body-file "$tmp" ${rest[@]+"${rest[@]}"}
  exit $?
fi
exec gh pr create --body "$body" ${rest[@]+"${rest[@]}"}
