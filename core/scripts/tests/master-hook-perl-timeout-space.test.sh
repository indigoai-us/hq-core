#!/usr/bin/env bash
# master-hook-perl-timeout-space.test.sh
#
# Pins that master-hook.sh's perl timeout fallback keeps a child's exit
# status when the HQ root contains a space. Bare `exec @ARGV` routes a
# single spaced path through /bin/sh, the exec fails, and perl exits 0,
# so every argless registry hook no-ops on stock macOS. GNU timeout is
# hidden so Linux CI takes the same branch.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MASTER="$ROOT/.claude/hooks/master-hook.sh"
GATE="$ROOT/.claude/hooks/hook-gate.sh"
RUN_PROJECT="$ROOT/.claude/scripts/run-project.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

[ -f "$MASTER" ] || fail "missing $MASTER"
[ -f "$GATE" ] || fail "missing $GATE"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "SKIP: perl required"; exit 0; }

# ── 1. Source: perl fallbacks use the list-path exec form ──────────────────
assert_indirect_exec() {
  local file="$1" label="$2"
  if grep -F '{$ARGV[0]} @ARGV' "$file" >/dev/null \
    || grep -F '{\$ARGV[0]} @ARGV' "$file" >/dev/null; then
    :
  else
    fail "$label: missing exec {\$ARGV[0]} @ARGV in $file"
  fi
  if grep -E 'perl -e .*;[[:space:]]*exec @ARGV' "$file" >/dev/null; then
    fail "$label: leftover bare exec @ARGV in $file"
  fi
  pass "$label uses list-path perl exec"
}
assert_indirect_exec "$MASTER" "master-hook.sh"
assert_indirect_exec "$RUN_PROJECT" "run-project.sh"

# ── 2. Fixture HQ root whose path contains a space ─────────────────────────
TMP="$(mktemp -d "${TMPDIR:-/tmp}/SE HQ.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/root"
mkdir -p "$FIX/.claude/hooks" "$FIX/bin"
cp "$MASTER" "$FIX/.claude/hooks/master-hook.sh"
cp "$GATE" "$FIX/.claude/hooks/hook-gate.sh"
chmod +x "$FIX/.claude/hooks/master-hook.sh" "$FIX/.claude/hooks/hook-gate.sh"

cat > "$FIX/.claude/hooks/guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'fixture guard blocked\n' >&2
exit 2
SH
cat > "$FIX/.claude/hooks/sleepy.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
sleep 10
exit 0
SH
chmod +x "$FIX/.claude/hooks/guard.sh" "$FIX/.claude/hooks/sleepy.sh"

jq -n '{hooks:{PreToolUse:[{matcher:"Write",hooks:[
  {id:"guard",script:".claude/hooks/guard.sh",timeout:30,gated:false}
]}]}}' > "$FIX/.claude/hooks/hook-registry.json"

# Hide GNU timeout so run_child takes the perl branch. Git Bash has no
# timeout(1) already; copying bash/perl into a private bin breaks MSYS
# DLL loading (exit 127). Do not isolate PATH there.
BASH_BIN="$(command -v bash)"
[ -n "$BASH_BIN" ] || fail "bash not on PATH"
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    PERL_PATH="$PATH"
    pass "Git Bash: use host PATH (perl fallback is already the timeout path)"
    ;;
  *)
    TMPBIN="$FIX/bin"
    link_real() {
      local c="$1" p
      p="$(command -v "$c" 2>/dev/null)" || return 0
      case "$p" in
        /*) ;;
        *) return 0 ;;
      esac
      [ -f "$p" ] || return 0
      [ -e "$TMPBIN/$c" ] && return 0
      ln -s "$p" "$TMPBIN/$c" 2>/dev/null || cp "$p" "$TMPBIN/$c" 2>/dev/null || true
    }
    for c in perl bash jq cat chmod mkdir mktemp basename dirname uname tr sed awk \
             sort cut head grep env sleep date hostname id ps rm mv cp ln \
             touch wc tee xargs which sh ls file find stat readlink; do
      link_real "$c"
    done
    [ -x "$TMPBIN/timeout" ] && fail "timeout leaked into perl-only PATH"
    [ -x "$TMPBIN/perl" ] || fail "perl missing from perl-only PATH"
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
    ;;
esac

PAYLOAD="$(jq -nc --arg p "$FIX/core/X.txt" --arg cwd "$FIX" \
  '{hook_event_name:"PreToolUse",session_id:"perl-space",cwd:$cwd,tool_name:"Write",tool_input:{file_path:$p,content:"p"}}')"

run_master() { # <path-to-master> -> sets RC ERR
  local master="$1" errfile
  errfile="$(mktemp)"
  RC=0
  printf '%s' "$PAYLOAD" \
    | env PATH="$PERL_PATH" HOME="${HOME:-/tmp}" HQ_HOOK_TIMEOUT_SENTRY=0 HQ_HOOK_TRACE=1 \
        CLAUDE_PROJECT_DIR="$FIX" \
        "$BASH_BIN" "$master" PreToolUse >/dev/null 2>"$errfile" || RC=$?
  ERR="$(cat "$errfile")"
  rm -f "$errfile"
}

case "$FIX" in
  *" "*) ;;
  *) fail "fixture path has no space: $FIX" ;;
esac

# Unix perl routes a one-element spaced LIST through /bin/sh and drops status.
# Windows perl often does not; still require master-hook to return 2.
bare_rc=0
perl -e 'alarm shift; exec @ARGV' 2 "$FIX/.claude/hooks/guard.sh" >/dev/null 2>&1 || bare_rc=$?
if [ "$bare_rc" = "0" ]; then
  pass "control: bare exec @ARGV drops exit status on a spaced path"
else
  pass "control: this perl already preserves status on a spaced path (rc=$bare_rc)"
fi

run_master "$FIX/.claude/hooks/master-hook.sh"
[ "$RC" = "2" ] || fail "perl fallback via master-hook: expected exit 2, got $RC stderr=$ERR"
printf '%s' "$ERR" | grep -q 'fixture guard blocked' \
  || fail "perl fallback lost guard stderr: $ERR"
printf '%s' "$ERR" | grep -q 'run guard rc=2' \
  || fail "perl fallback trace did not record rc=2: $ERR"
pass "argless registry guard blocks through perl fallback on a spaced HQ root"

# ── 3. Alarm still fires under the same fallback ───────────────────────────
# ITIMER_REAL does not survive exec the same way on Windows Git Bash.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    pass "skip perl alarm check on $(uname -s)"
    ;;
  *)
    jq -n '{hooks:{PreToolUse:[{matcher:"Write",hooks:[
      {id:"sleepy",script:".claude/hooks/sleepy.sh",timeout:2,gated:false}
    ]}]}}' > "$FIX/.claude/hooks/hook-registry.json"
    rm -rf "$FIX/workspace/orchestrator/hook-state/registry-rows"
    run_master "$FIX/.claude/hooks/master-hook.sh"
    [ "$RC" -ne 0 ] || fail "perl alarm did not terminate a 10s child in 2s (rc=$RC) stderr=$ERR"
    pass "perl alarm still terminates an over-budget child (rc=$RC)"
    ;;
esac

echo "ALL PASS: master-hook-perl-timeout-space"
exit 0
