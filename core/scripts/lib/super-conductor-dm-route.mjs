// super-conductor-dm-route.mjs — which conductor owns an HQ DM when several
// /super-conductor sessions run on one machine, each bound to its own company
// set (the heartbeat's --company).
//
// The HQ DM inbox is per person, so every conductor sees every DM the owner
// receives. Without routing, two conductors would both handle a DM. The rule:
//   - a DM from a person who is a member of exactly this conductor's companies
//     (and of no other running conductor's) belongs here; its ledger row carries
//     the one company that holds the sender, when there is exactly one;
//   - a DM from a person in several running conductors' company sets, or in
//     none of them (a stranger, an agent, a personal contact), belongs to the
//     primary conductor only;
//   - a DM from a person who is only in another conductor's companies is not
//     this conductor's: it is never recorded, named, or answered here;
//   - with no other conductor running, every DM belongs here (one conductor per
//     owner, the behavior before routing);
//   - while this conductor's own roster is not yet published for all of its
//     companies, every DM belongs here, so none is dropped by every conductor.
//
// Primary: the save file with `primary: true` (super-conductor-state.mjs set
// <save> primary true); with none or several, the conductor whose heartbeat
// started first. Conductors find each other through their save files in
// workspace/reports/conduct/<link>-state.json: each watcher publishes
// `dm_route` = {companies, members: {<slug>: {uids, emails}}, at} there from
// `hq members list --company <slug> --json`, so a conductor reads only "is this
// sender claimed by another conductor" and never another company's roster. A
// save file not updated for --stale-seconds (default 7200) is a stopped
// conductor and is ignored.
//
// CLI (the hq_dms sweep in the skill pipes the inbox through it):
//   hq dm inbox --limit 100 --json \
//     | node core/scripts/lib/super-conductor-dm-route.mjs filter-dms --save <save file> [--stale-seconds <n>]
//       Prints the inbox rows this conductor owns, each with `_company` (the
//       resolved slug or null) and `_route` (mine|shared|unknown|solo).
//   node core/scripts/lib/super-conductor-dm-route.mjs primary --save <save file>
//       Prints "<link> primary|secondary": the primary conductor's link and
//       whether this save file is it.
//   node core/scripts/lib/super-conductor-dm-route.mjs members --save <save file> --company <csv>
//       Refreshes `dm_route` in the save file from `hq members list` (the
//       watcher does this on its own every 15 minutes).
// Exit: 0 ok, 2 bad arguments or input.
import fs from 'node:fs';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { isMain, parseCompanies } from './super-conductor-scope.mjs';
import { withLockSync } from './super-conductor-lock.mjs';
import { load, save } from '../super-conductor-state.mjs';
import { prepareWindowsCommand } from './windows-cmd-spawn.mjs';

const HQ_BIN = process.env.HQ_BIN || 'hq';
export const STALE_MS = 2 * 3600 * 1000;
export const MEMBERS_TTL_MS = 15 * 60 * 1000;

const ms = (v) => { const n = typeof v === 'string' ? Date.parse(v) : NaN; return Number.isFinite(n) ? n : 0; };
const lower = (e) => String(e || '').trim().toLowerCase();

// The company set a save file's conductor runs in: dm_route.companies (written
// by its watcher), else `company` (csv) or `companies` (list). Empty when
// unknown.
export function companiesOf(state) {
  const r = state && state.dm_route;
  if (r && Array.isArray(r.companies) && r.companies.length) return r.companies.map(String);
  if (Array.isArray(state?.companies)) return state.companies.map(String);
  if (typeof state?.company === 'string') return state.company.split(',').map((s) => s.trim()).filter(Boolean);
  return [];
}

function startedAt(state) {
  return ms(state?.heartbeat?.started_at) || ms(state?.started_at) || ms(state?.dm_route?.at) || 0;
}

// One conductor record from a save file.
export function conductorOf(file, state, now = Date.now(), staleMs = STALE_MS) {
  const members = {};
  const raw = state?.dm_route?.members;
  if (raw && typeof raw === 'object') {
    for (const [slug, m] of Object.entries(raw)) {
      members[slug] = { uids: new Set((m?.uids || []).map(String)), emails: new Set((m?.emails || []).map(lower)) };
    }
  }
  const updated = Math.max(ms(state?.updated_at), ms(state?.dm_route?.at));
  return {
    file,
    link: String(state?.link || path.basename(file).replace(/-state\.json$/, '')),
    companies: companiesOf(state),
    primary: state?.primary === true,
    started_at: startedAt(state),
    alive: updated > 0 && now - updated <= staleMs,
    members,
  };
}

// Every live conductor whose save file is in `dir` (the self file included).
export function listConductors(dir, { now = Date.now(), staleMs = STALE_MS } = {}) {
  let names = [];
  try { names = fs.readdirSync(dir); } catch { return []; }
  const out = [];
  for (const n of names) {
    if (!/^cl-[A-Za-z0-9-]+-state\.json$/.test(n)) continue;
    const file = path.join(dir, n);
    const c = conductorOf(file, load(file), now, staleMs);
    if (c.alive) out.push(c);
  }
  return out;
}

// The primary conductor's link: `primary: true` wins (earliest start when
// several are marked); otherwise the earliest heartbeat start. Null for none.
export function pickPrimary(conductors) {
  if (!conductors.length) return null;
  const marked = conductors.filter((c) => c.primary);
  const pool = marked.length ? marked : conductors;
  return [...pool].sort((a, b) => (a.started_at || Infinity) - (b.started_at || Infinity) || a.link.localeCompare(b.link))[0].link;
}

function senderIn(members, ev) {
  const uid = ev.fromPersonUid ? String(ev.fromPersonUid) : '';
  const email = lower(ev.fromEmail);
  const slugs = [];
  for (const [slug, m] of Object.entries(members)) {
    if ((uid && m.uids.has(uid)) || (email && m.emails.has(email))) slugs.push(slug);
  }
  return slugs;
}

// True when the conductor has a published roster for every company it runs in.
export function rosterPublished(c) {
  if (!c || !c.companies || !c.companies.length) return false;
  return c.companies.every((slug) => Object.prototype.hasOwnProperty.call(c.members || {}, slug));
}

// The routing context for one conductor: itself, the other live conductors,
// and the primary link.
export function makeRouteContext(selfFile, conductors) {
  const real = (f) => { try { return fs.realpathSync(f); } catch { return path.resolve(f); } };
  const me = real(selfFile);
  const self = conductors.find((c) => real(c.file) === me) || null;
  const others = conductors.filter((c) => real(c.file) !== me);
  return { self, others, primary: pickPrimary(conductors) };
}

// {owned, company, route} for one inbox event. See the header for the rule.
export function routeDm(ev, ctx) {
  if (!ctx || !ctx.self) return { owned: true, company: undefined, route: 'solo' };
  const mine = senderIn(ctx.self.members, ev);
  const company = mine.length === 1 ? mine[0] : undefined;
  if (!ctx.others.length) return { owned: true, company, route: 'solo' };
  // This conductor's own roster is not published yet (first poll, or every
  // `hq members list` so far failed), or covers only part of its companies.
  // It cannot tell "only in another conductor's set" from "also in mine", so
  // it keeps the DM rather than dropping one that no conductor may take. The
  // cost is that a DM may be handled twice until the roster lands.
  if (!rosterPublished(ctx.self)) return { owned: true, company, route: 'unpublished' };
  const elsewhere = ctx.others.some((c) => senderIn(c.members, ev).length > 0);
  const isPrimary = ctx.primary === ctx.self.link;
  if (mine.length && !elsewhere) return { owned: true, company, route: 'mine' };
  if (mine.length && elsewhere) return { owned: isPrimary, company: undefined, route: 'shared' };
  if (elsewhere) return { owned: false, company: undefined, route: 'other' };
  return { owned: isPrimary, company: undefined, route: 'unknown' };
}

function hqJson(args) {
  const run = prepareWindowsCommand(HQ_BIN, args, { maxBuffer: 64 * 1024 * 1024, timeout: 120_000 });
  return new Promise((resolve, reject) => {
    execFile(run.file, run.args, run.options, (err, stdout, stderr) => {
      if (err) { reject(new Error(`hq ${args.slice(0, 2).join(' ')} failed: ${(stderr || err.message).trim().split('\n')[0]}`)); return; }
      try { resolve(JSON.parse(stdout)); } catch { reject(new Error(`hq ${args.slice(0, 2).join(' ')} printed non-JSON`)); }
    });
  });
}

// {<slug>: {uids: [...], emails: [...]}} for the given companies, from
// `hq members list --company <slug> --json` (an object with `members`, or an
// array). Active people and agents both count; a sender is matched by uid or
// email. Throws on the first company that cannot be read.
export async function fetchMembers(slugs, call = hqJson) {
  const out = {};
  for (const slug of slugs) {
    const data = await call(['members', 'list', '--company', slug, '--json']);
    const rows = Array.isArray(data) ? data : Array.isArray(data?.members) ? data.members : [];
    const uids = new Set();
    const emails = new Set();
    for (const m of rows) {
      if (m?.status && String(m.status) !== 'active') continue;
      const uid = m?.person_id || m?.personUid || m?.personId || m?.agentUid;
      if (uid) uids.add(String(uid));
      const e = lower(m?.email);
      if (e) emails.add(e);
    }
    out[slug] = { uids: [...uids].sort(), emails: [...emails].sort() };
  }
  return out;
}

// Write dm_route into the save file under its lock, one key, like state.mjs.
export function publishMembers(saveFile, companies, members, at = new Date().toISOString()) {
  withLockSync(saveFile, () => {
    const state = load(saveFile);
    state.dm_route = { companies: [...companies], members, at };
    state.updated_at = at;
    save(saveFile, state);
  });
}

// Refresh when the save file has no dm_route for these companies or it is
// older than MEMBERS_TTL_MS. Returns true when it refreshed.
export async function refreshMembers(saveFile, companies, { call, now = Date.now(), ttlMs = MEMBERS_TTL_MS } = {}) {
  const cur = load(saveFile).dm_route;
  const same = cur && Array.isArray(cur.companies) && cur.companies.join(',') === [...companies].join(',');
  if (same && now - ms(cur.at) < ttlMs) return false;
  const members = await fetchMembers(companies, call);
  publishMembers(saveFile, companies, members, new Date(now).toISOString());
  return true;
}

function parse(argv) {
  const o = { company: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const v = () => { const x = argv[++i]; if (x === undefined) throw new Error(`${a} needs a value`); return x; };
    if (a === '--save') o.save = v();
    else if (a === '--company') o.company.push(v());
    else if (a === '--stale-seconds') o.stale = Number(v());
    else throw new Error(`unexpected argument ${a}`);
  }
  if (!o.save) throw new Error('--save <save file> is required');
  if (o.stale !== undefined && !(Number.isFinite(o.stale) && o.stale > 0)) throw new Error('--stale-seconds must be a positive number');
  return o;
}

async function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  const fail = (msg) => { process.stderr.write(`super-conductor-dm-route: ${msg}\n`); process.exit(2); };
  if (!['filter-dms', 'primary', 'members'].includes(cmd)) fail('usage: filter-dms|primary|members --save <save file> [--company <csv>] [--stale-seconds <n>]');
  let o;
  try { o = parse(rest); } catch (e) { fail(e.message); }
  const staleMs = o.stale ? o.stale * 1000 : STALE_MS;
  if (cmd === 'members') {
    let slugs;
    try { slugs = parseCompanies(o.company); } catch (e) { fail(e.message); }
    try { await refreshMembers(o.save, slugs, { ttlMs: 0 }); } catch (e) { fail(e.message); }
    process.stdout.write(`dm_route refreshed for ${slugs.join(',')}\n`);
    return;
  }
  const ctx = makeRouteContext(o.save, listConductors(path.dirname(o.save), { staleMs }));
  if (cmd === 'primary') {
    process.stdout.write(`${ctx.primary || '-'} ${ctx.self && ctx.primary === ctx.self.link ? 'primary' : ctx.self ? 'secondary' : 'unknown'}\n`);
    return;
  }
  let data;
  try { data = JSON.parse(fs.readFileSync(0, 'utf8')); } catch (e) { fail(`stdin is not JSON: ${e.message}`); }
  if (!Array.isArray(data)) fail('expected the `hq dm inbox --json` array');
  const out = [];
  for (const ev of data) {
    if (!ev || typeof ev !== 'object') continue;
    const r = routeDm(ev, ctx);
    if (r.owned) out.push({ ...ev, _company: r.company || null, _route: r.route });
  }
  process.stdout.write(`${JSON.stringify(out, null, 2)}\n`);
}

if (isMain(import.meta.url)) main();
