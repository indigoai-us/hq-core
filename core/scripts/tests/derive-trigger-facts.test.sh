#!/usr/bin/env bash
# hq-core: public
# Tests for core/scripts/derive-trigger-facts.sh
#
# Contract:
#   <hook-json on stdin> | bash derive-trigger-facts.sh <EVENT>
#     -> prints a space-separated fact set to stdout (exit 0)
#   EVENT in {PreToolUse, PostToolUse, UserPromptSubmit, AssistantIntent}
#
# Facts = event tokens + best-effort static session facts. These tests assert
# only the DETERMINISTIC event/transcript-derived tokens (static facts such
# as company/repo/branch depend on live cwd+git and are covered by the live
# verification step in the plan, not here).
#
# Token derivation contract under test:
#   Tokens are OPEN — the fact set for a text event is EVERY word token in the
#   text (lowercased, letter-led, length >= 2), NOT a curated keyword list. On
#   top of the literal words, non-literal facts are derived: op:// / AWS_PROFILE
#   / a .env path -> secret; a shared branch name (main/master/staging/
#   production) -> shared_branch; file refs -> basename + .ext; /mentions -> slash.
#   PreToolUse Bash command -> word tokens of the command (git, push, commit, ...).
#   PreToolUse non-Bash -> lowercased tool name token (Glob->glob, Grep->grep,
#     Read->read, Write->write, Edit->edit).
#   UserPromptSubmit -> word tokens from the prompt text.
#   PostToolUse -> word tokens from the tool OUTPUT (tool_response) text.
#   AssistantIntent -> word tokens from assistant message text emitted since
#     the last user turn in transcript_path, AND NOTHING ELSE (no command/prompt
#     tokens, no static facts). This is the dedicated AI-message channel; the
#     raw PreToolUse/UserPromptSubmit fact sets do NOT include look-back.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/derive-trigger-facts.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# has <expected-token> <event> <json>  -> asserts token present in output
has() {
  local tok="$1" event="$2" json="$3" out
  out="$(printf '%s' "$json" | bash "$SRC" "$event" 2>/dev/null)" || fail "$event: script errored"
  printf '%s' " $out " | grep -qw "$tok" || fail "$event: expected token '$tok' in fact set, got: [$out]"
}

# hasnot <unexpected-token> <event> <json>
hasnot() {
  local tok="$1" event="$2" json="$3" out
  out="$(printf '%s' "$json" | bash "$SRC" "$event" 2>/dev/null)" || fail "$event: script errored"
  printf '%s' " $out " | grep -qw "$tok" && fail "$event: did NOT expect token '$tok', got: [$out]" || true
}

[ -f "$SRC" ] || fail "derive-trigger-facts.sh not found at $SRC (implement it)"

# ---- PreToolUse: Bash command tokenization ----
J='{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
has git          PreToolUse "$J"
has push         PreToolUse "$J"
has shared_branch PreToolUse "$J"

J='{"tool_name":"Bash","tool_input":{"command":"git commit -m wip"}}'
has git    PreToolUse "$J"
has commit PreToolUse "$J"
hasnot push PreToolUse "$J"

J='{"tool_name":"Bash","tool_input":{"command":"gh pr create -R o/r"}}'
has pr PreToolUse "$J"

J='{"tool_name":"Bash","tool_input":{"command":"AWS_PROFILE=x aws s3 ls"}}'
has secret PreToolUse "$J"

J='{"tool_name":"Bash","tool_input":{"command":"cat repos/private/x/.env"}}'
has secret PreToolUse "$J"

# ---- PreToolUse: non-Bash tool name token ----
has glob  PreToolUse '{"tool_name":"Glob","tool_input":{"pattern":"**/*.ts"}}'
has grep  PreToolUse '{"tool_name":"Grep","tool_input":{"pattern":"foo"}}'
has write PreToolUse '{"tool_name":"Write","tool_input":{"file_path":"/x"}}'

# ---- UserPromptSubmit: prompt keyword tokens ----
has deploy UserPromptSubmit '{"prompt":"please deploy to prod"}'
has push   UserPromptSubmit '{"prompt":"push my changes upstream"}'
hasnot deploy UserPromptSubmit '{"prompt":"what does this function do?"}'

# ---- PostToolUse: tokens from tool OUTPUT, not just input ----
J='{"tool_name":"Bash","tool_input":{"command":"./run"},"tool_response":{"stdout":"starting deploy to vercel"}}'
has deploy PostToolUse "$J"

# ---- AssistantIntent: look-back is surfaced ONLY here, not on raw events ----
# REAL Claude Code transcript schema: assistant text at .message.content[].text.
TRANSCRIPT="$TMP/t.jsonl"
{
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"start"}}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I will push the branch"}]}}'
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"actually deploy it"}}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"running the deploy now"},{"type":"tool_use","name":"Bash","input":{"command":"true"}}]}}'
} > "$TRANSCRIPT"

# UserPromptSubmit no longer folds in look-back: a neutral prompt yields no
# "deploy" even though the transcript has it.
J="$(printf '{"prompt":"go ahead","transcript_path":"%s"}' "$TRANSCRIPT")"
hasnot deploy UserPromptSubmit "$J"

# AssistantIntent surfaces "deploy" from the most recent assistant turn (after
# the last user turn) and NOT "push" (which predates the last user turn).
has deploy   AssistantIntent "$J"
hasnot push  AssistantIntent "$J"

# AssistantIntent ignores the command and static facts entirely: a `git status`
# command must NOT contribute `git` to the AssistantIntent fact set.
JC="$(printf '{"tool_name":"Bash","tool_input":{"command":"git status"},"transcript_path":"%s"}' "$TRANSCRIPT")"
has deploy AssistantIntent "$JC"
hasnot git AssistantIntent "$JC"

# ---- `always` token: present in every event's fact set ----
has always PreToolUse      '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
has always UserPromptSubmit '{"prompt":"hello"}'
has always SessionStart    '{}'
has always AssistantIntent  '{}'

# ---- SessionStart: static facts + always only; NO command tokens ----
has    always SessionStart '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
hasnot git    SessionStart '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
hasnot push   SessionStart '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'

# ---- Filename tokens: a named file -> literal basename + `.ext` ----
# Lets a file-scoped policy fire from the file being named, on any text event.
# (eval-trigger identifiers allow dots/slashes, so tokens are literal.)
J='{"prompt":"edit .claude/settings.json"}'
has settings.json UserPromptSubmit "$J"
has .json         UserPromptSubmit "$J"
has settings.local.json UserPromptSubmit '{"prompt":"open .claude/settings.local.json"}'
has .mcp.json     UserPromptSubmit '{"prompt":"add a server to .mcp.json"}'
has .png          UserPromptSubmit '{"prompt":"review the shot.png export"}'
has shot.png      UserPromptSubmit '{"prompt":"review the shot.png export"}'
# Version-like dotted numbers are NOT files (ext must be letter-led).
hasnot .5 UserPromptSubmit '{"prompt":"bump to v1.5"}'
# Neutral prose emits no file token.
hasnot .do UserPromptSubmit '{"prompt":"what does this function do?"}'
# Filename tokens reach the AssistantIntent channel from the look-back text.
TFILE="$TMP/t2.jsonl"
{
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"go"}}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I will edit .mcp.json next"}]}}'
} > "$TFILE"
has .mcp.json AssistantIntent "$(printf '{"prompt":"ok","transcript_path":"%s"}' "$TFILE")"

# ---- Slash-command tokens: a /command mention -> /command ----
has /brainstorm UserPromptSubmit '{"prompt":"/brainstorm a new approach"}'
has /deep-plan  UserPromptSubmit '{"prompt":"please run /deep-plan now"}'
# Path segments are NOT slash-commands (slash must follow a space/start).
hasnot /public UserPromptSubmit '{"prompt":"look in repos/public for code"}'

# ---- OPEN tokenization: any word in the text is a fact (no curated vocab) ----
# These words are deliberately NOT in any keyword list — they must still surface.
has refactor UserPromptSubmit '{"prompt":"refactor the auth module"}'
has monitor  UserPromptSubmit '{"prompt":"add a monitor for the queue"}'
has docker   UserPromptSubmit '{"prompt":"build the docker image"}'
has linear   UserPromptSubmit '{"prompt":"sync the linear issue"}'
has supabase UserPromptSubmit '{"prompt":"wire up supabase auth"}'
has rename   UserPromptSubmit '{"prompt":"rename this function"}'
# Open tokens reach the AssistantIntent channel via look-back too.
TI="$TMP/t3.jsonl"
{
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"go"}}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I will refactor the dashboard component"}]}}'
} > "$TI"
has refactor  AssistantIntent "$(printf '{"prompt":"ok","transcript_path":"%s"}' "$TI")"
has dashboard AssistantIntent "$(printf '{"prompt":"ok","transcript_path":"%s"}' "$TI")"
# Single chars and pure numbers are NOT facts (length >= 2, letter-led).
hasnot 5 UserPromptSubmit '{"prompt":"bump to 5 now"}'

# ---- AssistantIntent look-back parses the REAL transcript schema ----
# Regression guard: the look-back MUST read assistant text from
# .message.content[].text (real Claude Code), not only a flat top-level
# .content. A real-schema transcript whose last assistant turn says "deploy"
# must surface `deploy`.
TR_REAL="$TMP/real.jsonl"
{
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"go"}}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I will deploy to prod"},{"type":"tool_use","name":"Bash","input":{"command":"true"}}]}}'
} > "$TR_REAL"
has deploy AssistantIntent "$(printf '{"prompt":"ok","transcript_path":"%s"}' "$TR_REAL")"
# Flat top-level .content is still accepted (lenient fallback for simple inputs).
TR_FLAT="$TMP/flat.jsonl"
{
  printf '%s\n' '{"type":"user","content":"go"}'
  printf '%s\n' '{"type":"assistant","content":"I will deploy to prod"}'
} > "$TR_FLAT"
has deploy AssistantIntent "$(printf '{"prompt":"ok","transcript_path":"%s"}' "$TR_FLAT")"

echo "PASS: derive-trigger-facts.sh"
