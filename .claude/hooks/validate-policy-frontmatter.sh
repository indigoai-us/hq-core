#!/bin/bash
# validate-policy-frontmatter.sh — PreToolUse (Write, Edit, MultiEdit).
#
# Blocks the create/edit of a POLICY file whose RESULTING frontmatter is missing
# `when:` or `on:` — the two fields that drive just-in-time policy injection
# (see core/knowledge/public/hq-core/policies-spec.md). Every policy authored or
# edited must declare both.
#
# Targets: */policies/*.md (core/, companies/*/, repos/*/*/.claude/, personal/).
# Excludes: README.md and the .claude/audit/ redaction-rule store (those are not
# trigger-injected policies). The retired `_digest.md` path has no exemption.
#
# Advisory-safe: FAILS OPEN (exit 0) on any ambiguity — non-policy paths,
# unparsable input, or when neither analyzer engine is usable — so it never
# blocks an unrelated write. It only ever exits 2 when it is confident the
# target is a policy file lacking when/on. Engines: node first (complex
# analyzers run on node per the hooks-no-python migration), else a jq/awk port
# of the same analyzer. python3 is no longer used — on Windows the Store alias
# stub used to pass `command -v python3` while failing every invocation, which
# silently disabled this validator.
#
# Override: set HQ_ALLOW_POLICY_NO_TRIGGER=1 in .claude/settings.local.json env.
#
# Exit codes: 0 = allow, 2 = block.
#
# Wired in .claude/settings.json PreToolUse (Edit/Write/MultiEdit) and gated by
# hook-gate.sh under "validate-policy-frontmatter" (all three profiles).

set -uo pipefail

INPUT="$(cat)"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
JQ="$(command -v jq || true)"
NODE="$(command -v node || true)"
case "${HQ_HOOK_ENGINE:-}" in
  jq)   NODE="" ;;
  node) JQ="" ;;
esac
if [ -z "$NODE" ] && [ -z "$JQ" ]; then exit 0; fi   # fail open

# Slurp the analyzer into a top-level var (NOT a heredoc inside $(...), which
# bash 3.2 / macOS mis-parses — see hooks-heredoc-syntax.test.sh), then run via
# `node -e`. Tool JSON is passed through the environment, not stdin/argv.
JSPROG=''
IFS= read -r -d '' JSPROG <<'JS' || true
const fs = require("fs");
const path = require("path");

const allow = () => { console.log("ALLOW"); process.exit(0); };

let data;
try { data = JSON.parse(process.env.HQ_HOOK_INPUT || ""); } catch (e) { allow(); }
const ti = (data && typeof data === "object" && data.tool_input && typeof data.tool_input === "object")
  ? data.tool_input : {};
const fp = ti.file_path || "";
if (!fp) allow();

const proj = process.env.HQ_PROJECT_DIR || "";
const p = path.isAbsolute(fp) ? fp : path.normalize(path.join(proj, fp));
const low = p.toLowerCase().replace(/\\/g, "/");

if (!(low.endsWith(".md") && low.includes("/policies/"))) allow();
const base = low.split("/").pop();
if (base === "readme.md") allow();
if (low.includes("/audit/")) allow();   // secret-redaction store, not a policy

const readCurrent = () => { try { return fs.readFileSync(p, "utf8"); } catch (e) { return ""; } };
// literal replace-once; a function replacement so "$&"-style patterns in the
// new string are never interpreted
const replaceOnce = (hay, o, n) => (o === "" ? hay : hay.replace(o, () => n));

let text = null;
if (ti.content !== undefined && ti.content !== null) {          // Write
  text = String(ti.content);
} else if (Array.isArray(ti.edits)) {                           // MultiEdit
  text = readCurrent();
  for (const e of ti.edits) {
    const o = String((e && e.old_string) || ""), n = String((e && e.new_string) || "");
    text = (o === "" && text === "") ? n : replaceOnce(text, o, n);
  }
} else if ("new_string" in ti) {                                // Edit
  const cur = readCurrent();
  const o = String(ti.old_string || ""), n = String(ti.new_string || "");
  text = (cur === "" && o === "") ? n : replaceOnce(cur, o, n);
} else allow();

if (text === null) allow();

// Analyze a line-ending-normalized COPY (CRLF / lone-CR -> LF): Windows
// editors produce \r\n and the python original tolerated it via \s*. The
// edit replay above runs on the RAW text so old_string matching is exact.
const norm = String(text).replace(/\r\n/g, "\n").replace(/\r/g, "\n");
const m = norm.match(/^\s*---[ \t]*\n([\s\S]*?)\n---[ \t]*(\n|$)/);
if (!m) { console.log("BLOCK|no-frontmatter"); process.exit(0); }
const fm = m[1];
const missing = [];
if (!/^\s*when:\s*\S/m.test(fm)) missing.push("when");
if (!/^\s*on:\s*\S/m.test(fm)) missing.push("on");
console.log(missing.length ? "BLOCK|" + missing.join(",") : "ALLOW");
JS

# Literal replace-once (newline-safe) for the jq/awk fallback engine. Strings
# cross via ENVIRON, not `awk -v`: -v mangles backslash escapes and BSD/
# onetrueawk aborts on newlines in -v values (same constraint as
# inject-policy-on-trigger.sh's HQ_ALREADY).
replace_once() {  # env: R_CUR R_OLD R_NEW -> stdout
  awk 'BEGIN{
    cur=ENVIRON["R_CUR"]; old=ENVIRON["R_OLD"]; new=ENVIRON["R_NEW"]
    if (old=="") { printf "%s", cur; exit }
    i=index(cur, old)
    if (i==0) printf "%s", cur
    else printf "%s%s%s", substr(cur,1,i-1), new, substr(cur,i+length(old))
  }'
}

# jq/awk port of the node analyzer above — same path filters, same
# resulting-text semantics (Write content / Edit / MultiEdit replays), same
# ALLOW / BLOCK|missing contract. Used when node is unavailable.
analyze_with_jq() {
  local fp path low base kind text cur o n count idx
  fp="$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.file_path // empty' 2>/dev/null || true)"
  [ -n "$fp" ] || { echo ALLOW; return; }
  case "$fp" in /*|[A-Za-z]:*) path="$fp" ;; *) path="$PROJECT_DIR/$fp" ;; esac
  low="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]' | tr '\\' '/')"
  case "$low" in *.md) : ;; *) echo ALLOW; return ;; esac
  case "$low" in */policies/*) : ;; *) echo ALLOW; return ;; esac
  base="${low##*/}"
  case "$base" in readme.md) echo ALLOW; return ;; esac
  case "$low" in */audit/*) echo ALLOW; return ;; esac

  kind="$(printf '%s' "$INPUT" | "$JQ" -r 'if (.tool_input.content? != null) then "write" elif ((.tool_input.edits? | type) == "array") then "multi" elif (.tool_input | has("new_string")) then "edit" else "none" end' 2>/dev/null || echo none)"
  case "$kind" in
    write) text="$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.content')" ;;
    edit)
      cur=""; [ -f "$path" ] && cur="$(cat "$path" 2>/dev/null || true)"
      o="$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.old_string // ""')"
      n="$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.new_string // ""')"
      if [ -z "$cur" ] && [ -z "$o" ]; then text="$n"
      else text="$(R_CUR="$cur" R_OLD="$o" R_NEW="$n" replace_once)"; fi
      ;;
    multi)
      cur=""; [ -f "$path" ] && cur="$(cat "$path" 2>/dev/null || true)"
      text="$cur"
      count="$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.edits | length' 2>/dev/null || echo 0)"
      idx=0
      while [ "$idx" -lt "${count:-0}" ]; do
        o="$(printf '%s' "$INPUT" | "$JQ" -r ".tool_input.edits[$idx].old_string // \"\"")"
        n="$(printf '%s' "$INPUT" | "$JQ" -r ".tool_input.edits[$idx].new_string // \"\"")"
        if [ -z "$o" ] && [ -z "$text" ]; then text="$n"
        else text="$(R_CUR="$text" R_OLD="$o" R_NEW="$n" replace_once)"; fi
        idx=$((idx+1))
      done
      ;;
    *) echo ALLOW; return ;;
  esac

  printf '%s' "$text" | awk '
    # normalize line endings (CRLF / stray CR) before structural checks —
    # mirrors the node engine and the python original'"'"'s \s* tolerance
    { line=$0; sub(/\r$/, "", line); L[NR]=line }
    END{
      i=1
      while (i<=NR && L[i] ~ /^[ \t]*$/) i++
      if (i>NR || L[i] !~ /^[ \t]*---[ \t]*$/) { print "BLOCK|no-frontmatter"; exit }
      i++
      closed=0; w=0; o=0
      for (; i<=NR; i++) {
        if (L[i] ~ /^---[ \t]*$/) { closed=1; break }
        if (L[i] ~ /^[ \t]*when:[ \t]*[^ \t]/) w=1
        if (L[i] ~ /^[ \t]*on:[ \t]*[^ \t]/) o=1
      }
      if (!closed) { print "BLOCK|no-frontmatter"; exit }
      m=""
      if (!w) m="when"
      if (!o) m=(m=="" ? "on" : m ",on")
      if (m!="") print "BLOCK|" m; else print "ALLOW"
    }'
}

if [ -n "$NODE" ]; then
  RESULT="$(HQ_HOOK_INPUT="$INPUT" HQ_PROJECT_DIR="$PROJECT_DIR" "$NODE" -e "$JSPROG" 2>/dev/null || echo ALLOW)"
else
  RESULT="$(analyze_with_jq)"
fi

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
