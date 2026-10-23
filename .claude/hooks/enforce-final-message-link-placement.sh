#!/bin/bash
# hq-core: public
# Stop hook: enforce final-message link placement.
#
# The Claude desktop app folds every assistant text block that precedes a tool
# call into a collapsed sub-message and renders a generated summary of it; only
# the text after the turn's LAST tool call renders in full. A deploy or share
# link that lives only in a folded block is therefore invisible to the user
# (observed 2026-10-22: a *.hq.work storyboard link vanished from the rendered
# chat because a Bash call followed it).
#
# This hook scans the just-finished turn (every assistant record after the
# last real user prompt). If an HQ-deploy-style URL (https://<app>.hq.work...)
# appears in an assistant text block that was followed by another assistant
# record (tool call or later text) and the FINAL assistant text block does not
# carry that same URL, block the stop once with a corrective directive so the
# agent restates the link in the final message.
#
# Handles Claude transcripts and Codex rollouts (user prompt = response_item
# message with role user, or event_msg user_message). URLs inside fenced code
# blocks in earlier text do not count. node only starts when the tail contains
# "hq.work".
#
# Non-fatal by design: any error path exits 0. Loop-safe via stop_hook_active.

set -uo pipefail

{
  INPUT="$(cat 2>/dev/null || echo '{}')"

  command -v jq  >/dev/null 2>&1 || exit 0
  command -v node >/dev/null 2>&1 || exit 0

  HQ_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  . "$HQ_REPO_ROOT/core/scripts/hook-lib.sh"
  . "$HQ_REPO_ROOT/core/scripts/lib/transcript-tail.sh"

  STOP_ACTIVE="$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)"
  [ "$STOP_ACTIVE" = "true" ] && exit 0

  TRANSCRIPT_PATH="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
  [ -z "$TRANSCRIPT_PATH" ] || [ ! -r "$TRANSCRIPT_PATH" ] && exit 0

  # Bounded suffix: a whole turn can hold many tool calls, so read a wide tail.
  TRANSCRIPT_TAIL="$(hq_transcript_tail "$TRANSCRIPT_PATH" 1500000 2>/dev/null)" || exit 0
  [ -z "$TRANSCRIPT_TAIL" ] && exit 0

  # Cheap pre-check: most turns carry no deploy link, so skip starting node.
  # No grep -q: an early grep exit would SIGPIPE printf and fail the pipeline.
  printf '%s' "$TRANSCRIPT_TAIL" | grep -iF 'hq.work' >/dev/null 2>&1 || exit 0

  # Node program slurped into a var (no heredoc inside $( ), per hooks-heredoc test).
  JSPROG=''
  IFS= read -r -d '' JSPROG <<'JS' || true
let raw = "";
process.stdin.on("data", (c) => raw += c).on("end", () => {
  const lines = raw.split("\n").filter(Boolean);
  const recs = [];
  for (const l of lines) { try { recs.push(JSON.parse(l)); } catch (_) {} }
  const content = (r) => (r.type === "assistant" ? (r.message && r.message.content) : (r.payload && r.payload.content));
  const isAssistant = (r) => r.type === "assistant" || (r.type === "response_item" && r.payload && r.payload.type === "message" && r.payload.role === "assistant");
  // A real user prompt.
  // Claude: type user whose content is a string or holds a text block (not only tool_result).
  // Codex rollout: response_item message with role user (input_text content), or the
  // event_msg user_message twin. function_call_output / custom_tool_call_output
  // records carry no role, so tool output never counts as a prompt.
  const isUserPrompt = (r) => {
    if (!r || typeof r !== "object") return false;
    if (r.type === "user") {
      const c = r.message && r.message.content;
      if (typeof c === "string") return true;
      if (Array.isArray(c)) return c.some((b) => b && b.type === "text");
      return false;
    }
    const p = r.payload;
    if (!p || typeof p !== "object") return false;
    if (r.type === "response_item") return p.type === "message" && p.role === "user";
    if (r.type === "event_msg") return p.type === "user_message";
    return false;
  };
  let start = -1;
  for (let i = recs.length - 1; i >= 0; i--) { if (isUserPrompt(recs[i])) { start = i; break; } }
  const turn = recs.slice(start + 1).filter(isAssistant);
  if (turn.length < 2) return;
  const textOf = (r) => {
    const c = content(r);
    if (typeof c === "string") return c;
    if (Array.isArray(c)) return c.filter((b) => b && (b.type === "text" || b.type === "output_text")).map((b) => b.text || "").join("\n");
    return "";
  };
  const url = /https:\/\/[a-z0-9][a-z0-9-]*\.hq\.work(?:\/[^\s)<>"'`\]]*)?/gi;
  const norm = (u) => u.replace(/[.,;:!?)]+$/, "").replace(/\/+$/, "").toLowerCase();
  // Fenced code blocks (``` or ~~~) hold examples, not links meant for the user.
  const unfenced = (t) => {
    const out = [];
    let fence = null;
    for (const line of t.split("\n")) {
      const m = line.match(/^\s{0,3}(`{3,}|~{3,})/);
      if (fence) { if (m && m[1][0] === fence[0] && m[1].length >= fence.length) fence = null; continue; }
      if (m) { fence = m[1]; continue; }
      out.push(line);
    }
    return out.join("\n");
  };
  const finalText = textOf(turn[turn.length - 1]);
  const finalUrls = new Set((finalText.match(url) || []).map(norm));
  const missing = new Set();
  for (let i = 0; i < turn.length - 1; i++) {
    for (const u of (unfenced(textOf(turn[i])).match(url) || [])) {
      const n = norm(u);
      if (!finalUrls.has(n)) missing.add(n);
    }
  }
  if (missing.size) console.log("MISSING " + [...missing].join(" "));
});
JS

  VERDICT="$(printf '%s\n' "$TRANSCRIPT_TAIL" | node -e "$JSPROG" 2>/dev/null || true)"
  case "$VERDICT" in MISSING*) ;; *) exit 0 ;; esac
  LINKS="${VERDICT#MISSING }"

  REASON="FINAL-MESSAGE LINK PLACEMENT (HQ output style, hard rule). The turn that just finished surfaced a deploy link only in a text block that was followed by a tool call. The desktop app folds that block into a generated summary, so the user never saw the link: ${LINKS}. Restate every such link in full, as the last message of this turn, after all tool calls, in one plain line (for example: 'It is live here (members only): <url>'). Do not run any tool after writing it."

  jq -nc --arg r "$REASON" '{decision:"block", reason:$r}' 2>/dev/null \
    || printf '{"decision":"block","reason":%s}' "$(printf '%s' "$REASON" | hq_json_encode)"
  exit 0
} 2>/dev/null || exit 0
