#!/usr/bin/env node
// super-conductor-sweep-check.mjs — per-channel sweep evidence for
// /super-conductor, and the mechanical check that a wakeup swept everything.
//
// A heartbeat wakeup is a full sweep of every selected channel, every Slack
// workspace, and every email account. The conductor records one evidence entry
// per target in the save file's `sweep` map, and the heartbeat runs `verify`
// before each new tick, so a wakeup that skipped a target is flagged instead
// of reported as "nothing new".
//
// Usage:
//   node core/scripts/super-conductor-sweep-check.mjs targets [--channels <csv>]
//       Expanded sweep targets, one per line (sessions, hq_dms, hq_channels,
//       slack:<workspace>, email:<account>, x, teammates). Channels, workspaces
//       and accounts come from the owner's prefs unless --channels is given.
//   node core/scripts/super-conductor-sweep-check.mjs record --state <file> --target <t>
//       (--cursor <cursor> | --unavailable <reason> --tried <csv>)
//       Write one evidence entry. A swept target gets last_swept_at and its
//       cursor. An unavailable target needs every fallback path for its
//       channel in --tried (see FALLBACKS); it is re-checked at most hourly.
//   node core/scripts/super-conductor-sweep-check.mjs verify --state <file> --since <iso>
//       [--channels <csv>] [--now <iso>]
//       Exit 0 when every target was swept at or after --since, or is
//       unavailable with all fallbacks tried and checked within the last hour.
//       Exit 1 otherwise, listing each missing target. Prints the status line.
//   node core/scripts/super-conductor-sweep-check.mjs status-line --state <file> --since <iso>
//       The owner-facing line: channels read, channels skipped and why.
//
// Exit: 0 ok, 1 incomplete sweep, 2 bad arguments, 3 refused record.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const RECHECK_MS = 60 * 60 * 1000;

// Every path the skill lists for a channel, in order. A target is marked
// unavailable only after each one was tried.
export const FALLBACKS = {
  sessions: ['ccd_list_sessions', 'hq_lanes_link'],
  hq_dms: ['hq_dm'],
  hq_channels: ['hq_channels'],
  slack: ['hq_integration', 'hq_slack_cli', 'slack_mcp'],
  email: ['hq_integration', 'mail_mcp', 'gmail_connector'],
  x: ['hq_integration', 'x_mcp'],
  teammates: ['hq_mesh', 'gh'],
};

function die(msg, code) {
  process.stderr.write(`super-conductor-sweep-check: ${msg}\n`);
  process.exit(code);
}

function opts(argv) {
  const o = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) die(`unexpected argument ${a}`, 2);
    o[a.slice(2)] = argv[i + 1];
    i++;
  }
  return o;
}

function prefs() {
  try {
    return JSON.parse(execFileSync('node', [path.join(HERE, 'super-conductor-prefs.mjs'), 'get'], { encoding: 'utf8' }));
  } catch {
    return { channels: ['hq_dms'] };
  }
}

export function targets(p, channelsCsv) {
  const chans = channelsCsv
    ? channelsCsv.split(',').map((s) => s.trim().replace(/ \(from settings\)$/, '')).filter(Boolean)
    : (p.channels || []);
  const list = ['sessions'];
  for (const c of chans) {
    if (c === 'sessions' || list.includes(c)) continue;
    if (c === 'slack') {
      const ws = p.slack_workspaces && p.slack_workspaces.length ? p.slack_workspaces : ['default'];
      for (const w of ws) list.push(`slack:${w}`);
    } else if (c === 'email') {
      const acc = p.email_accounts && p.email_accounts.length ? p.email_accounts : ['default'];
      for (const a of acc) list.push(`email:${a}`);
    } else {
      list.push(c);
    }
  }
  return list;
}

function readState(file) {
  if (!file) die('--state is required', 2);
  if (!fs.existsSync(file)) return {};
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (e) {
    die(`cannot parse ${file}: ${e.message}`, 3);
  }
}

// Returns {ok, read: [...], skipped: [{target, reason}], missing: [{target, why}]}.
export function evaluate(state, list, since, now) {
  const sweep = state.sweep || {};
  const sinceMs = Date.parse(since);
  const nowMs = now ? Date.parse(now) : Date.now();
  const read = [];
  const skipped = [];
  const missing = [];
  for (const t of list) {
    const e = sweep[t];
    const channel = t.split(':')[0];
    if (!e) { missing.push({ target: t, why: 'no sweep evidence' }); continue; }
    if (e.status === 'unavailable') {
      const need = FALLBACKS[channel] || [];
      const tried = e.tried || [];
      const untried = need.filter((f) => !tried.includes(f));
      if (untried.length) { missing.push({ target: t, why: `unavailable without trying ${untried.join(', ')}` }); continue; }
      if (!(nowMs - Date.parse(e.checked_at) < RECHECK_MS)) { missing.push({ target: t, why: 'unavailable recheck due (over an hour)' }); continue; }
      skipped.push({ target: t, reason: e.reason || 'unavailable' });
      continue;
    }
    if (!e.last_swept_at || !(Date.parse(e.last_swept_at) >= sinceMs)) {
      missing.push({ target: t, why: `not swept since ${since} (last ${e.last_swept_at || 'never'})` });
      continue;
    }
    read.push(t);
  }
  return { ok: missing.length === 0, read, skipped, missing };
}

export function statusLine(r) {
  const parts = [`Read: ${r.read.length ? r.read.join(', ') : 'none'}`];
  if (r.skipped.length) parts.push(`Skipped: ${r.skipped.map((s) => `${s.target} (${s.reason})`).join(', ')}`);
  if (r.missing.length) parts.push(`NOT SWEPT: ${r.missing.map((m) => `${m.target} (${m.why})`).join(', ')}`);
  return parts.join(' | ');
}

function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  const o = opts(rest);
  if (cmd === 'targets') {
    process.stdout.write(targets(prefs(), o.channels).join('\n') + '\n');
    return;
  }
  if (cmd === 'record') {
    const state = readState(o.state);
    if (!o.target) die('--target is required', 2);
    const now = new Date().toISOString();
    state.sweep = state.sweep || {};
    if (o.unavailable !== undefined) {
      const tried = (o.tried || '').split(',').map((s) => s.trim()).filter(Boolean);
      const untried = (FALLBACKS[o.target.split(':')[0]] || []).filter((f) => !tried.includes(f));
      if (untried.length) die(`refusing to mark ${o.target} unavailable: still untried ${untried.join(', ')}`, 3);
      state.sweep[o.target] = { status: 'unavailable', reason: o.unavailable, tried, checked_at: now };
    } else {
      if (o.cursor === undefined) die('record needs --cursor or --unavailable', 2);
      state.sweep[o.target] = { status: 'swept', last_swept_at: now, cursor: o.cursor };
    }
    fs.writeFileSync(o.state, JSON.stringify(state, null, 2) + '\n');
    return;
  }
  if (cmd === 'verify' || cmd === 'status-line') {
    if (!o.since || Number.isNaN(Date.parse(o.since))) die('--since <iso> is required', 2);
    const r = evaluate(readState(o.state), targets(prefs(), o.channels), o.since, o.now);
    process.stdout.write(statusLine(r) + '\n');
    if (cmd === 'verify' && !r.ok) process.exit(1);
    return;
  }
  die('usage: targets | record | verify | status-line', 2);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) main();
