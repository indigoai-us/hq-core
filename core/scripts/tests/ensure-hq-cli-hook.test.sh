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
#   5. Emit the manual-install remedy when hq is missing and npm is absent.
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
for u in bash sh cat stat date mkdir rm mv dirname timeout chmod env grep jq sleep kill; do
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
local_path() { jq -r '.env.PATH // empty' "$ROOTDIR/.claude/settings.local.json" 2>/dev/null; }

run_hook() { # run_hook <PATH> [env assignments...]
  local runpath="$1"; shift
  env -i PATH="$runpath" HQ_ROOT="$ROOTDIR" HOME="$TMP/home" "$@" \
    "$BASH_BIN" "$HOOK" UserPromptSubmit </dev/null
}

COREUTILS_PATH="$BIN:$CORE"

# --- 1. hq resolves on the settings PATH -> silent -----------------------
reset_root
mkdir -p "$TMP/hqbin"; : > "$TMP/hqbin/hq"; chmod +x "$TMP/hqbin/hq"
write_local_settings "{\"env\":{\"PATH\":\"$TMP/hqbin:/usr/bin\"}}"
out="$(run_hook "$COREUTILS_PATH")"
[ -z "$out" ] || fail "hq on settings PATH should be silent, got: $out"

# --- 2. no settings PATH configured -> ambient fallback (silent) ---------
reset_root
write_local_settings '{}'
stub hq 'exit 0'
out="$(run_hook "$COREUTILS_PATH")"   # hq stub is on ambient PATH
[ -z "$out" ] || fail "ambient hq with no settings PATH should be silent, got: $out"
rm -f "$BIN/hq"

# --- 3. hq installed but OFF the settings PATH -> auto-fix local settings --
reset_root
# settings PATH deliberately excludes where hq lives; add an unrelated key.
write_local_settings "{\"env\":{\"PATH\":\"/usr/bin:/bin\",\"FOO\":\"bar\"},\"other\":1}"
stub hq 'exit 0'   # hq is on ambient PATH ($BIN) but not on the settings PATH
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
mkdir -p "$TMP/prefix/bin"
# npm stub: on install, drop hq into the global prefix bin (NOT on any PATH).
stub npm "case \"\$*\" in
  *install*) printf '#!/usr/bin/env bash\\nexit 0\\n' > '$TMP/prefix/bin/hq'; chmod +x '$TMP/prefix/bin/hq'; exit 0 ;;
  'config get prefix') echo '$TMP/prefix'; exit 0 ;;
  *) exit 0 ;;
esac"
out="$(run_hook "$COREUTILS_PATH")"
printf '%s' "$out" | grep -q '<hq-cli-path-updated>' \
  || fail "install+fix should emit <hq-cli-path-updated>, got: $out"
case ":$(local_path):" in *":$TMP/prefix/bin:"*) : ;; *) fail "install did not add global bin to env.PATH: $(local_path)";; esac
[ ! -f "$ROOTDIR/workspace/.hq-cli-ensure/last-attempt.stamp" ] \
  || fail "successful install must clear the stamp"

# --- 5. hq missing, npm missing -> manual-install remedy -----------------
reset_root
write_local_settings "{\"env\":{\"PATH\":\"/usr/bin:/bin\"}}"
rm -f "$BIN/hq" "$BIN/npm"
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
  'config get prefix') echo '$TMP/noprefix'; exit 0 ;;
  *) exit 0 ;;
esac"
out="$(run_hook "$COREUTILS_PATH" 2> "$TMP/stderr")"
grep -q 'INSTALL_RAN' "$TMP/stderr" && fail "cooldown active must NOT re-run install"
printf '%s' "$out" | grep -q '<hq-cli-missing>' \
  || fail "cooldown active + hq missing should still emit remedy, got: $out"
rm -f "$BIN/npm"

# --- 7. hq off-PATH but settings dir unwritable -> add-to-PATH remedy -----
# jq can READ the settings PATH (so we reach the auto-fix branch), but the
# .claude dir is read-only so the write fails -> the hook must advise instead.
reset_root
write_local_settings "{\"env\":{\"PATH\":\"/usr/bin:/bin\"}}"
stub hq 'exit 0'
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

# --- 9. install stays bounded when `timeout` is absent (macOS) -----------
# Build a coreutils PATH WITHOUT `timeout`, so the hook takes the portable
# watchdog branch. A stalled 5s install with a 1s bound must return in ~1s.
reset_root
write_local_settings "{\"env\":{\"PATH\":\"/usr/bin:/bin\"}}"
NOTIMEOUT="$TMP/notimeout"; mkdir -p "$NOTIMEOUT"
for u in bash sh cat stat date mkdir rm mv dirname chmod env grep jq sleep kill; do
  ln -sf "$CORE/$u" "$NOTIMEOUT/$u" 2>/dev/null || true
done
stub npm 'exit 0'   # npm present so the install branch is reached
start="$(date +%s)"
out="$(run_hook "$BIN:$NOTIMEOUT" \
  HQ_ENSURE_CLI_INSTALL_CMD='sleep 5' HQ_ENSURE_CLI_TIMEOUT=1)"
elapsed="$(( $(date +%s) - start ))"
[ "$elapsed" -lt 4 ] || fail "watchdog did not bound the install (took ${elapsed}s, expected ~1s)"
printf '%s' "$out" | grep -q '<hq-cli-missing>' \
  || fail "bounded-but-failed install should emit remedy, got: $out"
rm -f "$BIN/npm"

# --- 10. concurrent install is locked out (atomic claim) -----------------
reset_root
write_local_settings "{\"env\":{\"PATH\":\"/usr/bin:/bin\"}}"
mkdir -p "$ROOTDIR/workspace/.hq-cli-ensure/installing.lock"   # a peer holds it
stub npm "case \"\$*\" in
  *install*) echo 'INSTALL_RAN' > '$TMP/lock-marker'; exit 0 ;;
  *) exit 0 ;;
esac"
out="$(run_hook "$COREUTILS_PATH")"
[ ! -f "$TMP/lock-marker" ] || fail "install ran despite a held lock (concurrent race)"
printf '%s' "$out" | grep -q '<hq-cli-missing>' \
  || fail "locked-out session should still emit remedy, got: $out"
rm -f "$BIN/npm"

echo "PASS: ensure-hq-cli-hook (settings-PATH detection, ambient fallback, auto-fix local settings, install+fix, npm-missing, cooldown, unwritable remedy, kill-switch, bounded-install, atomic-lock)"
