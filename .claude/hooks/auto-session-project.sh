#!/usr/bin/env bash
# UserPromptSubmit hook: ensure native sessions have a durable HQ project target.
#
# Explicit /prd, /plan, /deep-plan, /run-project, and /startwork flows already
# own project selection. This hook covers the native path where a user simply
# asks Claude/Codex to think, plan, or execute.

set -uo pipefail

STDIN_JSON="$(cat 2>/dev/null || echo '{}')"
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
HELPER="$HQ_ROOT/core/scripts/session-project.sh"
STATE_DIR="$HQ_ROOT/.claude/state"

case "${HQ_AUTO_SESSION_PROJECT:-1}" in
  0|false|FALSE|off|OFF|no|NO) exit 0 ;;
esac

disabled_hooks=",${HQ_DISABLED_HOOKS:-},"
disabled_hooks="$(printf '%s' "$disabled_hooks" | tr -d '[:space:]')"
case "$disabled_hooks" in
  *,auto-session-project,*) exit 0 ;;
esac

[ -x "$HELPER" ] || exit 0

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/core/scripts/hook-lib.sh"
command -v node >/dev/null 2>&1 || exit 0

extract() {
  printf '%s' "$STDIN_JSON" | hq_json_get "$1"
}

PROMPT="$(extract prompt)"
SESSION_ID="$(extract session_id)"
[ -z "$SESSION_ID" ] && SESSION_ID="default"

# NOTE: slurp the classifier into a variable via a standalone heredoc, then run
# it with `node -e`. A heredoc nested inside a `$( … )` substitution is
# mis-parsed as an unterminated quote by macOS system bash 3.2
# (policy indigo-hook-no-heredoc-in-command-substitution).
classify_js=""
IFS= read -r -d '' classify_js <<'JS' || true
const fs = require("fs");
const path = require("path");

const hq = process.argv[1] || "";
const prompt = (process.env.AUTO_SESSION_PROJECT_PROMPT || "").trim();
const lower = prompt.toLowerCase();

const skipPatterns = [
  /^\s*(thanks|thank you|ok|okay|cool|yes|no|continue from where you left off)\s*[.!]?\s*$/,
  /^\s*\/(journal|checkpoint|handoff|prd|plan|deep-plan|run-project|execute-task|startwork|brainstorm)\b/,
];

let skip = !prompt || prompt.split(/\s+/).length < 3;
for (const p of skipPatterns) if (p.test(lower)) skip = true;

// Continuation / approval guard: prompts like "ok do it", "go for it",
// "do it for me", "ya do it", "1 and 2", "do it in this session" are replies
// that advance existing work — they must NOT name a new project. Strip
// approval/filler tokens; if fewer than 2 content words remain, skip.
const APPROVAL = new Set([
  "ok", "okay", "k", "kk", "yes", "yep", "yeah", "ya", "yup", "sure", "cool",
  "nice", "great", "good", "perfect", "thanks", "thank", "you", "please",
  "pls", "go", "ahead", "for", "it", "do", "that", "this", "now", "lets",
  "let", "us", "proceed", "continue", "just", "still", "and", "then", "also",
  "the", "a", "an", "to", "with", "up", "on", "in", "of", "both", "all",
  "sounds", "lgtm", "fine", "yea", "right", "correct", "exactly", "agreed",
  "approve", "approved", "next", "keep", "going", "again", "more", "plus",
  "number", "make", "sense", "im", "i", "m", "we", "should", "can", "could",
]);
if (!skip) {
  const toks = lower.match(/[a-z0-9]+/g) || [];
  const content = toks.filter((t) => !APPROVAL.has(t) && !/^[0-9]+$/.test(t) && t.length > 1);
  if (content.length < 2) skip = true;
}

let scope = "personal";
let company = "";

const first = (lower.split(/\s+/)[0] || "").replace(/[^a-z0-9_-]/g, "");
try {
  if (first && first !== "template" && first !== "_template" &&
      fs.statSync(path.join(hq, "companies", first)).isDirectory()) {
    scope = "company";
    company = first;
  }
} catch (e) {}

const hqSignals = [
  "hqwork", "hq core", "hq-core", ".claude/", ".codex/", "core/scripts",
  "core/policies", "hook", "hooks", "policy", "policies", "skill",
  "skills", "slash command", "commands", "session journal", "native plan",
  "run-project", "prd.json",
];
if (hqSignals.some((s) => lower.includes(s))) {
  scope = "hq-core";
  company = "";
}

let clean = prompt.replace(/\[[^\]]+\]\([^)]+\)/g, " ").replace(/\s+/g, " ").trim();
let title = clean.split(" ").slice(0, 12).join(" ").replace(/^[ ,.;:!?]+/, "").replace(/[ ,.;:!?]+$/, "") || "Native session";
if (title.length > 90) title = title.slice(0, 90).replace(/\s+$/, "");

console.log(JSON.stringify({ skip: skip, scope: scope, company: company, title: title }));
JS

classification_json="$(AUTO_SESSION_PROJECT_PROMPT="$PROMPT" node -e "$classify_js" "$HQ_ROOT")"

# JSON booleans surface as the strings "true"/"false"; anything else (parse
# failure, empty) is treated as skip — same fail-closed default as before.
skip="$(printf '%s' "$classification_json" | hq_json_get skip)"
[ "$skip" = "false" ] || exit 0

scope="$(printf '%s' "$classification_json" | hq_json_get scope)"
[ -n "$scope" ] || scope="personal"
company="$(printf '%s' "$classification_json" | hq_json_get company)"
title="$(printf '%s' "$classification_json" | hq_json_get title)"
[ -n "$title" ] || title="Native session"

mkdir -p "$STATE_DIR" 2>/dev/null || true
SESSION_KEY="$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9._-' '_')"
[ -n "$SESSION_KEY" ] || SESSION_KEY="default"
SESSION_MARKER="$STATE_DIR/auto-session-project-${SESSION_KEY}"

if [ -f "$SESSION_MARKER" ]; then
  "$HELPER" append-event --kind user-prompt --summary "$title" >/dev/null 2>&1 || true
  exit 0
fi

result="$("$HELPER" ensure \
  --scope "$scope" \
  --company "$company" \
  --title "$title" \
  --prompt "$PROMPT" \
  --session-id "$SESSION_ID" \
  --origin "auto-session-project" 2>/dev/null || true)"

[ -z "$result" ] && exit 0

project_dir="$(printf '%s' "$result" | hq_json_get projectDir)"
prd_path="$(printf '%s' "$result" | hq_json_get prdPath)"
reused="$(printf '%s' "$result" | hq_json_get reused)"
[ -n "$reused" ] || reused="false"

[ -n "$project_dir" ] || exit 0
printf '%s\n' "$project_dir" > "$SESSION_MARKER" 2>/dev/null || true

context="AUTO SESSION PROJECT ACTIVE

Project: $project_dir
PRD: $prd_path
Selection: $( [ "$reused" = "true" ] && printf 'reused related project' || printf 'created lightweight native-session project' )

Use this project as the durable home for native work in this session. Before creating another project, search related projects first. After native Claude/Codex plan approval, update this PRD via:
  core/scripts/session-project.sh ingest-plan

Disable with HQ_AUTO_SESSION_PROJECT=0 or HQ_DISABLED_HOOKS=auto-session-project."

jq -n --arg ctx "<auto-session-project>
$context
</auto-session-project>" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $ctx
  }
}'

exit 0
