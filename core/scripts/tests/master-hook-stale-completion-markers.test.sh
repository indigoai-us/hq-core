#!/usr/bin/env bash
# master-hook-stale-completion-markers.test.sh
#
# A master-hook that is killed before its end-of-dispatch cleanup leaves its
# <invocation>.<n>.done completion markers in
# workspace/.hook-timeout-completions. Nothing else removed them, so the
# directory grew without bound and every later hook event paid for each entry
# when it listed the directory.
#
# Cases, under each available bash (PATH bash and /bin/bash):
#   - a backlog of old markers is removed by the next run; a recent marker, a
#     file with another name and a subdirectory stay
#   - the stamp that rate-limits the sweep sits beside the directory, not in it
#   - a second run inside the interval does not sweep and starts no find and
#     no more than one date; interval 0 sweeps
#   - a stamp that is not a number, has a leading zero, or is in the future
#     does not stop the sweep, and prints nothing
#   - an old marker of the bridge fallback (<marker>.fb) is removed too
#   - the run that creates the marker directory writes the stamp and starts no
#     find for it
#   - a run that dispatches a child still returns the child's output, and its
#     own marker is gone afterwards
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MASTER="$ROOT/.claude/hooks/master-hook.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

[ -f "$MASTER" ] || fail "missing $MASTER"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v perl >/dev/null 2>&1 || fail "perl is required"
REAL_FIND="$(command -v find)" || fail "find is required"
REAL_DATE="$(command -v date)" || fail "date is required"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mh-stale-markers.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

BACKLOG=3000

# find and date wrappers that log each call, so a run's process starts for the
# sweep can be counted.
SHIM="$TMP/shim"
CALLS="$TMP/calls.log"
mkdir -p "$SHIM"
cat > "$SHIM/find" <<SH
#!/bin/sh
printf 'find %s\\n' "\$*" >> "$CALLS"
exec "$REAL_FIND" "\$@"
SH
cat > "$SHIM/date" <<SH
#!/bin/sh
printf 'date %s\\n' "\$*" >> "$CALLS"
exec "$REAL_DATE" "\$@"
SH
chmod +x "$SHIM/find" "$SHIM/date"
sweep_finds() { grep -c '^find .*hook-timeout-completions.*-mmin' "$CALLS" 2>/dev/null || true; }
date_calls() { grep -c '^date ' "$CALLS" 2>/dev/null || true; }

# age <path...>: set mtime two hours back, past the 60 min stale bound.
age() { perl -e 'my $t = time - 7200; utime($t, $t, @ARGV) == @ARGV or exit 1' "$@"; }

run_suite() {
  local bash_bin="$1" tag="$2"
  local FIX="$TMP/$tag/root" SCRATCH="$TMP/$tag/scratch"
  local H="$FIX/.claude/hooks"
  local COMPLETIONS="$FIX/workspace/.hook-timeout-completions"
  local STAMP="$COMPLETIONS.swept"
  local i count before

  mkdir -p "$H" "$FIX/core/scripts/lib" "$COMPLETIONS" "$SCRATCH"
  cp "$MASTER" "$H/master-hook.sh"
  cp "$ROOT/.claude/hooks/hook-gate.sh" "$H/hook-gate.sh"
  cp "$ROOT/.claude/hooks/hook-timeout-probe.sh" "$H/hook-timeout-probe.sh"
  cp "$ROOT/.claude/hooks/hook-timeout-watchdog.sh" "$H/hook-timeout-watchdog.sh"
  cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$FIX/core/scripts/lib/hook-adapter-core.sh"
  [ ! -f "$ROOT/core/scripts/lib/advisory-cap.sh" ] || cp "$ROOT/core/scripts/lib/advisory-cap.sh" "$FIX/core/scripts/lib/advisory-cap.sh"
  [ ! -f "$ROOT/core/scripts/resolve-hq-root.sh" ] || cp "$ROOT/core/scripts/resolve-hq-root.sh" "$FIX/core/scripts/resolve-hq-root.sh"
  chmod +x "$H/master-hook.sh" "$H/hook-gate.sh"
  printf '#!/usr/bin/env bash\ncat >/dev/null\necho "fast output"\n' > "$H/fast.sh"
  chmod +x "$H/fast.sh"
  cat > "$H/hook-registry.json" <<'JSON'
{
  "$schema": "hq-hook-registry@1",
  "description": "fixture",
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [
        {"id": "fast", "script": ".claude/hooks/fast.sh", "gated": false, "timeout": 30}
      ]}
    ]
  }
}
JSON

  # run <label> <tool> [env...]: one master-hook PreToolUse run. LANG is left
  # unset, the case in which master-hook picks its own locale.
  run() {
    local label="$1" tool="$2"
    shift 2
    printf '{"session_id":"stale-markers","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"command":"echo hi","file_path":"/dev/null"},"cwd":"%s"}' \
      "$tool" "$FIX" > "$TMP/$tag/in.json"
    : > "$CALLS"
    env -i "HOME=$TMP/$tag" "PATH=$SHIM:$PATH" "TMPDIR=$SCRATCH" "HQ_ROOT=$FIX" "CLAUDE_PROJECT_DIR=$FIX" \
      "BASH_ENV=/dev/null" "HQ_HOOK_TIMEOUT_SENTRY=0" "$@" \
      "$bash_bin" "$H/master-hook.sh" PreToolUse <"$TMP/$tag/in.json" >"$TMP/$tag/$label.out" 2>"$TMP/$tag/$label.err" \
      || fail "$tag $label: master-hook exited $? ($(cat "$TMP/$tag/$label.err"))"
  }
  done_count() { find "$COMPLETIONS" -maxdepth 1 -type f -name '*.done' | wc -l | tr -d ' '; }

  # Backlog: names in the form master-hook writes (<64 hex>.<n>.done).
  i=0
  while [ "$i" -lt "$BACKLOG" ]; do
    : > "$COMPLETIONS/$(printf '%064x' "$i").$((i % 7 + 1)).done"
    i=$((i + 1))
  done
  : > "$COMPLETIONS/keep.txt"
  mkdir -p "$COMPLETIONS/sub.done"
  find "$COMPLETIONS" -maxdepth 1 -name '*.done' -exec perl -e 'my $t = time - 7200; utime($t, $t, @ARGV)' {} +
  age "$COMPLETIONS/keep.txt"
  : > "$COMPLETIONS/$(printf '%064x' 999999).1.done"   # recent: could belong to a live run
  [ "$(done_count)" -eq $((BACKLOG + 1)) ] || fail "$tag: fixture backlog was not created"

  run backlog Read
  [ "$(done_count)" -eq 1 ] || fail "$tag backlog: $(done_count) markers left, expected only the recent one"
  [ "$(sweep_finds)" -eq 1 ] || fail "$tag backlog: expected one find for the sweep, saw $(sweep_finds)"
  [ -f "$COMPLETIONS/$(printf '%064x' 999999).1.done" ] || fail "$tag backlog: the recent marker was removed"
  [ -f "$COMPLETIONS/keep.txt" ] || fail "$tag backlog: a file that is not a marker was removed"
  [ -d "$COMPLETIONS/sub.done" ] || fail "$tag backlog: a directory was removed"
  pass "$tag: $BACKLOG old markers removed; a recent marker, another file and a directory stay"

  [ -f "$STAMP" ] || fail "$tag: no sweep stamp at $STAMP"
  count="$(find "$COMPLETIONS" -maxdepth 1 -type f ! -name '*.done' ! -name 'keep.txt' | wc -l | tr -d ' ')"
  [ "$count" -eq 0 ] || fail "$tag: the sweep left a file of its own inside the marker directory"
  case "$(cat "$STAMP")" in ''|*[!0-9]*) fail "$tag: stamp does not hold epoch seconds: $(cat "$STAMP")" ;; esac
  pass "$tag: the stamp sits beside the marker directory and holds epoch seconds"

  : > "$COMPLETIONS/$(printf '%064x' 5).2.done"
  age "$COMPLETIONS/$(printf '%064x' 5).2.done"
  before="$(cat "$STAMP")"
  run inside-interval Read
  [ -f "$COMPLETIONS/$(printf '%064x' 5).2.done" ] || fail "$tag: a run inside the interval swept"
  [ "$(cat "$STAMP")" = "$before" ] || fail "$tag: a run inside the interval rewrote the stamp"
  [ "$(sweep_finds)" -eq 0 ] || fail "$tag: a run inside the interval started find for the sweep"
  [ "$(date_calls)" -le 1 ] || fail "$tag: a run inside the interval started date $(date_calls) times (at most 1 expected)"
  pass "$tag: a second run inside the interval does not sweep and starts no find and at most one date"

  run interval-zero Read "HQ_HOOK_MARKER_SWEEP_SECONDS=0"
  [ ! -e "$COMPLETIONS/$(printf '%064x' 5).2.done" ] || fail "$tag: interval 0 did not sweep"
  pass "$tag: interval 0 sweeps on every run"

  : > "$COMPLETIONS/$(printf '%064x' 6).2.done"
  age "$COMPLETIONS/$(printf '%064x' 6).2.done"
  printf 'not-a-number\n' > "$STAMP"
  run bad-stamp Read
  [ ! -e "$COMPLETIONS/$(printf '%064x' 6).2.done" ] || fail "$tag: a stamp that is not a number stopped the sweep"
  : > "$COMPLETIONS/$(printf '%064x' 7).2.done"
  age "$COMPLETIONS/$(printf '%064x' 7).2.done"
  printf '%s\n' "$(( $(date +%s) + 86400 ))" > "$STAMP"
  run future-stamp Read
  [ ! -e "$COMPLETIONS/$(printf '%064x' 7).2.done" ] || fail "$tag: a stamp in the future stopped the sweep"
  : > "$COMPLETIONS/$(printf '%064x' 8).2.done"
  : > "$COMPLETIONS/$(printf '%064x' 8).3.done.fb"
  age "$COMPLETIONS/$(printf '%064x' 8).2.done" "$COMPLETIONS/$(printf '%064x' 8).3.done.fb"
  printf '0800\n' > "$STAMP"
  run zero-stamp Read
  [ ! -e "$COMPLETIONS/$(printf '%064x' 8).2.done" ] || fail "$tag: a stamp with a leading zero stopped the sweep"
  [ ! -e "$COMPLETIONS/$(printf '%064x' 8).3.done.fb" ] || fail "$tag: an old fallback marker (.done.fb) was not removed"
  [ ! -s "$TMP/$tag/zero-stamp.err" ] || fail "$tag: a stamp with a leading zero printed: $(cat "$TMP/$tag/zero-stamp.err")"
  [ ! -s "$TMP/$tag/bad-stamp.err" ] || fail "$tag: a stamp that is not a number printed: $(cat "$TMP/$tag/bad-stamp.err")"
  pass "$tag: a stamp that is not a number, has a leading zero or is in the future does not stop the sweep; old fallback markers go too"

  rm -rf "$COMPLETIONS" "$STAMP"
  run fresh-dir Bash
  [ -d "$COMPLETIONS" ] || fail "$tag fresh-dir: the run did not create the marker directory (fixture is not exercising the timeout runner)"
  [ -f "$STAMP" ] || fail "$tag fresh-dir: the run that created the directory wrote no stamp"
  [ "$(sweep_finds)" -eq 0 ] || fail "$tag fresh-dir: the run that created the directory started find for the sweep"
  pass "$tag: the run that creates the marker directory writes the stamp and starts no find"

  rm -f "$COMPLETIONS/$(printf '%064x' 999999).1.done"
  run dispatch Bash
  grep -q "fast output" "$TMP/$tag/dispatch.out" "$TMP/$tag/dispatch.err" \
    || fail "$tag dispatch: the child's output is missing (out: $(cat "$TMP/$tag/dispatch.out"); err: $(cat "$TMP/$tag/dispatch.err"))"
  [ "$(done_count)" -eq 0 ] || fail "$tag dispatch: the run left its own marker behind"
  pass "$tag: a dispatching run returns the child's output and leaves no marker"
}

ran=0
path_bash="$(command -v bash)"
run_suite "$path_bash" "path-bash-$("$path_bash" -c 'printf %s "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"')"
ran=$((ran + 1))
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'printf %s "$BASH_VERSION"')" != "$("$path_bash" -c 'printf %s "$BASH_VERSION"')" ]; then
  run_suite /bin/bash "bin-bash-$(/bin/bash -c 'printf %s "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"')"
  ran=$((ran + 1))
fi

echo "PASS: master-hook stale completion markers ($ran bash version(s))"
