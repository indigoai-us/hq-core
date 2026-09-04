#!/usr/bin/env bash
# Regression coverage for core/hooks/UserPromptSubmit/31-ensure-hq-desktop.sh.
#
# The hook reads the installed HQ desktop app's version, compares it with the
# public updater manifest (cached 24h), and on macOS replaces an outdated
# bundle with the latest release. It must:
#   1. Stay silent when the app is not installed (it never installs from scratch).
#   2. Stay silent, and not touch the network, when the app is current and the
#      manifest cache is fresh.
#   3. Refresh a stale manifest cache, then stay silent when still current.
#   4. Update an outdated app: download, unpack, verify, swap, relaunch when it
#      was running; announce; clear the attempt stamp.
#   5. Not relaunch an app that was not running.
#   6. Leave the installed app untouched when verification fails (codesign,
#      bundle id, version) and surface the manual remedy.
#   7. Not retry while the cooldown stamp is fresh, but keep surfacing the remedy.
#   8. Not run while a peer session holds the update lock.
#   9. On Windows, advise once per cooldown with the installer link; never download.
#  10. Stay silent on other platforms and under its kill switches.
#  11. Stay silent when no manifest can be obtained at all.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$ROOT/core/hooks/UserPromptSubmit/31-ensure-hq-desktop.sh"
[ -f "$HOOK" ] || { echo "FAIL: hook not found at $HOOK"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

BASH_BIN="$(command -v bash)"

# CORE holds symlinks to exactly the real utilities the hook needs, so a test
# PATH of "$BIN:$CORE" gives the hook its tools while $BIN controls which
# platform-specific commands (curl, pgrep, osascript, open, codesign) exist.
CORE="$TMP/core"; mkdir -p "$CORE"
for u in bash sh cat cp stat date mkdir rm mv rmdir dirname tr sed grep head find tar gzip sleep kill pkill env chmod; do
  p="$(command -v "$u" 2>/dev/null)" && ln -sf "$p" "$CORE/$u"
done
# jq is optional for the hook; exercise the no-jq (sed/grep) parsers here.

BIN="$TMP/bin"; mkdir -p "$BIN"
stub() { # stub <name> <body>
  { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$2"; } > "$BIN/$1"
  chmod +x "$BIN/$1"
}
unstub() { rm -f "$BIN/$1"; }

ROOTDIR="$TMP/hqroot"
HOMEDIR="$TMP/home"
APPS="$TMP/Applications"
APP="$APPS/HQ.app"
STATE="$ROOTDIR/workspace/.hq-desktop-ensure"
MANIFEST_URL="https://example.invalid/latest.json"
MAC_URL="https://example.invalid/HQ_0.10.200_universal.app.tar.gz"
WIN_URL="https://example.invalid/HQ_0.10.200_x64-setup.exe"

write_plist() { # write_plist <app-dir> <version> [bundle-id]
  mkdir -p "$1/Contents/MacOS"
  cat > "$1/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>${3:-ai.indigo.hq-sync-menubar}</string>
  <key>CFBundleShortVersionString</key>
  <string>$2</string>
  <key>CFBundleExecutable</key>
  <string>hq-sync-menubar</string>
</dict>
</plist>
EOF
  printf 'binary %s\n' "$2" > "$1/Contents/MacOS/hq-sync-menubar"
}

write_manifest() { # write_manifest <file> <version>
  cat > "$1" <<EOF
{
  "version": "$2",
  "notes": "test",
  "pub_date": "2026-09-04T00:00:00Z",
  "platforms": {
    "darwin-aarch64": {"signature": "sig", "url": "$MAC_URL"},
    "darwin-x86_64": {"signature": "sig", "url": "$MAC_URL"},
    "windows-x86_64": {"signature": "sig", "url": "$WIN_URL"}
  }
}
EOF
}

# Build the release tarball: HQ.app at the new version (optionally with a
# different bundle id / version to exercise the verification arms).
build_tarball() { # build_tarball <out.tar.gz> <version> [bundle-id]
  local stage="$TMP/stage"; rm -rf "$stage"; mkdir -p "$stage"
  write_plist "$stage/HQ.app" "$2" "${3:-}"
  tar -czf "$1" -C "$stage" HQ.app
}
TARBALL="$TMP/release.tar.gz"
build_tarball "$TARBALL" 0.10.200

FIXTURE_MANIFEST="$TMP/fixture-latest.json"
write_manifest "$FIXTURE_MANIFEST" 0.10.200

# curl stub: serves the manifest fixture or the tarball by URL, and records
# every URL it was asked for so tests can assert "no network" / "no download".
CURL_LOG="$TMP/curl.log"
stub curl "out=''; url=''
while [ \$# -gt 0 ]; do
  case \"\$1\" in
    -o) out=\"\$2\"; shift 2 ;;
    --max-time) shift 2 ;;
    -*) shift ;;
    *) url=\"\$1\"; shift ;;
  esac
done
printf '%s\n' \"\$url\" >> '$CURL_LOG'
case \"\$url\" in
  '$MANIFEST_URL') cp '$FIXTURE_MANIFEST' \"\$out\" ;;
  *.tar.gz)        cp '$TARBALL' \"\$out\" ;;
  *) exit 22 ;;
esac"

CALLS="$TMP/calls.log"
stub open      "echo \"open \$*\" >> '$CALLS'"
stub codesign  "echo codesign >> '$CALLS'; exit 0"
RUNNING_FLAG="$TMP/app-running"
# pgrep reports running while the flag exists; osascript's quit removes it.
# Both must be asked for the exact process NAME (-x), never a command-line
# pattern (-f): a -f match once killed the shell running this very test.
stub pgrep "echo \"pgrep \$*\" >> '$CALLS'; [ \"\$1\" = -x ] || exit 3; [ -f '$RUNNING_FLAG' ]"
# The hook's watchdog helper legitimately uses `pkill -P <pid>`; pass that
# through to the real pkill so background sleeps are reaped.
stub pkill "[ \"\$1\" = -P ] && exec '$CORE/pkill' \"\$@\"; echo \"pkill \$*\" >> '$CALLS'; [ \"\$1\" = -x ] || exit 3; rm -f '$RUNNING_FLAG'"
stub osascript "echo osascript >> '$CALLS'; rm -f '$RUNNING_FLAG'"

reset_root() {
  rm -rf "$ROOTDIR" "$HOMEDIR" "$APPS"
  mkdir -p "$ROOTDIR/workspace" "$HOMEDIR" "$APPS"
  : > "$CURL_LOG"; : > "$CALLS"; rm -f "$RUNNING_FLAG"
}
fresh_cache() { mkdir -p "$STATE"; write_manifest "$STATE/latest.json" "${1:-0.10.200}"; }
stale_cache() { fresh_cache "$@"; touch -d '2 days ago' "$STATE/latest.json" 2>/dev/null || touch -t 202001010000 "$STATE/latest.json"; }
installed_version() { sed -n 's/.*<string>\([0-9.]*\)<\/string>.*/\1/p' "$APP/Contents/Info.plist" | head -1; }

run_hook() { # run_hook [env assignments...]
  env -i PATH="$BIN:$CORE" HQ_ROOT="$ROOTDIR" HOME="$HOMEDIR" \
    HQ_ENSURE_DESKTOP_OS=Darwin HQ_ENSURE_DESKTOP_ARCH=arm64 \
    HQ_ENSURE_DESKTOP_APP_PATH="$APP" HQ_ENSURE_DESKTOP_MANIFEST_URL="$MANIFEST_URL" \
    "$@" "$BASH_BIN" "$HOOK" UserPromptSubmit </dev/null
}

# --- 1. not installed -> silent, no network -------------------------------
reset_root
out="$(run_hook)"
[ -z "$out" ] || fail "missing app should be silent, got: $out"
[ ! -s "$CURL_LOG" ] || fail "missing app must not touch the network"

# --- 2. current + fresh cache -> silent, no network -----------------------
reset_root
write_plist "$APP" 0.10.200
fresh_cache
out="$(run_hook)"
[ -z "$out" ] || fail "current app should be silent, got: $out"
[ ! -s "$CURL_LOG" ] || fail "fresh cache must not be refetched"

# A newer local build (dev) is also "current".
write_plist "$APP" 0.11.0
out="$(run_hook)"
[ -z "$out" ] || fail "ahead-of-latest app should be silent, got: $out"

# --- 3. stale cache -> refetch manifest, still silent when current --------
reset_root
write_plist "$APP" 0.10.200
stale_cache 0.10.100   # old cache says 0.10.100; the fixture says 0.10.200
out="$(run_hook)"
[ -z "$out" ] || fail "current app with stale cache should be silent, got: $out"
grep -qx "$MANIFEST_URL" "$CURL_LOG" || fail "stale cache was not refreshed"
grep -q '"version": "0.10.200"' "$STATE/latest.json" || fail "refreshed manifest was not cached"
[ "$(grep -c . "$CURL_LOG")" -eq 1 ] || fail "current app must not download anything"

# --- 4. outdated + running -> update, relaunch, announce ------------------
reset_root
write_plist "$APP" 0.10.150
fresh_cache
: > "$RUNNING_FLAG"
out="$(run_hook)"
printf '%s' "$out" | grep -q '<hq-desktop-updated>' || fail "outdated app should emit <hq-desktop-updated>, got: $out"
printf '%s' "$out" | grep -q '0.10.150' || fail "announcement should name the old version"
printf '%s' "$out" | grep -q '0.10.200' || fail "announcement should name the new version"
[ "$(installed_version)" = "0.10.200" ] || fail "bundle was not replaced (version $(installed_version))"
grep -q '0.10.200' "$APP/Contents/MacOS/hq-sync-menubar" || fail "new bundle contents not in place"
grep -qx "$MAC_URL" "$CURL_LOG" || fail "the darwin release URL was not downloaded"
grep -q codesign "$CALLS" || fail "codesign verification was skipped"
grep -q osascript "$CALLS" || fail "running app was not asked to quit"
grep -q 'pgrep -x hq-sync-menubar' "$CALLS" || fail "app must be matched by exact process name (pgrep -x)"
grep -q 'pgrep -f' "$CALLS" && fail "app must never be matched by command line (pgrep -f)"
grep -q 'pkill -x' "$CALLS" && fail "a gracefully quit app must not be force-killed"
grep -q "open -a $APP" "$CALLS" || fail "running app was not relaunched"
printf '%s' "$out" | grep -q 'relaunched' || fail "announcement should say it was relaunched"
[ ! -f "$STATE/last-attempt.stamp" ] || fail "successful update must clear the stamp"
[ ! -d "$STATE/updating.lock" ] || fail "lock must be released"
[ -z "$(find "$APPS" -maxdepth 1 -name '*.hq-ensure-backup.*')" ] || fail "backup bundle was left behind"
[ -z "$(find "$STATE" -maxdepth 1 -name 'work.*')" ] || fail "work dir was left behind"

# 4b. graceful quit ignored -> the fallback kills by exact name only.
reset_root
write_plist "$APP" 0.10.150
fresh_cache
: > "$RUNNING_FLAG"
stub osascript "echo osascript >> '$CALLS'"   # app ignores the quit
out="$(run_hook)"
printf '%s' "$out" | grep -q '<hq-desktop-updated>' || fail "stuck app should still be updated, got: $out"
grep -q 'pkill -x hq-sync-menubar' "$CALLS" || fail "stuck app should be killed by exact name"
grep -q 'pkill -f' "$CALLS" && fail "fallback must never pkill -f"
stub osascript "echo osascript >> '$CALLS'; rm -f '$RUNNING_FLAG'"

# --- 5. outdated + not running -> update, no relaunch --------------------
reset_root
write_plist "$APP" 0.10.150
fresh_cache
out="$(run_hook)"
printf '%s' "$out" | grep -q '<hq-desktop-updated>' || fail "outdated (not running) should update, got: $out"
[ "$(installed_version)" = "0.10.200" ] || fail "bundle was not replaced when app not running"
grep -q open "$CALLS" && fail "a non-running app must not be launched"
printf '%s' "$out" | grep -q 'not running' || fail "announcement should say it was not running"

# --- 6. verification failures leave the installed app untouched -----------
# 6a. codesign rejects the download.
reset_root
write_plist "$APP" 0.10.150
fresh_cache
stub codesign 'exit 1'
out="$(run_hook)"
printf '%s' "$out" | grep -q '<hq-desktop-update-available>' || fail "codesign failure should emit the remedy, got: $out"
printf '%s' "$out" | grep -q 'code-signature' || fail "remedy should name the codesign failure"
printf '%s' "$out" | grep -q "$MAC_URL" || fail "remedy should carry the download URL"
[ "$(installed_version)" = "0.10.150" ] || fail "codesign failure must not replace the bundle"
[ -f "$STATE/last-attempt.stamp" ] || fail "failed attempt must leave the cooldown stamp"
[ ! -d "$STATE/updating.lock" ] || fail "lock must be released after failure"
stub codesign "echo codesign >> '$CALLS'; exit 0"

# 6b. bundle id mismatch.
reset_root
write_plist "$APP" 0.10.150
fresh_cache
build_tarball "$TARBALL" 0.10.200 com.example.other
out="$(run_hook)"
printf '%s' "$out" | grep -q 'bundle id' || fail "bundle-id mismatch should be reported, got: $out"
[ "$(installed_version)" = "0.10.150" ] || fail "bundle-id mismatch must not replace the bundle"

# 6c. version mismatch (manifest says 0.10.200, tarball carries 0.10.199).
reset_root
write_plist "$APP" 0.10.150
fresh_cache
build_tarball "$TARBALL" 0.10.199
out="$(run_hook)"
printf '%s' "$out" | grep -q '0.10.199' || fail "version mismatch should be reported, got: $out"
[ "$(installed_version)" = "0.10.150" ] || fail "version mismatch must not replace the bundle"
build_tarball "$TARBALL" 0.10.200

# --- 7. cooldown: fresh stamp -> no download, remedy still surfaces --------
reset_root
write_plist "$APP" 0.10.150
fresh_cache
mkdir -p "$STATE"; : > "$STATE/last-attempt.stamp"
out="$(run_hook)"
printf '%s' "$out" | grep -q '<hq-desktop-update-available>' || fail "cooldown should still surface the remedy, got: $out"
grep -q '.tar.gz' "$CURL_LOG" && fail "cooldown active must NOT re-download"
[ "$(installed_version)" = "0.10.150" ] || fail "cooldown must not touch the bundle"

# --- 8. lock held by a peer -> no download, remedy ------------------------
reset_root
write_plist "$APP" 0.10.150
fresh_cache
mkdir -p "$STATE/updating.lock"
out="$(run_hook)"
printf '%s' "$out" | grep -q 'Another HQ session' || fail "held lock should report the peer, got: $out"
grep -q '.tar.gz' "$CURL_LOG" && fail "held lock must NOT download"
[ -d "$STATE/updating.lock" ] || fail "a peer's lock must not be removed"

# --- 9. Windows: advise once per cooldown, never download -----------------
reset_root
mkdir -p "$HOMEDIR/.hq"
printf '{"version":"0.10.150","updatedAt":"2026-09-01T00:00:00Z"}\n' > "$HOMEDIR/.hq/sync-version.json"
fresh_cache
out="$(run_hook HQ_ENSURE_DESKTOP_OS=Windows_NT HQ_ENSURE_DESKTOP_ARCH=x86_64)"
printf '%s' "$out" | grep -q '<hq-desktop-update-available>' || fail "outdated Windows app should advise, got: $out"
printf '%s' "$out" | grep -q "$WIN_URL" || fail "Windows advice should carry the x64 installer URL"
grep -q '.tar.gz\|setup.exe' "$CURL_LOG" && fail "Windows must never download the installer"
out="$(run_hook HQ_ENSURE_DESKTOP_OS=Windows_NT HQ_ENSURE_DESKTOP_ARCH=x86_64)"
[ -z "$out" ] || fail "Windows advice should not repeat inside the cooldown, got: $out"
# Current on Windows -> silent.
printf '{"version":"0.10.200"}\n' > "$HOMEDIR/.hq/sync-version.json"
rm -f "$STATE/last-attempt.stamp"
out="$(run_hook HQ_ENSURE_DESKTOP_OS=Windows_NT)"
[ -z "$out" ] || fail "current Windows app should be silent, got: $out"

# --- 10. other platforms + kill switches -> silent ------------------------
reset_root
write_plist "$APP" 0.10.150
fresh_cache
out="$(run_hook HQ_ENSURE_DESKTOP_OS=Linux)"
[ -z "$out" ] || fail "Linux should be silent, got: $out"
out="$(run_hook HQ_NO_ENSURE_HQ_DESKTOP=1)"
[ -z "$out" ] || fail "HQ_NO_ENSURE_HQ_DESKTOP=1 should be silent, got: $out"
out="$(run_hook HQ_DISABLED_HOOKS='foo,ensure-hq-desktop,bar')"
[ -z "$out" ] || fail "HQ_DISABLED_HOOKS should be silent, got: $out"
[ "$(installed_version)" = "0.10.150" ] || fail "kill switches must not touch the bundle"

# --- 11. no manifest obtainable (no cache, no curl) -> silent -------------
reset_root
write_plist "$APP" 0.10.150
unstub curl
out="$(run_hook)"
[ -z "$out" ] || fail "no manifest should be silent, got: $out"
[ "$(installed_version)" = "0.10.150" ] || fail "no manifest must not touch the bundle"

echo "PASS: ensure-hq-desktop-hook (not-installed, current, cache-refresh, update+relaunch, update-no-relaunch, verification-guards, cooldown, atomic-lock, windows-advise, platform+kill-switch, no-manifest)"
