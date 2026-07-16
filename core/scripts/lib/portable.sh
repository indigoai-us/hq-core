# shellcheck shell=bash
# portable.sh — shared OS-portability helpers for hq-core shell scripts.
#
# SOURCED, never executed:  . "$ROOT/core/scripts/lib/portable.sh"
# bash 3.2 safe; works under Linux, macOS, and Windows Git Bash with set -u.
#
# Canonicalizes good in-repo dual-implementation patterns:
#   - work-mesh-lib.sh wm_file_mtime (numeric-probe dual stat)
#   - archive-old-threads.sh dual stat / date -d | date -v
#   - compute-checksums.sh Git Bash awareness
#
# JSON engines are NOT here — source core/scripts/hook-lib.sh (hq_json_get /
# hq_json_encode: jq first, then node). This file owns OS primitives + hard-fail
# jq install messaging only.

# portable_stat_mtime <path>
#   Print mtime as epoch seconds. Uses BSD-form stat -f first, accepts only a
#   strictly numeric result (GNU stat -f is filesystem mode and may print text),
#   then falls through to GNU stat -c. Mirrors work-mesh-lib.sh:215-230.
#   Returns 1 when both forms fail.
portable_stat_mtime() {
  local f="${1:-}" value
  [ -n "$f" ] || return 1
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

# portable_sed_inplace <sed-script> <file> [extra sed args...]
#   In-place sed that works on both GNU sed (sed -i) and BSD sed (sed -i '').
portable_sed_inplace() {
  local script="${1:-}"
  local file="${2:-}"
  shift 2 2>/dev/null || true
  [ -n "$script" ] && [ -n "$file" ] || return 1
  [ -f "$file" ] || return 1
  # Prefer GNU form; fall back to BSD empty-suffix form.
  if sed --version >/dev/null 2>&1; then
    sed -i "$@" -e "$script" "$file"
  else
    sed -i '' "$@" -e "$script" "$file"
  fi
}

# portable_tmpdir
#   Print a writable temp directory (no trailing slash). Prefer TMPDIR, else /tmp.
portable_tmpdir() {
  local d="${TMPDIR:-/tmp}"
  # Strip trailing slash except for root.
  case "$d" in
    /) printf '%s' "$d" ;;
    */) printf '%s' "${d%/}" ;;
    *) printf '%s' "$d" ;;
  esac
}

# portable_date_epoch_to_iso <epoch_seconds>
#   Convert epoch seconds to UTC ISO-8601 (YYYY-MM-DDTHH:MM:SSZ).
#   Dual: GNU date -d @N / BSD date -r N.
portable_date_epoch_to_iso() {
  local epoch="${1:-}"
  case "$epoch" in
    ''|*[!0-9]*) return 1 ;;
  esac
  date -u -d "@${epoch}" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -r "$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || return 1
}

# portable_user
#   Print a filename-safe user key from USER or USERNAME (Git Bash often lacks USER).
portable_user() {
  local u="${USER:-${USERNAME:-unknown}}"
  # shellcheck disable=SC2001
  u="$(printf '%s' "$u" | sed 's/[^[:alnum:]_.-]/_/g')"
  [ -n "$u" ] || u="unknown"
  printf '%s' "$u"
}

# portable_jq_install_hint
#   Print multi-line per-OS jq install guidance to stdout.
portable_jq_install_hint() {
  # Single multi-OS line so portability lint does not flag brew-only messages.
  printf '%s\n' "Install jq: Windows: winget install jqlang.jq | choco install jq | scoop install jq; Linux: sudo apt install jq | sudo dnf install jq; macOS: brew install jq"
}

# require_jq
#   Return 0 if jq is on PATH. Otherwise print install guidance to stderr and
#   return 1. Caller decides whether to die. Does not implement JSON parse.
require_jq() {
  if command -v jq >/dev/null 2>&1; then
    return 0
  fi
  printf 'jq is required but not installed.\n' >&2
  portable_jq_install_hint >&2
  return 1
}
