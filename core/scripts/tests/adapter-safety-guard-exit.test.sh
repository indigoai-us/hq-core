#!/usr/bin/env bash
# hq-core: public
# adapter-safety-guard-exit.test.sh
#
# Pins the safety-guard exit rule on the Codex and Grok adapter paths (the
# Windows launcher hq-codex-hook.cmd passes the Codex adapter's exit code on).
# A PreToolUse registry guard marked "safety": true allows only with exit 0.
# Exit 2 is its own block. Exit 1, a signal death (SIGSEGV, 139) or any other
# code (5) blocks with master-hook's reason: "guard crashed, blocked" or
# "guard failed, blocked".
#
# Before: the Codex adapter exited with the guard's own status, and Codex
# treats any exit but 2 as a non-blocking error, so a crashed or odd-exit
# safety guard let the tool call run. A non-safety guard keeps its old result
# on both adapters (Codex passes exit 1 on; Grok denies any non-zero exit).
# A safety guard whose script is missing blocks on both adapters with a
# repair message; a missing non-safety guard is still skipped.
# The fixture registry row uses the id mandatory-scope-authorizer, so the hook
# profile gate runs it, with a stub script in place of the real guard.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/../../.." && pwd -P)"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/adapter-safety-exit.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
FIX="$(cd "$TMP" && pwd -P)/root"
mkdir -p "$FIX/.codex/hooks" "$FIX/.grok/hooks" "$FIX/.claude/hooks" "$FIX/core/scripts/lib"
git -C "$FIX" init -q
cp "$ROOT/.codex/hooks/hq-codex-hook-adapter.sh" "$FIX/.codex/hooks/"
cp "$ROOT/.grok/hooks/hq-grok-hook-adapter.sh" "$FIX/.grok/hooks/"
cp "$ROOT/.claude/hooks/hook-gate.sh" "$FIX/.claude/hooks/"
cp "$ROOT/core/scripts/hook-lib.sh" "$FIX/core/scripts/"
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$FIX/core/scripts/lib/"
chmod +x "$FIX/.codex/hooks/hq-codex-hook-adapter.sh" "$FIX/.grok/hooks/hq-grok-hook-adapter.sh" \
  "$FIX/.claude/hooks/hook-gate.sh"
# No settings.json hooks: only the fixture registry row dispatches.
printf '{"hooks":{"PreToolUse":[]}}\n' > "$FIX/.claude/settings.json"

GUARD="$FIX/.claude/hooks/fixture-guard.sh"
write_guard() { # <ok|deny|error|segv|odd>
  local body
  case "$1" in
    ok) body='exit 0' ;;
    deny) body='echo "fixture guard denied" >&2; exit 2' ;;
    error) body='echo "fixture guard internal error" >&2; exit 1' ;;
    # Signals the shell that runs the guard body; works on bash 3.2.
    segv) body='sh -c '\''kill -SEGV "$PPID"'\''; sleep 5; exit 0' ;;
    odd) body='exit 5' ;;
  esac
  printf '#!/usr/bin/env bash\ncat >/dev/null\n%s\n' "$body" > "$GUARD"
  chmod +x "$GUARD"
}
write_registry() { # <safety:true|false>
  jq -n --argjson s "$1" '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[
    {id:"mandatory-scope-authorizer",script:".claude/hooks/fixture-guard.sh",timeout:30,safety:$s}]}]}}' \
    > "$FIX/.claude/hooks/hook-registry.json"
}

FAILS=0
check() { # <label> <cond-result 0|1> <detail>
  if [ "$2" = "0" ]; then
    echo "  ok: $1"
  else
    echo "FAIL: $1: $3" >&2
    FAILS=$((FAILS + 1))
  fi
}

CODEX_PAYLOAD="$(jq -nc --arg cwd "$FIX" \
  '{hook_event_name:"PreToolUse",session_id:"adapter-safety",cwd:$cwd,tool_name:"Bash",tool_input:{command:"ls"}}')"
GROK_PAYLOAD="$(jq -nc --arg cwd "$FIX" \
  '{hookEventName:"PreToolUse",toolName:"Shell",cwd:$cwd,toolInput:{command:"ls"}}')"

run_codex() {
  RC=0
  printf '%s' "$CODEX_PAYLOAD" | ( cd / && bash "$FIX/.codex/hooks/hq-codex-hook-adapter.sh" ) \
    >"$TMP/out" 2>"$TMP/err" || RC=$?
}
run_grok() {
  RC=0
  printf '%s' "$GROK_PAYLOAD" | ( cd / && bash "$FIX/.grok/hooks/hq-grok-hook-adapter.sh" ) \
    >"$TMP/out" 2>"$TMP/err" || RC=$?
}

export HQ_ALLOW_HQ_WORKTREE=1

# <mode> <want-codex-rc> <reason or empty>
cases=(
  "ok|0|"
  "deny|2|fixture guard denied"
  "error|2|guard failed, blocked: mandatory-scope-authorizer exited 1 without a verdict"
  "segv|2|guard crashed, blocked: mandatory-scope-authorizer was killed by signal 11 (SIGSEGV, exit 139)"
  "odd|2|guard failed, blocked: mandatory-scope-authorizer exited 5 without a verdict"
)

write_registry true
for c in "${cases[@]}"; do
  mode="${c%%|*}"; rest="${c#*|}"; want="${rest%%|*}"; reason="${rest#*|}"
  write_guard "$mode"

  run_codex
  r=0; [ "$RC" = "$want" ] || r=1
  check "codex: safety guard $mode exits $want" "$r" "got $RC; stderr=$(cat "$TMP/err")"
  if [ -n "$reason" ]; then
    r=0; grep -qF "$reason" "$TMP/err" || r=1
    check "codex: safety guard $mode names the reason" "$r" "stderr=$(cat "$TMP/err")"
  fi

  run_grok
  if [ "$want" = "0" ]; then
    r=0; ! grep -q '"deny"' "$TMP/out" || r=1
    check "grok: safety guard $mode allows" "$r" "rc=$RC out=$(cat "$TMP/out")"
  else
    r=0; [ "$RC" = "2" ] && grep -q '"deny"' "$TMP/out" || r=1
    check "grok: safety guard $mode denies" "$r" "rc=$RC out=$(cat "$TMP/out")"
    r=0; grep -qF "$reason" "$TMP/out" || r=1
    check "grok: safety guard $mode deny names the reason" "$r" "out=$(cat "$TMP/out")"
  fi
done

# A non-safety guard keeps its old result: Codex passes exit 1 and 5 on, and
# neither adapter prints the safety reason.
write_registry false
for mode in error odd; do
  write_guard "$mode"
  want=1; [ "$mode" = odd ] && want=5
  run_codex
  r=0; [ "$RC" = "$want" ] || r=1
  check "codex: non-safety guard $mode keeps exit $want" "$r" "got $RC; stderr=$(cat "$TMP/err")"
  r=0; ! grep -q 'blocked: mandatory-scope-authorizer' "$TMP/err" || r=1
  check "codex: non-safety guard $mode has no safety reason" "$r" "stderr=$(cat "$TMP/err")"
  run_grok
  r=0; [ "$RC" = "2" ] || r=1
  check "grok: non-safety guard $mode still denies" "$r" "rc=$RC out=$(cat "$TMP/out")"
  r=0; ! grep -q 'blocked: mandatory-scope-authorizer' "$TMP/out" || r=1
  check "grok: non-safety guard $mode has no safety reason" "$r" "out=$(cat "$TMP/out")"
done

# Operator switch HQ_CODEX_LAUNCH_FAIL_OPEN=1: it passes a
# safety guard's LAUNCH failure (126/127 where the
# guard could not start) through on Codex, and nothing else. A guard that ran
# and exited 1, died by a signal, exited 5, or exited 127 by itself still
# blocks. Without the switch a launch failure blocks.
write_registry true
run_codex_fail_open() {
  RC=0
  printf '%s' "$CODEX_PAYLOAD" | ( cd / && HQ_CODEX_LAUNCH_FAIL_OPEN=1 bash "$FIX/.codex/hooks/hq-codex-hook-adapter.sh" ) \
    >"$TMP/out" 2>"$TMP/err" || RC=$?
}
fail_open_cases=(
  "error|guard failed, blocked: mandatory-scope-authorizer exited 1 without a verdict"
  "segv|guard crashed, blocked: mandatory-scope-authorizer was killed by signal 11 (SIGSEGV, exit 139)"
  "odd|guard failed, blocked: mandatory-scope-authorizer exited 5 without a verdict"
)
for c in "${fail_open_cases[@]}"; do
  mode="${c%%|*}"; reason="${c#*|}"
  write_guard "$mode"
  run_codex_fail_open
  r=0; [ "$RC" = "2" ] || r=1
  check "codex: switch set, safety guard $mode still blocks" "$r" "got $RC; stderr=$(cat "$TMP/err")"
  r=0; grep -qF "$reason" "$TMP/err" || r=1
  check "codex: switch set, safety guard $mode names the reason" "$r" "stderr=$(cat "$TMP/err")"
done

# A guard that ran and exited 127 by itself is not a launch failure.
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 127\n' > "$GUARD"
chmod +x "$GUARD"
run_codex_fail_open
r=0; [ "$RC" = "2" ] || r=1
check "codex: switch set, safety guard exit 127 by itself still blocks" "$r" "got $RC; stderr=$(cat "$TMP/err")"
r=0; grep -qF "guard failed, blocked: mandatory-scope-authorizer exited 127 without a verdict" "$TMP/err" || r=1
check "codex: switch set, safety guard exit 127 by itself names the reason" "$r" "stderr=$(cat "$TMP/err")"

# A guard that cannot be launched (unreadable file, exit 126).
write_guard ok
chmod 000 "$GUARD"
if [ -r "$GUARD" ]; then
  echo "  skip: running as root, the unreadable guard stays readable (no launch failure)"
else
  run_codex_fail_open
  r=0; [ "$RC" = "126" ] || r=1
  check "codex: switch set, safety guard launch failure passes (126)" "$r" "got $RC; stderr=$(cat "$TMP/err")"
  r=0; ! grep -q 'blocked: mandatory-scope-authorizer' "$TMP/err" || r=1
  check "codex: switch set, launch failure has no safety reason" "$r" "stderr=$(cat "$TMP/err")"

  run_codex
  r=0; [ "$RC" = "2" ] || r=1
  check "codex: switch unset, safety guard launch failure blocks" "$r" "got $RC; stderr=$(cat "$TMP/err")"
  r=0; grep -qF "guard 'mandatory-scope-authorizer' could not be launched (exit 126)" "$TMP/err" || r=1
  check "codex: switch unset, launch failure names the reason" "$r" "stderr=$(cat "$TMP/err")"

  # The switch must come from the adapter's own environment with the value 1.
  RC=0
  printf '%s' "$CODEX_PAYLOAD" | ( cd / && HQ_CODEX_LAUNCH_FAIL_OPEN=true bash "$FIX/.codex/hooks/hq-codex-hook-adapter.sh" ) \
    >"$TMP/out" 2>"$TMP/err" || RC=$?
  r=0; [ "$RC" = "2" ] || r=1
  check "codex: switch set to a value other than 1, launch failure blocks" "$r" "got $RC; stderr=$(cat "$TMP/err")"
fi
chmod 755 "$GUARD"

# A safety guard whose script is missing blocks on both adapters with the
# repair message, also with the Codex launch
# switch set. A missing non-safety guard is still skipped, and a profile that
# turns the guard off still skips it.
missing_reason='BLOCKED: a required HQ safety check is missing (mandatory-scope-authorizer). Run hq rescue from a terminal (or re-run /update-hq) to repair it, then retry.'
rm -f "$GUARD"
write_registry true
run_codex
r=0; [ "$RC" = "2" ] || r=1
check "codex: missing safety guard blocks" "$r" "got $RC; stderr=$(cat "$TMP/err")"
r=0; grep -qF "$missing_reason" "$TMP/err" || r=1
check "codex: missing safety guard names the repair" "$r" "stderr=$(cat "$TMP/err")"
run_codex_fail_open
r=0; [ "$RC" = "2" ] && grep -qF "$missing_reason" "$TMP/err" || r=1
check "codex: switch set, missing safety guard still blocks" "$r" "got $RC; stderr=$(cat "$TMP/err")"
run_grok
r=0; [ "$RC" = "2" ] && grep -q '"deny"' "$TMP/out" || r=1
check "grok: missing safety guard denies" "$r" "rc=$RC out=$(cat "$TMP/out")"
r=0; grep -qF "$missing_reason" "$TMP/out" || r=1
check "grok: missing safety guard deny names the repair" "$r" "out=$(cat "$TMP/out")"

RC=0
printf '%s' "$CODEX_PAYLOAD" | ( cd / && HQ_DISABLED_HOOKS=mandatory-scope-authorizer bash "$FIX/.codex/hooks/hq-codex-hook-adapter.sh" ) \
  >"$TMP/out" 2>"$TMP/err" || RC=$?
r=0; [ "$RC" = "0" ] && ! grep -q 'safety check is missing' "$TMP/err" || r=1
check "codex: missing safety guard turned off by the profile is skipped" "$r" "got $RC; stderr=$(cat "$TMP/err")"

write_registry false
run_codex
r=0; [ "$RC" = "0" ] && ! grep -q 'safety check is missing' "$TMP/err" || r=1
check "codex: missing non-safety guard is skipped" "$r" "got $RC; stderr=$(cat "$TMP/err")"
run_grok
r=0; ! grep -q '"deny"' "$TMP/out" || r=1
check "grok: missing non-safety guard is skipped" "$r" "rc=$RC out=$(cat "$TMP/out")"
write_guard ok

# The shared reason helper, for codes the fixtures above do not reach.
. "$ROOT/core/scripts/lib/hook-adapter-core.sh"
got="$(hqad_safety_block_reason some-guard 137)"
r=0; [ "$got" = "guard crashed, blocked: some-guard was killed by signal 9 (SIGKILL, exit 137), so this tool call was not checked." ] || r=1
check "reason helper names SIGKILL" "$r" "got: $got"
got="$(hqad_safety_block_reason 'bad id' 127)"
r=0; [ "$got" = "guard failed, blocked: registered hook exited 127 without a verdict, so this tool call was not checked." ] || r=1
check "reason helper hides an unsafe id" "$r" "got: $got"
got="$(hqad_missing_safety_reason 'bad id')"
r=0; [ "$got" = "BLOCKED: a required HQ safety check is missing (registered hook). Run hq rescue from a terminal (or re-run /update-hq) to repair it, then retry." ] || r=1
check "missing reason helper hides an unsafe id" "$r" "got: $got"

if [ "$FAILS" -ne 0 ]; then
  echo "FAILED: $FAILS adapter-safety-guard-exit check(s)" >&2
  exit 1
fi
echo "ALL PASS: adapter-safety-guard-exit"
