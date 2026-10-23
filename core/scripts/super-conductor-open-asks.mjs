#!/usr/bin/env node
// super-conductor-open-asks.mjs — find sessions that ended their turn waiting
// on the owner, so /super-conductor can bring the decision to the owner.
//
// A session is waiting when its transcript ends on either:
//   - an AskUserQuestion picker with no tool_result (unanswered), or
//   - a desktop next-step box: a mcp__ccd_turn__wrap_up call with `ask`, with
//     no owner message, conductor relay, or further tool work after it.
// `list_events` does not show tool inputs, so the conductor cannot see these
// boxes any other way; a box can otherwise sit for hours unseen.
//
// What counts as an answer after the ask:
//   - a turn the owner typed (turnOrigin "human", or a plain user text entry in
//     older transcripts without turnOrigin);
//   - a cross-session message from one of the --conductor ids (the conductor
//     relaying the owner's answer);
//   - for a picker, its tool_result.
// Harness entries (system reminders, task notifications, hook feedback, meta
// entries, cross-session messages from other sessions) do not answer anything.
//
// Usage:
//   node core/scripts/super-conductor-open-asks.mjs --company <csv> [--dir <transcripts dir>]...
//       [--max-age-hours <h>] [--conductor <local_id>]... [--exclude <session uuid>]...
//       [--state <asks file>] [--now <iso>]
// Prints one JSON object per waiting session:
//   {session, title, ask_id, kind: "picker"|"card", question, actions, asked_at, age_minutes}
// --dir (repeatable) defaults to every ~/.claude/projects folder for the HQ
// root: <HQ root with every non-alphanumeric as -> (the folder name Claude Code
// uses for a project's transcripts) and the folders that start with it, which
// hold sessions running in worktrees under the root.
//
// The session id is the transcript's file name. Only the last 2 MB of each
// transcript is read (an open ask is always near the end), plus any session
// title lines from its first 256 KB.
//
// --company: the conductor's locked company set (`hq-session.sh get
// company_slugs`); required, or --session-companies to read it from
// hq-session.sh directly. A transcript is read only when its session's
// meta.yaml (workspace/sessions/<id>/) puts every one of its companies inside
// that set; a session with no meta is skipped unread.
//
// --state: the asks file. An ask (session + ask_id) already recorded there is
// not printed again, so it is queued once.
//
//   node core/scripts/super-conductor-open-asks.mjs mark --state <asks file>
//       --session <id> --ask-id <id> --status queued|relayed
// Records an ask. Exit 0 when the ask moved to this status (queue it, or send
// the relay, now); exit 3 when it is already at this status or later, so the
// owner is asked once and the session gets one relay. Entries older than 7 days
// are dropped on each write. `--question <text>` and `--title <text>` are kept
// on the entry so a queued ask can be re-asked after a compaction without
// reading the transcript again.
//   node core/scripts/super-conductor-open-asks.mjs check --session <id> --ask-id <id> [--dir <d>]...
// Exit 0 and print {"answered_at"} when that ask has a tool_result or a later
// owner turn in its own transcript (the owner answered it there), 3 while it
// is open, 2 when the transcript is missing. Run it before every picker or
// relay for an OPEN-ASK: an ask answered in its source window is dropped, and
// `watch` closes such queued asks itself with one ASK-ANSWERED line:
//   SUPER-CONDUCTOR ASK-ANSWERED <iso> | <title> answered its own picker at <iso> | ask_id <id> | <hint>.
//   node core/scripts/super-conductor-open-asks.mjs queued --state <asks file>
// Prints every ask recorded `queued` (one JSON line each, oldest first): the
// list to re-ask after a compact or resume.
//
// A queued ask with no relay after 10 minutes (SC_ASK_STALE_MINUTES) may be
// lost (a compaction mid-picker, an interrupted turn) or may still be on the
// owner's open picker. `list` prints it again with `stale: true`, and `watch`
// announces it again exactly once (the conductor ignores the line when the
// ask is still on its open picker, and re-asks it otherwise), so a question
// is never dropped and an away owner is not woken every ten minutes.
//   node core/scripts/super-conductor-open-asks.mjs watch --company <csv> --seen <file>
//       [--state <asks file>] [--interval <s>] [--parent-pid <pid>] [--once] [list options]
// The heartbeat's open-ask wake. Every --interval seconds (default 60) it lists
// open asks as above and prints one line per ask it has not announced before:
//   SUPER-CONDUCTOR OPEN-ASK <iso> | <title> (session <id>, card|picker, <n>m) asks: "<question>" [<buttons>] | ask_id <id> | <hint>.
// Announced asks are kept in --seen, so a restart does not repeat them; asks
// recorded in --state (queued or relayed) are never announced. Only
// transcripts whose size or mtime changed are read again. Exits at the next
// poll once --parent-pid is gone.
// Exit: 0 (also when nothing is waiting), 2 on bad arguments, 3 already recorded.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { replaceFile } from './lib/super-conductor-lock.mjs';
import { isMain, makeScope, parseCompanies, sessionCompanySlugs, sessionInScope } from './lib/super-conductor-scope.mjs';

const ROOT = process.env.HQ_ROOT || path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const WRAP_UP = /(^|__)wrap_up$/;
// answered_in_source: the owner answered the picker in the source window
// before the conductor asked or relayed; it is closed, never asked, never
// relayed.
const STATUS_RANK = { queued: 1, relayed: 2, answered_in_source: 2 };
const STALE_MS = (Number(process.env.SC_ASK_STALE_MINUTES) > 0 ? Number(process.env.SC_ASK_STALE_MINUTES) : 10) * 60e3;
const KEEP_MS = 7 * 24 * 3600e3;
const TAIL_BYTES = 2 * 1024 * 1024;
const HEAD_BYTES = 256 * 1024;

function die(msg) {
  process.stderr.write(`super-conductor-open-asks: ${msg}\n`);
  process.exit(2);
}

// Claude Code names a project's transcript folder after its path with every
// character outside [A-Za-z0-9] replaced by '-' (slashes, dots, spaces,
// underscores, and Windows drive colons and backslashes alike).
export function projectDirName(root) {
  return String(root).replace(/[^A-Za-z0-9]/g, '-');
}

function parseArgs(argv) {
  const o = {
    maxAgeH: 24, dirs: [], conductors: [], exclude: [], companies: [], now: Date.now(),
    interval: 60, once: false, hint: 'Queue it with /decision-queue now (mark it queued first)',
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const val = () => { const v = argv[++i]; if (v === undefined) die(`${a} needs a value`); return v; };
    if (a === '--dir') o.dirs.push(val());
    else if (a === '--max-age-hours') o.maxAgeH = Number(val());
    else if (a === '--conductor') o.conductors.push(val());
    else if (a === '--exclude') o.exclude.push(val());
    else if (a === '--now') o.now = Date.parse(val());
    else if (a === '--company') o.companies.push(val());
    else if (a === '--session-companies') o.fromSession = true;
    else if (a === '--state') o.state = val();
    else if (a === '--seen') o.seen = val();
    else if (a === '--interval') o.interval = Number(val());
    else if (a === '--parent-pid') o.parentPid = Number(val());
    else if (a === '--once') o.once = true;
    else if (a === '--hint') o.hint = val();
    else die(`unknown argument ${a}`);
  }
  try {
    if (o.fromSession) o.companies.push(...sessionCompanySlugs(ROOT));
    o.companies = parseCompanies(o.companies);
  } catch (e) { die(e.message); }
  if (!Number.isFinite(o.maxAgeH) || o.maxAgeH <= 0) die('--max-age-hours must be a positive number');
  if (!Number.isFinite(o.now)) die('--now must be an ISO time');
  if (!Number.isFinite(o.interval) || o.interval < 1) die('--interval must be a positive number of seconds');
  if (!o.dirs.length) o.dirs = defaultDirs();
  return o;
}

// The HQ root's transcript folder and its worktree sessions' folders.
function defaultDirs() {
  const base = path.join(os.homedir(), '.claude', 'projects');
  const slug = projectDirName(ROOT);
  let names = [];
  try { names = fs.readdirSync(base); } catch { /* no transcripts yet */ }
  return names.filter((n) => n === slug || n.startsWith(`${slug}-`)).map((n) => path.join(base, n));
}

// The last TAIL_BYTES of a transcript, split into lines, with the title lines
// from its head prepended. A cut first line fails to parse and is skipped.
export function readTranscript(file, size = fs.statSync(file).size) {
  const fd = fs.openSync(file, 'r');
  try {
    const start = Math.max(0, size - TAIL_BYTES);
    const buf = Buffer.alloc(size - start);
    fs.readSync(fd, buf, 0, buf.length, start);
    const lines = buf.toString('utf8').split('\n');
    if (start > 0) {
      const head = Buffer.alloc(Math.min(HEAD_BYTES, start));
      fs.readSync(fd, head, 0, head.length, 0);
      lines.unshift(...head.toString('utf8').split('\n').filter((l) => l.includes('"customTitle"')));
    }
    return lines;
  } finally {
    fs.closeSync(fd);
  }
}

// Text of a user entry, with leading <system-reminder> blocks removed.
function userText(entry) {
  const c = entry.message && entry.message.content;
  let t = '';
  if (typeof c === 'string') t = c;
  else if (Array.isArray(c)) t = c.filter((b) => b.type === 'text').map((b) => b.text).join('\n');
  return t.replace(/^(\s*<system-reminder>[\s\S]*?<\/system-reminder>)+/, '').trim();
}

// Does this user entry answer an open ask? See the header for the rules.
export function isAnswer(entry, conductors) {
  if (entry.type !== 'user') return false;
  const text = userText(entry);
  // Two relay shapes: the message as the turn's prompt, or a peer entry
  // (isMeta, turnOrigin "peer") prefixed "Another Claude session sent a message:".
  const relay = /^(?:Another Claude session sent a message:\s*)?<cross-session-message from="([^"]+)"/.exec(text);
  if (relay) return conductors.has(relay[1]);
  if (entry.isMeta) return false;
  if (entry.turnOrigin) return entry.turnOrigin === 'human';
  return text.length > 0 && !text.startsWith('<');
}

// The open ask at the end of a transcript, or null.
export function openAsk(lines, conductors, session = '') {
  let open = null;
  let title = '';
  const answered = new Set();
  for (const line of lines) {
    let x;
    try { x = JSON.parse(line); } catch { continue; }
    if (x.customTitle) title = x.customTitle;
    if (isAnswer(x, conductors)) { open = null; continue; }
    const c = x.message && x.message.content;
    if (!Array.isArray(c)) continue;
    for (const b of c) {
      if (b.type === 'tool_result') {
        answered.add(b.tool_use_id);
        if (open && open.kind === 'picker' && open.id === b.tool_use_id) open = null;
      }
      if (b.type !== 'tool_use') continue;
      if (b.name === 'AskUserQuestion') {
        const q = b.input && b.input.questions && b.input.questions[0];
        open = { kind: 'picker', id: b.id, asked_at: x.timestamp, question: q ? q.question : '', actions: q && q.options ? q.options.map((o) => o.label) : [] };
      } else if (WRAP_UP.test(b.name)) {
        open = b.input && b.input.ask
          ? { kind: 'card', id: b.id, asked_at: x.timestamp, question: b.input.ask, actions: (b.input.actions || []).map((a) => a.label || a.action) }
          : null;
      } else if (open && open.kind === 'card') {
        // The session kept working after the box, so the box is not what it is waiting on.
        open = null;
      }
    }
  }
  if (!open || (open.kind === 'picker' && answered.has(open.id))) return null;
  const { id, ...rest } = open;
  return { session, title, ask_id: id, ...rest };
}

// When the ask with this id was answered in its own transcript: the picker's
// tool_result time, or the first owner turn (or conductor relay) after the
// ask. Null while it is still open.
export function answeredAt(lines, askId, conductors = new Set()) {
  let askedAt = null;
  let picker = false;
  for (const line of lines) {
    let x;
    try { x = JSON.parse(line); } catch { continue; }
    const c = x.message && x.message.content;
    if (askedAt && isAnswer(x, conductors)) return x.timestamp || askedAt;
    if (!Array.isArray(c)) continue;
    for (const b of c) {
      if (b.type === 'tool_use' && b.id === askId) { askedAt = x.timestamp || 'asked'; picker = b.name === 'AskUserQuestion'; }
      // A picker's tool_result is the owner's click. A next-step card's
      // tool_result is immediate and says nothing; only a later owner turn or
      // conductor relay answers a card.
      if (askedAt && picker && b.type === 'tool_result' && b.tool_use_id === askId) return x.timestamp || askedAt;
    }
  }
  return null;
}

// Transcript file for a session id across the transcript dirs, or null.
function transcriptOf(dirs, sid) {
  for (const dir of dirs) {
    const f = path.join(dir, `${sid}.jsonl`);
    if (fs.existsSync(f)) return f;
  }
  return null;
}

// `check --session <id> --ask-id <id> [--dir ...]`: exit 0 and print
// {"answered_at"} when the ask is answered in its source transcript, 3 when it
// is still open, 2 when the transcript cannot be found. The conductor runs it
// right before opening a picker or sending a relay for an OPEN-ASK.
function checkCmd(argv) {
  // No --company here: the conductor already holds this ask (it came from a
  // session inside its set), and the check reads one named transcript.
  const o = { dirs: [], conductors: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const val = () => { const v = argv[++i]; if (v === undefined) die(`${a} needs a value`); return v; };
    if (a === '--session') o.session = val();
    else if (a === '--ask-id') o.askId = val();
    else if (a === '--dir') o.dirs.push(val());
    else if (a === '--conductor') o.conductors.push(val());
    else die(`check: unknown argument ${a}`);
  }
  if (!o.session || !o.askId) die('check needs --session and --ask-id');
  if (!/^[A-Za-z0-9._-]+$/.test(o.session)) die('check: --session must be a transcript id');
  if (!o.dirs.length) o.dirs = defaultDirs();
  const file = transcriptOf(o.dirs, o.session);
  if (!file) die(`check: no transcript for ${o.session}`);
  const sid = o.session;
  const askId = o.askId;
  const at = answeredAt(readTranscript(file), askId, new Set(o.conductors));
  if (!at) process.exit(3);
  process.stdout.write(`${JSON.stringify({ session: sid, ask_id: askId, answered_at: at })}\n`);
}

export const askKey = (session, askId) => `${session}:${askId}`;

export function loadAsks(file) {
  try {
    const s = JSON.parse(fs.readFileSync(file, 'utf8'));
    return s && typeof s.asks === 'object' && s.asks ? s : { asks: {} };
  } catch { return { asks: {} }; }
}

// Record an ask at `status`. Returns false when it is already there or later.
export function markAsk(state, session, askId, status, now = Date.now(), extra = {}) {
  const key = askKey(session, askId);
  const cur = state.asks[key];
  if (cur && (STATUS_RANK[cur.status] || 0) >= STATUS_RANK[status]) return false;
  const keep = {};
  for (const k of ['question', 'title']) {
    const v = extra[k] != null ? extra[k] : cur && cur[k];
    if (v) keep[k] = String(v).slice(0, 400);
  }
  state.asks[key] = { ...keep, status, at: new Date(now).toISOString(), session, ask_id: askId };
  for (const [k, v] of Object.entries(state.asks)) {
    if (now - Date.parse(v.at) > KEEP_MS) delete state.asks[k];
  }
  return true;
}

function saveAsks(file, state) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, `${JSON.stringify(state, null, 2)}\n`);
  replaceFile(tmp, file);
}

function mark(argv) {
  const o = {};
  for (let i = 0; i < argv.length; i += 2) {
    if (!['--state', '--session', '--ask-id', '--status', '--question', '--title'].includes(argv[i]) || argv[i + 1] === undefined) die(`mark: unexpected argument ${argv[i]}`);
    o[argv[i].slice(2)] = argv[i + 1];
  }
  if (!o.state || !o.session || !o['ask-id']) die('mark needs --state, --session and --ask-id');
  if (!STATUS_RANK[o.status]) die('mark: --status must be queued, relayed or answered_in_source');
  const state = loadAsks(o.state);
  if (!markAsk(state, o.session, o['ask-id'], o.status, Date.now(), { question: o.question, title: o.title })) {
    process.stdout.write(`already ${state.asks[askKey(o.session, o['ask-id'])].status}\n`);
    process.exit(3);
  }
  saveAsks(o.state, state);
  process.stdout.write(`${o.status}\n`);
}

// Every ask recorded `queued`, oldest first: what to re-ask after a resume.
function queued(argv) {
  const i = argv.indexOf('--state');
  if (i < 0 || argv[i + 1] === undefined) die('queued needs --state <asks file>');
  const asks = Object.values(loadAsks(argv[i + 1]).asks).filter((a) => a.status === 'queued');
  asks.sort((a, b) => Date.parse(a.at) - Date.parse(b.at));
  for (const a of asks) process.stdout.write(`${JSON.stringify(a)}\n`);
}

// A queued ask whose relay never came: re-ask it.
function isStale(rec, now) {
  return !!rec && rec.status === 'queued' && now - Date.parse(rec.at) > STALE_MS;
}

function transcriptFiles(o) {
  const files = [];
  for (const dir of o.dirs) {
    let names;
    try { names = fs.readdirSync(dir).filter((n) => n.endsWith('.jsonl')); } catch (e) {
      // An explicit --dir must exist; a default folder may not yet.
      if (process.argv.includes('--dir')) die(`cannot read ${dir}: ${e.message}`);
      continue;
    }
    for (const name of names) files.push(path.join(dir, name));
  }
  return files;
}

// Open asks across the transcripts, newest state. `cache` (file -> {mtimeMs,
// size, ask}) lets a watcher skip transcripts that did not change.
export function scan(o, scope, conductors, recorded, now, cache = null) {
  const out = [];
  for (const file of transcriptFiles(o)) {
    const sid = path.basename(file).replace(/\.jsonl$/, '');
    if (o.exclude.includes(sid)) continue;
    // The age check needs only the file's mtime, so it runs before the
    // session's meta.yaml is read.
    let st;
    try { st = fs.statSync(file); } catch { continue; }
    if (now - st.mtimeMs > o.maxAgeH * 3600e3) continue;
    // Company boundary: never open a transcript from outside the locked set.
    if (!sessionInScope(ROOT, sid, scope)) continue;
    let ask;
    const hit = cache && cache.get(file);
    if (hit && hit.mtimeMs === st.mtimeMs && hit.size === st.size) ask = hit.ask;
    else {
      // One unreadable transcript (permissions, deleted mid-scan) must not stop
      // the scan: skip it and say so once on stderr.
      try { ask = openAsk(readTranscript(file, st.size), conductors, sid); } catch (e) {
        process.stderr.write(`super-conductor-open-asks: skipped ${path.basename(file)}: ${e.code || e.message}\n`);
        continue;
      }
      if (cache) cache.set(file, { mtimeMs: st.mtimeMs, size: st.size, ask });
    }
    if (!ask) continue;
    const rec = recorded[askKey(ask.session, ask.ask_id)];
    if (rec && !isStale(rec, now)) continue;
    const at = Date.parse(ask.asked_at);
    out.push({ ...ask, age_minutes: Number.isFinite(at) ? Math.max(0, Math.round((now - at) / 60000)) : null, ...(rec ? { stale: true } : {}) });
  }
  return out;
}

// One line, no "|" (it separates the wake line's fields), clipped.
const clip = (t, n) => { const x = String(t || '').replace(/\s+/g, ' ').replace(/\|/g, '/').trim(); return x.length > n ? `${x.slice(0, n - 1)}…` : x; };

export function askLine(ask, hint, now = Date.now()) {
  const stamp = new Date(now).toISOString().replace(/\.\d+Z$/, 'Z');
  const who = clip(ask.title, 60) || ask.session;
  const age = ask.age_minutes == null ? '' : `, ${ask.age_minutes}m`;
  const buttons = (ask.actions || []).length ? ` [${ask.actions.map((a) => clip(a, 30)).join(' | ')}]` : '';
  const stale = ask.stale ? ' | stale: queued with no answer relayed; ask it again' : '';
  return `SUPER-CONDUCTOR OPEN-ASK ${stamp} | ${who} (session ${ask.session}, ${ask.kind}${age}) asks: "${clip(ask.question, 240)}"${buttons} | ask_id ${ask.ask_id}${stale} | ${hint}.`;
}

function loadSeen(file) {
  try { const j = JSON.parse(fs.readFileSync(file, 'utf8')); return j && typeof j.announced === 'object' && j.announced ? j : { announced: {} }; } catch { return { announced: {} }; }
}

async function watch(argv) {
  const o = parseArgs(argv);
  if (!o.seen) die('watch needs --seen <file>');
  const scope = makeScope(ROOT, o.companies);
  const conductors = new Set(o.conductors);
  const cache = new Map();
  const parentAlive = () => {
    if (!o.parentPid) return true;
    try { process.kill(o.parentPid, 0); return true; } catch (e) { return e.code === 'EPERM'; }
  };
  for (;;) {
    if (!parentAlive()) return;
    const now = Date.now();
    const recorded = o.state ? loadAsks(o.state).asks : {};
    const seen = loadSeen(o.seen);
    let changed = false;
    // A queued ask the owner answered in its own window is closed here, and
    // one ASK-ANSWERED line tells the conductor to drop it unasked.
    if (o.state) {
      const asksState = loadAsks(o.state);
      let asksChanged = false;
      for (const rec of Object.values(asksState.asks)) {
        if (!rec || rec.status !== 'queued') continue;
        const file = transcriptOf(o.dirs, rec.session);
        if (!file) continue;
        let at = null;
        try { at = answeredAt(readTranscript(file), rec.ask_id, conductors); } catch { continue; }
        if (!at) continue;
        if (markAsk(asksState, rec.session, rec.ask_id, 'answered_in_source', now)) {
          asksChanged = true;
          process.stdout.write(`SUPER-CONDUCTOR ASK-ANSWERED ${new Date(now).toISOString().replace(/\.\d+Z$/, 'Z')} | ${clip(rec.title || rec.session, 60)} answered its own picker at ${at} | ask_id ${rec.ask_id} | Drop it from the queue; ask nothing, relay nothing.\n`);
        }
      }
      if (asksChanged) saveAsks(o.state, asksState);
    }
    for (const ask of scan(o, scope, conductors, recorded, now, cache)) {
      const key = askKey(ask.session, ask.ask_id);
      // A stale ask is announced a second time, once.
      if (seen.announced[key] && !(ask.stale && !seen.restale?.[key] && now - Date.parse(seen.announced[key]) > STALE_MS)) continue;
      if (ask.stale) { seen.restale ||= {}; seen.restale[key] = new Date(now).toISOString(); }
      process.stdout.write(`${askLine(ask, o.hint, now)}\n`);
      seen.announced[key] = new Date(now).toISOString();
      changed = true;
    }
    for (const [k, at] of Object.entries(seen.announced)) {
      if (now - Date.parse(at) > KEEP_MS) { delete seen.announced[k]; if (seen.restale) delete seen.restale[k]; changed = true; }
    }
    if (changed) saveAsks(o.seen, seen);
    if (o.once) return;
    await new Promise((r) => setTimeout(r, o.interval * 1000));
  }
}

function main() {
  if (process.argv[2] === 'mark') { mark(process.argv.slice(3)); return; }
  if (process.argv[2] === 'watch') { watch(process.argv.slice(3)); return; }
  if (process.argv[2] === 'queued') { queued(process.argv.slice(3)); return; }
  if (process.argv[2] === 'check') { checkCmd(process.argv.slice(3)); return; }
  const o = parseArgs(process.argv.slice(2));
  const scope = makeScope(ROOT, o.companies);
  const recorded = o.state ? loadAsks(o.state).asks : {};
  for (const ask of scan(o, scope, new Set(o.conductors), recorded, o.now)) {
    process.stdout.write(`${JSON.stringify(ask)}\n`);
  }
}

// Real paths on both sides, so a symlinked HQ root still runs main().
if (isMain(import.meta.url)) main();
