#!/usr/bin/env bash
# hq-core: public
# advisory-hook-hard-cap.test.sh
#
# Pins the shared advisory-hook hard cap (core/scripts/lib/advisory-cap.sh):
#   1. master-hook: a slow advisory registry hook that ignores SIGTERM ends at
#      its registry timeout plus the kill grace, exits 0, prints none of its
#      output, and its child process is gone.
#   2. Codex adapter: the same hook through hq-codex-hook-adapter.sh is cut at
#      its registry timeout and fails open with no output.
#   3. HQ_HOOK_ADVISORY_CAP=0 restores the old behaviour (the hook runs on).
#   4. A PreToolUse guard is never capped (master-hook and adapter).
#   5. Journal rows carry exit code, timed_out flag and load average.
#   6. The cap's grace loop ends as soon as the hook has exited on SIGTERM
#      instead of always waiting the full grace; a hook that ignores SIGTERM
#      is still killed when the grace runs out.
#      Both runners still work on a perl without POSIX.pm.
#   7. The capped Codex path repairs a hook that lost its exec bit, the same
#      way the uncapped launcher does, and still caps it.
# HQ_TEST_SOURCE_ROOT points the fixture at another checkout (used to show the
# test fails on the base branch).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SOURCE_ROOT="${HQ_TEST_SOURCE_ROOT:-$ROOT}"

FAILS=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }
pass() { printf '  ok: %s\n' "$*"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "SKIP: perl required (test timing)"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/advisory-cap.XXXXXX")"
cleanup() {
  local f pid
  for f in "$TMP"/*.pid; do
    [ -f "$f" ] || continue
    pid="$(cat "$f" 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -KILL "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

now_ms() { perl -MTime::HiRes=time -e 'printf "%.0f", time() * 1000'; }

FIX="$TMP/root"
mkdir -p "$FIX/.claude/hooks" "$FIX/.codex/hooks" "$FIX/core/scripts/lib" "$FIX/core/hooks" "$FIX/workspace"
for rel in .claude/hooks/master-hook.sh .claude/hooks/hook-gate.sh .claude/hooks/hook-timeout-probe.sh \
  .claude/hooks/hook-timeout-watchdog.sh core/scripts/lib/hook-adapter-core.sh core/scripts/hook-lib.sh \
  core/scripts/lib/trigger-fact-text.awk .codex/hooks/hq-codex-hook-adapter.sh core/scripts/lib/advisory-cap.sh; do
  [ -f "$SOURCE_ROOT/$rel" ] || continue
  cp "$SOURCE_ROOT/$rel" "$FIX/$rel"
done
chmod +x "$FIX/.claude/hooks/"*.sh "$FIX/.codex/hooks/"*.sh
printf '{"hooks":{}}\n' > "$FIX/.claude/settings.json"

# Slow hook: prints output, ignores TERM, waits on a 30 s child.
write_slow() { # <path> <pidfile> <seconds>
  cat > "$1" <<SH
#!/usr/bin/env bash
trap '' TERM
cat >/dev/null
echo "slow hook output"
sleep $3 &
printf '%s' "\$!" > "$2"
wait
echo "slow hook finished"
exit 0
SH
  chmod +x "$1"
}
write_slow "$FIX/.claude/hooks/slow-advisory.sh" "$TMP/advisory.pid" 30
write_slow "$FIX/.claude/hooks/slow-guard.sh" "$TMP/guard.pid" 9

write_registry() { # <event> <id> <script> <timeout>
  jq -n --arg ev "$1" --arg id "$2" --arg script ".claude/hooks/$3" --argjson t "$4" \
    '{hooks:{($ev):[{matcher:(if $ev == "PreToolUse" then "Bash" else "*" end),hooks:[{id:$id,script:$script,timeout:$t,gated:true}]}]}}' \
    > "$FIX/.claude/hooks/hook-registry.json"
  rm -rf "$FIX/workspace/orchestrator/hook-state/registry-rows"
}

prompt_payload() {
  jq -nc --arg cwd "$FIX" --arg sid "$1" '{hook_event_name:"UserPromptSubmit",session_id:$sid,cwd:$cwd,prompt:"hello"}'
}
bash_payload() {
  jq -nc --arg cwd "$FIX" --arg sid "$1" '{hook_event_name:"PreToolUse",session_id:$sid,cwd:$cwd,tool_name:"Bash",tool_input:{command:"ls"}}'
}

run_master() { # <event> <payload> [extra env...]
  local event="$1" payload="$2" started
  shift 2
  RC=0
  started="$(now_ms)"
  printf '%s' "$payload" | env HOME="$TMP/home" CLAUDE_PROJECT_DIR="$FIX" HQ_HOOK_TIMEOUT_SENTRY=1 \
    HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE="$TMP/never" "$@" \
    bash "$FIX/.claude/hooks/master-hook.sh" "$event" >"$TMP/out" 2>"$TMP/err" || RC=$?
  ELAPSED_MS=$(($(now_ms) - started))
}

run_codex() { # <payload> [extra env...]
  local payload="$1" started
  shift
  RC=0
  started="$(now_ms)"
  printf '%s' "$payload" | env HOME="$TMP/home" HQ_ROOT="$FIX" CLAUDE_PROJECT_DIR="$FIX" HQ_HOOK_TIMEOUT_SENTRY=1 \
    HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE="$TMP/never" BASH_ENV=/dev/null "$@" \
    bash "$FIX/.codex/hooks/hq-codex-hook-adapter.sh" >"$TMP/out" 2>"$TMP/err" || RC=$?
  ELAPSED_MS=$(($(now_ms) - started))
}

child_gone() { # <pidfile>
  local pid
  [ -s "$1" ] || return 1
  pid="$(cat "$1")"
  sleep 0.5
  rm -f "$1"
  ! kill -0 "$pid" 2>/dev/null
}

kill_pidfile() {
  local pid
  [ -s "$1" ] || return 0
  pid="$(cat "$1")"
  kill -KILL "$pid" 2>/dev/null || true
  rm -f "$1"
}

journal_last_row() { # <session-id> -> last journal line for that session
  local hash
  hash="$(printf '%s\0' "$1" | { shasum -a 256 2>/dev/null || sha256sum; } | cut -d' ' -f1)"
  tail -n 1 "$FIX/workspace/.hook-timeout-journal/$hash.tsv" 2>/dev/null || true
}

mkdir -p "$TMP/home"

# 2 s registry timeout + 2 s grace + dispatcher overhead. Uncapped: 30 s.
CAP_BUDGET_MS=9000

# ── 1. master-hook caps the advisory hook ─────────────────────────────────
write_registry UserPromptSubmit inject-policy-on-trigger slow-advisory.sh 2
run_master UserPromptSubmit "$(prompt_payload cap-master-1)"
if [ "$ELAPSED_MS" -lt "$CAP_BUDGET_MS" ] && [ "$RC" = "0" ] \
  && ! grep -q 'slow hook' "$TMP/out" && child_gone "$TMP/advisory.pid"; then
  pass "master-hook capped advisory hook in ${ELAPSED_MS}ms, rc 0, no output"
else
  fail "master-hook: rc=$RC elapsed=${ELAPSED_MS}ms out=$(head -c 200 "$TMP/out")"
  kill_pidfile "$TMP/advisory.pid"
fi
row="$(journal_last_row cap-master-1)"
IFS=$'\t' read -r j_script j_event j_ms j_inv j_rc j_to j_load <<<"$row" || true
if [ "${j_script:-}" = "slow-advisory.sh" ] && [ "${j_to:-}" = "1" ] && [[ "${j_rc:-}" =~ ^(124|137|142)$ ]] \
  && [[ "${j_load:-}" =~ ^([0-9.]+|-)$ ]] && [ -n "${j_inv:-}" ] && [ -n "${j_ms:-}" ] && [ -n "${j_event:-}" ]; then
  pass "master-hook journal row has rc=$j_rc timed_out=1 load1=$j_load"
else
  fail "master-hook journal row missing new fields: '$row'"
fi

# ── 2. Codex adapter caps the advisory hook ───────────────────────────────
run_codex "$(prompt_payload cap-codex-1)"
if [ "$ELAPSED_MS" -lt "$CAP_BUDGET_MS" ] && [ "$RC" = "0" ] \
  && ! grep -q 'slow hook' "$TMP/out" && child_gone "$TMP/advisory.pid"; then
  pass "codex adapter capped advisory hook in ${ELAPSED_MS}ms, rc 0, no output"
else
  fail "codex adapter: rc=$RC elapsed=${ELAPSED_MS}ms out=$(head -c 200 "$TMP/out") err=$(head -c 300 "$TMP/err")"
  kill_pidfile "$TMP/advisory.pid"
fi
row="$(journal_last_row cap-codex-1)"
IFS=$'\t' read -r j_script j_event j_ms j_inv j_rc j_to j_load <<<"$row" || true
if [ "${j_script:-}" = "slow-advisory.sh" ] && [ "${j_to:-}" = "1" ] && [ "${j_rc:-}" = "124" ] \
  && [[ "${j_load:-}" =~ ^([0-9.]+|-)$ ]]; then
  pass "codex adapter journal row has rc=124 timed_out=1 load1=$j_load"
else
  fail "codex adapter journal row missing new fields: '$row'"
fi

# ── 3. Kill switch restores the old behaviour ─────────────────────────────
# The slow hook runs 5 s here so the uncapped run stays short.
write_slow "$FIX/.claude/hooks/slow-advisory.sh" "$TMP/advisory.pid" 5
write_registry UserPromptSubmit inject-policy-on-trigger slow-advisory.sh 1
run_master UserPromptSubmit "$(prompt_payload cap-off-1)" HQ_HOOK_ADVISORY_CAP=0
if [ "$ELAPSED_MS" -ge 4500 ]; then
  pass "master-hook with HQ_HOOK_ADVISORY_CAP=0 ran uncapped (${ELAPSED_MS}ms)"
else
  fail "master-hook kill switch: expected >= 4500ms, got ${ELAPSED_MS}ms"
fi
kill_pidfile "$TMP/advisory.pid"
run_codex "$(prompt_payload cap-off-2)" HQ_HOOK_ADVISORY_CAP=0
if [ "$ELAPSED_MS" -ge 4500 ] && grep -q 'slow hook finished' "$TMP/out"; then
  pass "codex adapter with HQ_HOOK_ADVISORY_CAP=0 ran uncapped (${ELAPSED_MS}ms)"
else
  fail "codex kill switch: expected >= 4500ms and full output, got ${ELAPSED_MS}ms out=$(head -c 200 "$TMP/out")"
fi
kill_pidfile "$TMP/advisory.pid"

# ── 4. A PreToolUse guard is never capped ─────────────────────────────────
# Guard sleeps 9 s, ignores TERM, registry timeout 3 s (long enough for the
# guard to install its TERM trap on a loaded host). A cap would end it near
# 5 s (3 s + 2 s grace); uncapped it runs its full 9 s.
write_registry PreToolUse block-unsafe-package-install slow-guard.sh 3
run_master PreToolUse "$(bash_payload guard-master-1)"
if [ "$ELAPSED_MS" -ge 7500 ]; then
  pass "master-hook left the PreToolUse guard uncapped (${ELAPSED_MS}ms)"
else
  fail "master-hook capped a PreToolUse guard (${ELAPSED_MS}ms)"
fi
kill_pidfile "$TMP/guard.pid"
run_codex "$(bash_payload guard-codex-1)"
if [ "$ELAPSED_MS" -ge 7500 ]; then
  pass "codex adapter left the PreToolUse guard uncapped (${ELAPSED_MS}ms, rc $RC)"
else
  fail "codex adapter capped a PreToolUse guard (${ELAPSED_MS}ms)"
fi
kill_pidfile "$TMP/guard.pid"

# ── 5. Fast advisory output passes through unchanged ──────────────────────
cat > "$FIX/.claude/hooks/fast-advisory.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
echo "fast advisory context"
SH
chmod +x "$FIX/.claude/hooks/fast-advisory.sh"
write_registry UserPromptSubmit inject-policy-on-trigger fast-advisory.sh 5
run_master UserPromptSubmit "$(prompt_payload fast-master-1)"
if [ "$RC" = "0" ] && grep -q 'fast advisory context' "$TMP/out"; then
  pass "master-hook passes fast advisory output"
else
  fail "master-hook fast advisory: rc=$RC out=$(head -c 200 "$TMP/out")"
fi
run_codex "$(prompt_payload fast-codex-1)"
if [ "$RC" = "0" ] && grep -q 'fast advisory context' "$TMP/out"; then
  pass "codex adapter passes fast advisory output"
else
  fail "codex fast advisory: rc=$RC out=$(head -c 200 "$TMP/out")"
fi

# ── 6. Grace loop ends when the hook is gone ─────────────────────────────
# Run hq_run_capped directly with its perl runner and a 5 s grace. A hook that
# exits on SIGTERM must end near the 1 s cap. Before the fix the unreaped hook
# kept its process group alive on Linux, so the loop waited the full grace
# (about 6 s). This timing check catches that bug only on Linux: macOS does
# not keep an unreaped child in its process group, so the old loop ended
# early there too. The Linux CI job is the regression check for it; on macOS
# the check still bounds the run time.
cat > "$TMP/term-ok.sh" <<'SH'
#!/usr/bin/env bash
exec sleep 30
SH
cat > "$TMP/term-ignored.sh" <<SH
#!/usr/bin/env bash
trap '' TERM
sleep 30 &
printf '%s' "\$!" > "$TMP/ignored.pid"
wait
SH
chmod +x "$TMP/term-ok.sh" "$TMP/term-ignored.sh"
run_capped_direct() { # <kill-after> <hook>
  local started
  started="$(now_ms)"
  HQ_HOOK_ADVISORY_CAP_KILL_AFTER="$1" bash -c '
    . "$1/core/scripts/lib/advisory-cap.sh"
    uname() { printf "Linux\n"; }
    hq_run_capped 1 "$2" </dev/null >/dev/null
    printf "%s %s" "$HQ_RUN_CAPPED_RC" "$HQ_RUN_CAPPED_TIMED_OUT"
  ' capped "$FIX" "$2" > "$TMP/direct.out" 2>/dev/null || true
  ELAPSED_MS=$(($(now_ms) - started))
}
run_capped_direct 5 "$TMP/term-ok.sh"
if [ "$(cat "$TMP/direct.out")" = "124 1" ] && [ "$ELAPSED_MS" -lt 3500 ]; then
  pass "grace loop ended once the hook exited on TERM (${ELAPSED_MS}ms with a 5 s grace; catches the old bug on Linux only)"
else
  fail "grace loop: out='$(cat "$TMP/direct.out")' elapsed=${ELAPSED_MS}ms (want 124 1 and < 3500ms)"
fi
run_capped_direct 1 "$TMP/term-ignored.sh"
if [ "$(cat "$TMP/direct.out")" = "124 1" ] && [ "$ELAPSED_MS" -ge 1800 ] && [ "$ELAPSED_MS" -lt 6000 ] \
  && child_gone "$TMP/ignored.pid"; then
  pass "a hook that ignores TERM is still killed after the grace (${ELAPSED_MS}ms)"
else
  fail "grace kill: out='$(cat "$TMP/direct.out")' elapsed=${ELAPSED_MS}ms"
  kill_pidfile "$TMP/ignored.pid"
fi
# master-hook's per-child perl runner has the same loop (fixed 0.5 s grace).
awk '/^child_timeout_perl_program=/{c=1; sub(/^child_timeout_perl_program=./, ""); print; next}
  c && /^'"'"'$/ {exit} c {print}' "$FIX/.claude/hooks/master-hook.sh" > "$TMP/child-runner.pl"
if [ -s "$TMP/child-runner.pl" ]; then
  started="$(now_ms)"
  rc=0
  perl "$TMP/child-runner.pl" 1 "" "$TMP/term-ignored.sh" </dev/null >/dev/null 2>&1 || rc=$?
  ELAPSED_MS=$(($(now_ms) - started))
  if [ "$rc" = "142" ] && [ "$ELAPSED_MS" -lt 4000 ] && child_gone "$TMP/ignored.pid"; then
    pass "master-hook child runner still kills a hook that ignores TERM (rc 142, ${ELAPSED_MS}ms)"
  else
    fail "master-hook child runner: rc=$rc elapsed=${ELAPSED_MS}ms"
    kill_pidfile "$TMP/ignored.pid"
  fi
else
  fail "could not extract child_timeout_perl_program from master-hook.sh"
fi

# A perl without POSIX.pm: a POSIX.pm that dies stands in for the missing
# module. The cap must still kill a TERM-ignoring hook and report a timeout
# (124 and 142), not die in its handler with exit 2 (a block code).
mkdir -p "$TMP/no-posix"
printf 'die "POSIX unavailable\\n";\n' > "$TMP/no-posix/POSIX.pm"
started="$(now_ms)"
PERL5LIB="$TMP/no-posix" HQ_HOOK_ADVISORY_CAP_KILL_AFTER=1 bash -c '
  . "$1/core/scripts/lib/advisory-cap.sh"
  uname() { printf "Linux\n"; }
  hq_run_capped 1 "$2" </dev/null >/dev/null
  printf "%s %s" "$HQ_RUN_CAPPED_RC" "$HQ_RUN_CAPPED_TIMED_OUT"
' capped "$FIX" "$TMP/term-ignored.sh" > "$TMP/direct.out" 2>/dev/null || true
ELAPSED_MS=$(($(now_ms) - started))
if [ "$(cat "$TMP/direct.out")" = "124 1" ] && [ "$ELAPSED_MS" -lt 6000 ] && child_gone "$TMP/ignored.pid"; then
  pass "cap runner without POSIX.pm still kills a TERM-ignoring hook (${ELAPSED_MS}ms)"
else
  fail "cap runner without POSIX.pm: out='$(cat "$TMP/direct.out")' elapsed=${ELAPSED_MS}ms"
  kill_pidfile "$TMP/ignored.pid"
fi
if [ -s "$TMP/child-runner.pl" ]; then
  rc=0
  PERL5LIB="$TMP/no-posix" perl "$TMP/child-runner.pl" 1 "" "$TMP/term-ignored.sh" </dev/null >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "142" ] && child_gone "$TMP/ignored.pid"; then
    pass "master-hook child runner without POSIX.pm still kills a TERM-ignoring hook (rc 142)"
  else
    fail "master-hook child runner without POSIX.pm: rc=$rc"
    kill_pidfile "$TMP/ignored.pid"
  fi
fi

# ── 7. Capped Codex path repairs the exec bit ─────────────────────────────
write_slow "$FIX/.claude/hooks/slow-advisory.sh" "$TMP/advisory.pid" 30
chmod a-x "$FIX/.claude/hooks/slow-advisory.sh"
write_registry UserPromptSubmit inject-policy-on-trigger slow-advisory.sh 2
run_codex "$(prompt_payload repair-codex-1)"
if [ -x "$FIX/.claude/hooks/slow-advisory.sh" ] && [ "$ELAPSED_MS" -lt "$CAP_BUDGET_MS" ] && [ "$RC" = "0" ] \
  && ! grep -q 'slow hook' "$TMP/out" && child_gone "$TMP/advisory.pid"; then
  pass "capped codex path restored the exec bit and still capped the hook (${ELAPSED_MS}ms)"
else
  fail "capped codex repair: exec=$([ -x "$FIX/.claude/hooks/slow-advisory.sh" ] && echo yes || echo no) rc=$RC elapsed=${ELAPSED_MS}ms out=$(head -c 200 "$TMP/out")"
  kill_pidfile "$TMP/advisory.pid"
fi

if [ "$FAILS" -gt 0 ]; then
  echo "advisory-hook-hard-cap: $FAILS failure(s)"
  exit 1
fi
echo "advisory-hook-hard-cap: all checks passed"
