#!/usr/bin/env node
// ontology-garden.mjs — promote signal and entity candidates into a company's
// local ontology and signal stores. Deterministic: no model call, no network.
// Spec: core/knowledge/public/hq-core/ontology-local-spec.md
//
// Usage: node core/scripts/ontology-garden.mjs --company <co> [--hq-root <path>] [--dry-run] [--json]
//
// What it does, in order:
//   1. Entity candidates  -> ontology/entities/{type}/{slug}.md (identity only).
//      Stopword names and a name already held by an entity of another type are
//      rejected to ontology/_rejected/{date}.jsonl.
//   2. Signal candidates  -> signals/{type}/{sha}.md (audience company) or
//      signals/@{key}/{type}/{sha}.md (scoped), plus signals/@{key}/_audience.yaml
//      and signals/_index/{date}.json.
//   3. Facts              -> for each promoted signal, every known entity whose
//      name or alias appears in it gets a line in
//      ontology/facts/@{key}/{type}/{slug}.md (never in the entity file).
//      Company-audience signals bump the entity's signal_count.
//   4. Processed candidates move to _candidates/_done/{date}/; .last-run is
//      bumped only when at least one candidate was processed.
// A second run over the same input changes nothing.
import fs from "node:fs";
import path from "node:path";

const STOPWORDS = new Set([
  "for", "calls", "call", "context", "summary", "reason", "the", "a", "an", "and",
  "or", "this", "that", "it", "we", "they", "you", "i", "notes", "meeting", "update",
  "question", "decision", "risk", "todo", "none", "n/a", "unknown",
]);
const SIGNAL_TYPES = new Set(["action_item", "commitment", "decision", "risk", "question",
  "key_point", "participant_contribution", "summary"]);
const ENTITY_TYPES = new Set(["person", "project", "company", "concept"]);

function parseArgs(argv) {
  const a = { dryRun: false, json: false };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (k === "--company") a.company = argv[++i];
    else if (k === "--hq-root") a.root = argv[++i];
    else if (k === "--dry-run") a.dryRun = true;
    else if (k === "--json") a.json = true;
    else { console.error(`ontology-garden: unknown flag ${k}`); process.exit(2); }
  }
  if (!a.company) { console.error("usage: ontology-garden.mjs --company <co> [--hq-root <p>] [--dry-run] [--json]"); process.exit(2); }
  a.root = a.root || process.env.HQ_ROOT || path.resolve(path.dirname(new URL(import.meta.url).pathname), "../..");
  return a;
}

// Minimal frontmatter reader for the flat key: value shape the writers emit.
function readDoc(file) {
  const text = fs.readFileSync(file, "utf8");
  const m = text.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
  if (!m) return { fm: {}, body: text.trim() };
  const fm = {};
  for (const line of m[1].split("\n")) {
    const mm = line.match(/^([A-Za-z_]+):\s*(.*)$/);
    if (!mm) continue;
    let v = mm[2].trim();
    if (v.startsWith("[") && v.endsWith("]")) v = v.slice(1, -1).split(",").map(s => s.trim().replace(/^["']|["']$/g, "")).filter(Boolean);
    else v = v.replace(/^["']|["']$/g, "");
    fm[mm[1]] = v;
  }
  return { fm, body: m[2].trim() };
}

function writeDoc(file, fm, body, dry) {
  if (dry) return;
  const lines = ["---"];
  for (const [k, v] of Object.entries(fm)) {
    if (v === undefined || v === null || v === "") continue;
    lines.push(`${k}: ${Array.isArray(v) ? `[${v.join(", ")}]` : v}`);
  }
  lines.push("---", body, "");
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.tmp`;
  fs.writeFileSync(tmp, lines.join("\n"));
  fs.renameSync(tmp, file);
}

const slugify = s => s.toLowerCase().normalize("NFKD").replace(/[^\p{L}\p{N}]+/gu, "-").replace(/^-+|-+$/g, "").slice(0, 80);
const today = () => new Date().toISOString().slice(0, 10);
const now = () => new Date().toISOString().replace(/\.\d{3}Z$/, "Z");

function listCandidates(dir) {
  if (!fs.existsSync(dir)) return [];
  const out = [];
  for (const d of fs.readdirSync(dir).sort()) {
    if (d === "_done") continue;
    const full = path.join(dir, d);
    if (!fs.statSync(full).isDirectory()) continue;
    for (const f of fs.readdirSync(full).sort()) if (f.endsWith(".md")) out.push(path.join(full, f));
  }
  return out;
}

function main() {
  const a = parseArgs(process.argv.slice(2));
  const co = path.join(a.root, "companies", a.company);
  if (!fs.existsSync(co)) { console.error(`ontology-garden: no company ${a.company}`); process.exit(2); }
  const ont = path.join(co, "ontology"), sig = path.join(co, "signals");
  const report = { company: a.company, entities_created: 0, entities_updated: 0, signals_promoted: 0,
    facts_written: 0, rejected: 0, candidates_processed: 0, dry_run: a.dryRun };
  const rejected = [];
  const moves = [];

  // Load the current entity index: slug -> {type, file, fm, names[]}
  const entities = new Map();
  const nameIndex = new Map(); // lowercased name/alias -> slug
  const entDir = path.join(ont, "entities");
  if (fs.existsSync(entDir)) for (const t of fs.readdirSync(entDir)) {
    const td = path.join(entDir, t);
    if (!fs.statSync(td).isDirectory()) continue;
    for (const f of fs.readdirSync(td)) {
      if (!f.endsWith(".md")) continue;
      const file = path.join(td, f); const { fm } = readDoc(file);
      const slug = fm.slug || f.replace(/\.md$/, "");
      const names = [fm.canonical_name, ...(Array.isArray(fm.aliases) ? fm.aliases : [])].filter(Boolean);
      entities.set(slug, { type: fm.type || t, file, fm, names });
      for (const n of names) nameIndex.set(n.toLowerCase(), slug);
    }
  }

  // 1. Entity candidates
  for (const file of listCandidates(path.join(ont, "_candidates"))) {
    const { fm, body } = readDoc(file);
    const name = body.split("\n")[0].trim();
    const type = fm.type;
    const reject = reason => { rejected.push({ at: now(), name, type, reason, candidate: path.relative(co, file) }); report.rejected++; };
    if (!ENTITY_TYPES.has(type)) reject("unknown-type");
    else if (!name || STOPWORDS.has(name.toLowerCase()) || name.length < 2) reject("stopword");
    else {
      const slug = slugify(name);
      const held = nameIndex.get(name.toLowerCase());
      const existing = entities.get(held || slug);
      if (existing && existing.type !== type) reject(`type-conflict:${existing.type}`);
      else if (existing) {
        const aliases = new Set(Array.isArray(existing.fm.aliases) ? existing.fm.aliases : []);
        if (name !== existing.fm.canonical_name && !aliases.has(name)) {
          aliases.add(name); existing.fm.aliases = [...aliases]; existing.fm.last_updated = now();
          writeDoc(existing.file, existing.fm, "", a.dryRun); report.entities_updated++;
          nameIndex.set(name.toLowerCase(), held || slug);
        }
      } else {
        const efile = path.join(ont, "entities", type, `${slug}.md`);
        const efm = { type, canonical_name: name, slug, aliases: [], signal_count: 0,
          first_seen: fm.created_at || now(), last_updated: now(), enriched_by: "ontology-worker" };
        writeDoc(efile, efm, "", a.dryRun);
        entities.set(slug, { type, file: efile, fm: efm, names: [name] });
        nameIndex.set(name.toLowerCase(), slug);
        report.entities_created++;
      }
    }
    moves.push(file); report.candidates_processed++;
  }

  // 2 + 3. Signal candidates -> signals + facts
  const index = [];
  for (const file of listCandidates(path.join(sig, "_candidates"))) {
    const { fm, body } = readDoc(file);
    const type = fm.type; const key = fm.audience_key;
    moves.push(file); report.candidates_processed++;
    if (!SIGNAL_TYPES.has(type) || !key || !body) {
      rejected.push({ at: now(), type, reason: !key ? "missing-audience" : "invalid", candidate: path.relative(co, file) }); report.rejected++;
      continue;
    }
    if (key !== "company" && !(Array.isArray(fm.audience) && fm.audience.length)) {
      rejected.push({ at: now(), type, reason: "scoped-without-principals", candidate: path.relative(co, file) }); report.rejected++;
      continue;
    }
    const id = path.basename(file, ".md");
    const scopeDir = key === "company" ? sig : path.join(sig, `@${key}`);
    const out = path.join(scopeDir, type, `${id}.md`);
    if (!fs.existsSync(out)) {
      writeDoc(out, { signal_id: id, type, canonical_content: JSON.stringify(body.split("\n")[0]), audience_key: key,
        source_ref: JSON.stringify(fm.source_ref || ""), created_at: fm.created_at || now() }, body, a.dryRun);
      report.signals_promoted++;
      index.push({ signal_id: id, type, audience_key: key, path: path.relative(co, out) });
      if (key !== "company") {
        const audFile = path.join(scopeDir, "_audience.yaml");
        if (!fs.existsSync(audFile) && !a.dryRun) {
          fs.mkdirSync(scopeDir, { recursive: true });
          fs.writeFileSync(audFile, `audience_key: ${key}\nprincipals: [${fm.audience.join(", ")}]\n`);
        }
      }
      // Facts: every known entity named in the signal.
      const lower = body.toLowerCase();
      const hit = new Set();
      for (const [n, slug] of nameIndex) {
        if (n.length < 3) continue;
        const re = new RegExp(`(^|[^\\p{L}\\p{N}])${n.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}($|[^\\p{L}\\p{N}])`, "u");
        if (re.test(lower)) hit.add(slug);
      }
      for (const slug of hit) {
        const e = entities.get(slug);
        const ffile = path.join(ont, "facts", `@${key}`, e.type, `${slug}.md`);
        const line = `- [${type}] ${body.split("\n")[0]} (signal ${id.slice(0, 12)})`;
        const prev = fs.existsSync(ffile) ? readDoc(ffile) : { fm: { entity: slug, type: e.type, audience_key: key }, body: "" };
        if (!prev.body.includes(`signal ${id.slice(0, 12)}`)) {
          writeDoc(ffile, prev.fm, [prev.body, line].filter(Boolean).join("\n"), a.dryRun);
          report.facts_written++;
        }
        if (key === "company") {
          e.fm.signal_count = String((parseInt(e.fm.signal_count || "0", 10) || 0) + 1);
          e.fm.last_updated = now();
          writeDoc(e.file, e.fm, "", a.dryRun);
        }
      }
    }
  }

  if (!a.dryRun) {
    if (index.length) {
      const f = path.join(sig, "_index", `${today()}.json`);
      const prev = fs.existsSync(f) ? JSON.parse(fs.readFileSync(f, "utf8")) : [];
      fs.mkdirSync(path.dirname(f), { recursive: true });
      fs.writeFileSync(f, JSON.stringify([...prev, ...index], null, 2) + "\n");
    }
    if (rejected.length) {
      const f = path.join(ont, "_rejected", `${today()}.jsonl`);
      fs.mkdirSync(path.dirname(f), { recursive: true });
      fs.appendFileSync(f, rejected.map(r => JSON.stringify(r)).join("\n") + "\n");
    }
    for (const file of moves) {
      const rel = path.relative(path.dirname(path.dirname(file)), file); // {date}/{sha}.md
      const dest = path.join(path.dirname(path.dirname(file)), "_done", rel);
      fs.mkdirSync(path.dirname(dest), { recursive: true });
      fs.renameSync(file, dest);
    }
    if (report.candidates_processed > 0) {
      fs.mkdirSync(ont, { recursive: true });
      fs.writeFileSync(path.join(ont, ".last-run"), `${Date.now()}\n`);
    }
  }
  if (a.json) console.log(JSON.stringify(report));
  else console.log(`garden ${a.company}: +${report.entities_created} entities, ~${report.entities_updated} updated, +${report.signals_promoted} signals, +${report.facts_written} facts, ${report.rejected} rejected, ${report.candidates_processed} candidates${a.dryRun ? " (dry run)" : ""}`);
}

main();
