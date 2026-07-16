#!/bin/bash
# Journal auto-capture hook — appends a one-line digest of meta-thinking tool calls
# (Agent, AskUserQuestion, WebFetch, WebSearch) to the active session journal's
# `## Auto-capture` section.
#
# Spec: core/knowledge/public/hq-core/journal-spec.md
#
# Activation:
#   Resolves the hook payload's `session_id` to a session-scoped journal pointer.
#   If no session ID or pointer is available, the hook exits silently.
#
# Skipped tools (noisy or secret-risky):
#   Bash, Read, Edit, Write, Grep, Glob, NotebookEdit, TodoWrite, anything else
#   not in the allowlist below.
#
# Non-blocking: failures are logged to /tmp/hq-journal-autocapture.log but never
# propagate. Hook always exits 0.

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
JOURNAL_HELPER="$PROJECT_DIR/.claude/skills/_shared/journal.sh"
LOG_FILE="/tmp/hq-journal-autocapture.log"
STALE_SECONDS=7200  # 2 hours
OVERFLOW_BYTES=1024  # spill raw tool output to journal/attachments/ when above this

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] journal-autocapture: $*" >> "$LOG_FILE" 2>/dev/null || true
}

trap 'exit 0' EXIT

# 1. Read tool JSON and resolve its session-scoped pointer. Hooks do not use
# the legacy pointer: a payload without a session_id cannot safely own one.
INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/core/scripts/hook-lib.sh"

SESSION_ID=$(printf '%s' "$INPUT" | hq_json_get session_id)
[ -n "$SESSION_ID" ] || exit 0
[ -x "$JOURNAL_HELPER" ] || exit 0

JOURNAL=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" HQ_JOURNAL_SESSION="$SESSION_ID" "$JOURNAL_HELPER" path 2>/dev/null || true)
[ -n "$JOURNAL" ] || exit 0
[ -f "$JOURNAL" ] || { log "pointer references missing file: $JOURNAL"; exit 0; }

# 2. Stale check
NOW=$(date +%s)
case "$(uname -s)" in
  Darwin|FreeBSD) MTIME=$(stat -f %m "$JOURNAL" 2>/dev/null || echo 0) ;;
  *) MTIME=$(stat -c %Y "$JOURNAL" 2>/dev/null || echo 0) ;;
esac
if [ "$MTIME" -gt 0 ] && [ $((NOW - MTIME)) -gt $STALE_SECONDS ]; then
  log "journal stale (mtime $((NOW - MTIME))s ago): $JOURNAL — skipping"
  exit 0
fi

# 3. auto_capture frontmatter check
if ! head -20 "$JOURNAL" 2>/dev/null | grep -q '^auto_capture: true'; then
  exit 0
fi

# 4. Status check — only append to active journals
if head -20 "$JOURNAL" 2>/dev/null | grep -qE '^status: (closed|abandoned)'; then
  exit 0
fi

# 5. Read tool name
TOOL_NAME=$(printf '%s' "$INPUT" | hq_json_get tool_name)

case "$TOOL_NAME" in
  Agent|AskUserQuestion|WebFetch|WebSearch) ;;
  *) exit 0 ;;
esac

# 6. Build digest line (with overflow spill into journal/attachments/)
# Project dir comes from journal frontmatter. Verify that the journal remains
# beneath it before any overflow attachment write.
PROJ_ROOT=$(awk '/^project: / { sub(/^project: /, ""); print; exit }' "$JOURNAL" 2>/dev/null)
[ -n "$PROJ_ROOT" ] || { log "journal has no project frontmatter: $JOURNAL"; exit 0; }
if [ "${PROJ_ROOT#/}" = "$PROJ_ROOT" ]; then
  PROJ_ROOT="$PROJECT_DIR/$PROJ_ROOT"
fi
PROJ_ROOT=$(cd "$PROJ_ROOT" 2>/dev/null && pwd -P) || { log "journal project is unavailable: $JOURNAL"; exit 0; }
case "$JOURNAL" in
  "$PROJ_ROOT"/journal/*) ;;
  *) log "journal is outside its project: $JOURNAL"; exit 0 ;;
esac
export JOURNAL_PROJECT="$PROJ_ROOT"
export JOURNAL_OVERFLOW_BYTES="$OVERFLOW_BYTES"

# Digest builder runs on node (python-free hooks). Without node the digest is
# skipped — same silent degradation the python version had without python3.
# Slurp the program into a top-level var (no heredoc inside $(...); see
# hooks-heredoc-syntax.test.sh), then run with `node -e`.
command -v node >/dev/null 2>&1 || exit 0
JSPROG=''
IFS= read -r -d '' JSPROG <<'JS' || true
const fs = require("fs"), path = require("path"), crypto = require("crypto");
const OVERFLOW = parseInt(process.env.JOURNAL_OVERFLOW_BYTES || "1024", 10);
const PROJ = process.env.JOURNAL_PROJECT || "";

const truncate = (s, n = 200) => {
  s = String(s == null ? "" : s).trim().split(/\s+/).join(" ");
  return s.length <= n ? s : s.slice(0, n).replace(/\s+$/, "") + "...";
};
const safeGet = (obj, ...keys) => {
  let cur = obj;
  for (const k of keys) {
    if (cur && typeof cur === "object" && !Array.isArray(cur) && k in cur) cur = cur[k];
    else return "";
  }
  return cur || "";
};
const utc = (fmt) => {
  const d = new Date(), p = (x) => String(x).padStart(2, "0");
  const date = d.getUTCFullYear() + "-" + p(d.getUTCMonth() + 1) + "-" + p(d.getUTCDate());
  const h = p(d.getUTCHours()), m = p(d.getUTCMinutes()), s = p(d.getUTCSeconds());
  return fmt === "file" ? date + "-" + h + m + s : date + "T" + h + ":" + m + ":" + s + "Z";
};
const spill = (tool, raw) => {
  if (!PROJ || !raw) return "";
  let body;
  try { body = typeof raw === "string" ? raw : JSON.stringify(raw); } catch (e) { return ""; }
  if (Buffer.byteLength(body, "utf8") <= OVERFLOW) return "";
  try {
    const h = crypto.createHash("sha256").update(body, "utf8").digest("hex").slice(0, 6);
    const attDir = path.join(PROJ, "journal", "attachments");
    fs.mkdirSync(attDir, { recursive: true });
    const name = utc("file") + "-" + tool.toLowerCase() + "-" + h + ".txt";
    fs.writeFileSync(path.join(attDir, name), body);
    return "journal/attachments/" + name;
  } catch (e) { process.stderr.write("spill-error: " + e + "\n"); return ""; }
};
const withSpill = (line, tool, raw) => {
  const rel = spill(tool, raw);
  return rel ? line + " (full: " + rel + ")" : line;
};

let d = "";
process.stdin.on("data", (c) => d += c).on("end", () => {
  try {
    const data = JSON.parse(d);
    const tool = data.tool_name || "";
    const inp = data.tool_input || {};
    const resp = data.tool_response || data.tool_output || {};
    const ts = utc();

    if (tool === "Agent") {
      const desc = safeGet(inp, "description") || safeGet(inp, "subagent_type") || "agent";
      let resultText = "";
      if (typeof resp === "string") resultText = resp;
      else if (Array.isArray(resp)) resultText = resp.map(String).join(" ");
      else if (resp && typeof resp === "object")
        resultText = resp.content || resp.result || JSON.stringify(resp).slice(0, 500);
      console.log(withSpill("- " + ts + " [Agent] " + truncate(desc, 80) + ": " + truncate(resultText, 200), "agent", resultText));

    } else if (tool === "AskUserQuestion") {
      const questions = inp.questions || [];
      const firstQ = questions[0] || {};
      const header = safeGet(firstQ, "header") || safeGet(firstQ, "question") || "question";
      let answer = "";
      if (Array.isArray(resp) && resp.length)
        answer = safeGet(resp[0], "answer") || safeGet(resp[0], "label") || String(resp[0]).slice(0, 100);
      else if (resp && typeof resp === "object") {
        const answers = resp.answers || resp.responses || [];
        if (Array.isArray(answers) && answers.length) {
          const a0 = answers[0];
          answer = (a0 && typeof a0 === "object") ? (a0.answer || a0.label || "") : String(a0);
        } else answer = resp.answer || "";
      }
      console.log("- " + ts + " [AskUserQuestion] " + truncate(header, 80) + " -> " + truncate(answer, 120));

    } else if (tool === "WebFetch") {
      const url = safeGet(inp, "url"), prompt = safeGet(inp, "prompt");
      let content = "";
      if (typeof resp === "string") content = resp;
      else if (resp && typeof resp === "object" && !Array.isArray(resp)) content = resp.content || resp.result || "";
      console.log(withSpill("- " + ts + " [WebFetch] " + truncate(url, 100) + " (" + truncate(prompt, 60) + "): " + truncate(content, 150), "webfetch", content));

    } else if (tool === "WebSearch") {
      const query = safeGet(inp, "query");
      let title = "", fullResults = "";
      if (resp && typeof resp === "object" && !Array.isArray(resp)) {
        const results = resp.results || [];
        if (Array.isArray(results) && results.length) {
          title = safeGet(results[0], "title") || safeGet(results[0], "url") || "";
          try { fullResults = JSON.stringify(results); } catch (e) { fullResults = ""; }
        }
      } else if (Array.isArray(resp) && resp.length) {
        title = safeGet(resp[0], "title") || String(resp[0]).slice(0, 100);
        try { fullResults = JSON.stringify(resp); } catch (e) { fullResults = ""; }
      }
      console.log(withSpill("- " + ts + " [WebSearch] \"" + truncate(query, 100) + "\" -> " + truncate(title, 120), "websearch", fullResults));
    }
  } catch (e) {
    process.stderr.write("parse-error: " + e + "\n");
  }
});
JS

ENTRY=$(printf '%s' "$INPUT" | node -e "$JSPROG" 2>>"$LOG_FILE")

[ -z "$ENTRY" ] && exit 0

# 7. Append under `## Auto-capture`
if grep -q '^## Auto-capture' "$JOURNAL" 2>/dev/null; then
  printf '%s\n' "$ENTRY" >> "$JOURNAL" 2>>"$LOG_FILE" || log "append failed: $JOURNAL"
else
  {
    printf '\n## Auto-capture\n'
    printf '%s\n' "$ENTRY"
  } >> "$JOURNAL" 2>>"$LOG_FILE" || log "append-with-header failed: $JOURNAL"
fi

exit 0
