#!/usr/bin/env node
// The super-conductor's request ledger: one durable row per inbound item (a
// teammate DM, a channel message, a Slack mention, a child report, a GitHub
// event) and its status until it is done. Written by scripts and sweep
// workers, read by the conductor; it survives compaction, a restart, and the
// conversation itself. Append-only JSON lines: a row with an existing id
// updates that request, and the latest row wins.
//
//   node core/scripts/super-conductor-requests.mjs add --file <ledger> \
//       --source hq_dm|hq_channel|slack|email|session|github|x|owner \
//       --ref <event id, ts, or session id> --from <name> \
//       --kind info|work|decision|fyi [--text <one line>] [--company <slug>]
//       [--priority critical] [--at <source iso>] [--seen-at <iso>]
//   `at` is the source message's own time; `seen_at` (default now) is when the
//   watcher or sweep saw it, so arrival-to-seen latency is on the row.
//   Exit 0 and print the id; exit 3 and print the existing id when source+ref
//   is already recorded (a second sweep of the same message adds nothing).
//   node core/scripts/super-conductor-requests.mjs set --file <ledger> --id <id> \
//       [--status routed|waiting_owner|answered|done|dropped] [--kind <kind>] \
//       [--note <text>] [--lane <lane id>] [--session <session id>] [--result <ref>]
//   `done` needs --result (the reply event, PR, relay, or lane that closed it).
//   --kind confirms or corrects the guessed kind at triage (with or without a
//   status) and marks the row `triaged`; `list --triaged` keeps only such rows.
//   node core/scripts/super-conductor-requests.mjs list --file <ledger> \
//       [--open] [--triaged] [--status <csv>] [--kind <csv>] [--company <slug>] [--since <iso>]
//       [--priority critical|normal] [--json]
//   Latest state per request, oldest first. --open means not done or dropped.
//   --priority critical keeps only rows from a critical channel or a team DM
//   (the wakeup reads those first).
//   node core/scripts/super-conductor-requests.mjs count --file <ledger>
//   Counts per status as one JSON object.
//
// Transitions: new → routed | waiting_owner | answered | done | dropped;
// routed → waiting_owner | answered | done | dropped; waiting_owner →
// answered | dropped; answered → routed | done | dropped. Anything else exits 2.
// Text is clipped to 300 characters, kept on one line, with "|" replaced.
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { isMain } from './lib/super-conductor-scope.mjs';
import { withLockSync } from './lib/super-conductor-lock.mjs';

const SOURCES = new Set(['hq_dm', 'hq_channel', 'slack', 'email', 'session', 'github', 'x', 'owner']);
const KINDS = new Set(['info', 'work', 'decision', 'fyi']);
const NEXT = {
  new: new Set(['routed', 'waiting_owner', 'answered', 'done', 'dropped']),
  routed: new Set(['waiting_owner', 'answered', 'done', 'dropped']),
  waiting_owner: new Set(['answered', 'dropped']),
  answered: new Set(['routed', 'done', 'dropped']),
  done: new Set(),
  dropped: new Set(),
};

function die(msg) { process.stderr.write(`super-conductor-requests: ${msg}\n`); process.exit(2); }

export const clean = (t, n = 300) => {
  const x = String(t == null ? '' : t).replace(/[\u0000-\u001f\u007f]+/g, ' ').replace(/\|/g, '/').replace(/\s+/g, ' ').trim();
  return x.length > n ? `${x.slice(0, n - 1)}…` : x;
};

function parse(argv, allowed) {
  const o = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) die(`unexpected argument ${a}`);
    const k = a.slice(2);
    if (!allowed.includes(k)) die(`unexpected argument ${a}`);
    if (['open', 'json', 'triaged'].includes(k)) { o[k] = true; continue; }
    if (argv[i + 1] === undefined) die(`${a} needs a value`);
    o[k] = argv[++i];
  }
  return o;
}

export function readRows(file) {
  let text = '';
  try { text = fs.readFileSync(file, 'utf8'); } catch (e) { if (e.code === 'ENOENT') return []; throw e; }
  const rows = [];
  for (const line of text.split('\n')) {
    if (!line.trim()) continue;
    try { const r = JSON.parse(line); if (r && typeof r === 'object' && r.id) rows.push(r); } catch { /* a torn last line is skipped */ }
  }
  return rows;
}

// Latest state per id, in first-seen order. `at` stays the first row's time;
// `updated_at` is the latest row's.
export function fold(rows) {
  const by = new Map();
  for (const r of rows) {
    const cur = by.get(r.id);
    if (!cur) { by.set(r.id, { ...r, updated_at: r.at, history: [{ status: r.status, at: r.at, note: r.note }] }); continue; }
    const { at, ...rest } = r;
    by.set(r.id, { ...cur, ...rest, updated_at: at, history: [...cur.history, { status: r.status, at, note: r.note }] });
  }
  return [...by.values()];
}

function append(file, row) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.appendFileSync(file, `${JSON.stringify(row)}\n`);
}

export function requestId(source, ref, at) {
  const h = createHash('sha256').update(`${source}\0${ref}`).digest('hex').slice(0, 10);
  return `rq_${String(at).replace(/[-:TZ.]/g, '').slice(0, 14)}_${h}`;
}

// Record one inbound item. Returns {id, dup}: dup is true when source+ref was
// already recorded (nothing is appended). Throws on a bad source or kind.
export function addRequest(file, o) {
  for (const k of ['source', 'ref', 'from', 'kind']) if (!o[k]) throw new Error(`add needs ${k}`);
  if (!SOURCES.has(o.source)) throw new Error(`source must be one of ${[...SOURCES].join(', ')}`);
  if (!KINDS.has(o.kind)) throw new Error(`kind must be one of ${[...KINDS].join(', ')}`);
  const at = o.at || new Date().toISOString();
  const ref = clean(o.ref, 200);
  // Two writers (the watcher and a sweep worker) may see the same message:
  // the dedupe read and the append happen under the ledger's lock.
  return withLockSync(file, () => {
    const dup = fold(readRows(file)).find((r) => r.source === o.source && r.ref === ref);
    if (dup) return { id: dup.id, dup: true };
    const row = {
      id: requestId(o.source, ref, at), at, source: o.source, ref, from: clean(o.from, 80),
      kind: o.kind, status: 'new', text: clean(o.text), company: clean(o.company, 60) || undefined,
      // critical: a critical channel or a team DM (super-conductor-prefs.mjs
      // critical); read first on every wake and never batched.
      priority: o.priority === 'critical' ? 'critical' : undefined,
      // When the watcher (or sweep worker) saw it; `at` is the source time.
      // Together they make stage A of the latency breakdown measurable.
      seen_at: o.seen_at || new Date().toISOString(),
    };
    append(file, row);
    return { id: row.id, dup: false };
  });
}

// A first guess at the kind, from the text alone: a status post is fyi, a
// question is a decision, anything else is work. The conductor confirms or
// corrects it at triage (`set --kind`) before a row is routed or asked.
export function guessKind(text) {
  const t = String(text || '').trim();
  // Review-channel grammar (the core-pr-reviews channel policy):
  // status posts are fyi, review requests and questions to the owner are
  // decisions. The "#channel: " prefix the watcher adds is dropped first.
  const body = t.replace(/^#[^:]{1,80}:\s*/, '');
  // A bare status word (optionally "(name)") is a status post; "Done? can you
  // merge" is a question and falls through.
  if (/^(in review|approved|done|merged)(\s*\([^)]{0,60}\))?\s*[.!]?\s*$/i.test(body)) return 'fyi';
  if (/^(flag [\w.-]+: (on|kept off)\b|core (reviewed|is starting)\b)/i.test(body)) return 'fyi';
  // A post that is only a link is a review request on the review channel:
  // work for the conductor to route, never closed unread by triage.
  if (/^https?:\/\/\S+$/i.test(body)) return 'work';
  // A reviewer's verdict addressed to a PR author ("@Pat Approved on GitHub
  // at f47e4d8d: ...", "@Sam Changes requested on GitHub at 422c8481: ...")
  // is work for the session that owns that PR, never an owner decision, even
  // when it ends in "merge when ready?" or "could you fix?".
  if (/^(@\S+(\s+\S+){0,2}\s+)?(approved|changes requested|re-?review requested)(\s+on github)?\s+at\s+[0-9a-f]{7,40}\b/i.test(body)) return 'work';
  if (/^(re-?review please|review please)\b|could (one of you|you)\b|\bready for your (re-?review|review|merge)\b|\bwants? a go\b|\bneeds? (a|your) go\b/i.test(body)) return 'decision';
  if (/^(changes requested)\b/i.test(body)) return 'work';
  // A question or a decision word anywhere wins over a status prefix: "FYI
  // can you approve the prod deploy?" and "Heads up: sync is down, should we
  // roll back?" are decisions, never closed unread as fyi.
  const asks = /\?|\b(approve|ok to|can (i|we|you)|should (i|we)|which|go ahead|roll back|need (a|your) go)\b/i.test(t);
  if (asks) return 'decision';
  // Word-bounded status prefixes. "update" and "note" need their colon
  // ("Update the README please" is an imperative, so work); "done" alone or
  // with a stop is a status.
  if (/^(fyi\b|heads.?up\b|update:|note:|deployed\b|shipped\b|merged\b|landed\b|released\b|done[.!]?\s*$)/i.test(t)) return 'fyi';
  return 'work';
}

function add(argv) {
  const o = parse(argv, ['file', 'source', 'ref', 'from', 'kind', 'text', 'company', 'at', 'priority', 'seen-at']);
  if (!o.file) die('add needs --file');
  let r;
  try { r = addRequest(o.file, { ...o, seen_at: o['seen-at'] }); } catch (e) { die(e.message); }
  process.stdout.write(`${r.id}\n`);
  if (r.dup) process.exit(3);
}

// Move or re-kind one request. Returns {from, to}; throws on a bad
// transition, an unknown id, or `done` without a result. Used by `set` and by
// the triage daemon (super-conductor-triage.mjs).
export function setRequest(file, o) {
  if (!o.id) throw new Error('set needs id');
  if (!o.status && !o.kind) throw new Error('set needs status or kind');
  if (o.status && (!NEXT[o.status] || o.status === 'new')) throw new Error(`status must be one of ${Object.keys(NEXT).filter((s) => s !== 'new').join(', ')}`);
  if (o.kind && !KINDS.has(o.kind)) throw new Error(`kind must be one of ${[...KINDS].join(', ')}`);
  return withLockSync(file, () => {
    const cur = fold(readRows(file)).find((r) => r.id === o.id);
    if (!cur) throw new Error(`no request ${o.id}`);
    const status = o.status || cur.status;
    if (o.status && !NEXT[cur.status].has(o.status)) throw new Error(`cannot move ${o.id} from ${cur.status} to ${o.status}`);
    if (o.status === 'done' && !o.result) throw new Error('done needs result (what closed it)');
    const row = { id: o.id, at: o.at || new Date().toISOString(), status };
    if (o.kind) { row.kind = o.kind; row.triaged = true; }
    if (o.note) row.note = clean(o.note);
    if (o.lane) row.lane = clean(o.lane, 80);
    if (o.session) row.session = clean(o.session, 80);
    if (o.result) row.result = clean(o.result, 200);
    append(file, row);
    return { from: cur.status, to: status };
  });
}

function set(argv) {
  const o = parse(argv, ['file', 'id', 'status', 'kind', 'note', 'lane', 'session', 'result', 'at']);
  for (const k of ['file', 'id']) if (!o[k]) die(`set needs --${k}`);
  let r;
  try { r = setRequest(o.file, o); } catch (e) { die(e.message); }
  process.stdout.write(`${o.id} ${r.from} → ${r.to}${o.kind ? ` (${o.kind})` : ''}\n`);
}

export function select(reqs, o) {
  const statuses = o.status ? new Set(o.status.split(',')) : null;
  const kinds = o.kind ? new Set(o.kind.split(',')) : null;
  const since = o.since ? Date.parse(o.since) : null;
  return reqs.filter((r) => (!o.open || !['done', 'dropped'].includes(r.status))
    && (!o.triaged || r.triaged === true)
    && (!statuses || statuses.has(r.status)) && (!kinds || kinds.has(r.kind))
    && (!o.company || r.company === o.company)
    && (!o.priority || (r.priority || 'normal') === o.priority)
    && (since == null || Date.parse(r.at) >= since));
}

export function line(r) {
  return `${r.id} | ${r.status} | ${r.kind}${r.priority === 'critical' ? ' | critical' : ''} | ${r.source}:${r.ref} | from ${r.from} | ${r.text || ''}${r.lane ? ` | lane ${r.lane}` : ''}${r.session ? ` | session ${r.session}` : ''}`;
}

function list(argv) {
  const o = parse(argv, ['file', 'open', 'triaged', 'status', 'kind', 'company', 'since', 'json', 'priority']);
  if (!o.file) die('list needs --file');
  for (const r of select(fold(readRows(o.file)), o)) process.stdout.write(`${o.json ? JSON.stringify(r) : line(r)}\n`);
}

function count(argv) {
  const o = parse(argv, ['file']);
  if (!o.file) die('count needs --file');
  const out = {};
  for (const r of fold(readRows(o.file))) out[r.status] = (out[r.status] || 0) + 1;
  process.stdout.write(`${JSON.stringify(out)}\n`);
}

function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  if (cmd === 'add') add(rest);
  else if (cmd === 'set') set(rest);
  else if (cmd === 'list') list(rest);
  else if (cmd === 'count') count(rest);
  else die('usage: add|set|list|count --file <ledger> ...');
}

if (isMain(import.meta.url)) main();
