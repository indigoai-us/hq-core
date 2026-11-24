#!/usr/bin/env bash
# Perl launch budget for master-hook on a stock Mac (feedback_0f247c64).
#
# A stock Mac runs hooks with Bash 3.2 (no EPOCHREALTIME) and has no coreutils
# `timeout`. master-hook used to read its millisecond clock with
# `perl -MTime::HiRes` twice per child and wrap every child in a perl timeout
# runner: about 26 perl launches per PreToolUse and 86 per SessionStart, over
# a thousand a minute with several sessions open. A reporter linked that
# launch rate to repeated macOS watchdog panics.
#
# This test runs a real SessionStart dispatch with the legacy clock forced
# (BASH_ENV unsets EPOCHREALTIME and EPOCHSECONDS) and checks:
#   1. master-hook starts no clock perl at all;
#   2. with no GNU timeout on PATH, perl starts at most once per child (the
#      process-group timeout runner);
#   3. with Homebrew's `gtimeout` on PATH and no `timeout`, no perl starts;
#   4. every child still gets a journal row with an elapsed time.
# Portable: macOS and Linux, no strace.
set -euo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# HQ_TEST_BASH_BIN=/bin/bash runs the dispatch under stock macOS Bash 3.2.
BASH_BIN="${HQ_TEST_BASH_BIN:-$(type -P bash || true)}"
PERL_BIN="$(type -P perl || true)"
PS_BIN="$(type -P ps || true)"
GNU_TIMEOUT="$(type -P timeout || type -P gtimeout || true)"
[ -n "$BASH_BIN" ] || { echo 'FAIL: bash is required' >&2; exit 1; }
[ -n "$PERL_BIN" ] || { echo 'SKIP: perl is not installed; nothing to count' >&2; exit 0; }
[ -n "$PS_BIN" ] || { echo 'FAIL: ps is required' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo 'FAIL: jq is required' >&2; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A PATH directory holding every command on the current PATH except timeout
# and gtimeout (first match wins, as in a PATH lookup), so the dispatch sees a
# stock Mac's toolset on any host.
STOCK="$TMP/stock-bin"
mkdir -p "$STOCK"
IFS=: read -r -a path_dirs <<< "$PATH"
for dir in "${path_dirs[@]}"; do
  [ -d "$dir" ] || continue
  for tool in "$dir"/*; do
    name="${tool##*/}"
    case "$name" in timeout|gtimeout|perl) continue ;; esac
    [ -x "$tool" ] && [ ! -d "$tool" ] || continue
    [ -e "$STOCK/$name" ] || ln -s "$tool" "$STOCK/$name"
  done
done
# Counting perl: records its arguments and its parent's command line.
cat > "$STOCK/perl" <<SHIM
#!/bin/sh
printf '%s\t%s\n' "\$(printf '%s ' "\$@" | tr '\n' ' ' | cut -c1-160)" "\$("$PS_BIN" -o command= -p "\$PPID" 2>/dev/null | cut -c1-200)" >> "\${HQ_TEST_PERL_LOG:?}"
exec "$PERL_BIN" "\$@"
SHIM
chmod +x "$STOCK/perl"
if env PATH="$STOCK" "$BASH_BIN" -c 'command -v timeout || command -v gtimeout' >/dev/null 2>&1; then
  fail 'the stock PATH still has a timeout command'
fi

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

# dispatch <name> <children> <extra-path-dir-or-empty>: one SessionStart.
dispatch() {
  local name="$1" children="$2" extra="$3" root log payload rc path
  root="$TMP/hq-$name"
  log="$TMP/perl-$name.log"
  make_fixture "$root" "$children"
  : > "$log"
  path="$STOCK"
  [ -z "$extra" ] || path="$extra:$STOCK"
  payload="$(jq -cn --arg cwd "$root" '{session_id:"stock-mac-perl-budget",hook_event_name:"SessionStart",source:"startup",cwd:$cwd}')"
  set +e
  ( cd "$root" && env -i HOME="$TMP/home" PATH="$path" BASH_ENV="$root/legacy-clock.sh" \
      HQ_TEST_PERL_LOG="$log" HQ_HOOK_ENGINE=off HQ_HOOK_TIMEOUT_MASTER_ABSOLUTE_SECONDS=600 \
      "$BASH_BIN" "$root/.claude/hooks/master-hook.sh" SessionStart <<<"$payload" \
      > "$TMP/out-$name.txt" 2> "$TMP/err-$name.txt" )
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { cat "$TMP/err-$name.txt" >&2; fail "master-hook exited $rc ($name)"; }
}

# Perl launches whose parent is master-hook (clock reads and timeout runners).
master_perls() { awk -F '\t' '$2 ~ /master-hook\.sh/ { n++ } END { print n + 0 }' "$1"; }
clock_perls() { awk -F '\t' '$2 ~ /master-hook\.sh/ && $1 ~ /Time::HiRes/ { n++ } END { print n + 0 }' "$1"; }

printf 'unset EPOCHREALTIME EPOCHSECONDS\n' > "$TMP/probe.sh"
legacy_probe="$(env BASH_ENV="$TMP/probe.sh" "$BASH_BIN" -c 'printf "%s" "${EPOCHREALTIME:-unset}"')"
[ "$legacy_probe" = unset ] || fail "BASH_ENV did not remove EPOCHREALTIME (got $legacy_probe)"

dispatch few 3 ""
dispatch many 11 ""
few_log="$TMP/perl-few.log"
many_log="$TMP/perl-many.log"
echo "perl started by master-hook, no GNU timeout: 3 children=$(master_perls "$few_log"), 11 children=$(master_perls "$many_log")"

[ "$(master_perls "$many_log")" -gt 0 ] \
  || fail 'no perl runner was recorded; the counting shim did not see master-hook'
clocks="$(clock_perls "$many_log")"
[ "$clocks" -eq 0 ] || { grep 'Time::HiRes' "$many_log" >&2 || true; \
  fail "master-hook started $clocks clock perls for 11 children (limit 0; base was about 2 per child)"; }
pass 'legacy-clock master-hook starts no clock perl'

grown=$(( $(master_perls "$many_log") - $(master_perls "$few_log") ))
[ "$grown" -le 8 ] \
  || fail "master-hook started $grown more perls for 8 more children (limit 8: one timeout runner per child; base was about 3 per child)"
pass "perl starts at most once per child without a GNU timeout ($grown for 8 more children)"

journal="$(find "$TMP/hq-many/workspace/.hook-timeout-journal" -name '*.tsv' -type f 2>/dev/null | head -1)"
[ -n "$journal" ] || fail 'no timeout journal was written'
rows="$(awk -F '\t' '$2 == "SessionStart" && $3 ~ /^[0-9]+$/ { n++ } END { print n + 0 }' "$journal")"
[ "$rows" -eq 11 ] || { cat "$journal" >&2; fail "expected 11 journal rows with an elapsed time, got $rows"; }
pass 'every child still has a journal row with an elapsed time'

if [ -n "$GNU_TIMEOUT" ] && "$GNU_TIMEOUT" --version 2>/dev/null | grep -q 'GNU coreutils'; then
  mkdir -p "$TMP/brew-bin"
  ln -s "$GNU_TIMEOUT" "$TMP/brew-bin/gtimeout"
  dispatch brew 11 "$TMP/brew-bin"
  brew_perls="$(master_perls "$TMP/perl-brew.log")"
  [ "$brew_perls" -eq 0 ] || { cat "$TMP/perl-brew.log" >&2; \
    fail "with gtimeout on PATH master-hook still started $brew_perls perls for 11 children (limit 0)"; }
  rows="$(awk -F '\t' '$2 == "SessionStart" && $3 ~ /^[0-9]+$/ { n++ } END { print n + 0 }' \
    "$(find "$TMP/hq-brew/workspace/.hook-timeout-journal" -name '*.tsv' -type f | head -1)")"
  [ "$rows" -eq 11 ] || fail "expected 11 journal rows under gtimeout, got $rows"
  pass 'with Homebrew gtimeout and no timeout, master-hook starts no perl'
else
  echo 'SKIP: no GNU coreutils timeout on this host for the gtimeout case'
fi
