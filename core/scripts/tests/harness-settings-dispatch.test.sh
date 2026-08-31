#!/usr/bin/env bash
# hq-core: public
# harness-settings-dispatch.test.sh — FULL-MATRIX parity guard for single-source
# hook dispatch.
#
# The Codex and Grok adapters read .claude/settings.json live (via
# core/scripts/lib/hook-adapter-core.sh) instead of carrying their own dispatch
# tables. This test derives the complete (event x tool) matrix FROM settings.json
# and proves each adapter dispatches every settings-registered hook for every
# combination its runtime can express. Combinations a runtime genuinely cannot
# express (tool/event does not exist there) are declared in an explicit
# per-runtime EXCEPTIONS list below — an undeclared gap fails the build.
#
# ESSENTIAL exceptions (tool/event absent in the runtime — cannot fire):
#   both  : PreToolUse EnterPlanMode        (no native plan-mode entry tool)
#   both  : PreToolUse/PostToolUse MultiEdit, NotebookEdit
#           (tool names never emitted; their hook sets are subsets of Edit/Write,
#            which ARE dispatched, so no guard coverage is lost)
#   codex : PostToolUse AskUserQuestion, WebFetch  (no such tool events)
#           Tool events are intentionally open-ended: native/custom tool names
#           pass through unchanged, with spawn_agent canonicalized to Agent.
#   codex : Notification event              (unsupported by Codex hooks)
#   grok  : PostToolUse AskUserQuestion, WebFetch         (no such tool events)
#           (Agent IS covered: grok spawn_subagent -> Agent-matched hooks)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
SRC_SETTINGS="$ROOT/.claude/settings.json"
SRC_CORE="$ROOT/core/scripts/lib/hook-adapter-core.sh"
SRC_CODEX="$ROOT/.codex/hooks/hq-codex-hook-adapter.sh"
SRC_GROK="$ROOT/.grok/hooks/hq-grok-hook-adapter.sh"

FAIL=0
pass() { echo "  ok: $1"; }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable" >&2; exit 0; }

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

mkdir -p "$FIX/.claude/hooks" "$FIX/.codex/hooks" "$FIX/.grok/hooks" \
         "$FIX/core/scripts/lib"
cp "$SRC_SETTINGS" "$FIX/.claude/settings.json"
cp "$SRC_CORE" "$FIX/core/scripts/lib/hook-adapter-core.sh"
cp "$SRC_CODEX" "$FIX/.codex/hooks/hq-codex-hook-adapter.sh"
cp "$SRC_GROK" "$FIX/.grok/hooks/hq-grok-hook-adapter.sh"

# Instance-local custom guard: Codex calls this operation `spawn_agent`, while
# Claude's canonical matcher is `Agent`. Keeping it in the fixture proves both
# the alias and the general custom-tool dispatch path without adding a shipped
# policy decision to the release settings.
jq '.hooks.PreToolUse += [{
  matcher: "Agent",
  hooks: [{
    type: "command",
    command: "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/hook-gate.sh\" block-subagents \"$CLAUDE_PROJECT_DIR/.claude/hooks/block-subagents.sh\" PreToolUse"
  }]
}, {
  matcher: "company_deny_tool",
  hooks: [{
    type: "command",
    command: "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/hook-gate.sh\" custom-json-deny \"$CLAUDE_PROJECT_DIR/.claude/hooks/custom-json-deny.sh\" PreToolUse"
  }]
}]' "$FIX/.claude/settings.json" > "$FIX/.claude/settings.json.next"
mv "$FIX/.claude/settings.json.next" "$FIX/.claude/settings.json"
: > "$FIX/core/scripts/hook-lib.sh"
: > "$FIX/core/scripts/migrate-policy-triggers.sh"

# Stub gate: drain stdin FIRST (avoid SIGPIPE under pipefail), then record.
cat > "$FIX/.claude/hooks/hook-gate.sh" <<'STUB'
#!/bin/bash
id="$1"
payload="$(cat 2>/dev/null || true)"
{ printf 'gate:%s\n' "$id" >> "${HQAD_TEST_LOG:-/dev/null}"; } 2>/dev/null || true
# For journal-autocapture, record the tool_name the adapter forwarded so the
# suite can prove WebSearch/Agent payloads are canonicalized (not left as
# web_search / Task, which the hook would ignore).
if [ "$id" = "journal-autocapture" ]; then
  jt="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"
  { printf 'jtool:%s\n' "$jt" >> "${HQAD_TEST_LOG:-/dev/null}"; } 2>/dev/null || true
fi
if [ "$id" = "custom-json-deny" ]; then
  printf '%s\n' '{"decision":"block","reason":"custom tool denied"}'
fi
exit 0
STUB
cat > "$FIX/.claude/hooks/master-hook.sh" <<'STUB'
#!/bin/bash
payload="$(cat 2>/dev/null || true)"
{ printf 'master:%s\n' "$1" >> "${HQAD_TEST_LOG:-/dev/null}"; } 2>/dev/null || true
tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"
{ printf 'mtool:%s\n' "$tool" >> "${HQAD_TEST_LOG:-/dev/null}"; } 2>/dev/null || true
if [ "$1" = "PreToolUse" ] && [ "$tool" = "company_mixed_deny_tool" ]; then
  printf '%s\n' 'context emitted before the company guard result'
  printf '%s\n' '{"decision":"block","reason":"mixed company denial"}'
fi
exit 0
STUB
cat > "$FIX/.claude/hooks/reindex.sh" <<'STUB'
#!/bin/bash
cat >/dev/null 2>&1 || true
{ printf 'script:reindex\n' >> "${HQAD_TEST_LOG:-/dev/null}"; } 2>/dev/null || true
exit 0
STUB
# Stub every referenced hook script so the missing-script guard keeps them all.
for id in $(jq -r '.hooks[][]?.hooks[]?.command' "$FIX/.claude/settings.json" \
              | grep -oE '/[a-z0-9-]+\.sh"' | tr -d '/"' | sort -u); do
  f="$FIX/.claude/hooks/$id"
  [ -e "$f" ] && continue
  printf '#!/bin/bash\nexit 0\n' > "$f"
done
for extra in inject-codex-checkpoint-reprompt auto-capture-registry; do
  f="$FIX/.claude/hooks/$extra.sh"
  [ -e "$f" ] || printf '#!/bin/bash\nexit 0\n' > "$f"
done
chmod +x "$FIX/.claude/hooks/"*.sh 2>/dev/null || true

export HQ_ROOT="$FIX" HQ_ALLOW_HQ_WORKTREE=1

CODEX="$FIX/.codex/hooks/hq-codex-hook-adapter.sh"
GROK="$FIX/.grok/hooks/hq-grok-hook-adapter.sh"

# Bash 3.2 on stock macOS cannot safely consume the literal SOH framing byte
# the iterator used to place between matcher and command. Keep control bytes out
# of the shell source; jq now emits validated, shell-escaped record words.
if LC_ALL=C od -An -t x1 "$FIX/core/scripts/lib/hook-adapter-core.sh" \
    | tr -s ' ' '\n' | grep -x '01' >/dev/null; then
  fail "shared iterator source contains a literal SOH framing byte"
else
  pass "shared iterator source is free of literal SOH framing bytes"
fi

# A framing failure after settings validation must not look like a valid empty
# hook set. Stub only the record-producing jq call and prove the iterator uses
# the critical Bash fallback guards rather than emitting zero records.
REAL_JQ="$(command -v jq)"
framing_fallback="$({
  set +u
  . "$FIX/core/scripts/lib/hook-adapter-core.sh"
  jq() {
    case "${1:-}" in
      -c|-r) printf '%s\n' 'not-a-json-record'; return 0 ;;
      *) command "$REAL_JQ" "$@" ;;
    esac
  }
  hqad_iter_settings "PreToolUse" "Bash"
} 2>/dev/null)"
if printf '%s\n' "$framing_fallback" | grep -q $'^gate\tmandatory-scope-authorizer\t'; then
  pass "malformed iterator framing uses critical PreToolUse fallback"
else
  fail "malformed iterator framing silently emitted zero critical guards"
fi

expected_gate_ids() { # <event> <tool>
  ( set +u; . "$FIX/core/scripts/lib/hook-adapter-core.sh"
    HQ_ROOT="$FIX" hqad_iter_settings "$1" "$2" \
      | awk -F'\t' '$1=="gate"{print $2}' | sort -u )
}

settings_has_master() { # <event>
  jq -e --arg ev "$1" '
    [.hooks[$ev][]?.hooks[]?.command | select(test("master-hook"))] | length > 0
  ' "$FIX/.claude/settings.json" >/dev/null 2>&1
}

run_recorded() { # <adapter> <payload> -> prints full record log
  local log; log="$(mktemp)"
  HQAD_TEST_LOG="$log" HQ_ROOT="$FIX" HQ_ALLOW_HQ_WORKTREE=1 \
    bash "$1" >/dev/null 2>&1 <<<"$2" || true
  cat "$log" 2>/dev/null
  rm -f "$log"
}

# Record every (event/tool) combination an assert_combo actually exercised, so
# the completeness pass can verify coverage per event AND tool — not just by tool
# name. Newline-delimited; queried with a fixed-string grep.
ASSERTED=""

assert_combo() { # <runtime-label> <adapter> <event> <tool> <payload>
  local label="$1" adapter="$2" event="$3" tool="$4" payload="$5"
  local expected recorded gates missing
  ASSERTED="${ASSERTED}${event}/${tool}
"
  expected="$(expected_gate_ids "$event" "$tool")"
  recorded="$(run_recorded "$adapter" "$payload")"
  gates="$(printf '%s\n' "$recorded" | grep '^gate:' | sed 's/^gate://' | sort -u)"
  missing="$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$gates") | grep -v '^$' || true)"
  if [ -n "$missing" ]; then
    fail "$label $event/$tool DROPPED: $(printf '%s' "$missing" | tr '\n' ' ')"
  else
    pass "$label $event/$tool (all $(printf '%s\n' "$expected" | grep -c . ) settings hooks)"
  fi
  if settings_has_master "$event"; then
    if printf '%s\n' "$recorded" | grep -q "^master:$event$"; then
      pass "$label $event/$tool master fan-out"
    else
      fail "$label $event/$tool did not run master-hook"
    fi
  fi
}

# --------------------------------------------------------------------------
# 1. Non-tool events — full sweep per runtime.
# --------------------------------------------------------------------------
echo "[non-tool events]"
for ev in SessionStart UserPromptSubmit Stop PreCompact SessionEnd SubagentStop; do
  assert_combo "codex" "$CODEX" "$ev" "ANY" \
    '{"hook_event_name":"'"$ev"'","cwd":"'"$FIX"'","session_id":"t"}'
  assert_combo "grok" "$GROK" "$ev" "ANY" \
    '{"hookEventName":"'"$ev"'","cwd":"'"$FIX"'","sessionId":"t"}'
done
# Notification: grok-only (Codex hooks do not support the event — declared exception).
assert_combo "grok" "$GROK" "Notification" "ANY" \
  '{"hookEventName":"Notification","cwd":"'"$FIX"'","sessionId":"t"}'

# --------------------------------------------------------------------------
# 2. Tool events — every settings-registered tool each runtime can express.
#    Payloads use each runtime's NATIVE tool names to also exercise aliasing.
# --------------------------------------------------------------------------
echo "[PreToolUse tools]"
FP="$FIX/README.md"
for spec in \
  "Bash|Bash|run_terminal_command" \
  "Read|Read|read_file" \
  "Grep|Grep|grep" \
  "Glob|Glob|list_dir" \
  "Edit|Edit|search_replace" \
  "Write|Write|write" \
; do
  canon="${spec%%|*}"; rest="${spec#*|}"; ctool="${rest%%|*}"; gtool="${rest#*|}"
  case "$canon" in
    Bash)
      cxp='{"hook_event_name":"PreToolUse","tool_name":"'"$ctool"'","cwd":"'"$FIX"'","session_id":"t","tool_input":{"command":"echo hi"}}'
      gkp='{"hookEventName":"PreToolUse","toolName":"'"$gtool"'","cwd":"'"$FIX"'","sessionId":"t","toolInput":{"command":"echo hi"}}'
      ;;
    Glob)
      cxp='{"hook_event_name":"PreToolUse","tool_name":"'"$ctool"'","cwd":"'"$FIX"'","session_id":"t","tool_input":{"path":"'"$FIX"'/core"}}'
      gkp='{"hookEventName":"PreToolUse","toolName":"'"$gtool"'","cwd":"'"$FIX"'","sessionId":"t","toolInput":{"target_directory":"'"$FIX"'/core"}}'
      ;;
    Grep)
      cxp='{"hook_event_name":"PreToolUse","tool_name":"'"$ctool"'","cwd":"'"$FIX"'","session_id":"t","tool_input":{"pattern":"x","path":"'"$FIX"'/core"}}'
      gkp='{"hookEventName":"PreToolUse","toolName":"'"$gtool"'","cwd":"'"$FIX"'","sessionId":"t","toolInput":{"pattern":"x","path":"'"$FIX"'/core"}}'
      ;;
    *)
      cxp='{"hook_event_name":"PreToolUse","tool_name":"'"$ctool"'","cwd":"'"$FIX"'","session_id":"t","tool_input":{"file_path":"'"$FP"'"}}'
      gkp='{"hookEventName":"PreToolUse","toolName":"'"$gtool"'","cwd":"'"$FIX"'","sessionId":"t","toolInput":{"file_path":"'"$FP"'","content":"x"}}'
      ;;
  esac
  assert_combo "codex" "$CODEX" "PreToolUse" "$canon" "$cxp"
  assert_combo "grok" "$GROK" "PreToolUse" "$canon" "$gkp"
done

# Codex's native spawn name must reach Claude's canonical Agent matcher.
assert_combo "codex" "$CODEX" "PreToolUse" "Agent" \
  '{"hook_event_name":"PreToolUse","tool_name":"spawn_agent","cwd":"'"$FIX"'","session_id":"t","tool_input":{"task_name":"probe"}}'

# An arbitrary provider/plugin tool name has no canonical alias. It must still
# reach the unscoped master fan-out unchanged so personal custom hooks can match
# it by its native name instead of being silently dropped by the adapter.
custom_payload='{"hook_event_name":"PreToolUse","tool_name":"company_custom_tool","cwd":"'"$FIX"'","session_id":"t","tool_input":{"value":"x"}}'
custom_recorded="$(run_recorded "$CODEX" "$custom_payload")"
if printf '%s\n' "$custom_recorded" | grep -q '^master:PreToolUse$'; then
  pass "codex custom PreToolUse reaches master fan-out"
else
  fail "codex custom PreToolUse was dropped before master fan-out"
fi
if printf '%s\n' "$custom_recorded" | grep -q '^mtool:company_custom_tool$'; then
  pass "codex custom PreToolUse preserves its native tool name"
else
  fail "codex custom PreToolUse did not preserve its native tool name"
fi

# A custom PreToolUse hook can deny by returning structured JSON with status 0.
# The adapter must preserve that as Codex control flow, not flatten or drop it.
deny_payload='{"hook_event_name":"PreToolUse","tool_name":"company_deny_tool","cwd":"'"$FIX"'","session_id":"t","tool_input":{"value":"x"}}'
ASSERTED="${ASSERTED}PreToolUse/company_deny_tool
"
deny_output="$(HQ_ROOT="$FIX" HQ_ALLOW_HQ_WORKTREE=1 bash "$CODEX" <<<"$deny_payload" 2>/dev/null || true)"
if printf '%s' "$deny_output" | jq -e '
  .decision == "block"
  and .reason == "custom tool denied"
  and .hookSpecificOutput.hookEventName == "PreToolUse"
  and .hookSpecificOutput.permissionDecision == "deny"
  and .hookSpecificOutput.permissionDecisionReason == "custom tool denied"
' >/dev/null 2>&1; then
  pass "codex custom PreToolUse preserves structured JSON denial"
else
  fail "codex custom PreToolUse swallowed structured JSON denial: $deny_output"
fi

# The master fan-out can emit plain context before a company hook's compact
# structured denial. The adapter must recover the trailing control object
# instead of treating the combined output as harmless display context.
mixed_deny_payload='{"hook_event_name":"PreToolUse","tool_name":"company_mixed_deny_tool","cwd":"'"$FIX"'","session_id":"t","tool_input":{"value":"x"}}'
mixed_deny_output="$(HQ_ROOT="$FIX" HQ_ALLOW_HQ_WORKTREE=1 bash "$CODEX" <<<"$mixed_deny_payload" 2>/dev/null || true)"
if printf '%s' "$mixed_deny_output" | jq -e '
  .decision == "block"
  and .reason == "mixed company denial"
  and .hookSpecificOutput.permissionDecision == "deny"
' >/dev/null 2>&1; then
  pass "codex custom PreToolUse preserves denial mixed with master context"
else
  fail "codex custom PreToolUse swallowed denial mixed with master context: $mixed_deny_output"
fi

echo "[PostToolUse tools]"
for spec in \
  "Bash|Bash|run_terminal_command" \
  "Edit|Edit|search_replace" \
  "Write|Write|write" \
; do
  canon="${spec%%|*}"; rest="${spec#*|}"; ctool="${rest%%|*}"; gtool="${rest#*|}"
  if [ "$canon" = "Bash" ]; then
    cxp='{"hook_event_name":"PostToolUse","tool_name":"'"$ctool"'","cwd":"'"$FIX"'","session_id":"t","tool_input":{"command":"echo hi"},"tool_response":{"exit_code":0}}'
    gkp='{"hookEventName":"PostToolUse","toolName":"'"$gtool"'","cwd":"'"$FIX"'","sessionId":"t","toolInput":{"command":"echo hi"}}'
  else
    cxp='{"hook_event_name":"PostToolUse","tool_name":"'"$ctool"'","cwd":"'"$FIX"'","session_id":"t","tool_input":{"file_path":"'"$FP"'"},"tool_response":{"exit_code":0}}'
    gkp='{"hookEventName":"PostToolUse","toolName":"'"$gtool"'","cwd":"'"$FIX"'","sessionId":"t","toolInput":{"file_path":"'"$FP"'","content":"x"}}'
  fi
  assert_combo "codex" "$CODEX" "PostToolUse" "$canon" "$cxp"
  assert_combo "grok" "$GROK" "PostToolUse" "$canon" "$gkp"
done

# The same open-ended contract applies after tool execution. A Codex
# spawn_agent PostToolUse event is only a launch acknowledgement, so keep its
# native name and do not send it through completed-Agent result hooks.
custom_post_payload='{"hook_event_name":"PostToolUse","tool_name":"company_custom_tool","cwd":"'"$FIX"'","session_id":"t","tool_input":{"value":"x"},"tool_response":{"ok":true}}'
custom_post_recorded="$(run_recorded "$CODEX" "$custom_post_payload")"
if printf '%s\n' "$custom_post_recorded" | grep -q '^master:PostToolUse$'; then
  pass "codex custom PostToolUse reaches master fan-out"
else
  fail "codex custom PostToolUse was dropped before master fan-out"
fi
if printf '%s\n' "$custom_post_recorded" | grep -q '^mtool:company_custom_tool$'; then
  pass "codex custom PostToolUse preserves its native tool name"
else
  fail "codex custom PostToolUse did not preserve its native tool name"
fi

# Plan sync: codex update_plan -> ExitPlanMode. (Grok has no plan tool — exception.)
assert_combo "codex" "$CODEX" "PostToolUse" "ExitPlanMode" \
  '{"hook_event_name":"PostToolUse","tool_name":"update_plan","cwd":"'"$FIX"'","session_id":"t","tool_input":{}}'

# WebSearch: grok web_search (native); codex web_search (best-effort mapping).
assert_combo "grok" "$GROK" "PostToolUse" "WebSearch" \
  '{"hookEventName":"PostToolUse","toolName":"web_search","cwd":"'"$FIX"'","sessionId":"t","toolInput":{"query":"x"}}'
assert_combo "codex" "$CODEX" "PostToolUse" "WebSearch" \
  '{"hook_event_name":"PostToolUse","tool_name":"web_search","cwd":"'"$FIX"'","session_id":"t","tool_input":{"query":"x"}}'

# Subagent journaling: grok spawn_subagent -> Agent-matched hooks.
assert_combo "grok" "$GROK" "PostToolUse" "Agent" \
  '{"hookEventName":"PostToolUse","toolName":"spawn_subagent","cwd":"'"$FIX"'","sessionId":"t","toolInput":{"prompt":"x"}}'

echo "[journal payload canonicalization]"
# journal-autocapture keys on the canonical tool_name; the adapters must forward
# WebSearch / Agent (not web_search / Task) or the record would be empty.
journal_tool_for() { # <adapter> <payload>
  run_recorded "$1" "$2" | grep '^jtool:' | sed 's/^jtool://' | head -1
}
assert_journal_tool() { # <label> <adapter> <payload> <expected>
  local got; got="$(journal_tool_for "$2" "$3")"
  if [ "$got" = "$4" ]; then pass "$1 forwards tool_name=$4 to journal-autocapture"
  else fail "$1 forwarded tool_name='$got' (want $4) to journal-autocapture"; fi
}
assert_journal_tool "grok web_search" "$GROK" \
  '{"hookEventName":"PostToolUse","toolName":"web_search","cwd":"'"$FIX"'","sessionId":"t","toolInput":{"query":"x"}}' "WebSearch"
assert_journal_tool "grok spawn_subagent" "$GROK" \
  '{"hookEventName":"PostToolUse","toolName":"spawn_subagent","cwd":"'"$FIX"'","sessionId":"t","toolInput":{"prompt":"x"}}' "Agent"
assert_journal_tool "codex web_search" "$CODEX" \
  '{"hook_event_name":"PostToolUse","tool_name":"web_search","cwd":"'"$FIX"'","session_id":"t","tool_input":{"query":"x"}}' "WebSearch"
codex_spawn_post='{"hook_event_name":"PostToolUse","tool_name":"spawn_agent","cwd":"'"$FIX"'","session_id":"t","tool_input":{"task_name":"probe"},"tool_response":{"agent_id":"agent-1","task_name":"probe","status":"running"}}'
codex_spawn_post_recorded="$(run_recorded "$CODEX" "$codex_spawn_post")"
if printf '%s\n' "$codex_spawn_post_recorded" | grep -q '^jtool:'; then
  fail "codex spawn acknowledgement was journaled as a completed Agent result"
else
  pass "codex spawn acknowledgement bypasses completed-Agent journaling"
fi
if printf '%s\n' "$codex_spawn_post_recorded" | grep -q '^mtool:spawn_agent$'; then
  pass "codex spawn acknowledgement preserves native tool_name for master hooks"
else
  fail "codex spawn acknowledgement did not preserve native tool_name"
fi

codex_subagent_stop='{"hook_event_name":"SubagentStop","cwd":"'"$FIX"'","session_id":"t","agent_id":"agent-1","agent_type":"explorer","last_assistant_message":"completed result"}'
codex_subagent_stop_recorded="$(run_recorded "$CODEX" "$codex_subagent_stop")"
if printf '%s\n' "$codex_subagent_stop_recorded" | grep -q '^jtool:Agent$'; then
  pass "codex SubagentStop journals a completed Agent result"
else
  fail "codex SubagentStop did not journal a completed Agent result"
fi
if [ "$(printf '%s\n' "$codex_subagent_stop_recorded" | grep -c '^master:SubagentStop$' || true)" = "1" ]; then
  pass "codex SubagentStop still runs its master fan-out exactly once"
else
  fail "codex SubagentStop did not run its master fan-out exactly once"
fi

master_tool_for() { # <adapter> <payload>
  run_recorded "$1" "$2" | grep '^mtool:' | sed 's/^mtool://' | head -1
}
spawn_master_tool="$(master_tool_for "$CODEX" \
  '{"hook_event_name":"PreToolUse","tool_name":"spawn_agent","cwd":"'"$FIX"'","session_id":"t","tool_input":{"task_name":"probe"}}')"
if [ "$spawn_master_tool" = "Agent" ]; then
  pass "codex spawn_agent forwards canonical tool_name=Agent to master hooks"
else
  fail "codex spawn_agent forwarded tool_name='$spawn_master_tool' (want Agent) to master hooks"
fi

# --------------------------------------------------------------------------
# 3. Completeness check — every (event x tool-matcher) pair in settings.json is
#    either covered above or explicitly declared an exception here. A NEW
#    matcher added to settings.json fails this until it is covered or declared.
# --------------------------------------------------------------------------
echo "[matrix completeness]"
# Runtime-agnostic exceptions the adapters genuinely cannot express, keyed by
# "<event>/<tool>". Prints the reason (returns 0) for a declared exception, else
# returns 1. Bash-3.2 safe (no associative arrays — HQ supports macOS system
# bash). WebSearch and Agent are exercised above (Codex for Agent PreToolUse;
# Grok for the completed Agent PostToolUse lifecycle).
exception_reason() {
  case "$1" in
    PreToolUse/EnterPlanMode) echo "no native plan-mode entry tool in codex/grok" ;;
    PreToolUse/MultiEdit) echo "tool name never emitted; hook set subset of Edit/Write" ;;
    PostToolUse/MultiEdit) echo "tool name never emitted; hook set subset of Edit/Write" ;;
    PreToolUse/NotebookEdit) echo "tool name never emitted; enforce-vault-write-access covered via Bash/Edit/Write" ;;
    PostToolUse/AskUserQuestion) echo "no such tool event in codex/grok" ;;
    PostToolUse/WebFetch) echo "no such tool event in codex/grok" ;;
    *) return 1 ;;
  esac
}
# Every (event, tool) matcher in settings.json must be either EXERCISED by an
# assert_combo above (tracked in ASSERTED, keyed by event AND tool) OR a declared
# exception. A new matcher — even reusing a covered tool name on a new event —
# fails this until it is covered or declared.
while IFS=$'\t' read -r ev matcher; do
  [ -n "$matcher" ] || continue
  [ "$matcher" = "*" ] && continue
  case "$ev" in PreToolUse|PostToolUse) ;; *) continue ;; esac
  # Split multi-tool matchers (Claude uses plain names; also handle , and |).
  for tool in $(printf '%s' "$matcher" | tr ',|' '  '); do
    [ -n "$tool" ] || continue
    key="$ev/$tool"
    if printf '%s\n' "$ASSERTED" | grep -qxF "$key"; then
      continue
    fi
    if reason="$(exception_reason "$key")"; then
      echo "  declared exception: $key — $reason"
      continue
    fi
    fail "UNCOVERED matcher $key: add an assert_combo for it or declare an exception with a reason"
  done
done < <(jq -r '.hooks | to_entries[] | .key as $ev | .value[] | select(.matcher) | "\($ev)\t\(.matcher)"' "$FIX/.claude/settings.json" | sort -u)

if [ "$FAIL" -eq 0 ]; then
  echo "harness-settings-dispatch: all passed"
  exit 0
fi
echo "harness-settings-dispatch: $FAIL failed" >&2
exit 1
