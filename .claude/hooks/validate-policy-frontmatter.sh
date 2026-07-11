#!/bin/bash
# validate-policy-frontmatter.sh — PreToolUse (Write, Edit, MultiEdit).
#
# Blocks the create/edit of a POLICY file whose RESULTING frontmatter is missing
# `when:` or `on:` — the two fields that drive just-in-time policy injection
# (see core/knowledge/public/hq-core/policies-spec.md). Every policy authored or
# edited must declare both.
#
# Targets: */policies/*.md (core/, companies/*/, repos/*/*/.claude/, personal/).
# Excludes: README.md, _digest.md, and the .claude/audit/ redaction-rule store
# (those are not trigger-injected policies).
#
# Advisory-safe: FAILS OPEN (exit 0) on any ambiguity — non-policy paths, unparsable
# input, or a missing python3 — so it never blocks an unrelated write. It only
# ever exits 2 when it is confident the target is a policy file lacking when/on.
#
# Override: set HQ_ALLOW_POLICY_NO_TRIGGER=1 in .claude/settings.local.json env.
#
# Exit codes: 0 = allow, 2 = block.
#
# Wired in .claude/settings.json PreToolUse (Edit/Write/MultiEdit) and gated by
# hook-gate.sh under "validate-policy-frontmatter" (all three profiles).

set -uo pipefail

INPUT="$(cat)"
command -v python3 >/dev/null 2>&1 || exit 0   # fail open

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Slurp the analyzer into a top-level var (NOT a heredoc inside $(...), which
# bash 3.2 / macOS mis-parses — see hooks-heredoc-syntax.test.sh), then run via
# `python3 -c`. Tool JSON is passed through the environment, not stdin/argv.
PYPROG=''
IFS= read -r -d '' PYPROG <<'PY' || true
import os, json, re

try:
    data = json.loads(os.environ.get("HQ_HOOK_INPUT", ""))
except Exception:
    print("ALLOW"); raise SystemExit

ti = data.get("tool_input") or {}
fp = ti.get("file_path") or ""
if not fp:
    print("ALLOW"); raise SystemExit

proj = os.environ.get("HQ_PROJECT_DIR", "")
path = fp if os.path.isabs(fp) else os.path.normpath(os.path.join(proj, fp))
low = path.lower()

if not (low.endswith(".md") and "/policies/" in low):
    print("ALLOW"); raise SystemExit
if os.path.basename(low) in ("readme.md", "_digest.md"):
    print("ALLOW"); raise SystemExit
if "/audit/" in low:                      # secret-redaction store, not a policy
    print("ALLOW"); raise SystemExit

def read_current():
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read()
    except Exception:
        return ""

text = None
if ti.get("content") is not None:                       # Write
    text = ti["content"]
elif isinstance(ti.get("edits"), list):                 # MultiEdit
    text = read_current()
    for e in ti["edits"]:
        o = e.get("old_string", ""); n = e.get("new_string", "")
        text = n if (o == "" and text == "") else text.replace(o, n, 1)
elif "new_string" in ti:                                # Edit
    cur = read_current()
    o = ti.get("old_string", ""); n = ti.get("new_string", "")
    text = n if (cur == "" and o == "") else cur.replace(o, n, 1)
else:
    print("ALLOW"); raise SystemExit

if text is None:
    print("ALLOW"); raise SystemExit

m = re.match(r'^\s*---\s*\n(.*?)\n---\s*(\n|$)', text, re.DOTALL)
if not m:
    print("BLOCK|no-frontmatter"); raise SystemExit
fm = m.group(1)
missing = []
if re.search(r'(?m)^\s*when:\s*\S', fm) is None: missing.append("when")
if re.search(r'(?m)^\s*on:\s*\S',   fm) is None: missing.append("on")
print("BLOCK|" + ",".join(missing) if missing else "ALLOW")
PY

RESULT="$(HQ_HOOK_INPUT="$INPUT" HQ_PROJECT_DIR="$PROJECT_DIR" python3 -c "$PYPROG")"

case "$RESULT" in
  BLOCK*)
    if [ "${HQ_ALLOW_POLICY_NO_TRIGGER:-}" = "1" ] || [ "${HQ_ALLOW_POLICY_NO_TRIGGER:-}" = "true" ]; then
      exit 0
    fi
    reason="${RESULT#BLOCK|}"
    cat >&2 <<MSG
BLOCKED: policy file is missing required trigger frontmatter (missing: ${reason}).

Every policy under */policies/ must declare BOTH:
  when: <expression>   # e.g.  always  |  git && push  |  deploy || share
  on:   [<events>]     # any of PreToolUse, PostToolUse, UserPromptSubmit, AssistantIntent, SessionStart

These drive just-in-time policy injection. See
core/knowledge/public/hq-core/policies-spec.md ("Trigger Expressions").
Add both fields to the frontmatter, then retry.

(Operator override: set HQ_ALLOW_POLICY_NO_TRIGGER=1 in .claude/settings.local.json "env".)
MSG
    exit 2
    ;;
  *)
    exit 0
    ;;
esac
