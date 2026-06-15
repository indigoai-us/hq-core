#!/usr/bin/env bash
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
out="$(run_hook "$(bash_send 'hq dm corey "Quick one — can you review the doc today?"')")"
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

echo "ALL PASS"
