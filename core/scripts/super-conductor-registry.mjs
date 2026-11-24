#!/usr/bin/env node
// super-conductor-registry.mjs — named super-conductor profiles.
//
// Several super-conductors can run at once, including two for the same
// company when their scopes differ. Each one has a unique name and a profile at
// personal/settings/super-conductors/<name>.yaml holding its scope, spawn
// and adoption rules, cadence, sweep channels, stats, decision mode, and the
// areas it must not watch. Its runtime files (state, decisions, requests,
// overnight log, message-watch state) live under workspace/reports/conduct/
// and are never shared with another conductor.
//
// Usage (all commands print JSON unless noted):
//   list [--json]                      names, status, link, company, scope line
//   show <name>                        the parsed profile
//   questions                          the setup questionnaire (one picker each)
//   resolve [<name>] [--session <local_id>]
//       startup and resume: a named profile; the profile whose session or desk
//       matches --session; or, with no name, the one active profile (confirm:
//       true) or the list to pick from.
//   create --answers <file|-> [--dry-run]
//       write a new profile from questionnaire answers; refuses a taken name,
//       link, file path, or a session another profile adopts.
//   set <name> <dotted.key> <value>    value is JSON when it parses, else text
//   add <name> <dotted.key> <value>... append to a list (no duplicates)
//   remove <name> <dotted.key> <value>...
//   bind <name> --link <id> [--desktop <local_id>] [--transcript <id>]
//       record the conduct link and session after `hq runners link open`;
//       derives the runtime file paths from the link.
//   paths <name>                       runtime files and the rendered prefs file
//   render-prefs <name>                write <name>.prefs.yaml (base settings +
//                                      this profile's sweep and cadence) and
//                                      print its absolute path; pass it to the
//                                      core scripts as SC_PREFS_FILE.
//   route [--session <id>] [--company <slug>] [--channel <key:value>]
//         [--group <sidebar group>] [--title <session title>] [--text <words>]
//         [--from <asking conductor>]
//       which conductor owns an item; prints {owner, reason, candidates}. With
//       --from it adds forward: true|false; false means the owner is in the
//       asker's scope.no_forward_to, so the asker leaves the item alone.
//       Exit 5 when no single owner is found.
//   claim <name> --session <local_id> [--note <text>]
//       record that <name> adopted a session; exit 4 (holder printed) when
//       another conductor holds it.
//   release <name> --session <local_id>
//   claims                              every claim
//   validate [<name>]                   cross-profile collision checks; exit 1
//                                       with the problems listed
//   delete <name> --yes                 remove the profile, its rendered prefs
//                                       and its claims; never touches state files
//
// Environment: HQ_ROOT, SC_REGISTRY_DIR (profiles), SC_CONDUCT_DIR (runtime
// files and the claims ledger), SC_BASE_PREFS (owner-wide settings file).

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { withLockSync, replaceFile } from './lib/super-conductor-lock.mjs';

const ROOT = process.env.HQ_ROOT || path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const REG = process.env.SC_REGISTRY_DIR || path.join(ROOT, 'personal/settings/super-conductors');
const CONDUCT = process.env.SC_CONDUCT_DIR || path.join(ROOT, 'workspace/reports/conduct');
const BASE_PREFS = process.env.SC_BASE_PREFS || path.join(ROOT, 'personal/settings/super-conductor.yaml');
const CLAIMS = path.join(CONDUCT, 'super-conductor-claims.json');
const NAME_RE = /^[a-z][a-z0-9-]{1,31}$/;
const RESERVED = new Set(['base', 'default', 'all', 'none', 'prefs', 'claims']);

function die(msg, code = 2) { process.stderr.write(`super-conductor-registry: ${msg}\n`); process.exit(code); }
function out(v) { process.stdout.write(`${typeof v === 'string' ? v : JSON.stringify(v, null, 2)}\n`); }
const rel = (p) => path.relative(ROOT, p);
const now = () => new Date().toISOString();

// ---------- YAML subset (same subset the core prefs helper reads) ----------
const KEY_RE = /^([A-Za-z_][\w-]*):(.*)$/;
function stripComment(s) {
  let q = null;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q) { if (c === '\\' && q === '"') { i++; continue; } if (c === q) q = null; continue; }
    if (c === '"' || c === "'") { q = c; continue; }
    if (c === '#' && (i === 0 || s[i - 1] === ' ' || s[i - 1] === '\t')) return s.slice(0, i).trim();
  }
  return s.trim();
}
function scalar(raw) {
  const s = raw.trim();
  if (s.length >= 2 && s[0] === s[s.length - 1] && (s[0] === '"' || s[0] === "'")) return s[0] === '"' ? JSON.parse(s) : s.slice(1, -1);
  if (/^-?\d+$/.test(s)) return Number(s);
  if (s === 'true' || s === 'false') return s === 'true';
  if (s === '' || s === 'null' || s === '~') return null;
  if (s === '[]') return [];
  if (s === '{}') return {};
  if (s.startsWith('[') && s.endsWith(']')) return s.slice(1, -1).split(',').map(scalar);
  return s;
}
export function parseYaml(text) {
  const rows = [];
  for (const line of text.split('\n')) {
    const body = stripComment(line);
    if (!body || body === '---') continue;
    rows.push({ indent: line.match(/^ */)[0].length, body });
  }
  let i = 0;
  function block(indent) {
    if (i >= rows.length || rows[i].indent < indent) return null;
    const base = rows[i].indent;
    if (rows[i].body.startsWith('- ') || rows[i].body === '-') {
      const list = [];
      while (i < rows.length && rows[i].indent === base && (rows[i].body.startsWith('- ') || rows[i].body === '-')) {
        const rest = rows[i].body.slice(2).trim();
        i++;
        const m = rest.match(KEY_RE);
        if (m && !/^["']/.test(rest)) {
          const obj = { [m[1]]: m[2].trim() ? scalar(m[2]) : block(base + 3) };
          if (i < rows.length && rows[i].indent > base && !rows[i].body.startsWith('- ')) Object.assign(obj, block(rows[i].indent));
          list.push(obj);
        } else list.push(rest ? scalar(rest) : block(base + 1));
      }
      return list;
    }
    const map = {};
    while (i < rows.length && rows[i].indent === base) {
      const m = rows[i].body.match(KEY_RE);
      i++;
      if (!m) continue;
      map[m[1]] = m[2].trim() ? scalar(m[2]) : block(base + 1);
    }
    return map;
  }
  const d = block(0);
  return d && !Array.isArray(d) ? d : {};
}
function q(s) {
  s = String(s);
  if (s.includes('"') && !s.includes("'")) return `'${s}'`;
  return JSON.stringify(s);
}
function emitScalar(v) {
  if (v === null || v === undefined) return 'null';
  if (typeof v === 'number' || typeof v === 'boolean') return String(v);
  return q(v);
}
export function emitYaml(v, indent = 0) {
  const pad = ' '.repeat(indent);
  const lines = [];
  for (const [k, val] of Object.entries(v)) {
    if (Array.isArray(val)) {
      if (!val.length) { lines.push(`${pad}${k}: []`); continue; }
      lines.push(`${pad}${k}:`);
      for (const item of val) {
        if (item && typeof item === 'object' && !Array.isArray(item)) {
          const inner = emitYaml(item, indent + 4).split('\n');
          lines.push(`${pad}  - ${inner[0].trimStart()}`, ...inner.slice(1));
        } else lines.push(`${pad}  - ${emitScalar(item)}`);
      }
    } else if (val && typeof val === 'object') {
      if (!Object.keys(val).length) { lines.push(`${pad}${k}: {}`); continue; }
      lines.push(`${pad}${k}:`, emitYaml(val, indent + 2));
    } else lines.push(`${pad}${k}: ${emitScalar(val)}`);
  }
  return lines.join('\n');
}

// ---------- profiles ----------
const profilePath = (name) => path.join(REG, `${name}.yaml`);
const prefsPath = (name) => path.join(REG, `${name}.prefs.yaml`);
function checkName(name) {
  if (!NAME_RE.test(name || '') || RESERVED.has(name)) die(`invalid conductor name '${name}': lowercase letters, digits and dashes, 2-32 chars, starting with a letter; not ${[...RESERVED].join('/')}`);
}
function listNames() {
  try { return fs.readdirSync(REG).filter((f) => f.endsWith('.yaml') && !f.endsWith('.prefs.yaml')).map((f) => f.slice(0, -5)).sort(); } catch { return []; }
}
function load(name) {
  checkName(name);
  let text;
  try { text = fs.readFileSync(profilePath(name), 'utf8'); } catch { die(`no conductor named '${name}' (known: ${listNames().join(', ') || 'none'})`, 3); }
  const p = parseYaml(text);
  if (p.name !== name) die(`profile ${rel(profilePath(name))} has name '${p.name}', expected '${name}'`, 3);
  return p;
}
const loadAll = () => listNames().map((n) => { try { return parseYaml(fs.readFileSync(profilePath(n), 'utf8')); } catch { return null; } }).filter(Boolean);

const HEADER = (name) => `# /super-conductor profile "${name}". One file per named conductor.\n# Edit with personal/scripts/super-conductor-registry.mjs (set/add/remove/bind)\n# so cross-conductor checks run; hand edits are read but not validated.\n`;
function save(p) {
  fs.mkdirSync(REG, { recursive: true });
  const file = profilePath(p.name);
  p.updated_at = now();
  withLockSync(file, () => {
    const tmp = `${file}.tmp-${process.pid}`;
    fs.writeFileSync(tmp, `${HEADER(p.name)}${emitYaml(p)}\n`);
    replaceFile(tmp, file);
  });
}

export function runtimeFiles(name, link) {
  // Keyed on the link so a resumed conductor keeps its history; a profile with
  // no link yet is keyed on its name. Never shared between conductors.
  const key = link || `sc-${name}`;
  const f = (s) => `workspace/reports/conduct/${key}-${s}`;
  return {
    state: f('state.json'), decisions: f('decisions.jsonl'), requests: f('requests.jsonl'),
    overnight: f('overnight.md'), message_watch: f('message-watch.json'), asks: f('asks.json'),
    prefs: rel(prefsPath(name)),
  };
}

// ---------- questionnaire ----------
// One AskUserQuestion per entry, in order. `key` is where the answer lands in
// the answers JSON passed to `create`. "Other" text is always accepted.
export const QUESTIONS = [
  { key: 'scope.manages', header: 'Scope', multiSelect: true, question: 'What should this conductor manage? Pick the companies, projects or lanes it owns.', options_from: 'companies, active projects, sidebar groups', hint: 'Name areas in plain words, for example "Acme owner work" or "the billing rewrite project lanes".' },
  { key: 'spawn.mode', header: 'New sessions', multiSelect: false, question: 'When may this conductor start new sessions?', options: [
    { label: 'Ask me each time (Recommended)', value: 'ask', description: 'It proposes a session card; you start it.' },
    { label: 'Inside its scope', value: 'auto_within_scope', description: 'It starts sessions for requests inside its scope on its own; anything else is asked.' },
    { label: 'Never', value: 'never', description: 'It only routes and relays; it never starts sessions.' }] },
  { key: 'adopt.mode', header: 'Adopt', multiSelect: false, question: 'Should it take over sessions that are already running?', options: [
    { label: 'Ones in its scope (Recommended)', value: 'all_in_scope', description: 'Invites every open session in its scope that no other conductor holds.' },
    { label: 'Only ones I pick', value: 'listed', description: 'A follow-up picker lists open sessions not held by another conductor.' },
    { label: 'None', value: 'none', description: 'Leaves running sessions alone; adopts only sessions it starts.' }] },
  { key: 'cadence.present', header: 'Check rate', multiSelect: false, question: 'How often should it check during your work hours?', options: [
    { label: '5 minutes (Recommended)', value: 300 }, { label: '1 minute', value: 60 }, { label: '10 minutes', value: 600 }, { label: '30 minutes', value: 1800 }] },
  { key: 'cadence.away', header: 'Away rate', multiSelect: false, question: 'How often should it check outside work hours or overnight?', options: [
    { label: '25 minutes (Recommended)', value: 1500 }, { label: '10 minutes', value: 600 }, { label: '1 hour', value: 3600 }, { label: 'Same as work hours', value: 'present' }] },
  { key: 'sweep.channels', header: 'Channels', multiSelect: true, question: 'Which channels should it sweep? Its own sessions are always swept.', options: [
    { label: 'HQ DMs', value: 'hq_dms' }, { label: 'HQ channels', value: 'hq_channels' }, { label: 'Email', value: 'email' }, { label: 'Slack', value: 'slack' }, { label: 'X', value: 'x' }],
    followups: { email: 'Which email accounts? (list)', slack: 'Which Slack workspaces and channels?', hq_channels: 'All HQ channels, or only some (names)?', x: 'Which X accounts?' } },
  { key: 'stats', header: 'Stats', multiSelect: true, question: 'Which other signals should it check?', options: [
    { label: 'CI on its repos', value: 'ci', description: 'Follow-up asks which repos.' },
    { label: 'Telemetry checks', value: 'telemetry', description: 'Follow-up asks which checks.' },
    { label: 'Calendar meetings', value: 'calendar', description: 'Follow-up asks which calendar and which meetings to join without asking.' },
    { label: 'Teammate work', value: 'teammates', description: 'Mesh threads and PRs of named teammates.' }] },
  { key: 'decisions.mode', header: 'Decisions', multiSelect: false, question: 'Where should your decisions from this conductor be asked?', options: [
    { label: 'Separate decision desk (Recommended)', value: 'desk_session', description: 'A desk session with this conductor\'s own queue asks you, one card at a time; the conductor keeps sweeping.' },
    { label: 'In the conductor', value: 'own_queue', description: 'The conductor asks one picker per turn in its own window, after each sweep.' }] },
  { key: 'decisions.child_asks', header: 'Child asks', multiSelect: false, question: 'When a session this conductor adopted asks you something, where should it be asked?', options: [
    { label: 'On the decision queue (Recommended)', value: 'queue', description: 'Every open question from an adopted session is queued and asked with the rest.' },
    { label: 'In that session', value: 'stay_in_window', description: 'It stays in the session\'s own window; the conductor raises it only after it waits too long (follow-up asks how long, default 2 hours of work time).' }] },
  { key: 'scope.not_watching', header: 'Hands off', multiSelect: true, question: 'Which sessions or areas must it NOT watch?', options_from: 'other conductors\' scopes and open sidebar groups', hint: 'Items listed here are forwarded to their owner, never acted on.' },
  { key: 'name', header: 'Name', multiSelect: false, question: 'What should this conductor be called? Lowercase, unique, for example "acme" or "acme-infra".', options_from: 'suggested names from the scope answer, minus names already used' },
];

// ---------- create from answers ----------
const asList = (v) => (v == null ? [] : Array.isArray(v) ? v : [v]).filter((x) => x !== '' && x != null);
function setPath(obj, dotted, value) {
  const keys = dotted.split('.');
  let o = obj;
  for (const k of keys.slice(0, -1)) { if (!o[k] || typeof o[k] !== 'object' || Array.isArray(o[k])) o[k] = {}; o = o[k]; }
  o[keys[keys.length - 1]] = value;
}
function getPath(obj, dotted) { return dotted.split('.').reduce((o, k) => (o == null ? undefined : o[k]), obj); }

export function profileFromAnswers(a) {
  const name = String(a.name || '').trim();
  checkName(name);
  const present = Number(a.cadence?.present ?? 300);
  const awayRaw = a.cadence?.away ?? 1500;
  const clamp = (n) => Math.min(3600, Math.max(30, Number(n) || 0));
  const channels = asList(a.sweep?.channels).filter((c) => c !== 'sessions');
  const p = {
    name,
    title: a.title || `${name} super-conductor`,
    status: 'active',
    created_at: now(),
    updated_at: now(),
    company: a.company || null,
    companies: asList(a.companies || a.company),
    primary_for_companies: asList(a.primary_for_companies),
    link: null,
    link_kind: a.link_kind || 'lanes-link',
    session: { desktop: a.session?.desktop || null, transcript: a.session?.transcript || null },
    scope: {
      manages: asList(a.scope?.manages),
      session_groups: asList(a.scope?.session_groups),
      title_match: asList(a.scope?.title_match),
      route_keywords: asList(a.scope?.route_keywords),
      not_watching: asList(a.scope?.not_watching),
      not_watching_sessions: asList(a.scope?.not_watching_sessions),
      not_watching_groups: asList(a.scope?.not_watching_groups),
      no_forward_to: asList(a.scope?.no_forward_to),
    },
    spawn: { mode: a.spawn?.mode || 'ask', rules: asList(a.spawn?.rules) },
    adopt: { mode: a.adopt?.mode || 'all_in_scope', sessions: asList(a.adopt?.sessions) },
    cadence: {
      present: clamp(present),
      away: awayRaw === 'present' ? clamp(present) : clamp(awayRaw),
      work_hours: a.cadence?.work_hours || null,
      message_wake: a.cadence?.message_wake !== false && (channels.includes('hq_dms') || channels.includes('hq_channels')),
    },
    sweep: { channels: ['sessions', ...channels] },
    stats: {},
    decisions: {
      mode: a.decisions?.mode || 'desk_session',
      desk_session: a.decisions?.desk_session || null,
      queue: null,
      child_asks: a.decisions?.child_asks || 'queue',
      child_ask_escalate_minutes: Number(a.decisions?.child_ask_escalate_minutes ?? 120),
    },
    policies: asList(a.policies),
    standing: asList(a.standing),
    notes: asList(a.notes),
    confirm: asList(a.confirm),
  };
  for (const k of ['email_accounts', 'slack_workspaces', 'slack_channels', 'x_accounts', 'hq_channels_exclude', 'critical_channels']) {
    const v = asList(a.sweep?.[k]);
    if (v.length) p.sweep[k] = v;
  }
  if (a.sweep?.hq_channels != null) p.sweep.hq_channels = a.sweep.hq_channels;
  const stats = a.stats || {};
  for (const k of ['ci', 'telemetry', 'calendar', 'teammates']) if (stats[k] != null && stats[k] !== false) p.stats[k] = stats[k];
  p.files = runtimeFiles(name, null);
  p.decisions.queue = p.files.decisions;
  return p;
}

// ---------- cross-profile checks ----------
function readClaims() {
  try { return JSON.parse(fs.readFileSync(CLAIMS, 'utf8')); } catch { return { claims: {} }; }
}
function writeClaims(c) {
  fs.mkdirSync(CONDUCT, { recursive: true });
  const tmp = `${CLAIMS}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, `${JSON.stringify(c, null, 2)}\n`);
  replaceFile(tmp, CLAIMS);
}
export function problems(profiles, claims = readClaims()) {
  const errs = [];
  const seen = (label) => { const m = new Map(); return (key, who) => { if (!key) return; if (m.has(key) && m.get(key) !== who) errs.push(`${label} '${key}' is used by both ${m.get(key)} and ${who}`); else m.set(key, who); }; };
  const name = seen('name'), link = seen('link'), file = seen('runtime file'), desk = seen('desk session'), desktop = seen('conductor session'), adopt = seen('adopted session');
  for (const p of profiles) {
    if (!NAME_RE.test(p.name || '')) errs.push(`bad name '${p.name}'`);
    name(p.name, p.name);
    link(p.link, p.name);
    for (const f of Object.values(p.files || {})) file(f, p.name);
    desk(p.decisions?.desk_session, p.name);
    desktop(p.session?.desktop, p.name);
    for (const s of asList(p.adopt?.sessions)) adopt(s, p.name);
    for (const s of asList(p.adopt?.sessions)) if (asList(p.scope?.not_watching_sessions).includes(s)) errs.push(`${p.name} both adopts and excludes ${s}`);
  }
  for (const p of profiles) for (const s of asList(p.adopt?.sessions)) {
    const other = profiles.find((o) => o !== p && o.session?.desktop === s);
    if (other) errs.push(`${p.name} adopts ${s}, which is conductor ${other.name}`);
  }
  for (const [sid, c] of Object.entries(claims.claims || {})) {
    if (!profiles.some((p) => p.name === c.conductor)) errs.push(`claim on ${sid} is held by unknown conductor '${c.conductor}'`);
  }
  return errs;
}

// ---------- routing ----------
// With item.from (the asking conductor's name), an owner listed in that
// conductor's scope.no_forward_to comes back with forward: false: the item
// belongs to that peer, which sweeps its own channels, so the asker leaves it
// alone instead of forwarding it.
export function route(profiles, item, claims = readClaims()) {
  const r = routeOwner(profiles, item, claims);
  if (item.from) {
    const asker = profiles.find((p) => p.name === item.from);
    r.forward = Boolean(r.owner && r.owner !== item.from && !asList(asker?.scope?.no_forward_to).includes(r.owner));
    if (r.owner && r.owner !== item.from && !r.forward) r.reason = `${r.reason}; ${item.from} does not forward to ${r.owner}, leave it alone`;
  }
  return r;
}

function routeOwner(profiles, item, claims) {
  const active = profiles.filter((p) => p.status !== 'retired');
  const excluded = (p) => (item.session && asList(p.scope?.not_watching_sessions).includes(item.session))
    || (item.group && asList(p.scope?.not_watching_groups).some((g) => g.toLowerCase() === item.group.toLowerCase()));
  const pick = (cands, reason) => {
    const c = cands.filter((p) => !excluded(p));
    return c.length === 1 ? { owner: c[0].name, reason, candidates: [c[0].name] } : c.length ? { owner: null, reason: `${reason}; ambiguous`, candidates: c.map((p) => p.name) } : null;
  };
  if (item.session) {
    const held = claims.claims?.[item.session];
    if (held) return { owner: held.conductor, reason: 'session claimed', candidates: [held.conductor] };
    const self = active.find((p) => p.session?.desktop === item.session || p.decisions?.desk_session === item.session);
    if (self) return { owner: self.name, reason: 'conductor or its decision desk', candidates: [self.name] };
    const r = pick(active.filter((p) => asList(p.adopt?.sessions).includes(item.session)), 'listed in adopt.sessions');
    if (r) return r;
  }
  if (item.group) {
    const r = pick(active.filter((p) => asList(p.scope?.session_groups).some((g) => g.toLowerCase() === item.group.toLowerCase())), `sidebar group ${item.group}`);
    if (r) return r;
  }
  if (item.title) {
    const r = pick(active.filter((p) => asList(p.scope?.title_match).some((re) => { try { return new RegExp(re, 'i').test(item.title); } catch { return false; } })), 'title match');
    if (r) return r;
  }
  if (item.channel) {
    const [kind, ...rest] = item.channel.split(':');
    const val = rest.join(':').toLowerCase();
    const key = { email: 'email_accounts', slack: 'slack_workspaces', x: 'x_accounts' }[kind];
    if (key && val) {
      const r = pick(active.filter((p) => asList(p.sweep?.[key]).some((v) => String(v).toLowerCase() === val)), `${kind} ${val}`);
      if (r && r.owner) return r;
    }
  }
  let cands = active.filter((p) => !excluded(p));
  if (item.company) cands = cands.filter((p) => asList(p.companies).includes(item.company));
  if (item.text) {
    const t = item.text.toLowerCase();
    const kw = cands.filter((p) => asList(p.scope?.route_keywords).some((k) => t.includes(String(k).toLowerCase())));
    if (kw.length === 1) return { owner: kw[0].name, reason: 'route keyword', candidates: [kw[0].name] };
    if (kw.length > 1) cands = kw;
  }
  if (cands.length === 1) return { owner: cands[0].name, reason: item.company ? `only conductor for ${item.company}` : 'only conductor', candidates: [cands[0].name] };
  const prim = cands.filter((p) => item.company && asList(p.primary_for_companies).includes(item.company));
  if (prim.length === 1) return { owner: prim[0].name, reason: `primary for ${item.company}`, candidates: cands.map((p) => p.name) };
  return { owner: null, reason: cands.length ? 'ambiguous' : 'no conductor in scope', candidates: cands.map((p) => p.name) };
}

// ---------- prefs rendering ----------
function readBasePrefs() { try { return parseYaml(fs.readFileSync(BASE_PREFS, 'utf8')); } catch { return {}; } }
export function renderPrefs(p, base = readBasePrefs()) {
  const outp = { ...base };
  // Sweep targets come from this profile only: a mailbox, X account or Slack
  // workspace in the owner-wide base file is not swept by every conductor.
  for (const k of ['email_accounts', 'x_accounts', 'slack_workspaces', 'slack_channels']) delete outp[k];
  for (const [k, v] of Object.entries(p.sweep || {})) outp[k] = v;
  outp.watch_interval = { present: p.cadence?.present ?? 300, away: p.cadence?.away ?? 1500 };
  if (p.cadence?.work_hours) outp.work_hours = { ...(base.work_hours || {}), ...p.cadence.work_hours };
  if (p.stats?.teammates && typeof p.stats.teammates === 'object') outp.teammates = p.stats.teammates;
  if (p.decisions?.child_asks === 'stay_in_window') outp.child_ask_escalate_minutes = p.decisions.child_ask_escalate_minutes ?? 120;
  outp.conductor_name = p.name;
  outp.conductor_decisions = p.decisions?.mode || 'desk_session';
  outp.conductor_child_asks = p.decisions?.child_asks || 'queue';
  outp.conductor_scope = asList(p.scope?.manages).join('; ');
  outp.conductor_not_watching = asList(p.scope?.not_watching);
  return outp;
}

// ---------- CLI ----------
function opts(args) {
  const o = { _: [] };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a.startsWith('--')) {
      const k = a.slice(2);
      if (['yes', 'dry-run', 'json'].includes(k)) o[k] = true; else { o[k] = args[i + 1]; i++; }
    } else o._.push(a);
  }
  return o;
}
const parseVal = (s) => { try { return JSON.parse(s); } catch { return s; } };

function main(argv) {
  const [cmd, ...rest] = argv;
  const o = opts(rest);
  switch (cmd) {
    case 'list': {
      const rows = loadAll().map((p) => ({ name: p.name, status: p.status, company: p.company, link: p.link, session: p.session?.desktop, decisions: p.decisions?.mode, scope: asList(p.scope?.manages).join('; ') }));
      if (o.json) return out(rows);
      if (!rows.length) return out('no saved conductors');
      return out(rows.map((r) => `${r.name}\t${r.status}\t${r.company || '-'}\t${r.link || '(no link yet)'}\t${r.scope}`).join('\n'));
    }
    case 'show': return out(load(o._[0]));
    case 'questions': return out(QUESTIONS);
    case 'resolve': {
      const all = loadAll().filter((p) => p.status !== 'retired');
      if (o._[0]) return out({ mode: 'named', confirm: false, profile: load(o._[0]) });
      if (o.session) {
        const m = all.find((p) => p.session?.desktop === o.session || p.session?.transcript === o.session);
        if (m) return out({ mode: 'session', confirm: false, profile: m });
      }
      if (all.length === 1) return out({ mode: 'only', confirm: true, profile: all[0] });
      return out({ mode: all.length ? 'pick' : 'new', confirm: false, names: all.map((p) => p.name) });
    }
    case 'create': {
      if (!o.answers) die('create needs --answers <file|->');
      const raw = o.answers === '-' ? fs.readFileSync(0, 'utf8') : fs.readFileSync(o.answers, 'utf8');
      const p = profileFromAnswers(JSON.parse(raw));
      if (fs.existsSync(profilePath(p.name))) die(`a conductor named '${p.name}' already exists; pick another name or reuse it`, 4);
      const errs = problems([...loadAll(), p]);
      if (errs.length) die(`refused:\n- ${errs.join('\n- ')}`, 4);
      if (o['dry-run']) return out({ dry_run: true, would_write: rel(profilePath(p.name)), profile: p });
      save(p);
      return out({ created: rel(profilePath(p.name)), profile: p });
    }
    case 'set': case 'add': case 'remove': {
      const [name, key, ...vals] = o._;
      if (!key) die(`${cmd} <name> <dotted.key> <value>...`);
      if (['name', 'files', 'created_at'].includes(key.split('.')[0])) die(`'${key}' is managed by the registry`);
      const p = load(name);
      if (cmd === 'set') setPath(p, key, parseVal(vals.join(' ')));
      else {
        const cur = asList(getPath(p, key));
        const v = vals.map(parseVal);
        setPath(p, key, cmd === 'add' ? [...cur, ...v.filter((x) => !cur.includes(x))] : cur.filter((x) => !v.includes(x)));
      }
      const errs = problems(loadAll().map((x) => (x.name === name ? p : x)));
      if (errs.length) die(`refused:\n- ${errs.join('\n- ')}`, 4);
      save(p);
      return out({ updated: name, key, value: getPath(p, key) });
    }
    case 'bind': {
      const p = load(o._[0]);
      if (!o.link) die('bind needs --link');
      p.link = o.link;
      if (o.desktop) p.session = { ...(p.session || {}), desktop: o.desktop };
      if (o.transcript) p.session = { ...(p.session || {}), transcript: o.transcript };
      p.files = runtimeFiles(p.name, o.link);
      if (p.decisions) p.decisions.queue = p.files.decisions;
      const errs = problems(loadAll().map((x) => (x.name === p.name ? p : x)));
      if (errs.length) die(`refused:\n- ${errs.join('\n- ')}`, 4);
      save(p);
      return out({ bound: p.name, link: p.link, files: p.files });
    }
    case 'paths': { const p = load(o._[0]); return out({ ...p.files, prefs_abs: prefsPath(p.name) }); }
    case 'render-prefs': {
      const p = load(o._[0]);
      const file = prefsPath(p.name);
      const body = `# Rendered by super-conductor-registry.mjs render-prefs ${p.name}. Do not edit:\n# change the profile (${p.name}.yaml) or the owner-wide base file instead.\n${emitYaml(renderPrefs(p))}\n`;
      fs.mkdirSync(REG, { recursive: true });
      const tmp = `${file}.tmp-${process.pid}`;
      fs.writeFileSync(tmp, body);
      replaceFile(tmp, file);
      return out(file);
    }
    case 'route': {
      const r = route(loadAll(), { session: o.session, company: o.company, channel: o.channel, group: o.group, title: o.title, text: o.text, from: o.from });
      out(r);
      if (!r.owner) process.exitCode = 5;
      return;
    }
    case 'claim': case 'release': {
      const name = o._[0];
      load(name);
      if (!o.session) die(`${cmd} needs --session <local_id>`);
      return withLockSync(CLAIMS, () => {
        const c = readClaims();
        c.claims = c.claims || {};
        const held = c.claims[o.session];
        if (cmd === 'claim') {
          if (held && held.conductor !== name) { out({ refused: true, session: o.session, held_by: held.conductor, since: held.at }); process.exitCode = 4; return; }
          const target = loadAll().find((p) => p.name !== name && (p.session?.desktop === o.session || p.decisions?.desk_session === o.session));
          if (target) { out({ refused: true, session: o.session, reason: `${o.session} is conductor ${target.name} or its desk` }); process.exitCode = 4; return; }
          const excl = load(name);
          if (asList(excl.scope?.not_watching_sessions).includes(o.session)) { out({ refused: true, session: o.session, reason: `${name} lists it under not_watching_sessions` }); process.exitCode = 4; return; }
          c.claims[o.session] = { conductor: name, at: held?.at || now(), note: o.note || held?.note || null };
        } else {
          if (held && held.conductor !== name) { out({ refused: true, session: o.session, held_by: held.conductor }); process.exitCode = 4; return; }
          delete c.claims[o.session];
        }
        c.updated_at = now();
        writeClaims(c);
        out({ [cmd === 'claim' ? 'claimed' : 'released']: o.session, conductor: name });
      });
    }
    case 'claims': return out(readClaims());
    case 'validate': {
      const all = loadAll();
      const errs = problems(all);
      const scoped = o._[0] ? errs.filter((e) => e.includes(o._[0])) : errs;
      out({ ok: !scoped.length, conductors: all.map((p) => p.name), problems: scoped });
      if (scoped.length) process.exitCode = 1;
      return;
    }
    case 'delete': {
      const name = o._[0];
      load(name);
      if (!o.yes) die(`delete removes ${rel(profilePath(name))} and its rendered prefs and claims; state files stay. Re-run with --yes.`);
      for (const f of [profilePath(name), prefsPath(name)]) { try { fs.unlinkSync(f); } catch { /* gone */ } }
      withLockSync(CLAIMS, () => {
        const c = readClaims();
        let n = 0;
        for (const [sid, v] of Object.entries(c.claims || {})) if (v.conductor === name) { delete c.claims[sid]; n++; }
        if (n) { c.updated_at = now(); writeClaims(c); }
      });
      return out({ deleted: name });
    }
    default:
      die('usage: list | show <name> | questions | resolve [<name>] [--session <id>] | create --answers <file|-> [--dry-run] | set|add|remove <name> <key> <value>... | bind <name> --link <id> | paths <name> | render-prefs <name> | route [...] | claim|release <name> --session <id> | claims | validate [<name>] | delete <name> --yes');
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main(process.argv.slice(2));
