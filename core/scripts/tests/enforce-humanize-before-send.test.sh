#!/usr/bin/env bash
# hq-core: public
# Regression tests for the enforce-humanize-before-send Stop hook.
#
# The hook is the backstop for humanize-before-send: it scans ONLY the
# just-finished assistant message; if that turn performed an outbound-send
# action (hq dm / hq cowork dm / Slack chat.postMessage / Post-Bridge post /
# mcp__hq__hq_dm) whose body carries a CLUSTER (>=2 categories) of AI-writing
# tells, it returns {"decision":"block"}. Otherwise it stays silent (exit 0,
# no decision). Loop-safe via stop_hook_active; fail-open on any error.

set -euo pipefail

ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
HOOK="$ROOT/.claude/hooks/enforce-humanize-before-send.sh"
CAPABILITY_HOOK="$ROOT/.claude/hooks/enforce-capability-link-render.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

run_capability_hook() { # <transcript path> -> hook JSON
  local transcript="$1"
  jq -nc --arg p "$transcript" '{transcript_path:$p,stop_hook_active:false}' \
    | bash "$CAPABILITY_HOOK"
}

[ -x "$HOOK" ] || fail "hook not executable: $HOOK"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Build a one-line JSONL transcript whose single assistant message has the given
# content array (passed as a compact JSON array string), then run the hook with
# stop_hook_active = $2 (default false). Echoes the hook's stdout.
run_hook() {
  local content="$1" stop_active="${2:-false}"
  local tf="$TMP/t.jsonl"
  jq -nc --argjson c "$content" '{type:"assistant",message:{content:$c}}' > "$tf"
  jq -nc --arg p "$tf" --argjson s "$stop_active" '{transcript_path:$p, stop_hook_active:$s}' \
    | bash "$HOOK"
}

decision_of() {
  [ -z "$1" ] && { echo none; return; }
  printf '%s' "$1" | jq -r '.decision // "none"' 2>/dev/null || echo none
}

# --- helpers to build tool_use content blocks ------------------------------
bash_send() { jq -nc --arg cmd "$1" '[{type:"tool_use",name:"Bash",input:{command:$cmd}}]'; }
mcp_send()  { jq -nc --arg m "$1" --arg d "$2" '[{type:"tool_use",name:"mcp__hq__hq_dm",input:{message:$m,details:$d}}]'; }
text_only() { jq -nc --arg t "$1" '[{type:"text",text:$t}]'; }

echo "[1] sloppy hq dm (em dash + AI vocab) -> block"
# Two categories: em dash + AI vocab ("leverage", "seamless").
out="$(run_hook "$(bash_send 'hq dm stefan@example.com "Hey — we should leverage this seamless new flow"')")"
[ "$(decision_of "$out")" = "block" ] || fail "[1] expected block, got: $out"
pass "sloppy hq dm blocked"

echo "[2] clean hq dm -> no block"
out="$(run_hook "$(bash_send 'hq dm stefan@example.com "Heads up, prod deploy goes out at 3pm. Ping me if that timing is bad."')")"
[ "$(decision_of "$out")" = "none" ] || fail "[2] expected no block, got: $out"
pass "clean hq dm passed"

echo "[3] single tell only on a send -> no block (cluster bar)"
# One em dash, nothing else AI-ish: below the >=2 category threshold.
out="$(run_hook "$(bash_send 'hq dm alice "Quick one — can you review the doc today?"')")"
[ "$(decision_of "$out")" = "none" ] || fail "[3] expected no block, got: $out"
pass "single-tell send passed"

echo "[4] non-send turn with tells -> no block (no outbound action)"
out="$(run_hook "$(text_only 'I will leverage this seamless approach — it is a game-changer.')")"
[ "$(decision_of "$out")" = "none" ] || fail "[4] expected no block, got: $out"
pass "non-send turn passed"

echo "[5] loop guard: stop_hook_active=true with sloppy send -> no block"
out="$(run_hook "$(bash_send 'hq dm stefan@example.com "Hey — leverage this seamless flow"')" true)"
[ "$(decision_of "$out")" = "none" ] || fail "[5] expected no block under stop_hook_active, got: $out"
pass "loop guard honored"

echo "[6] Slack chat.postMessage (promo + emoji) -> block"
out="$(run_hook "$(bash_send 'curl -s -X POST https://slack.com/api/chat.postMessage --data "{\"text\":\"We are thrilled to announce our best-in-class launch 🚀\"}"')")"
[ "$(decision_of "$out")" = "block" ] || fail "[6] expected block, got: $out"
pass "sloppy slack post blocked"

echo "[7] mcp__hq__hq_dm (sycophantic + AI vocab across message+details) -> block"
out="$(run_hook "$(mcp_send 'Great question! Happy to help.' 'We will harness this robust capability.')")"
[ "$(decision_of "$out")" = "block" ] || fail "[7] expected block, got: $out"
pass "sloppy mcp dm blocked"

echo "[8] work-broadcast signature emoji shortcode is NOT counted as emoji"
# The :chart_with_upwards_trend: ASCII shortcode + one fancy word is a single
# category at most, so a normal small broadcast must NOT be blocked.
out="$(run_hook "$(bash_send 'curl -s -X POST https://slack.com/api/chat.postMessage --data "{\"text\":\":chart_with_upwards_trend: *Vault list* — presign lambdas shipped. https://github.com/x/y/pull/1\"}"')")"
[ "$(decision_of "$out")" = "none" ] || fail "[8] signature shortcode wrongly flagged, got: $out"
pass "work-broadcast signature shortcode not flagged"

echo "[9] missing/unreadable transcript -> fail-open (no block)"
out="$(jq -nc '{transcript_path:"/no/such/file", stop_hook_active:false}' | bash "$HOOK")"
[ "$(decision_of "$out")" = "none" ] || fail "[9] expected fail-open, got: $out"
pass "fail-open on bad transcript"

# --- channel coverage beyond dm/slack: email, whatsapp, sms ----------------
tool_send() { jq -nc --arg n "$1" --argjson i "$2" '[{type:"tool_use",name:$n,input:$i}]'; }

echo "[10] superhuman email draft with tells -> block"
out="$(run_hook "$(tool_send mcp__superhuman-mail__create_or_update_draft \
  "$(jq -nc '{to:"a@example.com",subject:"Quick note",body:"Hi — thrilled to share this seamless new flow."}')")")"
[ "$(decision_of "$out")" = "block" ] || fail "[10] expected block, got: $out"
pass "sloppy email draft blocked"

echo "[11] clean email draft -> no block"
out="$(run_hook "$(tool_send mcp__superhuman-mail__send_draft \
  "$(jq -nc '{to:"a@example.com",subject:"Deploy at 3pm",body:"Deploy goes out at 3pm. Tell me if that timing is bad."}')")")"
[ "$(decision_of "$out")" = "none" ] || fail "[11] expected no block, got: $out"
pass "clean email draft passed"

echo "[12] whatsapp send with tells -> block"
out="$(run_hook "$(tool_send mcp__whatsapp__send_message \
  "$(jq -nc '{to:"+15550000000",text:"Excited to announce we can leverage this."}')")")"
[ "$(decision_of "$out")" = "block" ] || fail "[12] expected block, got: $out"
pass "sloppy whatsapp send blocked"

echo "[13] recipients/ids are never scrutinised (no text tells -> no block)"
out="$(run_hook "$(tool_send mcp__twilio__send_sms \
  "$(jq -nc '{to:"+15550000000",account_sid:"AC-crucial-seamless-robust",body:"Running late, 10 min."}')")")"
[ "$(decision_of "$out")" = "none" ] || fail "[13] non-prose fields wrongly scrutinised, got: $out"
pass "non-prose fields ignored"

# --- mannered-prose categories (core/policies/hq-no-mannered-prose.md) -----
echo "[14] antithesis + portentous fragment on a dm -> block"
out="$(run_hook "$(bash_send 'hq dm alice "This is not a bug, it'"'"'s a boundary problem. Which is the point."')")"
[ "$(decision_of "$out")" = "block" ] || fail "[14] expected block, got: $out"
pass "mannered prose blocked"

echo "[15] throat-clearing + rhythm triad on a dm -> block"
out="$(run_hook "$(bash_send 'hq dm alice "Here'"'"'s the thing. It is faster, cleaner, and safer now."')")"
[ "$(decision_of "$out")" = "block" ] || fail "[15] expected block, got: $out"
pass "throat-clearing + triad blocked"

echo "[16] ordinary three-item list is not a rhythm triad on its own"
# One category at most: a plain enumeration with no other tells stays under the bar.
out="$(run_hook "$(bash_send 'hq dm alice "Ship order is staging, canary, and prod."')")"
[ "$(decision_of "$out")" = "none" ] || fail "[16] plain enumeration wrongly blocked, got: $out"
pass "plain enumeration passed"

echo "[17] capability-link hook reads a bounded tail and keeps the last assistant turn"
REAL_JQ="$(command -v jq)"
JQ_TRACE="$TMP/capability-jq-bytes"
JQ_SHIM_DIR="$TMP/bin"
mkdir -p "$JQ_SHIM_DIR"
cat > "$JQ_SHIM_DIR/jq" <<'JQ_SHIM'
#!/usr/bin/env bash
set -o pipefail
measure=0
for arg in "$@"; do
  [ "$arg" = "-nr" ] && measure=1
done
if [ "$measure" -eq 0 ]; then exec "$REAL_JQ" "$@"; fi
last_arg=""
for arg in "$@"; do last_arg="$arg"; done
if [ -f "$last_arg" ]; then
  stat -c %s "$last_arg" > "$JQ_TRACE"
  exec "$REAL_JQ" "$@"
fi
MEASURED_INPUT="${JQ_TRACE}.input"
cat > "$MEASURED_INPUT"
wc -c < "$MEASURED_INPUT" > "$JQ_TRACE"
"$REAL_JQ" "$@" < "$MEASURED_INPUT"
status=$?
rm -f "$MEASURED_INPUT"
exit "$status"
JQ_SHIM
chmod +x "$JQ_SHIM_DIR/jq"
CAPABILITY_TRANSCRIPT="$TMP/capability-large.jsonl"
CAPABILITY_RECORD_BYTES="$TMP/capability-record-bytes"
python3 - "$CAPABILITY_TRANSCRIPT" "$CAPABILITY_RECORD_BYTES" <<'PY'
import json, sys
transcript_path, length_path = sys.argv[1:]
padding = {"type":"progress","padding":"x" * 1200000}
assistant = {
    "type":"assistant",
    "message":{"role":"assistant","content":[
        {"type":"text","text":"x" * 1100000 + " https://hq.computer/share-session/abcdefghijklmnopqrstuvwx"}
    ]}
}
with open(transcript_path, "w", encoding="utf-8") as transcript:
    transcript.write(json.dumps(padding, separators=(",", ":")) + "\n")
    last_record = json.dumps(assistant, separators=(",", ":")) + "\n"
    transcript.write(last_record)
with open(length_path, "w", encoding="ascii") as length:
    length.write(str(len(last_record.encode("utf-8"))))
PY
CAPABILITY_OUT="$(printf '%s' "$(jq -nc --arg p "$CAPABILITY_TRANSCRIPT" '{transcript_path:$p,stop_hook_active:false}')" | PATH="$JQ_SHIM_DIR:$PATH" REAL_JQ="$REAL_JQ" JQ_TRACE="$JQ_TRACE" bash "$CAPABILITY_HOOK")"
[ "$(decision_of "$CAPABILITY_OUT")" = "block" ] \
  || fail "[17] expected a block for the last assistant bare capability URL, got: $CAPABILITY_OUT"
CAPABILITY_JQ_BYTES="$(cat "$JQ_TRACE")"
EXPECTED_CAPABILITY_RECORD_BYTES="$(cat "$CAPABILITY_RECORD_BYTES")"
[ "$CAPABILITY_JQ_BYTES" -eq "$EXPECTED_CAPABILITY_RECORD_BYTES" ] \
  || fail "[17] capability hook parsed $CAPABILITY_JQ_BYTES bytes, expected only final record ($EXPECTED_CAPABILITY_RECORD_BYTES bytes)"
pass "capability-link hook retained and blocked an oversized latest bare URL record"

echo "[18] oversized assistant followed by Claude Code metadata: bare URL blocks, markdown link passes"
make_nonfinal_transcript() { # <path> <rendered|bare>
  python3 - "$1" "$2" <<'PY_FIXTURE'
import json, sys
path, render = sys.argv[1:]
url = "https://hq.computer/share-session/abcdefghijklmnopqrstuvwx"
text = "x" * 1100000 + (" [open](" + url + ")" if render == "rendered" else " " + url)
assistant = {
    "type": "assistant",
    "uuid": "assistant-turn",
    "message": {"role": "assistant", "content": [{"type": "text", "text": text}], "stop_reason": "end_turn"},
}
# Claude Code transcript records are JSONL objects; metadata records may follow
# the assistant record before Stop hooks consume transcript_path.
records = [
    assistant,
    {"type": "system", "subtype": "hook_feedback", "content": "Stop hook feedback"},
    {"type": "file-history-snapshot", "messageId": "assistant-turn", "snapshot": {"trackedFileBackups": {}, "timestamp": "2026-09-29T00:00:00Z"}},
]
with open(path, "w", encoding="utf-8") as transcript:
    for record in records:
        transcript.write(json.dumps(record, separators=(",", ":")) + "\n")
PY_FIXTURE
}
NONFINAL_BARE="$TMP/oversized-assistant-followed-by-metadata-bare.jsonl"
make_nonfinal_transcript "$NONFINAL_BARE" bare
NONFINAL_BARE_OUT="$(run_capability_hook "$NONFINAL_BARE")"
[ "$(decision_of "$NONFINAL_BARE_OUT")" = "block" ] \
  || fail "[18] expected oversized nonfinal bare URL to block, got: $NONFINAL_BARE_OUT"
pass "oversized nonfinal assistant bare capability URL blocked"

NONFINAL_RENDERED="$TMP/oversized-assistant-followed-by-metadata-rendered.jsonl"
make_nonfinal_transcript "$NONFINAL_RENDERED" rendered
NONFINAL_RENDERED_OUT="$(run_capability_hook "$NONFINAL_RENDERED")"
[ "$(decision_of "$NONFINAL_RENDERED_OUT")" = "none" ] \
  || fail "[18] expected oversized nonfinal rendered URL to pass, got: $NONFINAL_RENDERED_OUT"
pass "oversized nonfinal assistant markdown capability link passed"

echo "[19] common-case assistant in tail reads one bounded window"
TAIL_LIB="$ROOT/core/scripts/lib/transcript-tail.sh"
TAIL_TRACE="$TMP/tail-trace"
TAIL_SHIM_DIR="$TMP/tail-bin"
mkdir -p "$TAIL_SHIM_DIR"
cat > "$TAIL_SHIM_DIR/tail" <<'TAIL_SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TAIL_TRACE"
exec "$REAL_TAIL" "$@"
TAIL_SHIM
chmod +x "$TAIL_SHIM_DIR/tail"
COMMON_TRANSCRIPT="$TMP/common-case.jsonl"
python3 - "$COMMON_TRANSCRIPT" <<'PY_FIXTURE'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as transcript:
    transcript.write(json.dumps({"type":"progress", "padding":"x" * 1200000}, separators=(",", ":")) + "\n")
    transcript.write(json.dumps({"type":"assistant", "message":{"role":"assistant", "content":[{"type":"text", "text":"common-case"}]}}, separators=(",", ":")) + "\n")
PY_FIXTURE
REAL_TAIL="$(command -v tail)"
TAIL_TRACE="$TAIL_TRACE" REAL_TAIL="$REAL_TAIL" PATH="$TAIL_SHIM_DIR:$PATH" bash -c '. "$1"; hq_transcript_tail_with_latest_assistant "$2" >/dev/null' _ "$TAIL_LIB" "$COMMON_TRANSCRIPT"
TAIL_READS="$(grep -c "^-c " "$TAIL_TRACE" || true)"
[ "$TAIL_READS" -eq 1 ] || fail "[19] common case made $TAIL_READS transcript byte-window reads, expected one"
grep -Fxq -- "-c 1048577 $COMMON_TRANSCRIPT" "$TAIL_TRACE" \
  || fail "[19] common case did not read exactly one 1 MiB tail window: $(cat "$TAIL_TRACE")"
pass "common-case assistant needed one tail-window read"

echo "[20] oversized newest assistant with a rendered capability link passes"
CAP_HIT_TRANSCRIPT="$TMP/assistant-over-cap.jsonl"
python3 - "$CAP_HIT_TRANSCRIPT" <<'PY_FIXTURE'
import json, sys
assistant = {"type":"assistant", "message":{"role":"assistant", "content":[{"type":"text", "text":"x" * 17000000 + " [open](https://hq.computer/share-session/abcdefghijklmnopqrstuvwx)"}]}}
metadata = {"type":"system", "subtype":"hook_feedback", "content":"small trailing record"}
with open(sys.argv[1], "w", encoding="utf-8") as transcript:
    for record in (assistant, metadata):
        transcript.write(json.dumps(record, separators=(",", ":")) + "\n")
PY_FIXTURE
CAP_HIT_OUT="$(run_capability_hook "$CAP_HIT_TRANSCRIPT")"
[ "$(decision_of "$CAP_HIT_OUT")" = "none" ] \
  || fail "[20] expected rendered capability link on oversized assistant to pass, got: $CAP_HIT_OUT"
printf '%s' "$CAP_HIT_OUT" | grep -Fq "POLICY CHECK BLOCKED" \
  && fail "[20] internal verification warning must not be shown: $CAP_HIT_OUT"
pass "oversized rendered capability link was inspected without an internal warning"

echo "[21] estimate capture retains oversized nonfinal assistant records"
CAPTURE_ROOT="$TMP/capture-hq"
CAPTURE_TRANSCRIPT="$TMP/capture-transcript.jsonl"
CAPTURE_TRACE="$TMP/capture-parser.trace"
mkdir -p "$CAPTURE_ROOT/.claude/hooks/lib" "$CAPTURE_ROOT/core/scripts/lib"
cp "$ROOT/.claude/hooks/capture-estimates.sh" "$CAPTURE_ROOT/.claude/hooks/"
cp "$ROOT/core/scripts/lib/transcript-tail.sh" "$CAPTURE_ROOT/core/scripts/lib/"
cat > "$CAPTURE_ROOT/.claude/hooks/lib/parse-estimates.pl" <<'PARSER_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CAPTURE_TRACE"
cat >/dev/null
printf '{"session_id":"%s","message_uuid":"%s","captured":true}\n' "$1" "$2"
PARSER_STUB
chmod +x "$CAPTURE_ROOT/.claude/hooks/capture-estimates.sh" "$CAPTURE_ROOT/.claude/hooks/lib/parse-estimates.pl"
python3 - "$CAPTURE_TRANSCRIPT" <<'PY_FIXTURE'
import json, sys
assistant = {"type":"assistant", "uuid":"oversized-assistant-turn", "message":{"role":"assistant", "content":[{"type":"text", "text":"Estimated time: 3 minutes. " + "x" * 1100000}]}}
records = [assistant, {"type":"system", "subtype":"hook_feedback", "content":"Stop hook feedback"}, {"type":"file-history-snapshot", "messageId":"oversized-assistant-turn", "snapshot":{"trackedFileBackups":{}, "timestamp":"2026-09-29T00:00:00Z"}}]
with open(sys.argv[1], "w", encoding="utf-8") as transcript:
    for record in records:
        transcript.write(json.dumps(record, separators=(",", ":")) + "\n")
PY_FIXTURE
jq -nc --arg p "$CAPTURE_TRANSCRIPT" '{transcript_path:$p,session_id:"session-fixture"}' \
  | CAPTURE_TRACE="$CAPTURE_TRACE" bash "$CAPTURE_ROOT/.claude/hooks/capture-estimates.sh"
CAPTURE_LOG="$CAPTURE_ROOT/workspace/estimate-log/log.jsonl"
grep -Fq '"message_uuid":"oversized-assistant-turn"' "$CAPTURE_LOG" \
  || fail "[21] estimate capture missed oversized nonfinal assistant record"
grep -Fq 'session-fixture oversized-assistant-turn' "$CAPTURE_TRACE" \
  || fail "[21] estimate parser did not receive the newest assistant record"
pass "estimate capture saw the oversized nonfinal assistant record"

echo "[21a] latest Codex assistant in fast tail avoids scan-cap read and keeps bounded output"
FAST_PATH_FAILURES=0
REAL_TAIL="$(command -v tail)"
make_fast_path_transcript() { # <path> <codex|claude>
  python3 - "$1" "$2" <<'PY_FAST_PATH_FIXTURE'
import json, sys
path, kind = sys.argv[1:]
padding = {"type":"progress", "padding":"x" * 256}
if kind == "codex":
    assistant = {"type":"response_item", "payload":{"type":"message", "role":"assistant", "content":[{"type":"output_text", "text":"fast-codex"}]}}
else:
    assistant = {"type":"assistant", "message":{"role":"assistant", "content":[{"type":"text", "text":"fast-claude"}]}}
with open(path, "w", encoding="utf-8") as transcript:
    for _ in range(8):
        transcript.write(json.dumps(padding, separators=(",", ":")) + "\n")
    transcript.write(json.dumps(assistant, separators=(",", ":")) + "\n")
PY_FAST_PATH_FIXTURE
}
run_tail_with_trace() { # <transcript> <trace>
  TAIL_TRACE="$2" REAL_TAIL="$REAL_TAIL" PATH="$TAIL_SHIM_DIR:$PATH" \
    bash -c '. "$1"; hq_transcript_tail_with_latest_assistant "$2" 512 1024' _ "$TAIL_LIB" "$1"
}
for FAST_KIND in codex claude; do
  FAST_TRANSCRIPT="$TMP/fast-path-$FAST_KIND.jsonl"
  FAST_TRACE="$TMP/fast-path-$FAST_KIND.trace"
  make_fast_path_transcript "$FAST_TRANSCRIPT" "$FAST_KIND"
  FAST_STATUS=0
  FAST_OUTPUT="$(run_tail_with_trace "$FAST_TRANSCRIPT" "$FAST_TRACE")" || FAST_STATUS=$?
  FAST_OUTPUT_BYTES="$(printf '%s' "$FAST_OUTPUT" | wc -c | tr -d ' ')"
  if [ "$FAST_STATUS" -ne 0 ] || ! printf '%s' "$FAST_OUTPUT" | grep -Fq "fast-$FAST_KIND"; then
    echo "FAIL [21a/$FAST_KIND]: expected status 0 and latest assistant output; status=$FAST_STATUS"
    FAST_PATH_FAILURES=1
  fi
  if [ "$FAST_OUTPUT_BYTES" -gt 513 ]; then
    echo "FAIL [21a/$FAST_KIND]: returned $FAST_OUTPUT_BYTES bytes; expected at most 513"
    FAST_PATH_FAILURES=1
  fi
  if awk '$1 == "-c" && $2 > 513 { bad=1 } END { exit bad ? 0 : 1 }' "$FAST_TRACE"; then
    echo "FAIL [21a/$FAST_KIND]: tail read exceeded max_bytes+1: $(cat "$FAST_TRACE")"
    FAST_PATH_FAILURES=1
  else
    pass "$FAST_KIND fast tail stayed within 513 bytes (output=$FAST_OUTPUT_BYTES bytes)"
  fi
done
[ "$FAST_PATH_FAILURES" -eq 0 ] || exit 1

echo "[22] Codex transcript over 16 MiB with no capability link does not trigger the guard"
CODEX_OVER_CAP_NO_LINK="$TMP/codex-over-cap-no-link.jsonl"
python3 - "$CODEX_OVER_CAP_NO_LINK" "" <<'PY_FIXTURE'
import json, sys
path, text = sys.argv[1:]
padding = {"type":"progress", "padding":"x" * 16778240}
assistant = {"type":"response_item", "payload":{"type":"message", "role":"assistant", "content":[{"type":"output_text", "text":text}]}}
with open(path, "w", encoding="utf-8") as transcript:
    transcript.write(json.dumps(padding, separators=(",", ":")) + "\n")
    transcript.write(json.dumps(assistant, separators=(",", ":")) + "\n")
PY_FIXTURE
CODEX_NO_LINK_OUT="$(run_capability_hook "$CODEX_OVER_CAP_NO_LINK")"
[ "$(decision_of "$CODEX_NO_LINK_OUT")" = "none" ] \
  || fail "[22] expected a no-link Codex turn to pass, got: $CODEX_NO_LINK_OUT"
pass "over-cap Codex assistant without capability link passed"

echo "[23] Codex transcript over 16 MiB with a bare capability link remains blocked"
CODEX_OVER_CAP_LINK="$TMP/codex-over-cap-link.jsonl"
python3 - "$CODEX_OVER_CAP_LINK" <<'PY_FIXTURE'
import json, sys
path = sys.argv[1]
padding = {"type":"progress", "padding":"x" * 16778240}
assistant = {"type":"response_item", "payload":{"type":"message", "role":"assistant", "content":[{"type":"output_text", "text":"https://hq.computer/share-session/abcdefghijklmnopqrstuvwx"}]}}
with open(path, "w", encoding="utf-8") as transcript:
    transcript.write(json.dumps(padding, separators=(",", ":")) + "\n")
    transcript.write(json.dumps(assistant, separators=(",", ":")) + "\n")
PY_FIXTURE
CODEX_LINK_OUT="$(run_capability_hook "$CODEX_OVER_CAP_LINK")"
[ "$(decision_of "$CODEX_LINK_OUT")" = "block" ] \
  || fail "[23] expected a bare capability link in Codex transcript to block, got: $CODEX_LINK_OUT"
pass "over-cap Codex assistant bare capability link blocked"

echo "[24] oversized newest Codex assistant record is returned beyond the old bounded scan cap"
CODEX_OVERSIZED="$TMP/codex-oversized-assistant.jsonl"
python3 - "$CODEX_OVERSIZED" <<'PY_FIXTURE'
import json, sys
assistant = {"type":"response_item", "payload":{"type":"message", "role":"assistant", "content":[{"type":"output_text", "text":"x" * 4096}]}}
with open(sys.argv[1], "w", encoding="utf-8") as transcript:
    transcript.write(json.dumps(assistant, separators=(",", ":")) + "\n")
PY_FIXTURE
TAIL_LIB="$ROOT/core/scripts/lib/transcript-tail.sh"
CODEX_TAIL_STATUS=0
CODEX_TAIL_OUTPUT="$(bash -c '. "$1"; hq_transcript_tail_with_latest_assistant "$2" 128 1024' _ "$TAIL_LIB" "$CODEX_OVERSIZED")" || CODEX_TAIL_STATUS=$?
[ "$CODEX_TAIL_STATUS" -eq 0 ] \
  || fail "[24] expected oversized Codex assistant to return status 0, got: $CODEX_TAIL_STATUS"
CODEX_TAIL_FIRST="$(printf '%s\n' "$CODEX_TAIL_OUTPUT" | sed -n '1p')"
printf '%s\n' "$CODEX_TAIL_FIRST" | jq -Rre 'fromjson? | select(.type == "response_item" and .payload.type == "message" and .payload.role == "assistant") | .payload.role == "assistant"' >/dev/null \
  || fail "[24] expected helper to return the oversized assistant record, got: ${CODEX_TAIL_FIRST:0:120}"
pass "oversized Codex assistant record was returned"

# Records after the newest assistant exceed the old 16 MiB verification window.
# Each transcript remains a temporary fixture, generated in bounded chunks.
make_over_cap_trailing_transcript() { # <path> <claude|codex> <assistant text>
  python3 - "$1" "$2" "$3" <<'PY_OVER_CAP_TRAILING'
import json, sys
path, kind, text = sys.argv[1:]
if kind == "codex":
    assistant = {"type":"response_item", "payload":{"type":"message", "role":"assistant", "content":[{"type":"output_text", "text":text}]}}
    trailing = {"type":"response_item", "payload":{"type":"function_call_output", "call_id":"large-output", "output":"x" * 18000000}}
else:
    assistant = {"type":"assistant", "message":{"role":"assistant", "content":[{"type":"text", "text":text}]}}
    trailing = {"type":"tool_result", "content":"x" * 18000000}
with open(path, "w", encoding="utf-8") as transcript:
    transcript.write(json.dumps(assistant, separators=(",", ":")) + "\n")
    transcript.write(json.dumps(trailing, separators=(",", ":")) + "\n")
    transcript.write(json.dumps({"type":"user", "message":{"role":"user", "content":"later user record"}}, separators=(",", ":")) + "\n")
PY_OVER_CAP_TRAILING
}
check_over_cap_hook() { # <case number> <label> <path> <expected decision>
  local case_no="$1" label="$2" transcript="$3" expected="$4" out decision
  out="$(run_capability_hook "$transcript")"
  decision="$(decision_of "$out")"
  if [ "$expected" = "none" ]; then
    [ "$decision" = "none" ] \
      || fail "[$case_no] expected $label to pass without an internal warning, got: $out"
    ! printf '%s' "$out" | grep -Fq "POLICY CHECK BLOCKED" \
      || fail "[$case_no] internal verification warning must be silent, got: $out"
    pass "$label passed without an internal warning"
  else
    [ "$decision" = "block" ] \
      || fail "[$case_no] expected $label to block, got: $out"
    printf '%s' "$out" | grep -Fq "POLICY VIOLATION" \
      || fail "[$case_no] expected POLICY VIOLATION for $label, got: $out"
    ! printf '%s' "$out" | grep -Fq "POLICY CHECK BLOCKED" \
      || fail "[$case_no] internal verification warning must not replace the policy violation, got: $out"
    pass "$label remained blocked for the policy violation"
  fi
}

for OVER_CAP_KIND in claude codex; do
  OVER_CAP_NO_LINK="$TMP/$OVER_CAP_KIND-over-cap-trailing-no-link.jsonl"
  make_over_cap_trailing_transcript "$OVER_CAP_NO_LINK" "$OVER_CAP_KIND" "assistant-without-link"
  if [ "$OVER_CAP_KIND" = "claude" ]; then
    check_over_cap_hook 25 "Claude assistant without a capability link and over-17-MiB trailing tool/user records" "$OVER_CAP_NO_LINK" none
  else
    check_over_cap_hook 27 "Codex assistant without a capability link and over-17-MiB trailing response items" "$OVER_CAP_NO_LINK" none
  fi

  OVER_CAP_LINK="$TMP/$OVER_CAP_KIND-over-cap-trailing-bare-link.jsonl"
  make_over_cap_trailing_transcript "$OVER_CAP_LINK" "$OVER_CAP_KIND" "https://hq.computer/share-session/abcdefghijklmnopqrstuvwx"
  if [ "$OVER_CAP_KIND" = "claude" ]; then
    check_over_cap_hook 26 "Claude newest assistant bare capability URL behind over-17-MiB trailing tool/user records" "$OVER_CAP_LINK" block
  else
    check_over_cap_hook 28 "Codex newest assistant bare capability URL behind over-17-MiB trailing response items" "$OVER_CAP_LINK" block
  fi
done

echo "[29] reverse helper returns the newest assistant and stops before the transcript prefix"
REVERSE_TRANSCRIPT="$TMP/reverse-latest-assistant.jsonl"
REVERSE_TRACE="$TMP/reverse-lines.trace"
: > "$REVERSE_TRACE"
python3 - "$REVERSE_TRANSCRIPT" <<'PY_REVERSE_FIXTURE'
import json, sys
path = sys.argv[1]
with open(path, "w", encoding="utf-8") as transcript:
    for index in range(5000):
        old = {"type":"assistant", "message":{"role":"assistant", "content":[{"type":"text", "text":f"older-{index}"}]}}
        transcript.write(json.dumps(old, separators=(",", ":")) + "\n")
    assistant = {"type":"assistant", "message":{"role":"assistant", "content":[{"type":"text", "text":"reverse-scan-target"}]}}
    transcript.write(json.dumps(assistant, separators=(",", ":")) + "\n")
    trailing = {"type":"tool_result", "content":"z" * 18000000}
    transcript.write(json.dumps(trailing, separators=(",", ":")) + "\n")
PY_REVERSE_FIXTURE
REVERSE_BIN="$TMP/reverse-bin"
mkdir -p "$REVERSE_BIN"
REAL_TAC="$(command -v tac || true)"
REAL_TAIL="$(command -v tail)"
if [ -n "$REAL_TAC" ]; then
  cat > "$REVERSE_BIN/tac" <<'TAC_TRACE_SHIM'
#!/usr/bin/env bash
"$REAL_TAC" "$@" | grep -E '"assistant"' | while IFS= read -r line || [ -n "$line" ]; do
  printf '.\n' >> "$REVERSE_TRACE"
  if ! printf '%s\n' "$line"; then
    break
  fi
done
TAC_TRACE_SHIM
  chmod +x "$REVERSE_BIN/tac"
else
  cat > "$REVERSE_BIN/tail" <<'TAIL_REVERSE_TRACE_SHIM'
#!/usr/bin/env bash
if [ "${1:-}" = "-r" ]; then
  "$REAL_TAIL" "$@" | grep -E '"assistant"' | while IFS= read -r line || [ -n "$line" ]; do
    printf '.\n' >> "$REVERSE_TRACE"
    if ! printf '%s\n' "$line"; then
      break
    fi
  done
else
  exec "$REAL_TAIL" "$@"
fi
TAIL_REVERSE_TRACE_SHIM
  chmod +x "$REVERSE_BIN/tail"
fi
REVERSE_STATUS=0
REVERSE_OUTPUT="$(REVERSE_TRACE="$REVERSE_TRACE" REAL_TAC="$REAL_TAC" REAL_TAIL="$REAL_TAIL" PATH="$REVERSE_BIN:$PATH" bash -c '. "$1"; hq_transcript_tail_with_latest_assistant "$2"' _ "$TAIL_LIB" "$REVERSE_TRANSCRIPT")" || REVERSE_STATUS=$?
[ "$REVERSE_STATUS" -eq 0 ] \
  || fail "[29] expected reverse helper status 0, got: $REVERSE_STATUS"
REVERSE_FIRST="$(printf '%s\n' "$REVERSE_OUTPUT" | sed -n '1p')"
[ "$(printf '%s\n' "$REVERSE_FIRST" | jq -r '.message.content[0].text')" = "reverse-scan-target" ] \
  || fail "[29] expected newest assistant record first, got: ${REVERSE_FIRST:0:120}"
REVERSE_LINES="$(wc -l < "$REVERSE_TRACE" | tr -d '[:space:]')"
[ "$REVERSE_LINES" -lt 5001 ] \
  || fail "[29] reverse reader scanned all $REVERSE_LINES assistant candidates instead of stopping at the newest one"
pass "reverse scan returned the newest assistant and stopped before the large prefix"

echo "ALL PASS"
