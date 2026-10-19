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
#   * running production app                  -> defer once per pending version;
#                                                a dev bundle does not block it.
#   * older, closed app                       -> macOS: download, verify, swap;
#                                                never quit or launch the app.
#                                                Windows: advise installer link.
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
# Kill switches: HQ_NO_ENSURE_HQ_DESKTOP=1, HQ_DISABLED_HOOKS=...,ensure-hq-desktop,...,
# or HQ_UPDATER_DISABLED set to 1, true, or yes. That flag accepts the same
# values as the desktop app's env_flag_value_enabled (trimmed, any case).
# Empty, 0, and on leave the hook enabled. Test and demo machines set it with
# `launchctl setenv` to pin a build; without honoring it here, the first
# Claude prompt on such a machine (for example the first-run setup assistant)
# replaced the pinned build with the latest release and relaunched it
# mid-onboarding (hq-desktop-app PR #1670).
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
# updater.rs env_flag_value_enabled: trim, then 1 / true / yes in any case.
_upd="${HQ_UPDATER_DISABLED:-}"
_upd="${_upd#"${_upd%%[![:space:]]*}"}"
_upd="${_upd%"${_upd##*[![:space:]]}"}"
case "$_upd" in
  1|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]) exit 0 ;;
esac
unset _upd

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
APP_RUNNING_CACHE="$STATE_DIR/app-running.cache"
DEFERRED_NOTICE="$STATE_DIR/deferred-notice"

MANIFEST_URL="${HQ_ENSURE_DESKTOP_MANIFEST_URL:-https://github.com/indigoai-us/hq-desktop-app/releases/latest/download/latest.json}"
CACHE_TTL="${HQ_ENSURE_DESKTOP_CACHE_TTL:-86400}"      # 24h between manifest fetches
COOLDOWN="${HQ_ENSURE_DESKTOP_COOLDOWN:-21600}"        # 6h between update attempts
UPDATE_TIMEOUT="${HQ_ENSURE_DESKTOP_TIMEOUT:-900}"     # worker download bound (seconds)
FETCH_TIMEOUT="${HQ_ENSURE_DESKTOP_FETCH_TIMEOUT:-8}"  # manifest bound (seconds)
OS_NAME="${HQ_ENSURE_DESKTOP_OS:-$(uname -s 2>/dev/null || echo unknown)}"
ARCH_NAME="${HQ_ENSURE_DESKTOP_ARCH:-$(uname -m 2>/dev/null || echo unknown)}"
USER_HOME="${HQ_ENSURE_DESKTOP_HOME:-${HOME:-}}"
RECORDING_LEDGER="$USER_HOME/.hq/recordings-ledger.json"
RECORDING_MARKER="$USER_HOME/.hq/recording-active.json"

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
  # Intentional splitting of validated numeric semver components on dots.
  # shellcheck disable=SC2086
  set -- $actual; a1="${1:-0}"; a2="${2:-0}"; a3="${3:-0}"
  # shellcheck disable=SC2086
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
    [ "$(bundle_identifier "${HQ_ENSURE_DESKTOP_APP_PATH}")" = "$BUNDLE_ID" ] || return 1
    printf '%s\n' "${HQ_ENSURE_DESKTOP_APP_PATH}"
    return 0
  fi
  for candidate in "/Applications/$APP_BUNDLE" "$USER_HOME/Applications/$APP_BUNDLE"; do
    [ -f "$candidate/Contents/Info.plist" ] || continue
    # Only the shipped app is ours to update. A test build installed as
    # HQ.app (a scratch or Lane Check bundle with its own bundle id) is left
    # alone: on 2026-10-12 this hook replaced one on a test VM with the
    # public release and pkilled it mid-walkthrough.
    [ "$(bundle_identifier "$candidate")" = "$BUNDLE_ID" ] || return 1
    printf '%s\n' "$candidate"
    return 0
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

# The marker is the hq-desktop-app PR #1476 contract. Treat every parse or
# liveness failure as stale: the legacy ledger below protects already-shipped
# desktop builds until that marker is universally available.
# Treat every parse or liveness failure as stale: a false positive would prevent
# an otherwise safe update indefinitely, while a false negative is avoided by
# requiring all three independent freshness signals below.
marker_recording_active() {
  local f="$RECORDING_MARKER" pid="" updated="" now updated_epoch age
  [ -f "$f" ] || return 1

  if have jq; then
    pid="$(jq -r 'if ((.recordings | type) == "array" and (.recordings | length) > 0) then (.pid // empty) else empty end' "$f" 2>/dev/null)"
    updated="$(jq -r 'if ((.recordings | type) == "array" and (.recordings | length) > 0) then (.updatedAt // empty) else empty end' "$f" 2>/dev/null)"
  else
    grep -Eq '"recordings"[[:space:]]*:[[:space:]]*\[[[:space:]]*\{' "$f" 2>/dev/null || return 1
    pid="$(grep -oE '"pid"[[:space:]]*:[[:space:]]*[0-9]+' "$f" 2>/dev/null | head -1 | grep -oE '[0-9]+')"
    updated="$(grep -oE '"updatedAt"[[:space:]]*:[[:space:]]*"[^"]+"' "$f" 2>/dev/null | head -1 | sed -n 's/.*"\([^"]*\)"$/\1/p')"
  fi

  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1

  # The writer uses UTC ISO-8601. Trim fractional seconds and normalize a
  # zero UTC offset so both GNU date (Windows Git Bash/Linux CI) and BSD date
  # (macOS) can parse the value. Non-zero offsets are deliberately rejected:
  # the recording ledger contract is UTC only.
  updated="$(printf '%s' "$updated" | sed -E 's/\.[0-9]+(Z|[+-][0-9][0-9]:[0-9][0-9])$/\1/')"
  case "$updated" in
    *+00:00) updated="${updated%+00:00}Z" ;;
    *-00:00) updated="${updated%-00:00}Z" ;;
    *[+-]??:??) return 1 ;;
    *Z) ;;
    *) return 1 ;;
  esac
  updated_epoch="$(date -u -d "$updated" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$updated" +%s 2>/dev/null || echo 0)"
  now="$(date -u +%s 2>/dev/null || echo 0)"
  case "$updated_epoch:$now" in *[!0-9:]*|:*) return 1 ;; esac
  age=$((now - updated_epoch))
  [ "$age" -ge 0 ] && [ "$age" -le 300 ]
}

# The shipped desktop app maintains this durable in-flight ledger. Its entries
# contain recordingId, so a literal substring is deliberately fail-closed and
# jq-free: an unreadable or partial non-empty ledger must not cause a quit.
ledger_recording_active() {
  [ -f "$RECORDING_LEDGER" ] || return 1
  grep -q '"recordingId"' "$RECORDING_LEDGER" 2>/dev/null
}

# Read-only running-app detection; never send application lifecycle commands.
# Only the installed production bundle defers an update. A dev or demo bundle
# running beside a closed HQ.app is not the pending update's target.
#
# The hook caches one process-list read for the cooldown window. The worker
# detects again at replacement time and does not trust that cache.
running_cache_fresh() {
  [ "$PLATFORM" = darwin ] || return 1
  file_age_ok "$APP_RUNNING_CACHE" "$COOLDOWN"
}

running_cache_says_yes() {
  running_cache_fresh || return 1
  local running=""
  IFS= read -r running < "$APP_RUNNING_CACHE" || return 1
  [ "$running" = 1 ]
}

write_running_cache() { # $1 = 0 or 1
  local tmp="$APP_RUNNING_CACHE.tmp.$$"
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  printf '%s\n' "$1" > "$tmp" 2>/dev/null || return 0
  mv "$tmp" "$APP_RUNNING_CACHE" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
}

detect_app_running() {
  if [ "$PLATFORM" != darwin ]; then
    have pgrep && pgrep -x "$PROCESS_NAME" >/dev/null 2>&1
    return
  fi
  local apps processes executable target="${APP_PATH:-}"
  if have lsappinfo; then
    apps="$(lsappinfo list 2>/dev/null)" || return 0
    # Exact production id. A longer id such as ai.indigo.hq-sync-menubar-dev
    # must not match: the closing quote is part of the searched text.
    if printf '%s\n' "$apps" | grep -F "bundleID=\"${BUNDLE_ID}\"" >/dev/null; then
      return 0
    fi
  fi
  # One process list. Match the installed app's path only. Do not read other
  # bundles' Info.plists: an unreadable plist must not look like HQ.
  have ps || return 0
  processes="$(ps -axo comm= 2>/dev/null)" || return 0
  [ -n "$target" ] || return 1
  while IFS= read -r executable || [ -n "$executable" ]; do
    case "$executable" in
      "$target"/Contents/*) return 0 ;;
    esac
  done <<< "$processes"
  return 1
}

app_running() {
  if [ "$MODE" != worker ] && running_cache_says_yes; then
    return 0
  fi
  detect_app_running
}

# Both the legacy ledger and new marker are live recording contracts. A stale
# signal from a crashed app does not block an update because there is no app to
# quit; the next desktop launch reconciles it.
recording_active() { marker_recording_active || ledger_recording_active; }
recording_in_progress() { app_running && recording_active; }

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
updating it in the background now. This can take a few minutes; if the app
starts before replacement, the update will wait until it is closed.
The outcome will be reported on a later prompt — no action is needed.
</hq-desktop-update-started>
EOF
}

emit_updated() { # $1=old $2=new
  cat <<EOF
<hq-desktop-updated>
The HQ desktop app was out of date ($1), so HQ updated it to $2 in place.
It was not running; the new version starts the next time HQ is opened.
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

emit_deferred() { # $1=installed $2=latest
  cat <<EOF
<hq-desktop-update-deferred>
The HQ desktop app on this machine is $1; the latest release is $2.
The app is running, so the hook left it untouched. The app manages its own
updates while open; hook-driven updates wait until it is closed.
</hq-desktop-update-deferred>
EOF
}

# ===========================================================================
# WORKER: download, verify, swap only while closed. Runs detached; reports via $RESULT.
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
  # Keep a downloaded, verified bundle under this stable path when the app
  # starts during the download. The next worker verifies it again and swaps it
  # without fetching the same release a second time.
  WORK="$STATE_DIR/work"

  fail_update() { # $1=reason
    rm -rf "$WORK" 2>/dev/null || true
    write_result failed "$INSTALLED" "$LATEST" "HQ tried to update it automatically but $1." 0 "$DOWNLOAD_URL"
    echo "[$(date -u +%H:%M:%S)] failed: $1"
    exit 0
  }

  defer_update() { # $1=reason — retain the verified staged bundle for retry
    rm -f "$STAMP" "$APP_RUNNING_CACHE" 2>/dev/null || true
    write_result deferred "$INSTALLED" "$LATEST" "$1" 0 "$DOWNLOAD_URL"
    echo "[$(date -u +%H:%M:%S)] deferred: $1"
    exit 0
  }

  app_running && defer_update "the HQ desktop app is running; its own updater owns updates"

  echo "[$(date -u +%H:%M:%S)] updating $INSTALLED -> $LATEST from $DOWNLOAD_URL"
  have curl || fail_update "curl is not available to download it"
  have tar  || fail_update "tar is not available to unpack it"

  NEW_APP=""
  if [ -d "$WORK" ]; then
    NEW_APP="$(find "$WORK" -maxdepth 2 -type d -name '*.app' 2>/dev/null | head -1)"
  fi
  # A deferred worker can leave a verified bundle here for a retry after a
  # running app closes. Reuse it only for this exact release: the manifest may
  # have advanced while the app was open.
  if [ -n "$NEW_APP" ] && [ -f "$NEW_APP/Contents/Info.plist" ]; then
    if [ "$(bundle_identifier "$NEW_APP")" != "$BUNDLE_ID" ] \
      || [ "$(bundle_version "$NEW_APP")" != "$LATEST" ]; then
      rm -rf "$WORK" 2>/dev/null
      NEW_APP=""
    fi
  fi
  if [ -z "$NEW_APP" ] || [ ! -f "$NEW_APP/Contents/Info.plist" ]; then
    rm -rf "$WORK" 2>/dev/null
    mkdir -p "$WORK" 2>/dev/null || fail_update "could not create a working directory"
    curl -fsSL --max-time "$UPDATE_TIMEOUT" -o "$WORK/app.tar.gz" "$DOWNLOAD_URL" >/dev/null 2>&1 \
      || fail_update "the download failed"
    tar -xzf "$WORK/app.tar.gz" -C "$WORK" >/dev/null 2>&1 \
      || fail_update "the download could not be unpacked"
    NEW_APP="$(find "$WORK" -maxdepth 2 -type d -name '*.app' 2>/dev/null | head -1)"
    [ -n "$NEW_APP" ] && [ -f "$NEW_APP/Contents/Info.plist" ] \
      || fail_update "the download did not contain an app bundle"
  fi

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

  BACKUP="$APP_PATH.hq-ensure-backup.$$"
  rm -rf "$BACKUP" 2>/dev/null || true
  # The app may have started during download or verification. Check at the
  # replacement boundary and retain the verified bundle for a later prompt.
  app_running && defer_update "the HQ desktop app started before replacement"
  if ! mv "$APP_PATH" "$BACKUP" 2>/dev/null; then
    fail_update "it could not replace $APP_PATH (permission denied?)"
  fi
  if ! mv "$NEW_APP" "$APP_PATH" 2>/dev/null; then
    mv "$BACKUP" "$APP_PATH" 2>/dev/null || true
    fail_update "it could not move the new app into $APP_PATH (the old copy was kept)"
  fi
  rm -rf "$BACKUP" "$WORK" 2>/dev/null || true
  rm -f "$STAMP" 2>/dev/null || true

  write_result updated "$INSTALLED" "$NEW_VERSION" "" 0 "$DOWNLOAD_URL"
  echo "[$(date -u +%H:%M:%S)] updated $INSTALLED -> $NEW_VERSION (app left closed)"
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
    R_REASON="$(result_get reason)"; R_URL="$(result_get url)"
    rm -f "$CLAIM" 2>/dev/null || true
    case "$R_STATUS" in
      updated) emit_updated "$R_FROM" "$R_TO"; exit 0 ;;
      failed)  emit_available "$R_FROM" "$R_TO" "$R_URL" "$R_REASON"; exit 0 ;;
      # A deferred worker may have finished after the app closed. Claim
      # its result, then continue so this same prompt can reuse its staged app.
      deferred) : ;;
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

# A running production app defers replacement. Notice once per pending
# version, and never delete the cooldown stamp from this check. A recording
# defers Windows installer advice the same way.
DOWNLOAD_URL="$(download_url_for "$CACHE")"
defer_notice_once() {
  local seen="" tmp="$DEFERRED_NOTICE.tmp.$$"
  [ -f "$DEFERRED_NOTICE" ] && IFS= read -r seen < "$DEFERRED_NOTICE" || true
  [ "$seen" = "$LATEST" ] && return 0
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  printf '%s\n' "$LATEST" > "$tmp" 2>/dev/null && mv "$tmp" "$DEFERRED_NOTICE" 2>/dev/null || true
  write_result deferred "$INSTALLED" "$LATEST" app_running 0 "$DOWNLOAD_URL"
  emit_deferred "$INSTALLED" "$LATEST"
}

if [ "$PLATFORM" = darwin ] && running_cache_says_yes; then
  defer_notice_once
  exit 0
fi
if [ "$PLATFORM" != darwin ] && recording_in_progress; then
  defer_notice_once
  exit 0
fi

# Read the process list only when the cached answer is missing, or when a
# cached "not running" would otherwise let this prompt start an update.
# A fresh cooldown stamp never skips the running-app notice, and this check
# does not delete that stamp.
if [ "$PLATFORM" = darwin ]; then
  scan=0
  if ! running_cache_fresh; then
    scan=1
  elif ! file_age_ok "$STAMP" "$COOLDOWN"; then
    scan=1
  fi
  if [ "$scan" -eq 1 ]; then
    if detect_app_running; then
      write_running_cache 1
      defer_notice_once
      exit 0
    fi
    write_running_cache 0
  fi
fi

# --- 4. cooldown: one attempt (and one announcement) per window -----------
file_age_ok "$STAMP" "$COOLDOWN" && exit 0
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
mkdir "$LOCK_DIR" 2>/dev/null || exit 0             # a peer got there first
: > "$STAMP" 2>/dev/null || true

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
