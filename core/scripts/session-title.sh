#!/usr/bin/env bash
# session-title.sh — compute an HQ session-title string for the Claude Code
# sidebar ("Recents") / terminal tab title / `/resume` picker.
#
# Pure compute: reads existing session + orchestrator state and prints ONE
# title line to stdout. It does NOT emit hook JSON — the SessionStart /
# UserPromptSubmit wrapper (.claude/hooks/session-title.sh) wraps this output
# in the hookSpecificOutput.sessionTitle envelope.
#
# Title convention:  {icon} {CATEGORY} · {subject} · {phase}
#   - emoji is a STATUS flag only (▶️ running, ✅ recently completed); it is
#     omitted otherwise — the command word already conveys the mode.
#   - company  : slug from the active project path, or "hq-core" for builder
#                work, or the sole company on a single-company HQ; else dropped.
#   - project  : active project slug; dropped when there is no project.
#   - command  : active slash command / mode word (e.g. brainstorm, plan,
#                run-project), defaulting to "chat".
#
# Usage: session-title.sh --session-id <id> [--command <word>]
set -uo pipefail

# core/scripts/ -> ../.. is the HQ root. It was "/.." (i.e. core/), which
# silently resolved every lookup against the wrong tree whenever
# CLAUDE_PROJECT_DIR was unset, yielding a projectless title.
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"

SESSION_ID="default"
COMMAND=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session-id) SESSION_ID="${2:-default}"; shift 2 ;;
    --command)    COMMAND="${2:-}"; shift 2 ;;
    *)            shift ;;
  esac
done

command -v node >/dev/null 2>&1 || exit 0

HQ_ROOT="$HQ_ROOT" SESSION_ID="$SESSION_ID" CMD="$COMMAND" node - <<'JS'
const fs = require("fs");
const path = require("path");

const hq = process.env.HQ_ROOT || "";
const sid = process.env.SESSION_ID || "default";
let command = (process.env.CMD || "").trim().replace(/^\/+/, "");

const key = sid.replace(/[^A-Za-z0-9._-]/g, "_") || "default";
const state = path.join(hq, ".claude", "state");

const firstLine = (p) => {
  try {
    for (let line of fs.readFileSync(p, "utf8").split(/\r?\n/)) {
      line = line.trim();
      if (line) return line;
    }
  } catch (e) {}
  return "";
};

// --- resolve active project path (session-scoped, then global fallback) ---
// Session-scoped ONLY. There used to be a fallback to the machine-global
// .claude/state/active-session-project here; it made every session without its
// own entry inherit whatever project was last active anywhere on the box (142
// unrelated sessions all named "learn-policies-only · chat"). Session-scoped
// state must fail to empty, never to a shared global.
let projPath = firstLine(path.join(state, "auto-session-project-" + key));

let company = "";
let project = "";
if (projPath) {
  let rel = projPath;
  try {
    const resolved = fs.realpathSync(projPath);
    const hqResolved = fs.realpathSync(hq);
    const r = path.relative(hqResolved, resolved);
    if (r === "" || r.startsWith("..") || path.isAbsolute(r)) throw new Error("outside hq");
    rel = r;
  } catch (e) {
    rel = projPath.split(hq.replace(/\/+$/, "") + "/").join("");
  }
  const parts = rel.replace(/\\/g, "/").replace(/^\/+|\/+$/g, "").split("/").filter(Boolean);
  if (parts.length >= 2 && parts[0] === "companies") {
    company = parts[1];
    project = parts[parts.length - 1];
  } else if (parts.length && parts[0] === "personal") {
    company = "";          // personal scope -> no company segment
    project = parts[parts.length - 1];
  } else if (parts.length) {
    project = parts[parts.length - 1];
  }
}

// --- company fallbacks when no project resolved ---
if (!company && command === "hqwork") company = "hq-core";

if (!company && !project) {
  const manifest = path.join(hq, "companies", "manifest.yaml");
  const slugs = [];
  try {
    let inCompanies = false;
    for (const line of fs.readFileSync(manifest, "utf8").split(/\r?\n/)) {
      if (!line.trim() || line.trimStart().startsWith("#")) continue;
      if (inCompanies && /^[^\s#]/.test(line)) break;
      if (/^companies:\s*$/.test(line)) { inCompanies = true; continue; }
      if (inCompanies) {
        const m = line.match(/^  ([a-z][a-z0-9_-]*):\s*$/);
        if (m && m[1] !== "_template") slugs.push(m[1]);
      }
    }
  } catch (e) {}
  if (slugs.length === 1) company = slugs[0];
}

// --- status emoji from the orchestrator ---
let emoji = "";
const orch = path.join(hq, "workspace", "orchestrator", "state.json");
if (project) {
  try {
    const data = JSON.parse(fs.readFileSync(orch, "utf8"));
    for (const p of data.projects || []) {
      const nm = p.name || "";
      const prd = "/" + (p.prdPath || "");
      if (nm === project || prd.includes("/" + project + "/")) {
        const st = p.state || "";
        if (st === "IN_PROGRESS") {
          emoji = "▶️";
        } else if (st === "COMPLETED") {
          const ts = p.updatedAt || p.updated_at || "";
          const t = new Date(ts);
          if (!isNaN(t.getTime()) && (Date.now() - t.getTime()) / 1000 < 86400) {
            emoji = "✅";   // only recent completions
          }
        }
        break;
      }
    }
  } catch (e) {}
}

// --- domain category ---
// First match wins. Keyed on the project slug, then the command word, then the
// company. Produces the "EMOJI CAT" lead-in of the HQ title grammar; see
// personal/policies/hq-session-title-grammar.md.
const CATEGORIES = [
  [/(secur|(^|[-_])sec([-_]|$)|auth|acl|vault|secret|credential|risk|permission)/, "🔒", "SEC"],
  [/(legal|contract|dispute|agreement|licen[cs]e|terms)/,                          "⚖️", "LEGAL"],
  [/(deploy|infra|migration|migrate|ops|pipeline|(^|[-_])ci([-_]|$)|release|sync)/, "⚙️", "OPS"],
  [/(bug|fix|debug|diagnose|repair|heal|incident|regression)/,                     "🔧", "FIX"],
  [/(design|brand|visual|(^|[-_])ui([-_]|$)|(^|[-_])ux([-_]|$)|animation)/,        "🎨", "DESIGN"],
  [/(doc|knowledge|policy|policies|learn|garden|charter|guide)/,                   "📚", "DOCS"],
  [/(test|benchmark|eval|(^|[-_])qa([-_]|$)|smoke|verify)/,                        "🧪", "TEST"],
  [/(data|report|analytic|metric|dashboard|signal)/,                               "📊", "DATA"],
  [/(plan|prd|brainstorm|strategy|roadmap|scope)/,                                 "🗺️", "PLAN"],
  [/(agent|worker|fleet|orchestrat|mesh)/,                                         "🤖", "FLEET"],
];

const classify = (text) => {
  for (const [re, ic, label] of CATEGORIES) if (re.test(text)) return [ic, label];
  return null;
};

if (!command) command = "chat";

let icon = "";
let category = "";
const hit = classify(project.toLowerCase()) ||
            classify(command.toLowerCase()) ||
            classify(company.toLowerCase());
if (hit) { icon = hit[0]; category = hit[1]; }
else if (company === "hq-core") { icon = "🏠"; category = "HQ"; }
else if (company === "personal") { icon = "🟦"; category = "ME"; }
else if (company) {
  // Never mid-word-truncate a slug into something like "PERSON": take the
  // first hyphenated token, and only hard-slice if that alone is still long.
  const head = company.split("-")[0].toUpperCase();
  icon = "🟦";
  category = head.length <= 8 ? head : head.slice(0, 6);
}
else { icon = "🟦"; category = "WORK"; }

// A live status flag outranks the domain icon — "is it running" beats "what
// kind of work is it". Never render both; two emoji read as noise.
const lead = emoji || icon;

// --- compose ---
// Grammar:  {icon} {CAT} · {subject} · {phase}
// The hook can only ever supply a slug as the subject. A session that knows
// what it is actually about should overwrite this with a written subject via
// set_session_title, keeping the same grammar.
const subject = project || company || "";
const core = [category, subject, command].filter(Boolean);
const short = [category, subject || command].filter(Boolean);

const compose = (parts) => lead + " " + parts.join(" · ");

const MAX = 56;
let title = compose(core);
if (title.length > MAX) title = compose(short);
if (title.length > MAX) title = title.slice(0, MAX - 1).replace(/\s+$/, "") + "…";

console.log(title);
JS
