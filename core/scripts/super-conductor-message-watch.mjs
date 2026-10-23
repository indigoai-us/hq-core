#!/usr/bin/env node
// super-conductor-message-watch.mjs — the cheap message wake for /super-conductor.
//
// Polls only what is new:
//   - the HQ DM inbox (`hq dm inbox --json`), and
//   - the channel directory change feed (`hq channels changes --cursor`), then
//     reads only the channels whose last human message moved
//     (`hq dm channel <id> --json`, which does not mark anything read).
// It prints one line, and only when an unseen inbound item arrives:
//
//   SUPER-CONDUCTOR MESSAGE <iso> | <n> new: DM from Ada; #hq-dev (Bob) | <hint>.
//
// The owner's own messages, system cards (work-session status), and items this
// watcher already reported never count. The first poll is a baseline: it records
// what exists and prints nothing, so a restart does not replay the backlog (the
// conductor's full sweep covers that).
//
// Slack: when the owner's settings select the `slack` channel and set
// `slack_watch.command`, it also runs that command for each workspace in
// `slack_workspaces`, every `slack_watch.interval` seconds (default 60):
//
//   <command> --since <unix seconds> --ws <workspace>
//
// The command prints a JSON array of the owner's new inbound Slack DMs and
// mentions since that time: [{id, ts, kind: "dm"|"mention", from, channel,
// self?}]. Company scope: a workspace is polled only when
// `slack_workspace_companies` maps it to a company in the --company set; an
// unmapped workspace is never polled (one DEGRADED line gives the count, not
// the names), and another company's workspace is skipped silently. The command
// must honor --ws (search that workspace only); ids are
// kept per workspace. Items with `self: true` and ids already reported are
// skipped. The command owns the owner's Slack token, so this script never
// touches it, and token-like text in its errors is redacted. The first Slack
// poll per workspace is a silent baseline: it runs the command and records
// what exists without reporting it, like HQ. Slack
// items go through the same --min-wake-gap rate cap as HQ items.
//
// Cost and cadence: polls every --interval seconds (default 30) inside the
// owner's work hours and every --away-interval seconds (default 300) outside
// them (`super-conductor-prefs.mjs interval`). MESSAGE lines are at least
// --min-wake-gap seconds apart (default 120); items found sooner are held and
// printed together, so a busy channel cannot trigger a sweep every poll.
//
// Run it under the heartbeat (`super-conductor-heartbeat.sh --message-watch
// <state>`), which runs inside `hq monitor start --persistent`, so the line
// wakes the idle conductor session.
//
// Critical channels (--critical, --team; super-conductor-prefs.mjs critical):
// an item from a listed channel, or an HQ DM from a listed teammate, is
// printed at once on its own line, never held by --min-wake-gap, and the
// poll stays on --interval outside work hours:
//
//   SUPER-CONDUCTOR CRITICAL <iso> | <n> critical: DM from Ada; #review (Bob) | <hint>.
//
// Its ledger row carries `priority: critical` and every row carries `seen_at`.
//
// Excluded channels (--exclude, plus `hq_channels_exclude` in the owner
// settings, re-read with the Slack settings): a channel whose slug or id is
// listed is dropped from the feed like an out-of-scope one. It is never read,
// stored, or named, so it produces no MESSAGE or CRITICAL line and no ledger
// row.
//
// Usage:
//   node core/scripts/super-conductor-message-watch.mjs --state <file> --company <csv>
//       [--interval <s>] [--away-interval <s>] [--min-wake-gap <s>] [--once]
//       [--critical <csv>] [--team <csv>] [--exclude <csv>]
//       [--owner-uid <prs_...>]... [--owner-email <e>]... [--hint <text>] [--parent-pid <pid>]
//
// --company: the session's locked company set (`hq-session.sh get
// company_slugs`); required. Only channels of those companies (by cloud_uid in
// companies/manifest.yaml) and the owner's person-to-person and group DMs are
// read, stored or named; every other channel in the feed is dropped unread.
// See lib/super-conductor-scope.mjs.
//
// --parent-pid: exit at the next poll once that process is gone (outside work
// hours that can be up to --away-interval later) (the heartbeat
// passes its own pid, so a hard-killed heartbeat does not leave a poller).
//
// Owner identity: every --owner-uid / --owner-email, plus `hq whoami --json`
// (personUid, email). When none resolves, one MESSAGE-WATCH-DEGRADED line says
// so and identity is retried on every poll. The state file keeps two seen sets (inbox event ids and
// channel message ids, capped separately so channel traffic never evicts inbox
// ids), the feed cursor, and each channel's last human message time.
//
// Env: HQ_BIN (default hq), SC_WATCH_ERROR_STREAK (default 5): consecutive
// polls with a failure (inbox, feed, or a channel read) before one
// MESSAGE-WATCH-ERROR line. The inbox and the channel feed are read
// independently: a failure in one never stops the other.
// Exit: 0 after --once, 2 on bad arguments.
import fs from 'node:fs';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { replaceFile } from './lib/super-conductor-lock.mjs';
import { prepareWindowsCommand } from './lib/windows-cmd-spawn.mjs';
import { isMain, makeScope, manifestUids, parseCompanies, rowExcluded, rowInScope } from './lib/super-conductor-scope.mjs';
import { addRequest, guessKind } from './super-conductor-requests.mjs';

const HQ_BIN = process.env.HQ_BIN || 'hq';
const ERROR_STREAK = Number(process.env.SC_WATCH_ERROR_STREAK || 5);
const SEEN_CAP = 500;
// Search indexes can lag a few seconds; each Slack poll looks back this far
// past its last run and dedupes by id.
const SLACK_OVERLAP_S = 300;
const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = process.env.HQ_ROOT || path.resolve(HERE, '../..');

function die(msg) {
  process.stderr.write(`super-conductor-message-watch: ${msg}\n`);
  process.exit(2);
}

function parseArgs(argv) {
  const o = {
    interval: 30, awayInterval: 300, minWakeGap: 120, once: false,
    ownerUids: [], ownerEmails: [], companies: [], hint: 'Run the /super-conductor wakeup (Step 7) now',
    critical: [], team: [], exclude: [],
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const val = () => { const v = argv[++i]; if (v === undefined) die(`${a} needs a value`); return v; };
    if (a === '--state') o.state = val();
    else if (a === '--interval') o.interval = Number(val());
    else if (a === '--away-interval') o.awayInterval = Number(val());
    else if (a === '--min-wake-gap') o.minWakeGap = Number(val());
    else if (a === '--once') o.once = true;
    else if (a === '--owner-uid') o.ownerUids.push(val());
    else if (a === '--owner-email') o.ownerEmails.push(val().toLowerCase());
    else if (a === '--hint') o.hint = val();
    else if (a === '--parent-pid') o.parentPid = Number(val());
    else if (a === '--company') o.companies.push(val());
    // --ledger: every new inbound item is recorded in the request ledger
    // (super-conductor-requests.mjs) as it is found, so the conductor reads
    // rows instead of re-reading the inbox and every channel.
    else if (a === '--ledger') o.ledger = val();
    // --save: the conductor's save file; each successful read records sweep
    // evidence for its target (super-conductor-sweep-check.mjs record).
    else if (a === '--save') o.save = val();
    // --critical: channels (hq_channel:<slug or id>) and `hq_dm:team` whose
    // items bypass --min-wake-gap and the away cadence and print a CRITICAL
    // line at once; --team: display names whose HQ DMs count for hq_dm:team.
    else if (a === '--critical') o.critical.push(...val().split(',').map((s) => s.trim()).filter(Boolean));
    else if (a === '--team') o.team.push(...val().split(',').map((s) => s.trim().toLowerCase()).filter(Boolean));
    // --exclude: HQ channel slugs or ids never read or named.
    else if (a === '--exclude') o.exclude.push(...val().split(',').map((s) => s.trim().toLowerCase()).filter(Boolean));
    else die(`unknown argument ${a}`);
  }
  if (!o.state) die('--state is required');
  try { o.companies = parseCompanies(o.companies); } catch (e) { die(e.message); }
  for (const [k, v] of [['--interval', o.interval], ['--away-interval', o.awayInterval]]) {
    if (!Number.isFinite(v) || v < 1) die(`${k} must be a positive number of seconds`);
  }
  if (!Number.isFinite(o.minWakeGap) || o.minWakeGap < 0) die('--min-wake-gap must be zero or more seconds');
  return o;
}

// The command line for one hq call. On Windows `hq` is an npm `hq.cmd` shim,
// which execFile cannot start without a shell; prepareWindowsCommand routes it
// through the shared PowerShell adapter with argv kept intact. Unchanged
// elsewhere.
export function hqInvocation(args, deps = {}) {
  return prepareWindowsCommand(HQ_BIN, args, { maxBuffer: 64 * 1024 * 1024, timeout: 120_000 }, deps);
}

function hq(args) {
  const run = hqInvocation(args);
  return new Promise((resolve, reject) => {
    execFile(run.file, run.args, run.options, (err, stdout, stderr) => {
      if (err) { reject(new Error(`hq ${args.slice(0, 2).join(' ')} failed: ${(stderr || err.message).trim().split('\n')[0]}`)); return; }
      try { resolve(JSON.parse(stdout)); } catch { reject(new Error(`hq ${args.slice(0, 2).join(' ')} printed non-JSON`)); }
    });
  });
}

function loadState(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return {}; }
}

function saveState(file, state) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, `${JSON.stringify(state, null, 2)}\n`);
  replaceFile(tmp, file);
}

const ms = (v) => { const n = typeof v === 'string' ? Date.parse(v) : NaN; return Number.isFinite(n) ? n : 0; };

// When a human last posted in a channel. lastHumanMessageAt is the signal; a
// row without it falls back to lastActivityAt/lastMessageAt only when the
// server says the channel has human messages. System cards (work-session
// status) alone never make a channel a candidate.
export function lastHuman(row) {
  const h = ms(row.lastHumanMessageAt);
  if (h) return h;
  return row.hasHumanMessage ? Math.max(ms(row.lastActivityAt), ms(row.lastMessageAt)) : 0;
}

export function isOwner(msg, owner) {
  if (msg.fromPersonUid && owner.uids.has(msg.fromPersonUid)) return true;
  const email = (msg.fromEmail || '').toLowerCase();
  return !!email && owner.emails.has(email);
}

// Is this channel, or this DM sender, on the critical list? `critical` holds
// `hq_channel:<slug or channel id>` and `hq_dm:team` entries; `team` holds
// lowercased display names.
export function criticalChannel(row, critical) {
  if (!critical || !critical.length) return false;
  const keys = new Set([row.channelId, row.slug, row.name].filter(Boolean).map((k) => `hq_channel:${String(k).toLowerCase()}`));
  return critical.some((c) => keys.has(String(c).toLowerCase()));
}
// Display names decide wake priority only. They are not an identity check:
// never reuse this for authorization (a go, a grant, a merge).
export function criticalDm(who, critical, team) {
  if (!critical || !critical.includes('hq_dm:team')) return false;
  return !!who && (team || []).includes(String(who).toLowerCase());
}

function channelLabel(row) {
  if (row.scope === 'group' || row.type === 'group') {
    const names = (row.members || []).map((m) => m.displayName).filter(Boolean);
    return `group DM with ${names.length ? names.join(', ') : row.name || row.subtitle || row.channelId}`;
  }
  return `#${row.slug || row.name || row.channelId}`;
}

// Mark an id seen and move it to the newest end, so an id still being returned
// is never the one the cap evicts.
function touch(set, id) {
  set.delete(id);
  set.add(id);
}

// One poll. Mutates state; returns the list of new item summaries. DM items
// are passed to onDms as soon as the inbox is read, before the slower channel
// feed call, so a DM wake does not wait on channels. `scope` (makeScope)
// limits channels to the locked company set; the default lets only
// person-to-person channels through. `crit.exclude` drops listed channels.
const textOf = (m) => m.text || m.body || m.message || m.preview || '';

export async function poll(state, owner, call = hq, onDms = () => {}, scope = { slugs: new Set(), uids: new Set() }, sink = () => {}, crit = { critical: [], team: [], exclude: [] }) {
  const baseline = !state.initialized;
  // Critical items are named here, printed at once by the caller, and never
  // held in `pending`.
  state.critical_pending = state.critical_pending || [];
  // A state file from before the split has one `seen` list; it seeds both.
  const seen = {
    inbox: new Set(state.seen_inbox || state.seen || []),
    channels: new Set(state.seen_channels || state.seen || []),
  };
  const items = [];
  // Failures of this poll, for the caller's error streak. The inbox and the
  // channel feed are independent: one failing never skips the other.
  state.poll_errors = [];

  // 1. DM inbox: inbound only by construction; still drop the owner's own.
  // Every id on the inbox page is touched, so it stays inside the cap for as
  // long as the inbox still returns it.
  // The inbox has its own baseline flag: when the first inbox read fails, the
  // next successful read is still a silent baseline. A state file from before
  // the flag counts as initialized.
  const inboxBaseline = state.inbox_initialized === undefined ? baseline : !state.inbox_initialized;
  let inbox = [];
  let inboxOk = false;
  try {
    inbox = await call(['dm', 'inbox', '--json', '--limit', '30']);
    inboxOk = true;
  } catch (e) {
    state.poll_errors.push(String(e.message).slice(0, 200));
  }
  if (inboxOk) state.inbox_initialized = true;
  else if (inboxBaseline) state.inbox_initialized = false;
  for (const ev of Array.isArray(inbox) ? inbox : []) {
    if (!ev.eventId) continue;
    const known = seen.inbox.has(ev.eventId);
    touch(seen.inbox, ev.eventId);
    if (known || inboxBaseline || isOwner(ev, owner)) continue;
    const who = ev.fromDisplayName || ev.fromEmail || 'a teammate';
    const isCrit = criticalDm(ev.fromDisplayName || ev.fromEmail, crit.critical, crit.team);
    (isCrit ? state.critical_pending : items).push(`DM from ${who}`);
    sink({ source: 'hq_dm', ref: ev.eventId, from: who, text: textOf(ev), at: ev.createdAt, seen_at: new Date().toISOString(), priority: isCrit ? 'critical' : undefined });
  }
  if (items.length) {
    finishPoll(state, seen);
    onDms(items.splice(0));
  }

  // 2. Channel feed. A snapshot (first call, or an expired cursor) re-baselines
  // channel times; a channel whose human-message time moved past what we knew
  // is a candidate either way, so an expired cursor never loses a message.
  // An hq without `channels changes` (older than the activity release) keeps
  // the DM wake working; the caller reports the gap once.
  let feed;
  try {
    feed = await call(state.cursor ? ['channels', 'changes', '--cursor', state.cursor] : ['channels', 'changes']);
  } catch (e) {
    state.cursor = null;
    const msg = String(e.message).slice(0, 200);
    // An hq without the command is a standing gap, reported once; anything
    // else (network, 5xx) is a failed poll that counts toward the error streak.
    if (/unknown command|unknown option/i.test(msg)) state.channel_error = msg;
    else { delete state.channel_error; state.poll_errors.push(msg); }
    finishPoll(state, seen);
    return items;
  }
  delete state.channel_error;
  // Out-of-scope and excluded channels are dropped here: never read, stored,
  // or named.
  const rows = [...(feed.rows || []), ...(feed.changed || [])].filter((r) => rowInScope(r, scope) && !rowExcluded(r, crit.exclude));
  const known = state.channels || {};
  const candidates = [];
  const advance = {};
  for (const row of rows) {
    if (!row.channelId) continue;
    const at = lastHuman(row);
    const before = known[row.channelId] || 0;
    if (!baseline && at > before && (before > 0 || ms(state.started_at) < at)) candidates.push({ row, before: before || ms(state.started_at) });
    if (at > before) advance[row.channelId] = at;
  }

  // Read each channel that moved. A channel's time advances only after its read
  // succeeds; on any failed read the cursor is dropped, so the next poll takes
  // a snapshot and finds the unread channel again instead of losing it.
  const failed = [];
  for (const { row, before } of candidates) {
    let msgs;
    try {
      // 50, not 10: a burst (one teammate posting a flag rollout every
      // minute) must not fall off the page between two polls.
      msgs = await call(['dm', 'channel', row.channelId, '--json', '--limit', '50']);
    } catch (e) {
      delete advance[row.channelId];
      failed.push(`${row.channelId}: ${String(e.message).slice(0, 120)}`);
      continue;
    }
    // Only messages newer than the channel's known time are recorded as seen;
    // older ones on the page are already excluded by time and would only fill
    // the cap.
    const fresh = (Array.isArray(msgs) ? msgs : msgs.messages || []).filter((m) => {
      const id = m.eventId || m.messageId;
      if (!id || !(ms(m.createdAt) > before)) return false;
      const known = seen.channels.has(id);
      touch(seen.channels, id);
      return !known && m.messageKind !== 'system' && !m.systemEvent && !isOwner(m, owner);
    });
    if (!fresh.length) continue;
    const who = [...new Set(fresh.map((m) => m.fromDisplayName || m.fromEmail).filter(Boolean))].join(', ');
    const isCrit = criticalChannel(row, crit.critical);
    (isCrit ? state.critical_pending : items).push(`${channelLabel(row)}${who ? ` (${who})` : ''}`);
    for (const m of fresh) {
      sink({ source: 'hq_channel', ref: m.eventId || m.messageId, from: m.fromDisplayName || m.fromEmail || 'a teammate', text: `${channelLabel(row)}: ${textOf(m)}`, at: m.createdAt, companyUid: row.companyUid, seen_at: new Date().toISOString(), priority: isCrit ? 'critical' : undefined });
    }
  }

  Object.assign(known, advance);
  for (const id of feed.removedChannelIds || []) delete known[id];
  state.channels = known;
  state.cursor = failed.length ? null : feed.cursor || null;
  if (failed.length) {
    state.channel_read_failures = failed;
    state.poll_errors.push(`channel reads failed: ${failed.join('; ')}`);
  } else delete state.channel_read_failures;
  finishPoll(state, seen);
  return items;
}

function finishPoll(state, seen) {
  delete state.seen;
  if (!state.poll_errors?.length) delete state.poll_errors;
  state.seen_inbox = [...seen.inbox].slice(-SEEN_CAP);
  state.seen_channels = [...seen.channels].slice(-SEEN_CAP);
  state.initialized = true;
  state.last_poll_at = new Date().toISOString();
}

// Hold items until the minimum gap since the last MESSAGE line has passed.
// Returns the items to print now (possibly empty). Mutates state.
export function takeWake(state, items, gapMs, now = Date.now()) {
  state.pending = [...(state.pending || []), ...items];
  if (!state.pending.length) { delete state.pending; return []; }
  if (now - ms(state.last_wake_at) < gapMs) return [];
  const out = state.pending;
  delete state.pending;
  state.last_wake_at = new Date(now).toISOString();
  return out;
}

function runText(file, args) {
  return new Promise((resolve) => {
    execFile(file, args, { cwd: ROOT, timeout: 30_000 }, (err, stdout) => resolve(err ? '' : String(stdout).trim()));
  });
}

// present or away, from the owner's work-day schedule. Unreadable settings
// count as present, the cheaper mistake to make for a wake.
async function cadenceMode() {
  const out = await runText(process.execPath, [path.join(HERE, 'super-conductor-prefs.mjs'), 'interval']);
  return /\baway\b/.test(out) ? 'away' : 'present';
}

// Slack watch settings from the owner's prefs, or null when off. Only
// workspaces mapped (slack_workspace_companies) to a company in scope.slugs
// are returned; `unmapped` counts the workspaces with no mapping.
export function slackConfig(prefs, scope = { slugs: new Set() }) {
  const chans = Array.isArray(prefs.channels) ? prefs.channels.map(String) : String(prefs.channels || '').split(',');
  const sw = prefs.slack_watch && typeof prefs.slack_watch === 'object' ? prefs.slack_watch : {};
  if (!chans.map((c) => c.trim()).includes('slack') || !sw.command) return null;
  // No fallback workspace: the company check needs a named, mapped workspace.
  const all = Array.isArray(prefs.slack_workspaces) ? prefs.slack_workspaces.map(String) : [];
  const map = prefs.slack_workspace_companies && typeof prefs.slack_workspace_companies === 'object' && !Array.isArray(prefs.slack_workspace_companies)
    ? prefs.slack_workspace_companies : {};
  let unmapped = 0;
  const workspaces = [];
  const companies = {};
  for (const ws of all) {
    const co = Object.hasOwn(map, ws) && typeof map[ws] === 'string' ? map[ws].trim() : '';
    if (!co) { unmapped++; continue; }
    if (scope.slugs.has(co)) { workspaces.push(ws); companies[ws] = co; }
  }
  const secs = Number(sw.interval);
  let argv = Array.isArray(sw.command) ? sw.command.map(String) : String(sw.command).trim().split(/\s+/);
  // Windows cannot start a shell script directly; run it through bash.
  if (process.platform === 'win32' && /\.sh$/i.test(argv[0])) argv = ['bash', ...argv];
  return {
    argv,
    workspaces,
    companies,
    unmapped,
    listed: all.length,
    intervalMs: (Number.isFinite(secs) && secs >= 10 ? secs : 60) * 1000,
  };
}

function readPrefs() {
  return new Promise((resolve) => {
    execFile(process.execPath, [path.join(HERE, 'super-conductor-prefs.mjs'), 'get'], { cwd: ROOT, timeout: 10_000 }, (err, stdout) => {
      if (err) { resolve({}); return; }
      try { resolve(JSON.parse(stdout)); } catch { resolve({}); }
    });
  });
}

function runSlackCommand(argv) {
  // 30s per workspace: the Slack poll runs in the same loop as the HQ poll.
  const run = prepareWindowsCommand(argv[0], argv.slice(1), { cwd: ROOT, maxBuffer: 16 * 1024 * 1024, timeout: 30_000 });
  return new Promise((resolve, reject) => {
    execFile(run.file, run.args, run.options, (err, stdout, stderr) => {
      if (err) { reject(new Error(`slack watch failed: ${redact((stderr || err.message).trim().split('\n')[0])}`)); return; }
      try { resolve(JSON.parse(stdout)); } catch { reject(new Error('slack watch printed non-JSON')); }
    });
  });
}

// Token-like strings (Slack xox*/xapp tokens, bearer values) never reach state
// or a wake line.
export function redact(t) {
  return String(t).replace(/\b(xox[a-z]-|xapp-)[A-Za-z0-9-]+/g, '$1[redacted]').replace(/(bearer\s+)\S+/gi, '$1[redacted]');
}

// Slack-controlled text (a bot username, a channel name) on one line, short:
// a newline must never forge a second SUPER-CONDUCTOR line, and a "|" never
// poses as a field of the wake line.
const cleanField = (t, n = 60) => {
  const x = String(t ?? '').replace(/[\u0000-\u001f\u007f]+/g, ' ').replace(/\s+/g, ' ').replace(/\|/g, '/').trim();
  return x.length > n ? `${x.slice(0, n - 1)}…` : x;
};

// One Slack poll across workspaces. Mutates state.slack and state.seen_slack
// (its own seen list, so Slack traffic never evicts HQ ids); returns item
// summaries.
export async function pollSlack(state, cfg, run = runSlackCommand, nowS = Math.floor(Date.now() / 1000), sink = () => {}) {
  state.slack ||= {};
  const seen = new Set(state.seen_slack || []);
  const items = [];
  const errors = [];
  for (const ws of cfg.workspaces) {
    const st = state.slack[ws] || {};
    const baseline = !st.since;
    let found;
    const floor = Math.max(0, (st.since || nowS) - SLACK_OVERLAP_S);
    try {
      // The baseline looks back the same overlap, so whatever a later poll's
      // overlap window returns is already recorded and stays silent.
      found = await run([...cfg.argv, '--since', String(floor), '--ws', ws]);
    } catch (e) {
      errors.push(`${ws}: ${redact(String(e.message)).slice(0, 160)}`);
      continue;
    }
    for (const m of Array.isArray(found) ? found : []) {
      if (!m || (!m.id && !m.ts)) continue; // nothing to tell it apart from the next one
      // An item older than the window asked for is never new, even once its
      // id has aged out of seen_slack (a command that ignores --since).
      if (Number(m.ts) > 0 && Number(m.ts) < floor) continue;
      const id = m.id || `${m.channel || ''}:${m.ts || ''}`;
      const key = `slack:${ws}:${id}`;
      if (seen.has(key)) continue;
      seen.add(key);
      if (baseline || m.self) continue;
      const who = cleanField(m.from) || 'someone';
      const where = cleanField(m.channel);
      const label = m.kind === 'mention'
        ? `Slack mention by ${who}${where ? ` in ${where}` : ''} (${cleanField(ws, 30)})`
        : `Slack DM from ${who} (${cleanField(ws, 30)})`;
      items.push(label);
      sink({ source: 'slack', ref: `${ws}:${id}`, from: who, text: `${label}: ${textOf(m)}`, at: Number(m.ts) > 0 ? new Date(Number(m.ts) * 1000).toISOString() : undefined, workspace: ws });
    }
    state.slack[ws] = { since: nowS };
  }
  state.seen_slack = [...seen].slice(-SEEN_CAP);
  if (errors.length) state.slack_error = errors.join('; ');
  else delete state.slack_error;
  return items;
}

async function resolveOwner(o, state) {
  const owner = { uids: new Set(o.ownerUids), emails: new Set(o.ownerEmails) };
  for (const u of state.owner?.uids || []) owner.uids.add(u);
  for (const e of state.owner?.emails || []) owner.emails.add(e);
  try {
    const me = await hq(['whoami', '--json']);
    if (me.personUid) owner.uids.add(me.personUid);
    if (me.email) owner.emails.add(String(me.email).toLowerCase());
  } catch { /* reported by the caller when nothing resolved */ }
  state.owner = { uids: [...owner.uids], emails: [...owner.emails] };
  return owner;
}

async function main() {
  const o = parseArgs(process.argv.slice(2));
  const scope = makeScope(ROOT, o.companies);
  if (scope.unmapped.length) {
    process.stderr.write(`super-conductor-message-watch: no cloud_uid in companies/manifest.yaml for ${scope.unmapped.join(', ')}; their channels are skipped\n`);
  }
  const state = loadState(o.state);
  state.started_at ||= new Date().toISOString();
  let owner = await resolveOwner(o, state);
  let errors = 0;
  let channelGapReported = false;
  let ownerGapReported = false;
  let slackGapReported = false;
  let slackNext = 0;
  // --exclude plus the settings' hq_channels_exclude, refreshed whenever the
  // settings are re-read (with the Slack settings), so a saved exclusion
  // applies without a restart.
  const excludeFrom = (prefs) => [...new Set([...o.exclude, ...(Array.isArray(prefs.hq_channels_exclude) ? prefs.hq_channels_exclude : []).map((s) => String(s).trim().toLowerCase()).filter(Boolean)])];
  let exclude = excludeFrom(await readPrefs());
  const stamp = () => new Date().toISOString().replace(/\.\d+Z$/, 'Z');
  const say = (line) => process.stdout.write(`${line}\n`);
  // Ledger rows. A row carries the company it belongs to: a channel's
  // company (uid mapped to its slug), a Slack workspace's mapped company, and
  // none for a person-to-person DM. A write failure is reported once, and no
  // sweep evidence is recorded for that poll, so the conductor reads the
  // target itself.
  const slugByUid = Object.fromEntries(Object.entries(manifestUids(ROOT)).map(([slug, uid]) => [uid, slug]));
  let ledgerGapReported = false;
  let ledgerFailed = false;
  let wsCompanies = {};
  const sink = (r) => {
    if (!o.ledger) return;
    const company = r.companyUid ? slugByUid[r.companyUid] : r.workspace ? wsCompanies[r.workspace] : undefined;
    try {
      addRequest(o.ledger, { ...r, kind: guessKind(r.text), company });
    } catch (e) {
      ledgerFailed = true;
      if (ledgerGapReported) return;
      ledgerGapReported = true;
      say(`SUPER-CONDUCTOR MESSAGE-WATCH-DEGRADED ${stamp()} | request ledger write failed for the inbox and channels (${String(e.message).slice(0, 120)}) | Items still wake the conductor; read the inbox and channels directly until the ledger is writable.`);
    }
  };
  // Sweep evidence for a target this watcher read in full. Calls run one at a
  // time (the save file has other writers) and never for a poll whose ledger
  // write failed.
  let recordGapReported = false;
  let recordChain = Promise.resolve();
  let recordPending = 0;
  const record = (target, cursor) => {
    if (!o.save || ledgerFailed) return;
    // Bounded: a hung record never piles up behind the poll interval.
    if (recordPending >= 8) return;
    recordPending++;
    recordChain = recordChain.then(() => new Promise((resolve) => {
      const run = prepareWindowsCommand(process.execPath, [path.join(HERE, 'super-conductor-sweep-check.mjs'), 'record', '--state', o.save, '--target', target, '--cursor', String(cursor)], { timeout: 15_000 });
      execFile(run.file, run.args, run.options, (err, _out, stderr) => {
        recordPending--;
        if (err && !recordGapReported) {
          recordGapReported = true;
          say(`SUPER-CONDUCTOR MESSAGE-WATCH-DEGRADED ${stamp()} | sweep evidence not recorded for ${target} (${String(stderr || err.message).trim().split('\n')[0].slice(0, 120)}) | The conductor must record ${target} itself.`);
        }
        resolve();
      });
    }));
  };
  const flush = (items) => {
    // Critical items first, at once, never gap-held. The gap clock is not
    // touched, so a normal batch still prints on its own schedule.
    const crit = (state.critical_pending || []).splice(0);
    delete state.critical_pending;
    if (crit.length) {
      const shownCrit = crit.slice(0, 6).join('; ') + (crit.length > 6 ? `; +${crit.length - 6} more` : '');
      say(`SUPER-CONDUCTOR CRITICAL ${stamp()} | ${crit.length} critical: ${shownCrit} | Read the critical rows first (super-conductor-requests.mjs list --open --priority critical), then ${o.hint}.`);
    }
    const out = takeWake(state, items, o.minWakeGap * 1000);
    saveState(o.state, state);
    if (!out.length) return;
    const shown = out.slice(0, 6).join('; ') + (out.length > 6 ? `; +${out.length - 6} more` : '');
    say(`SUPER-CONDUCTOR MESSAGE ${stamp()} | ${out.length} new: ${shown} | ${o.hint}.`);
  };
  const parentAlive = () => {
    if (!o.parentPid) return true;
    try { process.kill(o.parentPid, 0); return true; } catch (e) { return e.code === 'EPERM'; }
  };
  for (;;) {
    // The heartbeat normally stops the watcher on exit; if it was killed hard
    // (SIGKILL), its trap never ran, so stop polling here instead.
    if (!parentAlive()) return;
    const started = Date.now();
    if (!owner.uids.size && !owner.emails.size) {
      owner = await resolveOwner(o, state);
      if (!owner.uids.size && !owner.emails.size && !ownerGapReported) {
        ownerGapReported = true;
        say(`SUPER-CONDUCTOR MESSAGE-WATCH-DEGRADED ${stamp()} | owner identity unknown (hq whoami failed and no --owner-uid/--owner-email) | The owner's own messages may wake the conductor until it resolves.`);
      }
    }
    let failures = [];
    ledgerFailed = false;
    // A baseline poll records what exists and reports nothing, so it is not
    // sweep evidence: the conductor's full sweep still reads the inbox and
    // the channels once, and a DM waiting at watcher start is never skipped.
    const inboxBaseline = state.inbox_initialized === undefined ? !state.initialized : !state.inbox_initialized;
    const channelBaseline = !state.initialized;
    try {
      const items = await poll(state, owner, hq, (dms) => flush(dms), scope, sink, { critical: o.critical, team: o.team, exclude });
      if (!inboxBaseline && state.inbox_initialized && !(state.poll_errors || []).some((e) => /^hq dm inbox/.test(e))) record('hq_dms', stamp());
      if (!channelBaseline && state.cursor && !state.channel_error) record('hq_channels', stamp());
      failures = state.poll_errors || [];
      if (state.channel_error && !channelGapReported) {
        channelGapReported = true;
        say(`SUPER-CONDUCTOR MESSAGE-WATCH-DEGRADED ${stamp()} | channel wake unavailable: this hq has no \`hq channels changes\` (${state.channel_error}); DMs still wake. Update hq | The timer sweep still covers channels.`);
      } else if (!state.channel_error) channelGapReported = false;
      flush(items);
    } catch (e) {
      failures = [String(e.message).slice(0, 200)];
      saveState(o.state, state);
    }
    errors = failures.length ? errors + 1 : 0;
    if (errors === ERROR_STREAK) {
      say(`SUPER-CONDUCTOR MESSAGE-WATCH-ERROR ${stamp()} | ${errors} polls failed in a row: ${failures.join('; ').slice(0, 300)} | The message wake is degraded; the timer sweep still runs.`);
    }
    // Slack, on its own interval. Settings are re-read each time so a change
    // to slack_watch applies without a restart.
    if (Date.now() >= slackNext) {
      const prefs = await readPrefs();
      exclude = excludeFrom(prefs);
      const slackCfg = slackConfig(prefs, scope);
      wsCompanies = slackCfg ? slackCfg.companies : {};
      slackNext = Date.now() + (slackCfg ? slackCfg.intervalMs : 300_000);
      // Report a Slack scope gap once per change, across restarts.
      const gap = !slackCfg ? ''
        : !slackCfg.listed ? 'no Slack workspace is listed in slack_workspaces, so Slack is not watched'
        : slackCfg.unmapped ? `${slackCfg.unmapped} Slack workspace(s) have no company in slack_workspace_companies and are not watched` : '';
      if ((state.slack_scope_gap || '') !== gap) {
        state.slack_scope_gap = gap;
        saveState(o.state, state);
        if (gap) say(`SUPER-CONDUCTOR MESSAGE-WATCH-DEGRADED ${stamp()} | ${gap} | List each workspace and map it to its company in the owner settings.`);
      }
      if (slackCfg && slackCfg.workspaces.length) {
        // A workspace's first poll is a silent baseline (it reports nothing),
        // so it is not sweep evidence; nor is a poll that failed for that
        // workspace (its cursor did not move).
        const before = Object.fromEntries(slackCfg.workspaces.map((ws) => [ws, (state.slack && state.slack[ws] && state.slack[ws].since) || 0]));
        const found = await pollSlack(state, slackCfg, undefined, undefined, sink);
        for (const ws of slackCfg.workspaces) {
          const after = (state.slack && state.slack[ws] && state.slack[ws].since) || 0;
          if (before[ws] && after && after !== before[ws]) record(`slack:${ws}`, stamp());
        }
        if (state.slack_error && !slackGapReported) {
          slackGapReported = true;
          say(`SUPER-CONDUCTOR MESSAGE-WATCH-DEGRADED ${stamp()} | Slack wake unavailable (${state.slack_error}) | The timer sweep still covers Slack.`);
        } else if (!state.slack_error) slackGapReported = false;
        flush(found);
      }
    }
    if (o.once) return;
    // With critical channels configured the poll never slows to the away
    // cadence: a critical message must be seen within --interval anywhere in
    // the day.
    const every = (await cadenceMode()) === 'away' && !o.critical.length ? o.awayInterval : o.interval;
    // Polls start every interval; a slow poll shortens the next wait.
    await new Promise((r) => setTimeout(r, Math.max(1000, every * 1000 - (Date.now() - started))));
  }
}

// Real paths on both sides: under a symlinked HQ root argv[1] is the link path
// while import.meta.url is the resolved file.
if (isMain(import.meta.url)) main();
