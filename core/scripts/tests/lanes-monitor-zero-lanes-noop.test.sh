#!/usr/bin/env bash
# hq-core: public
# Zero-lane no-op contract for the lane Stop gate and the monitor reminder hooks.
#
# In default /conduct mode (conduct.runner = subagent) no lane record is ever
# written, so these hooks must stay silent and must not start hq:
#   - .claude/hooks/lanes-senior-monitor-stop-gate.sh passes (exit 0, no block,
#     no `hq runners monitor-check`) with an empty, missing or other-sessions-only
#     lane store, even when hq is not installed.
#   - An unreadable lane store counts as zero lanes when the session's runner
#     resolves to subagent: exit 0 and exactly one warning line on stderr.
#     Under runner mode the unreadable store keeps the fail-closed path.
#   - .claude/hooks/hq-monitor-session-hook.sh and .claude/hooks/hq-monitor-guard.sh
#     emit no reminder and start no hq process for a session with no lanes.
#   - The registry still lists every one of these hooks.
#
# The gate is run directly rather than through master-hook.sh: master-hook adds
# toolchain directories to PATH, so an hq installed on the test machine would
# shadow the stub and make the "no hq call" assertions meaningless.
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
TMP="$(mktemp -d)"
cleanup() {
  chmod -R u+rwx "$TMP" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL - $1" >&2; }
assert_empty() { if [ -z "$1" ]; then pass "$2"; else fail "$2 (got: $1)"; fi; }
assert_contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3 (missing '$2' in: $1)" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "$3 (unexpected '$2' in: $1)" ;; *) pass "$3" ;; esac; }
assert_eq() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (want '$2', got '$1')"; fi; }

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required" >&2; exit 1; }
JQ_DIR="$(dirname "$(command -v jq)")"

# The id avoids the word "lane" so the guard wording check below sees only
# the hook's own text.
SID="senior-under-test"
OTHER_SID="another-senior"

# ---------------------------------------------------------------------------
# Stub hq: logs every call; behaviour comes from $STUB_MODE_FILE.
BIN="$TMP/bin"
NO_HQ="$TMP/no-hq"
EMPTY_DIR="$TMP/empty-install-dir"
STUB_LOG="$TMP/hq.calls"
STUB_MODE_FILE="$TMP/hq.mode"
mkdir -p "$BIN" "$NO_HQ" "$EMPTY_DIR"
cat > "$BIN/hq" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ZL_STUB_LOG"
mode="$(cat "$ZL_STUB_MODE_FILE" 2>/dev/null || echo pass)"
case "$1 ${2:-}" in
  "runners monitor-check")
    case "$mode" in
      uncovered)
        printf '%s\n' '{"action":"monitor-check","active_lane_ids":["lane-a"],"uncovered_lane_ids":["lane-a"],"monitor_calls":[{"command":"hq runners watch lane-a","timeout_ms":1800000,"persistent":true}]}'
        exit 2 ;;
      error) echo "stub monitor-check failure" >&2; exit 1 ;;
      *) printf '%s\n' '{"action":"monitor-check","active_lane_ids":[],"uncovered_lane_ids":[]}'; exit 0 ;;
    esac ;;
  "monitor enabled") [ "$mode" = monitor-enabled ] && exit 0; exit 1 ;;
  "monitor drain") printf '%s\n' 'STUB-MONITOR-DRAIN'; exit 0 ;;
  "--help "*) printf '%s\n' 'Commands:' '  lanes' '  monitor'; exit 0 ;;
esac
exit 0
SH
chmod 755 "$BIN" "$BIN/hq"
export ZL_STUB_LOG="$STUB_LOG" ZL_STUB_MODE_FILE="$STUB_MODE_FILE"

reset_stub() { : > "$STUB_LOG"; printf '%s\n' "${1:-pass}" > "$STUB_MODE_FILE"; }
stub_calls() { cat "$STUB_LOG" 2>/dev/null; }

PATH_WITH_HQ="$BIN:$JQ_DIR:/usr/bin:/bin"
PATH_WITHOUT_HQ="$NO_HQ:$JQ_DIR:/usr/bin:/bin"
if env PATH="$PATH_WITHOUT_HQ" bash -c 'command -v hq >/dev/null 2>&1'; then
  echo "FAIL: hq is installed in a system directory; the no-hq cases cannot run" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Fixture HQ root: the gate, its resolver (install dirs pinned to an empty dir),
# the conduct runner resolver, and the shipped orchestrator settings.
ROOT="$TMP/hq"
LANES="$ROOT/workspace/lanes/lanes"
mkdir -p "$ROOT/.claude/hooks" "$ROOT/core/scripts/lib" "$ROOT/core/settings" "$LANES"
cp "$SRC/.claude/hooks/lanes-senior-monitor-stop-gate.sh" \
   "$SRC/.claude/hooks/hq-monitor-session-hook.sh" \
   "$SRC/.claude/hooks/hq-monitor-guard.sh" \
   "$SRC/.claude/hooks/hq-monitor-hook-lib.sh" \
   "$SRC/.claude/hooks/hook-gate.sh" \
   "$SRC/.claude/hooks/hook-timeout-probe.sh" \
   "$ROOT/.claude/hooks/"
cp "$SRC/core/scripts/hook-lib.sh" "$SRC/core/scripts/conduct-runner-resolve.sh" "$ROOT/core/scripts/"
cp "$SRC/core/scripts/lib/lanes-senior-monitor.sh" "$SRC/core/scripts/lib/session-auto-bind.sh" "$ROOT/core/scripts/lib/"
cp "$SRC/core/settings/orchestrator.yaml" "$ROOT/core/settings/orchestrator.yaml"
awk -v d="$EMPTY_DIR" '/# HQ_BIN_DEFAULT_DIRS$/ { print "  dirs=\"" d "\" # HQ_BIN_DEFAULT_DIRS"; next } { print }' \
  "$SRC/core/scripts/lib/resolve-hq-bin.sh" > "$ROOT/core/scripts/lib/resolve-hq-bin.sh"
grep -qF "dirs=\"$EMPTY_DIR\" # HQ_BIN_DEFAULT_DIRS" "$ROOT/core/scripts/lib/resolve-hq-bin.sh" \
  || { echo "FAIL: could not pin resolve-hq-bin.sh install dirs" >&2; exit 1; }
GATE="$ROOT/.claude/hooks/lanes-senior-monitor-stop-gate.sh"

RUNNER_NOW="$(sh "$ROOT/core/scripts/conduct-runner-resolve.sh" --session-id "$SID" --root "$ROOT" 2>/dev/null)"
assert_eq "$RUNNER_NOW" "subagent" "fixture resolves the shipped default runner (subagent)"

lane_record() { # id state senior-id
  jq -cn --arg id "$1" --arg st "$2" --arg sid "$3" \
    '{lane_id:$id,state:$st,senior:{kind:"session",id:$sid}}' > "$LANES/$1.json"
}
reset_store() {
  chmod u+rwx "$LANES" 2>/dev/null || true
  rm -rf "$LANES"
  mkdir -p "$LANES"
}
set_runner() { # subagent | runner
  awk -v r="$1" '/^conduct:/ {on=1; print; next}
    on && /^[^ #]/ {on=0}
    on && /^  runner:/ {print "  runner: " r; next}
    {print}' "$SRC/core/settings/orchestrator.yaml" > "$ROOT/core/settings/orchestrator.yaml"
  assert_eq "$(sh "$ROOT/core/scripts/conduct-runner-resolve.sh" --session-id "$SID" --root "$ROOT" 2>/dev/null)" "$1" \
    "fixture runner set to $1"
}

stop_payload() { jq -cn --arg sid "$1" '{session_id:$sid,hook_event_name:"Stop",stop_hook_active:false}'; }

# run_gate SCRIPT PATH [SID] -> GRC, GOUT, GERR
run_gate() {
  local script="$1" path="$2" sid="${3:-$SID}"
  GRC=0
  stop_payload "$sid" | env -u HQ_HARNESS -u HQ_LANE_ID \
    HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" HOME="$TMP/home" TMPDIR="$TMP" PATH="$path" \
    bash "$script" >"$TMP/gate.out" 2>"$TMP/gate.err" || GRC=$?
  GOUT="$(cat "$TMP/gate.out")"
  GERR="$(cat "$TMP/gate.err")"
}

expect_silent_pass() { # label
  assert_eq "$GRC" "0" "$1: exit 0"
  assert_empty "$GOUT" "$1: no block output"
  assert_not_contains "$(stub_calls)" "monitor-check" "$1: no hq runners monitor-check call"
}

echo "== Stop gate: zero lanes for this session"

for hq_case in present absent; do
  if [ "$hq_case" = present ]; then path="$PATH_WITH_HQ"; else path="$PATH_WITHOUT_HQ"; fi

  reset_store; reset_stub
  run_gate "$GATE" "$path"
  expect_silent_pass "empty lane store, hq $hq_case"
  assert_empty "$GERR" "empty lane store, hq $hq_case: no stderr"

  reset_store; rm -rf "$LANES"; reset_stub
  run_gate "$GATE" "$path"
  expect_silent_pass "missing lane store, hq $hq_case"

  reset_store; reset_stub
  lane_record other-running running "$OTHER_SID"
  lane_record other-queued queued "$OTHER_SID"
  lane_record other-blocked blocked "third-senior"
  run_gate "$GATE" "$path"
  expect_silent_pass "store with only other sessions' records, hq $hq_case"
  assert_empty "$GERR" "other sessions only, hq $hq_case: no stderr"

  reset_store; reset_stub
  lane_record other-running running "$OTHER_SID"
  lane_record mine-done done "$SID"
  run_gate "$GATE" "$path"
  expect_silent_pass "only a finished lane for this session, hq $hq_case"
done
assert_empty "$(stub_calls)" "zero-lane gate runs start no hq process at all"

echo "== Stop gate: a running lane still arms the gate"

reset_store; reset_stub pass
lane_record mine-running running "$SID"
run_gate "$GATE" "$PATH_WITH_HQ"
assert_eq "$GRC" "0" "running lane, covered: exit 0"
assert_contains "$(stub_calls)" "runners monitor-check" "running lane: hq runners monitor-check is called"
assert_eq "$(grep -c 'runners monitor-check' "$STUB_LOG")" "1" "running lane: exactly one monitor-check call"

reset_stub uncovered
run_gate "$GATE" "$PATH_WITH_HQ"
assert_contains "$GOUT" '"decision":"block"' "running lane, uncovered: Stop is blocked"

reset_stub pass
run_gate "$GATE" "$PATH_WITHOUT_HQ"
assert_contains "$GOUT" '"decision":"block"' "running lane, hq missing: still fails closed"

echo "== Stop gate: unreadable lane store"
# Behaviour before this change: session_has_active_lane returned "unsure" (2)
# for an unreadable store and the gate fell through to hq runners monitor-check,
# so a CLI error or missing hq blocked the Stop (fail closed) in every mode,
# including default mode where no lane can exist. That behaviour is kept under
# runner mode and asserted below. In default mode (runner subagent) the store
# now counts as zero lanes: exit 0 with one warning line.

make_unreadable_variants() {
  UNREADABLE_VARIANTS="not-a-directory"
  if [ "$(id -u)" != 0 ]; then
    UNREADABLE_VARIANTS="mode-000 $UNREADABLE_VARIANTS"
  else
    echo "  note - running as root: mode 000 does not deny root, so only the not-a-directory variant can make the store unreadable"
  fi
}
make_store_unreadable() { # variant
  reset_store
  lane_record mine-running running "$SID"
  case "$1" in
    mode-000) chmod 000 "$LANES" ;;
    not-a-directory) rm -rf "$LANES"; printf 'not a directory\n' > "$LANES" ;;
  esac
}
make_unreadable_variants

for variant in $UNREADABLE_VARIANTS; do
  if [ "$variant" = mode-000 ]; then
    make_store_unreadable "$variant"
    if [ -r "$LANES" ]; then fail "mode-000: chmod 000 did not make the store unreadable"; fi
  fi

  # Runner mode keeps the documented fail-closed path.
  set_runner runner
  make_store_unreadable "$variant"; reset_stub error
  run_gate "$GATE" "$PATH_WITH_HQ"
  assert_contains "$(stub_calls)" "runners monitor-check" "unreadable store ($variant), runner mode: falls through to monitor-check"
  assert_contains "$GOUT" '"decision":"block"' "unreadable store ($variant), runner mode, CLI error: Stop is blocked"

  make_store_unreadable "$variant"; reset_stub
  run_gate "$GATE" "$PATH_WITHOUT_HQ"
  assert_contains "$GOUT" '"decision":"block"' "unreadable store ($variant), runner mode, hq missing: Stop is blocked"

  # Default mode: zero lanes, one warning line, no hq.
  set_runner subagent
  for path in "$PATH_WITH_HQ" "$PATH_WITHOUT_HQ"; do
    make_store_unreadable "$variant"; reset_stub error
    run_gate "$GATE" "$path"
    expect_silent_pass "unreadable store ($variant), runner subagent"
    assert_eq "$(printf '%s\n' "$GERR" | grep -c .)" "1" "unreadable store ($variant), runner subagent: exactly one stderr line"
    assert_contains "$GERR" "WARNING: lanes Stop gate: lane store" "unreadable store ($variant), runner subagent: the line is the warning"
  done
  assert_empty "$(stub_calls)" "unreadable store ($variant), runner subagent: no hq process"
done

# Without a resolvable runner the doubt keeps failing closed.
ROOT_SAVED_RESOLVER="$TMP/conduct-runner-resolve.sh.saved"
mv "$ROOT/core/scripts/conduct-runner-resolve.sh" "$ROOT_SAVED_RESOLVER"
NORESOLVE_GATE_DIR="$TMP/noresolve/.claude/hooks"
mkdir -p "$NORESOLVE_GATE_DIR"
cp "$GATE" "$NORESOLVE_GATE_DIR/"
make_store_unreadable not-a-directory; reset_stub error
run_gate "$NORESOLVE_GATE_DIR/lanes-senior-monitor-stop-gate.sh" "$PATH_WITH_HQ"
assert_contains "$(stub_calls)" "runners monitor-check" "unreadable store, runner unresolvable: falls through to monitor-check"
assert_contains "$GOUT" '"decision":"block"' "unreadable store, runner unresolvable: Stop is blocked"
mv "$ROOT_SAVED_RESOLVER" "$ROOT/core/scripts/conduct-runner-resolve.sh"
reset_store

echo "== Stop gate: doubt about a record fails closed in default mode too"
# Only an unreadable store directory counts as zero lanes in default mode.
# A malformed or truncated record, or a jq failure while reading the records,
# says nothing about whether this session owns a running lane, so it keeps the
# fail-closed path: hq runners monitor-check runs and a CLI error blocks the Stop.
set_runner subagent

reset_store; reset_stub error
lane_record mine-running running "$SID"
printf '{"lane_id":"mine-truncated","state":"running","senior":{"kind":"session","id":"%s"' "$SID" > "$LANES/mine-truncated.json"
run_gate "$GATE" "$PATH_WITH_HQ"
assert_contains "$(stub_calls)" "runners monitor-check" "active lane plus truncated record, runner subagent: falls through to monitor-check"
assert_contains "$GOUT" '"decision":"block"' "active lane plus truncated record, runner subagent, CLI error: Stop is blocked"
assert_not_contains "$GERR" "treated as having no lanes" "active lane plus truncated record, runner subagent: not treated as zero lanes"

reset_store; reset_stub error
printf '{"lane_id":"mine-truncated","state":"running","senior":{"kind":"session","id":"%s"' "$SID" > "$LANES/mine-truncated.json"
run_gate "$GATE" "$PATH_WITH_HQ"
assert_contains "$(stub_calls)" "runners monitor-check" "only a truncated record naming this session, runner subagent: falls through to monitor-check"
assert_contains "$GOUT" '"decision":"block"' "only a truncated record naming this session, runner subagent, CLI error: Stop is blocked"

# jq fails while reading the records (a broken or vanished jq exits 127). The
# shim passes every other jq call through, so payload parsing still works.
REAL_JQ="$(command -v jq)"
BROKEN_JQ_DIR="$TMP/broken-jq"
mkdir -p "$BROKEN_JQ_DIR"
cat > "$BROKEN_JQ_DIR/jq" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "-e" ] && [ "\${2:-}" = "-n" ]; then echo "jq: not runnable" >&2; exit 127; fi
exec "$REAL_JQ" "\$@"
SH
chmod 755 "$BROKEN_JQ_DIR/jq"
reset_store; reset_stub error
lane_record mine-running running "$SID"
run_gate "$GATE" "$BROKEN_JQ_DIR:$PATH_WITH_HQ"
assert_contains "$(stub_calls)" "runners monitor-check" "jq fails reading records, runner subagent: falls through to monitor-check"
assert_contains "$GOUT" '"decision":"block"' "jq fails reading records, runner subagent, CLI error: Stop is blocked"

# jq missing altogether: the payload cannot be parsed, so the gate blocks
# before it looks at the store.
if env PATH="$BIN:/bin" bash -c 'command -v jq >/dev/null 2>&1'; then
  echo "  note - jq is in /bin, so the missing-jq case cannot run here"
else
  reset_store; reset_stub
  lane_record mine-running running "$SID"
  run_gate "$GATE" "$BIN:/bin"
  assert_contains "$GOUT" '"decision":"block"' "jq missing, runner subagent, active lane: Stop is blocked"
  assert_contains "$GERR" "jq is unavailable" "jq missing, runner subagent: the error names jq"
fi

# The unreadable store directory still counts as zero lanes in default mode.
make_store_unreadable not-a-directory; reset_stub error
run_gate "$GATE" "$PATH_WITH_HQ"
expect_silent_pass "unreadable store after the record cases, runner subagent"
reset_store

echo "== Stop gate: mutations go red"

# mutate NAME MARKER REPLACEMENT: copy the gate, replace the first `exit 0` at
# or after MARKER with REPLACEMENT, and print the copy's path. The copy sits
# outside the fixture root, so it finds hq on PATH and the runner through
# HQ_ROOT.
mutate() {
  local dir="$TMP/mut-$1/.claude/hooks"
  mkdir -p "$dir"
  awk -v marker="$2" -v repl="$3" '
    index($0, marker) { hit = 1 }
    hit { if (sub(/exit 0/, repl)) { hit = 0; changed = 1 } }
    { print }
    END { if (!changed) exit 3 }' "$GATE" > "$dir/lanes-senior-monitor-stop-gate.sh" || return 1
  printf '%s' "$dir/lanes-senior-monitor-stop-gate.sh"
}

if ! MUT="$(mutate fast-path ZERO_LANE_FAST_PATH_MUST_EXIT ': mutated')"; then
  fail "mutation fast-path: marker ZERO_LANE_FAST_PATH_MUST_EXIT not found"
else
  reset_store; reset_stub
  run_gate "$MUT" "$PATH_WITHOUT_HQ"
  if [ "$GRC" = 0 ] && [ -z "$GOUT" ]; then
    fail "mutation fast-path: removing the zero-lane exit stayed green"
  else
    pass "mutation fast-path: removing the zero-lane exit goes red (hq missing blocks)"
  fi
fi

if ! MUT="$(mutate unreadable-default UNREADABLE_DEFAULT_MODE_MUST_PASS ': mutated')"; then
  fail "mutation unreadable-default: marker UNREADABLE_DEFAULT_MODE_MUST_PASS not found"
else
  make_store_unreadable not-a-directory; reset_stub error
  run_gate "$MUT" "$PATH_WITH_HQ"
  if [ -z "$(stub_calls)" ] && [ -z "$GOUT" ]; then
    fail "mutation unreadable-default: removing the default-mode exit stayed green"
  else
    pass "mutation unreadable-default: removing the default-mode exit goes red"
  fi
  reset_store
fi

echo "== Monitor reminder hooks: zero lanes, runner subagent"

reset_store
set_runner subagent

# run_hook SCRIPT PAYLOAD [ARGS...] -> HRC, HOUT, HERR
run_hook() {
  local script="$1" payload="$2"
  shift 2
  HRC=0
  printf '%s' "$payload" | env -u HQ_LANE_ID -u HQ_CHECKPOINT_RUNTIME \
    HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" HOME="$TMP/home" TMPDIR="$TMP" \
    XDG_CACHE_HOME="$TMP/cache" PATH="$PATH_WITH_HQ" \
    bash "$script" "$@" >"$TMP/hook.out" 2>"$TMP/hook.err" || HRC=$?
  HOUT="$(cat "$TMP/hook.out")"
  HERR="$(cat "$TMP/hook.err")"
}

SESSION_HOOK="$ROOT/.claude/hooks/hq-monitor-session-hook.sh"
GUARD="$ROOT/.claude/hooks/hq-monitor-guard.sh"
REMINDER="$ROOT/core/scripts/lib/lanes-senior-monitor.sh"

for event in PreToolUse UserPromptSubmit; do
  reset_stub monitor-enabled
  run_hook "$SESSION_HOOK" "$(jq -cn --arg sid "$SID" --arg e "$event" '{session_id:$sid,hook_event_name:$e,prompt:"hello"}')" drain "$event"
  assert_eq "$HRC" "0" "hq-monitor-session-hook $event: exit 0"
  assert_empty "$HOUT" "hq-monitor-session-hook $event: no reminder"
  assert_empty "$(stub_calls)" "hq-monitor-session-hook $event: no hq call"
done

# Positive control: the same hook does deliver once this session has a monitor.
mkdir -p "$ROOT/workspace/monitors/sessions/claude-$SID/active"
: > "$ROOT/workspace/monitors/sessions/claude-$SID/active/m1"
reset_stub monitor-enabled
run_hook "$SESSION_HOOK" "$(jq -cn --arg sid "$SID" '{session_id:$sid,hook_event_name:"PreToolUse"}')" drain PreToolUse
assert_contains "$(stub_calls)" "monitor drain" "hq-monitor-session-hook control: an active monitor reaches hq monitor drain"
rm -rf "$ROOT/workspace/monitors"

for cmd in 'ls -la' 'git status' 'hq runners list' 'echo done'; do
  reset_stub monitor-enabled
  run_hook "$GUARD" "$(jq -cn --arg sid "$SID" --arg c "$cmd" '{session_id:$sid,hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}')"
  assert_eq "$HRC" "0" "hq-monitor-guard '$cmd': exit 0"
  assert_empty "$HOUT" "hq-monitor-guard '$cmd': no reminder"
  assert_empty "$(stub_calls)" "hq-monitor-guard '$cmd': no hq call"
done

# The guard's only output is its foreground-wait block, and that text never
# mentions lanes.
reset_stub monitor-enabled
run_hook "$GUARD" "$(jq -cn --arg sid "$SID" '{session_id:$sid,hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"sleep 900"}}')"
assert_contains "$HOUT" '"permissionDecision":"deny"' "hq-monitor-guard control: a long foreground wait is still denied"
assert_not_contains "$(printf '%s' "$HOUT" | tr '[:upper:]' '[:lower:]')" "lane" "hq-monitor-guard wait block does not mention lanes"

for event in SessionStart UserPromptSubmit; do
  lane_record other-running running "$OTHER_SID"
  reset_stub
  run_hook "$REMINDER" "$(jq -cn --arg sid "$SID" '{session_id:$sid,engine:"claude"}')" "$event"
  assert_eq "$HRC" "0" "lanes senior reminder $event: exit 0"
  assert_empty "$HOUT" "lanes senior reminder $event: no reminder"
  assert_empty "$(stub_calls)" "lanes senior reminder $event: no hq call"
  reset_store
done

echo "== Registry: every hook is still registered"

REGISTRY="$SRC/.claude/hooks/hook-registry.json"
registered() { # event id script [args-json]
  jq -e --arg e "$1" --arg id "$2" --arg s "$3" --argjson a "${4:-null}" \
    '[.hooks[$e][]?.hooks[]? | select(.id == $id and .script == $s and (.args // null) == $a and .gated == true)] | length == 1' \
    "$REGISTRY" >/dev/null
}
registered Stop lanes-senior-monitor-stop-gate .claude/hooks/lanes-senior-monitor-stop-gate.sh \
  && pass "registry: Stop lanes-senior-monitor-stop-gate" || fail "registry: Stop lanes-senior-monitor-stop-gate missing or changed"
registered PreToolUse hq-monitor-session-hook .claude/hooks/hq-monitor-session-hook.sh '["drain","PreToolUse"]' \
  && pass "registry: PreToolUse hq-monitor-session-hook" || fail "registry: PreToolUse hq-monitor-session-hook missing or changed"
registered UserPromptSubmit hq-monitor-session-hook .claude/hooks/hq-monitor-session-hook.sh '["drain","UserPromptSubmit"]' \
  && pass "registry: UserPromptSubmit hq-monitor-session-hook" || fail "registry: UserPromptSubmit hq-monitor-session-hook missing or changed"
registered PreToolUse hq-monitor-guard .claude/hooks/hq-monitor-guard.sh \
  && pass "registry: PreToolUse hq-monitor-guard" || fail "registry: PreToolUse hq-monitor-guard missing or changed"
for f in lanes-senior-monitor-stop-gate.sh hq-monitor-session-hook.sh hq-monitor-guard.sh; do
  [ -f "$SRC/.claude/hooks/$f" ] && pass "hook file present: $f" || fail "hook file removed: $f"
done

echo
echo "lanes-monitor-zero-lanes-noop: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
