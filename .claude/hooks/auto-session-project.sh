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

extract() {
  printf '%s' "$STDIN_JSON" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    value = data.get(sys.argv[1], "")
    sys.stdout.write(str(value if value is not None else ""))
except Exception:
    pass
' "$1" 2>/dev/null || true
}

PROMPT="$(extract prompt)"
SESSION_ID="$(extract session_id)"
[ -z "$SESSION_ID" ] && SESSION_ID="default"

# NOTE: slurp the classifier into a variable via a standalone heredoc, then run
# it with `python3 -c`. A heredoc nested inside a `$( … )` substitution is
# mis-parsed as an unterminated quote by macOS system bash 3.2
# (policy indigo-hook-no-heredoc-in-command-substitution).
classify_py=""
IFS= read -r -d '' classify_py <<'PY' || true
import json
import os
import pathlib
import re
import sys

hq = pathlib.Path(sys.argv[1])
prompt = os.environ.get("AUTO_SESSION_PROJECT_PROMPT", "").strip()
lower = prompt.lower()

skip_patterns = [
    r"^\s*(thanks|thank you|ok|okay|cool|yes|no|continue from where you left off)\s*[.!]?\s*$",
    r"^\s*/(journal|checkpoint|handoff|prd|plan|deep-plan|run-project|execute-task|startwork|brainstorm)\b",
]

skip = not prompt or len(prompt.split()) < 3
for pattern in skip_patterns:
    if re.search(pattern, lower):
        skip = True

# Continuation / approval guard: prompts like "ok do it", "go for it",
# "do it for me", "ya do it", "1 and 2", "do it in this session" are replies
# that advance existing work — they must NOT name a new project. Strip
# approval/filler tokens; if fewer than 2 content words remain, skip.
APPROVAL = {
    "ok", "okay", "k", "kk", "yes", "yep", "yeah", "ya", "yup", "sure", "cool",
    "nice", "great", "good", "perfect", "thanks", "thank", "you", "please",
    "pls", "go", "ahead", "for", "it", "do", "that", "this", "now", "lets",
    "let", "us", "proceed", "continue", "just", "still", "and", "then", "also",
    "the", "a", "an", "to", "with", "up", "on", "in", "of", "both", "all",
    "sounds", "lgtm", "fine", "yea", "right", "correct", "exactly", "agreed",
    "approve", "approved", "next", "keep", "going", "again", "more", "plus",
    "number", "make", "sense", "im", "i", "m", "we", "should", "can", "could",
}
if not skip:
    toks = re.findall(r"[a-z0-9]+", lower)
    content = [t for t in toks if t not in APPROVAL and not t.isdigit() and len(t) > 1]
    if len(content) < 2:
        skip = True

scope = "personal"
company = ""

first = re.sub(r"[^a-z0-9_-]", "", (lower.split() or [""])[0])
company_dir = hq / "companies" / first
if first and company_dir.is_dir() and first not in {"template", "_template"}:
    scope = "company"
    company = first

hq_signals = [
    "hqwork", "hq core", "hq-core", ".claude/", ".codex/", "core/scripts",
    "core/policies", "hook", "hooks", "policy", "policies", "skill",
    "skills", "slash command", "commands", "session journal", "native plan",
    "run-project", "prd.json",
]
if any(signal in lower for signal in hq_signals):
    scope = "hq-core"
    company = ""

clean = re.sub(r"\[[^\]]+\]\([^)]+\)", " ", prompt)
clean = re.sub(r"\s+", " ", clean).strip()
words = clean.split()
title = " ".join(words[:12]).strip(" ,.;:!?") or "Native session"
if len(title) > 90:
    title = title[:90].rstrip()

print(json.dumps({"skip": skip, "scope": scope, "company": company, "title": title}))
PY

classification_json="$(AUTO_SESSION_PROJECT_PROMPT="$PROMPT" python3 -c "$classify_py" "$HQ_ROOT")"

skip="$(printf '%s' "$classification_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("skip", True))' 2>/dev/null || echo True)"
[ "$skip" = "True" ] && exit 0

scope="$(printf '%s' "$classification_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("scope", "personal"))' 2>/dev/null || echo personal)"
company="$(printf '%s' "$classification_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("company", ""))' 2>/dev/null || true)"
title="$(printf '%s' "$classification_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("title", "Native session"))' 2>/dev/null || echo "Native session")"

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

project_dir="$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("projectDir", ""))' 2>/dev/null || true)"
prd_path="$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("prdPath", ""))' 2>/dev/null || true)"
reused="$(printf '%s' "$result" | python3 -c 'import json,sys; print(str(json.load(sys.stdin).get("reused", False)).lower())' 2>/dev/null || echo false)"

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
