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
#   codex : PostToolUse Agent, AskUserQuestion, WebFetch  (no such tool events)
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
exit 0
STUB
cat > "$FIX/.claude/hooks/master-hook.sh" <<'STUB'
#!/bin/bash
cat >/dev/null 2>&1 || true
{ printf 'master:%s\n' "$1" >> "${HQAD_TEST_LOG:-/dev/null}"; } 2>/dev/null || true
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

# --------------------------------------------------------------------------
# 3. Completeness check — every (event x tool-matcher) pair in settings.json is
#    either covered above or explicitly declared an exception here. A NEW
#    matcher added to settings.json fails this until it is covered or declared.
# --------------------------------------------------------------------------
echo "[matrix completeness]"
# Runtime-agnostic exceptions the adapters genuinely cannot express, keyed by
# "<event>/<tool>". Prints the reason (returns 0) for a declared exception, else
# returns 1. Bash-3.2 safe (no associative arrays — HQ supports macOS system
# bash). WebSearch/Agent are NOT here: they are exercised by assert_combo above.
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
