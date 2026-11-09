#!/usr/bin/env bash
# Session-start hooks: cached probes and the cases that must still run.
#
# Runs every case three ways:
#   native  the stat on this machine
#   gnu     a stat shim that behaves like GNU coreutils: -f is filesystem mode,
#           prints a multi-line dump and exits 1; -c %Y prints the mtime.
#           This is the Linux and Windows Git Bash behaviour.
#   gstat   real GNU coreutils stat (gstat) first on PATH, when installed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

if [ -z "${HOOK_SPEED_STAT_MODE:-}" ]; then
  modes="native gnu"
  command -v gstat >/dev/null 2>&1 && modes="$modes gstat"
  for mode in $modes; do
    printf -- '--- stat mode: %s\n' "$mode"
    HOOK_SPEED_STAT_MODE="$mode" bash "${BASH_SOURCE[0]}" || { printf 'FAIL: stat mode %s\n' "$mode" >&2; exit 1; }
  done
  printf 'hook-speed-daily: ok (%s)\n' "$modes"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL [%s]: %s\n' "$HOOK_SPEED_STAT_MODE" "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

STAT_BIN="$TMP/statbin"
mkdir -p "$STAT_BIN"
case "$HOOK_SPEED_STAT_MODE" in
  native) ;;
  gnu)
    cat > "$STAT_BIN/stat" <<'SHIM'
#!/usr/bin/env bash
# GNU coreutils stat behaviour for the two forms the hooks use.
case "${1:-}" in
  -f)
    printf "stat: cannot read file system information for '%s': No such file or directory\n" "${2:-}" >&2
    printf '  File: "%s"\n    ID: 0        Namelen: 255     Type: ext2/ext3\n' "${3:-}"
    printf 'Block size: 4096       Fundamental block size: 4096\n'
    printf 'Blocks: Total: 1000000    Free: %s    Available: 1\n' "$RANDOM"
    exit 1
    ;;
  -c)
    [ "${2:-}" = %Y ] || exit 1
    [ -e "${3:-}" ] || exit 1
    exec perl -e 'print((stat $ARGV[0])[9], "\n")' "$3"
    ;;
esac
exit 1
SHIM
    chmod +x "$STAT_BIN/stat"
    ;;
  gstat)
    ln -s "$(command -v gstat)" "$STAT_BIN/stat"
    ;;
  *) fail "unknown mode" ;;
esac
export PATH="$STAT_BIN:$PATH"

if [ "$HOOK_SPEED_STAT_MODE" != native ]; then
  if stat -f %m / >/dev/null 2>&1; then fail 'stat -f did not fail like GNU'; fi
  [ -n "$(stat -f %m / 2>/dev/null || true)" ] || fail 'stat -f did not print a dump like GNU'
  pass 'stat on PATH behaves like GNU'
fi

GATE_ROOT="$TMP/hq"
mkdir -p "$GATE_ROOT/workspace"
PAYLOAD='{"session_id":"plain-1","source":"startup"}'

# --- hooks: a fresh session with no lanes still asks the CLI ------------------
# "No link, no lanes" is the state auto-conduct bootstraps from, and the monitor
# note follows monitor.enabled. Neither may be skipped on lane state.
BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/hq" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_CALLS"
if [ "${1:-}" = --version ]; then printf '5.345.67\n'; exit 0; fi
if [ "${1:-}" = monitor ]; then printf 'on\n'; exit 0; fi
printf 'conductor text\n'
FAKE
chmod +x "$BIN/hq"
export PATH="$STAT_BIN:$BIN:/usr/bin:/bin"
export FAKE_CALLS="$TMP/calls"
export CLAUDE_PROJECT_DIR="$GATE_ROOT"
export HQ_ROOT="$GATE_ROOT"
mkdir -p "$GATE_ROOT/.claude/hooks"
: > "$GATE_ROOT/.claude/hooks/hook-gate.sh"
rm -rf "$GATE_ROOT/workspace/lanes" "$GATE_ROOT/workspace/lanes-links"
: > "$FAKE_CALLS"
printf '%s' "$PAYLOAD" | HQ_CHECKPOINT_RUNTIME=codex bash "$ROOT/.claude/hooks/hq-monitor-session-start.sh" >"$TMP/out"
grep -Fq 'hq monitor start' "$TMP/out" || fail 'fresh Codex session got no monitor note'
pass 'monitor note reaches a session with no lanes'

: > "$FAKE_CALLS"
printf '%s' "$PAYLOAD" | bash "$ROOT/.claude/hooks/conduct-lanes-session-start.sh" >"$TMP/out"
grep -Fq 'lanes session-start' "$FAKE_CALLS" || fail 'fresh session did not reach the auto-conduct bootstrap'
grep -Fq 'conductor text' "$TMP/out" || fail 'auto-conduct output was not passed through'
pass 'fresh session reaches the auto-conduct bootstrap'

# --- work mesh: foreground reconcile is offline; network call is detached ---
mesh="$ROOT/core/hooks/SessionStart/35-work-mesh-session-start.sh"
grep -Fq 'mesh context reconcile --observation-file "$OBS_FILE" --machine --offline' "$mesh" \
  || fail 'foreground reconcile is not offline'
grep -Fq 'nohup bash -c' "$mesh" || fail 'reconcile drainer is not detached'
pass 'work mesh keeps network reconcile off the foreground path'

set_age() { # file seconds
  perl -e 'my $t = time - $ARGV[1]; utime $t, $t, $ARGV[0] or exit 1' "$1" "$2"
}

# --- worktree guard: an allow verdict holds for a day, not ten minutes ------
# A full check that allows rewrites the cache with a new ts; a cache hit
# leaves the file as it was.
GUARD="$ROOT/.claude/hooks/block-hq-worktree-session.sh"
GUARD_CACHE="$GATE_ROOT/workspace/orchestrator/hook-state/worktree-guard/guard-1"
mkdir -p "${GUARD_CACHE%/*}"
guard_payload="{\"session_id\":\"guard-1\",\"cwd\":\"$GATE_ROOT\",\"hook_event_name\":\"UserPromptSubmit\"}"
guard_ts() { sed -n 's/^ts=//p' "$GUARD_CACHE"; }
write_guard_cache() { # age-seconds
  local age="$1" now
  now="$(date +%s)"
  printf 'root=%s\ncwd=%s\nts=%s\n' "$GATE_ROOT" "$GATE_ROOT" "$((now - age))" > "$GUARD_CACHE"
}
write_guard_cache 3600
before="$(guard_ts)"
printf '%s' "$guard_payload" | bash "$GUARD" UserPromptSubmit >/dev/null 2>&1 || fail 'guard did not allow a 1h-old allow verdict'
[ "$(guard_ts)" = "$before" ] || fail 'guard re-checked a 1h-old allow verdict'
write_guard_cache 90000
before="$(guard_ts)"
printf '%s' "$guard_payload" | bash "$GUARD" UserPromptSubmit >/dev/null 2>&1 || fail 'guard blocked a plain HQ root'
[ "$(guard_ts)" -gt "$before" ] || fail 'guard trusted a 25h-old allow verdict'
pass 'worktree allow verdict is reused for a day and rechecked after'

# --- ensure-hq-cli: a usable probe is reused for a day, not 15 minutes ------
ENSURE="$ROOT/core/hooks/UserPromptSubmit/30-ensure-hq-cli.sh"
if command -v jq >/dev/null 2>&1; then
  E_ROOT="$TMP/ensure"
  mkdir -p "$E_ROOT/.claude" "$E_ROOT/workspace"
  printf '{"env":{"PATH":"%s:/usr/bin"}}\n' "$BIN" > "$E_ROOT/.claude/settings.local.json"
  run_ensure() {
    env -i PATH="$STAT_BIN:$BIN:/usr/bin:/bin" HQ_ROOT="$E_ROOT" HOME="$TMP/home" FAKE_CALLS="$FAKE_CALLS" \
      bash "$ENSURE" UserPromptSubmit </dev/null >/dev/null 2>&1 || true
  }
  probes() { grep -c -- '--version' "$FAKE_CALLS" 2>/dev/null || true; }
  : > "$FAKE_CALLS"
  run_ensure
  [ "$(probes)" = 1 ] || fail "ensure first run probed $(probes) times"
  OK_CACHE="$E_ROOT/workspace/.hq-cli-ensure/usable.ok"
  [ -f "$OK_CACHE" ] || fail 'ensure did not write the usable cache'
  set_age "$OK_CACHE" 3600
  run_ensure
  [ "$(probes)" = 1 ] || fail 'ensure re-probed a 1h-old usable cache'
  set_age "$OK_CACHE" 90000
  run_ensure
  [ "$(probes)" = 2 ] || fail 'ensure trusted a 25h-old usable cache'
  pass 'hq usable probe is reused for a day and rechecked after'
else
  printf 'SKIP: jq missing, ensure-hq-cli cache case not run\n'
fi

# --- repo-rooted skills note: shown to every repo session, every time ------
if command -v jq >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
  S_HQ="$TMP/skills-hq"
  mkdir -p "$S_HQ/core/hooks/SessionStart" "$S_HQ/core/scripts/lib" "$S_HQ/.claude/skills/review" "$S_HQ/workspace"
  printf -- '---\nname: review\n---\nbody\n' > "$S_HQ/.claude/skills/review/SKILL.md"
  cp "$ROOT/core/hooks/SessionStart/55-repo-rooted-hq-skills.sh" "$S_HQ/core/hooks/SessionStart/"
  git -C "$S_HQ" init -q
  S_REPO="$S_HQ/repos/private/app"
  mkdir -p "$S_REPO"
  git -C "$S_REPO" init -q
  for n in 1 2; do
    out="$(jq -cn --arg cwd "$S_REPO" '{session_id:"sk",cwd:$cwd,hook_event_name:"SessionStart",source:"startup"}' \
      | env HQ_ROOT="$S_HQ" bash "$S_HQ/core/hooks/SessionStart/55-repo-rooted-hq-skills.sh")"
    case "$out" in *additionalContext*) ;; *) fail "repo session $n got no skills note" ;; esac
  done
  pass 'repo-rooted skills note is shown to every repo session'
fi

printf 'hook-speed-daily [%s]: ok\n' "$HOOK_SPEED_STAT_MODE"
