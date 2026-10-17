#!/usr/bin/env bash
# master-hook-perl-timeout-process-group.test.sh
#
# Pins that master-hook.sh's perl timeout fallback (macOS without coreutils
# timeout) bounds the whole hook, not only its first process. The old
# `alarm; exec` / `alarm; system` runners killed perl or the hook's Bash and
# left the hook's children running. Those children held the stdout pipe that
# master-hook reads, so master-hook waited for the slowest descendant: a 2 s
# registry timeout on a hook whose child sleeps 20 s took 20 s, and in real
# sessions 30-60 s registry timeouts ran 120-280 s (feedback_ea24aaad).
#
# Covers the registry exec runner, the registry source runner, and a
# discovered core/hooks/<event> hook (HQ_MASTER_CHILD_TIMEOUT). Each must
# return within the time budget and leave no surviving child.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MASTER="$ROOT/.claude/hooks/master-hook.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

[ -f "$MASTER" ] || fail "missing $MASTER"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "SKIP: perl required"; exit 0; }
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    # Git Bash ships coreutils timeout, and perl alarm does not survive exec
    # there; the perl branch is not the timeout path on Windows.
    echo "SKIP: perl process-group timeout is a Unix path"
    exit 0
    ;;
esac

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mh-perl-pgrp.XXXXXX")"
cleanup() {
  local pidfile pid
  for pidfile in "$TMP"/*.pid; do
    [ -f "$pidfile" ] || continue
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -KILL "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

FIX="$TMP/root"
mkdir -p "$FIX/.claude/hooks" "$FIX/core/scripts/lib" "$FIX/core/hooks" "$FIX/bin"
cp "$MASTER" "$FIX/.claude/hooks/master-hook.sh"
cp "$ROOT/.claude/hooks/hook-gate.sh" "$FIX/.claude/hooks/hook-gate.sh"
cp "$ROOT/.claude/hooks/hook-timeout-probe.sh" "$FIX/.claude/hooks/hook-timeout-probe.sh"
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$FIX/core/scripts/lib/hook-adapter-core.sh"
chmod +x "$FIX/.claude/hooks/master-hook.sh" "$FIX/.claude/hooks/hook-gate.sh"

# A hook whose own Bash is not the slow process: it starts a long child,
# records the child's pid, and waits on it. The child inherits stdout.
write_slow_hook() { # <path> <pidfile>
  cat > "$1" <<SH
#!/usr/bin/env bash
cat >/dev/null
sleep 20 &
printf '%s' "\$!" > "$2"
wait
echo "slow hook finished"
exit 0
SH
  chmod +x "$1"
}
write_slow_hook "$FIX/.claude/hooks/slow-exec.sh" "$TMP/exec.pid"
write_slow_hook "$FIX/.claude/hooks/slow-source.sh" "$TMP/source.pid"

# Hide GNU timeout so run_child takes the perl branch on Linux CI as well.
BASH_BIN="$(command -v bash)"
TMPBIN="$FIX/bin"
link_real() {
  local c="$1" p
  p="$(command -v "$c" 2>/dev/null)" || return 0
  case "$p" in /*) ;; *) return 0 ;; esac
  [ -f "$p" ] || return 0
  [ -e "$TMPBIN/$c" ] && return 0
  ln -s "$p" "$TMPBIN/$c" 2>/dev/null || cp "$p" "$TMPBIN/$c" 2>/dev/null || true
}
for c in perl bash jq cat chmod mkdir mktemp basename dirname uname tr sed awk \
         sort cut head tail grep env sleep date hostname id ps rm mv cp ln \
         touch wc tee xargs which sh ls file find stat readlink shasum sha256sum; do
  link_real "$c"
done
PERL_PATH="$TMPBIN"
old_ifs="$IFS"
IFS=:
for dir in $PATH; do
  [ -n "$dir" ] || continue
  if [ -x "$dir/timeout" ] || [ -x "$dir/gtimeout" ]; then
    continue
  fi
  PERL_PATH="$PERL_PATH:$dir"
done
IFS="$old_ifs"
PATH="$PERL_PATH" command -v timeout >/dev/null 2>&1 \
  && fail "timeout still visible after PATH filter"
PATH="$PERL_PATH" command -v perl >/dev/null 2>&1 \
  || fail "perl missing after PATH filter"

PAYLOAD="$(jq -nc --arg cwd "$FIX" \
  '{hook_event_name:"PreToolUse",session_id:"perl-pgrp",cwd:$cwd,tool_name:"Bash",tool_input:{command:"ls"}}')"

now_ms() { perl -MTime::HiRes=time -e 'printf "%.0f", time() * 1000'; }

run_master() { # -> sets RC ELAPSED_MS
  local started ended
  started="$(now_ms)"
  RC=0
  printf '%s' "$PAYLOAD" \
    | env PATH="$PERL_PATH" HOME="${HOME:-/tmp}" HQ_HOOK_TIMEOUT_SENTRY=0 \
        HQ_MASTER_CHILD_TIMEOUT=2 CLAUDE_PROJECT_DIR="$FIX" \
        "$BASH_BIN" "$FIX/.claude/hooks/master-hook.sh" PreToolUse \
        >"$TMP/out" 2>"$TMP/err" || RC=$?
  ended="$(now_ms)"
  ELAPSED_MS=$((ended - started))
}

# 2 s child timeout + master overhead. The unbounded runner takes >= 20 s.
BUDGET_MS=12000

assert_bounded() { # <label> <pidfile>
  local label="$1" pidfile="$2" pid
  [ "$ELAPSED_MS" -lt "$BUDGET_MS" ] \
    || fail "$label: master-hook took ${ELAPSED_MS}ms with a 2s child timeout (budget ${BUDGET_MS}ms); stderr=$(cat "$TMP/err")"
  ! grep -q 'slow hook finished' "$TMP/out" \
    || fail "$label: timed-out hook ran to completion"
  [ -s "$pidfile" ] || fail "$label: hook never started (no pid file); stderr=$(cat "$TMP/err")"
  pid="$(cat "$pidfile")"
  sleep 1
  if kill -0 "$pid" 2>/dev/null; then
    fail "$label: child pid $pid survived the timeout"
  fi
  pass "$label: returned in ${ELAPSED_MS}ms and left no child running"
}

# ── 1. Registry hook, exec runner ──────────────────────────────────────────
jq -n '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[
  {id:"slow-exec",script:".claude/hooks/slow-exec.sh",timeout:2,gated:false}
]}]}}' > "$FIX/.claude/hooks/hook-registry.json"
run_master
assert_bounded "registry exec runner" "$TMP/exec.pid"

# ── 2. Registry hook, source runner ────────────────────────────────────────
jq -n '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[
  {id:"slow-source",script:".claude/hooks/slow-source.sh",timeout:2,gated:false,runner:"source"}
]}]}}' > "$FIX/.claude/hooks/hook-registry.json"
rm -rf "$FIX/workspace/orchestrator/hook-state/registry-rows"
run_master
assert_bounded "registry source runner" "$TMP/source.pid"

# ── 3. Discovered core/hooks/<event> hook ──────────────────────────────────
jq -n '{hooks:{}}' > "$FIX/.claude/hooks/hook-registry.json"
rm -rf "$FIX/workspace/orchestrator/hook-state/registry-rows"
mkdir -p "$FIX/core/hooks/PreToolUse"
write_slow_hook "$FIX/core/hooks/PreToolUse/50-slow-discovered.sh" "$TMP/discovered.pid"
run_master
assert_bounded "discovered core hook" "$TMP/discovered.pid"
rm -f "$FIX/core/hooks/PreToolUse/50-slow-discovered.sh"

# ── 4. A fast hook keeps its exit status and output ────────────────────────
cat > "$FIX/.claude/hooks/guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'fixture guard blocked\n' >&2
exit 2
SH
chmod +x "$FIX/.claude/hooks/guard.sh"
jq -n '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[
  {id:"guard",script:".claude/hooks/guard.sh",timeout:5,gated:false}
]}]}}' > "$FIX/.claude/hooks/hook-registry.json"
rm -rf "$FIX/workspace/orchestrator/hook-state/registry-rows"
run_master
[ "$RC" = "2" ] || fail "fast guard: expected exit 2 through perl runner, got $RC stderr=$(cat "$TMP/err")"
grep -q 'fixture guard blocked' "$TMP/err" || fail "fast guard lost stderr: $(cat "$TMP/err")"
pass "fast guard keeps exit 2 and stderr through the perl runner"

echo "ALL PASS: master-hook-perl-timeout-process-group"
exit 0
