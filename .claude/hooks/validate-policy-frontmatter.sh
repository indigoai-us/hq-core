#!/bin/bash
# validate-policy-frontmatter.sh — PreToolUse (Write, Edit, MultiEdit).
#
# Blocks the create/edit of a POLICY file whose RESULTING frontmatter is missing
# `when:` or `on:`, or whose `when:` is outside the documented boolean grammar.
# These fields drive just-in-time policy injection (see
# core/knowledge/public/hq-core/policies-spec.md). Every policy authored or
# edited must declare both, and malformed expressions must not reach the
# runtime's degraded compatibility path.
#
# For `enforcement: hard` it also enforces the two limits that keep an
# always-injected, full-text rule from eating the session it is meant to guard:
#   - no unconditional `when:` (a tautology containing `always`) on a REACTIVE
#     event — that outranks policies that genuinely matched. Unconditional
#     rules belong on `on: [SessionStart]`.
#   - a binding body at or under HQ_POLICY_HARD_RULE_MAX_BYTES (default 6144),
#     measured over the same span inject-policy-on-trigger.sh quotes: text
#     after the frontmatter, up to the first archival heading (`## Rationale`,
#     `## Background`, `## Change history`, `## Examples`, `## References`, …).
# Both are checked only for hard policies; core/scripts/lint-policy-triggers.sh
# reports the softer cases across the whole tree.
#
# Targets: */policies/*.md (core/, companies/*/, repos/*/*/.claude/, personal/).
# Excludes: README.md and the .claude/audit/ redaction-rule store (those are not
# trigger-injected policies). The retired `_digest.md` path has no exemption.
#
# Advisory-safe: FAILS OPEN (exit 0) on any ambiguity — non-policy paths,
# unparsable input, or when neither analyzer engine is usable — so it never
# blocks an unrelated write. It only ever exits 2 when it is confident the
# target is a policy file lacking when/on or carrying malformed `when:` syntax.
# Engines: node first (complex analyzers run on node per the hooks-no-python
# migration), else a jq/awk port of the same analyzer. python3 is no longer used
# — on Windows the Store alias stub used to pass `command -v python3` while
# failing every invocation, which silently disabled this validator.
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
const whenLines = [...fm.matchAll(/^[ \t]*when:[ \t]*(.*)$/gm)].map((match) => match[1]);
if (!whenLines.some((expr) => /\S/.test(expr))) missing.push("when");
if (!/^[ \t]*on:[ \t]*\S/m.test(fm)) missing.push("on");
if (missing.length) { console.log("BLOCK|" + missing.join(",")); process.exit(0); }

// Grammar-only validation. Tokens remain open: this checks syntax, not whether
// an identifier can be derived for a particular event. The runtime evaluators
// deliberately stay fail-open for legacy malformed policies.
const validWhen = (expr) => {
  let pos = 0;
  const skip = () => { while (pos < expr.length && /[ \t]/.test(expr[pos])) pos++; };
  const identifier = () => {
    skip();
    const match = expr.slice(pos).match(/^[A-Za-z0-9_.\/][A-Za-z0-9_.\/-]*/);
    if (!match) return false;
    pos += match[0].length;
    return true;
  };
  const atom = () => {
    skip();
    if (expr[pos] !== "(") return identifier();
    pos++;
    if (!orExpr()) return false;
    skip();
    if (expr[pos] !== ")") return false;
    pos++;
    return true;
  };
  const notExpr = () => {
    skip();
    if (expr[pos] === "!") { pos++; return notExpr(); }
    return atom();
  };
  const andExpr = () => {
    if (!notExpr()) return false;
    while (true) {
      skip();
      if (expr.slice(pos, pos + 2) !== "&&") return true;
      pos += 2;
      if (!notExpr()) return false;
    }
  };
  function orExpr() {
    if (!andExpr()) return false;
    while (true) {
      skip();
      if (expr.slice(pos, pos + 2) !== "||") return true;
      pos += 2;
      if (!andExpr()) return false;
    }
  }
  if (!orExpr()) return false;
  skip();
  return pos === expr.length;
};

if (!whenLines.every(validWhen)) { console.log("BLOCK|invalid-when"); process.exit(0); }

// ── Strictness rules for enforcement: hard ────────────────────────────────
// A hard policy is injected in FULL TEXT and, when its trigger is loose, on
// every event. Both cost is paid out of the same context the user is trying to
// work in, so both are constrained here — at authoring time, where the fix is
// one line — rather than being silently truncated at injection time.
const enfMatch = fm.match(/^[ \t]*enforcement:[ \t]*["']?([A-Za-z]+)["']?/m);
const isHard = enfMatch && enfMatch[1].toLowerCase() === "hard";

if (isHard) {
  // (1) `when: always` must not be paired with a reactive event. A tautology on
  // PreToolUse/PostToolUse/UserPromptSubmit/AssistantIntent is ranked as an
  // event-specific match and takes the cap slot of a policy that actually
  // matched. SessionStart is the documented home for unconditional rules.
  // A pure OR-chain containing `always` is a tautology; anything with && or !
  // is conditional and left alone.
  const tautological = whenLines.some((w) =>
    !/[&!]/.test(w) && /(^|[^A-Za-z0-9_./-])always([^A-Za-z0-9_./-]|$)/.test(w));
  const onLine = (fm.match(/^[ \t]*on:[ \t]*(.*)$/m) || [, ""])[1];
  const reactive = ["PreToolUse", "PostToolUse", "UserPromptSubmit", "AssistantIntent"]
    .filter((e) => onLine.includes(e));
  if (tautological && reactive.length) {
    console.log("BLOCK|hard-always-reactive|" + reactive.join(", "));
    process.exit(0);
  }

  // (2) Bound the binding text. Everything from the first archival heading on
  // is history, not rule — the injector already stops there, so measure the
  // same span the agent will actually be made to read.
  const STOP = /^#+[ \t]*(rationale|rationale and context|background|change history|changelog|history|examples?|references?|related|see also|sources?|provenance|evidence)[ \t]*$/;
  const after = norm.slice(m.index + m[0].length);
  const binding = [];
  for (const line of after.split("\n")) {
    if (STOP.test(line.trim().toLowerCase())) break;
    binding.push(line);
  }
  const bytes = Buffer.byteLength(binding.join("\n").trim(), "utf8");
  const max = parseInt(process.env.HQ_POLICY_HARD_RULE_MAX_BYTES || "6144", 10);
  if (Number.isFinite(max) && max > 0 && bytes > max) {
    console.log("BLOCK|hard-too-long|" + bytes + "|" + max);
    process.exit(0);
  }
}

console.log("ALLOW");
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
    # Syntax-only parser for the documented when: grammar. It deliberately
    # does not constrain identifier vocabulary; it only enforces token and
    # operator placement, non-empty groups, and balanced parentheses.
    function validwhen(s,   i,n,c,two,expect,depth) {
      i=1; n=length(s); expect=1; depth=0
      while (i<=n) {
        c=substr(s,i,1)
        if (c==" " || c=="\t") { i++; continue }
        if (expect) {
          if (c=="!") { i++; continue }
          if (c=="(") { depth++; i++; continue }
          if (c ~ /[A-Za-z0-9_.\/]/) {
            i++
            while (i<=n && substr(s,i,1) ~ /[A-Za-z0-9_.\/-]/) i++
            expect=0
            continue
          }
          return 0
        }
        two=substr(s,i,2)
        if (two=="&&" || two=="||") { expect=1; i+=2; continue }
        if (c==")") {
          if (depth==0) return 0
          depth--; i++; continue
        }
        return 0
      }
      return (!expect && depth==0)
    }
    # normalize line endings (CRLF / stray CR) before structural checks —
    # mirrors the node engine and the python original'"'"'s \s* tolerance
    { line=$0; sub(/\r$/, "", line); L[NR]=line }
    END{
      i=1
      while (i<=NR && L[i] ~ /^[ \t]*$/) i++
      if (i>NR || L[i] !~ /^[ \t]*---[ \t]*$/) { print "BLOCK|no-frontmatter"; exit }
      i++
      closed=0; w=0; o=0; wi=0; taut=0; onx=""; enf=""
      for (; i<=NR; i++) {
        if (L[i] ~ /^---[ \t]*$/) { closed=1; break }
        if (L[i] ~ /^[ \t]*when:[ \t]*[^ \t]/) {
          w=1; wx=L[i]; sub(/^[ \t]*when:[ \t]*/, "", wx)
          if (!validwhen(wx)) wi=1
          # a pure OR-chain containing `always` is a tautology; && / ! make it
          # conditional and it is left alone
          if (wx !~ /[&!]/ && wx ~ /(^|[^A-Za-z0-9_.\/-])always([^A-Za-z0-9_.\/-]|$)/) taut=1
        }
        if (L[i] ~ /^[ \t]*on:[ \t]*[^ \t]/) { o=1; onx=L[i] }
        if (L[i] ~ /^[ \t]*enforcement:[ \t]*[^ \t]/) {
          enf=L[i]; sub(/^[ \t]*enforcement:[ \t]*/, "", enf)
          gsub(/["'"'"']/, "", enf); sub(/[ \t].*$/, "", enf); enf=tolower(enf)
        }
      }
      if (!closed) { print "BLOCK|no-frontmatter"; exit }
      m=""
      if (!w) m="when"
      if (!o) m=(m=="" ? "on" : m ",on")
      if (m!="") { print "BLOCK|" m; exit }
      if (wi) { print "BLOCK|invalid-when"; exit }

      if (enf == "hard") {
        # (1) unconditional trigger on a reactive event — see the node engine
        react=""
        split("PreToolUse PostToolUse UserPromptSubmit AssistantIntent", ev, " ")
        for (k=1; k<=4; k++) if (index(onx, ev[k]) > 0) react=react (react=="" ? "" : ", ") ev[k]
        if (taut && react != "") { print "BLOCK|hard-always-reactive|" react; exit }

        # (2) bound the binding text — the same span the injector will quote
        stop="^#+[ \t]*(rationale|rationale and context|background|change history|changelog|history|examples?|references?|related|see also|sources?|provenance|evidence)[ \t]*$"
        bytes=0
        for (i++; i<=NR; i++) {
          probe=tolower(L[i]); sub(/^[ \t]+/, "", probe); sub(/[ \t]+$/, "", probe)
          if (probe ~ stop) break
          bytes += length(L[i]) + 1
        }
        max=ENVIRON["HQ_POLICY_HARD_RULE_MAX_BYTES"]; if (max=="") max=6144
        if (max+0 > 0 && bytes > max+0) { print "BLOCK|hard-too-long|" bytes "|" max; exit }
      }
      print "ALLOW"
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
    case "$reason" in
      hard-always-reactive*)
        events="${reason#hard-always-reactive|}"
        cat >&2 <<MSG
BLOCKED: an enforcement: hard policy pairs an unconditional \`when:\` with a
reactive event (${events}).

\`when: always\` is TRUE for every command, prompt, and message. On a reactive
event the injector ranks that as an event-specific match, so it takes the
session cap slot of a policy that genuinely matched the thing you are doing —
the loose trigger crowds out the precise one.

Pick one:
  when: always          + on: [SessionStart]        # ambient governance rule
  when: <real signal>   + on: [PreToolUse, ...]     # e.g. deploy || publish

Name the word(s) that actually appear when the rule is relevant. See
core/knowledge/public/hq-core/policies-spec.md ("Trigger Expressions").

(Operator override: set HQ_ALLOW_POLICY_NO_TRIGGER=1 in .claude/settings.local.json "env".)
MSG
        exit 2
        ;;
      hard-too-long*)
        rest="${reason#hard-too-long|}"
        cat >&2 <<MSG
BLOCKED: enforcement: hard policy body is ${rest%%|*} bytes; the limit is ${rest##*|}.

A hard policy is injected VERBATIM into the session, so its length is a
recurring context cost for every session it fires in. Keep the binding rule
tight and move the reasoning out of the injected span: everything from the
first \`## Rationale\` / \`## Background\` / \`## Change history\` /
\`## Examples\` / \`## References\` heading onward is NOT counted and NOT
injected, so long-form context belongs there.

If the rule genuinely needs more than that, either split it into separate
policies with distinct triggers, or raise HQ_POLICY_HARD_RULE_MAX_BYTES in
.claude/settings.local.json "env".

(Operator override: set HQ_ALLOW_POLICY_NO_TRIGGER=1 in .claude/settings.local.json "env".)
MSG
        exit 2
        ;;
    esac
    if [ "$reason" = "invalid-when" ]; then
      cat >&2 <<MSG
BLOCKED: policy file has a malformed when: trigger expression.

Use only identifiers joined by the documented boolean grammar:
  when: <identifier>                 # e.g.  always  |  git  |  /deep-plan
  when: <expr> && <expr>             # AND
  when: <expr> || <expr>             # OR
  when: ! <expr>                     # NOT
  when: ( <expr> )                   # grouping
Identifiers may contain letters, digits, _, ., /, and internal -. Quotes,
YAML block scalars, adjacent identifiers without an operator, and other
punctuation are not valid. See core/knowledge/public/hq-core/policies-spec.md
("Trigger Expressions"). Fix the expression, then retry.

(Operator override: set HQ_ALLOW_POLICY_NO_TRIGGER=1 in .claude/settings.local.json "env".)
MSG
      exit 2
    fi
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
