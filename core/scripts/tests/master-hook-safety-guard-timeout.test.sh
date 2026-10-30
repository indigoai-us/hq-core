#!/usr/bin/env bash
# master-hook-safety-guard-timeout.test.sh
#
# Pins that a PreToolUse safety guard (registry "safety": true) that times out
# blocks the tool call. Claude Code treats any hook exit other than 2 as
# non-blocking, so before this change a guard that hung until its timeout
# (124 from coreutils timeout, 142/124 from the perl runner) let the command
# through unchecked. master-hook now caps safety guards at min(timeout, 25 s),
# kills the guard's process group, and exits 2 with "guard timed out, blocked".
# Non-safety hooks keep the old fail-open behavior.
#
# Each case runs under every runner master-hook can pick (coreutils timeout,
# the perl fallback, and the plain-bash fallback when neither exists) and
# under every Bash found: the PATH bash (bash 5 on CI and Homebrew) and
# /bin/bash (3.2 on macOS). Set MASTER_HOOK_TEST_BASHES to override the list.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MASTER="$ROOT/.claude/hooks/master-hook.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

[ -f "$MASTER" ] || fail "missing $MASTER"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "SKIP: perl required (test timing)"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mh-safety-timeout.XXXXXX")"
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

# ── 0. Cap arithmetic (pure function, no fixture needed) ───────────────────
cap_fn="$TMP/cap.sh"
sed -n '/^MASTER_SAFETY_GUARD_TIMEOUT_MAX=/,/^}/p' "$MASTER" > "$cap_fn"
grep -q 'master_safety_guard_timeout()' "$cap_fn" || fail "cap function not found in master-hook"
cap_case() { # <HQ_SAFETY_GUARD_TIMEOUT or -> <registry-timeout> <expected>
  local env_val="$1" reg="$2" want="$3" got
  if [ "$env_val" = "-" ]; then
    got="$(env -u HQ_SAFETY_GUARD_TIMEOUT bash -c '. "$1"; master_safety_guard_timeout "$2"' _ "$cap_fn" "$reg")"
  else
    got="$(HQ_SAFETY_GUARD_TIMEOUT="$env_val" bash -c '. "$1"; master_safety_guard_timeout "$2"' _ "$cap_fn" "$reg")"
  fi
  [ "$got" = "$want" ] || fail "cap(env=$env_val, registry=$reg) = $got, want $want"
}
cap_case - 30 25
cap_case - 60 25
cap_case - 10 10
cap_case - "" 25
cap_case 2 30 2
cap_case 99 30 25
cap_case abc 30 25
cap_case 0 30 25
cap_case 5 3 3
pass "safety cap is min(registry timeout, HQ_SAFETY_GUARD_TIMEOUT, 25)"

# Total budget: every safety guard in one master-hook run shares 240 s, so
# several slow guards cannot together outlast the 300 s host hook timeout
# (a host-killed master-hook does not block). 0 means the budget is spent.
budget_case() { # <HQ_SAFETY_GUARD_TOTAL_BUDGET or -> <registry-timeout> <elapsed> <expected>
  local env_val="$1" reg="$2" elapsed="$3" want="$4" got
  if [ "$env_val" = "-" ]; then
    got="$(env -u HQ_SAFETY_GUARD_TIMEOUT -u HQ_SAFETY_GUARD_TOTAL_BUDGET bash -c '. "$1"; master_safety_guard_timeout "$2" "$3"' _ "$cap_fn" "$reg" "$elapsed")"
  else
    got="$(env -u HQ_SAFETY_GUARD_TIMEOUT HQ_SAFETY_GUARD_TOTAL_BUDGET="$env_val" bash -c '. "$1"; master_safety_guard_timeout "$2" "$3"' _ "$cap_fn" "$reg" "$elapsed")"
  fi
  [ "$got" = "$want" ] || fail "budget(env=$env_val, registry=$reg, elapsed=$elapsed) = $got, want $want"
}
budget_case - 30 0 25
budget_case - 30 200 25
budget_case - 30 230 10
budget_case - 30 239 1
budget_case - 30 240 0
budget_case - 30 299 0
budget_case - 30 abc 25
budget_case 10 30 4 6
budget_case 10 30 10 0
budget_case 999 30 230 10
budget_case abc 30 230 10
pass "safety cap is clamped to what is left of the 240 s shared budget"

FIX="$TMP/root"
mkdir -p "$FIX/.claude/hooks" "$FIX/core/scripts/lib" "$FIX/core/hooks"
cp "$MASTER" "$FIX/.claude/hooks/master-hook.sh"
cp "$ROOT/.claude/hooks/hook-gate.sh" "$FIX/.claude/hooks/hook-gate.sh"
cp "$ROOT/.claude/hooks/hook-timeout-probe.sh" "$FIX/.claude/hooks/hook-timeout-probe.sh"
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$FIX/core/scripts/lib/hook-adapter-core.sh"
chmod +x "$FIX/.claude/hooks/master-hook.sh" "$FIX/.claude/hooks/hook-gate.sh"

# A slow hook that starts a long child and waits for it. The TERM-ignoring
# variant also proves the SIGKILL follow-up reaches the whole group.
write_slow_hook() { # <path> <pidfile> <ignore-term:0|1>
  local trap_line=""
  [ "$3" = "1" ] && trap_line="trap '' TERM"
  cat > "$1" <<SH
#!/usr/bin/env bash
$trap_line
cat >/dev/null
sleep 20 &
printf '%s' "\$!" > "$2"
wait
echo "slow hook finished"
exit 0
SH
  chmod +x "$1"
}
write_slow_hook "$FIX/.claude/hooks/slow-guard.sh" "$TMP/guard.pid" 0
write_slow_hook "$FIX/.claude/hooks/stubborn-guard.sh" "$TMP/stubborn.pid" 1
write_slow_hook "$FIX/.claude/hooks/slow-advisory.sh" "$TMP/advisory.pid" 0
cat > "$FIX/.claude/hooks/fast-deny.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'fixture guard denied\n' >&2
exit 2
SH
cat > "$FIX/.claude/hooks/fast-allow.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
exit 0
SH
chmod +x "$FIX/.claude/hooks/fast-deny.sh" "$FIX/.claude/hooks/fast-allow.sh"

# PATH variants. "timeout" keeps coreutils timeout (skipped when absent, as on
# stock macOS); "perl" hides timeout; "bash" hides timeout and perl.
BIN_ALL="$TMP/bin-all"
mkdir -p "$BIN_ALL"
link_real() { # <dir> <cmd>
  local p
  p="$(command -v "$2" 2>/dev/null)" || return 0
  case "$p" in /*) ;; *) return 0 ;; esac
  [ -f "$p" ] || return 0
  [ -e "$1/$2" ] && return 0
  ln -s "$p" "$1/$2" 2>/dev/null || cp "$p" "$1/$2" 2>/dev/null || true
}
for c in bash jq cat chmod mkdir mktemp basename dirname uname tr sed awk \
         sort cut head tail grep env sleep date hostname id ps rm mv cp ln \
         touch wc tee xargs which sh ls file find stat readlink shasum sha256sum \
         kill; do
  link_real "$BIN_ALL" "$c"
done
BIN_PERL="$TMP/bin-perl"
BIN_TIMEOUT="$TMP/bin-timeout"
mkdir -p "$BIN_PERL" "$BIN_TIMEOUT"
link_real "$BIN_PERL" perl
link_real "$BIN_TIMEOUT" perl
link_real "$BIN_TIMEOUT" timeout
[ -e "$BIN_TIMEOUT/timeout" ] || { command -v gtimeout >/dev/null 2>&1 && ln -s "$(command -v gtimeout)" "$BIN_TIMEOUT/timeout"; } || true

RUNNERS=()
[ -e "$BIN_TIMEOUT/timeout" ] && RUNNERS+=(timeout)
RUNNERS+=(perl bash)
case "$(uname -s 2>/dev/null)" in
  # Git Bash: perl alarm does not survive exec and there is no POSIX job
  # control for the bash fallback. coreutils timeout is always present there.
  MINGW*|MSYS*|CYGWIN*) RUNNERS=(timeout) ;;
esac

# Git Bash copies executables on `ln -s`, and the copies cannot load the MSYS
# runtime DLL (exit 127). jq then fails inside master-hook and the guard never
# runs. Use the host PATH there; it already has coreutils timeout.
HOST_PATH="$PATH"
runner_path() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) printf '%s' "$HOST_PATH"; return ;;
  esac
  case "$1" in
    timeout) printf '%s:%s' "$BIN_TIMEOUT" "$BIN_ALL" ;;
    perl) printf '%s:%s' "$BIN_PERL" "$BIN_ALL" ;;
    bash) printf '%s' "$BIN_ALL" ;;
  esac
}

BASHES=()
if [ -n "${MASTER_HOOK_TEST_BASHES:-}" ]; then
  old_ifs="$IFS"; IFS=:
  for b in $MASTER_HOOK_TEST_BASHES; do BASHES+=("$b"); done
  IFS="$old_ifs"
else
  # PATH bash, then Homebrew bash 5 and stock /bin/bash (3.2 on macOS) when
  # they are different binaries.
  for b in "$(command -v bash)" /opt/homebrew/bin/bash /usr/local/bin/bash /bin/bash; do
    [ -x "$b" ] || continue
    real_b="$(cd "$(dirname "$b")" && pwd -P)/$(basename "$b")"
    dup=0
    for seen in ${BASHES[@]+"${BASHES[@]}"}; do
      [ "$(cd "$(dirname "$seen")" && pwd -P)/$(basename "$seen")" = "$real_b" ] && dup=1
    done
    [ "$dup" = 1 ] || BASHES+=("$b")
  done
fi
echo "  bashes under test:"
for b in "${BASHES[@]}"; do echo "    $b ($("$b" -c 'echo "$BASH_VERSION"'))"; done

PAYLOAD="$(jq -nc --arg cwd "$FIX" \
  '{hook_event_name:"PreToolUse",session_id:"safety-timeout",cwd:$cwd,tool_name:"Bash",tool_input:{command:"ls"}}')"

now_ms() { perl -MTime::HiRes=time -e 'printf "%.0f", time() * 1000'; }

write_registry() { # <id> <script> <timeout> <safety:true|false> [runner]
  jq -n --arg id "$1" --arg script ".claude/hooks/$2" --argjson t "$3" --argjson s "$4" --arg r "${5:-}" \
    '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[{id:$id,script:$script,timeout:$t,gated:false,safety:$s} + (if $r == "" then {} else {runner:$r} end)]}]}}' \
    > "$FIX/.claude/hooks/hook-registry.json"
  rm -rf "$FIX/workspace/orchestrator/hook-state/registry-rows"
}

run_master() { # <bash> <runner> -> RC ELAPSED_MS
  local bash_bin="$1" path started ended
  path="$(runner_path "$2")"
  started="$(now_ms)"
  RC=0
  printf '%s' "$PAYLOAD" \
    | env PATH="$path" HOME="${HOME:-/tmp}" HQ_HOOK_TIMEOUT_SENTRY=0 \
        HQ_SAFETY_GUARD_TIMEOUT=2 CLAUDE_PROJECT_DIR="$FIX" \
        "$bash_bin" "$FIX/.claude/hooks/master-hook.sh" PreToolUse \
        >"$TMP/out" 2>"$TMP/err" || RC=$?
  ended="$(now_ms)"
  ELAPSED_MS=$((ended - started))
}

# 2 s cap + 2 s kill-after + master overhead. An unbounded guard takes >= 20 s.
BUDGET_MS=12000

assert_child_gone() { # <label> <pidfile>
  local pid
  [ -s "$2" ] || fail "$1: hook never started (no pid file); stderr=$(cat "$TMP/err")"
  pid="$(cat "$2")"
  sleep 1
  ! kill -0 "$pid" 2>/dev/null || fail "$1: child pid $pid survived the timeout"
  rm -f "$2"
}

for bash_bin in "${BASHES[@]}"; do
  bash_ver="$("$bash_bin" -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"')"
  for runner in "${RUNNERS[@]}"; do
    tag="bash $bash_ver, $runner runner"

    # ── 1. Slow safety guard blocks ─────────────────────────────────────────
    write_registry slow-guard slow-guard.sh 30 true
    run_master "$bash_bin" "$runner"
    [ "$RC" = "2" ] || fail "$tag: slow safety guard should block with exit 2, got $RC; stderr=$(cat "$TMP/err")"
    grep -q 'guard timed out, blocked' "$TMP/err" || fail "$tag: missing block reason; stderr=$(cat "$TMP/err")"
    grep -q 'slow-guard' "$TMP/err" || fail "$tag: block reason does not name the guard; stderr=$(cat "$TMP/err")"
    [ "$ELAPSED_MS" -lt "$BUDGET_MS" ] || fail "$tag: slow safety guard took ${ELAPSED_MS}ms (budget ${BUDGET_MS}ms)"
    ! grep -q 'slow hook finished' "$TMP/out" || fail "$tag: timed-out guard ran to completion"
    assert_child_gone "$tag slow safety guard" "$TMP/guard.pid"
    pass "$tag: slow safety guard blocked with exit 2 in ${ELAPSED_MS}ms"

    # ── 2. TERM-ignoring safety guard is killed and blocks ──────────────────
    write_registry stubborn-guard stubborn-guard.sh 30 true
    run_master "$bash_bin" "$runner"
    [ "$RC" = "2" ] || fail "$tag: TERM-ignoring safety guard should block with exit 2, got $RC; stderr=$(cat "$TMP/err")"
    grep -q 'guard timed out, blocked' "$TMP/err" || fail "$tag: missing block reason for TERM-ignoring guard"
    [ "$ELAPSED_MS" -lt "$BUDGET_MS" ] || fail "$tag: TERM-ignoring guard took ${ELAPSED_MS}ms (budget ${BUDGET_MS}ms)"
    assert_child_gone "$tag TERM-ignoring guard" "$TMP/stubborn.pid"
    pass "$tag: TERM-ignoring safety guard killed and blocked in ${ELAPSED_MS}ms"

    # ── 2b. Same two guards through the registry source runner ──────────────
    for g in slow-guard stubborn-guard; do
      pidfile="$TMP/guard.pid"
      [ "$g" = "stubborn-guard" ] && pidfile="$TMP/stubborn.pid"
      write_registry "$g" "$g.sh" 30 true source
      run_master "$bash_bin" "$runner"
      [ "$RC" = "2" ] || fail "$tag: source-runner $g should block with exit 2, got $RC; stderr=$(cat "$TMP/err")"
      grep -q 'guard timed out, blocked' "$TMP/err" || fail "$tag: source-runner $g missing block reason"
      [ "$ELAPSED_MS" -lt "$BUDGET_MS" ] || fail "$tag: source-runner $g took ${ELAPSED_MS}ms (budget ${BUDGET_MS}ms)"
      assert_child_gone "$tag source-runner $g" "$pidfile"
      pass "$tag: source-runner $g blocked in ${ELAPSED_MS}ms"
    done

    # ── 3. Slow non-safety hook stays non-blocking ──────────────────────────
    write_registry slow-advisory slow-advisory.sh 2 false
    run_master "$bash_bin" "$runner"
    [ "$RC" != "2" ] || fail "$tag: slow non-safety hook must not block; stderr=$(cat "$TMP/err")"
    ! grep -q 'guard timed out, blocked' "$TMP/err" || fail "$tag: non-safety hook printed the safety block reason"
    if [ "$runner" != "bash" ]; then
      # The plain-bash fallback has no bound for non-safety hooks; that is the
      # unchanged pre-existing behavior, so only assert timing where a runner exists.
      [ "$ELAPSED_MS" -lt "$BUDGET_MS" ] || fail "$tag: slow non-safety hook took ${ELAPSED_MS}ms"
      assert_child_gone "$tag slow non-safety hook" "$TMP/advisory.pid"
    else
      rm -f "$TMP/advisory.pid"
    fi
    pass "$tag: slow non-safety hook stayed non-blocking (exit $RC)"

    # ── 4. Fast safety guards keep their own verdicts ───────────────────────
    write_registry fast-deny fast-deny.sh 30 true
    run_master "$bash_bin" "$runner"
    [ "$RC" = "2" ] || fail "$tag: fast deny guard expected exit 2, got $RC"
    grep -q 'fixture guard denied' "$TMP/err" || fail "$tag: fast deny guard lost its reason"
    ! grep -q 'guard timed out' "$TMP/err" || fail "$tag: fast deny reported as a timeout"
    write_registry fast-allow fast-allow.sh 30 true
    run_master "$bash_bin" "$runner"
    [ "$RC" = "0" ] || fail "$tag: fast allow guard expected exit 0, got $RC; stderr=$(cat "$TMP/err")"
    pass "$tag: fast safety guards keep exit 2 and exit 0"

    # ── 4b. A spent shared budget blocks the next safety guard ──────────────
    # The slow non-safety hook uses about 2 s of a 1 s budget, so the safety
    # guard after it must block without running. The plain-bash fallback has
    # no bound for the non-safety hook, so it is skipped there.
    if [ "$runner" != "bash" ]; then
      jq -n '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[
          {id:"slow-advisory",script:".claude/hooks/slow-advisory.sh",timeout:2,gated:false,safety:false},
          {id:"fast-allow",script:".claude/hooks/fast-allow.sh",timeout:30,gated:false,safety:true}]}]}}' \
        > "$FIX/.claude/hooks/hook-registry.json"
      rm -rf "$FIX/workspace/orchestrator/hook-state/registry-rows"
      HQ_SAFETY_GUARD_TOTAL_BUDGET=1 run_master "$bash_bin" "$runner"
      [ "$RC" = "2" ] || fail "$tag: spent budget should block with exit 2, got $RC; stderr=$(cat "$TMP/err")"
      grep -q 'guard timed out, blocked: the safety-guard time budget was spent before fast-allow' "$TMP/err" \
        || fail "$tag: spent budget missing its reason; stderr=$(cat "$TMP/err")"
      rm -f "$TMP/advisory.pid"
      pass "$tag: spent shared budget blocked the next safety guard"
    fi
  done
done

# ── 5. The shipped registry marks the guards that must fail closed ─────────
for id in mandatory-scope-authorizer detect-secrets block-agent-secrets-reveal \
          block-env-dump block-core-writes-bash block-policy-writes-bash \
          enforce-vault-write-access block-hq-root-git-mutation \
          block-company-repo-creation block-unsafe-package-install \
          protect-core block-core-writes block-company-git-metadata; do
  n_all="$(jq --arg id "$id" '[.hooks.PreToolUse[]?.hooks[]? | select(.id == $id)] | length' "$ROOT/.claude/hooks/hook-registry.json")"
  n_safe="$(jq --arg id "$id" '[.hooks.PreToolUse[]?.hooks[]? | select(.id == $id and .safety == true)] | length' "$ROOT/.claude/hooks/hook-registry.json")"
  [ "$n_all" -gt 0 ] || fail "registry has no PreToolUse rows for $id"
  [ "$n_all" = "$n_safe" ] || fail "registry: $id has $n_all PreToolUse rows but only $n_safe marked safety:true"
done
pass "shipped registry marks every safety guard row safety:true"

echo "ALL PASS: master-hook-safety-guard-timeout"
exit 0
