#!/bin/bash
# Stop hook: backstop for humanize-before-send.
#
# Scans ONLY the just-finished assistant message. If that turn performed an
# outbound-send action (hq dm / hq cowork dm / a Slack chat.postMessage / a
# Post-Bridge post / the mcp__hq__hq_dm tool) whose human-readable body still
# carries a CLUSTER of AI-writing tells, block the stop with a corrective
# directive so the agent humanizes the body and re-issues, per
# core/policies/humanize-generated-content.md (hard) and the shared block
# core/knowledge/public/hq-core/humanize-before-send.md.
#
# The inline "humanize before send" step in each outbound skill is the PRIMARY
# control; this hook is the independent safety net that catches a skipped pass
# (cloned in shape from enforce-capability-link-render.sh).
#
# Precision: it fires only when (a) the finished turn actually sent outbound
# comms AND (b) the body shows >=2 distinct tell categories. A single em dash or
# one fancy word never trips it. False positives cost at most one corrective
# turn, never a lost message.
#
# Non-fatal by design: any error path exits 0 (never wedge session turnaround).
# Loop-safe: respects stop_hook_active so it blocks at most once per stop chain.

set -uo pipefail

{
  INPUT="$(cat 2>/dev/null || echo '{}')"

  command -v jq  >/dev/null 2>&1 || exit 0
  command -v python3 >/dev/null 2>&1 || exit 0

  STOP_ACTIVE="$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)"
  # Already in a continuation triggered by a prior block — do not re-block (loop guard).
  [ "$STOP_ACTIVE" = "true" ] && exit 0

  TRANSCRIPT_PATH="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
  [ -z "$TRANSCRIPT_PATH" ] || [ ! -r "$TRANSCRIPT_PATH" ] && exit 0

  # Full content array of the last assistant message (text + tool_use blocks),
  # as compact JSON. The send signature lives in tool_use inputs.
  LAST_CONTENT="$(
    jq -sc '
      [ .[] | select(.type=="assistant") ] | last
      | .message.content
      | (if type=="array" then . elif type=="string" then [{type:"text",text:.}] else [] end)
    ' "$TRANSCRIPT_PATH" 2>/dev/null || true
  )"
  [ -z "$LAST_CONTENT" ] || [ "$LAST_CONTENT" = "null" ] && exit 0

  VERDICT="$(
    printf '%s' "$LAST_CONTENT" | python3 -c '
import json, re, sys

try:
    blocks = json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit(0)
if not isinstance(blocks, list):
    print(""); raise SystemExit(0)

# --- Gather the outbound-send bodies from this turn ------------------------
# A send signature: an hq dm / hq cowork dm CLI call, a Slack chat.postMessage,
# a Post-Bridge post, or the host-side mcp__hq__hq_dm tool. For each, build the
# haystack of human-readable text to scrutinise.
SEND_BASH = re.compile(
    r"\bhq\s+(?:cowork\s+)?dm\b"
    r"|chat\.postMessage"
    r"|api\.post-bridge\.com/v1/posts",
    re.I,
)
URL = re.compile(r"https?://\S+")

bodies = []
for b in blocks:
    if not isinstance(b, dict):
        continue
    if b.get("type") != "tool_use":
        continue
    name = b.get("name") or ""
    inp = b.get("input") or {}
    if name == "Bash":
        cmd = inp.get("command", "") if isinstance(inp, dict) else ""
        if cmd and SEND_BASH.search(cmd):
            # Drop URLs so a link in the body cannot create noise.
            bodies.append(URL.sub(" ", cmd))
    elif name.endswith("hq_dm") or name == "mcp__hq__hq_dm":
        if isinstance(inp, dict):
            parts = [str(inp.get(k, "")) for k in ("message", "details", "prompt")]
            bodies.append(" ".join(parts))

if not bodies:
    print(""); raise SystemExit(0)

# --- Tell categories -------------------------------------------------------
DASH = re.compile(r"—|–|(?<=\s)--(?=\s)")
AI_VOCAB = re.compile(
    r"\b(?:delve|leverage(?:s|d|ing)?|seamless(?:ly)?|robust|testament|underscore(?:s|d|ing)?|"
    r"showcas(?:e|es|ed|ing)|pivotal|vibrant|unlock(?:s|ed|ing)?|elevate(?:s|d|ing)?|"
    r"harness(?:es|ed|ing)?|tapestry|intricate|crucial|foster(?:s|ed|ing)?|"
    r"supercharge(?:s|d|ing)?|game[- ]?changer|cutting[- ]edge|paradigm|synerg(?:y|ies|istic))\b",
    re.I,
)
COLLAB = re.compile(
    r"\bI hope this helps\b|\blet me know if\b|\bfeel free to\b|\bgreat question\b|"
    r"\bcertainly!|\bof course!|\bhappy to help\b|\byou\x27?re absolutely right\b|"
    r"\bdon\x27?t hesitate to\b",
    re.I,
)
PROMO = re.compile(
    r"\bexcited to announce\b|\bthrilled to\b|\bdelighted to\b|\bproud to announce\b|"
    r"\brevolutionar(?:y|ize)\b|\bbest-in-class\b|\bworld-class\b|\btake .* to the next level\b",
    re.I,
)
NEGPAR = re.compile(
    r"\bnot only\b[^.]*\bbut\b|\bit\x27?s not (?:just|merely) about\b|\bit\x27?s not just\b[^.]*\bit\x27?s\b",
    re.I,
)
# Unicode emoji (pictographic ranges) — NOT Slack :shortcode: ASCII text, so the
# work-broadcast :chart_with_upwards_trend: signature is never counted here.
EMOJI = re.compile(
    "[\U0001F300-\U0001FAFF\U00002600-\U000027BF\U0001F1E6-\U0001F1FF\U00002190-\U000021FF\U00002B00-\U00002BFF]"
)

def categories(text):
    cats = set()
    if DASH.search(text):    cats.add("dash")
    if AI_VOCAB.search(text): cats.add("ai_vocab")
    if COLLAB.search(text):  cats.add("collab")
    if PROMO.search(text):   cats.add("promo")
    if NEGPAR.search(text):  cats.add("neg_parallel")
    if EMOJI.search(text):   cats.add("emoji")
    return cats

for body in bodies:
    if len(categories(body)) >= 2:
        print("BLOCK")
        break
' 2>/dev/null || true
  )"

  [ "$VERDICT" != "BLOCK" ] && exit 0

  REASON='POLICY VIOLATION — humanize-generated-content (hard) + humanize-before-send. The turn that just finished sent (or composed for send) an outbound message whose body still carries a cluster of AI-writing tells (em/en dashes, AI vocabulary, promotional or sycophantic framing, negative parallelisms, or decorative emoji). Per core/knowledge/public/hq-core/humanize-before-send.md the human-readable body MUST run the channel-aware humanize pass BEFORE it is sent. Do this now: (1) run the /humanize audit on the body at the channel intensity (dm/cowork-dm default light, work-broadcast light, social full), (2) re-issue the corrected message — for a store-and-forward DM that already went out, send the corrected version only if the original was clearly slop, otherwise apply the pass to every future send. Do NOT rewrite recipients, emails/personUids, URLs, scheduling flags, account IDs, or the work-broadcast :chart_with_upwards_trend: signature emoji — only the prose a person reads.'

  jq -nc --arg r "$REASON" '{decision:"block", reason:$r}' 2>/dev/null \
    || printf '{"decision":"block","reason":%s}' "$(printf '%s' "$REASON" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')"
  exit 0
} 2>/dev/null || exit 0
