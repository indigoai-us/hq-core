#!/usr/bin/env bash
# hq-core: public
# 31-ensure-hq-desktop.sh — UserPromptSubmit hook.
#
# Keeps the HQ desktop app (the "HQ" menubar app, bundle id
# ai.indigo.hq-sync-menubar, released from indigoai-us/hq-desktop-app) current,
# the way 30-ensure-hq-cli.sh keeps the `hq` CLI current.
#
# On every prompt:
#   * no desktop app installed                -> fully silent no-op. The app is
#                                                optional (CLI-only and CI
#                                                installs); this hook never
#                                                installs it from scratch.
#   * installed app is current                -> fully silent no-op (common case).
#   * installed app is older than the latest  -> macOS: download that release's
#     release                                    .app.tar.gz, verify it, swap it
#                                                into place, relaunch the app if
#                                                it was running, and announce.
#                                                Windows: announce the installer
#                                                link (never runs an installer
#                                                silently).
#   * update cannot run / fails               -> announce the manual remedy.
#
# "Latest" is the same public updater manifest the app itself consumes:
#   https://github.com/indigoai-us/hq-desktop-app/releases/latest/download/latest.json
# cached for 24h under workspace/.hq-desktop-ensure/latest.json, so the common
# case costs one local Info.plist read and one cache read per prompt.
#
# Contract:
#   * Advisory only — ALWAYS exits 0 (fail-soft); never blocks the prompt.
#   * The download + swap is bounded, gated by a once-per-cooldown stamp, and
#     serialised by an atomic lock so a broken environment never re-downloads
#     on every prompt and two sessions never race the same bundle.
#   * The new bundle is verified (bundle id, version, and `codesign` where
#     available) BEFORE the old one is touched; the old bundle is kept until the
#     swap succeeds and restored if it does not.
#   * stdout is added to the model's context by Claude Code, so anything printed
#     is deliberate, tagged context. Silence = print nothing.
#
# bash-3.2 compatible (macOS default shell).
#
# Kill switches: HQ_NO_ENSURE_HQ_DESKTOP=1, or HQ_DISABLED_HOOKS=...,ensure-hq-desktop,...
# Test seams: HQ_ROOT, HQ_ENSURE_DESKTOP_APP_PATH, HQ_ENSURE_DESKTOP_MANIFEST_URL,
#             HQ_ENSURE_DESKTOP_CACHE_TTL, HQ_ENSURE_DESKTOP_COOLDOWN,
#             HQ_ENSURE_DESKTOP_TIMEOUT, HQ_ENSURE_DESKTOP_FETCH_TIMEOUT,
#             HQ_ENSURE_DESKTOP_OS, HQ_ENSURE_DESKTOP_ARCH, HQ_ENSURE_DESKTOP_HOME.

set -uo pipefail
trap 'exit 0' EXIT

# Consume stdin (master-hook always pipes the event JSON, even if unused).
cat >/dev/null 2>&1 || true

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
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$HOOK_DIR/../../.." 2>/dev/null && pwd)}}"
[ -n "$HQ_ROOT" ] || exit 0

STATE_DIR="$HQ_ROOT/workspace/.hq-desktop-ensure"
CACHE="$STATE_DIR/latest.json"
STAMP="$STATE_DIR/last-attempt.stamp"
LOCK_DIR="$STATE_DIR/updating.lock"

MANIFEST_URL="${HQ_ENSURE_DESKTOP_MANIFEST_URL:-https://github.com/indigoai-us/hq-desktop-app/releases/latest/download/latest.json}"
CACHE_TTL="${HQ_ENSURE_DESKTOP_CACHE_TTL:-86400}"      # 24h between manifest fetches
COOLDOWN="${HQ_ENSURE_DESKTOP_COOLDOWN:-21600}"        # 6h between update attempts
UPDATE_TIMEOUT="${HQ_ENSURE_DESKTOP_TIMEOUT:-180}"     # download bound (seconds)
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

platform_key() {
  case "$PLATFORM:$ARCH_NAME" in
    darwin:arm64|darwin:aarch64) echo darwin-aarch64 ;;
    darwin:*)                    echo darwin-x86_64 ;;
    windows:arm64|windows:aarch64|windows:ARM64) echo windows-aarch64 ;;
    windows:*)                   echo windows-x86_64 ;;
  esac
}

# --- context emitters ------------------------------------------------------
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
  local reason="$4"
  cat <<EOF
<hq-desktop-update-available>
The HQ desktop app on this machine is $1; the latest release is $2.
$reason
Download it here and install it over the current copy:

  $3
</hq-desktop-update-available>
EOF
}

# --- 1. installed version ---------------------------------------------------
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

# --- 2. latest version (cached manifest) -----------------------------------
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

DOWNLOAD_URL="$(manifest_url "$CACHE" "$(platform_key)")"
if [ -z "$DOWNLOAD_URL" ] && [ "$PLATFORM" = darwin ]; then
  DOWNLOAD_URL="$(manifest_url "$CACHE" darwin-x86_64)"
  [ -n "$DOWNLOAD_URL" ] || DOWNLOAD_URL="$(manifest_url "$CACHE" darwin-aarch64)"
fi
[ -n "$DOWNLOAD_URL" ] || DOWNLOAD_URL="https://github.com/indigoai-us/hq-desktop-app/releases/latest"

# --- 3. cooldown + atomic claim ---------------------------------------------
if file_age_ok "$STAMP" "$COOLDOWN"; then
  # An attempt already ran recently; keep surfacing the remedy, do not retry.
  [ "$PLATFORM" = windows ] && exit 0                # Windows was told once
  emit_available "$INSTALLED" "$LATEST" "$DOWNLOAD_URL" \
    "HQ tried to update it automatically a little while ago and could not."
  exit 0
fi
mkdir -p "$STATE_DIR" 2>/dev/null || true
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  [ "$PLATFORM" = windows ] && exit 0
  emit_available "$INSTALLED" "$LATEST" "$DOWNLOAD_URL" \
    "Another HQ session is updating it right now."
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null; exit 0' EXIT
: > "$STAMP" 2>/dev/null || true

# --- 4a. Windows: advise once per cooldown ---------------------------------
if [ "$PLATFORM" = windows ]; then
  emit_available "$INSTALLED" "$LATEST" "$DOWNLOAD_URL" \
    "HQ does not run installers silently on Windows."
  exit 0
fi

# --- 4b. macOS: download, verify, swap, relaunch ----------------------------
fail_update() { # $1=reason
  rm -rf "$WORK" 2>/dev/null || true
  emit_available "$INSTALLED" "$LATEST" "$DOWNLOAD_URL" "HQ tried to update it automatically but $1."
  exit 0
}

have curl || fail_update "curl is not available to download it"
have tar  || fail_update "tar is not available to unpack it"

WORK="$STATE_DIR/work.$$"
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
emit_updated "$INSTALLED" "$NEW_VERSION" "$RELAUNCHED"
exit 0
