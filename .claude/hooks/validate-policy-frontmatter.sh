#!/bin/bash
# validate-policy-frontmatter.sh — PreToolUse (Write, Edit, MultiEdit).
#
# Blocks the create/edit of a POLICY file whose RESULTING frontmatter is missing
# `when:` or `on:`, or whose `when:` is rejected by the canonical boolean
# trigger grammar.
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
# Advisory-safe: FAILS OPEN (exit 0) on ambiguity about whether a write targets
# a policy (non-policy paths, unparsable tool input, or no analyzer engine), so
# it never blocks an unrelated write. Once it has identified a policy with a
# `when:`, it FAILS CLOSED if the canonical evaluator is unavailable: silently
# skipping that dependency would admit malformed hard rules. Engines: node first
# (complex analyzers run on node per the hooks-no-python migration), else a
# jq/awk port of the frontmatter/resulting-text analyzer. Neither port parses
# trigger expressions; core/scripts/eval-trigger.sh owns that grammar.
#
# HQ_ALLOW_POLICY_NO_TRIGGER is an emergency operator override. It requires
# explicit human permission; an agent must never set, export, or write it on
# its own initiative.
#
# Exit codes: 0 = allow, 2 = block.
#
# Wired in .claude/settings.json PreToolUse (Edit/Write/MultiEdit) and gated by
# hook-gate.sh under "validate-policy-frontmatter" (all three profiles).

set -uo pipefail

# --all: batch mode for quality gates. Replays every policy file under
# core/policies, personal/policies, and companies/<co>/policies through this
# same hook as a Write, naming each offending file and field.
# Symlinks in core/policies are personal overlay mirrors and are skipped.
#
# The gate is baseline-aware. Base is $HQ_POLICY_BASELINE_REF, else the merge
# base of HEAD and origin/main. A failing file that is unchanged since base is
# pre-existing and prints as WARN. A failing file that is new or changed prints
# as FAIL. Exit 1 when any FAIL is printed or the failing-file count rises
# over base. With no resolvable base, or with --strict, every failure is FAIL.
if [ "${1:-}" = "--all" ]; then
  ALL_STRICT=0
  [ "${2:-}" = "--strict" ] && ALL_STRICT=1
  ALL_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)}"
  SELF="$ALL_ROOT/.claude/hooks/validate-policy-frontmatter.sh"
  [ -f "$SELF" ] || SELF="${BASH_SOURCE[0]:-$0}"
  command -v jq >/dev/null 2>&1 || { echo "validate-policy-frontmatter --all: jq is required" >&2; exit 2; }

  all_check() {  # $1 path, $2 file holding content -> stdout first error line; rc 0 = valid
    local out
    out="$(jq -n --arg fp "$1" --rawfile c "$2" '{tool_input:{file_path:$fp, content:$c}}' \
      | HQ_ROOT="$ALL_ROOT" HQ_ALLOW_POLICY_NO_TRIGGER= bash "$SELF" 2>&1 >/dev/null)" && return 0
    printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | head -1
    return 1
  }

  BASE=""
  if [ "$ALL_STRICT" -eq 0 ] && git -C "$ALL_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [ -n "${HQ_POLICY_BASELINE_REF:-}" ]; then
      BASE="$(git -C "$ALL_ROOT" rev-parse --verify -q "${HQ_POLICY_BASELINE_REF}^{commit}" 2>/dev/null)"
    elif git -C "$ALL_ROOT" rev-parse --verify -q 'origin/main^{commit}' >/dev/null 2>&1; then
      BASE="$(git -C "$ALL_ROOT" merge-base HEAD origin/main 2>/dev/null)"
    fi
  fi
  PREFIX=""; CHANGED=""
  if [ -n "$BASE" ]; then
    PREFIX="$(git -C "$ALL_ROOT" rev-parse --show-prefix 2>/dev/null)"
    ALL_TMP="$(mktemp -d "${TMPDIR:-/tmp}/vpf-all.XXXXXX")" || ALL_TMP=""
    if [ -n "$ALL_TMP" ]; then
      trap 'rm -rf "$ALL_TMP"' EXIT
      CHANGED="$ALL_TMP/changed"
      # Paths relative to ALL_ROOT that differ from base, including untracked.
      { git -C "$ALL_ROOT" diff --name-only --relative "$BASE" -- core/policies personal/policies 'companies/*/policies' 2>/dev/null
        git -C "$ALL_ROOT" ls-files --others --exclude-standard -- core/policies personal/policies 'companies/*/policies' 2>/dev/null
      } | sort -u > "$CHANGED"
    else
      BASE=""
    fi
  fi

  scanned=0; failed=0; warned=0; base_failed=0
  for f in "$ALL_ROOT"/core/policies/*.md "$ALL_ROOT"/personal/policies/*.md "$ALL_ROOT"/companies/*/policies/*.md; do
    [ -f "$f" ] || continue
    case "$f" in "$ALL_ROOT"/core/policies/*) [ -L "$f" ] && continue ;; esac
    case "$(basename "$f" | tr '[:upper:]' '[:lower:]')" in readme.md) continue ;; esac
    scanned=$((scanned + 1))
    rel="${f#"$ALL_ROOT"/}"
    err="$(all_check "$f" "$f")" && continue
    if [ -n "$BASE" ] && ! grep -Fxq "$rel" "$CHANGED"; then
      warned=$((warned + 1)); base_failed=$((base_failed + 1))
      printf 'WARN %s: %s (pre-existing)\n' "$rel" "$err"
    else
      failed=$((failed + 1))
      printf 'FAIL %s: %s\n' "$rel" "$err"
    fi
  done
  current=$((failed + warned))
  if [ -n "$BASE" ]; then
    # Changed or removed files: count their base copy if it failed too.
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      git -C "$ALL_ROOT" show "$BASE:$PREFIX$rel" > "$ALL_TMP/base.md" 2>/dev/null || continue
      all_check "$ALL_ROOT/$rel" "$ALL_TMP/base.md" >/dev/null || base_failed=$((base_failed + 1))
    done < "$CHANGED"
    printf 'policies validated: %d | failed: %d | pre-existing: %d | baseline failing: %d | current failing: %d\n' \
      "$scanned" "$failed" "$warned" "$base_failed" "$current"
    [ "$failed" -eq 0 ] && [ "$current" -le "$base_failed" ] && exit 0 || exit 1
  fi
  printf 'policies validated: %d | failed: %d\n' "$scanned" "$failed"
  [ "$failed" -eq 0 ] && exit 0 || exit 1
fi

INPUT="$(cat)"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
HOOK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)"
HQ_ROOT="${HQ_ROOT:-$HOOK_ROOT}"
EVAL_TRIGGER="$HQ_ROOT/core/scripts/eval-trigger.sh"
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

// ── Lifecycle and gate fields (policies-spec.md "Lifecycle Fields") ───────
// Optional, but when present they must be well-formed: /garden, the injector,
// policy-retire.sh, and the gate hook all read them as data.
const fmVal = (key) => {
  const r = fm.match(new RegExp("^" + key + ":[ \\t]*(.*)$", "m"));
  return r ? r[1].replace(/[ \t]+#.*$/, "").trim().replace(/^["']|["']$/g, "") : null;
};
const lc = (field, detail) => { console.log("BLOCK|lifecycle|" + field + "|" + detail); process.exit(0); };
const status = fmVal("status");
if (status !== null && !/^(active|retired|superseded)$/.test(status))
  lc("status", "'" + status + "' is not one of active, retired, superseded");
for (const k of ["retired_at", "retired_by", "retired_reason"]) {
  if (fmVal(k) !== null && status !== "retired")
    lc(k, k + " requires status: retired (status is " + (status === null ? "absent" : status) + ")");
}
const lastConfirmed = fmVal("last_confirmed");
if (lastConfirmed !== null && !/^\d{4}-\d{2}-\d{2}([T ][0-9:.]+(Z|[+-]\d{2}:?\d{2})?)?$/.test(lastConfirmed))
  lc("last_confirmed", "'" + lastConfirmed + "' is not an ISO date (YYYY-MM-DD)");
const retireWhenM = fm.match(/^retire_when:[ \t]*(.*)$/m);
const retireWhenRaw = retireWhenM ? retireWhenM[1].replace(/[ \t]+#.*$/, "") : undefined;
if (retireWhenRaw !== undefined && /["'*+?\[\](){}|\\^$]/.test(retireWhenRaw))
  lc("retire_when", "contains a quote or regex metacharacter; write a plain-text condition");
const supersedes = fmVal("supersedes");
if (supersedes !== null) {
  const ids = supersedes.replace(/^\[|\]$/g, "").split(",").map((s) => s.trim().replace(/^["']|["']$/g, "")).filter(Boolean);
  // YAML block list form: supersedes:, then indented "- id" lines
  const supLines = fm.split("\n");
  for (let j = supLines.findIndex((l) => /^supersedes:/.test(l)) + 1; j > 0 && j < supLines.length; j++) {
    const item = supLines[j].match(/^[ \t]+-[ \t]*(.*)$/);
    if (!item) break;
    ids.push(item[1].replace(/[ \t]+#.*$/, "").trim().replace(/^["']|["']$/g, ""));
  }
  const bad = ids.find((id) => !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(id));
  if (bad !== undefined) lc("supersedes", "'" + bad + "' is not a policy id");
}
const enfRaw = fmVal("enforcement");
const fmLines = fm.split("\n");
const gateIdx = fmLines.findIndex((l) => /^gate:[ \t]*(#.*)?$/.test(l));
if ((enfRaw || "").toLowerCase() === "gate" || gateIdx >= 0) {
  if (gateIdx < 0) lc("gate", "enforcement: gate requires a gate: block");
  const gate = {};
  for (const l of fmLines.slice(gateIdx + 1)) {
    if (!/^[ \t]+\S/.test(l)) break;
    const g = l.match(/^[ \t]+([A-Za-z_]+):[ \t]*(.*)$/);
    if (g) gate[g[1]] = g[2].replace(/[ \t]+#.*$/, "").trim().replace(/^["']|["']$/g, "");
  }
  const unknown = Object.keys(gate).find((k) => !["tools", "bash", "requires", "freshness", "override"].includes(k));
  if (unknown) lc("gate." + unknown, "unknown gate field; allowed: tools, bash, requires, freshness, override");
  const empty = (v) => v === undefined || /^\[?[ \t]*\]?$/.test(v);
  if (empty(gate.tools) && empty(gate.bash)) lc("gate.tools", "gate block needs tools or bash (at least one)");
  if (empty(gate.requires)) lc("gate.requires", "gate block needs at least one required fact");
  if (gate.freshness !== undefined && !/^\d+$/.test(gate.freshness)) lc("gate.freshness", "must be whole minutes");
  if (gate.override !== undefined && !/^(allowed|denied)$/.test(gate.override)) lc("gate.override", "must be allowed or denied");
}

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
  const tautological = whenLines.some((w) => {
    const normalized = w.toLowerCase();
    return !/[&!]/.test(normalized) && /(^|[^A-Za-z0-9_./-])always([^A-Za-z0-9_./-]|$)/.test(normalized);
  });
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

// Leave syntax to the canonical batch evaluator below. Emit one record for
// every `when:` so duplicate frontmatter keys do not escape validation.
for (const when of whenLines) console.log("CHECK|" + when);
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
      closed=0; w=0; wc=0; o=0; taut=0; onx=""; enf=""
      for (; i<=NR; i++) {
        if (L[i] ~ /^---[ \t]*$/) { closed=1; break }
        if (L[i] ~ /^[ \t]*when:[ \t]*/) {
          wx=L[i]; sub(/^[ \t]*when:[ \t]*/, "", wx)
          wx=tolower(wx)
          whens[++wc]=wx
          if (wx ~ /[^ \t]/) w=1
          # a pure OR-chain containing `always` is a tautology; && / ! make it
          # conditional and it is left alone
          if (wx !~ /[&!]/ && wx ~ /(^|[^A-Za-z0-9_.\/-])always([^A-Za-z0-9_.\/-]|$)/) taut=1
        }
        if (L[i] ~ /^[ \t]*on:[ \t]*[^ \t]/) { o=1; onx=L[i] }
        if (enf == "" && L[i] ~ /^[ \t]*enforcement:[ \t]*[^ \t]/) {
          enf=L[i]; sub(/^[ \t]*enforcement:[ \t]*/, "", enf)
          gsub(/["'"'"']/, "", enf); sub(/[ \t].*$/, "", enf); enf=tolower(enf)
        }
        # lifecycle and gate fields — mirrors the node engine
        if (L[i] ~ /^[a-z_]+:/) {
          k=L[i]; sub(/:.*$/, "", k); v=L[i]; sub(/^[a-z_]+:[ \t]*/, "", v)
          raw=v; sub(/[ \t]+#.*$/, "", v); gsub(/^[ \t]+|[ \t]+$/, "", v)
          gsub(/^["'"'"']|["'"'"']$/, "", v)
          ingate=(k=="gate")
          # first occurrence wins, matching fm.match in the node engine
          if (!(k in HAS)) { F[k]=v; HAS[k]=1; if (k=="retire_when") { RW=raw; sub(/[ \t]+#.*$/, "", RW) } }
          gr=raw; sub(/[ \t]+$/, "", gr)
          if (k=="gate" && gr !~ /^(#.*)?$/) { ingate=0; delete HAS["gate"] }
          insup=(k=="supersedes")
        } else if (insup && L[i] ~ /^[ \t]+-/) {
          v=L[i]; sub(/^[ \t]+-[ \t]*/, "", v); sub(/[ \t]+#.*$/, "", v); gsub(/[ \t]+$/, "", v)
          SUPB=SUPB "," v
        } else if (ingate && L[i] ~ /^[ \t]+[A-Za-z_]+:/) {
          k=L[i]; sub(/^[ \t]+/, "", k); sub(/:.*$/, "", k)
          v=L[i]; sub(/^[ \t]+[A-Za-z_]+:[ \t]*/, "", v); sub(/[ \t]+#.*$/, "", v); gsub(/[ \t]+$/, "", v)
          gsub(/^["'"'"']|["'"'"']$/, "", v)
          G[k]=v; GH[k]=1
        } else if (L[i] !~ /^[ \t]/) { ingate=0; insup=0 }
      }
      if (!closed) { print "BLOCK|no-frontmatter"; exit }
      m=""
      if (!w) m="when"
      if (!o) m=(m=="" ? "on" : m ",on")
      if (m!="") { print "BLOCK|" m; exit }
      st=F["status"]
      if (HAS["status"] && st !~ /^(active|retired|superseded)$/) { print "BLOCK|lifecycle|status|'"'"'" st "'"'"' is not one of active, retired, superseded"; exit }
      split("retired_at retired_by retired_reason", rk, " ")
      for (k=1; k<=3; k++) if (HAS[rk[k]] && st != "retired") { print "BLOCK|lifecycle|" rk[k] "|" rk[k] " requires status: retired (status is " (HAS["status"] ? st : "absent") ")"; exit }
      if (HAS["last_confirmed"] && F["last_confirmed"] !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]([T ][0-9:.]+(Z|[+-][0-9][0-9]:?[0-9][0-9])?)?$/) { print "BLOCK|lifecycle|last_confirmed|'"'"'" F["last_confirmed"] "'"'"' is not an ISO date (YYYY-MM-DD)"; exit }
      if (HAS["retire_when"] && RW ~ /["'"'"'*+?\[\](){}|\\^$]/) { print "BLOCK|lifecycle|retire_when|contains a quote or regex metacharacter; write a plain-text condition"; exit }
      if (HAS["supersedes"]) {
        sv=F["supersedes"]; gsub(/^\[|\]$/, "", sv); sv=sv SUPB; n=split(sv, ids, ",")
        for (k=1; k<=n; k++) { id=ids[k]; gsub(/^[ \t"'"'"']+|[ \t"'"'"']+$/, "", id)
          if (id != "" && id !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/) { print "BLOCK|lifecycle|supersedes|'"'"'" id "'"'"' is not a policy id"; exit } }
      }
      if (enf == "gate" || HAS["gate"]) {
        if (!HAS["gate"]) { print "BLOCK|lifecycle|gate|enforcement: gate requires a gate: block"; exit }
        for (k in GH) if (k !~ /^(tools|bash|requires|freshness|override)$/) { print "BLOCK|lifecycle|gate." k "|unknown gate field; allowed: tools, bash, requires, freshness, override"; exit }
        te=(!GH["tools"] || G["tools"] ~ /^\[?[ \t]*\]?$/); be=(!GH["bash"] || G["bash"] ~ /^\[?[ \t]*\]?$/)
        if (te && be) { print "BLOCK|lifecycle|gate.tools|gate block needs tools or bash (at least one)"; exit }
        if (!GH["requires"] || G["requires"] ~ /^\[?[ \t]*\]?$/) { print "BLOCK|lifecycle|gate.requires|gate block needs at least one required fact"; exit }
        if (GH["freshness"] && G["freshness"] !~ /^[0-9]+$/) { print "BLOCK|lifecycle|gate.freshness|must be whole minutes"; exit }
        if (GH["override"] && G["override"] !~ /^(allowed|denied)$/) { print "BLOCK|lifecycle|gate.override|must be allowed or denied"; exit }
      }
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
      # Grammar validation belongs solely to eval-trigger.sh. Emit every
      # populated when: line so duplicate keys are checked too.
      for (k=1; k<=wc; k++) print "CHECK|" whens[k]
    }'
}

if [ -n "$NODE" ]; then
  RESULT="$(HQ_HOOK_INPUT="$INPUT" HQ_PROJECT_DIR="$PROJECT_DIR" "$NODE" -e "$JSPROG" 2>/dev/null || echo ALLOW)"
else
  RESULT="$(analyze_with_jq)"
fi

# The evaluator is deliberately checked only after the frontmatter analyzer
# identifies a policy with at least one populated `when:`. A missing evaluator
# must block that policy write: allowing it would recreate the malformed-rule
# bypass this hook exists to prevent. Non-policy writes remain advisory-safe.
override_enabled() {
  [ "${HQ_ALLOW_POLICY_NO_TRIGGER:-}" = "1" ] || [ "${HQ_ALLOW_POLICY_NO_TRIGGER:-}" = "true" ]
}

block_missing_evaluator() {
  # This is an operator-selected emergency override, deliberately as broad as
  # the existing override below: it permits a policy write even when structural
  # checks would otherwise block. Keeping only presence checks in this path
  # would make the same documented override behave differently based on whether
  # the evaluator happened to be executable, and could still prevent a repair
  # write during an evaluator outage. Never make that degradation silent.
  if override_enabled; then
    cat >&2 <<MSG
NOTE: HQ_ALLOW_POLICY_NO_TRIGGER override active. Allowing this policy write
without canonical trigger syntax validation because the evaluator is unavailable:
${EVAL_TRIGGER}
MSG
    exit 0
  fi
  cat >&2 <<MSG
BLOCKED: cannot validate this policy's when: expression because the canonical
trigger evaluator is unavailable.

Checked: ${EVAL_TRIGGER}
Expected: an executable core/scripts/eval-trigger.sh resolved from HQ_ROOT.

This write is blocked fail-closed rather than silently skipping syntax
validation. Restore that executable (or correct HQ_ROOT / CLAUDE_PROJECT_DIR)
and retry; allowing the write would permit rules that can never parse or fire.
MSG
  exit 2
}

case "$RESULT" in
  CHECK\|*)
    [ -x "$EVAL_TRIGGER" ] || block_missing_evaluator

    CHECK_EXPRESSIONS=()
    check_count=0
    while IFS= read -r check_line; do
      case "$check_line" in
        CHECK\|*)
          CHECK_EXPRESSIONS[check_count]="${check_line#CHECK|}"
          check_count=$((check_count + 1))
          ;;
        *)
          # The analyzer's protocol is internal and deterministic. A mixed
          # response after identifying a policy is unsafe to interpret as an
          # allow, so use the same explicit fail-closed diagnostic.
          block_missing_evaluator
          ;;
      esac
    done <<EOF
$RESULT
EOF

    [ "$check_count" -gt 0 ] || block_missing_evaluator
    CHECK_OUTPUT="$({
      check_index=0
      while [ "$check_index" -lt "$check_count" ]; do
        id="when-$check_index"
        when="${CHECK_EXPRESSIONS[check_index]}"
        printf '%s\t%s\n' "$id" "$when"
        check_index=$((check_index + 1))
      done
    } | bash "$EVAL_TRIGGER" --check 2>&1)" || block_missing_evaluator

    check_index=0
    malformed_when_found=0
    bad_when=""
    while IFS=$'\t' read -r checked_id checked_status checked_extra || [ -n "${checked_id:-}${checked_status:-}${checked_extra:-}" ]; do
      [ "$checked_id" = "when-$check_index" ] && [ -z "$checked_extra" ] || block_missing_evaluator
      case "$checked_status" in
        ok) ;;
        malformed)
          malformed_when_found=1
          bad_when="${CHECK_EXPRESSIONS[check_index]}"
          ;;
        *) block_missing_evaluator ;;
      esac
      check_index=$((check_index + 1))
    done <<EOF
$CHECK_OUTPUT
EOF
    [ "$check_index" = "$check_count" ] || block_missing_evaluator
    if [ "$malformed_when_found" = "1" ]; then
      RESULT="BLOCK|invalid-when|$bad_when"
    else
      RESULT="ALLOW"
    fi
    ;;
esac

case "$RESULT" in
  BLOCK*)
    if override_enabled; then
      exit 0
    fi
    reason="${RESULT#BLOCK|}"
    case "$reason" in
      lifecycle\|*)
        rest="${reason#lifecycle|}"
        cat >&2 <<MSG
BLOCKED: invalid policy frontmatter field \`${rest%%|*}\`: ${rest#*|}

Lifecycle fields (status, retired_at, retired_by, retired_reason,
last_confirmed, retire_when, supersedes) and the enforcement: gate block are
optional, but must be well-formed when present. See
core/knowledge/public/hq-core/policies-spec.md ("Lifecycle Fields" and
"Gate Block"). Fix the field, then retry.

(The HQ_ALLOW_POLICY_NO_TRIGGER override requires explicit human permission.
An agent must never set, export, or write it on its own initiative.)
MSG
        exit 2
        ;;
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

(The HQ_ALLOW_POLICY_NO_TRIGGER override requires explicit human permission.
An agent must never set, export, or write it on its own initiative.)
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

(The HQ_ALLOW_POLICY_NO_TRIGGER override requires explicit human permission.
An agent must never set, export, or write it on its own initiative.)
MSG
        exit 2
        ;;
    esac
    if [ "${reason%%|*}" = "invalid-when" ]; then
      when_expression="${reason#invalid-when|}"
      cat >&2 <<MSG
BLOCKED: policy file has a malformed when: trigger expression:

  when: ${when_expression}

The canonical trigger evaluator rejected it. A space is NOT an AND, and quoted
phrases are NOT tokens. Use explicit boolean operators instead:
  "pull request"  -> (pull && request)
  "force-push"    -> force-push

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

(The HQ_ALLOW_POLICY_NO_TRIGGER override requires explicit human permission.
An agent must never set, export, or write it on its own initiative.)
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

(The HQ_ALLOW_POLICY_NO_TRIGGER override requires explicit human permission.
An agent must never set, export, or write it on its own initiative.)
MSG
    exit 2
    ;;
  *)
    exit 0
    ;;
esac
