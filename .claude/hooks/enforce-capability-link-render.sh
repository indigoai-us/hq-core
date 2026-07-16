#!/bin/bash
# Stop hook: enforce hq-secure-link-render-as-markdown.
#
# Scans ONLY the just-finished assistant message. If it surfaced a single-use
# capability URL (share-session / secrets-input) as bare visible text — i.e.
# not wrapped in a Markdown `](href)` — block the stop with a corrective
# directive so the agent re-mints (single-use) and re-renders as a Markdown
# inline link, per core/policies/hq-secure-link-render-as-markdown.md (hard).
#
# Mint-turn on-screen exposure cannot be un-rung; the block forces ONE
# corrective turn (fresh mint + proper render) and trains the behavior.
#
# Non-fatal by design: any error path exits 0 (never wedge session turnaround).
# Loop-safe: respects stop_hook_active so it blocks at most once per stop chain.

set -uo pipefail

{
  INPUT="$(cat 2>/dev/null || echo '{}')"

  command -v jq  >/dev/null 2>&1 || exit 0
  command -v node >/dev/null 2>&1 || exit 0

  . "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/core/scripts/hook-lib.sh"

  # Bare-capability-URL detector (node). Slurped into a top-level var — no
  # heredoc inside $( ) (hooks-heredoc-syntax.test.sh).
  JSPROG=''
  IFS= read -r -d '' JSPROG <<'JS' || true
let t = "";
process.stdin.on("data", (c) => t += c).on("end", () => {
  // Capability URL: a share-session / secrets-input path with a long opaque token.
  const cap = /https?:\/\/[^\s)<>"'`\]]+\/(?:share-session|secrets-input)\/[A-Za-z0-9_-]{20,}/g;

  // Spans that are inside a Markdown link href: ]( ... )
  const okSpans = [];
  const href = /\]\(\s*([^)\s]+)\s*\)/g;
  let m;
  while ((m = href.exec(t)) !== null) {
    const start = m.index + m[0].indexOf(m[1]);
    okSpans.push([start, start + m[1].length]);
  }
  const insideHref = (s, e) => okSpans.some(([a, b]) => a <= s && e <= b);

  while ((m = cap.exec(t)) !== null) {
    const seg = m[0];
    if (seg.includes("TOKEN_REDACTED")) continue;
    if (!insideHref(m.index, m.index + seg.length)) { console.log("BARE"); break; }
  }
});
JS

  STOP_ACTIVE="$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)"
  # Already in a continuation triggered by a prior block — do not re-block (loop guard).
  [ "$STOP_ACTIVE" = "true" ] && exit 0

  TRANSCRIPT_PATH="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
  [ -z "$TRANSCRIPT_PATH" ] || [ ! -r "$TRANSCRIPT_PATH" ] && exit 0

  # Last assistant message text only (the turn that just finished).
  LAST_TEXT="$(
    jq -rs '
      [ .[] | select(.type=="assistant") ] | last
      | .message.content
      | (if type=="array" then [ .[] | select(.type=="text") | .text ] | join("\n")
         elif type=="string" then .
         else "" end)
    ' "$TRANSCRIPT_PATH" 2>/dev/null || true
  )"
  [ -z "$LAST_TEXT" ] && exit 0

  VERDICT="$(printf '%s' "$LAST_TEXT" | node -e "$JSPROG" 2>/dev/null || true)"

  [ "$VERDICT" != "BARE" ] && exit 0

  REASON='POLICY VIOLATION — hq-secure-link-render-as-markdown (hard). The turn that just finished surfaced a single-use capability URL (share-session / secrets-input) as bare visible text. These tokens are single-use and on-screen exposure cannot be undone, so you MUST: (1) mint a FRESH link (the exposed one is burned), (2) render the new one as EXACTLY ONE Markdown inline link: [<purpose> — expires <ts> >](<full-url-with-token>) — label carries NO token, href carries the full token, (3) emit nothing else carrying the token (no bare URL, no code fence, no echoed segment). For any later/persisted mention use the redacted text form per hq-share-session-urls-are-capabilities. Re-issue the link correctly now.'

  jq -nc --arg r "$REASON" '{decision:"block", reason:$r}' 2>/dev/null \
    || printf '{"decision":"block","reason":%s}' "$(printf '%s' "$REASON" | hq_json_encode)"
  exit 0
} 2>/dev/null || exit 0
