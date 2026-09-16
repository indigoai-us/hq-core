#!/bin/bash
# hq-core: public
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
  command -v node >/dev/null 2>&1 || exit 0

  . "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/core/scripts/hook-lib.sh"

  # Tell-detection program (node). Slurped into a top-level var — no heredoc
  # inside $( ) (hooks-heredoc-syntax.test.sh).
  JSPROG=''
  IFS= read -r -d '' JSPROG <<'JS' || true
let d = "";
process.stdin.on("data", (c) => d += c).on("end", () => {
  let blocks;
  try { blocks = JSON.parse(d); } catch (e) { console.log(""); return; }
  if (!Array.isArray(blocks)) { console.log(""); return; }

  // --- Gather the outbound-send bodies from this turn ----------------------
  // A send signature: an hq dm / hq cowork dm CLI call, a Slack
  // chat.postMessage, a Post-Bridge post, or the host-side mcp__hq__hq_dm
  // tool. For each, build the haystack of human-readable text to scrutinise.
  const SEND_BASH = /\bhq\s+(?:cowork\s+)?dm\b|chat\.postMessage|chat\.update|api\.post-bridge\.com\/v1\/posts|hq-slack[a-z-]*\.(?:sh|py)\b|graph\.facebook\.com\/[^\s"']*\/messages|api\.twilio\.com\/[^\s"']*\/Messages|\bosascript\b[^\n]*\b(?:Messages|WhatsApp)\b/i;
  // Outbound MCP tool names. Broad on purpose: a channel added later (a new
  // WhatsApp or SMS server) is covered without editing this hook again.
  // Matches either the tool verb after the final "__" (email/slack/sms/social
  // send + draft surfaces) or a channel name anywhere in the server segment.
  const SEND_TOOL = /__(?:send_email|send_draft|create_or_update_draft|send_message|post_message|create_post|publish_post|schedule_post|send_sms|send_text|send_whatsapp|send_dm|send_reply)$|(?:whatsapp|imessage|twilio|telegram|post[-_]?bridge|slack)/i;
  const TEXT_FIELDS = ["body", "text", "message", "content", "caption", "subject", "details", "prompt", "instructions", "markdown", "html_body", "plain_body"];
  const URL = /https?:\/\/\S+/g;

  const bodies = [];
  for (const b of blocks) {
    if (!b || typeof b !== "object" || b.type !== "tool_use") continue;
    const name = b.name || "";
    const inp = b.input || {};
    if (name === "Bash") {
      const cmd = (inp && typeof inp === "object") ? (inp.command || "") : "";
      // Drop URLs so a link in the body cannot create noise.
      if (cmd && SEND_BASH.test(cmd)) bodies.push(cmd.replace(URL, " "));
    } else if (name.endsWith("hq_dm") || name === "mcp__hq__hq_dm") {
      if (inp && typeof inp === "object")
        bodies.push(["message", "details", "prompt"].map((k) => String(inp[k] == null ? "" : inp[k])).join(" "));
    } else if (SEND_TOOL.test(name)) {
      // Outbound MCP surfaces: email (superhuman/gmail), Slack, WhatsApp,
      // SMS/iMessage, Telegram, and social publishers. Scrutinise only the
      // human-readable fields; never recipients, ids, or scheduling flags.
      if (inp && typeof inp === "object") {
        const t = TEXT_FIELDS.map((k) => (typeof inp[k] === "string" ? inp[k] : "")).join(" ");
        if (t.trim()) bodies.push(t.replace(URL, " "));
      }
    }
  }
  if (!bodies.length) { console.log(""); return; }

  // --- Tell categories ------------------------------------------------------
  const DASH = /—|–|(?<=\s)--(?=\s)/;
  const AI_VOCAB = /\b(?:delve|leverage(?:s|d|ing)?|seamless(?:ly)?|robust|testament|underscore(?:s|d|ing)?|showcas(?:e|es|ed|ing)|pivotal|vibrant|unlock(?:s|ed|ing)?|elevate(?:s|d|ing)?|harness(?:es|ed|ing)?|tapestry|intricate|crucial|foster(?:s|ed|ing)?|supercharge(?:s|d|ing)?|game[- ]?changer|cutting[- ]edge|paradigm|synerg(?:y|ies|istic))\b/i;
  const COLLAB = /\bI hope this helps\b|\blet me know if\b|\bfeel free to\b|\bgreat question\b|\bcertainly!|\bof course!|\bhappy to help\b|\byou'?re absolutely right\b|\bdon'?t hesitate to\b/i;
  const PROMO = /\bexcited to announce\b|\bthrilled to\b|\bdelighted to\b|\bproud to announce\b|\brevolutionar(?:y|ize)\b|\bbest-in-class\b|\bworld-class\b|\btake .* to the next level\b/i;
  const NEGPAR = /\bnot only\b[^.]*\bbut\b|\bit'?s not (?:just|merely) about\b|\bit'?s not just\b[^.]*\bit'?s\b/i;
  // --- mannered-prose tells (core/policies/hq-no-mannered-prose.md) --------
  // Antithesis: "not a X, it's a Y" / "less a X than a Y".
  const ANTITHESIS = /\bnot (?:a|an|the)\b[^.!?]{2,60}?,\s*(?:it'?s|but)\b|\bless (?:a|an)\b[^.!?]{2,60}?\bthan (?:a|an)\b|\bisn'?t (?:a|an|about)\b[^.!?]{2,60}?,\s*it'?s\b/i;
  // Rhythm triad: "faster, cleaner, and safer" — three short adjectives/nouns.
  const TRIAD = /\b[a-z]{3,14},\s+[a-z]{3,14},\s+(?:and|or)\s+[a-z]{3,14}\b/i;
  // Portentous fragment: a sentence-initial subordinator standing alone.
  const FRAGMENT = /(?:^|[.!?]\s)(?:Which is (?:the|why|what)|And that'?s (?:the|why)|That'?s the (?:whole )?point|Hence the)\b/;
  // Throat-clearing before the answer.
  const THROAT = /\b(?:here'?s the thing|the short version|the tl;?dr|worth noting|to be clear|at the end of the day|that said,)\b/i;
  // Unicode emoji (pictographic ranges) — NOT Slack :shortcode: ASCII text, so
  // the work-broadcast :chart_with_upwards_trend: signature is never counted.
  const EMOJI = /[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{1F1E6}-\u{1F1FF}\u{2190}-\u{21FF}\u{2B00}-\u{2BFF}]/u;

  const categories = (t) => {
    const c = new Set();
    if (DASH.test(t)) c.add("dash");
    if (AI_VOCAB.test(t)) c.add("ai_vocab");
    if (COLLAB.test(t)) c.add("collab");
    if (PROMO.test(t)) c.add("promo");
    if (NEGPAR.test(t)) c.add("neg_parallel");
    if (ANTITHESIS.test(t)) c.add("antithesis");
    if (TRIAD.test(t)) c.add("triad");
    if (FRAGMENT.test(t)) c.add("portentous_fragment");
    if (THROAT.test(t)) c.add("throat_clearing");
    if (EMOJI.test(t)) c.add("emoji");
    return c;
  };

  for (const body of bodies) {
    if (categories(body).size >= 2) { console.log("BLOCK"); break; }
  }
});
JS

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

  VERDICT="$(printf '%s' "$LAST_CONTENT" | node -e "$JSPROG" 2>/dev/null || true)"

  [ "$VERDICT" != "BLOCK" ] && exit 0

  REASON='POLICY VIOLATION — humanize-generated-content (hard) + humanize-before-send. The turn that just finished sent (or composed for send) an outbound message whose body still carries a cluster of AI-writing tells (em/en dashes, AI vocabulary, promotional or sycophantic framing, negative parallelisms, decorative emoji, or mannered prose: antithesis, rhythm triads, portentous fragments, throat-clearing). Per core/knowledge/public/hq-core/humanize-before-send.md the human-readable body MUST run the channel-aware humanize pass BEFORE it is sent. Do this now: (1) run the /humanize audit on the body at the channel intensity (dm/cowork-dm default light, work-broadcast light, email/social full), also applying core/policies/hq-no-mannered-prose.md, (2) re-issue the corrected message — for a store-and-forward DM that already went out, send the corrected version only if the original was clearly slop, otherwise apply the pass to every future send. Do NOT rewrite recipients, emails/personUids, URLs, scheduling flags, account IDs, or the work-broadcast :chart_with_upwards_trend: signature emoji — only the prose a person reads.'

  jq -nc --arg r "$REASON" '{decision:"block", reason:$r}' 2>/dev/null \
    || printf '{"decision":"block","reason":%s}' "$(printf '%s' "$REASON" | hq_json_encode)"
  exit 0
} 2>/dev/null || exit 0
