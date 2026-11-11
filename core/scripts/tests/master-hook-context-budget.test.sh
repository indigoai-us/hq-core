#!/usr/bin/env bash
# hq-core: public
# Regression (feedback d69d01c0): master-hook bounds the total hook context of
# one turn-start event. When the children's combined output is over the
# budget, the task and handoff hooks' output is kept and comes first, JSON
# that carries a control field, systemMessage or sessionTitle is kept, output from
# once-only notice hooks is kept, the rest is kept in arrival order
# while it fits, and one closing line names what was left out. Under the
# budget, or with HQ_HOOK_CONTEXT_BUDGET_BYTES=0, the output is unchanged.
# Tool events are not budgeted.
# pass and fail always return 0, so A && pass || fail is safe here.
# shellcheck disable=SC2015
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MASTER="$ROOT/.claude/hooks/master-hook.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/hq"
mkdir -p "$FIX/.claude/hooks" "$FIX/core/hooks/UserPromptSubmit" "$FIX/core/hooks/PostToolUse" \
  "$FIX/core/scripts/lib" "$FIX/workspace/sessions" "$FIX/workspace/.hook-timeout-journal"
cp "$MASTER" "$FIX/.claude/hooks/master-hook.sh"
cp "$ROOT/.claude/hooks/hook-timeout-probe.sh" "$FIX/.claude/hooks/"
cat > "$FIX/.claude/hooks/hook-timeout-watchdog.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cp "$ROOT/.claude/hooks/hook-gate.sh" "$FIX/.claude/hooks/"
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$FIX/core/scripts/lib/"
chmod +x "$FIX/.claude/hooks/master-hook.sh"

FAIL=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

# make_child <event> <file> <body>: a child that drains stdin, then runs body.
make_child() {
  printf '#!/usr/bin/env bash\ncat >/dev/null\n%s\n' "$3" > "$FIX/core/hooks/$1/$2"
  chmod +x "$FIX/core/hooks/$1/$2"
}
# Arrival order follows the file names: the floods arrive before the task hook.
make_child UserPromptSubmit 10-flood-a.sh "printf 'FLOOD-A\n'; head -c 6000 /dev/zero | tr '\\0' a; printf '\n'"
make_child UserPromptSubmit 20-flood-b.sh "printf 'FLOOD-B\n'; head -c 12000 /dev/zero | tr '\\0' b; printf '\n'"
make_child UserPromptSubmit 30-hint-json.sh "printf '{\"hookSpecificOutput\":{\"hookEventName\":\"UserPromptSubmit\",\"additionalContext\":\"HINT-JSON %s\"}}' \"\$(head -c 1000 /dev/zero | tr '\\0' h)\""
make_child UserPromptSubmit 40-control-json.sh "printf '{\"continue\":true,\"hookSpecificOutput\":{\"hookEventName\":\"UserPromptSubmit\",\"additionalContext\":\"CONTROL-JSON %s\"}}' \"\$(head -c 6000 /dev/zero | tr '\\0' c)\""
make_child UserPromptSubmit auto-startwork.sh "printf 'ACTIVE-TASK-MARKER\n'; head -c 2000 /dev/zero | tr '\\0' t; printf '\n'"

printf '%s\n' '{"session_id":"ctx-budget-test","prompt":"run the handoff"}' > "$TMP/prompt.json"
printf '%s\n' '{"session_id":"ctx-budget-test","tool_name":"Bash","tool_input":{"command":"true"},"tool_response":{}}' > "$TMP/tool.json"

# run_master <event> <input> <out> [env assignments...]
run_master() {
  local event="$1" input="$2" out="$3" rc=0
  shift 3
  env CLAUDE_PROJECT_DIR="$FIX" HQ_MASTER_CHILD_TIMEOUT=20 "$@" \
    bash "$FIX/.claude/hooks/master-hook.sh" "$event" \
    < "$input" > "$out" 2> "$out.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "$event exited $rc: $(head -c 300 "$out.err")"
}
line_of() { grep -n -m1 -F -- "$1" "$2" | cut -d: -f1; }

# 1. Over the default 16 KB UserPromptSubmit budget.
run_master UserPromptSubmit "$TMP/prompt.json" "$TMP/over"
first_line="$(head -n 1 "$TMP/over")"
[ "$first_line" = "ACTIVE-TASK-MARKER" ] && pass "task hook output comes first" \
  || fail "first line is [$first_line], want the task hook's output"
grep -qF 'FLOOD-A' "$TMP/over" && pass "a chunk that fits is kept" || fail "FLOOD-A was dropped"
grep -qF 'FLOOD-B' "$TMP/over" && fail "FLOOD-B should be left out" || pass "a chunk over the budget is left out"
grep -qF 'CONTROL-JSON' "$TMP/over" && pass "JSON with a control field is kept" || fail "control JSON was dropped"
grep -qF 'HINT-JSON' "$TMP/over" && pass "context JSON that fits is kept" || fail "HINT-JSON was dropped"
grep -qF 'HQ hook context budget' "$TMP/over" && grep -F 'HQ hook context budget' "$TMP/over" | grep -qF '20-flood-b' \
  && pass "closing line names the hook left out" || fail "missing or wrong budget note"
a_line="$(line_of FLOOD-A "$TMP/over")"
t_line="$(line_of ACTIVE-TASK-MARKER "$TMP/over")"
[ -n "$a_line" ] && [ "$t_line" -lt "$a_line" ] && pass "kept chunks follow the task output" \
  || fail "order wrong (task line $t_line, FLOOD-A line ${a_line:-none})"
json_line="$(grep -E '^\{' "$TMP/over" | tail -n 1)"
printf '%s' "$json_line" | jq -e '.continue == true and (.hookSpecificOutput.additionalContext | test("CONTROL-JSON"))' >/dev/null 2>&1 \
  && pass "merged JSON keeps the control field" || fail "merged JSON lost the control field"
bytes="$(wc -c < "$TMP/over" | tr -d ' ')"
[ "$bytes" -le 17500 ] && pass "event output is bounded (${bytes} bytes)" || fail "event output is ${bytes} bytes"

# 2. HQ_HOOK_CONTEXT_BUDGET_BYTES=0 turns the budget off: everything, in
# arrival order, no note.
run_master UserPromptSubmit "$TMP/prompt.json" "$TMP/off" HQ_HOOK_CONTEXT_BUDGET_BYTES=0
if grep -qF FLOOD-A "$TMP/off" && grep -qF FLOOD-B "$TMP/off" && grep -qF HINT-JSON "$TMP/off" \
  && grep -qF CONTROL-JSON "$TMP/off" && grep -qF ACTIVE-TASK-MARKER "$TMP/off" \
  && ! grep -qF 'HQ hook context budget' "$TMP/off" \
  && [ "$(head -n 1 "$TMP/off")" = "FLOOD-A" ]; then
  pass "budget 0 leaves the output unchanged"
else
  fail "budget 0 changed the output"
fi

# 3. A malformed value keeps the default budget.
run_master UserPromptSubmit "$TMP/prompt.json" "$TMP/bad" HQ_HOOK_CONTEXT_BUDGET_BYTES=abc
grep -qF 'HQ hook context budget' "$TMP/bad" && ! grep -qF FLOOD-B "$TMP/bad" \
  && pass "malformed budget keeps the default" || fail "malformed budget switched the budget off"

# 4. A tiny budget never cuts task or control output.
run_master UserPromptSubmit "$TMP/prompt.json" "$TMP/tiny" HQ_HOOK_CONTEXT_BUDGET_BYTES=100
if grep -qF ACTIVE-TASK-MARKER "$TMP/tiny" && grep -qF CONTROL-JSON "$TMP/tiny" \
  && ! grep -qF FLOOD-A "$TMP/tiny" && ! grep -qF HINT-JSON "$TMP/tiny"; then
  pass "tiny budget keeps only task and control output"
else
  fail "tiny budget kept the wrong chunks"
fi

# 4b. Output from a once-only notice hook (it records the notice as shown
# before it prints) and JSON that carries systemMessage (text the user sees)
# are kept under a tiny budget, like control JSON; other output is still cut.
make_child UserPromptSubmit 35-work-mesh-turn-start.sh "printf 'ONCE-NOTICE\n'; head -c 3000 /dev/zero | tr '\\0' o; printf '\n'"
make_child UserPromptSubmit 37-sysmsg-json.sh "printf '{\"systemMessage\":\"SYSMSG-JSON %s\"}' \"\$(head -c 3000 /dev/zero | tr '\\0' s)\""
run_master UserPromptSubmit "$TMP/prompt.json" "$TMP/once" HQ_HOOK_CONTEXT_BUDGET_BYTES=100
grep -qF ONCE-NOTICE "$TMP/once" && pass "once-only notice hook output is kept over the budget" \
  || fail "once-only notice output was cut"
grep -qF SYSMSG-JSON "$TMP/once" && pass "JSON with systemMessage is kept over the budget" \
  || fail "systemMessage JSON was cut"
json_line="$(grep -E '^\{' "$TMP/once" | tail -n 1)"
printf '%s' "$json_line" | jq -e '(.systemMessage | test("SYSMSG-JSON")) and .continue == true' >/dev/null 2>&1 \
  && pass "merged JSON keeps systemMessage and the control field" || fail "merged JSON lost systemMessage [${json_line:0:200}]"
[ "$(head -n 1 "$TMP/once")" = "ACTIVE-TASK-MARKER" ] && pass "task output still comes before the once-only notice" \
  || fail "first line is [$(head -n 1 "$TMP/once")], want the task hook's output"
! grep -qF FLOOD-A "$TMP/once" && ! grep -qF HINT-JSON "$TMP/once" \
  && pass "other output is still cut next to once-only and systemMessage output" || fail "tiny budget kept a flood or hint"
grep -F 'HQ hook context budget' "$TMP/once" | grep -qF '35-work-mesh-turn-start' \
  && fail "closing line names the once-only hook as left out" || pass "once-only hook is not named as left out"
rm -f "$FIX/core/hooks/UserPromptSubmit/35-work-mesh-turn-start.sh" "$FIX/core/hooks/UserPromptSubmit/37-sysmsg-json.sh"

# 4c. A 17 KB task block puts the event over the 16 KB default budget. The
# session-title hook writes its nudge marker and title state before it prints,
# so its sessionTitle JSON must still arrive: once from the hook named
# session-title, and once from any hook, because JSON carrying sessionTitle is
# kept like control JSON.
make_child UserPromptSubmit auto-session-project.sh "printf 'TASK-BLOCK\n'; head -c 17000 /dev/zero | tr '\\0' k; printf '\n'"
title_json="printf '{\"hookSpecificOutput\":{\"hookEventName\":\"UserPromptSubmit\",\"sessionTitle\":\"TITLE-MARKER\"}}'"
for title_hook in session-title.sh 38-title-json.sh; do
  make_child UserPromptSubmit "$title_hook" "$title_json"
  run_master UserPromptSubmit "$TMP/prompt.json" "$TMP/title"
  grep -qF 'HQ hook context budget' "$TMP/title" && pass "17 KB task block puts the event over the budget ($title_hook)" \
    || fail "event was not over the budget ($title_hook)"
  grep -qF TASK-BLOCK "$TMP/title" && pass "task block kept ($title_hook)" || fail "task block was cut ($title_hook)"
  json_line="$(grep -E '^\{' "$TMP/title" | tail -n 1)"
  printf '%s' "$json_line" | jq -e '.hookSpecificOutput.sessionTitle == "TITLE-MARKER"' >/dev/null 2>&1 \
    && pass "sessionTitle is kept over the budget ($title_hook)" || fail "sessionTitle was cut ($title_hook) [${json_line:0:200}]"
  grep -F 'HQ hook context budget' "$TMP/title" | grep -qF "${title_hook%.sh}" \
    && fail "closing line names $title_hook as left out" || pass "$title_hook is not named as left out"
  rm -f "$FIX/core/hooks/UserPromptSubmit/$title_hook"
done
rm -f "$FIX/core/hooks/UserPromptSubmit/auto-session-project.sh"

# 5. Under the budget the output is unchanged (arrival order, no note).
rm -f "$FIX/core/hooks/UserPromptSubmit/20-flood-b.sh"
run_master UserPromptSubmit "$TMP/prompt.json" "$TMP/under"
if [ "$(head -n 1 "$TMP/under")" = "FLOOD-A" ] && ! grep -qF 'HQ hook context budget' "$TMP/under" \
  && grep -qF ACTIVE-TASK-MARKER "$TMP/under"; then
  pass "under the budget nothing is moved or cut"
else
  fail "output changed while under the budget"
fi

# 6. Tool events are not budgeted.
make_child PostToolUse 10-big.sh "printf 'POST-BIG\n'; head -c 40000 /dev/zero | tr '\\0' p; printf '\n'"
run_master PostToolUse "$TMP/tool.json" "$TMP/post"
grep -qF POST-BIG "$TMP/post" && ! grep -qF 'HQ hook context budget' "$TMP/post" \
  && pass "PostToolUse output is not budgeted" || fail "PostToolUse output was budgeted"

# 7. Every JSON master-hook appends itself in master_foreign_bind has a paired
# json_sources entry (the PAYLOAD_AGENT_TYPE branch had none), so the budget
# rebuild cannot shift a source onto the wrong output.
bind_body="$(awk '/^master_foreign_bind\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$MASTER")"
outs="$(printf '%s\n' "$bind_body" | grep -c 'json_outputs+=' || true)"
srcs="$(printf '%s\n' "$bind_body" | grep -c 'json_sources+=' || true)"
[ -n "$bind_body" ] && [ "$outs" -gt 0 ] && [ "$outs" = "$srcs" ] \
  && pass "master_foreign_bind pairs every json_outputs entry with a json_sources entry ($outs)" \
  || fail "master_foreign_bind appends $outs json_outputs but $srcs json_sources"

if [ "$FAIL" -gt 0 ]; then
  printf 'master-hook-context-budget: %s failure(s)\n' "$FAIL" >&2
  exit 1
fi
printf 'master-hook-context-budget: PASS\n'
