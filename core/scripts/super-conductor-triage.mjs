#!/usr/bin/env node
// super-conductor-triage.mjs — the background triage daemon for /super-conductor.
//
// Replaces the conductor launching long "triage" agents. It reads the request
// ledger (super-conductor-requests.mjs), classifies every untriaged `new` row
// deterministically from its text (guessKind), and either closes it (fyi),
// queues an owner decision on the decision queue (decision), or marks it
// `work` and leaves it for the conductor to route to a lane. Rows from the
// owner never reach the ledger (the watcher drops them), so no owner check.
//
//   node core/scripts/super-conductor-triage.mjs run --ledger <file> --decisions <file> \
//       --company <csv> [--once]
//   One pass over the ledger. Rows whose company is in the --company set, or
//   that have no company (a person-to-person DM), are triaged; critical rows
//   first, then oldest `at`.
//     fyi      → status done, result "fyi: no action (triage)";
//     decision already on the queue in the last 24 h (same words from the same
//       person or source thread in the same company; a dropped row never
//       anchors) → done, result "duplicate of <dq id>"; the owner is never
//       asked twice by the same asker, and a different asker gets their own row
//     decision → one decision-queue row (source ledger, ref <request id>) and
//                status waiting_owner; a duplicate question still marks the row;
//     work     → kind work only; status stays new for the conductor to route.
//   node core/scripts/super-conductor-triage.mjs watch --ledger <file> --decisions <file> \
//       --company <csv> [--interval <s>] [--parent-pid <pid>] [--once]
//   The loop: one pass every --interval seconds (default 15); exits at the
//   next poll once --parent-pid is gone; --once returns after one pass.
//
// After a pass that changed anything, exactly one wake line is printed:
//   SUPER-CONDUCTOR TRIAGE <iso> | <n> rows: <a> fyi closed, <b> decisions queued,
//   <c> work pending[, <k> critical] | Route the work rows (...); decisions are on the queue.
// Nothing is printed when nothing changed. A row that fails (a bad transition,
// a throw) is counted and reported once per pass on stderr; the pass continues.
// Exit: 0, 2 on bad arguments.
import { isMain, parseCompanies } from './lib/super-conductor-scope.mjs';
import { readRows, fold, guessKind, setRequest } from './super-conductor-requests.mjs';
import { addDecision, findDuplicate, readRows as readDecisionRows } from './super-conductor-decisions.mjs';

function die(msg) { process.stderr.write(`super-conductor-triage: ${msg}\n`); process.exit(2); }

const stamp = () => new Date().toISOString().replace(/\.\d+Z$/, 'Z');

function parseArgs(argv) {
  const o = { companies: [], interval: 15, once: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const val = () => { const v = argv[++i]; if (v === undefined) die(`${a} needs a value`); return v; };
    if (a === '--ledger') o.ledger = val();
    else if (a === '--decisions') o.decisions = val();
    else if (a === '--company') o.companies.push(val());
    else if (a === '--interval') o.interval = Number(val());
    else if (a === '--parent-pid') o.parentPid = Number(val());
    else if (a === '--once') o.once = true;
    else die(`unknown argument ${a}`);
  }
  if (!o.ledger) die('--ledger is required');
  if (!o.decisions) die('--decisions is required');
  try { o.companies = parseCompanies(o.companies); } catch (e) { die(e.message); }
  if (!Number.isFinite(o.interval) || o.interval < 1) die('--interval must be a positive number of seconds');
  if (o.parentPid !== undefined && (!Number.isInteger(o.parentPid) || o.parentPid <= 0)) die('--parent-pid must be a pid');
  return o;
}

// Deterministic classification of one ledger row. The watcher's kind is a
// guess too, so the text is always re-guessed here.
export function classify(row) {
  if (row.triaged) return { kind: null, why: 'already triaged' };
  const kind = guessKind(row.text);
  return { kind, why: `guessKind(text) → ${kind}` };
}

// The rows one pass works on: new, untriaged, in scope; critical first, then
// oldest `at`.
export function pending(rows, companies) {
  const set = new Set(companies);
  return rows.filter((r) => r.status === 'new' && !r.triaged && (!r.company || set.has(r.company)))
    .sort((a, b) => (a.priority === 'critical' ? 0 : 1) - (b.priority === 'critical' ? 0 : 1) || Date.parse(a.at) - Date.parse(b.at));
}

// One pass. Returns {rows, fyi, decisions, work, critical, errors: [text]}.
export function pass(ledger, decisions, companies) {
  const c = { rows: 0, fyi: 0, decisions: 0, dups: 0, standing: 0, work: 0, critical: 0, errors: [] };
  // The decision queue is read once per pass; rows queued in this pass are
  // added to the in-memory copy so a repeat later in the same pass matches.
  let queued = null;
  for (const row of pending(fold(readRows(ledger)), companies)) {
    const { kind } = classify(row);
    if (!kind) continue;
    let dup = null;
    try {
      if (kind === 'fyi') {
        setRequest(ledger, { id: row.id, kind: 'fyi', status: 'done', result: 'fyi: no action (triage)' });
        c.fyi++;
      } else if (kind === 'decision' && (dup = findDuplicate(queued || (queued = fold(readDecisionRows(decisions))), { question: row.text, from: row.from, company: row.company, source: row.source, ref: row.ref }))) {
        // The same person already asked this (or is being asked): close the
        // repeat and point at the row that carries the answer.
        setRequest(ledger, { id: row.id, kind: 'fyi', status: 'done', result: `duplicate of ${dup.id} (triage): ${dup.status}${dup.answer ? ` → ${dup.answer.slice(0, 60)}` : ''}` });
        c.dups++;
      } else if (kind === 'decision') {
        const d = addDecision(decisions, {
          source: 'ledger', ref: row.id,
          replyTo: { source: row.source, ref: row.ref, from: row.from },
          question: `${row.from} (${row.source}): ${row.text}`,
          options: [
            { label: 'Handle it (Recommended)', description: 'route to the owning session or reply', recommended: true },
            { label: 'Hold' },
            { label: 'Not mine' },
          ],
          priority: row.priority === 'critical' ? 'critical' : 'normal',
          company: row.company, askedBy: row.from,
        });
        setRequest(ledger, { id: row.id, kind: 'decision', status: 'waiting_owner', note: d.standing ? `decision ${d.id} answered by standing ${d.standing}: ${d.answer}` : `decision ${d.id} queued` });
        if (d.standing) c.standing++;
        if (queued && !d.dup) queued.push({ id: d.id, at: new Date().toISOString(), status: 'open', question: `${row.from} (${row.source}): ${row.text}`, company: row.company, asked_by: row.from, reply_to: { source: row.source, ref: row.ref, from: row.from } });
        c.decisions++;
      } else {
        setRequest(ledger, { id: row.id, kind: 'work' });
        c.work++;
      }
      c.rows++;
      if (row.priority === 'critical') c.critical++;
    } catch (e) {
      c.errors.push(`${row.id}: ${String(e && e.message || e).replace(/\|/g, '/').replace(/\s+/g, ' ').slice(0, 120)}`);
    }
  }
  return c;
}

// The wake line for a pass that changed something; null otherwise. Only
// counts and fixed text go in, never row text.
export function wakeLine(c) {
  if (!c.rows) return null;
  return `SUPER-CONDUCTOR TRIAGE ${stamp()} | ${c.rows} rows: ${c.fyi} fyi closed, ${c.decisions} decisions queued${c.standing ? ` (${c.standing} answered by standing rules)` : ''}${c.dups ? `, ${c.dups} duplicates closed` : ''}, ${c.work} work pending${c.critical ? `, ${c.critical} critical` : ''} | Route the work rows (requests.mjs list --open --kind work --triaged); decisions are on the queue.`;
}

// Row failures are printed on stdout once per failure streak (the heartbeat
// forwards stdout into the conductor; stderr is read only when the daemon
// exits), and again on stderr for the log.
let errorStreak = 0;
function runOnce(o) {
  const c = pass(o.ledger, o.decisions, o.companies);
  if (c.errors.length) {
    process.stderr.write(`super-conductor-triage: ${c.errors.length} row(s) failed: ${c.errors.join('; ')}\n`);
    if (errorStreak === 0) process.stdout.write(`SUPER-CONDUCTOR TRIAGE-ERROR ${stamp()} | ${c.errors.length} row(s) could not be triaged: ${c.errors.join('; ').slice(0, 300)} | Triage those rows by hand (requests.mjs set) and check the ledger and queue files are writable.\n`);
    errorStreak++;
  } else errorStreak = 0;
  const l = wakeLine(c);
  if (l) process.stdout.write(`${l}\n`);
}

async function watch(o) {
  const parentAlive = () => {
    if (!o.parentPid) return true;
    try { process.kill(o.parentPid, 0); return true; } catch (e) { return e.code === 'EPERM'; }
  };
  for (;;) {
    // The heartbeat normally stops the daemon on exit; if it was killed hard
    // its trap never ran, so stop polling here instead.
    if (!parentAlive()) return;
    runOnce(o);
    if (o.once) return;
    await new Promise((r) => setTimeout(r, o.interval * 1000));
  }
}

function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  if (cmd === 'run') runOnce(parseArgs(rest));
  else if (cmd === 'watch') watch(parseArgs(rest));
  else die('usage: run|watch --ledger <file> --decisions <file> --company <csv> [--interval <s>] [--parent-pid <pid>] [--once]');
}

if (isMain(import.meta.url)) main();
