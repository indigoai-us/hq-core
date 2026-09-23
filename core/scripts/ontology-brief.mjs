#!/usr/bin/env node
// ontology-brief.mjs — render a company brief from the reader's LOCAL tree.
// Spec: core/knowledge/public/hq-core/ontology-local-spec.md
//
// Usage: node core/scripts/ontology-brief.mjs --company <co> [--hq-root <p>] [--days N] [--top N] [--json]
//
// Reads ontology/entities/, every ontology/facts/@*/ and signals/{type}/ +
// signals/@*/{type}/ present locally. Sync pull only delivers what the reader
// may read, so the brief shows exactly their visible facts and signals.
// Writes nothing. Prints markdown (default) or JSON. Exit 0 with an empty brief
// ("no local ontology") when nothing is there.
import fs from "node:fs";
import path from "node:path";

const TYPES = ["decision", "commitment", "risk", "question", "action_item", "key_point", "participant_contribution", "summary"];
const args = process.argv.slice(2);
const opt = { days: 14, top: 10, json: false };
for (let i = 0; i < args.length; i++) {
  const k = args[i];
  if (k === "--company") opt.company = args[++i];
  else if (k === "--hq-root") opt.root = args[++i];
  else if (k === "--days") opt.days = Number(args[++i]);
  else if (k === "--top") opt.top = Number(args[++i]);
  else if (k === "--json") opt.json = true;
  else { console.error(`ontology-brief: unknown flag ${k}`); process.exit(2); }
}
if (!opt.company) { console.error("usage: ontology-brief.mjs --company <co> [--days N] [--top N] [--json]"); process.exit(2); }
opt.root = opt.root || process.env.HQ_ROOT || path.resolve(path.dirname(new URL(import.meta.url).pathname), "../..");
const C = path.join(opt.root, "companies", opt.company);
if (!fs.existsSync(C)) { console.error(`ontology-brief: no company ${opt.company}`); process.exit(2); }

function fm(file) {
  const t = fs.readFileSync(file, "utf8");
  const m = t.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
  const out = { _body: (m ? m[2] : t).trim() };
  if (m) for (const line of m[1].split("\n")) {
    const mm = line.match(/^([A-Za-z_]+):\s*(.*)$/);
    if (mm) out[mm[1]] = mm[2].trim().replace(/^"(.*)"$/, "$1");
  }
  return out;
}
const walk = (dir, pred) => {
  if (!fs.existsSync(dir)) return [];
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { if (!e.name.startsWith("_")) out.push(...walk(p, pred)); }
    else if (pred(p)) out.push(p);
  }
  return out;
};

const entities = walk(path.join(C, "ontology", "entities"), p => p.endsWith(".md")).map(f => fm(f));
const cutoff = Date.now() - opt.days * 86400e3;
const signals = walk(path.join(C, "signals"), p => p.endsWith(".md") && !p.includes(`${path.sep}_`))
  .map(f => ({ ...fm(f), _scope: f.includes(`${path.sep}signals${path.sep}@`) ? "scoped" : "company" }))
  .filter(s => TYPES.includes(s.type));
const recent = signals.filter(s => !s.created_at || Date.parse(s.created_at) >= cutoff)
  .sort((a, b) => (b.created_at || "").localeCompare(a.created_at || ""));
const facts = new Map(); // slug -> [{scope, line}]
for (const f of walk(path.join(C, "ontology", "facts"), p => p.endsWith(".md"))) {
  const d = fm(f); const scope = f.includes(`${path.sep}@company${path.sep}`) ? "company" : "scoped";
  const slug = d.entity || path.basename(f, ".md");
  for (const line of d._body.split("\n").filter(l => l.startsWith("- "))) {
    if (!facts.has(slug)) facts.set(slug, []);
    facts.get(slug).push({ scope, line: line.slice(2) });
  }
}
const hot = entities.map(e => ({ ...e, _facts: facts.get(e.slug) || [] }))
  .sort((a, b) => (b._facts.length - a._facts.length) || ((+b.signal_count || 0) - (+a.signal_count || 0)))
  .slice(0, opt.top);

if (opt.json) {
  console.log(JSON.stringify({ company: opt.company, entities: entities.length, signals: signals.length,
    recent: recent.slice(0, opt.top * 2).map(s => ({ type: s.type, scope: s._scope, text: s.canonical_content || s._body })),
    hot: hot.map(e => ({ name: e.canonical_name, type: e.type, facts: e._facts })) }));
  process.exit(0);
}
if (!entities.length && !signals.length) { console.log(`# ${opt.company} — no local ontology yet\n\nNothing under ontology/ or signals/ that you can see.`); process.exit(0); }
const out = [`# ${opt.company} — company brief (local)`, "", `${entities.length} entities · ${signals.length} signals you can see · last ${opt.days} days`, "", "## Recent Signals"];
for (const t of TYPES) {
  const rows = recent.filter(s => s.type === t).slice(0, 5);
  if (!rows.length) continue;
  out.push("", `### ${t.replace("_", " ")}`);
  for (const s of rows) out.push(`- ${s.canonical_content || s._body} _(${s._scope})_`);
}
out.push("", "## Entities");
for (const e of hot) {
  out.push("", `### ${e.canonical_name} — ${e.type}`);
  if (!e._facts.length) out.push("- no facts you can see");
  for (const f of e._facts.slice(0, 6)) out.push(`- ${f.line} _(${f.scope})_`);
}
console.log(out.join("\n"));
