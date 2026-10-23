#!/usr/bin/env bash
# Regression: a deploy link that only appears in a folded (pre-tool-call) text
# block must block the stop once; a link restated in the final text passes;
# stop_hook_active never re-blocks.
set -euo pipefail

ROOT="$(git -C "$(dirname "$0")/../../.." rev-parse --show-toplevel)"
HOOK="$ROOT/.claude/hooks/enforce-final-message-link-placement.sh"
[ -r "$HOOK" ] || { printf 'FAIL hook missing\n' >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/final-link.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

URL='https://example-client-storyboard-preview.hq.work'
user='{"type":"user","message":{"role":"user","content":"show me the link"}}'
a_link='{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Here is the storyboard link (members only): '"$URL"'"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"true"}}]}}'
tool_res='{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}'
a_final_nolink='{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"When you have had a look, tell me whether the direction holds."}]}}'
a_final_link='{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"It is live here (members only): '"$URL"'/"}]}}'

run_hook() { # $1 transcript file, $2 stop_hook_active
  printf '{"transcript_path":"%s","stop_hook_active":%s}' "$1" "$2" | bash "$HOOK"
}

# Case 1: link only in the folded block -> block.
printf '%s\n' "$user" "$a_link" "$tool_res" "$a_final_nolink" > "$TMP/t1.jsonl"
OUT="$(run_hook "$TMP/t1.jsonl" false)"
printf '%s' "$OUT" | grep -q '"decision":"block"' || fail "folded-only link did not block: $OUT"
printf '%s' "$OUT" | grep -q "$URL" || fail "block reason does not name the link"
pass "folded-only deploy link blocks the stop"

# Case 2: link restated in the final text -> pass (trailing slash tolerated).
printf '%s\n' "$user" "$a_link" "$tool_res" "$a_final_link" > "$TMP/t2.jsonl"
OUT="$(run_hook "$TMP/t2.jsonl" false)"
[ -z "$OUT" ] || fail "restated link still blocked: $OUT"
pass "link restated in the final message passes"

# Case 3: loop guard.
OUT="$(run_hook "$TMP/t1.jsonl" true)"
[ -z "$OUT" ] || fail "stop_hook_active re-blocked: $OUT"
pass "stop_hook_active never re-blocks"

# Case 4: single-message turn with a link -> pass (nothing folded).
printf '%s\n' "$user" "$a_final_link" > "$TMP/t4.jsonl"
OUT="$(run_hook "$TMP/t4.jsonl" false)"
[ -z "$OUT" ] || fail "single final message blocked: $OUT"
pass "single-message turn passes"

# Case 5: link in a previous turn does not leak into this turn's check.
printf '%s\n' "$a_link" "$tool_res" "$user" "$a_final_nolink" > "$TMP/t5.jsonl"
OUT="$(run_hook "$TMP/t5.jsonl" false)"
[ -z "$OUT" ] || fail "previous-turn link leaked: $OUT"
pass "scan is bounded to the current turn"

# --- Codex rollout format -------------------------------------------------
# Record shapes match the Codex rollout JSONL used elsewhere in this repo
# (core/scripts/tests/checkpoint-stop-gate.test.sh append_codex_user/tool,
# .claude/skills/daily-brief/scripts/local_sessions.py codex_first_prompt).
cx_user='{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"next question"}]}}'
cx_user_event='{"type":"event_msg","payload":{"type":"user_message","message":"next question"}}'
cx_a_link='{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Storyboard (members only): '"$URL"'"}]}}'
cx_call='{"type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"c1","arguments":"{\"cmd\":\"true\"}"}}'
cx_call_out='{"type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"user said: ok"}}'
cx_a_final_nolink='{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Tell me whether the direction holds."}]}}'

# Case 6: Codex link from an earlier turn does not block a later turn.
printf '%s\n' "$cx_user" "$cx_a_link" "$cx_call" "$cx_call_out" "$cx_a_final_nolink" \
  "$cx_user_event" "$cx_user" "$cx_a_final_nolink" "$cx_call" "$cx_call_out" "$cx_a_final_nolink" > "$TMP/t6.jsonl"
OUT="$(run_hook "$TMP/t6.jsonl" false)"
[ -z "$OUT" ] || fail "Codex previous-turn link leaked: $OUT"
pass "Codex user prompt bounds the turn"

# Case 7: Codex folded link in the current turn still blocks; a
# function_call_output is not mistaken for a user prompt.
printf '%s\n' "$cx_user" "$cx_a_link" "$cx_call" "$cx_call_out" "$cx_a_final_nolink" > "$TMP/t7.jsonl"
OUT="$(run_hook "$TMP/t7.jsonl" false)"
printf '%s' "$OUT" | grep -q '"decision":"block"' || fail "Codex folded link did not block: $OUT"
pass "Codex folded link blocks; tool output is not a prompt"

# --- Fail-open paths ------------------------------------------------------
run_hook_rc() { # $1 transcript, $2 PATH -> sets OUT and RC
  set +e
  OUT="$(printf '{"transcript_path":"%s","stop_hook_active":false}' "$1" | PATH="$2" "$BASH" "$HOOK")"
  RC=$?
  set -e
}

# Case 8: missing transcript.
run_hook_rc "$TMP/does-not-exist.jsonl" "$PATH"
{ [ "$RC" -eq 0 ] && [ -z "$OUT" ]; } || fail "missing transcript: rc=$RC out=$OUT"
pass "missing transcript fails open"

# Case 9/10: missing jq, missing node. Each PATH holds wrappers for the basic
# tools only, so the absent tool is really absent.
make_path() { # $1 dir, rest: tools to expose
  local dir="$1" tool p; shift; mkdir -p "$dir"
  for tool in "$@"; do
    p="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$p" ] || continue
    printf '#!/bin/sh\nexec %s "$@"\n' "$p" > "$dir/$tool"
    chmod +x "$dir/$tool"
  done
}
BASIC="sh cat dirname sed tail stat grep head tr wc awk"
# shellcheck disable=SC2086
make_path "$TMP/nojq" $BASIC node
# shellcheck disable=SC2086
make_path "$TMP/nonode" $BASIC jq
run_hook_rc "$TMP/t1.jsonl" "$TMP/nojq"
{ [ "$RC" -eq 0 ] && [ -z "$OUT" ]; } || fail "missing jq: rc=$RC out=$OUT"
pass "missing jq fails open"
run_hook_rc "$TMP/t1.jsonl" "$TMP/nonode"
{ [ "$RC" -eq 0 ] && [ -z "$OUT" ]; } || fail "missing node: rc=$RC out=$OUT"
pass "missing node fails open"

# Case 11: malformed JSONL lines.
printf '%s\n' '{"type":"user"' 'not json at all' "$user" '{{{' "$a_final_link" '["x"' > "$TMP/t11.jsonl"
run_hook_rc "$TMP/t11.jsonl" "$PATH"
{ [ "$RC" -eq 0 ] && [ -z "$OUT" ]; } || fail "malformed lines: rc=$RC out=$OUT"
printf '%s\n' 'garbage' '{"type":' "$URL" > "$TMP/t11b.jsonl"
run_hook_rc "$TMP/t11b.jsonl" "$PATH"
{ [ "$RC" -eq 0 ] && [ -z "$OUT" ]; } || fail "all-malformed transcript: rc=$RC out=$OUT"
pass "malformed JSONL fails open"

# --- Cost: node is not started without an hq.work URL in the tail ---------
mkdir -p "$TMP/shim"
printf '#!/bin/sh\necho called >> "%s"\nexit 0\n' "$TMP/node-calls" > "$TMP/shim/node"
chmod +x "$TMP/shim/node"
a_nourl='{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Working on it."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"true"}}]}}'
printf '%s\n' "$user" "$a_nourl" "$tool_res" "$a_final_nolink" > "$TMP/t12.jsonl"
rm -f "$TMP/node-calls"
run_hook_rc "$TMP/t12.jsonl" "$TMP/shim:$PATH"
{ [ "$RC" -eq 0 ] && [ -z "$OUT" ]; } || fail "no-url turn: rc=$RC out=$OUT"
[ ! -e "$TMP/node-calls" ] || fail "node was started for a tail without hq.work"
rm -f "$TMP/node-calls"
run_hook_rc "$TMP/t1.jsonl" "$TMP/shim:$PATH"
[ -e "$TMP/node-calls" ] || fail "node shim not reached for a tail with hq.work (shim broken)"
pass "node is not started when the tail has no hq.work URL"

# --- Fenced code blocks ---------------------------------------------------
FENCE='```'
a_fenced='{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Example config:\n'"$FENCE"'\nurl: '"$URL"'\n'"$FENCE"'\nRunning it."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"true"}}]}}'
printf '%s\n' "$user" "$a_fenced" "$tool_res" "$a_final_nolink" > "$TMP/t13.jsonl"
OUT="$(run_hook "$TMP/t13.jsonl" false)"
[ -z "$OUT" ] || fail "URL inside a fenced code block blocked: $OUT"
a_mixed='{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"'"$FENCE"'\nx\n'"$FENCE"'\nLive: '"$URL"'"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"true"}}]}}'
printf '%s\n' "$user" "$a_mixed" "$tool_res" "$a_final_nolink" > "$TMP/t13b.jsonl"
OUT="$(run_hook "$TMP/t13b.jsonl" false)"
printf '%s' "$OUT" | grep -q '"decision":"block"' || fail "URL after a closed fence did not block: $OUT"
pass "URLs inside fenced code blocks are ignored"
