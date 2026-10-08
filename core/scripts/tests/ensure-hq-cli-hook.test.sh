#!/usr/bin/env bash
# Regression coverage for core/hooks/UserPromptSubmit/30-ensure-hq-cli.sh.
#
# The hook reads the PATH Claude Code runs under from .claude/settings.local.json
# (fallback settings.json) and, when `hq` is not on it, auto-fixes by appending
# hq's dir to env.PATH in settings.local.json. It must:
#   1. Stay silent when hq resolves on the settings PATH.
#   2. Fall back to the ambient PATH when no settings PATH is configured.
#   3. Auto-fix: hq installed but off the settings PATH -> append its dir to
#      env.PATH in settings.local.json (NOT settings.json), preserving other keys.
#   4. Install when hq is missing, then auto-fix the PATH; announce it.
# 5. Emit the manual-install remedy when hq is missing and no installer is present.
#   6. Not re-run the install command while the cooldown stamp is fresh.
#   7. Emit the add-to-PATH remedy when settings cannot be written (no jq).
#   8. Honor its kill switches.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$ROOT/core/hooks/UserPromptSubmit/30-ensure-hq-cli.sh"
[ -f "$HOOK" ] || { echo "FAIL: hook not found at $HOOK"; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

BASH_BIN="$(command -v bash)"

# CORE holds symlinks to exactly the real utilities the hook needs — so a test
# PATH of "$BIN:$CORE" gives the hook its tools while letting us control whether
# `hq`/`npm` are resolvable purely by what we drop into $BIN.
CORE="$TMP/core"; mkdir -p "$CORE"
for u in bash sh cat stat date mkdir rm mv dirname timeout chmod env grep head jq sleep kill pkill ps awk; do
  p="$(command -v "$u" 2>/dev/null)" && ln -sf "$p" "$CORE/$u"
done

BIN="$TMP/bin"; mkdir -p "$BIN"

stub() { # stub <name> <body>
  { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$2"; } > "$BIN/$1"
  chmod +x "$BIN/$1"
}

# HQ_ROOT for the run; settings live under $HQ_ROOT/.claude/.
ROOTDIR="$TMP/hqroot"
reset_root() {
  rm -rf "$ROOTDIR"
  mkdir -p "$ROOTDIR/workspace" "$ROOTDIR/.claude"
}
write_local_settings() { printf '%s\n' "$1" > "$ROOTDIR/.claude/settings.local.json"; }
write_base_settings() { printf '%s\n' "$1" > "$ROOTDIR/.claude/settings.json"; }
local_path() { jq -r '.env.PATH // empty' "$ROOTDIR/.claude/settings.local.json" 2>/dev/null; }

run_hook() { # run_hook <PATH> [env assignments...]
  local runpath="$1"; shift
  env -i PATH="$runpath" HQ_ROOT="$ROOTDIR" HOME="$TMP/home" "$@" \
    "$BASH_BIN" "$HOOK" UserPromptSubmit </dev/null
}

COREUTILS_PATH="$BIN:$CORE"

# --- 1. a trusted hq resolves on the settings PATH -> silent -------------
reset_root
stub hq 'echo 5.108.2'
write_local_settings "{\"env\":{\"PATH\":\"$BIN:/usr/bin\"}}"
out="$(run_hook "$COREUTILS_PATH")"
[ -z "$out" ] || fail "hq on settings PATH should be silent, got: $out"
rm -f "$BIN/hq"

# --- 1a. a successful probe is cached per session window (HP-8) ---------
reset_root
CALLS="$TMP/hq-calls"; : > "$CALLS"
stub hq "echo probe >> '$CALLS'; echo 5.108.2"
write_local_settings "{\"env\":{\"PATH\":\"$BIN:/usr/bin\"}}"
out="$(run_hook "$COREUTILS_PATH")"; [ -z "$out" ] || fail "1a first run should be silent, got: $out"
out="$(run_hook "$COREUTILS_PATH")"; [ -z "$out" ] || fail "1a second run should be silent, got: $out"
[ "$(wc -l < "$CALLS" | tr -d ' ')" = "1" ] || fail "1a: expected one version probe across two prompts, got $(cat "$CALLS" | wc -l)"
[ -f "$ROOTDIR/workspace/.hq-cli-ensure/usable.ok" ] || fail "1a: usable.ok cache was not written"
# TTL 0 disables the cache -> re-probe.
run_hook "$COREUTILS_PATH" HQ_ENSURE_CLI_OK_TTL=0 >/dev/null
[ "$(wc -l < "$CALLS" | tr -d ' ')" = "2" ] || fail "1a: TTL=0 should re-probe"
# A changed binary (different mtime) invalidates the cache -> re-probe.
touch -t 202001010000 "$BIN/hq"
run_hook "$COREUTILS_PATH" >/dev/null
[ "$(wc -l < "$CALLS" | tr -d ' ')" = "3" ] || fail "1a: a changed hq binary should re-probe"
# A failing probe is never cached: a broken hq re-probes every prompt.
reset_root
: > "$CALLS"
stub hq "echo probe >> '$CALLS'; exit 1"
write_local_settings "{\"env\":{\"PATH\":\"$BIN:/usr/bin\"}}"
run_hook "$COREUTILS_PATH" HQ_ENSURE_CLI_COOLDOWN=0 >/dev/null 2>&1 || true
run_hook "$COREUTILS_PATH" HQ_ENSURE_CLI_COOLDOWN=0 >/dev/null 2>&1 || true
[ ! -f "$ROOTDIR/workspace/.hq-cli-ensure/usable.ok" ] || fail "1a: a failing probe must not be cached"
printf '%s\n' 'PASS: successful version probe is cached per window; failures and changed binaries re-probe'
reset_root
rm -f "$BIN/hq"

# --- 1b. Windows settings PATH resolves a Git Bash-visible hq.cmd shim ----
reset_root
WINDOWS_HQ_BIN="$TMP/windows-hq-bin"
mkdir -p "$WINDOWS_HQ_BIN" "$TMP/windows-system32"
printf '#!/usr/bin/env bash\necho 5.108.2\n' > "$WINDOWS_HQ_BIN/hq.cmd"
chmod +x "$WINDOWS_HQ_BIN/hq.cmd"
stub cygpath "printf '%s\\n' '$WINDOWS_HQ_BIN:$TMP/windows-system32'"
write_local_settings '{"env":{"PATH":"C:\\Users\\HqTest\\.hq-cli\\node_modules\\.bin;C:\\Windows\\System32"}}'
out="$(run_hook "$COREUTILS_PATH")"
[ -z "$out" ] || fail "Windows settings PATH with a working hq.cmd should be silent, got: $out"
printf '%s\n' 'PASS: Windows settings PATH resolves cygpath-converted hq.cmd'
rm -f "$BIN/cygpath" "$WINDOWS_HQ_BIN/hq.cmd"

# --- 1c. adding an off-PATH Windows shim preserves the Windows delimiter --
reset_root
WINDOWS_NPM_BIN="$TMP/windows-npm-bin"; mkdir -p "$WINDOWS_NPM_BIN" "$TMP/windows-system32"
printf '#!/usr/bin/env bash\necho 5.108.2\n' > "$WINDOWS_NPM_BIN/hq.cmd"
chmod +x "$WINDOWS_NPM_BIN/hq.cmd"
stub cygpath "case \"\$1:\${2:-}\" in
  -u:-p) printf '%s\\n' '$TMP/windows-system32' ;;
  -m:*) printf '%s\\n' 'C:/Users/HqTest/AppData/Local/Temp/windows-npm-bin' ;;
  *) printf '%s\\n' '$TMP/windows-system32' ;;
esac"
stub npm "case \"\$*\" in 'prefix -g') printf '%s\\n' '$WINDOWS_NPM_BIN';; *) exit 1;; esac"
write_local_settings '{"env":{"PATH":"C:\\Users\\HqTest\\.hq-cli\\node_modules\\.bin;C:\\Windows\\System32"}}'
out="$(run_hook "$COREUTILS_PATH")"
grep -F '<hq-cli-path-updated>' <<<"$out" >/dev/null \
  || fail "off-PATH Windows hq.cmd should be added to settings PATH, got: $out"
[ "$(local_path)" = "C:/Users/HqTest/AppData/Local/Temp/windows-npm-bin;C:\\Users\\HqTest\\.hq-cli\\node_modules\\.bin;C:\\Windows\\System32" ] \
  || fail "adding Windows hq.cmd must preserve semicolon-delimited PATH, got: $(local_path)"
printf '%s\n' 'PASS: adding an off-PATH Windows hq.cmd preserves semicolon separators'
rm -f "$BIN/cygpath" "$BIN/npm" "$WINDOWS_NPM_BIN/hq.cmd"

# --- 2. no settings PATH configured -> ambient fallback (silent) ---------
reset_root
write_local_settings '{}'
stub hq 'echo 5.108.2'
out="$(run_hook "$COREUTILS_PATH")"   # hq stub is on ambient PATH
[ -z "$out" ] || fail "ambient hq with no settings PATH should be silent, got: $out"
rm -f "$BIN/hq"

# --- 3. hq installed but OFF the settings PATH -> auto-fix local settings --
reset_root
# settings PATH deliberately excludes where hq lives; add an unrelated key.
write_local_settings "{\"env\":{\"PATH\":\"/usr/bin:/bin\",\"FOO\":\"bar\"},\"other\":1}"
stub hq 'echo 5.108.2'   # hq is on ambient PATH ($BIN) but not on the settings PATH
out="$(run_hook "$COREUTILS_PATH")"
printf '%s' "$out" | grep -q '<hq-cli-path-updated>' \
  || fail "off-settings-PATH hq should emit <hq-cli-path-updated>, got: $out"
# settings.local.json now carries $BIN on env.PATH...
case ":$(local_path):" in *":$BIN:"*) : ;; *) fail "auto-fix did not add $BIN to env.PATH: $(local_path)";; esac
# ...and preserved the sibling keys.
[ "$(jq -r '.env.FOO' "$ROOTDIR/.claude/settings.local.json")" = "bar" ] \
  || fail "auto-fix clobbered env.FOO"
[ "$(jq -r '.other' "$ROOTDIR/.claude/settings.local.json")" = "1" ] \
  || fail "auto-fix clobbered top-level key"
# settings.json must NOT be created/written.
[ ! -f "$ROOTDIR/.claude/settings.json" ] || fail "hook must not write settings.json"
rm -f "$BIN/hq"

# --- 4. hq missing -> install, then auto-fix + announce ------------------
reset_root
write_local_settings "{\"env\":{\"PATH\":\"/usr/bin:/bin\"}}"
mkdir -p "$TMP/prefix/bin" "$TMP/pnpm-prefix/bin"
stub npm "case \"\$*\" in
  'prefix -g') echo '$TMP/prefix'; exit 0 ;;
  *) exit 0 ;;
esac"
stub pnpm "case \"\$*\" in
  *add*) printf '#!/usr/bin/env bash\\necho 5.108.2\\n' > '$TMP/pnpm-prefix/bin/hq'; chmod +x '$TMP/pnpm-prefix/bin/hq'; exit 0 ;;
  'bin -g') echo '$TMP/pnpm-prefix/bin'; exit 0 ;;
  *) exit 0 ;;
esac"
out="$(run_hook "$COREUTILS_PATH")"
printf '%s' "$out" | grep -q '<hq-cli-path-updated>' \
  || fail "install+fix should emit <hq-cli-path-updated>, got: $out"
case ":$(local_path):" in *":$TMP/pnpm-prefix/bin:"*) : ;; *) fail "install did not add global bin to env.PATH: $(local_path)";; esac
[ ! -f "$ROOTDIR/workspace/.hq-cli-ensure/last-attempt.stamp" ] \
  || fail "successful install must clear the stamp"
rm -f "$BIN/npm" "$BIN/pnpm"

# A path entry is not health proof: stale and broken hq binaries must be
# repaired instead of making the hook return a false healthy no-op.
reset_root
OLD_BIN="$TMP/old-hq-bin"; mkdir -p "$OLD_BIN"
printf '#!/usr/bin/env bash\necho 5.77.10\n' > "$OLD_BIN/hq"
chmod +x "$OLD_BIN/hq"
rm -f "$TMP/prefix/bin/hq"
write_local_settings "{\"env\":{\"PATH\":\"$OLD_BIN:/usr/bin:/bin\"}}"
stub npm "case \"\$*\" in
  'prefix -g') echo '$TMP/prefix'; exit 0 ;;
  *) exit 0 ;;
esac"
stub pnpm "case \"\$*\" in
  *add*) printf '#!/usr/bin/env bash\\necho 5.108.2\\n' > '$TMP/prefix/bin/hq'; chmod +x '$TMP/prefix/bin/hq'; echo installed > '$TMP/stale-repaired'; exit 0 ;;
  'bin -g') echo '$TMP/prefix/bin'; exit 0 ;;
  *) exit 0 ;;
esac"
out="$(run_hook "$COREUTILS_PATH")"
[ -f "$TMP/stale-repaired" ] || fail "a stale hq binary did not trigger repair"
printf '%s' "$out" | grep -q '<hq-cli-path-updated>' \
  || fail "stale hq repair should emit <hq-cli-path-updated>, got: $out"
case ":$(local_path):" in *":$TMP/prefix/bin:"*) : ;; *) fail "repaired hq bin was not preferred on settings PATH";; esac
rm -f "$BIN/npm" "$BIN/pnpm"

# A binary found only through repo-controlled settings is never executed. It
# must be treated as untrusted and repaired from a known install location.
reset_root
HANG_BIN="$TMP/hanging-hq-bin"; mkdir -p "$HANG_BIN"
printf '#!/usr/bin/env bash\necho executed > %s\nsleep 5\necho 5.108.2\n' "$TMP/untrusted-executed" > "$HANG_BIN/hq"
chmod +x "$HANG_BIN/hq"
rm -f "$TMP/prefix/bin/hq"
write_base_settings "{\"env\":{\"PATH\":\"$HANG_BIN:/usr/bin:/bin\"}}"
stub npm "case \"\$*\" in
  'prefix -g') echo '$TMP/prefix'; exit 0 ;;
  *) exit 0 ;;
esac"
stub pnpm "case \"\$*\" in
  *add*) printf '#!/usr/bin/env bash\\necho 5.108.2\\n' > '$TMP/prefix/bin/hq'; chmod +x '$TMP/prefix/bin/hq'; exit 0 ;;
  'bin -g') echo '$TMP/prefix/bin'; exit 0 ;;
  *) exit 0 ;;
esac"
start="$(date +%s)"
out="$(run_hook "$COREUTILS_PATH" HQ_ENSURE_CLI_VERSION_TIMEOUT=1)"
elapsed="$(( $(date +%s) - start ))"
[ "$elapsed" -lt 4 ] || fail "untrusted settings hq was executed (took ${elapsed}s)"
[ ! -f "$TMP/untrusted-executed" ] || fail "repo-controlled settings hq must never execute"
printf '%s' "$out" | grep -q '<hq-cli-path-updated>' \
  || fail "an untrusted settings hq should trigger repair, got: $out"
rm -f "$BIN/npm" "$BIN/pnpm"

# --- 5. hq missing, npm missing -> manual-install remedy -----------------
reset_root
write_local_settings "{\"env\":{\"PATH\":\"/usr/bin:/bin\"}}"
rm -f "$BIN/hq" "$BIN/npm" "$BIN/pnpm"
out="$(run_hook "$COREUTILS_PATH")"
printf '%s' "$out" | grep -q '<hq-cli-missing>' \
  || fail "npm missing should emit <hq-cli-missing>, got: $out"

# --- 6. cooldown: fresh stamp -> no reinstall, still surfaces remedy ------
reset_root
write_local_settings "{\"env\":{\"PATH\":\"/usr/bin:/bin\"}}"
mkdir -p "$ROOTDIR/workspace/.hq-cli-ensure"
: > "$ROOTDIR/workspace/.hq-cli-ensure/last-attempt.stamp"
stub npm "case \"\$*\" in
  *install*) echo 'INSTALL_RAN' >&2; exit 1 ;;
  'prefix -g') echo '$TMP/noprefix'; exit 0 ;;
  *) exit 0 ;;
esac"
out="$(run_hook "$COREUTILS_PATH" 2> "$TMP/stderr")"
grep -q 'INSTALL_RAN' "$TMP/stderr" && fail "cooldown active must NOT re-run install"
printf '%s' "$out" | grep -q '<hq-cli-missing>' \
  || fail "cooldown active + hq missing should still emit remedy, got: $out"
rm -f "$BIN/npm" "$BIN/pnpm"

# --- 7. hq off-PATH but settings dir unwritable -> add-to-PATH remedy -----
# jq can READ the settings PATH (so we reach the auto-fix branch), but the
# .claude dir is read-only so the write fails -> the hook must advise instead.
reset_root
write_local_settings "{\"env\":{\"PATH\":\"/usr/bin:/bin\"}}"
stub hq 'echo 5.108.2'
chmod 0500 "$ROOTDIR/.claude"
out="$(run_hook "$COREUTILS_PATH")"
chmod 0700 "$ROOTDIR/.claude"   # restore so the trap can clean up
printf '%s' "$out" | grep -q '<hq-cli-not-on-path>' \
  || fail "unwritable settings should emit <hq-cli-not-on-path>, got: $out"
rm -f "$BIN/hq"

# --- 8. kill switches -> silent ------------------------------------------
reset_root
write_local_settings "{\"env\":{\"PATH\":\"/usr/bin:/bin\"}}"
out="$(run_hook "$COREUTILS_PATH" HQ_NO_ENSURE_HQ_CLI=1)"
[ -z "$out" ] || fail "HQ_NO_ENSURE_HQ_CLI=1 should be silent, got: $out"
out="$(run_hook "$COREUTILS_PATH" HQ_DISABLED_HOOKS='foo,ensure-hq-cli,bar')"
[ -z "$out" ] || fail "HQ_DISABLED_HOOKS should be silent, got: $out"

# --- 8b. floor advisory: 5.108.2 ok; 5.108.1 repairs, always exit 0 ------
# Floor is the shipped release 5.108.2. At-floor hq is a silent no-op.
# One patch below (5.108.1) is treated as missing: cooldown-limited install
# attempt, then still exit 0 (advisory — never blocks the prompt).
reset_root
stub hq 'echo 5.108.2'
write_local_settings "{\"env\":{\"PATH\":\"$BIN:/usr/bin\"}}"
set +e
out="$(run_hook "$COREUTILS_PATH")"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "5.108.2 on PATH must exit 0, got rc=$rc"
[ -z "$out" ] || fail "5.108.2 on settings PATH should be silent, got: $out"
rm -f "$BIN/hq"

reset_root
BELOW_BIN="$TMP/below-floor-bin"; mkdir -p "$BELOW_BIN"
printf '#!/usr/bin/env bash\necho 5.108.1\n' > "$BELOW_BIN/hq"
chmod +x "$BELOW_BIN/hq"
rm -f "$TMP/prefix/bin/hq" "$TMP/below-floor-install"
mkdir -p "$TMP/prefix/bin"
write_local_settings "{\"env\":{\"PATH\":\"$BELOW_BIN:/usr/bin:/bin\"}}"
stub npm "case \"\$*\" in
  'prefix -g') echo '$TMP/prefix'; exit 0 ;;
  *) exit 0 ;;
esac"
stub pnpm "case \"\$*\" in
  *add*) printf '#!/usr/bin/env bash\\necho 5.108.2\\n' > '$TMP/prefix/bin/hq'; chmod +x '$TMP/prefix/bin/hq'; echo installed > '$TMP/below-floor-install'; exit 0 ;;
  'bin -g') echo '$TMP/prefix/bin'; exit 0 ;;
  *) exit 0 ;;
esac"
set +e
out="$(run_hook "$COREUTILS_PATH")"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "5.108.1 repair must exit 0 (advisory), got rc=$rc"
[ -f "$TMP/below-floor-install" ] || fail "5.108.1 must trigger cooldown-limited install"
printf '%s' "$out" | grep -q '<hq-cli-path-updated>' \
  || fail "5.108.1 repair should emit <hq-cli-path-updated>, got: $out"
rm -f "$BIN/npm" "$BIN/pnpm"

# --- 9. install stays bounded when `timeout` is absent (macOS) -----------
# Build a coreutils PATH WITHOUT `timeout`, so the hook takes the portable
# watchdog branch. A stalled 5s install with a 1s bound must return after the
# new 2s missing-hq re-probe plus bounded install work.
reset_root
write_local_settings "{\"env\":{\"PATH\":\"/usr/bin:/bin\"}}"
NOTIMEOUT="$TMP/notimeout"; mkdir -p "$NOTIMEOUT"
for u in bash sh cat stat date mkdir rm mv dirname chmod env grep head jq sleep kill pkill ps awk; do
  ln -sf "$CORE/$u" "$NOTIMEOUT/$u" 2>/dev/null || true
done
stub npm 'exit 0'   # npm present so the install branch is reached
start="$(date +%s)"
out="$(run_hook "$BIN:$NOTIMEOUT" \
  HQ_ENSURE_CLI_INSTALL_CMD='sleep 5' HQ_ENSURE_CLI_TIMEOUT=1)"
elapsed="$(( $(date +%s) - start ))"
[ "$elapsed" -lt 6 ] || fail "watchdog did not bound the install (took ${elapsed}s, expected under 6s including the re-probe)"
printf '%s' "$out" | grep -q '<hq-cli-missing>' \
  || fail "bounded-but-failed install should emit remedy, got: $out"
rm -f "$BIN/npm"

# --- 10. concurrent install is locked out (atomic claim) -----------------
reset_root
write_local_settings "{\"env\":{\"PATH\":\"/usr/bin:/bin\"}}"
mkdir -p "$ROOTDIR/workspace/.hq-cli-ensure/installing.lock"   # a peer holds it
stub pnpm "case \"\$*\" in
  *add*) echo 'INSTALL_RAN' > '$TMP/lock-marker'; exit 0 ;;
  *) exit 0 ;;
esac"
out="$(run_hook "$COREUTILS_PATH")"
[ ! -f "$TMP/lock-marker" ] || fail "install ran despite a held lock (concurrent race)"
printf '%s' "$out" | grep -q '<hq-cli-missing>' \
  || fail "locked-out session should still emit remedy, got: $out"
rm -f "$BIN/pnpm"

# --- 11. truly missing hq still restores through pnpm ------------------------
reset_root
write_local_settings "{\"env\":{\"PATH\":\"/usr/bin:/bin\"}}"
mkdir -p "$TMP/pnpm-prefix/bin"
rm -f "$TMP/prefix/bin/hq" "$TMP/pnpm-prefix/bin/hq" "$TMP/pnpm-ran" "$TMP/npm-ran"
stub pnpm "case \"\$*\" in
  *add*) printf '#!/usr/bin/env bash\\necho 5.108.2\\n' > '$TMP/pnpm-prefix/bin/hq'; chmod +x '$TMP/pnpm-prefix/bin/hq'; echo ran > '$TMP/pnpm-ran'; exit 0 ;;
  'bin -g') echo '$TMP/pnpm-prefix/bin'; exit 0 ;;
  *) exit 0 ;;
esac"
stub npm "case \"\$*\" in
  *install*) echo ran > '$TMP/npm-ran'; exit 0 ;;
  'prefix -g') echo '$TMP/prefix'; exit 0 ;;
  *) exit 0 ;;
esac"
out="$(run_hook "$COREUTILS_PATH")"
[ -f "$TMP/pnpm-ran" ] || fail "pnpm present must drive CLI restore, got: $out"
[ ! -f "$TMP/npm-ran" ] || fail "pnpm present must not fall back to npm"
printf '%s' "$out" | grep -q '<hq-cli-path-updated>' \
  || fail "pnpm restore should emit <hq-cli-path-updated>, got: $out"
case ":$(local_path):" in *":$TMP/pnpm-prefix/bin:"*) : ;; *) fail "pnpm restore did not add pnpm bin to env.PATH: $(local_path)";; esac
printf '%s\n' 'PASS: truly missing hq still restores through pnpm'
rm -f "$BIN/pnpm" "$BIN/npm"

# --- 12. a timed-out hq probe is unknown, not proof it needs reinstalling ---
reset_root
TIMEOUT_BIN="$TMP/timeout-hq-bin"; mkdir -p "$TIMEOUT_BIN" "$TMP/pnpm-empty/bin"
printf '#!/usr/bin/env bash\nsleep 5\necho 5.108.2\n' > "$TIMEOUT_BIN/hq"
chmod +x "$TIMEOUT_BIN/hq"
write_local_settings "{\"env\":{\"PATH\":\"$TIMEOUT_BIN:/usr/bin:/bin\"}}"
rm -f "$TMP/timeout-install-ran"
stub pnpm "case \"\$*\" in
  *add*) echo ran > '$TMP/timeout-install-ran'; exit 0 ;;
  'bin -g') echo '$TMP/pnpm-empty/bin'; exit 0 ;;
  *) exit 0 ;;
esac"
start="$(date +%s)"
out="$(run_hook "$TIMEOUT_BIN:$COREUTILS_PATH" HQ_ENSURE_CLI_VERSION_TIMEOUT=1)"
elapsed="$(( $(date +%s) - start ))"
[ "$elapsed" -lt 4 ] || fail "timed-out hq probe took too long (${elapsed}s)"
[ ! -f "$TMP/timeout-install-ran" ] \
  || fail "a timed-out hq version probe must not trigger an install"
[ -z "$out" ] || fail "a timed-out hq probe should remain silent, got: $out"
rm -f "$BIN/pnpm"
printf '%s\n' 'PASS: timeout does not trigger install'

# --- 13. a live npm install owns the missing-package window ---------------
reset_root
write_local_settings "{\"env\":{\"PATH\":\"/usr/bin:/bin\"}}"
mkdir -p "$TMP/prefix/bin" "$TMP/pnpm-prefix/bin"
rm -f "$TMP/prefix/bin/hq" "$TMP/pnpm-prefix/bin/hq"
rm -f "$TMP/active-install-ran" "$TMP/active-pnpm-ran"
stub npm "case \"\$*\" in
  *'@indigoai-us/hq-cli@5.223.0'*)
    sleep 30 &
    child=\$!
    trap 'kill \"\$child\" 2>/dev/null || true; wait \"\$child\" 2>/dev/null || true; exit 0' TERM INT
    wait \"\$child\" ;;
  *install*) echo ran > '$TMP/active-install-ran'; exit 0 ;;
  'prefix -g'|'config get prefix') echo '$TMP/prefix'; exit 0 ;;
  *) exit 0 ;;
esac"
stub pnpm "case \"\$*\" in
  *add*) echo ran > '$TMP/active-pnpm-ran'; exit 0 ;;
  'bin -g') echo '$TMP/pnpm-prefix/bin'; exit 0 ;;
  'root -g') echo '$TMP/pnpm-prefix/global/5/node_modules'; exit 0 ;;
  *) exit 0 ;;
esac"
"$BIN/npm" install -g @indigoai-us/hq-cli@5.223.0 &
installer_pid=$!
sleep 0.2
processes="$(ps -eww -o args= 2>/dev/null)"
case "$processes" in
  *"@indigoai-us/hq-cli@5.223.0"*) : ;;
  *) kill "$installer_pid" 2>/dev/null || true; wait "$installer_pid" 2>/dev/null || true; fail "installer process ignored: fake npm install was not visible to ps" ;;
esac
out="$(run_hook "$COREUTILS_PATH")"
kill "$installer_pid" 2>/dev/null || true
wait "$installer_pid" 2>/dev/null || true
[ ! -f "$TMP/active-install-ran" ] || fail "installer process ignored: hook started a second npm install"
[ ! -f "$TMP/active-pnpm-ran" ] || fail "installer process ignored: hook started pnpm during npm install"
case "$out" in *'<hq-cli-install-in-progress>'*) : ;; *) fail "installer process ignored: expected a named deferred-install message, got: $out";; esac
printf '%s\n' 'PASS: installer process ignored'
rm -f "$BIN/npm" "$BIN/pnpm"

# --- 14. npm staging directory is also an active install window -----------
reset_root
write_local_settings "{\"env\":{\"PATH\":\"/usr/bin:/bin\"}}"
mkdir -p "$TMP/prefix/lib/node_modules/.hq-cli-staging-123" "$TMP/pnpm-prefix/bin"
rm -f "$TMP/prefix/bin/hq" "$TMP/pnpm-prefix/bin/hq"
rm -f "$TMP/staging-npm-ran" "$TMP/staging-pnpm-ran"
stub npm "case \"\$*\" in
  *install*) echo ran > '$TMP/staging-npm-ran'; exit 0 ;;
  'prefix -g'|'config get prefix') echo '$TMP/prefix'; exit 0 ;;
  *) exit 0 ;;
esac"
stub pnpm "case \"\$*\" in
  *add*) echo ran > '$TMP/staging-pnpm-ran'; exit 0 ;;
  'bin -g') echo '$TMP/pnpm-prefix/bin'; exit 0 ;;
  'root -g') echo '$TMP/pnpm-prefix/global/5/node_modules'; exit 0 ;;
  *) exit 0 ;;
esac"
out="$(run_hook "$COREUTILS_PATH")"
[ ! -f "$TMP/staging-npm-ran" ] || fail "npm staging dir ignored: hook started npm while staging exists"
[ ! -f "$TMP/staging-pnpm-ran" ] || fail "npm staging dir ignored: hook started pnpm while staging exists"
case "$out" in *'<hq-cli-install-in-progress>'*) : ;; *) fail "npm staging dir ignored: expected a named deferred-install message, got: $out";; esac
printf '%s\n' 'PASS: npm staging dir ignored'
rm -f "$BIN/npm" "$BIN/pnpm"
rmdir "$TMP/prefix/lib/node_modules/.hq-cli-staging-123"

# --- 15. an hq binary that reappears during the wait avoids restore --------
reset_root
write_local_settings "{\"env\":{\"PATH\":\"/usr/bin:/bin\"}}"
mkdir -p "$TMP/prefix/bin" "$TMP/pnpm-prefix/bin"
rm -f "$TMP/prefix/bin/hq" "$TMP/pnpm-prefix/bin/hq"
rm -f "$TMP/reprobe-count" "$TMP/reprobe-install-ran"
stub npm "case \"\$*\" in
  'prefix -g'|'config get prefix') echo '$TMP/prefix'; exit 0 ;;
  *install*) echo ran > '$TMP/reprobe-install-ran'; exit 0 ;;
  *) exit 0 ;;
esac"
stub pnpm "case \"\$*\" in
  'bin -g')
    if [ ! -f '$TMP/reprobe-start' ]; then date +%s > '$TMP/reprobe-start'; fi
    started=\$(cat '$TMP/reprobe-start')
    now=\$(date +%s)
    if [ \"\$now\" -gt \"\$started\" ]; then printf '#!/usr/bin/env bash\\necho 5.108.2\\n' > '$TMP/pnpm-prefix/bin/hq'; chmod +x '$TMP/pnpm-prefix/bin/hq'; fi
    echo '$TMP/pnpm-prefix/bin'; exit 0 ;;
  *add*) echo ran > '$TMP/reprobe-install-ran'; exit 0 ;;
  'root -g') echo '$TMP/pnpm-prefix/global/5/node_modules'; exit 0 ;;
  *) exit 0 ;;
esac"
start="$(date +%s)"
out="$(run_hook "$COREUTILS_PATH")"
elapsed="$(( $(date +%s) - start ))"
[ "$elapsed" -le 5 ] || fail "no re-probe: wait exceeded 5s (elapsed ${elapsed}s)"
[ -x "$TMP/pnpm-prefix/bin/hq" ] || fail "no re-probe: test hq did not reappear"
[ ! -f "$TMP/reprobe-install-ran" ] || fail "no re-probe: restore ran after hq reappeared"
case ":$(local_path):" in *":$TMP/pnpm-prefix/bin:"*) : ;; *) fail "no re-probe: restored hq path was not added after it reappeared";; esac
printf '%s\n' 'PASS: hq reappears within the re-probe wait'
rm -f "$BIN/npm" "$BIN/pnpm"

# --- 16. npm-global ownership wins over pnpm for restore ------------------
reset_root
write_local_settings "{\"env\":{\"PATH\":\"/usr/bin:/bin\"}}"
mkdir -p "$TMP/prefix/lib/node_modules/@indigoai-us/hq-cli" "$TMP/prefix/bin" "$TMP/pnpm-prefix/bin"
printf '{"version":"5.223.0"}\n' > "$TMP/prefix/lib/node_modules/@indigoai-us/hq-cli/package.json"
rm -f "$TMP/prefix/bin/hq" "$TMP/pnpm-prefix/bin/hq"
rm -f "$TMP/npm-owner-ran" "$TMP/pnpm-owner-ran"
stub npm "case \"\$*\" in
  *install*) echo \"\$*\" > '$TMP/npm-owner-ran'; printf '#!/usr/bin/env bash\\necho 5.108.2\\n' > '$TMP/prefix/bin/hq'; chmod +x '$TMP/prefix/bin/hq'; exit 0 ;;
  'prefix -g') echo '$TMP/prefix'; exit 0 ;;
  *) exit 0 ;;
esac"
stub pnpm "case \"\$*\" in
  *add*) echo ran > '$TMP/pnpm-owner-ran'; exit 0 ;;
  'bin -g') echo '$TMP/pnpm-prefix/bin'; exit 0 ;;
  'root -g') echo '$TMP/pnpm-prefix/global/5/node_modules'; exit 0 ;;
  *) exit 0 ;;
esac"
out="$(run_hook "$COREUTILS_PATH")"
[ -f "$TMP/npm-owner-ran" ] || fail "restore prefers pnpm over npm owner: npm-owned package was not restored by npm, got: $out"
grep -Fxq 'install -g @indigoai-us/hq-cli@5.223.0' "$TMP/npm-owner-ran" \
  || fail "npm restore did not pin the version from npm's installed package"
[ ! -f "$TMP/pnpm-owner-ran" ] || fail "restore prefers pnpm over npm owner: pnpm ran despite npm ownership"
printf '%s\n' 'PASS: npm-global restore is pinned to the installed package version'
rm -f "$BIN/npm" "$BIN/pnpm"

# --- 16b. unreadable npm owner version falls back to age-gated pnpm --------
reset_root
write_local_settings "{\"env\":{\"PATH\":\"/usr/bin:/bin\"}}"
mkdir -p "$TMP/prefix/lib/node_modules/@indigoai-us/hq-cli" "$TMP/prefix/bin" "$TMP/pnpm-prefix/bin"
printf '{"name":"@indigoai-us/hq-cli"}\n' > "$TMP/prefix/lib/node_modules/@indigoai-us/hq-cli/package.json"
rm -f "$TMP/prefix/bin/hq" "$TMP/pnpm-fallback-ran" "$TMP/npm-fallback-ran"
stub npm "case \"\$*\" in
  *install*) echo ran > '$TMP/npm-fallback-ran'; exit 0 ;;
  'prefix -g') echo '$TMP/prefix'; exit 0 ;;
  *) exit 0 ;;
esac"
stub pnpm "case \"\$*\" in
  *add*) echo \"\$*\" > '$TMP/pnpm-fallback-ran'; printf '#!/usr/bin/env bash\\necho 5.108.2\\n' > '$TMP/pnpm-prefix/bin/hq'; chmod +x '$TMP/pnpm-prefix/bin/hq'; exit 0 ;;
  'bin -g') echo '$TMP/pnpm-prefix/bin'; exit 0 ;;
  *) exit 0 ;;
esac"
out="$(run_hook "$COREUTILS_PATH" 2> "$TMP/fallback-stderr")"
[ -f "$TMP/pnpm-fallback-ran" ] || fail "unreadable npm version did not fall back to pnpm, got: $out"
grep -Fq 'minimumReleaseAge=1440' "$TMP/pnpm-fallback-ran" \
  || fail "npm version fallback did not retain pnpm minimumReleaseAge"
[ ! -f "$TMP/npm-fallback-ran" ] || fail "unreadable npm version must not use an unpinned npm restore"
grep -Fq 'exact version could not be read' "$TMP/fallback-stderr" \
  || fail "npm version fallback did not log why it used pnpm"
printf '%s\n' 'PASS: unreadable npm owner version falls back to logged age-gated pnpm'
rm -f "$BIN/npm" "$BIN/pnpm"

# --- 17. auto-fix places npm-global hq before pnpm hq ----------------------
reset_root
write_local_settings "{\"env\":{\"PATH\":\"/usr/bin:/bin\"}}"
mkdir -p "$TMP/prefix/bin" "$TMP/pnpm-prefix/bin"
rm -f "$TMP/prefix/bin/hq" "$TMP/pnpm-prefix/bin/hq"
printf '#!/usr/bin/env bash\necho 5.108.2\n' > "$TMP/prefix/bin/hq"
printf '#!/usr/bin/env bash\necho 5.108.2\n' > "$TMP/pnpm-prefix/bin/hq"
chmod +x "$TMP/prefix/bin/hq" "$TMP/pnpm-prefix/bin/hq"
stub npm "case \"\$*\" in
  'prefix -g'|'config get prefix') echo '$TMP/prefix'; exit 0 ;;
  *) exit 0 ;;
esac"
stub pnpm "case \"\$*\" in
  'bin -g') echo '$TMP/pnpm-prefix/bin'; exit 0 ;;
  'root -g') echo '$TMP/pnpm-prefix/global/5/node_modules'; exit 0 ;;
  *) exit 0 ;;
esac"
out="$(run_hook "$TMP/pnpm-prefix/bin:$COREUTILS_PATH")"
case "$(local_path)" in "$TMP/prefix/bin:"*) : ;; *) fail "pnpm prepended to PATH: auto-fix did not place npm-global hq first: $(local_path)";; esac
case "$(local_path)" in *"$TMP/pnpm-prefix/bin:"*) fail "pnpm prepended to PATH: pnpm precedes npm-global in settings";; esac
printf '%s\n' 'PASS: PATH auto-fix keeps npm-global hq first'
rm -f "$BIN/npm" "$BIN/pnpm"

# --- 18. documented restores include the pnpm age-gated fallback ------------
grep -F 'pnpm add -g @indigoai-us/hq-cli@latest --config.minimumReleaseAge=1440' "$HOOK" >/dev/null \
  || fail "ensure-hq-cli must document pnpm restore with minimumReleaseAge=1440"
if grep -E 'npm install -g @indigoai-us/hq-cli@latest' "$HOOK" | grep -v 'NPM_RESTORE_CMD=' | grep -v 'Do not run' >/dev/null; then
  fail "ensure-hq-cli still advertises npm @latest as the restore command"
fi

# --- 19. reuse HQ Desktop's managed toolchain before a global restore --------
reset_root
write_local_settings '{"env":{"PATH":"/usr/bin:/bin"}}'
DESKTOP_HQ_BIN="$TMP/home/Library/Application Support/Indigo HQ/toolchain/npm-global/bin"
mkdir -p "$DESKTOP_HQ_BIN"
printf '#!/usr/bin/env bash\necho 5.108.2\n' > "$DESKTOP_HQ_BIN/hq"
chmod +x "$DESKTOP_HQ_BIN/hq"
rm -f "$TMP/desktop-restore-ran"
out="$(run_hook "$COREUTILS_PATH" HQ_ENSURE_CLI_COOLDOWN=0 HQ_ENSURE_CLI_INSTALL_CMD="echo ran > '$TMP/desktop-restore-ran'")"
case "$(local_path)" in "$DESKTOP_HQ_BIN:"*) : ;; *) fail "desktop-managed hq was not added to settings PATH: $(local_path); output: $out";; esac
[ ! -f "$TMP/desktop-restore-ran" ] || fail "global restore ran despite desktop-managed hq existing"
printf '%s\n' 'PASS: desktop-managed hq is reused before global restore'

if [ "${HQ_TEST_SKIP_DESKTOP_NODE_CASE:-0}" != 1 ]; then
# --- 20. managed Node runs the Desktop npm shim and is persisted on PATH ---
reset_root
write_local_settings '{"env":{"PATH":"/usr/bin:/bin"}}'
DESKTOP_NODE_BIN="$TMP/home/Library/Application Support/Indigo HQ/toolchain/node/bin"
DESKTOP_HQ_BIN="$TMP/home/Library/Application Support/Indigo HQ/toolchain/npm-global/bin"
mkdir -p "$DESKTOP_NODE_BIN" "$DESKTOP_HQ_BIN"
printf '#!/usr/bin/env bash\nprintf \"5.108.2\\n\"\n' > "$DESKTOP_NODE_BIN/node"
printf '#!/usr/bin/env node\n' > "$DESKTOP_HQ_BIN/hq"
chmod +x "$DESKTOP_NODE_BIN/node" "$DESKTOP_HQ_BIN/hq"
rm -f "$TMP/desktop-node-restore-ran"
out="$(run_hook "$COREUTILS_PATH" HQ_ENSURE_CLI_COOLDOWN=0 HQ_ENSURE_CLI_INSTALL_CMD="echo ran > '$TMP/desktop-node-restore-ran'")"
case "$(local_path)" in "$DESKTOP_NODE_BIN:$DESKTOP_HQ_BIN:"*) : ;; *) fail "Desktop managed Node and hq were not prepended in order: $(local_path); output: $out";; esac
[ ! -f "$TMP/desktop-node-restore-ran" ] || fail "global restore ran despite managed Node and Desktop hq existing"
out="$(run_hook "$(local_path)")"
[ -z "$out" ] || fail "Desktop hq shim should resolve silently after both paths persist, got: $out"
printf '%s\n' 'PASS: Desktop managed Node runs the CLI shim and is persisted before npm-global'

fi

if [ "${HQ_TEST_SKIP_WINDOWS_DESKTOP_CASE:-0}" != 1 ]; then
# --- 21. Windows desktop paths stay Windows-form across repeated prompts ---
reset_root
rm -rf "$TMP/home/Library/Application Support/Indigo HQ/toolchain"
WINDOWS_LOCAL_ROOT="$TMP/windows-local-appdata"
WINDOWS_LOCAL_HQ_BIN="$WINDOWS_LOCAL_ROOT/IndigoHQ/toolchain/npm-global/bin"
mkdir -p "$WINDOWS_LOCAL_HQ_BIN" "$TMP/windows-system32"
printf '#!/usr/bin/env bash\necho 5.108.2\n' > "$WINDOWS_LOCAL_HQ_BIN/hq"
chmod +x "$WINDOWS_LOCAL_HQ_BIN/hq"
stub cygpath "case \"\$1:\${2:-}\" in
  -u:-p) case \"\$3\" in *IndigoHQ/toolchain/npm-global/bin*) printf '%s\\n' '$WINDOWS_LOCAL_HQ_BIN:$TMP/windows-system32' ;; *) printf '%s\\n' '$TMP/windows-system32' ;; esac ;;
  -u:*) printf '%s\\n' '$WINDOWS_LOCAL_ROOT' ;;
  -m:*) printf '%s\\n' 'C:/Users/HqTest/AppData/Local/IndigoHQ/toolchain/npm-global/bin' ;;
  *) exit 1 ;;
esac"
write_local_settings '{"env":{"PATH":"C:\\Users\\HqTest\\.hq-cli\\node_modules\\.bin;C:\\Windows\\System32"}}'
run_hook "$COREUTILS_PATH" LOCALAPPDATA='C:\Users\HqTest\AppData\Local' >/dev/null
expected_windows_hq='C:/Users/HqTest/AppData/Local/IndigoHQ/toolchain/npm-global/bin'
[ "$(local_path)" = "$expected_windows_hq;C:\Users\HqTest\.hq-cli\node_modules\.bin;C:\Windows\System32" ] \
  || fail "Windows desktop candidate did not preserve the semicolon-delimited path: $(local_path)"
out="$(run_hook "$COREUTILS_PATH" LOCALAPPDATA='C:\Users\HqTest\AppData\Local')"
[ -z "$out" ] || fail "second Windows prompt did not resolve the preserved candidate silently: $out"
printf '%s\n' 'PASS: Windows desktop path remains semicolon-delimited on repeated prompts'
rm -f "$BIN/cygpath"

fi

# --- 22. APPDATA and npm-global/bin legacy layout is discovered ------------
reset_root
rm -rf "$TMP/home/Library/Application Support/Indigo HQ/toolchain"
write_local_settings '{"env":{"PATH":"/usr/bin:/bin"}}'
APPDATA_HQ_BIN="$TMP/windows-roaming-appdata/Indigo HQ/toolchain/npm-global/bin"
mkdir -p "$APPDATA_HQ_BIN"
printf '#!/usr/bin/env bash\necho 5.108.2\n' > "$APPDATA_HQ_BIN/hq"
chmod +x "$APPDATA_HQ_BIN/hq"
rm -f "$TMP/appdata-restore-ran"
out="$(run_hook "$COREUTILS_PATH" APPDATA="$TMP/windows-roaming-appdata" HQ_ENSURE_CLI_COOLDOWN=0 HQ_ENSURE_CLI_INSTALL_CMD="echo ran > '$TMP/appdata-restore-ran'")"
case ":$(local_path):" in *":$APPDATA_HQ_BIN:"*) : ;; *) fail "APPDATA npm-global/bin candidate was not added: $(local_path); output: $out";; esac
[ ! -f "$TMP/appdata-restore-ran" ] || fail "global restore ran despite the APPDATA managed CLI existing"
printf '%s\n' 'PASS: APPDATA Indigo HQ npm-global/bin candidate is reused'

echo "PASS: ensure-hq-cli-hook (settings-PATH detection, ambient fallback, auto-fix local settings, install+fix, npm-missing, cooldown, unwritable remedy, kill-switch, floor-advisory 5.108.1/5.108.2, bounded-install, atomic-lock, install-window guards, re-probe, npm owner restore, npm-first PATH, desktop toolchain reuse)"

# Prompt-contract coverage lives in a sibling file; run it here so CI picks it
# up without a workflow-permission edit.
bash "$ROOT/core/scripts/tests/hq-heal-cli-restore.test.sh"
