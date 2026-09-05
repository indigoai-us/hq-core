#!/usr/bin/env bash
# hq-core: public
# 31-ensure-hq-desktop.sh — UserPromptSubmit hook (+ detached update worker).
#
# Keeps the HQ desktop app (the "HQ" menubar app, bundle id
# ai.indigo.hq-sync-menubar, released from indigoai-us/hq-desktop-app) current,
# the way 30-ensure-hq-cli.sh keeps the `hq` CLI current.
#
# The hook itself only ever does CHEAP work and returns at once. A desktop
# release is a multi-hundred-megabyte download, and every UserPromptSubmit hook
# shares one wall-clock ceiling (300s in .claude/settings.json), so the download
# + swap runs in a DETACHED worker process (this same script, invoked with
# `--worker`) that outlives the hook. The prompt that notices the stale app
# announces that the update has started; a later prompt announces the outcome.
#
# On every prompt:
#   * no desktop app installed                -> fully silent no-op. The app is
#                                                optional (CLI-only and CI
#                                                installs); this hook never
#                                                installs it from scratch.
#   * installed app is current                -> fully silent no-op (common case).
#   * a worker finished since the last prompt -> announce its result ONCE
#                                                (<hq-desktop-updated> or the
#                                                manual remedy) and stop.
#   * a worker is still running               -> silent.
#   * installed app is older than the latest  -> macOS: spawn the worker, which
#     release                                    downloads that release's
#                                                .app.tar.gz, verifies it, swaps it
#                                                into place, and relaunches the app
#                                                if it was running; announce that
#                                                the update has started.
#                                                Windows: announce the installer
#                                                link (never runs an installer
#                                                silently).
#
# "Latest" is the same public updater manifest the app itself consumes:
#   https://github.com/indigoai-us/hq-desktop-app/releases/latest/download/latest.json
# cached for 24h under workspace/.hq-desktop-ensure/latest.json, so the common
# case costs one local Info.plist read and one cache read per prompt.
#
# Contract:
#   * Advisory only — ALWAYS exits 0 (fail-soft); never blocks the prompt.
#   * The worker is gated by a once-per-cooldown stamp and serialised by an
#     atomic lock (which records the worker pid, so a dead worker's lock is
#     reclaimed), so a broken environment never re-downloads on every prompt
#     and two sessions never race the same bundle.
#   * Concurrent hook invocations (several Claude/Codex sessions, rapid
#     prompts) never interfere: the manifest cache and the result record are
#     written via temp-file + atomic rename, the worker claim is an atomic
#     mkdir, the result is claimed by an atomic rename so it is reported by
#     exactly one prompt, and every scratch path carries the owning pid.
#   * The new bundle is verified (bundle id, version, and `codesign` where
#     available) BEFORE the old one is touched; the old bundle is kept until the
#     swap succeeds and restored if it does not.
#   * stdout is added to the model's context by Claude Code, so anything printed
#     is deliberate, tagged context. Silence = print nothing. The worker's own
#     output goes to workspace/.hq-desktop-ensure/worker.log, never to the hook.
#
# bash-3.2 compatible (macOS default shell).
#
# Kill switches: HQ_NO_ENSURE_HQ_DESKTOP=1, or HQ_DISABLED_HOOKS=...,ensure-hq-desktop,...
# Test seams: HQ_ROOT, HQ_ENSURE_DESKTOP_APP_PATH, HQ_ENSURE_DESKTOP_MANIFEST_URL,
#             HQ_ENSURE_DESKTOP_CACHE_TTL, HQ_ENSURE_DESKTOP_COOLDOWN,
#             HQ_ENSURE_DESKTOP_TIMEOUT, HQ_ENSURE_DESKTOP_FETCH_TIMEOUT,
#             HQ_ENSURE_DESKTOP_OS, HQ_ENSURE_DESKTOP_ARCH, HQ_ENSURE_DESKTOP_HOME.

set -uo pipefail

MODE=hook
[ "${1:-}" = "--worker" ] && MODE=worker

if [ "$MODE" = hook ]; then
  trap 'exit 0' EXIT
  # Consume stdin (master-hook always pipes the event JSON, even if unused).
  cat >/dev/null 2>&1 || true
fi

# --- kill switches --------------------------------------------------------
case "${HQ_NO_ENSURE_HQ_DESKTOP:-}" in
  1|true|TRUE|yes|YES|on|ON) exit 0 ;;
esac
case ",${HQ_DISABLED_HOOKS:-}," in
  *,ensure-hq-desktop,*) exit 0 ;;
esac

# --- root + state ---------------------------------------------------------
# This file lives at <HQ>/core/hooks/UserPromptSubmit/, so the HQ root is THREE
# parents up. Prefer an explicit HQ_ROOT, then CLAUDE_PROJECT_DIR, then the walk.
SELF="${BASH_SOURCE[0]}"
HOOK_DIR="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd)" || exit 0
SELF_ABS="$HOOK_DIR/$(basename "$SELF")"
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$HOOK_DIR/../../.." 2>/dev/null && pwd)}}"
[ -n "$HQ_ROOT" ] || exit 0
export HQ_ROOT

STATE_DIR="$HQ_ROOT/workspace/.hq-desktop-ensure"
CACHE="$STATE_DIR/latest.json"
STAMP="$STATE_DIR/last-attempt.stamp"
LOCK_DIR="$STATE_DIR/updating.lock"
LOCK_PID="$LOCK_DIR/pid"
RESULT="$STATE_DIR/last-result"
WORKER_LOG="$STATE_DIR/worker.log"

MANIFEST_URL="${HQ_ENSURE_DESKTOP_MANIFEST_URL:-https://github.com/indigoai-us/hq-desktop-app/releases/latest/download/latest.json}"
CACHE_TTL="${HQ_ENSURE_DESKTOP_CACHE_TTL:-86400}"      # 24h between manifest fetches
COOLDOWN="${HQ_ENSURE_DESKTOP_COOLDOWN:-21600}"        # 6h between update attempts
UPDATE_TIMEOUT="${HQ_ENSURE_DESKTOP_TIMEOUT:-900}"     # worker download bound (seconds)
FETCH_TIMEOUT="${HQ_ENSURE_DESKTOP_FETCH_TIMEOUT:-8}"  # manifest bound (seconds)
OS_NAME="${HQ_ENSURE_DESKTOP_OS:-$(uname -s 2>/dev/null || echo unknown)}"
ARCH_NAME="${HQ_ENSURE_DESKTOP_ARCH:-$(uname -m 2>/dev/null || echo unknown)}"
USER_HOME="${HQ_ENSURE_DESKTOP_HOME:-${HOME:-}}"

BUNDLE_ID="ai.indigo.hq-sync-menubar"
APP_BUNDLE="HQ.app"
PROCESS_NAME="hq-sync-menubar"

# --- platform ---------------------------------------------------------------
case "$OS_NAME" in
  Darwin) PLATFORM=darwin ;;
  MINGW*|MSYS*|CYGWIN*|Windows_NT) PLATFORM=windows ;;
  *) exit 0 ;;   # no desktop app on this platform
esac

have() { command -v "$1" >/dev/null 2>&1; }

version_at_least() {
  local actual="$1" required="$2" a1 a2 a3 r1 r2 r3 oldifs
  oldifs="$IFS"; IFS='.'
  set -- $actual; a1="${1:-0}"; a2="${2:-0}"; a3="${3:-0}"
  set -- $required; r1="${1:-0}"; r2="${2:-0}"; r3="${3:-0}"
  IFS="$oldifs"
  [ "$a1" -gt "$r1" ] && return 0
  [ "$a1" -lt "$r1" ] && return 1
  [ "$a2" -gt "$r2" ] && return 0
  [ "$a2" -lt "$r2" ] && return 1
  [ "$a3" -ge "$r3" ]
}

semver_of() { printf '%s' "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1; }

file_age_ok() { # file_age_ok <file> <max-age-seconds> -> 0 when the file is younger than max
  local f="$1" max="$2" mtime now
  [ -f "$f" ] || return 1
  mtime="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)"
  now="$(date +%s 2>/dev/null || echo 0)"
  [ "$now" -gt 0 ] && [ "$((now - mtime))" -lt "$max" ]
}

stop_watchdog() {
  local watchdog_pid="$1"
  if have pkill; then pkill -P "$watchdog_pid" 2>/dev/null || true; fi
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
}

# Run shell command string $2 bounded to $1 seconds. `timeout` is absent on
# stock macOS, so use a portable watchdog. Returns the command's status.
run_bounded() {
  local secs="$1" cmd="$2" cmd_pid killer_pid rc=0
  sh -c "$cmd" >/dev/null 2>&1 &
  cmd_pid=$!
  ( sleep "$secs" 2>/dev/null; kill "$cmd_pid" 2>/dev/null ) >/dev/null 2>&1 &
  killer_pid=$!
  wait "$cmd_pid" 2>/dev/null || rc=$?
  stop_watchdog "$killer_pid"
  return "$rc"
}

# --- Info.plist reading ----------------------------------------------------
# plutil / defaults handle binary plists on macOS; the XML fallback covers
# Tauri's XML plist everywhere else (and the test harness).
plist_string() { # plist_string <Info.plist> <key>
  local plist="$1" key="$2" v=""
  [ -f "$plist" ] || return 1
  if have plutil; then
    v="$(plutil -extract "$key" raw -o - "$plist" 2>/dev/null)" || v=""
  fi
  if [ -z "$v" ] && have defaults; then
    v="$(defaults read "${plist%.plist}" "$key" 2>/dev/null)" || v=""
  fi
  if [ -z "$v" ]; then
    v="$(tr -d '\n\r' < "$plist" 2>/dev/null \
      | sed -n "s/.*<key>$key<\/key>[[:space:]]*<string>\([^<]*\)<\/string>.*/\1/p")"
  fi
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

bundle_version() { semver_of "$(plist_string "$1/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)"; }
bundle_identifier() { plist_string "$1/Contents/Info.plist" CFBundleIdentifier 2>/dev/null; }

# --- locate the installed app --------------------------------------------
locate_app_darwin() {
  local candidate
  if [ -n "${HQ_ENSURE_DESKTOP_APP_PATH:-}" ]; then
    [ -f "${HQ_ENSURE_DESKTOP_APP_PATH}/Contents/Info.plist" ] || return 1
    printf '%s\n' "${HQ_ENSURE_DESKTOP_APP_PATH}"
    return 0
  fi
  for candidate in "/Applications/$APP_BUNDLE" "$USER_HOME/Applications/$APP_BUNDLE"; do
    if [ -f "$candidate/Contents/Info.plist" ]; then printf '%s\n' "$candidate"; return 0; fi
  done
  return 1
}

# The running app records its version to ~/.hq/sync-version.json (read by
# `hq doctor` too). It is the only version source available from a shell on
# Windows, where the install lives inside an NSIS-managed folder.
recorded_version() {
  local f="$USER_HOME/.hq/sync-version.json"
  [ -f "$f" ] || return 1
  if have jq; then
    semver_of "$(jq -r '.version // empty' "$f" 2>/dev/null)"
  else
    semver_of "$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | head -1)"
  fi
}

# --- latest manifest (cached) ---------------------------------------------
manifest_version() { # manifest_version <file>
  local f="$1"
  if have jq; then
    semver_of "$(jq -r '.version // empty' "$f" 2>/dev/null)"
  else
    semver_of "$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | head -1)"
  fi
}

manifest_url() { # manifest_url <file> <platform-key>
  local f="$1" key="$2"
  if have jq; then
    jq -r --arg k "$key" '.platforms[$k].url // empty' "$f" 2>/dev/null
  else
    tr -d '\n\r' < "$f" 2>/dev/null \
      | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*{[^}]*\"url\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
  fi
}

refresh_manifest() {
  have curl || return 1
  mkdir -p "$STATE_DIR" 2>/dev/null || return 1
  local tmp="$CACHE.tmp.$$"
  if curl -fsSL --max-time "$FETCH_TIMEOUT" -o "$tmp" "$MANIFEST_URL" >/dev/null 2>&1 \
     && [ -n "$(manifest_version "$tmp")" ]; then
    mv "$tmp" "$CACHE" 2>/dev/null && return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

platform_key() {
  case "$PLATFORM:$ARCH_NAME" in
    darwin:arm64|darwin:aarch64) echo darwin-aarch64 ;;
    darwin:*)                    echo darwin-x86_64 ;;
    windows:arm64|windows:aarch64|windows:ARM64) echo windows-aarch64 ;;
    windows:*)                   echo windows-x86_64 ;;
  esac
}

download_url_for() { # download_url_for <manifest>
  local url
  url="$(manifest_url "$1" "$(platform_key)")"
  if [ -z "$url" ] && [ "$PLATFORM" = darwin ]; then
    url="$(manifest_url "$1" darwin-x86_64)"
    [ -n "$url" ] || url="$(manifest_url "$1" darwin-aarch64)"
  fi
  [ -n "$url" ] || url="https://github.com/indigoai-us/hq-desktop-app/releases/latest"
  printf '%s\n' "$url"
}

# --- result record (worker -> next prompt) ---------------------------------
# Plain key=value lines: status, from, to, reason, relaunched, url.
result_get() { sed -n "s/^$1=//p" "$RESULT" 2>/dev/null | head -1; }
write_result() { # write_result <status> <from> <to> <reason> <relaunched> <url>
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  {
    printf 'status=%s\n' "$1"
    printf 'from=%s\n' "$2"
    printf 'to=%s\n' "$3"
    printf 'reason=%s\n' "$4"
    printf 'relaunched=%s\n' "$5"
    printf 'url=%s\n' "$6"
    printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
  } > "$RESULT.tmp.$$" 2>/dev/null && mv "$RESULT.tmp.$$" "$RESULT" 2>/dev/null
}

# --- context emitters ------------------------------------------------------
emit_started() { # $1=installed $2=latest
  cat <<EOF
<hq-desktop-update-started>
The HQ desktop app on this machine is $1; the latest release is $2. HQ is
updating it in the background now. This can take a few minutes; if the app is
running it will quit and relaunch on its own once the new version is in place.
The outcome will be reported on a later prompt — no action is needed.
</hq-desktop-update-started>
EOF
}

emit_updated() { # $1=old $2=new $3=relaunched(1/0)
  local tail
  if [ "$3" = "1" ]; then
    tail="It was running, so HQ quit it and relaunched the new version."
  else
    tail="It was not running; the new version starts the next time HQ is opened."
  fi
  cat <<EOF
<hq-desktop-updated>
The HQ desktop app was out of date ($1), so HQ updated it to $2 in place.
$tail
</hq-desktop-updated>
EOF
}

emit_available() { # $1=installed $2=latest $3=download-url $4=reason
  cat <<EOF
<hq-desktop-update-available>
The HQ desktop app on this machine is $1; the latest release is $2.
$4
Download it here and install it over the current copy:

  $3
</hq-desktop-update-available>
EOF
}

# ===========================================================================
# WORKER: download, verify, swap, relaunch. Runs detached; reports via $RESULT.
# ===========================================================================
if [ "$MODE" = worker ]; then
  # The dispatcher claimed $LOCK_DIR before spawning us; we own it now and
  # release it on ANY exit, so a crashed worker cannot wedge later attempts.
  printf '%s\n' "$$" > "$LOCK_PID" 2>/dev/null || true
  trap 'rm -rf "$LOCK_DIR" 2>/dev/null; exit 0' EXIT   # lock holds our pid file

  APP_PATH="$(locate_app_darwin)" || exit 0
  INSTALLED="$(bundle_version "$APP_PATH")"
  [ -f "$CACHE" ] || exit 0
  LATEST="$(manifest_version "$CACHE")"
  [ -n "$INSTALLED" ] && [ -n "$LATEST" ] || exit 0
  DOWNLOAD_URL="$(download_url_for "$CACHE")"
  WORK="$STATE_DIR/work.$$"

  fail_update() { # $1=reason
    rm -rf "$WORK" 2>/dev/null || true
    write_result failed "$INSTALLED" "$LATEST" "HQ tried to update it automatically but $1." 0 "$DOWNLOAD_URL"
    echo "[$(date -u +%H:%M:%S)] failed: $1"
    exit 0
  }

  echo "[$(date -u +%H:%M:%S)] updating $INSTALLED -> $LATEST from $DOWNLOAD_URL"
  have curl || fail_update "curl is not available to download it"
  have tar  || fail_update "tar is not available to unpack it"

  rm -rf "$WORK" 2>/dev/null; mkdir -p "$WORK" 2>/dev/null || fail_update "could not create a working directory"

  curl -fsSL --max-time "$UPDATE_TIMEOUT" -o "$WORK/app.tar.gz" "$DOWNLOAD_URL" >/dev/null 2>&1 \
    || fail_update "the download failed"
  tar -xzf "$WORK/app.tar.gz" -C "$WORK" >/dev/null 2>&1 \
    || fail_update "the download could not be unpacked"

  NEW_APP="$(find "$WORK" -maxdepth 2 -type d -name '*.app' 2>/dev/null | head -1)"
  [ -n "$NEW_APP" ] && [ -f "$NEW_APP/Contents/Info.plist" ] \
    || fail_update "the download did not contain an app bundle"

  # Verify BEFORE touching the installed copy.
  [ "$(bundle_identifier "$NEW_APP")" = "$BUNDLE_ID" ] \
    || fail_update "the downloaded app was not the HQ app (bundle id mismatch)"
  NEW_VERSION="$(bundle_version "$NEW_APP")"
  [ "$NEW_VERSION" = "$LATEST" ] \
    || fail_update "the downloaded app reported version ${NEW_VERSION:-unknown}, not $LATEST"
  if have codesign; then
    codesign --verify --deep --strict "$NEW_APP" >/dev/null 2>&1 \
      || fail_update "the downloaded app failed code-signature verification"
  fi

  # Quit the running app gracefully (its own updater does the same), then swap.
  # Match the exact process NAME (`-x`), never the full command line (`-f`): a
  # shell, grep, or editor whose arguments merely mention "hq-sync-menubar" must
  # not be mistaken for the app — and must never be killed by the fallback.
  app_running() { have pgrep && pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; }
  WAS_RUNNING=0
  if app_running; then
    WAS_RUNNING=1
    if have osascript; then
      run_bounded 10 "osascript -e 'tell application id \"$BUNDLE_ID\" to quit'" || true
    fi
    i=0
    while [ "$i" -lt 10 ] && app_running; do
      sleep 1; i=$((i + 1))
    done
    if app_running; then
      have pkill && pkill -x "$PROCESS_NAME" >/dev/null 2>&1
      sleep 2
    fi
  fi

  BACKUP="$APP_PATH.hq-ensure-backup.$$"
  rm -rf "$BACKUP" 2>/dev/null || true
  if ! mv "$APP_PATH" "$BACKUP" 2>/dev/null; then
    fail_update "it could not replace $APP_PATH (permission denied?)"
  fi
  if ! mv "$NEW_APP" "$APP_PATH" 2>/dev/null; then
    mv "$BACKUP" "$APP_PATH" 2>/dev/null || true
    [ "$WAS_RUNNING" = 1 ] && have open && open -a "$APP_PATH" >/dev/null 2>&1
    fail_update "it could not move the new app into $APP_PATH (the old copy was kept)"
  fi
  rm -rf "$BACKUP" "$WORK" 2>/dev/null || true
  rm -f "$STAMP" 2>/dev/null || true

  RELAUNCHED=0
  if [ "$WAS_RUNNING" = 1 ] && have open; then
    open -a "$APP_PATH" >/dev/null 2>&1 && RELAUNCHED=1
  fi
  write_result updated "$INSTALLED" "$NEW_VERSION" "" "$RELAUNCHED" "$DOWNLOAD_URL"
  echo "[$(date -u +%H:%M:%S)] updated $INSTALLED -> $NEW_VERSION (relaunched=$RELAUNCHED)"
  exit 0
fi

# ===========================================================================
# HOOK: cheap checks only; delegate the heavy lifting to the worker.
# ===========================================================================

# --- 0. report a finished worker's outcome, exactly once --------------------
# Prompts from several sessions can land at the same moment. `mv` is atomic,
# so only ONE of them can claim the record; the others see nothing and carry
# on with the ordinary (silent, current) path.
if [ -f "$RESULT" ]; then
  CLAIM="$RESULT.claim.$$"
  if mv "$RESULT" "$CLAIM" 2>/dev/null; then
    RESULT="$CLAIM"
    R_STATUS="$(result_get status)"; R_FROM="$(result_get from)"; R_TO="$(result_get to)"
    R_REASON="$(result_get reason)"; R_RELAUNCHED="$(result_get relaunched)"; R_URL="$(result_get url)"
    rm -f "$CLAIM" 2>/dev/null || true
    case "$R_STATUS" in
      updated) emit_updated "$R_FROM" "$R_TO" "$R_RELAUNCHED"; exit 0 ;;
      failed)  emit_available "$R_FROM" "$R_TO" "$R_URL" "$R_REASON"; exit 0 ;;
    esac
  fi
fi

# --- 1. a worker in flight -> silent; a dead worker's lock -> reclaim ------
if [ -d "$LOCK_DIR" ]; then
  W_PID="$(cat "$LOCK_PID" 2>/dev/null || true)"
  if [ -n "$W_PID" ] && kill -0 "$W_PID" 2>/dev/null; then
    exit 0
  fi
  if [ -z "$W_PID" ] && file_age_ok "$LOCK_DIR" 60; then
    exit 0   # just claimed by a peer that has not written its pid yet
  fi
  rm -rf "$LOCK_DIR" 2>/dev/null || true
fi

# --- 2. installed version ---------------------------------------------------
APP_PATH=""
INSTALLED=""
if [ "$PLATFORM" = darwin ]; then
  APP_PATH="$(locate_app_darwin)" || exit 0        # not installed -> silent
  INSTALLED="$(bundle_version "$APP_PATH")"
  [ -n "$INSTALLED" ] || exit 0                      # unreadable -> leave it alone
else
  INSTALLED="$(recorded_version)" || exit 0
  [ -n "$INSTALLED" ] || exit 0
fi

# --- 3. latest version (cached manifest) -----------------------------------
if ! file_age_ok "$CACHE" "$CACHE_TTL"; then
  refresh_manifest || true      # a stale cache still counts; no cache -> quiet
fi
[ -f "$CACHE" ] || exit 0
LATEST="$(manifest_version "$CACHE")"
[ -n "$LATEST" ] || exit 0

if version_at_least "$INSTALLED" "$LATEST"; then
  [ -f "$STAMP" ] && rm -f "$STAMP" 2>/dev/null || true
  exit 0                                             # current -> silent
fi

# --- 4. cooldown: one attempt (and one announcement) per window -----------
file_age_ok "$STAMP" "$COOLDOWN" && exit 0
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
mkdir "$LOCK_DIR" 2>/dev/null || exit 0             # a peer got there first
: > "$STAMP" 2>/dev/null || true

DOWNLOAD_URL="$(download_url_for "$CACHE")"

# --- 5a. Windows: advise once per cooldown ---------------------------------
if [ "$PLATFORM" = windows ]; then
  rm -rf "$LOCK_DIR" 2>/dev/null || true
  emit_available "$INSTALLED" "$LATEST" "$DOWNLOAD_URL" \
    "HQ does not run installers silently on Windows."
  exit 0
fi

# --- 5b. macOS: spawn the detached worker and return at once ---------------
# The worker must not inherit the hook's stdout/stderr (Claude Code waits for
# EOF on them) and must survive the hook's exit, so it gets its own session
# (`setsid`, absent on stock macOS -> `nohup`), /dev/null stdin, and the log.
if have setsid; then
  setsid bash "$SELF_ABS" --worker </dev/null >>"$WORKER_LOG" 2>&1 &
else
  nohup bash "$SELF_ABS" --worker </dev/null >>"$WORKER_LOG" 2>&1 &
fi
W_PID=$!
[ -f "$LOCK_PID" ] || printf '%s\n' "$W_PID" > "$LOCK_PID" 2>/dev/null || true
disown "$W_PID" 2>/dev/null || true

emit_started "$INSTALLED" "$LATEST"
exit 0
