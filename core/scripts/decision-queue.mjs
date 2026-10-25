#!/usr/bin/env node
// Persistent conductor owner-step queue. External actions are acknowledged by receipt.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const now = () => new Date().toISOString();
function run(argv) {
  const r = spawnSync(argv[0], argv.slice(1), { encoding: 'utf8', timeout: 60000, maxBuffer: 4 * 1024 * 1024 });
  if (r.error || r.signal) throw Object.assign(new Error(r.error?.message || `command terminated: ${r.signal}`), { uncertain: true });
  if (r.status !== 0) throw new Error(r.stderr.trim() || 'command failed');
  return r.stdout.trim();
}
const decide = (...args) => run(['hq', 'decide', ...args]);
function checkContextLinks(links) {
  if (!links.length) return;
  const decoded = links.map(link => {
    const url = new URL(link);
    const secretKeys = /^(?:x-amz-.+|x-goog-.+|sig|signature|token|access_token|refresh_token|api[_-]?key|key|secret|password|authorization|policy|key-pair-id)$/i;
    const fragmentKeys = new URLSearchParams(url.hash.slice(1));
    if (url.username || url.password || [...url.searchParams.keys(), ...fragmentKeys.keys()].some(k => secretKeys.test(k))) {
      throw new Error('context links must not contain credentials or signed URL parameters; use a stable access-controlled link');
    }
    try { return decodeURIComponent(link); } catch { throw new Error('context link has invalid percent encoding'); }
  });
  // Use the shared secret patterns; keep values out of argv, errors and the save file.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hq-decision-links-'));
  const input = path.join(dir, 'links.txt');
  try {
    fs.writeFileSync(input, decoded.join('\n'), { mode: 0o600 });
    const library = fileURLToPath(new URL('./lib/secret-patterns.sh', import.meta.url));
    const result = spawnSync('bash', ['-c', 'source "$1"; hq_scan_secrets "$2"', 'context-link-scan', library, input], { encoding: 'utf8', timeout: 10000 });
    if (result.error || result.status !== 0) throw new Error('context link secret check failed; remove credentials and use a stable access-controlled link');
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}
function persist(file, state) {
  state.updated_at = now();
  const tmp = `${file}.${process.pid}.tmp`;
  const fd = fs.openSync(tmp, 'wx', 0o600);
  try { fs.writeFileSync(fd, JSON.stringify(state, null, 2) + '\n'); fs.fsyncSync(fd); }
  finally { fs.closeSync(fd); }
  fs.renameSync(tmp, file);
}
function validate(i) {
  for (const key of ['step_id', 'statement', 'source', 'relay_target', 'company']) {
    if (typeof i[key] !== 'string' || !i[key].trim()) throw new Error(`${key} is required`);
  }
  if (!Array.isArray(i.options) || i.options.length < 2 || i.options.length > 4) throw new Error('options must contain 2-4 choices');
  for (const o of i.options) {
    if (!o || !['id', 'label'].every(k => typeof o[k] === 'string' && o[k].trim()) || o.id.includes('|')) throw new Error('each option needs a valid id and label');
  }
  const ids = i.options.map(o => o.id);
  if (new Set(ids).size !== ids.length || !ids.includes(i.recommend)) throw new Error('unique options and a valid recommend are required');
  if (!Array.isArray(i.context_links ?? []) || !(i.context_links ?? []).every(s => {
    try { return ['http:', 'https:'].includes(new URL(s).protocol); } catch { return false; }
  })) throw new Error('context_links must be HTTP(S) links');
  checkContextLinks(i.context_links ?? []);
  if (i.expires !== undefined && (typeof i.expires !== 'string' || !i.expires.trim())) throw new Error('expires must be a non-empty duration or ISO datetime');
  for (const k of ['context', 'commitment_id']) {
    if (i[k] !== undefined && typeof i[k] !== 'string') throw new Error(`${k} must be a string`);
  }
}
function main() {
  const args = process.argv.slice(2);
  if (args[0] !== '--state' || !args[1]) throw new Error('usage: decision-queue.sh --state <save-file> enqueue|enqueue-row|sweep|ack|fallback-answer|withdraw|cancel|resolve-expired ...');
  const file = path.resolve(args[1]), cmd = args[2], rest = args.slice(3);
  const flag = name => { const i = rest.indexOf(name); if (i < 0 || !rest[i + 1]?.trim()) throw new Error(`${name} is required`); return rest[i + 1]; };
  fs.mkdirSync(path.dirname(file), { recursive: true });
  // Fail closed on contention or a crashed writer. No unsafe stale-lock stealing.
  const lock = `${file}.decision-lock`;
  try { fs.mkdirSync(lock); } catch (e) { if (e.code === 'EEXIST') throw new Error(`queue locked at ${lock}; if stale, verify the process recorded in ${path.join(lock, 'pid')} exited before removing this lock`); throw e; }
  try {
    fs.writeFileSync(path.join(lock, 'pid'), String(process.pid));
    const state = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : {};
    const queue = state.decision_queue ??= { items: [], failures: [] };
    const items = queue.items;
    const current = items.find(i => !['relayed', 'withdrawn', 'dropped'].includes(i.status));
    let output = { status: 'idle' };
    if (cmd === 'enqueue') {
      const item = JSON.parse(fs.readFileSync(rest[0], 'utf8')); validate(item);
      if (items.some(i => i.step_id === item.step_id)) output = { status: 'already_queued', step_id: item.step_id };
      else {
        const safe = Object.fromEntries(['step_id', 'statement', 'source', 'relay_target', 'options', 'recommend', 'context_links', 'context', 'commitment_id', 'company', 'expires'].filter(k => item[k] !== undefined).map(k => [k, item[k]]));
        items.push({ ...safe, status: 'queued', created_at: now() });
        output = { status: 'queued', step_id: item.step_id };
      }
    } else if (cmd === 'enqueue-row') {
      // Build a step from one decision-desk queue row (super-conductor-decisions.mjs next --json).
      const parsed = JSON.parse(fs.readFileSync(rest[0], 'utf8'));
      const row = Array.isArray(parsed) ? parsed[0] : parsed;
      if (!row || typeof row.id !== 'string' || !row.id) throw new Error('row needs an id');
      const company = row.company || (rest.includes('--company') ? flag('--company') : undefined);
      const opts = (row.options || []).map((o, n) => ({ id: 'ABCD'[n] ?? String(n), label: String(o.label ?? ''), description: o.description }));
      const rec = opts[Math.max(0, (row.options || []).findIndex(o => o.recommended))];
      const askedBy = row.asked_by || [row.source, row.ref].filter(Boolean).join(':');
      const details = opts.filter(o => o.description).map(o => `${o.label}: ${o.description}`).join('\n');
      const item = {
        step_id: row.id, statement: askedBy ? `${askedBy}: ${row.question}` : row.question,
        source: `${row.source}:${row.ref}`, relay_target: `decision-row:${row.id}`,
        options: opts.map(({ id, label }) => ({ id, label })), recommend: rec?.id, company,
        ...(details ? { context: details } : {}), ...(row.expires ? { expires: row.expires } : {}),
      };
      validate(item);
      const prior = items.find(i => i.step_id === item.step_id);
      if (prior && ['dropped', 'withdrawn'].includes(prior.status)) {
        // The row is still open (a picker was dismissed, or the card was
        // withdrawn), so it gets a new attempt instead of being skipped forever.
        // A new attempt goes to the back: steps already waiting keep their turn.
        items.splice(items.indexOf(prior), 1);
        (item.attempts = prior.attempts ?? []).push({ status: prior.status, decision_id: prior.decision_id, at: now() });
        items.push({ ...item, status: 'queued', created_at: now() });
        output = { status: 'queued', step_id: item.step_id, attempt: item.attempts.length + 1 };
      } else if (prior) output = { status: prior.status === 'relayed' ? 'already_relayed' : 'already_queued', step_id: item.step_id };
      else { items.push({ ...item, status: 'queued', created_at: now() }); output = { status: 'queued', step_id: item.step_id }; }
    } else if (cmd === 'cancel') {
      // The source row was answered or dropped elsewhere before a card exists.
      const step = items.find(i => i.step_id === rest[0]);
      const reason = flag('--reason');
      // answer_pending is cancellable too: the source row was resolved elsewhere
      // (or another desk holds it), so the step must not block later rows.
      if (!step || !['queued', 'fallback', 'answer_pending'].includes(step.status)) throw new Error('can only cancel a queued, fallback or answer_pending step; withdraw an open card instead');
      Object.assign(step, { status: 'dropped', cancel_reason: reason, cancelled_at: now() });
      output = { status: 'dropped', step_id: step.step_id };
    } else if (cmd === 'sweep') {
      // An open list omits answered records; show the owned active id below.
      // A failed list before this queue owns a card (for example the decisions
      // API returning 404 before it is deployed) is an ask failure: the queued
      // step falls back to the chat picker. Once a card exists, a failed read
      // is retried on the next sweep and never opens a picker.
      let listError;
      try {
        const records = JSON.parse(decide('list', '--open', '--json'));
        if (!Array.isArray(records)) throw new Error('hq decide list must return an array');
      } catch (error) { listError = error; }
      queue.last_sweep_at = now();
      if (listError && current?.status === 'open') throw listError;
      if (listError && !current) {
        // Nothing to ask yet: report the read failure and let the caller claim
        // its next row, which then falls back if the API is still failing.
        queue.failures.push({ at: now(), operation: 'list', error: listError.message });
        output = { status: 'idle', read_error: listError.message };
      }
      if (current) {
        if (['asking', 'ask_uncertain'].includes(current.status)) output = { status: 'reconcile_required', step: current };
        else if (current.status === 'queued' && listError) {
          current.status = 'fallback';
          queue.failures.push({ at: now(), step_id: current.step_id, operation: 'list', error: listError.message });
          output = { status: current.status, step: current };
        } else if (current.status === 'queued') {
          validate(current); // Recheck saved links before any outbound ask.
          const argv = ['ask', '--to', 'me', '--company', current.company, '--expires', current.expires ?? '72h', '--json'];
          for (const o of current.options) argv.push('--option', `${o.id}|${o.label}`);
          argv.push('--recommend', current.recommend);
          for (const link of current.context_links ?? []) argv.push('--context-link', link);
          if (current.context) argv.push('--context', current.context);
          if (current.commitment_id) argv.push('--commitment', current.commitment_id);
          argv.push('--', current.statement);
          current.status = 'asking'; persist(file, state);
          let raw;
          try { raw = decide(...argv); }
          catch (error) {
            current.status = error.uncertain ? 'ask_uncertain' : 'fallback';
            queue.failures.push({ at: now(), step_id: current.step_id, operation: 'ask', error: error.message });
          }
          if (raw !== undefined) {
            try {
              const record = JSON.parse(raw);
              if (typeof record?.id !== 'string' || !record.id) throw new Error('ask returned no decision id');
              Object.assign(current, { status: 'open', decision_id: record.id });
            } catch (error) {
              current.status = 'ask_uncertain';
              queue.failures.push({ at: now(), step_id: current.step_id, operation: 'ask', error: error.message });
            }
          }
          output = { status: current.status, step: current };
        } else if (current.status === 'open') {
          const record = JSON.parse(decide('show', current.decision_id));
          if (record.id !== current.decision_id) throw new Error('show returned a different decision');
          if (record.state === 'answered') {
            if (!current.options.some(o => o.id === record.answer?.choiceId)) throw new Error('answer has an unknown choice');
            Object.assign(current, { status: 'answer_pending', answer: record.answer });
          } else if (['withdrawn', 'expired'].includes(record.state)) current.status = record.state;
          else if (!['open', 'talking'].includes(record.state)) throw new Error('unknown decision state');
          output = { status: current.status, step: current };
        } else output = { status: current.status, step: current };
      }
    } else if (cmd === 'resolve-expired') {
      if (!current || current.step_id !== rest[0] || current.status !== 'expired') throw new Error('no matching expired step awaiting resolution');
      const action = flag('--action'), reason = flag('--reason');
      if (!['reask', 'drop'].includes(action)) throw new Error('--action must be reask or drop');
      const replacement = rest.includes('--expires') ? flag('--expires') : undefined;
      if (action === 'reask') validate({ ...current, ...(replacement === undefined ? {} : { expires: replacement }) });
      (current.expiry_resolutions ??= []).push({ decision_id: current.decision_id, action, reason, at: now() });
      if (action === 'reask') {
        if (replacement !== undefined) current.expires = replacement;
        delete current.decision_id;
        current.status = 'queued';
      } else current.status = 'dropped';
      output = { status: current.status, step: current };
    } else if (cmd === 'withdraw') {
      const owned = items.find(i => i.decision_id === rest[0]);
      if (!owned || owned.status !== 'open') throw new Error('can only withdraw an open decision this queue asked');
      if (decide('withdraw', rest[0]) !== 'withdrawn') throw new Error('withdraw did not confirm withdrawn');
      owned.status = 'withdrawn'; output = { status: 'withdrawn', decision_id: rest[0] };
    } else if (cmd === 'fallback-answer') {
      if (!current || current.step_id !== rest[0] || current.status !== 'fallback') throw new Error('no matching failed ask awaiting a chat picker');
      if (rest.includes('--text')) {
        const text = flag('--text');
        Object.assign(current, { status: 'answer_pending', answer: { text, source: 'desktop', at: now() } });
      } else {
        const choice = flag('--choice');
        if (!current.options.some(o => o.id === choice)) throw new Error('unknown choice');
        Object.assign(current, { status: 'answer_pending', answer: { choiceId: choice, source: 'desktop', at: now() } });
      }
      output = { status: 'answer_pending', step: current };
    } else if (cmd === 'ack') {
      if (!current || current.step_id !== rest[0] || current.status !== 'answer_pending') throw new Error('no matching answer awaiting relay');
      const evidence = flag('--evidence');
      current.relay_evidence = evidence; persist(file, state);
      if (current.commitment_id) {
        current.ledger_evidence = flag('--ledger-evidence');
      }
      Object.assign(current, { status: 'relayed', relayed_at: now() }); output = { status: 'relayed', step_id: current.step_id };
    } else throw new Error(`unknown command: ${cmd}`);
    persist(file, state); console.log(JSON.stringify(output));
  } finally {
    fs.unlinkSync(path.join(lock, 'pid')); fs.rmdirSync(lock);
  }
}
try { main(); } catch (error) { console.error(`decision-queue: ${error.message}`); process.exitCode = 1; }
