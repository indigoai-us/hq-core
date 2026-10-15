# shellcheck shell=bash
# hq-core: public
# fingerprint.sh - explicit HQ-Fingerprint trailer for commits that skip hooks.
#
# SOURCED, never executed:  . "$HQ_ROOT/core/scripts/lib/fingerprint.sh"
# Bash 3.2 safe, set -euo pipefail safe, no jq/python/node of its own.
#
# HQ scripts that commit session work with --no-verify (the run-project
# orchestrator, handoff-finalize, handoff-knowledge-commit) never reach the
# commit-msg hook that stamps HQ-Fingerprint, so they pass the trailer to
# `git commit` themselves. The autosave hook does not: a fingerprint marks
# work a session produced, never the session saving itself.
#
#   hq_fingerprint_trailer_args [hq_root]
#     Prints two lines, `--trailer` and `HQ-Fingerprint: <value>`, when
#     `${HQ_FINGERPRINT_BIN:-hq} fingerprint self --json --offline` returns a
#     non-null fingerprint within HQ_FINGERPRINT_TIMEOUT_SECS (default 2).
#     Prints nothing, and returns 0, in every other case: the setting is
#     `enabled: false`, there is no session id, hq is missing or older than
#     HQ_FINGERPRINT_MIN_HQ_CLI, the call times out or fails, the fingerprint
#     is null or malformed, or this git has no --trailer.
#
#   hq_fingerprint_trailer_load [hq_root]
#     Runs hq_fingerprint_trailer_args and stores its lines in the global
#     array HQ_FINGERPRINT_TRAILER_ARGS (empty when nothing was printed).
#
# Calling pattern (use this one everywhere; it keeps the value as one argv
# word and is safe under `set -u` with an empty array on Bash 3.2):
#
#   hq_fingerprint_trailer_load "$HQ_ROOT"
#   git commit -m "..." ${HQ_FINGERPRINT_TRAILER_ARGS[@]+"${HQ_FINGERPRINT_TRAILER_ARGS[@]}"}
#
# Cost: the builder is a full node boot, so it runs at most once per session
# however many callers ask. The result is
# cached in workspace/sessions/<session id>/fingerprint-trailer.cache, keyed by
# the session id and the hq-cli version. A null or failed result is cached for
# the rest of the session too, so a later `hq login` takes effect in the next
# session. The session id comes from the same environment variables, in the
# same order, as core/scripts/lib/session-id.sh. With no session id there is
# no cache key, so nothing is printed and the builder never runs.
#
# The hq-cli version floor alone does not decide whether hq can build a
# fingerprint: an install at or above the floor is also probed once, by running
# the builder, and the answer is cached per hq binary in
# ~/.hq/cache/fingerprint-cli-<cksum>.cache. The key is the resolved binary
# path, its mtime and its version, so a new hq install (or reinstall) is probed
# again; any answer also expires after HQ_FINGERPRINT_CAPABILITY_TTL_SECS
# (default 86400, 24 h). A negative answer (unknown command, non-zero exit,
# timeout, no JSON) is cached the same way, so an hq without `hq fingerprint`
# costs one node boot per install per day across all sessions, not one per
# session. The cache is per machine rather than per session for exactly that
# reason: a per-session cache would make every new session pay the boot again.
# When ~/.hq/cache cannot be written the probe still runs, and the per-session
# trailer cache still limits it to once per session.
#
#   hq_fp_cli_version
#     Prints the installed hq-cli version (read from its package.json, no node
#     spawn) and returns 0, or returns 1 when hq is missing or unreadable.
#
#   hq_fp_cli_capable
#     Returns 0 when the installed hq-cli is at or above the floor and its
#     cached (or fresh) probe says it ships `hq fingerprint`, 1 otherwise.
#     Prints nothing; its only side effect is the per-binary cache file.
#
# HQ_FINGERPRINT_BIN overrides the builder command. It is a space-separated
# command: it is word-split with no quote handling, so it cannot hold a path
# that contains spaces (put such a binary on PATH or behind a wrapper script).
# Setting it bypasses the hq-cli version floor and the capability probe; tests
# and the pre-release live check use it.
#
# The setting is read from personal/settings/fingerprint.yaml, then
# core/settings/fingerprint.yaml (`enabled: true|false`, top-level key only). A
# missing file or key means enabled. The builder is offline, so no commit path
# gains a network call.

# First hq-cli version that ships `hq fingerprint`. An older install is skipped
# without spawning anything; a newer one still has to pass the capability probe.
# PLACEHOLDER: 5.345.131 is not a released builder version. The senior sets the
# real hq-cli tag here before the hq-core release.
HQ_FINGERPRINT_MIN_HQ_CLI="5.345.131"

HQ_FINGERPRINT_TRAILER_ARGS=()

_HQ_FP_LIB_DIR="${BASH_SOURCE[0]%/*}"
[ "$_HQ_FP_LIB_DIR" != "${BASH_SOURCE[0]}" ] || _HQ_FP_LIB_DIR="."
_HQ_FP_CACHE_SCHEMA="hq-fingerprint-trailer.v2"
_HQ_FP_CLI_CACHE_SCHEMA="hq-fingerprint-cli.v1"

_hq_fp_yaml_scalar() { # file key
  local line=""
  [ -f "$1" ] || return 1
  line="$(grep -E "^$2:[[:space:]]*" "$1" 2>/dev/null | head -n 1)" || return 1
  [ -n "$line" ] || return 1
  printf '%s' "${line#*:}" | sed -E 's/[[:space:]]*#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//'
}

_hq_fp_enabled() { # hq_root
  local v=""
  v="$(_hq_fp_yaml_scalar "$1/personal/settings/fingerprint.yaml" enabled)" \
    || v="$(_hq_fp_yaml_scalar "$1/core/settings/fingerprint.yaml" enabled)" \
    || v=""
  v="$(printf '%s' "$v" | tr -d "\"'" | tr '[:upper:]' '[:lower:]')"
  case "$v" in
    false|no|off|0) return 1 ;;
  esac
  return 0
}

# Sets _HQ_FP_SID to the first valid session id in the environment, using the
# precedence and charset of core/scripts/lib/session-id.sh. Returns 1 when none.
_hq_fp_session_id() {
  local var val
  _HQ_FP_SID=""
  for var in HQ_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID \
             CODEX_SESSION_ID CODEX_THREAD_ID GROK_SESSION_ID; do
    val="${!var:-}"
    val="${val//[[:space:]]/}"
    [ -n "$val" ] || continue
    case "$val" in
      .|..|*[!A-Za-z0-9._-]*) continue ;;
    esac
    _HQ_FP_SID="$val"
    return 0
  done
  return 1
}

# Sets _HQ_FP_VERSION to the installed hq-cli version, read from the package's
# package.json with no node spawn, _HQ_FP_CLI_CMD to the hq command on PATH and
# _HQ_FP_CLI_PATH to the file it resolves to. Returns 1 when hq is missing or
# the version cannot be read that way (the caller then skips the builder).
_hq_fp_read_cli() {
  local cmd="" resolved="" dir="" parent="" version=""
  _HQ_FP_VERSION=""
  _HQ_FP_CLI_CMD=""
  _HQ_FP_CLI_PATH=""
  if ! declare -F _hq_cli_floor_package_version >/dev/null 2>&1; then
    [ -f "$_HQ_FP_LIB_DIR/hq-cli-floor.sh" ] || return 1
    # shellcheck source=hq-cli-floor.sh
    . "$_HQ_FP_LIB_DIR/hq-cli-floor.sh" 2>/dev/null || return 1
  fi
  cmd="$(command -v hq 2>/dev/null)" || return 1
  [ -n "$cmd" ] || return 1
  resolved="$(_hq_cli_floor_resolve_executable "$cmd" 2>/dev/null)" || return 1
  dir="${resolved%/*}"
  while [ -n "$dir" ] && [ "$dir" != / ]; do
    if [ -f "$dir/package.json" ]; then
      version="$(_hq_cli_floor_package_version "$dir/package.json" 2>/dev/null)" || version=""
      if [ -n "$version" ]; then
        _HQ_FP_VERSION="$version"
        _HQ_FP_CLI_CMD="$cmd"
        _HQ_FP_CLI_PATH="$resolved"
        return 0
      fi
    fi
    parent="${dir%/*}"
    [ -n "$parent" ] || parent="/"
    [ "$parent" != "$dir" ] || break
    dir="$parent"
  done
  return 1
}

hq_fp_cli_version() {
  _hq_fp_read_cli || return 1
  printf '%s\n' "$_HQ_FP_VERSION"
}

# Sets _HQ_FP_CLI_CACHE to the per-machine capability cache file for the binary
# _hq_fp_read_cli found, and _HQ_FP_CLI_KEY to its key (resolved path, mtime,
# version). Returns 1 when there is no HOME or the mtime cannot be read.
_hq_fp_cli_cache_path() {
  local mtime="" sum=""
  _HQ_FP_CLI_KEY=""
  _HQ_FP_CLI_CACHE=""
  [ -n "${HOME:-}" ] || return 1
  mtime="$(stat -c %Y "$_HQ_FP_CLI_PATH" 2>/dev/null)" \
    || mtime="$(stat -f %m "$_HQ_FP_CLI_PATH" 2>/dev/null)" \
    || mtime=""
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  _HQ_FP_CLI_KEY="$_HQ_FP_CLI_PATH|$mtime|$_HQ_FP_VERSION"
  sum="$(printf '%s' "$_HQ_FP_CLI_KEY" | cksum 2>/dev/null)" || return 1
  sum="${sum%% *}"
  case "$sum" in ''|*[!0-9]*) return 1 ;; esac
  _HQ_FP_CLI_CACHE="$HOME/.hq/cache/fingerprint-cli-$sum.cache"
  return 0
}

# Reads the cached capability for the current binary. Returns 0 for capable,
# 1 for incapable, 2 when there is no fresh entry.
_hq_fp_cli_cache_read() {
  local ttl="${HQ_FINGERPRINT_CAPABILITY_TTL_SECS:-86400}"
  local c_schema="" c_key="" c_result="" c_stamp="" now=""
  case "$ttl" in ''|*[!0-9]*) ttl=86400 ;; esac
  _hq_fp_cli_cache_path || return 2
  [ -f "$_HQ_FP_CLI_CACHE" ] || return 2
  {
    IFS= read -r c_schema || c_schema=""
    IFS= read -r c_key || c_key=""
    IFS= read -r c_result || c_result=""
    IFS= read -r c_stamp || c_stamp=""
  } <"$_HQ_FP_CLI_CACHE" 2>/dev/null || true
  [ "$c_schema" = "$_HQ_FP_CLI_CACHE_SCHEMA" ] || return 2
  [ "$c_key" = "$_HQ_FP_CLI_KEY" ] || return 2
  case "$c_stamp" in ''|*[!0-9]*) return 2 ;; esac
  now="$(date +%s 2>/dev/null)" || return 2
  case "$now" in ''|*[!0-9]*) return 2 ;; esac
  [ $((now - c_stamp)) -lt "$ttl" ] || return 2
  case "$c_result" in
    capable) return 0 ;;
    incapable) return 1 ;;
  esac
  return 2
}

# Best effort: a capability that cannot be cached only costs the next session
# one probe. Write to a temp file and rename so readers never see half.
_hq_fp_cli_cache_write() { # capable|incapable
  local tmp=""
  [ -n "$_HQ_FP_CLI_CACHE" ] || _hq_fp_cli_cache_path || return 0
  mkdir -p "${_HQ_FP_CLI_CACHE%/*}" 2>/dev/null || return 0
  tmp="$_HQ_FP_CLI_CACHE.$$"
  if printf '%s\n' "$_HQ_FP_CLI_CACHE_SCHEMA" "$_HQ_FP_CLI_KEY" "$1" \
      "$(date +%s 2>/dev/null || echo 0)" >"$tmp" 2>/dev/null; then
    mv -f "$tmp" "$_HQ_FP_CLI_CACHE" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  fi
  return 0
}

# Probes the binary _hq_fp_read_cli found by running the builder once, records
# the capability in the per-machine cache, and leaves the builder's result in
# _HQ_FP_VALUE so a caller that wanted a trailer does not boot node twice.
_hq_fp_cli_probe() { # limit_secs
  _hq_fp_build "$1" "$_HQ_FP_CLI_CMD"
  [ "$_HQ_FP_PROBED" = 1 ] || return 1
  if [ "$_HQ_FP_CAPABLE" = 1 ]; then
    _hq_fp_cli_cache_write capable
    return 0
  fi
  _hq_fp_cli_cache_write incapable
  return 1
}

hq_fp_cli_capable() {
  local limit="${HQ_FINGERPRINT_TIMEOUT_SECS:-2}" rc=0
  case "$limit" in ''|*[!0-9]*) limit=2 ;; esac
  _hq_fp_read_cli || return 1
  hq_cli_version_ge "$_HQ_FP_VERSION" "$HQ_FINGERPRINT_MIN_HQ_CLI" 2>/dev/null || return 1
  _hq_fp_cli_cache_read || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
  esac
  _hq_fp_cli_probe "$limit" >/dev/null 2>&1
}

# Stops a builder that overran: TERM, a short grace period, then KILL, so a
# builder that ignores TERM cannot hold the caller until the hook timeout.
_hq_fp_stop() { # pid
  local pid="$1" grace=0
  pkill -TERM -P "$pid" 2>/dev/null || true
  kill -TERM "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && [ "$grace" -lt 5 ]; do
    sleep 0.05
    grace=$((grace + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    pkill -KILL -P "$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
}

# Runs the builder once and sets _HQ_FP_VALUE to a well-formed fingerprint, or
# to "" for every failure. Sets _HQ_FP_PROBED=1 when the command actually ran
# (or timed out), and _HQ_FP_CAPABLE=1 when it exited 0 with a "fingerprint"
# key in its JSON, whether that value is a string or null.
_hq_fp_build() { # limit_secs command [args...]
  local limit="$1" tmp="" pid="" waited=0 max_ms=0 out="" value="" help=""
  shift
  _HQ_FP_VALUE=""
  _HQ_FP_PROBED=0
  _HQ_FP_CAPABLE=0
  # `git commit --trailer` needs git 2.32+; an older git must keep committing.
  # Capture the help text first: piping into `grep -q` lets git die of SIGPIPE,
  # which fails the check in callers running under `set -o pipefail`.
  help="$(git commit -h 2>&1 || true)"
  case "$help" in
    *--trailer*) ;;
    *) return 0 ;;
  esac
  command -v "$1" >/dev/null 2>&1 || return 0
  max_ms=$((limit * 1000))
  tmp="$(mktemp "${TMPDIR:-/tmp}/hq-fingerprint.XXXXXX" 2>/dev/null)" || return 0

  # Portable timeout (no GNU `timeout` on macOS): run the builder in the
  # background with stdout in a file, never on our own stdout, so a caller's
  # $(...) cannot be held open by a hung child. Poll, then stop it on overrun.
  # The first checks come after a few ms, so a fast builder is not charged a
  # full 100 ms tick; the interval grows to 100 ms for a slow one.
  ( exec "$@" fingerprint self --json --offline >"$tmp" 2>/dev/null </dev/null ) &
  pid=$!
  _HQ_FP_PROBED=1
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$max_ms" ]; then
      _hq_fp_stop "$pid"
      rm -f "$tmp"
      return 0
    fi
    if [ "$waited" -lt 20 ]; then
      sleep 0.005
      waited=$((waited + 5))
    elif [ "$waited" -lt 200 ]; then
      sleep 0.02
      waited=$((waited + 20))
    else
      sleep 0.1
      waited=$((waited + 100))
    fi
  done
  if ! wait "$pid" 2>/dev/null; then
    rm -f "$tmp"
    return 0
  fi
  out="$(tr -d '\r\n' <"$tmp" 2>/dev/null)" || out=""
  rm -f "$tmp"

  case "$out" in
    *'"fingerprint"'*) _HQ_FP_CAPABLE=1 ;;
    *) return 0 ;;
  esac
  value="$(printf '%s' "$out" | sed -n -E 's/.*"fingerprint"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')" || value=""
  [ -n "$value" ] || return 0
  # Only a well-formed token becomes a trailer; anything else is ignored.
  case "$value" in
    hqfp[0-9]*:*) ;;
    *) return 0 ;;
  esac
  case "$value" in
    *[!A-Za-z0-9:._@+/=-]*) return 0 ;;
  esac
  _HQ_FP_VALUE="$value"
  return 0
}

hq_fingerprint_trailer_args() {
  local root="${1:-}" bin="${HQ_FINGERPRINT_BIN:-}" limit="${HQ_FINGERPRINT_TIMEOUT_SECS:-2}"
  local key="" cache_dir="" cache="" c_schema="" c_key="" c_result="" cache_tmp="" rc=0
  if [ -z "$root" ]; then
    root="$(cd "$_HQ_FP_LIB_DIR/../../.." 2>/dev/null && pwd -P)" || return 0
  fi
  _hq_fp_enabled "$root" || return 0
  _hq_fp_session_id || return 0
  case "$limit" in ''|*[!0-9]*) limit=2 ;; esac

  if [ -n "$bin" ]; then
    key="bin:$bin"
  else
    _hq_fp_read_cli || return 0
    hq_cli_version_ge "$_HQ_FP_VERSION" "$HQ_FINGERPRINT_MIN_HQ_CLI" 2>/dev/null || return 0
    key="hq-cli:$_HQ_FP_VERSION"
  fi

  cache_dir="$root/workspace/sessions/$_HQ_FP_SID"
  cache="$cache_dir/fingerprint-trailer.cache"
  if [ -f "$cache" ]; then
    {
      IFS= read -r c_schema || c_schema=""
      IFS= read -r c_key || c_key=""
      IFS= read -r c_result || c_result=""
    } <"$cache" 2>/dev/null || true
    if [ "$c_schema" = "$_HQ_FP_CACHE_SCHEMA" ] && [ "$c_key" = "$key" ]; then
      case "$c_result" in
        value:hqfp*)
          printf '%s\n' "--trailer" "HQ-Fingerprint: ${c_result#value:}"
          return 0
          ;;
        none) return 0 ;;
      esac
    fi
  fi

  if [ -n "$bin" ]; then
    # shellcheck disable=SC2086
    _hq_fp_build "$limit" $bin
  else
    _hq_fp_cli_cache_read || rc=$?
    case "$rc" in
      0) _hq_fp_build "$limit" "$_HQ_FP_CLI_CMD" ;;
      1) _HQ_FP_VALUE="" ;;
      *) _hq_fp_cli_probe "$limit" || true ;;
    esac
  fi

  # Best effort: a cache that cannot be written only costs the next call a
  # builder run. Write to a temp file and rename so readers never see half.
  if mkdir -p "$cache_dir" 2>/dev/null; then
    cache_tmp="$cache.$$"
    if [ -n "$_HQ_FP_VALUE" ]; then
      c_result="value:$_HQ_FP_VALUE"
    else
      c_result="none"
    fi
    if printf '%s\n' "$_HQ_FP_CACHE_SCHEMA" "$key" "$c_result" >"$cache_tmp" 2>/dev/null; then
      mv -f "$cache_tmp" "$cache" 2>/dev/null || rm -f "$cache_tmp" 2>/dev/null || true
    fi
  fi

  [ -n "$_HQ_FP_VALUE" ] || return 0
  printf '%s\n' "--trailer" "HQ-Fingerprint: $_HQ_FP_VALUE"
  return 0
}

hq_fingerprint_trailer_load() {
  local line=""
  HQ_FINGERPRINT_TRAILER_ARGS=()
  while IFS= read -r line; do
    [ -n "$line" ] && HQ_FINGERPRINT_TRAILER_ARGS+=("$line")
  done <<EOF
$(hq_fingerprint_trailer_args "${1:-}")
EOF
  return 0
}
