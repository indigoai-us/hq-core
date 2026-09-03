#!/usr/bin/env bash
# session-title.sh — compute an HQ session-title string for the Claude Code
# sidebar ("Recents") / terminal tab title / `/resume` picker.
#
# Pure compute: reads existing session + orchestrator state and prints ONE
# title line to stdout. It does NOT emit hook JSON — the SessionStart /
# UserPromptSubmit wrapper (.claude/hooks/session-title.sh) wraps this output
# in the hookSpecificOutput.sessionTitle envelope.
#
# Title convention:  {glyph} {COMPANY} · {Product} · {subject}
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
SESSION_CWD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session-id) SESSION_ID="${2:-default}"; shift 2 ;;
    --command)    COMMAND="${2:-}"; shift 2 ;;
    --cwd)        SESSION_CWD="${2:-}"; shift 2 ;;
    *)            shift ;;
  esac
done

command -v node >/dev/null 2>&1 || exit 0

HQ_ROOT="$HQ_ROOT" SESSION_ID="$SESSION_ID" CMD="$COMMAND" SESSION_CWD="$SESSION_CWD" node - <<'JS'
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
    company = "personal";  // rendered as the "ME" org token
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

// --- mode ---
// The emoji encodes what the session IS DOING, not what domain it belongs to.
// State is what a human scans a sidebar for ("does this need me?"); domain is
// already implied by the subject line. Keyed on the active slash command,
// which the wrapper hook already tracks turn to turn.
//
// Exactly ONE glyph, never two — a second glyph beside the first reads as a
// badge pair and makes the left edge busier without making it more scannable.
// The single slot shows the most USEFUL thing about the session right now,
// picked by the precedence ladder in hq-session-title-grammar: work that needs
// the user or has terminated outranks the session kind, which outranks the
// workflow stage, which outranks the craft.
//
// This script only ever emits a stage or kind glyph. It never emits 🙋 (needs
// the user) — it cannot know that — and never a craft glyph, since its only
// subject is a directory slug and any keyword match against that slug is
// redundant with the slug by construction. Both are the model's job.
//
// A handoff has two moments and they are different rows in a sidebar:
// 📝 the handoff is being written (the session is wrapping up) and 📤 it is
// ready (the session is closed; resume from the thread). This script emits 📝
// while /handoff runs; only the model can know when it finished, so it sets 📤.
// Both are distinct from ✅ "the work shipped" and 🤝 "a person owns it now".
const MODES = [
  [/^(brainstorm|idea|dream|discover|strategize)$/,                            "💭"],
  [/^(plan|prd|deep-plan|storyboard|architect|review-plan|codebase-design)$/,  "📐"],
  [/^(run-project|execute-task|ship|land|land-batch|run-pipeline|orchestrate|tdd|deploy)$/, "⚡"],
  [/^(review|code-review|security-review)$/,                                   "👀"],
  [/^(quality-gate|smoke|verify|diagnose|investigate)$/,                       "🧪"],
  [/^(handoff|checkpoint-handoff|retro)$/,                                     "📝"],
  [/^(delegate|new-hire|new-agent|promote)$/,                                  "🤝"],
  [/^(dm|hq-slack|meeting-notes|work-broadcast|signals|hq-share)$/,            "💬"],
  [/^(schedule|job|loop)$/,                                                    "🔁"],
];

const modeFor = (word) => {
  for (const [re, ic] of MODES) if (re.test(word)) return ic;
  return "";
};

if (!command) command = "chat";

// Precedence: a finished or running project outranks the command word — "it
// shipped" and "it is executing right now" beat "you typed /plan an hour ago".
// `emoji` is set above from orchestrator state (✅ recent completion, ▶️ running).
const mode = emoji === "▶️" ? "⚡" : (emoji || modeFor(command));

// --- company ---
// Always the first text token. Long slugs get an explicit short form from the
// settings `aliases:` block rather than a mid-word truncation — a single-word
// slug sliced at 8 characters is unreadable.
// Built-ins only. Company short forms are USER data — a release-shipped file
// must never carry tenant slugs (enforced by the slug-scan / denylist-scan CI
// gates). Users map their own long slugs in personal/settings/session-title.yaml:
//
//   aliases:
//     some-long-company-slug: SHORT
//
const ALIASES = { personal: "ME", "hq-core": "HQ" };

// Merge user aliases from the settings files, lowest precedence first.
const readAliases = (file) => {
  let text = "";
  try { text = fs.readFileSync(file, "utf8"); } catch (e) { return; }
  let inBlock = false;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.replace(/#.*$/, "").replace(/\s+$/, "");
    if (!line.trim()) continue;
    if (/^aliases:\s*$/.test(line)) { inBlock = true; continue; }
    if (!/^\s/.test(line)) { inBlock = false; continue; }   // any new top-level key ends it
    if (!inBlock) continue;
    const m = line.match(/^\s+["']?([A-Za-z0-9._-]+)["']?:\s*["']?([^"'\s]+)["']?\s*$/);
    if (m) ALIASES[m[1]] = m[2];
  }
};
readAliases(path.join(hq, "core", "settings", "session-title.yaml"));
readAliases(path.join(hq, "personal", "settings", "session-title.yaml"));

let org = "";
if (company) {
  org = ALIASES[company];
  if (!org) {
    const head = company.split("-")[0].toUpperCase();
    org = head.length <= 8 ? head : head.slice(0, 8);
  }
}

// --- compose ---
// Grammar:  {glyph} {COMPANY} · {Product} · {subject}
//
// Every rendered glyph must mean something. When the mode is unknown the title
// simply starts with the company — a placeholder icon (the old "🟦") is worse
// than nothing, because it trains the eye to ignore the emoji column.
//
// The hook can only ever put a directory slug in the subject slot. A session
// that knows what it is actually about should overwrite this via
// set_session_title, keeping the same grammar.
// --- product / repo ---
// The repo or product the session is working in, rendered between the company
// and the subject so identity survives a narrow sidebar's truncation. Derived
// from the session cwd when it sits inside repos/; otherwise left to the model.
//
// A leading company prefix is stripped, because the company token already said
// it: repos/public/hq-work under company HQ renders as "Work", not "Hq-work".
let product = "";
const cwd = process.env.SESSION_CWD || "";
if (cwd) {
  const rel = cwd.split(/[\\/]/).filter(Boolean);
  const i = rel.lastIndexOf("repos");
  if (i !== -1 && rel.length > i + 1) {
    // repos/<public|private>/<repo>/... or repos/<repo>/...
    let name = rel[i + 1];
    if ((name === "public" || name === "private") && rel.length > i + 2) name = rel[i + 2];
    if (name) {
      // "hq-work" -> ["HQ", "Work"]. Two-letter tokens are acronyms, not words.
      let words = name.split("-").filter(Boolean).map((w) =>
        w.length <= 2 ? w.toUpperCase() : w.charAt(0).toUpperCase() + w.slice(1)
      );
      // Drop a leading word the company token already said: under company HQ,
      // "hq-work" is "Work", not "HQ Work".
      if (org && words.length > 1 && words[0].toUpperCase() === org.toUpperCase()) {
        words = words.slice(1);
      }
      product = words.join(" ");
    }
  }
}

const subject = project || "";

// --- stub suppression -------------------------------------------------------
// With no project AND no repo/product, every remaining ingredient is
// information-free: a bare command word ("chat", "startwork") or a lone org
// token ("HQ"). Emitting one of those is actively harmful — it is not merely
// useless, it OVERWRITES the host's written summary ("HQ core skill cloning")
// with a word that distinguishes nothing, and because the stub never changes,
// the wrapper's change-only cadence then goes silent for the rest of the
// session. Sessions were sitting on 1281 prompts still titled "chat".
//
// Printing nothing makes the wrapper exit before it emits or records anything,
// so the host's own title stands. The moment a project or repo does resolve,
// the normal path takes the title back.
if (!project && !product) process.exit(0);

const parts = [org, product, subject].filter(Boolean);
if (!parts.length) parts.push(command);

const compose = (ps) => (mode ? mode + " " : "") + ps.join(" · ");

const MAX = 56;
let title = compose(parts);
if (title.length > MAX && parts.length > 1) title = compose([parts[parts.length - 1]]);
if (title.length > MAX) title = title.slice(0, MAX - 1).replace(/\s+$/, "") + "…";

console.log(title);
JS
