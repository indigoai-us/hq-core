#!/usr/bin/env bash
# session-project.sh - create or reuse a lightweight project folder for native sessions.
#
# This is intentionally thinner than /plan. It gives native Claude/Codex work a
# durable project/prd.json target without forcing a full interview flow.

set -uo pipefail

HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
SESSION_PROJECT_STDIN_INPUT=""
if [ "${1:-}" = "ingest-plan" ]; then
  SESSION_PROJECT_STDIN_INPUT="$(cat 2>/dev/null || true)"
fi
export SESSION_PROJECT_STDIN_INPUT

command -v node >/dev/null 2>&1 || { echo "session-project: node is required" >&2; exit 1; }

node - "$HQ_ROOT" "$@" <<'JS'
const fs = require("fs");
const path = require("path");

const HQ_ROOT = fs.realpathSync(process.argv[2]);
const ARGS = process.argv.slice(3);

const STOPWORDS = new Set([
  "about", "after", "again", "almost", "always", "and", "any", "are",
  "basically", "before", "being", "can", "claude", "codex", "create",
  "created", "creating", "default", "does", "doing", "done", "for",
  "from", "have", "how", "into", "mode", "native", "ones", "plan",
  "project", "projects", "session", "sessions", "should", "that",
  "the", "this", "update", "updated", "when", "with", "work", "would",
]);

const pad = (x) => String(x).padStart(2, "0");
function nowIso() {
  const d = new Date();
  return d.getUTCFullYear() + "-" + pad(d.getUTCMonth() + 1) + "-" + pad(d.getUTCDate()) +
    "T" + pad(d.getUTCHours()) + ":" + pad(d.getUTCMinutes()) + ":" + pad(d.getUTCSeconds()) + "Z";
}
function today() {
  const d = new Date();
  return d.getUTCFullYear() + "-" + pad(d.getUTCMonth() + 1) + "-" + pad(d.getUTCDate());
}

function slugify(value) {
  value = (value || "native-session").toLowerCase();
  value = value.replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
  value = value.replace(/-+/g, "-");
  value = (value || "native-session").slice(0, 60).replace(/^-+|-+$/g, "");
  return value || "native-session";
}

// Filler words that should never anchor a project name — approvals,
// pleasantries, pronouns, and instruction scaffolding. Distinct from STOPWORDS
// (which tunes reuse-matching); this set tunes the human-facing slug.
const SLUG_FILLER = new Set([
  "ok", "okay", "yes", "yep", "yeah", "ya", "sure", "cool", "nice", "great",
  "good", "perfect", "thanks", "thank", "you", "your", "please", "pls", "go",
  "ahead", "for", "it", "do", "did", "that", "this", "now", "lets", "let",
  "us", "proceed", "continue", "just", "still", "also", "and", "then", "the",
  "a", "an", "to", "with", "up", "on", "in", "of", "both", "all", "sounds",
  "lgtm", "fine", "right", "exactly", "agreed", "next", "keep", "again",
  "more", "im", "i", "we", "should", "can", "could", "would", "want", "need",
  "me", "my", "our", "help", "make", "get", "got", "have", "is", "are", "be",
  "out", "here", "there", "some", "any", "as", "at", "by", "or", "but", "so",
  "from", "into", "about", "kindly", "gonna", "wanna", "like",
]);

// Build a clean, meaningful project slug: drop filler, keep the first few
// content words. Date-stamp as a last resort so a name is always produced.
function topicSlug(text, maxWords = 5) {
  const toks = ((text || "").toLowerCase().match(/[a-z0-9][a-z0-9-]*/g)) || [];
  const content = toks.filter((t) => !SLUG_FILLER.has(t) && !/^[0-9]+$/.test(t) && t.length > 1);
  if (!content.length) return "session-" + today();
  return slugify(content.slice(0, maxWords).join("-"));
}

function words(value) {
  const found = ((value || "").toLowerCase().match(/[a-z0-9][a-z0-9-]{2,}/g)) || [];
  const out = new Set();
  for (const w of found) if (!STOPWORDS.has(w)) out.add(w);
  return out;
}

function readJson(p) {
  try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch (e) { return null; }
}

function writeJson(p, data) {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, JSON.stringify(data, null, 2) + "\n");
}

const relToRoot = (p) => path.relative(HQ_ROOT, p).replace(/\\/g, "/");

function projectBase(scope, company) {
  if (scope === "company" && company) return path.join(HQ_ROOT, "companies", company, "projects");
  return path.join(HQ_ROOT, "personal", "projects");
}

// Company isolation: when a company is explicit, only reuse that company's
// projects. Otherwise use personal/HQ projects as the neutral home.
const candidateBases = (scope, company) => [projectBase(scope, company)];

function projectText(prd, prdPath) {
  const metadata = (prd && typeof prd.metadata === "object" && prd.metadata) || {};
  const stories = Array.isArray(prd.userStories) ? prd.userStories : [];
  const storyText = stories.slice(0, 5)
    .filter((s) => s && typeof s === "object")
    .map((s) => (s.id || "") + " " + (s.title || "") + " " + (s.description || ""))
    .join(" ");
  return [
    String(prd.name || ""),
    String(prd.description || ""),
    String(metadata.goal || ""),
    path.basename(path.dirname(prdPath)),
    storyText,
  ].join(" ");
}

function findCandidates(scope, company, query, limit = 5) {
  const queryWords = words(query);
  if (!queryWords.size) return [];

  const candidates = [];
  for (const base of candidateBases(scope, company)) {
    let children;
    try { children = fs.readdirSync(base).sort(); } catch (e) { continue; }
    for (const name of children) {
      const child = path.join(base, name);
      const prdPath = path.join(child, "prd.json");
      let stat;
      try { stat = fs.statSync(prdPath); } catch (e) { continue; }
      if (!stat.isFile()) continue;
      const prd = readJson(prdPath);
      if (!prd || typeof prd !== "object" || Array.isArray(prd)) continue;
      const hayWords = words(projectText(prd, prdPath));
      const overlap = [...queryWords].filter((w) => hayWords.has(w)).sort();
      const slugHits = [...queryWords].filter((w) => name.toLowerCase().includes(w));
      const score = overlap.length + slugHits.length;
      if (score === 0) continue;
      candidates.push({
        path: relToRoot(prdPath),
        projectDir: relToRoot(child),
        name: prd.name || name,
        score: score,
        overlap: overlap.slice(0, 12),
      });
    }
  }

  candidates.sort((a, b) => (b.score - a.score) || (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  return candidates.slice(0, limit);
}

function loadOrCreatePrd(projectDir, title, scope, company, prompt, origin, repoPath) {
  const prdPath = path.join(projectDir, "prd.json");
  if (fs.existsSync(prdPath)) {
    const prd = readJson(prdPath);
    return (prd && typeof prd === "object" && !Array.isArray(prd)) ? prd : {};
  }

  const slug = path.basename(projectDir);
  const description = prompt || title;
  return {
    name: slug,
    description: description,
    branchName: "main",
    metadata: {
      origin: "native-session",
      scope: scope,
      company: company || "personal",
      createdAt: nowIso(),
      goal: title,
      repoPath: repoPath,
      status: "active",
      executionMode: "native",
      source: origin,
      nativeSessions: [],
      nativePlans: [],
    },
    userStories: [
      {
        id: "US-001",
        title: title,
        description: description,
        acceptanceCriteria: [],
        e2eTests: [],
        priority: 1,
        passes: false,
        files: [],
        labels: ["native-session"],
        dependsOn: [],
        notes: "Created automatically from a native Claude/Codex session. Enrich with /prd or /plan if this becomes a structured project.",
        model_hint: "",
      },
    ],
  };
}

function appendSession(prd, sessionId, prompt, reused) {
  const metadata = prd.metadata || (prd.metadata = {});
  const sessions = metadata.nativeSessions || (metadata.nativeSessions = []);
  const entry = {
    ts: nowIso(),
    sessionId: sessionId || "unknown",
    prompt: (prompt || "").slice(0, 1000),
    reused: Boolean(reused),
  };
  const last = sessions[sessions.length - 1];
  if (!sessions.length || JSON.stringify(last) !== JSON.stringify(entry)) sessions.push(entry);
  metadata.updatedAt = entry.ts;
}

function writeReadme(projectDir, prd) {
  const readme = path.join(projectDir, "README.md");
  if (fs.existsSync(readme)) return;
  const name = prd.name || path.basename(projectDir);
  const description = prd.description || "";
  fs.writeFileSync(readme,
    "# " + name + "\n\n" +
    description + "\n\n" +
    "## Status\n\n" +
    "Native session project. This folder was created automatically so work " +
    "done outside `/plan` and `/run-project` still has a durable home.\n\n" +
    "## Next\n\n" +
    "- Enrich `prd.json` if this becomes structured execution work.\n" +
    "- Keep session notes in `journal/` or `sessions/`.\n");
}

function setActivePointer(projectDir) {
  const state = path.join(HQ_ROOT, ".claude", "state");
  fs.mkdirSync(state, { recursive: true });
  fs.writeFileSync(path.join(state, "active-session-project"), String(projectDir) + "\n");
}

function readActivePointer(pointer) {
  let raw;
  try { raw = fs.readFileSync(pointer, "utf8"); } catch (e) { return null; }

  // This pointer is a one-line project directory, not arbitrary file content.
  // In particular, never reinterpret merge conflict markers as directory names.
  const match = raw.match(/^([^\r\n]+)(?:\r?\n)?$/);
  if (!match || /<<<<<<<|=======|>>>>>>>/.test(match[1])) return null;

  const projectDir = path.resolve(HQ_ROOT, match[1]);
  const rel = path.relative(HQ_ROOT, projectDir);
  const parts = rel.split(path.sep).filter(Boolean);
  const isPersonalProject = parts.length >= 3 && parts[0] === "personal" && parts[1] === "projects";
  const isCompanyProject = parts.length >= 4 && parts[0] === "companies" && parts[2] === "projects";
  if (rel === "" || rel === ".." || rel.startsWith(".." + path.sep) || path.isAbsolute(rel) ||
      (!isPersonalProject && !isCompanyProject)) return null;

  return projectDir;
}

function ensureProject(args) {
  const query = [args.title || "", args.prompt || ""].join(" ").trim();
  let reuse = null;
  if (!args.force_new) {
    const candidates = findCandidates(args.scope, args.company, query, 3);
    if (candidates.length && candidates[0].score >= args.reuse_threshold) reuse = candidates[0];
  }

  let projectDir, reused;
  if (reuse) {
    projectDir = path.join(HQ_ROOT, reuse.projectDir);
    reused = true;
  } else {
    const base = projectBase(args.scope, args.company);
    const slug = args.slug ? slugify(args.slug) : topicSlug(args.title || args.prompt);
    projectDir = path.join(base, slug);
    let suffix = 2;
    while (fs.existsSync(projectDir) && !fs.existsSync(path.join(projectDir, "prd.json"))) {
      projectDir = path.join(base, slug + "-" + suffix);
      suffix += 1;
    }
    reused = false;
  }

  fs.mkdirSync(projectDir, { recursive: true });
  fs.mkdirSync(path.join(projectDir, "journal"), { recursive: true });
  fs.mkdirSync(path.join(projectDir, "sessions"), { recursive: true });

  const prd = loadOrCreatePrd(projectDir, args.title, args.scope, args.company,
    args.prompt, args.origin, args.repo_path);
  appendSession(prd, args.session_id, args.prompt, reused);
  writeJson(path.join(projectDir, "prd.json"), prd);
  writeReadme(projectDir, prd);
  setActivePointer(projectDir);

  const stamp = nowIso().split(":").join("").split("-").join("");
  const sessionFile = path.join(projectDir, "sessions", stamp + "-" + (args.session_id || "session") + ".json");
  writeJson(sessionFile, {
    ts: nowIso(),
    kind: "native-session-start",
    prompt: args.prompt,
    reused: reused,
    projectDir: relToRoot(projectDir),
  });

  console.log(JSON.stringify({
    projectDir: relToRoot(projectDir),
    prdPath: relToRoot(path.join(projectDir, "prd.json")),
    reused: reused,
    match: reuse,
  }, null, 2));
}

function resolveProjectDir(project, requiredMsg) {
  const pointer = path.join(HQ_ROOT, ".claude", "state", "active-session-project");
  let projectDir;
  if (project) {
    projectDir = path.join(HQ_ROOT, project);
  } else if (fs.existsSync(pointer)) {
    projectDir = readActivePointer(pointer);
    if (!projectDir) {
      process.stderr.write("session-project: invalid active project pointer\n");
      process.exit(2);
    }
  } else if (requiredMsg) {
    process.stderr.write(requiredMsg + "\n");
    process.exit(1);
  } else {
    process.exit(0);
  }
  if (!path.isAbsolute(projectDir)) projectDir = path.join(HQ_ROOT, projectDir);
  return projectDir;
}

function ingestPlan(args) {
  const projectDir = resolveProjectDir(args.project, "session-project: no active project; run ensure first");
  const prdPath = path.join(projectDir, "prd.json");
  const prd = readJson(prdPath) || {};

  let body;
  if (args.plan_file) body = fs.readFileSync(args.plan_file, "utf8");
  else body = process.env.SESSION_PROJECT_STDIN_INPUT || "";
  body = body.trim();
  if (!body) process.exit(0);

  const plansDir = path.join(projectDir, "sessions");
  fs.mkdirSync(plansDir, { recursive: true });
  const stamp = nowIso().split(":").join("").split("-").join("");
  const planPath = path.join(plansDir, stamp + "-native-plan.md");
  fs.writeFileSync(planPath, body + "\n");

  const metadata = prd.metadata || (prd.metadata = {});
  const nativePlans = metadata.nativePlans || (metadata.nativePlans = []);
  nativePlans.push({
    ts: nowIso(),
    path: relToRoot(planPath),
    summary: body.slice(0, 500),
    source: args.source,
  });
  metadata.updatedAt = nowIso();
  writeJson(prdPath, prd);
  console.log(relToRoot(planPath));
}

function appendEvent(args) {
  const projectDir = resolveProjectDir(args.project, "");
  const prdPath = path.join(projectDir, "prd.json");
  const prd = readJson(prdPath) || {};
  const metadata = prd.metadata || (prd.metadata = {});
  const events = metadata.nativeEvents || (metadata.nativeEvents = []);
  events.push({ ts: nowIso(), kind: args.kind, summary: args.summary });
  metadata.updatedAt = nowIso();
  writeJson(prdPath, prd);
  console.log(relToRoot(prdPath));
}

// --- minimal argparse ---
function die(msg) { process.stderr.write("session-project.sh: " + msg + "\n"); process.exit(2); }

const cmd = ARGS[0];
const flags = {};
for (let i = 1; i < ARGS.length; i++) {
  const a = ARGS[i];
  if (a === "--force-new") { flags.force_new = true; continue; }
  if (a.startsWith("--")) {
    flags[a.slice(2).replace(/-/g, "_")] = ARGS[i + 1] !== undefined ? ARGS[++i] : "";
    continue;
  }
}

const defaults = {
  scope: "personal", company: "", title: "", prompt: "", slug: "",
  repo_path: "", session_id: "", origin: "native-session",
  reuse_threshold: 2, force_new: false, query: "", limit: 5,
  project: "", plan_file: "", source: "native-plan", kind: "", summary: "",
};
const args = Object.assign({}, defaults, flags);
args.reuse_threshold = parseInt(args.reuse_threshold, 10) || 2;
args.limit = parseInt(args.limit, 10) || 5;

if (cmd === "find") {
  if (!args.query) die("find requires --query");
  console.log(JSON.stringify(findCandidates(args.scope, args.company, args.query, args.limit), null, 2));
} else if (cmd === "ensure") {
  if (!args.title) die("ensure requires --title");
  ensureProject(args);
} else if (cmd === "ingest-plan") {
  ingestPlan(args);
} else if (cmd === "append-event") {
  if (!args.kind || !args.summary) die("append-event requires --kind and --summary");
  appendEvent(args);
} else {
  die("unknown or missing subcommand (find | ensure | ingest-plan | append-event)");
}
JS
