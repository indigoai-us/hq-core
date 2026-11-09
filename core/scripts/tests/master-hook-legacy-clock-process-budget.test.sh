#!/usr/bin/env bash
# Clock-read process budget for master-hook on a shell without EPOCHREALTIME
# (feedback_25b10339, feedback_33222c70).
#
# Bash 3.2, the system Bash on macOS and the one a desktop host usually runs
# hooks with, has no EPOCHREALTIME or EPOCHSECONDS, and BSD date prints a
# literal "N" for %N. Every master-hook clock read used to start a `date` that
# could never give milliseconds, then a `perl`, and every debug phase boundary
# started another `date +%s`. That was about ten processes per dispatched
# child, half of all the processes an event started. On a Mac where each
# process start is slow (endpoint scanning, heavy load) it added minutes to
# SessionStart, UserPromptSubmit and PreToolUse.
#
# This test runs a real master-hook dispatch with the legacy clock forced
# (BASH_ENV unsets EPOCHREALTIME and EPOCHSECONDS, as on Bash 3.2), counts the
# `date` and clock `perl` processes that master-hook itself starts, and checks
# that the count does not grow by more than two per child: one millisecond read
# when the child starts and one when it ends. Portable: macOS and Linux, no
# strace.
set -euo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# HQ_TEST_BASH_BIN=/bin/bash runs the dispatch under stock macOS Bash 3.2.
BASH_BIN="${HQ_TEST_BASH_BIN:-$(type -P bash || true)}"
PERL_BIN="$(type -P perl || true)"
DATE_BIN="$(type -P date || true)"
PS_BIN="$(type -P ps || true)"
[ -n "$BASH_BIN" ] || { echo 'FAIL: bash is required' >&2; exit 1; }
[ -n "$PERL_BIN" ] || { echo 'SKIP: perl is not installed; the legacy clock has no millisecond source' >&2; exit 0; }
[ -n "$DATE_BIN" ] && [ -n "$PS_BIN" ] || { echo 'FAIL: date and ps are required' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo 'FAIL: jq is required' >&2; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SHIMS="$TMP/shims"
mkdir -p "$SHIMS"

# Each shim records its arguments and the command line of the process that
# started it, then runs the real tool. A `$(date ...)` in master-hook is a
# forked copy of master-hook, so its parent command line names master-hook.sh.
for tool in date perl; do
  real="$DATE_BIN"
  [ "$tool" = perl ] && real="$PERL_BIN"
  cat > "$SHIMS/$tool" <<SHIM
#!/bin/sh
printf '%s\t%s\n' "$tool \$*" "\$("$PS_BIN" -o command= -p "\$PPID" 2>/dev/null)" >> "\${HQ_TEST_CLOCK_LOG:?}"
exec "$real" "\$@"
SHIM
  chmod +x "$SHIMS/$tool"
done

make_fixture() {
  local root="$1" children="$2" i
  mkdir -p "$root/.claude/hooks" "$root/core/hooks/SessionStart" "$root/core/scripts/lib" "$root/workspace"
  for relative in \
    .claude/hooks/master-hook.sh \
    .claude/hooks/hook-timeout-probe.sh \
    .claude/hooks/hook-timeout-watchdog.sh \
    .claude/hooks/hook-gate.sh \
    core/scripts/resolve-hq-root.sh \
    core/scripts/lib/perl-child-locale.sh \
    core/scripts/lib/advisory-cap.sh; do
    [ -f "$ROOT/$relative" ] || continue
    cp "$ROOT/$relative" "$root/$relative"
  done
  chmod +x "$root/.claude/hooks/"*.sh
  cat > "$root/.claude/settings.json" <<'JSON'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash .claude/hooks/master-hook.sh SessionStart","timeout":300}]}]}}
JSON
  printf '{"hooks":{}}\n' > "$root/.claude/hooks/hook-registry.json"
  printf 'hqVersion: "16.0.0"\n' > "$root/core/core.yaml"
  for ((i = 1; i <= children; i++)); do
    printf '#!/bin/sh\nexit 0\n' > "$root/core/hooks/SessionStart/$((10 + i))-noop-$i.sh"
    chmod +x "$root/core/hooks/SessionStart/$((10 + i))-noop-$i.sh"
  done
  printf 'unset EPOCHREALTIME EPOCHSECONDS\n' > "$root/legacy-clock.sh"
}

# Prints the number of clock processes master-hook started for one SessionStart.
clock_reads() {
  local children="$1" root log payload rc
  root="$TMP/hq-$children"
  log="$TMP/clock-$children.log"
  make_fixture "$root" "$children"
  : > "$log"
  payload="$(jq -cn --arg cwd "$root" '{session_id:"legacy-clock-budget",hook_event_name:"SessionStart",source:"startup",cwd:$cwd}')"
  set +e
  ( cd "$root" && env BASH_ENV="$root/legacy-clock.sh" PATH="$SHIMS:$PATH" HOME="$TMP/home" \
      HQ_TEST_CLOCK_LOG="$log" HQ_HOOK_TIMEOUT_MASTER_ABSOLUTE_SECONDS=600 \
      "$BASH_BIN" "$root/.claude/hooks/master-hook.sh" SessionStart <<<"$payload" \
      > "$TMP/out-$children.txt" 2> "$TMP/err-$children.txt" )
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { cat "$TMP/err-$children.txt" >&2; fail "master-hook exited $rc with $children children"; }
  # Only master-hook's own clock reads: every date, and perl only when it
  # loads Time::HiRes (the per-child timeout runner is a different perl).
  awk -F '\t' '
    $2 ~ /master-hook\.sh/ && ($1 ~ /^date / || ($1 ~ /^perl / && $1 ~ /Time::HiRes/)) { n++ }
    END { print n + 0 }
  ' "$log"
}

# The fixture really ran with the legacy clock, or the budget proves nothing.
printf 'unset EPOCHREALTIME EPOCHSECONDS\n' > "$TMP/probe.sh"
legacy_probe="$(env BASH_ENV="$TMP/probe.sh" "$BASH_BIN" -c 'printf "%s" "${EPOCHREALTIME:-unset}"')"
[ "$legacy_probe" = unset ] || fail "BASH_ENV did not remove EPOCHREALTIME (got $legacy_probe)"

few="$(clock_reads 3)"
many="$(clock_reads 11)"
per_child=$(((many - few + 7) / 8))
echo "clock processes started by master-hook: 3 children=$few, 11 children=$many (about $per_child per child)"

[ "$few" -gt 0 ] || fail 'no clock reads were recorded; the shims did not see master-hook'
# Two reads per child (16 for 8 children) plus 4 for once-per-event `date +%s`
# reads whose count depends on timing (seen as 3 or 5 between identical runs).
# The base commit started 80 more for the same 8 children.
[ $((many - few)) -le 24 ] \
  || fail "master-hook started $((many - few)) more clock processes for 8 more children (limit 24: two per child plus up to 8 event-level reads; base is about 80)"
pass 'legacy-clock master-hook starts at most two clock processes per child'

# The fixed path still journals every child with a millisecond timing.
journal="$(find "$TMP/hq-11/workspace/.hook-timeout-journal" -name '*.tsv' -type f 2>/dev/null | head -1)"
[ -n "$journal" ] || fail 'no timeout journal was written'
rows="$(awk -F '\t' '$2 == "SessionStart" && $3 ~ /^[0-9]+$/ { n++ } END { print n + 0 }' "$journal")"
[ "$rows" -eq 11 ] || { cat "$journal" >&2; fail "expected 11 journal rows with an elapsed time, got $rows"; }
pass 'every child still has a journal row with an elapsed time'

# Twelve readings in a row of the fork-free epoch clock never run ahead of the
# real clock and stay within a second of it.
probe_root="$TMP/hq-3"
drift="$(env BASH_ENV="$probe_root/legacy-clock.sh" PATH="$PATH" "$BASH_BIN" -c '
  . "$1/.claude/hooks/hook-timeout-probe.sh"
  command -v hook_timeout_epoch_seconds >/dev/null 2>&1 || { echo missing; exit 0; }
  worst=0
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    hook_timeout_epoch_seconds || { echo failed; exit 0; }
    real="$(date +%s)"
    d=$((real - HOOK_TIMEOUT_EPOCH_SECONDS))
    [ "$d" -ge 0 ] || { echo "ahead:$d"; exit 0; }
    [ "$d" -le "$worst" ] || worst="$d"
    sleep 0.2
  done
  echo "$worst"
' _ "$probe_root")"
case "$drift" in
  0|1) pass "fork-free epoch seconds stay within one second of date +%s (worst lag ${drift}s)" ;;
  *) fail "fork-free epoch seconds drifted from date +%s: $drift" ;;
esac
