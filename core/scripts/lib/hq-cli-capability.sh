#!/usr/bin/env bash
# hq-core: public
#
# hq-cli-capability.sh - does the installed hq CLI have `hq fingerprint`?
#
# The commit-msg stage (core/scripts/hq-fingerprint-hooks.sh) asks this before
# it starts node. An hq CLI older than HQ_FINGERPRINT_MIN_HQ_CLI is skipped
# from its package.json version alone. A newer one that still fails the probe
# takes about a second to fail, on every commit, so the answer is cached per
# machine in one file shared by every session and every HQ folder:
#
#   ~/.hq/fingerprint-capability.cache   (HQ_FINGERPRINT_CAPABILITY_CACHE)
#
# One line per hq binary: <schema>\t<key>\t<result>\t<epoch seconds>
#   key     resolved path|mtime|version, so an upgrade or reinstall misses
#   result  capable, or a negative: exit<N> (no such command), timeout,
#           nooutput (exit 0 without a "fingerprint" key), below-floor
#           (version older than HQ_FINGERPRINT_MIN_HQ_CLI, never started)
# Entries older than HQ_FINGERPRINT_CAPABILITY_TTL_SECS (default 86400) are
# ignored; 0 turns the cache off.
#
# The version comes from the CLI package's package.json (no node spawn). The
# helpers are adapted from the US-004 lib (core/scripts/lib/fingerprint.sh:
# _hq_fp_session_id, _hq_fp_read_cli, _hq_fp_cli_cache_*), so both can move
# to this file after merge.
#
# Bash 3.2-safe, no python/node/jq: it runs inside git hooks.

_HQ_CAP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)"
HQ_CAP_SCHEMA="hqcap1"

# First hq-cli version that ships `hq fingerprint`. An older install is skipped
# without spawning anything; a newer one still has to pass the capability probe.
# PLACEHOLDER: 5.345.131 is not a released builder version. The senior sets the
# real hq-cli tag here before the hq-core release.
# shellcheck disable=SC2034 # read by hq-fingerprint-hooks.sh, which sources this lib
HQ_FINGERPRINT_MIN_HQ_CLI="5.345.131"

hq_cap_cache_file() {
  printf '%s' "${HQ_FINGERPRINT_CAPABILITY_CACHE:-${HOME:-/nonexistent}/.hq/fingerprint-capability.cache}"
}

# Sets HQ_CAP_SID to the agent session id, or returns 1. Ids that could
# escape a folder name are ignored.
hq_cap_session_id() {
  local var val
  HQ_CAP_SID=""
  for var in HQ_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID \
             CODEX_SESSION_ID CODEX_THREAD_ID GROK_SESSION_ID; do
    eval "val=\"\${$var:-}\""
    val="${val//[[:space:]]/}"
    [ -n "$val" ] || continue
    case "$val" in
      .|..|*[!A-Za-z0-9._-]*) continue ;;
    esac
    # shellcheck disable=SC2034 # read by the sourcing script
    HQ_CAP_SID="$val"
    return 0
  done
  return 1
}

# Reads the first "name" and "version" of a package.json with shell builtins.
_hq_cap_package_version() { # package.json
  local line name="" version=""
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -z "$name" ] && [[ "$line" =~ \"name\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
      name="${BASH_REMATCH[1]}"
    fi
    if [ -z "$version" ] && [[ "$line" =~ \"version\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
      version="${BASH_REMATCH[1]}"
    fi
    [ -n "$name" ] && [ -n "$version" ] && break
  done <"$1"
  [ "$name" = "@indigoai-us/hq-cli" ] && [ -n "$version" ] || return 1
  printf '%s' "$version"
}

# Sets HQ_CAP_CMD (hq on PATH), HQ_CAP_PATH (the file it resolves to),
# HQ_CAP_VERSION (package version, or - when there is no hq-cli
# package.json above it) and HQ_CAP_KEY. Returns 1 when hq is not on PATH.
hq_cap_read_cli() {
  local dir parent mtime=""
  HQ_CAP_CMD=""; HQ_CAP_PATH=""; HQ_CAP_VERSION="-"; HQ_CAP_KEY=""
  HQ_CAP_CMD="$(command -v hq 2>/dev/null)" || return 1
  case "$HQ_CAP_CMD" in /*) ;; *) return 1 ;; esac
  if ! declare -F _hq_cli_floor_resolve_executable >/dev/null 2>&1; then
    # shellcheck source=hq-cli-floor.sh
    . "$_HQ_CAP_LIB_DIR/hq-cli-floor.sh" 2>/dev/null || return 1
  fi
  HQ_CAP_PATH="$(_hq_cli_floor_resolve_executable "$HQ_CAP_CMD" 2>/dev/null)" || HQ_CAP_PATH="$HQ_CAP_CMD"
  dir="${HQ_CAP_PATH%/*}"
  while [ -n "$dir" ] && [ "$dir" != / ]; do
    if [ -f "$dir/package.json" ]; then
      HQ_CAP_VERSION="$(_hq_cap_package_version "$dir/package.json" 2>/dev/null)" && break
      HQ_CAP_VERSION="-"
    fi
    parent="${dir%/*}"
    [ "$parent" != "$dir" ] || break
    dir="$parent"
  done
  # BSD stat first on macOS and BSD, GNU stat first elsewhere: one spawn.
  case "${OSTYPE:-}" in
    darwin*|*bsd*) mtime="$(stat -f %m "$HQ_CAP_PATH" 2>/dev/null)" || mtime="$(stat -c %Y "$HQ_CAP_PATH" 2>/dev/null)" || mtime="0" ;;
    *) mtime="$(stat -c %Y "$HQ_CAP_PATH" 2>/dev/null)" || mtime="$(stat -f %m "$HQ_CAP_PATH" 2>/dev/null)" || mtime="0" ;;
  esac
  case "$mtime" in ''|*[!0-9]*) mtime=0 ;; esac
  # shellcheck disable=SC2034 # read by the sourcing script
  HQ_CAP_KEY="$HQ_CAP_PATH|$mtime|$HQ_CAP_VERSION"
  return 0
}

_hq_cap_now() { printf '%s' "${EPOCHSECONDS:-$(date +%s)}"; }

_hq_cap_ttl() {
  local ttl="${HQ_FINGERPRINT_CAPABILITY_TTL_SECS:-86400}"
  case "$ttl" in ''|*[!0-9]*) ttl=86400 ;; esac
  printf '%s' "$ttl"
}

# Looks up a key. Prints the cached result and returns 0 (capable), 1 (a
# cached negative) or 2 (no fresh entry).
hq_cap_cache_read() { # key
  local file schema key result stamp ttl now
  ttl="$(_hq_cap_ttl)"
  [ "$ttl" -gt 0 ] || return 2
  file="$(hq_cap_cache_file)"
  [ -f "$file" ] || return 2
  while IFS="$(printf '\t')" read -r schema key result stamp; do
    [ "$schema" = "$HQ_CAP_SCHEMA" ] && [ "$key" = "$1" ] || continue
    case "$stamp" in ''|*[!0-9]*) return 2 ;; esac
    now="$(_hq_cap_now)"
    [ $((now - stamp)) -lt "$ttl" ] && [ "$stamp" -le "$now" ] || return 2
    printf '%s' "$result"
    [ "$result" = "capable" ] && return 0
    return 1
  done <"$file"
  return 2
}

# Records a result for a key, replacing an older line for the same key.
hq_cap_cache_write() { # key result
  local file tmp schema key result stamp
  [ "$(_hq_cap_ttl)" -gt 0 ] || return 0
  file="$(hq_cap_cache_file)"
  mkdir -p "${file%/*}" 2>/dev/null || return 0
  tmp="$file.$$"
  {
    if [ -f "$file" ]; then
      while IFS="$(printf '\t')" read -r schema key result stamp; do
        [ "$schema" = "$HQ_CAP_SCHEMA" ] || continue
        [ "$key" = "$1" ] && continue
        printf '%s\t%s\t%s\t%s\n' "$schema" "$key" "$result" "$stamp"
      done <"$file"
    fi
    printf '%s\t%s\t%s\t%s\n' "$HQ_CAP_SCHEMA" "$1" "$2" "$(_hq_cap_now)"
  } >"$tmp" 2>/dev/null && mv -f "$tmp" "$file" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  return 0
}
