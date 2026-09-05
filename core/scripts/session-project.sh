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

// Words that must never, on their own, make two pieces of work "the same
// project". The original list held 48 entries and omitted the vocabulary that
// actually recurs in engineering prompts, so slugs built from ordinary
// instructions ("not-ask-changes-pr-revert", "many-folders-root-hq-not")
// became attractors that swallowed hundreds of unrelated sessions.
const STOPWORDS = new Set([
  "about", "after", "again", "almost", "always", "and", "any", "are",
  "basically", "before", "being", "can", "claude", "codex", "create",
  "created", "creating", "default", "does", "doing", "done", "for",
  "from", "have", "how", "into", "mode", "native", "ones", "plan",
  "project", "projects", "session", "sessions", "should", "that",
  "the", "this", "update", "updated", "when", "with", "work", "would",
  // Instruction scaffolding and generic engineering verbs/nouns. These carry
  // no signal about *which* piece of work a session belongs to.
  "actually", "add", "added", "adding", "all", "also", "back", "but",
  "change", "changed", "changes", "check", "checked", "checking", "could",
  "current", "currently", "error", "errors", "failed", "failing", "file",
  "files", "find", "fix", "fixed", "fixes", "fixing", "get", "got", "here",
  "issue", "issues", "just", "keep", "let", "lets", "like", "look", "looking",
  "looks", "made", "make", "makes", "making", "more", "need", "needs", "new",
  "not", "now", "old", "only", "our", "out", "over", "please", "put", "report",
  "reports", "root", "run", "running", "runs", "same", "see", "some", "still",
  "sure", "take", "test", "tested", "testing", "tests", "than", "them", "then",
  "there", "they", "thing", "things", "try", "trying", "use", "used", "using",
  "very", "want", "wants", "was", "way", "were", "what", "where", "which",
  "who", "why", "will", "your",
]);

// A project that has already absorbed this many sessions is an attractor, not
// a match. Past this point only a strong slug match may add to it.
const MAX_REUSE_SESSIONS = 25;
// Fraction of a project's own slug words the query must cover to override the
// saturation breaker above.
const STRONG_SLUG_COVERAGE = 0.6;

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

// Slug words, split on the hyphen boundary. `words()` keeps hyphens inside a
// token, so a directory name like "a-b-c" is one opaque token to it; matching
// needs the individual words. Deliberately NOT a substring test — the previous
// rule was `name.includes(word)`, which scored "git" against "github" and gave
// long slugs a large accidental match surface.
function slugWords(name) {
  const out = new Set();
  for (const t of (((name || "").toLowerCase().match(/[a-z0-9]+/g)) || [])) {
    if (t.length >= 3 && !STOPWORDS.has(t)) out.add(t);
  }
  return out;
}

// Returns null for an absent file. An unreadable or unparseable file is
// reported and skipped — never silently treated as an empty project, because
// callers that write the result back would then destroy its contents.
function readJson(p) {
  try {
    return JSON.parse(fs.readFileSync(p, "utf8"));
  } catch (e) {
    if (e && e.code === "ENOENT") return null;
    process.stderr.write("session-project: skipping unreadable " + p + ": " +
      (e && e.message ? e.message : String(e)) + "\n");
    return null;
  }
}

// Strict variant for the read-modify-write paths. Absent is fine (null);
// present-but-corrupt is fatal, so a temporarily unreadable prd.json — which
// is exactly what a sync conflict produces — is never overwritten with a stub.
function readJsonForWrite(p) {
  let raw;
  try {
    raw = fs.readFileSync(p, "utf8");
  } catch (e) {
    if (e && e.code === "ENOENT") return null;
    die("cannot read " + p + ": " + (e && e.message ? e.message : String(e)));
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (e) {
    die("refusing to overwrite unparseable " + p + ": " +
      (e && e.message ? e.message : String(e)) +
      " — repair or remove the file, then retry");
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    die("refusing to overwrite " + p + ": expected a JSON object");
  }
  return parsed;
}

function writeJson(p, data) {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, JSON.stringify(data, null, 2) + "\n");
}

const relToRoot = (p) => path.relative(HQ_ROOT, p).replace(/\\/g, "/");

function registeredCompanySlugs() {
  let text;
  try {
    text = fs.readFileSync(path.join(HQ_ROOT, "companies", "manifest.yaml"), "utf8");
  } catch (e) {
    return new Set();
  }
  const slugs = new Set();
  let wrapped = false;
  for (const raw of text.split("\n")) {
    if (/^companies:\s*$/.test(raw)) {
      wrapped = true;
      continue;
    }
    if (wrapped && /^\S/.test(raw)) wrapped = false;
    const m = wrapped
      ? raw.match(/^  ([a-z][a-z0-9_-]*):/)
      : raw.match(/^([a-z][a-z0-9_-]*):/);
    if (!m) continue;
    const slug = m[1];
    if (slug === "_template" || slug === "companies" || slug === "unaffiliated_repos") continue;
    slugs.add(slug);
  }
  return slugs;
}

function projectBase(scope, company) {
  // Never mkdir a ghost tenant. companies/<slug> on disk is not enough —
  // the slug must be in companies/manifest.yaml. Unregistered names fall
  // back to personal so "ok …" cannot create companies/ok.
  if (scope === "company" && company && registeredCompanySlugs().has(company)) {
    return path.join(HQ_ROOT, "companies", company, "projects");
  }
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
      const slugTokens = slugWords(name);
      // Score each distinct query word ONCE. The previous rule summed
      // `overlap.length + slugHits.length` over the same query-word set, and a
      // project's slug is derived from its own originating prompt — which is
      // also stored as its description — so nearly every slug word was counted
      // twice. One shared word scored 2 and cleared the default threshold on
      // its own, which is how ~900 unrelated sessions landed in one project.
      const overlap = [...queryWords].filter((w) => hayWords.has(w) || slugTokens.has(w)).sort();
      const score = overlap.length;
      if (score === 0) continue;

      // Saturation breaker: once a project has absorbed a lot of sessions it
      // is almost certainly an accidental attractor. Keep adding to it only
      // when the query really is about that project, measured as coverage of
      // the project's own slug words rather than raw hit count.
      const sessions = prd.metadata && Array.isArray(prd.metadata.nativeSessions)
        ? prd.metadata.nativeSessions
        : [];
      if (sessions.length > MAX_REUSE_SESSIONS) {
        const slugHits = [...slugTokens].filter((w) => queryWords.has(w)).length;
        const coverage = slugTokens.size ? slugHits / slugTokens.size : 0;
        if (coverage < STRONG_SLUG_COVERAGE) continue;
      }

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
  // A slug collision can land us on a directory that already holds a prd.json.
  // Reuse it if it parses; refuse loudly if it does not. Returning `{}` here
  // used to overwrite a real PRD with a metadata-only stub.
  const existing = readJsonForWrite(prdPath);
  if (existing) return existing;

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

function resolveProjectPath(raw) {
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

function readActivePointer(pointer) {
  let raw;
  try { raw = fs.readFileSync(pointer, "utf8"); } catch (e) { return null; }
  return resolveProjectPath(raw);
}

function allProjectBases() {
  const bases = [path.join(HQ_ROOT, "personal", "projects")];
  const companiesDir = path.join(HQ_ROOT, "companies");
  let companies;
  try { companies = fs.readdirSync(companiesDir).sort(); } catch (e) { return bases; }
  for (const company of companies) {
    const base = path.join(companiesDir, company, "projects");
    try {
      if (fs.statSync(base).isDirectory()) bases.push(base);
    } catch (e) {}
  }
  return bases;
}

function findProjectsBySession(sessionId) {
  if (!sessionId) return [];
  const matches = [];
  for (const base of allProjectBases()) {
    let children;
    try { children = fs.readdirSync(base).sort(); } catch (e) { continue; }
    for (const name of children) {
      const projectDir = path.join(base, name);
      const prd = readJson(path.join(projectDir, "prd.json"));
      if (!prd || typeof prd !== "object" || Array.isArray(prd)) continue;
      const sessions = prd.metadata && Array.isArray(prd.metadata.nativeSessions)
        ? prd.metadata.nativeSessions
        : [];
      if (sessions.some((session) => session && session.sessionId === sessionId)) {
        matches.push({ projectDir: projectDir, prd: prd });
      }
    }
  }
  return matches;
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
    projectDir = resolveProjectPath(project);
    if (!projectDir) {
      process.stderr.write("session-project: invalid project path\n");
      process.exit(2);
    }
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
  // Absent is fine (fresh project); corrupt must not be flattened into a
  // metadata-only stub by the writeJson() below.
  const prd = readJsonForWrite(prdPath) || {};

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
  let projectDir = resolveProjectDir(args.project, "");
  let prdPath = path.join(projectDir, "prd.json");
  // Absent means the project moved and we reconcile by session id. Corrupt
  // means the file is damaged: readJsonForWrite exits rather than letting the
  // event land in some other project and the damage go unnoticed.
  let prd = readJsonForWrite(prdPath);
  if (!prd) {
    const matches = findProjectsBySession(args.session_id);
    if (matches.length !== 1) die("cannot uniquely reconcile project");
    projectDir = matches[0].projectDir;
    prdPath = path.join(projectDir, "prd.json");
    prd = matches[0].prd;
  }
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
  reuse_threshold: 3, force_new: false, query: "", limit: 5,
  project: "", plan_file: "", source: "native-plan", kind: "", summary: "",
};
const args = Object.assign({}, defaults, flags);
args.reuse_threshold = parseInt(args.reuse_threshold, 10) || 3;
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
