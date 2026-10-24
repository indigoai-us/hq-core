#!/usr/bin/env node
// super-conductor-prefs.mjs — read and extend the owner's /super-conductor
// preferences in personal/settings/super-conductor.yaml.
//
// The settings file is a personal extension layer over the core skill's
// defaults. Every key in it is honored or carried through, including keys this
// release does not know yet. Writes only ever extend: adding to a list or
// setting one scalar touches that key's lines and nothing else (comments,
// order, and every other key stay byte-for-byte), and a write that would change
// any other key is refused.
//
// Usage:
//   node core/scripts/super-conductor-prefs.mjs [--file <yaml>] get
//       Resolved prefs as JSON: core defaults overlaid with the file. Unknown
//       keys are kept and listed in "_extension_keys".
//   node core/scripts/super-conductor-prefs.mjs [--file <yaml>] critical
//       Critical-channel settings as one line: "<critical_channels csv>\t<team
//       csv>\t<max_delay>" (see DEFAULTS.critical_channels).
//   node core/scripts/super-conductor-prefs.mjs [--file <yaml>] channels
//       Swept channels as CSV, always starting with "sessions".
//   node core/scripts/super-conductor-prefs.mjs [--file <yaml>] exclude
//       hq_channels_exclude as CSV: HQ channel slugs or ids the watcher and
//       the hq_channels sweep never read (trimmed, lowercased).
//   node core/scripts/super-conductor-prefs.mjs [--file <yaml>] interval [--at <iso>]
//       The heartbeat cadence for that moment (default now) from the work-day
//       schedule: "<seconds> present" inside work_hours, "<seconds> away"
//       outside them, using watch_interval.present / watch_interval.away.
//   node core/scripts/super-conductor-prefs.mjs [--file <yaml>] cadence
//       Per-channel sweep cadence as JSON: {constant: [...], hourly: [...],
//       hourly_seconds}. Constant channels are swept on every wakeup; hourly
//       channels only when their last sweep is older than hourly_seconds.
//   node core/scripts/super-conductor-prefs.mjs [--file <yaml>] add <key> <value>...
//       Append values to a top-level list key (created when missing). Values
//       already present are skipped.
//   node core/scripts/super-conductor-prefs.mjs [--file <yaml>] set <key>[.<subkey>] <value>
//       Set one scalar, top level or one level under a map
//       (for example watch_interval.present).
//
// The file defaults to $SC_PREFS_FILE, else <HQ root>/personal/settings/super-conductor.yaml.
// Exit: 0 ok, 2 bad arguments, 3 refused write or unreadable file.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { replaceFile } from './lib/super-conductor-lock.mjs';

const ROOT = process.env.HQ_ROOT || path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
let file = process.env.SC_PREFS_FILE || path.join(ROOT, 'personal/settings/super-conductor.yaml');
const argv = process.argv.slice(2);
if (argv[0] === '--file') {
  file = argv[1] || '';
  argv.splice(0, 2);
}
const [cmd, ...args] = argv;

// Keys the core skill knows. Anything else in the file is an owner extension:
// kept, returned by `get`, and never dropped by a write.
// work_hours: when the owner counts as present. timezone defaults to this
// machine's zone; days is a list (mon, tue, ...) or a range string ("mon-fri").
const DEFAULTS = {
  channels: ['hq_dms'],
  watch_interval: { present: 60, away: 1500 },
  work_hours: { timezone: null, days: 'mon-fri', start: '09:00', end: '18:00' },
  // Constant channels are swept on every wakeup (and wake it early when a
  // watcher covers them); hourly channels at most once an hour. A channel in
  // neither list is constant.
  channel_cadence: {
    constant: ['sessions', 'hq_dms', 'slack'],
    hourly: ['email', 'hq_channels', 'github', 'x', 'teammates'],
    hourly_seconds: 3600,
  },
  surface: 'needs_attention',
  // Critical channels: messages there bypass the watcher's wake gap and the
  // away cadence, get a `SUPER-CONDUCTOR CRITICAL` line within critical_wake
  // .max_delay seconds, and a `priority: critical` ledger row the wakeup
  // reads first. Entries: `hq_channel:<slug or channel id>` and
  // `hq_dm:team` (person-to-person HQ DMs from anyone in `team`).
  critical_channels: [],
  team: [],
  critical_wake: { max_delay: 60 },
  // HQ channels (slug or channel id) the message watcher and the hq_channels
  // sweep never read, name, or count as unswept.
  hq_channels_exclude: [],
};
const KNOWN = new Set([
  'channels', 'watch_interval', 'work_hours', 'channel_cadence', 'slack_watch', 'surface', 'slack_workspaces', 'slack_channels',
  'slack_workspace_companies',
  'hq_channels', 'email_accounts', 'company', 'github_org', 'teammates',
  'critical_channels', 'team', 'critical_wake', 'hq_channels_exclude',
]);
const KEY_RE = /^([A-Za-z_][\w-]*):(.*)$/;

function die(msg, code) {
  process.stderr.write(`super-conductor-prefs: ${msg}\n`);
  process.exit(code);
}

function stripComment(s) {
  let quote = null;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (quote) { if (ch === quote) quote = null; continue; }
    if (ch === '"' || ch === "'") { quote = ch; continue; }
    if (ch === '#' && (i === 0 || s[i - 1] === ' ' || s[i - 1] === '\t')) return s.slice(0, i).trim();
  }
  return s.trim();
}

function scalar(raw) {
  const s = raw.trim();
  if (s.length >= 2 && s[0] === s[s.length - 1] && (s[0] === '"' || s[0] === "'")) {
    return s[0] === '"' ? JSON.parse(s) : s.slice(1, -1);
  }
  if (/^-?\d+$/.test(s)) return Number(s);
  if (s === 'true' || s === 'false') return s === 'true';
  if (s === '' || s === 'null' || s === '~') return null;
  if (s.startsWith('[') && s.endsWith(']')) {
    const inner = s.slice(1, -1).trim();
    return inner ? inner.split(',').map(scalar) : [];
  }
  if (s.startsWith('{') && s.endsWith('}')) {
    const inner = s.slice(1, -1).trim();
    const out = {};
    if (inner) for (const part of inner.split(',')) {
      const k = part.indexOf(':');
      out[part.slice(0, k).trim()] = scalar(part.slice(k + 1));
    }
    return out;
  }
  return s;
}

// YAML subset: maps, block and flow lists, lists of maps, nesting by indent,
// comments. Enough for this settings file; anything it cannot read is still
// kept on disk because writes never rewrite other keys' lines.
function parse(text) {
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
        const itemIndent = base + 2;
        i++;
        const m = rest.match(KEY_RE);
        if (m && !rest.startsWith('"') && !rest.startsWith("'")) {
          const obj = {};
          obj[m[1]] = m[2].trim() ? scalar(m[2]) : block(itemIndent + 1);
          if (i < rows.length && rows[i].indent >= itemIndent && !rows[i].body.startsWith('- ')) {
            Object.assign(obj, block(rows[i].indent));
          }
          list.push(obj);
        } else {
          list.push(rest ? scalar(rest) : block(itemIndent));
        }
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
  const data = block(0);
  return data && !Array.isArray(data) ? data : {};
}

function readText() {
  try { return fs.readFileSync(file, 'utf8'); } catch (e) {
    if (e.code === 'ENOENT') return '';
    die(`cannot read ${file}: ${e.message}`, 3);
  }
}

function resolved() {
  const data = parse(readText());
  const out = structuredClone(DEFAULTS);
  for (const [k, v] of Object.entries(data)) {
    const d = out[k];
    out[k] = d && typeof d === 'object' && !Array.isArray(d) && v && typeof v === 'object' && !Array.isArray(v)
      ? { ...d, ...v } : v;
  }
  // A free-text channel_cadence (an owner note) keeps the default lists and is
  // carried as _channel_cadence_note.
  if (!out.channel_cadence || typeof out.channel_cadence !== 'object' || Array.isArray(out.channel_cadence)) {
    if (out.channel_cadence != null) out._channel_cadence_note = String(out.channel_cadence);
    out.channel_cadence = structuredClone(DEFAULTS.channel_cadence);
  }
  // Lists may be YAML lists or comma-separated strings; normalize once here so
  // every reader (cadence, sweep-check) sees the same arrays. A channel the
  // owner lists as constant leaves the default hourly list even when the owner
  // did not restate `hourly`; an explicit hourly list wins over constant.
  {
    const c = out.channel_cadence;
    const own = data.channel_cadence && typeof data.channel_cadence === 'object' && !Array.isArray(data.channel_cadence) ? data.channel_cadence : {};
    const list = (v) => (Array.isArray(v) ? v : String(v ?? '').split(',')).map((x) => String(x).trim()).filter(Boolean);
    let hourly = list(c.hourly);
    const constant = list(c.constant);
    if (own.constant != null && own.hourly == null) hourly = hourly.filter((x) => !constant.includes(x));
    c.hourly = hourly;
    c.constant = constant.filter((x) => !hourly.includes(x));
  }
  // A YAML list or a comma-separated string; one lowercased slug or id each.
  out.hq_channels_exclude = excludeList(out.hq_channels_exclude);
  out._extension_keys = Object.keys(data).filter((k) => !KNOWN.has(k)).sort();
  out._file = file;
  return out;
}

function excludeList(v) {
  const raw = Array.isArray(v) ? v : typeof v === 'string' && v ? v.split(',') : [];
  return [...new Set(raw.map((x) => String(x ?? '').trim().toLowerCase()).filter(Boolean))];
}

const fmt = (v) => (/^[A-Za-z0-9@._/+-]+$/.test(String(v)) ? String(v) : JSON.stringify(String(v)));
const isTopKey = (line) => KEY_RE.test(line);
const isCont = (line) => !line.trim() || /^[ \t]/.test(line) || line.trimStart().startsWith('#');

// [key line index, end index exclusive] of a top-level key, or null.
function blockRange(lines, key) {
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(KEY_RE);
    if (m && m[1] === key) {
      let j = i + 1;
      while (j < lines.length && isCont(lines[j])) j++;
      // Trailing blank and comment lines belong to the next key.
      while (j > i + 1 && (!lines[j - 1].trim() || lines[j - 1].trimStart().startsWith('#'))) j--;
      return [i, j];
    }
  }
  return null;
}

function splitTail(line) {
  const idx = line.indexOf(' #');
  return idx === -1 ? '' : `  ${line.slice(idx + 1).trim()}`;
}

function appendBlock(text, block) {
  let t = text;
  if (t && !t.endsWith('\n')) t += '\n';
  if (t.trim()) t += '\n';
  return t + block;
}

const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

function writeChecked(beforeText, afterText, changedKey) {
  const before = parse(beforeText);
  const after = parse(afterText);
  for (const k of new Set([...Object.keys(before), ...Object.keys(after)])) {
    if (k !== changedKey && !same(before[k], after[k])) {
      die(`refused: the write would change '${k}' as well as '${changedKey}'`, 3);
    }
  }
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = path.join(path.dirname(file), `.super-conductor-prefs.${process.pid}`);
  fs.writeFileSync(tmp, afterText);
  try { fs.chmodSync(tmp, fs.statSync(file).mode & 0o777); } catch { /* new file */ }
  replaceFile(tmp, file);
  return after;
}

function cmdAdd(key, values) {
  if (!KEY_RE.test(`${key}:`)) die(`bad key '${key}'`, 2);
  const text = readText();
  const current = parse(text)[key];
  if (current != null && !Array.isArray(current)) die(`refused: '${key}' is not a list; use set`, 3);
  const have = current || [];
  const added = values.filter((v) => !have.map(String).includes(String(v)));
  if (!added.length) {
    process.stdout.write(`${JSON.stringify({ key, added: [], value: have })}\n`);
    return;
  }
  let next;
  const lines = text.replace(/\n$/, '').split('\n');
  const rng = text ? blockRange(lines, key) : null;
  if (!rng) {
    next = appendBlock(text, `${key}:\n${added.map((v) => `  - ${fmt(v)}\n`).join('')}`);
  } else {
    const [i, j] = rng;
    const rest = stripComment(lines[i].match(KEY_RE)[2]);
    if (rest.startsWith('[')) {
      lines[i] = `${key}: [${[...have, ...added].map(fmt).join(', ')}]${splitTail(lines[i])}`;
    } else {
      let last = i;
      let indent = '  ';
      for (let n = i + 1; n < j; n++) {
        if (stripComment(lines[n]).startsWith('- ')) { last = n; indent = lines[n].match(/^\s*/)[0]; }
      }
      lines.splice(last + 1, 0, ...added.map((v) => `${indent}- ${fmt(v)}`));
    }
    next = `${lines.join('\n')}\n`;
  }
  const after = writeChecked(text, next, key);
  process.stdout.write(`${JSON.stringify({ key, added, value: after[key] })}\n`);
}

function cmdSet(dotted, value) {
  const parts = dotted.split('.');
  if (parts.length > 2 || !parts.every((p) => KEY_RE.test(`${p}:`))) die(`bad key '${dotted}' (use key or key.subkey)`, 2);
  const [key, sub] = parts;
  const text = readText();
  const current = parse(text)[key];
  const lines = text.replace(/\n$/, '').split('\n');
  const rng = text ? blockRange(lines, key) : null;
  let next;
  if (!sub) {
    if (current && typeof current === 'object') die(`refused: '${key}' is a list or map; use add or ${key}.<subkey>`, 3);
    if (!rng) next = appendBlock(text, `${key}: ${fmt(value)}\n`);
    else {
      lines[rng[0]] = `${key}: ${fmt(value)}${splitTail(lines[rng[0]])}`;
      next = `${lines.join('\n')}\n`;
    }
  } else {
    if (current != null && (typeof current !== 'object' || Array.isArray(current))) die(`refused: '${key}' is not a map`, 3);
    if (!rng) next = appendBlock(text, `${key}:\n  ${sub}: ${fmt(value)}\n`);
    else {
      const [i, j] = rng;
      let hit = -1;
      for (let n = i + 1; n < j; n++) {
        const m = lines[n].match(/^(\s+)([\w-]+):/);
        if (m && m[2] === sub) { hit = n; break; }
      }
      if (hit >= 0) {
        const indent = lines[hit].match(/^\s+/)[0];
        lines[hit] = `${indent}${sub}: ${fmt(value)}${splitTail(lines[hit])}`;
      } else {
        lines.splice(j, 0, `  ${sub}: ${fmt(value)}`);
      }
      next = `${lines.join('\n')}\n`;
    }
  }
  const after = writeChecked(text, next, key);
  process.stdout.write(`${JSON.stringify({ key: dotted, value: after[key] })}\n`);
}

const DAY_NAMES = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];

const FULL_DAY_NAMES = ['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday'];

// A day as its three-letter or full English name ("mon", "monday"); anything
// else ("monkey", "mo") is refused.
function dayIndex(name) {
  const n = String(name).trim().toLowerCase();
  let i = DAY_NAMES.indexOf(n);
  if (i === -1) i = FULL_DAY_NAMES.indexOf(n);
  if (i === -1) die(`work_hours.days: unknown day '${name}' (use mon..sun or monday..sunday)`, 3);
  return i;
}

// Set of weekday indexes (0 = Sunday) from a list or "mon-fri" / "mon,wed".
export function workDays(days) {
  const parts = Array.isArray(days) ? days.map(String) : String(days ?? 'mon-fri').split(',');
  const out = new Set();
  for (const raw of parts) {
    const part = raw.trim();
    if (!part) continue;
    const [a, b] = part.split('-');
    if (b === undefined) { out.add(dayIndex(a)); continue; }
    for (let i = dayIndex(a), n = 0; n < 7; i = (i + 1) % 7, n++) {
      out.add(i);
      if (i === dayIndex(b)) break;
    }
  }
  return out;
}

// HH:MM from 00:00 to 23:59; 24:00 is accepted as an end of day only.
function minutesOf(hhmm, field) {
  const m = /^(\d{1,2}):(\d{2})$/.exec(String(hhmm).trim());
  const h = m ? Number(m[1]) : NaN;
  const min = m ? Number(m[2]) : NaN;
  const ok = m && min <= 59 && (h <= 23 || (field === 'end' && h === 24 && min === 0));
  if (!ok) die(`work_hours.${field} must be HH:MM between 00:00 and 23:59${field === 'end' ? ' (or 24:00)' : ''}, got '${hhmm}'`, 3);
  return h * 60 + min;
}

// {present: bool, timezone} for an instant under the work_hours schedule.
// An end before the start wraps past midnight (for example 20:00-04:00).
export function isWorkTime(workHours, at) {
  if (workHours != null && (typeof workHours !== 'object' || Array.isArray(workHours))) {
    die(`work_hours must be a map (timezone, days, start, end), got '${workHours}'`, 3);
  }
  const wh = workHours || {};
  let tz = wh.timezone || Intl.DateTimeFormat().resolvedOptions().timeZone;
  let fmt;
  try {
    fmt = new Intl.DateTimeFormat('en-US', { timeZone: tz, weekday: 'short', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
  } catch {
    die(`work_hours.timezone: unknown time zone '${tz}'`, 3);
  }
  const parts = Object.fromEntries(fmt.formatToParts(at).map((p) => [p.type, p.value]));
  const day = dayIndex(parts.weekday);
  const now = Number(parts.hour) * 60 + Number(parts.minute);
  const start = minutesOf(wh.start ?? '09:00', 'start');
  const end = minutesOf(wh.end ?? '18:00', 'end');
  if (start === end) die(`work_hours.start and work_hours.end are both ${wh.start ?? '09:00'}; an empty window would never be present`, 3);
  const days = workDays(wh.days);
  let present;
  if (start <= end) present = days.has(day) && now >= start && now < end;
  // Overnight shift: the late part belongs to today, the early part to yesterday.
  else present = (days.has(day) && now >= start) || (days.has((day + 6) % 7) && now < end);
  return { present, timezone: tz };
}

switch (cmd) {
  case 'get':
    process.stdout.write(`${JSON.stringify(resolved(), null, 2)}\n`);
    break;
  case 'channels': {
    let chans = resolved().channels || [];
    if (typeof chans === 'string') chans = chans.split(',').map((c) => c.trim());
    process.stdout.write(`${['sessions', ...chans.map(String).filter((c) => c && c !== 'sessions')].join(',')}\n`);
    break;
  }
  case 'interval': {
    let at = new Date();
    if (args[0] === '--at') {
      at = new Date(args[1] || '');
      if (Number.isNaN(at.getTime())) die(`interval: bad --at '${args[1]}'`, 2);
    } else if (args.length) die('usage: interval [--at <iso>]', 2);
    const p = resolved();
    const { present } = isWorkTime(p.work_hours, at);
    const wi = p.watch_interval || {};
    // Whole seconds: the heartbeat accepts only integers.
    const pick = (v, d) => (Number.isFinite(Number(v)) && Number(v) > 0 ? Math.max(1, Math.round(Number(v))) : d);
    const secs = present ? pick(wi.present, DEFAULTS.watch_interval.present) : pick(wi.away, DEFAULTS.watch_interval.away);
    process.stdout.write(`${secs} ${present ? 'present' : 'away'}\n`);
    break;
  }
  case 'critical': {
    // "<critical_channels csv>\t<team csv>\t<max_delay seconds>" for the
    // heartbeat to pass to the watcher. Empty fields when unset.
    const p = resolved();
    // An unquoted `- hq_channel:slug` parses as a one-key map; render it back.
    const item = (x) => (x && typeof x === 'object' && !Array.isArray(x) ? Object.entries(x).map(([k, v]) => `${k}:${v ?? ''}`).join(',') : String(x ?? ''));
    const list = (v) => (Array.isArray(v) ? v : typeof v === 'string' && v ? v.split(',') : []).map((x) => item(x).trim()).filter(Boolean);
    const cw = p.critical_wake && typeof p.critical_wake === 'object' ? p.critical_wake : {};
    const delay = Number(cw.max_delay);
    process.stdout.write(`${list(p.critical_channels).join(',')}\t${list(p.team).join(',')}\t${Number.isFinite(delay) && delay >= 10 ? Math.round(delay) : 60}\n`);
    break;
  }
  case 'exclude':
    process.stdout.write(`${resolved().hq_channels_exclude.join(',')}\n`);
    break;
  case 'cadence': {
    const c = resolved().channel_cadence;
    const { hourly, constant } = c;
    const secs = Number(c.hourly_seconds);
    process.stdout.write(`${JSON.stringify({ constant, hourly, hourly_seconds: Number.isFinite(secs) && secs > 0 ? secs : 3600 })}\n`);
    break;
  }
  case 'add':
    if (args.length < 2) die('usage: add <key> <value>...', 2);
    cmdAdd(args[0], args.slice(1));
    break;
  case 'set':
    if (args.length !== 2) die('usage: set <key>[.<subkey>] <value>', 2);
    cmdSet(args[0], args[1]);
    break;
  default:
    die(`usage: get | channels | interval | cadence | critical | exclude | add <key> <value>... | set <key>[.<subkey>] <value>${cmd ? ` (unknown command '${cmd}')` : ''}`, 2);
}
