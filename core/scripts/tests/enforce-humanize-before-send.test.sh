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

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

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

echo "ALL PASS"
