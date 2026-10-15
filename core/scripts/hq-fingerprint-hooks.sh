#!/usr/bin/env bash
# hq-core: public
#
# hq-fingerprint-hooks.sh - stamp an `HQ-Fingerprint: hqfp1:...` trailer on
# commits made inside this HQ folder (on by default; see
# core/settings/fingerprint.yaml).
#
# The trailer records which HQ session, company and machine made the commit.
# The value comes from `hq fingerprint self --json --offline`. Only repos whose
# top level is inside $HQ_ROOT get it (repos/, workspace/worktrees/ and the
# HQ folder itself); every other repo on the computer is left alone.
#
#   status               what is wired now, and the recorded setting
#   enable [--replace]   wire the shared HQ git hook dispatcher
#                        (core/scripts/lib/git-hooks-dispatcher.sh) and turn
#                        the trailer on. Does not need the hq CLI: until it
#                        has `hq fingerprint`, the stage adds nothing.
#   disable [--dry-run]  turn the trailer off and record enabled: false in
#                        personal/settings/fingerprint.yaml so session start
#                        does not turn it back on. The dispatcher stays wired
#                        while the commit secret scan is on.
#   disable --keep-setting
#                        the same without writing the setting (session start
#                        does this when the setting is false).
#   hook commit-msg <file>
#                        the stage itself (called by the dispatcher). Never
#                        fails a commit and prints nothing; when it adds no
#                        trailer for a reason other than scope, it appends one
#                        line to ~/.hq/fingerprint-hook.log (kept under 1 MB,
#                        one older copy in fingerprint-hook.log.1).
#
# Speed: `enabled: false` stops the stage first. A commit made outside an
# agent session (no HQ_SESSION_ID, CLAUDE_CODE_SESSION_ID, ...) gets no
# trailer and starts nothing. An hq CLI older than HQ_FINGERPRINT_MIN_HQ_CLI
# (core/scripts/lib/hq-cli-capability.sh) is skipped without being started.
# A newer one is probed once; a failed probe is cached per hq binary for a day
# in ~/.hq/fingerprint-capability.cache. The result for this agent session,
# a fingerprint or "none", is kept in
# workspace/sessions/<session id>/fingerprint-trailer.cache, the same v2 file
# core/scripts/lib/fingerprint.sh reads and writes.
#
# Exit codes: 0 ok, 2 usage or setup error.
# Env: HQ_ROOT (default: this script's HQ), HQ_FINGERPRINT_BIN (override the
# hq command, for tests; skips the capability cache),
# HQ_FINGERPRINT_TIMEOUT_TENTHS (default 20 = 2 s),
# HQ_FINGERPRINT_CAPABILITY_CACHE, HQ_FINGERPRINT_CAPABILITY_TTL_SECS,
# HQ_SECRET_SCAN_HOOKS_DIR (default ~/.hq/git-hooks).
#
# Bash 3.2-safe, no python/node/jq: it runs inside git hooks.

set -u

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
SELF="$HQ_ROOT/core/scripts/hq-fingerprint-hooks.sh"
SETTING_CORE="$HQ_ROOT/core/settings/fingerprint.yaml"
SETTING_PERSONAL="$HQ_ROOT/personal/settings/fingerprint.yaml"
# No HOME (a stripped hook environment): no log, the commit still goes ahead.
LOG=""
[ -n "${HOME:-}" ] && LOG="$HOME/.hq/fingerprint-hook.log"
LOG_MAX_BYTES=1048576
TRAILER_KEY="HQ-Fingerprint"
SESSION_CACHE_SCHEMA="hq-fingerprint-trailer.v2"
# shellcheck disable=SC2034 # read by ghd_die in the sourced lib
GHD_PROG="hq-fingerprint-hooks"
# shellcheck source=lib/git-hooks-dispatcher.sh
. "$HQ_ROOT/core/scripts/lib/git-hooks-dispatcher.sh"
# shellcheck source=lib/hq-cli-capability.sh
. "$HQ_ROOT/core/scripts/lib/hq-cli-capability.sh"

# Hooks launched from GUI apps can have a thin PATH.
ghd_augment_path

die() { echo "hq-fingerprint-hooks: $*" >&2; exit 2; }

setting() { # key default
  local v=""
  v="$(yaml_scalar "$SETTING_PERSONAL" "$1")" || v="$(yaml_scalar "$SETTING_CORE" "$1")" || v=""
  printf '%s' "${v:-$2}"
}

write_setting() { # enabled-value
  # Only touch the personal file when the effective value actually changes, so
  # a daily "Already on." pass never rewrites a hand-edited settings file.
  [ "$(setting enabled true)" = "$1" ] && return 0
  mkdir -p "$(dirname "$SETTING_PERSONAL")"
  cat >"$SETTING_PERSONAL" <<EOF
# Written by core/scripts/hq-fingerprint-hooks.sh. Change it with
# \`bash core/scripts/hq-fingerprint-hooks.sh enable|disable\`, not by hand.
enabled: $1
EOF
}

wired() { ghd_wired && ghd_feature_on fingerprint; }

# ---------------------------------------------------------------- the stage

log_skip() { # reason (never the fingerprint value)
  local size
  [ -n "$LOG" ] || return 0
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || return 0
  if [ -f "$LOG" ]; then
    size="$(wc -c <"$LOG" 2>/dev/null)" || size=0
    size="${size//[[:space:]]/}"
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    [ "$size" -ge "$LOG_MAX_BYTES" ] && mv -f "$LOG" "$LOG.1" 2>/dev/null
  fi
  printf '%s commit-msg no trailer: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >>"$LOG" 2>/dev/null
  return 0
}

# Is the current repo's top level inside $HQ_ROOT? Both sides canonical, so a
# symlinked HQ folder or /tmp -> /private/tmp still compares equal.
# Also sets GIT_DIR_FOUND (one git call for both, as each spawn costs ~10 ms).
inside_hq_root() {
  local top root out
  out="$(git rev-parse --show-toplevel --git-dir 2>/dev/null)" || return 1
  top="${out%%$'\n'*}"
  GIT_DIR_FOUND="${out#*$'\n'}"
  [ -n "$top" ] && [ "$GIT_DIR_FOUND" != "$out" ] || return 1
  top="$(cd "$top" 2>/dev/null && pwd -P)" || return 1
  root="$(cd "$HQ_ROOT" 2>/dev/null && pwd -P)" || return 1
  case "$top/" in "$root/"*) return 0 ;; esac
  return 1
}

# Run the fingerprint command with a hard time limit (background and poll; no
# GNU timeout or perl on a stock Mac). Output goes to $1. Job control puts the
# command in its own process group, so a timeout also stops any child a
# wrapper `hq` started (node under a shell script).
# Polls often at first (a fast CLI answers in well under a second), then
# every 0.1 s.
run_fingerprint() { # outfile
  local limit="${HQ_FINGERPRINT_TIMEOUT_TENTHS:-20}" i=0 step pid rc
  case "$limit" in ''|*[!0-9]*) limit=20 ;; esac
  limit=$((limit * 10)) # hundredths
  if [ -z "${HQ_FINGERPRINT_BIN:-}" ]; then
    command -v hq >/dev/null 2>&1 || return 3
  fi
  set -m
  if [ -n "${HQ_FINGERPRINT_BIN:-}" ]; then
    # shellcheck disable=SC2086
    $HQ_FINGERPRINT_BIN fingerprint self --json --offline >"$1" 2>/dev/null </dev/null &
  else
    hq fingerprint self --json --offline >"$1" 2>/dev/null </dev/null &
  fi
  pid=$!
  set +m
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge "$limit" ]; then
      kill -TERM -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null
      sleep 0.1
      kill -9 -- "-$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    if [ "$i" -lt 20 ]; then step=2; elif [ "$i" -lt 100 ]; then step=5; else step=10; fi
    sleep "0.$(printf '%02d' "$step")"
    i=$((i + step))
  done
  wait "$pid"; rc=$?
  return "$rc"
}

# Does the message have content git would keep? Git runs commit-msg before
# its own empty-message check, so a trailer on an empty message would turn an
# aborted commit into one whose subject is the trailer. Mirrors git's cleanup:
# text below the scissors line and comment lines are dropped unless
# commit.cleanup is verbatim or whitespace. Git sets GIT_EDITOR=: for the hook
# when no editor runs (-m, -F, --no-edit); the default cleanup is then
# whitespace, so comment lines count. With core.commentChar=auto any of git's
# candidate characters counts as a comment (at worst no trailer).
has_message() { # msgfile
  # The hook cannot see the cleanup mode git will apply (command-line
  # --cleanup, GIT_EDITOR=: as a user's real editor, -F with a comment-only
  # file), so it always strips comments and cuts at the scissors line before
  # deciding whether there is a message. Over-stripping only costs a missed
  # trailer on a comment-only message; under-stripping would turn an aborted
  # empty commit into a commit whose subject is the fingerprint.
  local cc body
  cc="$(git config --get core.commentString 2>/dev/null)" || cc="$(git config --get core.commentChar 2>/dev/null)" || cc="#"
  [ -n "$cc" ] || cc="#"
  body="$(cat "$1")" || return 1
  body="$(printf '%s\n' "$body" | awk -v s="$cc ------------------------ >8 ------------------------" '$0==s{exit} {print}')"
  if [ "$cc" = "auto" ]; then
    body="$(printf '%s\n' "$body" | grep -v '^[#;@!$%^&|:]')"
  else
    body="$(printf '%s\n' "$body" | git -c "core.commentChar=$cc" stripspace --strip-comments 2>/dev/null)" || return 1
  fi
  printf '%s\n' "$body" | git stripspace 2>/dev/null | grep -q .
}

# The per-session fingerprint cache, in the same format as
# core/scripts/lib/fingerprint.sh (hq_fingerprint_trailer_args) so a value or
# a "none" written by either side is reused by the other. Three lines:
#   hq-fingerprint-trailer.v2
#   hq-cli:<version>  or  bin:<HQ_FINGERPRINT_BIN>
#   value:<hqfp...>   or  none
session_cache_read() { # file key; prints the value, or nothing for "none"
  local schema="" key="" result=""
  [ -f "$1" ] || return 1
  { IFS= read -r schema; IFS= read -r key; IFS= read -r result; } <"$1" 2>/dev/null
  [ "$schema" = "$SESSION_CACHE_SCHEMA" ] && [ "$key" = "$2" ] || return 1
  case "$result" in
    none) return 0 ;;
    value:hqfp*) result="${result#value:}" ;;
    *) return 1 ;;
  esac
  case "$result" in *[!A-Za-z0-9:._~+/=-]*) return 1 ;; esac
  printf '%s' "$result"
}

session_cache_write() { # file key result (value:<fp> or none)
  local tmp="$1.$$"
  mkdir -p "${1%/*}" 2>/dev/null || return 0
  printf '%s\n' "$SESSION_CACHE_SCHEMA" "$2" "$3" >"$tmp" 2>/dev/null && mv -f "$tmp" "$1" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  return 0
}

stage_commit_msg() { # msgfile
  local msg="${1:-}" gd out rc fp="" cap_key="" sc_file="" sc_key="" cached
  # Kill switch first: enabled: false means no work at all.
  [ "$(setting enabled true)" = "true" ] || return 0
  [ -n "$msg" ] && [ -f "$msg" ] || { log_skip "no message file"; return 0; }

  # No agent session: the fingerprint would be null, so start nothing.
  # The session and version checks use no git call, so they come before the
  # scope check (the stub already only calls in for repos under the HQ root).
  hq_cap_session_id || return 0
  sc_file="$HQ_ROOT/workspace/sessions/$HQ_CAP_SID/fingerprint-trailer.cache"

  # An hq CLI older than the floor has no `hq fingerprint`: stop without
  # starting it. A newer one known (within a day) to fail the probe stops the
  # same way. A test override (HQ_FINGERPRINT_BIN) is never cached per machine.
  if [ -n "${HQ_FINGERPRINT_BIN:-}" ]; then
    sc_key="bin:$HQ_FINGERPRINT_BIN"
  else
    hq_cap_read_cli || return 0
    cap_key="$HQ_CAP_KEY"
    if [ "$HQ_CAP_VERSION" = "-" ] || ! hq_cli_version_ge "$HQ_CAP_VERSION" "$HQ_FINGERPRINT_MIN_HQ_CLI" 2>/dev/null; then
      hq_cap_cache_read "$cap_key" >/dev/null
      [ $? -eq 2 ] && hq_cap_cache_write "$cap_key" below-floor
      return 0
    fi
    sc_key="hq-cli:$HQ_CAP_VERSION"
    hq_cap_cache_read "$cap_key" >/dev/null
    [ $? -eq 1 ] && return 0
  fi

  inside_hq_root || return 0
  gd="$GIT_DIR_FOUND"
  if [ -f "$gd/MERGE_HEAD" ]; then return 0; fi

  # Empty message: add nothing and let git abort the commit as usual.
  has_message "$msg" || return 0

  # A cached value or a cached "none" for this session: no spawn.
  if cached="$(session_cache_read "$sc_file" "$sc_key")"; then
    [ -n "$cached" ] || return 0
    fp="$cached"
  fi

  if [ -z "$fp" ]; then
    out="$(mktemp "${TMPDIR:-/tmp}/hq-fingerprint.XXXXXX")" || { log_skip "no temp file"; return 0; }
    run_fingerprint "$out"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      rm -f "$out"
      case "$rc" in
        3) log_skip "hq CLI not found"; return 0 ;;
        124) log_skip "fingerprint command timed out"
             [ -n "$cap_key" ] && hq_cap_cache_write "$cap_key" timeout ;;
        *) log_skip "fingerprint command failed (exit $rc)"
           [ -n "$cap_key" ] && hq_cap_cache_write "$cap_key" "exit$rc" ;;
      esac
      session_cache_write "$sc_file" "$sc_key" none
      return 0
    fi
    fp="$(sed -n 's/.*"fingerprint"[[:space:]]*:[[:space:]]*"\(hqfp[0-9]*:[^"[:space:]]*\)".*/\1/p' "$out" | head -n 1)"
    case "$fp" in *[!A-Za-z0-9:._~+/=-]*) fp="" ;; esac
    if [ -z "$fp" ]; then
      if grep -q '"fingerprint"[[:space:]]*:[[:space:]]*null' "$out" 2>/dev/null; then
        # The CLI has the command; this session just has no fingerprint.
        [ -n "$cap_key" ] && hq_cap_cache_write "$cap_key" capable
        log_skip "fingerprint unavailable ($(sed -n 's/.*"reason"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$out" | head -n 1 | cut -c1-80))"
      else
        [ -n "$cap_key" ] && hq_cap_cache_write "$cap_key" nooutput
        log_skip "could not read a fingerprint from the command output"
      fi
      rm -f "$out"
      session_cache_write "$sc_file" "$sc_key" none
      return 0
    fi
    rm -f "$out"
    [ -n "$cap_key" ] && hq_cap_cache_write "$cap_key" capable
    session_cache_write "$sc_file" "$sc_key" "value:$fp"
  fi

  # --no-divider: a "---" line in the body is not the end of the message.
  if git interpret-trailers --no-divider --parse "$msg" 2>/dev/null | grep -qxF "$TRAILER_KEY: $fp"; then return 0; fi
  git interpret-trailers --no-divider --in-place --if-exists replace --trailer "$TRAILER_KEY: $fp" "$msg" 2>/dev/null \
    || log_skip "git interpret-trailers failed"
  return 0
}

# ---------------------------------------------------------------- enable/disable

enable() {
  local replace=""
  [ "${1:-}" = "--replace" ] && replace="--replace"
  write_setting true
  # Already wired: rewrite stale stubs (moved HQ folder, edited markers).
  if wired; then ghd_refresh >/dev/null 2>&1; echo "Already on."; return 0; fi
  ghd_install $replace
  ghd_set_marker fingerprint
  echo "On. Commits in repos inside $HQ_ROOT now get an $TRAILER_KEY trailer."
  echo "To undo: bash \"$SELF\" disable"
}

disable() {
  local dry="${1:-}" out
  # Session start with enabled: false: stop the stub from starting bash for
  # the trailer. The setting stays as is; the dispatcher stays while the
  # secret scan is on, and is put back when nothing else uses it (its pass-
  # through stubs alone cost a dash start per hook, about 15 ms a commit).
  if [ "$dry" = "--keep-setting" ]; then
    wired || return 0
    ghd_clear_marker fingerprint
    ( ghd_uninstall_if_unused fingerprint ) >/dev/null 2>&1
    return 0
  fi
  [ "$dry" = "--dry-run" ] || ghd_clear_marker fingerprint
  out="$(ghd_uninstall_if_unused fingerprint "$dry")" || { [ "$dry" = "--dry-run" ] || ghd_set_marker fingerprint; exit 2; }
  if [ "$out" = "kept" ]; then
    [ "$dry" = "--dry-run" ] && { echo "  would stop the trailer; the HQ git hook stays for the commit secret scan"; return 0; }
    out=""
  fi
  [ -n "$out" ] && echo "$out"
  [ "$dry" = "--dry-run" ] && return 0
  write_setting false
  echo "Off. Commits no longer get an $TRAILER_KEY trailer."
}

status() {
  if wired; then echo "fingerprint trailer: on"; else echo "fingerprint trailer: off"; fi
  echo "setting: enabled=$(setting enabled true)"
  echo "scope: repos inside $HQ_ROOT"
}

case "${1:-status}" in
  status)  status ;;
  enable)  enable "${2:-}" ;;
  disable) disable "${2:-}" ;;
  hook)
    [ "${2:-}" = "commit-msg" ] || die "usage: $(basename "$0") hook commit-msg <message-file>"
    stage_commit_msg "${3:-}" >/dev/null 2>&1
    exit 0 ;;
  -h|--help) sed -n '2,41p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "usage: $(basename "$0") status | enable [--replace] | disable [--dry-run] | hook commit-msg <file>" ;;
esac
