#!/usr/bin/env bash
# External-command budget for 31-ensure-hq-desktop.sh.
#
# The no-update path must not scan processes. A pending update may read the
# process list once per cooldown window, including when dozens of other .app
# processes are running. It must not run plutil (or the plist fallback) once
# per process.
#
# bash-guard-process-budgets is the strace suite for the bash write-guards.
# This hook does not fit that harness, so the same budget script is invoked
# from that job and from the desktop-hook job.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$ROOT/core/hooks/UserPromptSubmit/31-ensure-hq-desktop.sh"
[ -f "$HOOK" ] || { echo "FAIL: hook not found at $HOOK"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ensure-desktop-budget.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

REAL_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
SHIMS="$TMP/shims"
LOG="$TMP/cmds.log"
mkdir -p "$SHIMS"
: > "$LOG"

wrap() { # wrap <name>
  local name="$1" real
  real="$(PATH="$REAL_PATH" command -v "$name" 2>/dev/null || true)"
  [ -n "$real" ] || return 0
  cat > "$SHIMS/$name" <<EOF
#!/bin/bash
printf '%s\n' '$name' >> "\$HQ_BUDGET_LOG"
exec '$real' "\$@"
EOF
  chmod +x "$SHIMS/$name"
}

for tool in cat dirname basename stat date grep head tr sed mkdir rm mv touch; do
  wrap "$tool"
done

cat > "$SHIMS/plutil" <<'EOF'
#!/bin/bash
printf 'plutil\n' >> "$HQ_BUDGET_LOG"
key=""
file=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-extract" ]; then key="$arg"; fi
  case "$arg" in
    -*) ;;
    *) file="$arg" ;;
  esac
  prev="$arg"
done
[ -n "$key" ] && [ -f "$file" ] || exit 1
flat="$(/usr/bin/tr -d '\n\r' < "$file")"
val="${flat#*<key>$key</key>}"
[ "$val" != "$flat" ] || exit 1
val="${val#*<string>}"
val="${val%%</string>*}"
[ -n "$val" ] || exit 1
printf '%s\n' "$val"
EOF
chmod +x "$SHIMS/plutil"

cat > "$SHIMS/lsappinfo" <<'EOF'
#!/bin/bash
printf 'lsappinfo\n' >> "$HQ_BUDGET_LOG"
[ "${1:-}" = "list" ] || exit 2
[ ! -s "$HQ_BUDGET_LS" ] || cat "$HQ_BUDGET_LS"
exit 0
EOF
chmod +x "$SHIMS/lsappinfo"

cat > "$SHIMS/ps" <<'EOF'
#!/bin/bash
printf 'ps\n' >> "$HQ_BUDGET_LOG"
[ "$*" = "-axo comm=" ] || exit 2
[ ! -s "$HQ_BUDGET_PS" ] || cat "$HQ_BUDGET_PS"
exit 0
EOF
chmod +x "$SHIMS/ps"

# The budget is the hook's own commands. Do not start the detached worker.
for tool in nohup setsid; do
  cat > "$SHIMS/$tool" <<EOF
#!/bin/bash
printf '%s\n' '$tool' >> "\$HQ_BUDGET_LOG"
exit 0
EOF
  chmod +x "$SHIMS/$tool"
done

ROOTDIR="$TMP/hqroot"
HOMEDIR="$TMP/home"
APP="$TMP/Applications/HQ.app"
STATE="$ROOTDIR/workspace/.hq-desktop-ensure"
LS_FILE="$TMP/ls.txt"
PS_FILE="$TMP/ps.txt"
: > "$LS_FILE"
: > "$PS_FILE"

write_plist() { # write_plist <app> <version> [bundle-id]
  mkdir -p "$1/Contents/MacOS"
  cat > "$1/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>${3:-ai.indigo.hq-sync-menubar}</string>
  <key>CFBundleShortVersionString</key><string>$2</string>
</dict></plist>
EOF
}

write_manifest() {
  mkdir -p "$STATE"
  cat > "$STATE/latest.json" <<EOF
{"version":"$1","platforms":{"darwin-aarch64":{"url":"https://example.invalid/app.tar.gz"}}}
EOF
}

reset_case() {
  rm -rf "$ROOTDIR" "$HOMEDIR"
  mkdir -p "$ROOTDIR/workspace" "$HOMEDIR"
  : > "$LOG"
  : > "$LS_FILE"
  : > "$PS_FILE"
}

run_hook() {
  env -i \
    PATH="$SHIMS" \
    HQ_BUDGET_LOG="$LOG" \
    HQ_BUDGET_LS="$LS_FILE" \
    HQ_BUDGET_PS="$PS_FILE" \
    HQ_ROOT="$ROOTDIR" \
    HOME="$HOMEDIR" \
    HQ_ENSURE_DESKTOP_OS=Darwin \
    HQ_ENSURE_DESKTOP_ARCH=arm64 \
    HQ_ENSURE_DESKTOP_APP_PATH="$APP" \
    HQ_ENSURE_DESKTOP_MANIFEST_URL="https://example.invalid/latest.json" \
    HQ_ENSURE_DESKTOP_COOLDOWN=21600 \
    /bin/bash "$HOOK" </dev/null
}

count_of() {
  local n
  n="$(grep -c "^$1$" "$LOG" || true)"
  printf '%s' "$n"
}
total() { wc -l < "$LOG" | tr -d ' '; }
dump() { echo "commands: $(tr '\n' ' ' < "$LOG")" >&2; }

# --- no update: current app, fresh manifest. No process list. -------------
reset_case
write_plist "$APP" 0.10.200
write_manifest 0.10.200
out="$(run_hook)"
[ -z "$out" ] || fail "current app should be silent, got: $out"
no_total="$(total)"
[ "$no_total" -le 20 ] || { dump; fail "no-update path ran $no_total external commands (budget 20)"; }
[ "$(count_of ps)" -eq 0 ] || fail "no-update path ran ps"
[ "$(count_of lsappinfo)" -eq 0 ] || fail "no-update path ran lsappinfo"
[ "$(count_of plutil)" -le 2 ] || { dump; fail "no-update path ran plutil $(count_of plutil) times"; }
echo "PASS no-update external=$no_total plutil=$(count_of plutil)"

# --- pending, production app running: one scan, then silence. -------------
reset_case
write_plist "$APP" 0.10.150
write_manifest 0.10.200
mkdir -p "$STATE"
printf 'keep\n' > "$STATE/last-attempt.stamp"
printf '    bundleID="ai.indigo.hq-sync-menubar"\n' > "$LS_FILE"
i=0
while [ "$i" -lt 40 ]; do
  printf '/tmp/decoy/App%s.app/Contents/MacOS/bin\n' "$i" >> "$PS_FILE"
  i=$((i + 1))
done
out="$(run_hook)"
case "$out" in *'<hq-desktop-update-deferred>'*) ;; *) dump; fail "running app should notice, got: $out" ;; esac
run_total="$(total)"
[ "$run_total" -le 40 ] || { dump; fail "pending running path ran $run_total external commands (budget 40)"; }
[ "$(count_of ps)" -le 1 ] || fail "pending running path ran ps $(count_of ps) times"
[ "$(count_of lsappinfo)" -le 1 ] || fail "pending running path ran lsappinfo $(count_of lsappinfo) times"
[ "$(count_of plutil)" -le 2 ] || { dump; fail "pending running path ran plutil $(count_of plutil) times"; }
[ "$(cat "$STATE/last-attempt.stamp")" = "keep" ] || fail "running path deleted the cooldown stamp"
echo "PASS pending-running external=$run_total plutil=$(count_of plutil) ps=$(count_of ps) lsappinfo=$(count_of lsappinfo)"

: > "$LOG"
out="$(run_hook)"
[ -z "$out" ] || { dump; fail "second pending prompt should be silent, got: $out"; }
[ "$(count_of ps)" -eq 0 ] || { dump; fail "second prompt ran ps"; }
[ "$(count_of lsappinfo)" -eq 0 ] || { dump; fail "second prompt ran lsappinfo"; }
[ "$(count_of plutil)" -le 2 ] || { dump; fail "second prompt ran plutil $(count_of plutil) times"; }
second_total="$(total)"
# The second prompt also claims the deferred result record (sed/head per field).
# That work is bounded. ps and lsappinfo staying at zero is the scan budget.
[ "$second_total" -le 40 ] || { dump; fail "second prompt ran $second_total external commands (budget 40)"; }
[ "$(cat "$STATE/last-attempt.stamp")" = "keep" ] || fail "second prompt deleted the cooldown stamp"
echo "PASS pending-running-second external=$second_total"

# --- pending, closed app, 40 other bundles. One ps, no per-process plutil. -
reset_case
write_plist "$APP" 0.10.150
write_manifest 0.10.200
: > "$LS_FILE"
: > "$PS_FILE"
i=0
while [ "$i" -lt 40 ]; do
  decoy="$TMP/decoy/App$i.app"
  write_plist "$decoy" 9.9.9 "com.example.decoy$i"
  printf '%s\n' "$decoy/Contents/MacOS/bin" >> "$PS_FILE"
  i=$((i + 1))
done
# One plist that cannot be read must not turn into "HQ is running".
mkdir -p "$TMP/decoy/Broken.app/Contents/MacOS"
printf '%s\n' "$TMP/decoy/Broken.app/Contents/MacOS/anything" >> "$PS_FILE"
out="$(run_hook)"
case "$out" in *'<hq-desktop-update-deferred>'*) dump; fail "closed app deferred: $out" ;; esac
case "$out" in *'<hq-desktop-update-started>'*) ;; *) dump; fail "closed app should start, got: $out" ;; esac
closed_total="$(total)"
[ "$(count_of plutil)" -le 2 ] || { dump; fail "closed path ran plutil $(count_of plutil) times for 41 other bundles"; }
[ "$(count_of ps)" -eq 1 ] || { dump; fail "closed path ran ps $(count_of ps) times"; }
[ "$(count_of lsappinfo)" -eq 1 ] || { dump; fail "closed path ran lsappinfo $(count_of lsappinfo) times"; }
[ "$(count_of tr)" -le 3 ] || { dump; fail "closed path ran tr $(count_of tr) times"; }
[ "$(count_of sed)" -le 3 ] || { dump; fail "closed path ran sed $(count_of sed) times"; }
[ "$closed_total" -le 45 ] || { dump; fail "closed path ran $closed_total external commands (budget 45)"; }
echo "PASS pending-closed external=$closed_total plutil=$(count_of plutil) ps=$(count_of ps)"

echo "PASS: ensure-hq-desktop-process-budget"
