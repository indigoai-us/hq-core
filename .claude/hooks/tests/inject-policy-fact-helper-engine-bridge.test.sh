#!/usr/bin/env bash
# hq-core: public
# The policy injector runs its fact helper through the hq-hook engine when
# master-hook exported a bridge plan that names derive-trigger-facts
# (windows-hook-parity US-008, flag hook-engine-port-derive-trigger-facts), and
# runs the shell helper exactly as before otherwise.
#
# A fixture HQ root carries the real injector, symlinks to the real
# core/scripts helpers, a stub derive-trigger-facts.sh that answers
# "always shellfact" and two policies: shell-probe fires on shellfact and
# engine-probe fires on enginefact. A stub hq-hook answers "always enginefact"
# in `on` mode and runs the shell helper in `shadow` mode, like the real engine.
#
# Sections:
#   [a] no exported plan: shell helper runs, engine never starts
#   [b] plan says on: engine answers, shell helper not run, argv and env checked
#   [c] plan says shadow: engine runs the shell helper; shell facts are used
#   [d] HQ_HOOK_ENGINE=off and ~/.hq/hook-engine.off: engine never starts
#   [e] plan without derive-trigger-facts, or a non-executable engine: no engine
#   [f] engine fault (70, 127, a signal): shell helper answers, engine tried once
#   [g] the helper's own failure (exit 1) through the engine is not re-run
#   [h] a helper that prints part of its answer and then dies inside the engine
#       (shadow passes its output and exit 141 through): the partial output is
#       dropped and the shell helper's facts are used once
#   [i] PostToolUse calls the helper from $(...) subshells; after a fault the
#       engine is not tried again in the same event
#   [j] a payload over the input-file limit keeps the shell helper
#   [k] no bridge output file is left behind
#   [l] a capture file that cannot be written keeps the shell helper
set -uo pipefail

TEST_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
HOOK_SOURCE="${HQ_INJECT_POLICY_TEST_HOOK:-$ROOT/.claude/hooks/inject-policy-on-trigger.sh}"
[ -f "$HOOK_SOURCE" ] || { echo "FAIL: hook source is missing: $HOOK_SOURCE" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "inject-policy-fact-helper-engine-bridge: skipped (jq missing)"; exit 0; }

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/inject-policy-engine-bridge.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
FIX="$TMP/hq"
FAKE_HOME="$TMP/home"
ENGINE_DIR="$TMP/engine"
ENGINE="$ENGINE_DIR/hq-hook"
ENGINE_LOG="$ENGINE_DIR/calls.log"
HELPER_LOG="$TMP/helper-calls.log"
mkdir -p "$FIX/.claude/hooks" "$FIX/core/scripts" "$FIX/core/policies" "$FIX/workspace" "$FAKE_HOME" "$ENGINE_DIR"

cp "$HOOK_SOURCE" "$FIX/.claude/hooks/inject-policy-on-trigger.sh"
for entry in "$ROOT"/core/scripts/*; do
  name="${entry##*/}"
  [ "$name" = "derive-trigger-facts.sh" ] && continue
  ln -s "$entry" "$FIX/core/scripts/$name"
done

# Stub shell helper: logs its argv and HQ_ROOT, answers one fact line, or two
# for a paired request, so the injector never needs a second launch.
cat > "$FIX/core/scripts/derive-trigger-facts.sh" <<HELPER
#!/usr/bin/env bash
payload="\$(cat)"
printf '%s hq_root=%s stdin=%s\n' "\$*" "\${HQ_ROOT:-unset}" "\${#payload}" >> "$HELPER_LOG"
[ ! -f "$TMP/helper-rc" ] || exit "\$(cat "$TMP/helper-rc")"
# First call only: print a partial answer and die of SIGPIPE, the way a helper
# inside the engine can fail after writing.
if [ -f "$TMP/helper-partial" ]; then
  rm -f "$TMP/helper-partial"
  printf '%s\n' "always partialfact"
  exit 141
fi
if [ "\${2:-}" = "--with-assistant-intent" ]; then
  printf '%s\n%s\n' "always shellfact" "always"
else
  printf '%s\n' "always shellfact"
fi
HELPER
chmod +x "$FIX/core/scripts/derive-trigger-facts.sh"

for probe in shell engine partial; do
  cat > "$FIX/core/policies/$probe-probe.md" <<POLICY
---
id: $probe-probe
when: ${probe}fact
on: [UserPromptSubmit]
enforcement: soft
version: 1
---

## Rule

Fixture policy that fires on the $probe fact.
POLICY
done

# Stub engine. `on` answers with engine facts; `shadow` runs the script it was
# given on the same stdin and returns its result, as hq-hook does.
cat > "$ENGINE" <<STUB
#!/usr/bin/env bash
payload="\$(cat)"
printf '%s hq_root=%s stdin=%s\n' "\$*" "\${HQ_ROOT:-unset}" "\${#payload}" >> "$ENGINE_LOG"
if [ -f "$ENGINE_DIR/rc" ]; then
  rc="\$(cat "$ENGINE_DIR/rc")"
  # Partial output before the fault: it must never reach the facts.
  printf '%s\n' "always enginefact"
  [ "\$rc" != "signal" ] || kill -9 \$\$
  exit "\$rc"
fi
mode=""
script=""
args=()
shift 2
while [ \$# -gt 0 ]; do
  case "\$1" in
    --mode) mode="\$2"; shift 2 ;;
    --script) script="\$2"; shift 2 ;;
    --event|--timeout) shift 2 ;;
    --) shift; args=("\$@"); break ;;
    *) shift ;;
  esac
done
if [ "\$mode" = "shadow" ]; then
  printf '%s' "\$payload" | bash "\$script" "\${args[@]}"
  exit "\${PIPESTATUS[1]}"
fi
if [ "\${args[1]:-}" = "--with-assistant-intent" ]; then
  printf '%s\n%s\n' "always enginefact" "always"
else
  printf '%s\n' "always enginefact"
fi
STUB
chmod +x "$ENGINE"

TAB="$(printf '\t')"
# Over the injector's 64 KiB input-file limit.
BIG_PROMPT="$(printf '%070000d' 0)"
SESSION=0
reset() {
  rm -f "$ENGINE_LOG" "$HELPER_LOG" "$ENGINE_DIR/rc" "$TMP/helper-rc" "$TMP/helper-partial" "$FAKE_HOME/.hq/hook-engine.off"
  chmod +x "$ENGINE"
}
# run [ENV=VALUE ...] — one UserPromptSubmit through the injector, fresh session.
run() {
  local payload
  SESSION=$((SESSION + 1))
  case "${RUN_EVENT:-UserPromptSubmit}" in
    PostToolUse) payload="$(jq -cn --arg cwd "$FIX" --arg sid "engine-bridge-$SESSION" \
      '{hook_event_name:"PostToolUse",session_id:$sid,tool_name:"Bash",tool_input:{command:"ls -la"},tool_response:{stdout:"total 0",stderr:"",interrupted:false},cwd:$cwd}')" ;;
    big) payload="$(jq -cn --arg cwd "$FIX" --arg sid "engine-bridge-$SESSION" --arg p "$BIG_PROMPT" \
      '{hook_event_name:"UserPromptSubmit",session_id:$sid,prompt:("hello there " + $p),cwd:$cwd}')" ;;
    *) payload="$(jq -cn --arg cwd "$FIX" --arg sid "engine-bridge-$SESSION" \
      '{hook_event_name:"UserPromptSubmit",session_id:$sid,prompt:"hello there",cwd:$cwd}')" ;;
  esac
  RC=0
  printf '%s' "$payload" | (cd "$FIX" && env -u HQ_HOOK_ENGINE -u HQ_HOOK_BRIDGE_PLAN -u HQ_HOOK_BRIDGE_BIN \
    -u BASH_ENV -u ENV -u HQ_POLICY_WORKER_DIR \
    HOME="$FAKE_HOME" XDG_STATE_HOME="$FAKE_HOME/.local/state" HQ_ROOT="$FIX" CLAUDE_PROJECT_DIR="$FIX" \
    HQ_HOOK_PROFILE=standard HQ_HOOK_TIMEOUT_SENTRY=0 HQ_POLICY_FACT_HELPER_DISABLE=1 \
    HQ_POLICY_COMPANY= HQ_COMPANY_SLUG= \
    "$@" bash "$FIX/.claude/hooks/inject-policy-on-trigger.sh") >"$TMP/out" 2>"$TMP/err" || RC=$?
}
plan_on() { printf 'derive-trigger-facts%son' "$TAB"; }
plan_shadow() { printf 'some-hook%son\nderive-trigger-facts%sshadow' "$TAB" "$TAB"; }
count() { [ -f "$1" ] && grep -c . "$1" || echo 0; }
out_has() { grep -qF "$1" "$TMP/out"; }

echo "[a] no exported plan: shell helper only"
reset
run
[ "$RC" = "0" ] && ok "rc 0" || bad "rc=$RC err=$(head -c 300 "$TMP/err")"
[ "$(count "$ENGINE_LOG")" = "0" ] && ok "engine never started" || bad "engine ran: $(cat "$ENGINE_LOG")"
[ "$(count "$HELPER_LOG")" = "1" ] && ok "shell helper ran once" || bad "helper calls: $(count "$HELPER_LOG")"
out_has 'shell-probe' && ! out_has 'engine-probe' && ok "shell facts drove the reminder" \
  || bad "out=$(head -c 400 "$TMP/out")"

echo "[b] plan says on: engine answers"
reset
run HQ_HOOK_BRIDGE_BIN="$ENGINE" HQ_HOOK_BRIDGE_PLAN="$(plan_on)"
[ "$RC" = "0" ] && ok "rc 0" || bad "rc=$RC err=$(head -c 300 "$TMP/err")"
[ "$(count "$HELPER_LOG")" = "0" ] && ok "shell helper not run" || bad "helper ran: $(cat "$HELPER_LOG")"
expected="bridge derive-trigger-facts --mode on --event UserPromptSubmit --timeout 20 --script $FIX/core/scripts/derive-trigger-facts.sh -- UserPromptSubmit --with-assistant-intent hq_root=$FIX stdin="
if [ "$(count "$ENGINE_LOG")" = "1" ] && grep -qF "$expected" "$ENGINE_LOG" && ! grep -q 'stdin=0$' "$ENGINE_LOG"; then
  ok "one paired engine call with the payload and HQ_ROOT"
else
  bad "engine calls: $(cat "$ENGINE_LOG" 2>/dev/null)"
fi
out_has 'engine-probe' && ! out_has 'shell-probe' && ok "engine facts drove the reminder" \
  || bad "out=$(head -c 400 "$TMP/out")"

echo "[c] plan says shadow: engine runs the shell helper"
reset
run HQ_HOOK_BRIDGE_BIN="$ENGINE" HQ_HOOK_BRIDGE_PLAN="$(plan_shadow)"
[ "$(count "$ENGINE_LOG")" = "1" ] && grep -q -- '--mode shadow' "$ENGINE_LOG" && ok "one shadow engine call" \
  || bad "engine calls: $(cat "$ENGINE_LOG" 2>/dev/null)"
[ "$(count "$HELPER_LOG")" = "1" ] && ok "shell helper ran once, inside the engine" || bad "helper calls: $(count "$HELPER_LOG")"
out_has 'shell-probe' && ! out_has 'engine-probe' && ok "shell facts returned" || bad "out=$(head -c 400 "$TMP/out")"

echo "[d] kill switch"
reset
run HQ_HOOK_BRIDGE_BIN="$ENGINE" HQ_HOOK_BRIDGE_PLAN="$(plan_on)" HQ_HOOK_ENGINE=OFF
[ "$(count "$ENGINE_LOG")" = "0" ] && [ "$(count "$HELPER_LOG")" = "1" ] && out_has 'shell-probe' \
  && ok "HQ_HOOK_ENGINE=OFF: engine never started" || bad "env kill switch: engine=$(count "$ENGINE_LOG") helper=$(count "$HELPER_LOG")"
reset
mkdir -p "$FAKE_HOME/.hq"
: > "$FAKE_HOME/.hq/hook-engine.off"
run HQ_HOOK_BRIDGE_BIN="$ENGINE" HQ_HOOK_BRIDGE_PLAN="$(plan_on)"
[ "$(count "$ENGINE_LOG")" = "0" ] && [ "$(count "$HELPER_LOG")" = "1" ] \
  && ok "~/.hq/hook-engine.off: engine never started" || bad "file kill switch: engine=$(count "$ENGINE_LOG")"

echo "[e] plan without the helper, or an engine that cannot run"
reset
run HQ_HOOK_BRIDGE_BIN="$ENGINE" HQ_HOOK_BRIDGE_PLAN="$(printf 'some-hook%son' "$TAB")"
[ "$(count "$ENGINE_LOG")" = "0" ] && [ "$(count "$HELPER_LOG")" = "1" ] \
  && ok "helper not in plan: engine never started" || bad "engine=$(count "$ENGINE_LOG")"
reset
run HQ_HOOK_BRIDGE_BIN="$ENGINE" HQ_HOOK_BRIDGE_PLAN="$(printf 'derive-trigger-facts%smaybe' "$TAB")"
[ "$(count "$ENGINE_LOG")" = "0" ] && ok "unknown mode: engine never started" || bad "engine=$(count "$ENGINE_LOG")"
reset
chmod -x "$ENGINE"
run HQ_HOOK_BRIDGE_BIN="$ENGINE" HQ_HOOK_BRIDGE_PLAN="$(plan_on)"
[ "$(count "$HELPER_LOG")" = "1" ] && out_has 'shell-probe' && ok "non-executable engine: shell helper" \
  || bad "helper=$(count "$HELPER_LOG")"
reset
run HQ_HOOK_BRIDGE_BIN="$ENGINE_DIR" HQ_HOOK_BRIDGE_PLAN="$(plan_on)"
[ "$(count "$HELPER_LOG")" = "1" ] && ok "directory as engine: shell helper" || bad "helper=$(count "$HELPER_LOG")"

echo "[f] engine faults fall back to the shell helper"
for fault in 70 127 signal; do
  reset
  printf '%s\n' "$fault" > "$ENGINE_DIR/rc"
  run HQ_HOOK_BRIDGE_BIN="$ENGINE" HQ_HOOK_BRIDGE_PLAN="$(plan_on)"
  [ "$RC" = "0" ] && [ "$(count "$ENGINE_LOG")" = "1" ] && [ "$(count "$HELPER_LOG")" = "1" ] \
    && out_has 'shell-probe' && ! out_has 'engine-probe' \
    && ok "engine $fault: shell helper answered, engine tried once" \
    || bad "engine $fault: rc=$RC engine=$(count "$ENGINE_LOG") helper=$(count "$HELPER_LOG") out=$(head -c 300 "$TMP/out")"
done

echo "[g] the helper's own failure is not re-run"
reset
printf '1\n' > "$ENGINE_DIR/rc"
run HQ_HOOK_BRIDGE_BIN="$ENGINE" HQ_HOOK_BRIDGE_PLAN="$(plan_on)"
[ "$RC" = "0" ] && [ "$(count "$HELPER_LOG")" = "0" ] && ! out_has 'shell-probe' \
  && ok "exit 1 through the engine: shell helper not run" \
  || bad "exit 1: rc=$RC helper=$(count "$HELPER_LOG") out=$(head -c 300 "$TMP/out")"

echo "[h] a helper that fails after printing inside the engine: facts printed once"
reset
: > "$TMP/helper-partial"
run HQ_HOOK_BRIDGE_BIN="$ENGINE" HQ_HOOK_BRIDGE_PLAN="$(plan_shadow)"
[ "$RC" = "0" ] && [ "$(count "$ENGINE_LOG")" = "1" ] && [ "$(count "$HELPER_LOG")" = "2" ] \
  && out_has 'shell-probe' && ! out_has 'partial-probe' \
  && ok "partial output dropped, shell helper answered once more" \
  || bad "partial: rc=$RC engine=$(count "$ENGINE_LOG") helper=$(count "$HELPER_LOG") out=$(head -c 300 "$TMP/out")"

echo "[i] PostToolUse: after a fault the engine is not tried again in the same event"
reset
printf '70\n' > "$ENGINE_DIR/rc"
RUN_EVENT=PostToolUse run HQ_HOOK_BRIDGE_BIN="$ENGINE" HQ_HOOK_BRIDGE_PLAN="$(plan_on)"
helper_calls="$(count "$HELPER_LOG")"
[ "$RC" = "0" ] && [ "$(count "$ENGINE_LOG")" = "1" ] && [ "$helper_calls" -ge 2 ] \
  && ok "engine tried once, shell helper answered all $helper_calls calls" \
  || bad "PostToolUse fault: rc=$RC engine=$(count "$ENGINE_LOG") helper=$helper_calls err=$(head -c 300 "$TMP/err")"
reset
RUN_EVENT=PostToolUse run HQ_HOOK_BRIDGE_BIN="$ENGINE" HQ_HOOK_BRIDGE_PLAN="$(plan_on)"
[ "$RC" = "0" ] && [ "$(count "$HELPER_LOG")" = "0" ] && [ "$(count "$ENGINE_LOG")" -ge 2 ] \
  && ok "PostToolUse on: every helper call through the engine" \
  || bad "PostToolUse on: rc=$RC engine=$(count "$ENGINE_LOG") helper=$(count "$HELPER_LOG")"

echo "[j] a payload over the input-file limit keeps the shell helper"
reset
RUN_EVENT=big run HQ_HOOK_BRIDGE_BIN="$ENGINE" HQ_HOOK_BRIDGE_PLAN="$(plan_on)"
[ "$RC" = "0" ] && [ "$(count "$ENGINE_LOG")" = "0" ] && [ "$(count "$HELPER_LOG")" = "1" ] \
  && ok "large payload: engine not started" \
  || bad "large payload: rc=$RC engine=$(count "$ENGINE_LOG") helper=$(count "$HELPER_LOG")"

echo "[l] a capture file that cannot be written keeps the shell helper"
reset
STATE_DIR="$FIX/workspace/orchestrator/hook-state"
mkdir -p "$STATE_DIR"
chmod 555 "$STATE_DIR"
run HQ_HOOK_BRIDGE_BIN="$ENGINE" HQ_HOOK_BRIDGE_PLAN="$(plan_on)"
chmod 755 "$STATE_DIR"
[ "$RC" = "0" ] && [ "$(count "$ENGINE_LOG")" = "0" ] && [ "$(count "$HELPER_LOG")" -ge 1 ] && out_has 'shell-probe' \
  && ok "read-only hook-state: shell helper answered, engine not started" \
  || bad "read-only hook-state: rc=$RC engine=$(count "$ENGINE_LOG") helper=$(count "$HELPER_LOG") out=$(head -c 300 "$TMP/out")"

echo "[k] bridge output files are removed at exit"
leftover="$(find "$FIX/workspace" -name '.policy-trigger-bridge.*' | head -3)"
[ -z "$leftover" ] && ok "no .policy-trigger-bridge files left" || bad "left behind: $leftover"

if [ "$fail" -eq 0 ]; then
  echo "ALL PASS: inject-policy-fact-helper-engine-bridge ($pass)"
  exit 0
fi
echo "FAILURES: inject-policy-fact-helper-engine-bridge ($fail failed, $pass passed)" >&2
exit 1
