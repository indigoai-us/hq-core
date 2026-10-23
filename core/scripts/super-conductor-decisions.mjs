#!/usr/bin/env node
// super-conductor-decisions.mjs — the owner decision queue for /super-conductor.
//
// One durable row per thing only the owner can decide, from any source (a
// ledger request, a child session's open ask, the conductor's own work),
// until it is answered and the answer is relayed. The decision desk session
// (`/decision-desk`) reads `next` and opens one picker per row; the conductor
// never opens a picker itself, so its turn is never held by one. Append-only
// JSON lines; a row with an existing id updates that decision, latest wins.
//
//   node core/scripts/super-conductor-decisions.mjs add --file <queue> \
//       --source ledger|ask|conductor --ref <request id | session:ask_id | text> \
//       --question <text> [--option <label>[::<description>]]... \
//       [--recommended <label>] [--company <slug>] [--priority critical|normal] \
//       [--relay-session <local_id>] [--relay-child <link child name>] [--relay-link <link>]
//   Exit 0 and print the id; exit 3 and print the existing id when source+ref
//   is already queued (the same question is never asked twice).
//   node core/scripts/super-conductor-decisions.mjs next --file <queue> [--json] [--lane merges|asks|general] [--claim <desk>] [--count <n>]
//   The oldest open decision, critical rows first; exit 3 when none is open.
//   --lane serves one desk lane; --claim records that this desk is asking the
//   row, so no other desk asks it while the claim is fresh (15 min).
//   --count <n> returns up to n distinct rows (a JSON array with --json), all
//   claimed under one lock; critical rows come back on their own.
//   node core/scripts/super-conductor-decisions.mjs claim --file <queue> --id <id> --desk <desk>
//   Claim one named open row (exit 3 when another desk holds it). The
//   conductor claims only critical rows.
//   node core/scripts/super-conductor-decisions.mjs answer --file <queue> --id <id> --answer <text> --desk <desk> [--relay-by desk]
//   --desk is required and must hold the row's fresh claim.
//   `--relay-by desk` says the desk delivers this answer itself (a row with a
//   relay session or child); the conductor's ANSWER line for that row waits
//   RELAY_GRACE_MS, so a desk relay that failed is still picked up.
//   node core/scripts/super-conductor-decisions.mjs relayed --file <queue> --id <id> [--result <ref>] [--by desk|conductor]
//   node core/scripts/super-conductor-decisions.mjs drop --file <queue> --id <id> --note <why> [--by desk|conductor]
//   --note is required: a dropped decision always records why.
//   node core/scripts/super-conductor-decisions.mjs list --file <queue> [--open] [--status <csv>] [--json]
//   node core/scripts/super-conductor-decisions.mjs count --file <queue>
//   node core/scripts/super-conductor-decisions.mjs standing add --match <regex> --answer <label>
//       [--source ledger|ask|conductor] [--from <who>] [--company <slug>] [--critical] [--free] [--note <why>]
//   node core/scripts/super-conductor-decisions.mjs standing list [--json] | remove --id <id> | disable --id <id>
//   Standing answers: a rule the owner set once answers every later matching
//   decision at add time (by "standing"); the desk never asks it, the
//   conductor relays it. `add --no-standing` skips the rules for one row.
//   node core/scripts/super-conductor-decisions.mjs stale --file <queue> [--after <s>] [--json]
//   Open rows waiting longer than --after seconds (default 300); exit 3 when none.
//   node core/scripts/super-conductor-decisions.mjs watch --file <queue> --for desk|conductor
//       [--interval <s>] [--parent-pid <pid>] [--once] [--stale-after <s>]
//   The wake loop. `--for desk` prints one SUPER-CONDUCTOR DECISION line when
//   an open decision appears (the desk session's monitor) and one
//   SUPER-CONDUCTOR STALE-DECISION line per row still open after --stale-after
//   seconds (default 300; the desk pushes a phone notification); `--for
//   conductor` prints one SUPER-CONDUCTOR ANSWER line per newly answered
//   decision the desk does not relay itself (the conductor relays it, then
//   marks it relayed). Each line is printed once.
//
// Transitions: open → answered | dropped; answered → relayed | dropped.
// Text is clipped and kept on one line, "|" replaced, so a row can never pose
// as a second field of a wake line.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { isMain } from './lib/super-conductor-scope.mjs';
import { withLockSync, replaceFile } from './lib/super-conductor-lock.mjs';

const SOURCES = new Set(['ledger', 'ask', 'conductor']);
const NEXT = {
  open: new Set(['answered', 'dropped']),
  answered: new Set(['relayed', 'dropped']),
  relayed: new Set(),
  dropped: new Set(),
};

function die(msg) { process.stderr.write(`super-conductor-decisions: ${msg}\n`); process.exit(2); }

export const clean = (t, n = 400) => {
  const x = String(t == null ? '' : t).replace(/[\u0000-\u001f\u007f]+/g, ' ').replace(/\|/g, '/').replace(/\s+/g, ' ').trim();
  return x.length > n ? `${x.slice(0, n - 1)}…` : x;
};

export function readRows(file) {
  let text = '';
  try { text = fs.readFileSync(file, 'utf8'); } catch (e) { if (e.code === 'ENOENT') return []; throw e; }
  const rows = [];
  for (const line of text.split('\n')) {
    if (!line.trim()) continue;
    try { const r = JSON.parse(line); if (r && typeof r === 'object' && r.id) rows.push(r); } catch { /* torn last line */ }
  }
  return rows;
}

// Latest state per id, first-seen order. `at` is the first row's time.
export function fold(rows) {
  const by = new Map();
  for (const r of rows) {
    const cur = by.get(r.id);
    if (!cur) { by.set(r.id, { ...r, updated_at: r.at }); continue; }
    const { at, ...rest } = r;
    by.set(r.id, { ...cur, ...rest, updated_at: at });
  }
  return [...by.values()];
}

function append(file, row) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.appendFileSync(file, `${JSON.stringify(row)}\n`);
}

export function decisionId(source, ref, at) {
  const h = createHash('sha256').update(`${source}\0${ref}`).digest('hex').slice(0, 10);
  return `dq_${String(at).replace(/[-:TZ.]/g, '').slice(0, 14)}_${h}`;
}

// Queue one decision. Returns {id, dup}. Options: [{label, description?,
// recommended?}], two to four of them; the first is the recommended one
// unless another is marked. Throws on bad input.
// Standing answers: rules the owner set once ("feedback older than two weeks
// → Close, won't do"). A rule is {id, match: <regex on the question>,
// answer, source?, from?, company?, critical?, note?, at}. When a new
// decision matches a rule, it is queued and answered in the same write, by
// "standing", so the desk never asks it and the conductor relays the answer
// as usual (the ANSWER line names the rule). The answer must be one of the
// row's option labels unless the rule says free: true. A critical row is
// only auto-answered by a rule with critical: true. Rules live in a JSON
// array file (default personal/settings/super-conductor-standing-answers.json
// under the HQ root, or $SC_STANDING_FILE).
//
// Safety limits, enforced in code on every read and match (not only on add):
// - A rule carries note, at and expires; an expired rule, or one missing
//   any of them (a hand-edited file), never fires. expires is at most
//   STANDING_MAX_DAYS after the rule was set.
// - A rule never answers an irreversible action (merge, deploy, release,
//   publish, tag, send, delete, drop, pay, transfer, refund, wire), named in
//   the question or in the answer, unless the owner set irreversible: true.
// - A rule never answers a row whose text came from a teammate (a ledger row
//   or a row with reply_to) unless the rule is scoped with from.
// - A free-text rule (free: true) never answers a critical row.
// - The regex needs STANDING_MIN_LITERALS literal letters or digits (a
//   wildcard such as `.*.*.*.*` is refused) and no nested quantifier.
export const STANDING_MAX_DAYS = 30;
export const STANDING_MIN_LITERALS = 6;
export const IRREVERSIBLE = /\b(merge[sd]?|merging|deploy(s|ed|ing|ment)?|redeploy|releas(e|es|ed|ing)|publish(es|ed|ing)?|tag(s|ged|ging)?|send(s|ing)?|sent|delet(e|es|ed|ing)|drop(s|ped|ping)?|pay(s|ing|ment)?|paid|transfer(s|red|ring)?|refund(s|ed|ing)?|wire[sd]?)\b/i;
export function standingFile() {
  if (process.env.SC_STANDING_FILE) return process.env.SC_STANDING_FILE;
  // fileURLToPath, not URL.pathname: a root with a space or a Windows drive
  // letter must not turn into "my%20hq" or "\\C:\\...".
  const here = path.dirname(fileURLToPath(import.meta.url));
  return path.join(process.env.HQ_ROOT || path.resolve(here, '..', '..'), 'personal', 'settings', 'super-conductor-standing-answers.json');
}
// Letters and digits a regex must match literally: character classes and
// escapes like \d or \w are removed first, so `[a-z]{8}` counts zero.
export const literalCount = (re) => String(re).replace(/\\[dDwWsSbB]/g, '').replace(/\[(?:\\.|[^\]])*\]/g, '').replace(/\\(.)/g, '$1').replace(/[^A-Za-z0-9]/g, '').length;
// A quantified group that itself holds a quantifier ((a+)+, (\w*)*, (x+){2,})
// can backtrack for minutes inside the queue lock.
export const nestedQuantifier = (re) => /\((?:[^()\\]|\\.)*[+*}](?:[^()\\]|\\.)*\)\s*[+*{?]/.test(String(re));
export function standingProblem(rule) {
  if (!rule || !rule.id || !rule.match || !rule.answer) return 'needs id, match and answer';
  if (!clean(rule.note) || !rule.at || Number.isNaN(Date.parse(rule.at))) return 'needs note and at';
  if (!rule.expires || Number.isNaN(Date.parse(rule.expires))) return 'needs expires';
  if (Date.parse(rule.expires) - Date.parse(rule.at) > STANDING_MAX_DAYS * 86400000) return `expires is more than ${STANDING_MAX_DAYS} days after it was set`;
  if (literalCount(rule.match) < STANDING_MIN_LITERALS) return `match needs at least ${STANDING_MIN_LITERALS} literal letters or digits: name the request, not a pattern`;
  if (nestedQuantifier(rule.match)) return 'match has a nested quantifier';
  try { new RegExp(rule.match, 'i'); } catch (e) { return `bad match: ${e.message}`; }
  if (rule.free && rule.critical) return 'a free-text rule never answers critical rows';
  return '';
}
export function readStanding(file = standingFile()) {
  try { const v = JSON.parse(fs.readFileSync(file, 'utf8')); return Array.isArray(v) ? v.filter((r) => !standingProblem(r)) : []; } catch { return []; }
}
function writeStanding(file, rules) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, `${JSON.stringify(rules, null, 2)}\n`);
  replaceFile(tmp, file);
}
const optionLabel = (l) => clean(l, 60).replace(/\s*\(recommended\)\s*$/i, '').toLowerCase();
export function matchStanding(rules, row, nowMs = Date.now()) {
  for (const rule of rules || []) {
    if (rule.disabled || standingProblem(rule)) continue;
    if (nowMs >= Date.parse(rule.expires)) continue;
    if (row.priority === 'critical' && (!rule.critical || rule.free)) continue;
    if ((row.source === 'ledger' || row.reply_to) && !rule.from) continue;
    if (!rule.irreversible && (IRREVERSIBLE.test(row.question || '') || IRREVERSIBLE.test(rule.answer))) continue;
    if (rule.source && rule.source !== row.source && !(row.reply_to && rule.source === row.reply_to.source)) continue;
    if (rule.company && rule.company !== (row.company || '')) continue;
    if (rule.from && normName(rule.from) !== normName(row.asked_by || (row.reply_to && row.reply_to.from))) continue;
    let re;
    try { re = new RegExp(rule.match, 'i'); } catch { continue; }
    if (!re.test(row.question)) continue;
    const want = optionLabel(rule.answer);
    const opt = (row.options || []).find((x) => optionLabel(x.label) === want);
    if (!opt && !rule.free) continue;
    const answer = opt ? opt.label.replace(/\s*\(recommended\)\s*$/i, '') : clean(rule.answer, 2000);
    if (!rule.irreversible && IRREVERSIBLE.test(answer)) continue;
    return { rule, answer };
  }
  return null;
}

export function addDecision(file, o) {
  for (const k of ['source', 'ref', 'question']) if (!o[k]) throw new Error(`add needs ${k}`);
  if (!SOURCES.has(o.source)) throw new Error(`source must be one of ${[...SOURCES].join(', ')}`);
  const options = (o.options || []).map((x) => (typeof x === 'string' ? { label: x } : x))
    .filter((x) => x && x.label).map((x) => ({ label: clean(x.label, 60), description: clean(x.description, 200) || undefined, recommended: !!x.recommended }));
  if (options.length < 2 || options.length > 4) throw new Error('add needs two to four --option values');
  if (!options.some((x) => x.recommended)) options[0].recommended = true;
  const at = o.at || new Date().toISOString();
  const ref = clean(o.ref, 200);
  return withLockSync(file, () => {
    const dup = fold(readRows(file)).find((r) => r.source === o.source && r.ref === ref && !['dropped'].includes(r.status));
    if (dup) return { id: dup.id, dup: true };
    const row = {
      id: decisionId(o.source, ref, at), at, source: o.source, ref, status: 'open',
      question: clean(o.question), options, priority: String(o.priority || '').trim().toLowerCase() === 'critical' ? 'critical' : 'normal',
      lane: LANES.includes(o.lane) ? o.lane : undefined,
      company: clean(o.company, 60) || undefined,
      relay: (o.relay && (o.relay.session || o.relay.child)) ? { session: o.relay.session || undefined, child: o.relay.child || undefined, link: o.relay.link || undefined } : undefined,
      asked_by: clean(o.askedBy, 80) || undefined,
      // Where the answer goes when there is no session to relay to: the
      // channel or DM the request came from (a ledger row's source and ref).
      reply_to: o.replyTo && o.replyTo.source ? { source: clean(o.replyTo.source, 20), ref: clean(o.replyTo.ref, 200), from: clean(o.replyTo.from, 80) || undefined } : undefined,
    };
    append(file, row);
    const hit = o.standing === false ? null : matchStanding(o.standing || readStanding(), row);
    if (hit) {
      append(file, { id: row.id, at, status: 'answered', answer: hit.answer, by: 'standing', note: `standing ${hit.rule.id}` });
      return { id: row.id, dup: false, standing: hit.rule.id, answer: hit.answer };
    }
    return { id: row.id, dup: false };
  });
}

export function setStatus(file, id, status, extra = {}, at = new Date().toISOString()) {
  if (!NEXT[status] || status === 'open') throw new Error(`status must be one of ${Object.keys(NEXT).filter((s) => s !== 'open').join(', ')}`);
  return withLockSync(file, () => {
    const cur = fold(readRows(file)).find((r) => r.id === id);
    if (!cur) throw new Error(`no decision ${id}`);
    if (!NEXT[cur.status].has(status)) throw new Error(`cannot move ${id} from ${cur.status} to ${status}`);
    if (status === 'answered' && !extra.answer) throw new Error('answered needs --answer');
    if (status === 'dropped' && !clean(extra.note)) throw new Error('drop needs --note <why>: a dropped decision always records why');
    // An answer is the owner's pick in one desk's open picker. Every answer
    // names that desk (--desk), and the row must hold that desk's fresh claim
    // (`next --claim` or `claim --id`): an answer with no desk, from a desk
    // that did not claim the row, or after the claim lapsed is refused. The
    // conductor is a desk only for critical rows (a critical card asked in
    // its own window).
    if (status === 'answered') {
      const nowMs = Date.parse(at) || Date.now();
      const desk = clean(extra.desk, 40);
      if (!desk) throw new Error(`answer needs --desk <desk name>: the desk whose picker the owner answered (claim the row first)`);
      if (cur.claimed_by !== desk || !freshClaim(cur, nowMs)) throw new Error(`${id} is not claimed by ${desk}${cur.claimed_by && freshClaim(cur, nowMs) ? ` (claimed by ${cur.claimed_by})` : ''}; claim it first with next --claim ${desk} or claim --id ${id} --desk ${desk}`);
      if ((desk === 'conductor' || extra.by === 'conductor') && cur.priority !== 'critical') throw new Error('the conductor answers only critical rows; every other row is asked on the desk');
    }
    const row = { id, at, status };
    if (extra.answer) row.answer = clean(extra.answer, 2000);
    if (extra.note) row.note = clean(extra.note);
    if (extra.result) row.result = clean(extra.result, 200);
    if (extra.by) row.by = clean(extra.by, 20);
    if (status === 'answered' && extra['relay-by'] === 'desk') {
      if (!(cur.relay && (cur.relay.session || cur.relay.child))) throw new Error('--relay-by desk needs a relay session or child on the row');
      row.relay_by = 'desk';
    }
    append(file, row);
    return { from: cur.status, to: status };
  });
}

// The same question asked again within `windowMs` (a teammate or an
// assistant bot repeating itself, a bot echoing a decision already on the
// queue) is a duplicate, whatever its source. Rows are compared on their
// question text without the "<who> (<source>): " prefix triage adds; a row
// dropped as a duplicate itself never anchors another match.
export const DUP_WINDOW_MS = 24 * 3600 * 1000;
export const normalizeQuestion = (t) => clean(t, 2000).replace(/^[^:()]{1,80}\s\([a-z_]+\):\s*/i, '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
const normName = (t) => clean(t, 80).toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
// A duplicate is the same words from the same person (or the same source
// thread) in the same company. A different person asking the same generic
// question ("can you review my PR?") is a new decision with its own reply
// path; another company's row never matches. A dropped row (for any reason)
// does not anchor a match: a repeat after a drop may carry new information.
// `ask` is {question, from, company, source, ref}.
export function findDuplicate(reqs, ask, nowMs = Date.now(), windowMs = DUP_WINDOW_MS) {
  const a = typeof ask === 'string' ? { question: ask } : (ask || {});
  const key = normalizeQuestion(a.question);
  if (key.length < 20) return null;
  const from = normName(a.from);
  const company = clean(a.company, 60) || '';
  return reqs.find((r) => nowMs - Date.parse(r.at) < windowMs
    && r.status !== 'dropped'
    && (r.company || '') === company
    && (
      (from && normName(r.asked_by || (r.reply_to && r.reply_to.from)) === from)
      || (a.source && a.ref && r.reply_to && r.reply_to.source === a.source && r.reply_to.ref === clean(a.ref, 200))
    )
    && normalizeQuestion(r.question) === key) || null;
}

// Oldest open decision, critical first.
export function nextOpen(reqs) {
  const open = reqs.filter((r) => r.status === 'open');
  open.sort((a, b) => (a.priority === 'critical' ? 0 : 1) - (b.priority === 'critical' ? 0 : 1) || Date.parse(a.at) - Date.parse(b.at));
  return open[0] || null;
}

// Desk lanes. Several desks can serve one queue; each serves one lane, so a
// row is woken on exactly one desk. A row's lane is set at add time
// (--lane) or derived from its question and ref: merges for a merge, release,
// deploy, tag or rollout go; asks for a teammate's request or a child
// session's ask; general for the rest. A desk run with no --lane serves every
// lane (the single-desk setup).
export const LANES = ['merges', 'asks', 'general'];
export function laneOf(r) {
  if (r.lane && LANES.includes(r.lane)) return r.lane;
  const t = `${r.ref || ''} ${r.question || ''}`;
  if (/\b(merge|merged|release|releases|deploy|redeploy|tag|rollout|roll out|cut v?\d|publish)\b/i.test(t)) return 'merges';
  if (r.source === 'ledger' || r.source === 'ask') return 'asks';
  return 'general';
}
const inLane = (r, lane) => !lane || laneOf(r) === lane;

// A desk claims a row when it asks it; another desk skips a row claimed by
// someone else within CLAIM_TTL_MS (the picker is open there). A claim that
// outlives the TTL (the desk was closed mid-picker) lapses and the row can be
// asked again.
export const CLAIM_TTL_MS = 15 * 60 * 1000;
const freshClaim = (r, nowMs) => !!(r.claimed_by && nowMs - Date.parse(r.claimed_at) < CLAIM_TTL_MS);
export const claimedByOther = (r, desk, nowMs = Date.now()) => freshClaim(r, nowMs) && r.claimed_by !== desk;

export function claimNext(file, { lane, desk, now } = {}) {
  return claimOpen(file, { lane, desk, now, count: 1 })[0] || null;
}

// Up to `count` distinct open rows in ask order, claimed in one lock, so one
// desk drain never gets the same row twice. When the first row is critical
// only critical rows come back (a critical picker is never mixed with routine
// rows). The desk's own claims are not skipped: a desk restarted mid-picker
// re-asks the rows it had claimed instead of waiting out CLAIM_TTL_MS.
export function claimOpen(file, { lane, desk, now, count = 1 } = {}) {
  return withLockSync(file, () => {
    const nowMs = now ? Date.parse(now) : Date.now();
    const open = fold(readRows(file)).filter((r) => r.status === 'open' && inLane(r, lane) && !claimedByOther(r, desk, nowMs) && (desk !== 'conductor' || r.priority === 'critical'));
    const picked = [];
    while (picked.length < count) {
      const r = nextOpen(open.filter((x) => !picked.includes(x)));
      if (!r || (picked.length && picked[0].priority === 'critical' && r.priority !== 'critical')) break;
      picked.push(r);
    }
    if (!desk) return picked;
    // A caller-supplied --now can move a claim back, never forward: a claim
    // dated in the future would hide the row from every other desk.
    const at = new Date(Math.min(nowMs, Date.now())).toISOString();
    return picked.map((r) => {
      append(file, { id: r.id, at, claimed_by: clean(desk, 40), claimed_at: at });
      return { ...r, claimed_by: clean(desk, 40), claimed_at: at };
    });
  });
}

// Claim one named open row for a desk. Throws when the row is not open, or the
// conductor asks for a normal row; returns {claimed:false, by} when another
// desk holds a fresh claim.
export function claimId(file, id, desk) {
  const d = clean(desk, 40);
  if (!d) throw new Error('claim needs --desk <desk name>');
  return withLockSync(file, () => {
    const cur = fold(readRows(file)).find((r) => r.id === id);
    if (!cur) throw new Error(`no decision ${id}`);
    if (cur.status !== 'open') throw new Error(`${id} is ${cur.status}, not open`);
    if (d === 'conductor' && cur.priority !== 'critical') throw new Error('the conductor claims only critical rows');
    const nowMs = Date.now();
    if (claimedByOther(cur, d, nowMs)) return { claimed: false, by: cur.claimed_by };
    const at = new Date(nowMs).toISOString();
    append(file, { id, at, claimed_by: d, claimed_at: at });
    return { claimed: true };
  });
}

export function select(reqs, o) {
  const statuses = o.status ? new Set(o.status.split(',')) : null;
  return reqs.filter((r) => (!o.open || r.status === 'open') && (!statuses || statuses.has(r.status)) && inLane(r, o.lane));
}

export function line(r) {
  const opts = r.options.map((x) => `${x.label}${x.recommended ? ' (Recommended)' : ''}`).join(' / ');
  return `${r.id} | ${r.status} | ${r.priority} | ${laneOf(r)} | ${r.source}:${r.ref} | ${r.question} | ${opts}${r.answer ? ` | answer: ${r.answer}` : ''}`;
}

function parse(argv, allowed, repeatable = []) {
  const o = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) die(`unexpected argument ${a}`);
    const k = a.slice(2);
    if (!allowed.includes(k)) die(`unexpected argument ${a}`);
    if (['open', 'json', 'once', 'no-standing', 'free', 'critical', 'irreversible'].includes(k)) { o[k] = true; continue; }
    if (argv[i + 1] === undefined) die(`${a} needs a value`);
    const v = argv[++i];
    if (repeatable.includes(k)) (o[k] ||= []).push(v); else o[k] = v;
  }
  return o;
}

function add(argv) {
  const o = parse(argv, ['file', 'source', 'ref', 'question', 'option', 'recommended', 'company', 'priority', 'relay-session', 'relay-child', 'relay-link', 'asked-by', 'at', 'no-standing', 'lane'], ['option']);
  if (!o.file) die('add needs --file');
  if (o.priority !== undefined && !['critical', 'normal'].includes(String(o.priority).trim().toLowerCase())) die('--priority must be critical or normal');
  if (o.lane && !LANES.includes(o.lane)) die(`--lane must be one of ${LANES.join(', ')}`);
  const options = (o.option || []).map((s) => { const [label, description] = s.split('::'); return { label, description, recommended: o.recommended ? label === o.recommended : false }; });
  let r;
  try {
    const standing = o['no-standing'] ? false : readStanding();
    r = addDecision(o.file, { ...o, options, standing, relay: { session: o['relay-session'], child: o['relay-child'], link: o['relay-link'] }, askedBy: o['asked-by'] });
  } catch (e) { die(e.message); }
  process.stdout.write(`${r.id}${r.standing ? ` answered by standing ${r.standing}: ${r.answer}` : ''}\n`);
  if (r.dup) process.exit(3);
}

// standing add --by desk --match <regex> --answer <label> --expires <Nd|ISO>
//   --note <owner's words> [--source ledger|ask|conductor] [--from <who>]
//   [--company <slug>] [--critical] [--free] [--irreversible]
// standing list [--json] | standing remove|disable --id <id> --by desk --note <why>
// A rule's answer is one of the row's option labels (compared without the
// "(Recommended)" suffix) unless --free; a rule never answers a critical row
// unless --critical, and a free-text rule never does. --irreversible lets a
// rule answer a merge, deploy, send or money row; only the owner's explicit
// words set it. Only the decision desk writes rules (--by desk). Every add,
// disable and remove is appended to <rules file>.log.jsonl. The rules file is
// $SC_STANDING_FILE or the HQ default; there is no per-call override.
function parseExpires(v, nowMs) {
  const m = /^(\d{1,3})d$/.exec(String(v || '').trim());
  const t = m ? nowMs + Number(m[1]) * 86400000 : Date.parse(v);
  return Number.isNaN(t) ? null : t;
}
function standing(argv) {
  const [sub, ...rest] = argv;
  const o = parse(rest, ['match', 'answer', 'source', 'from', 'company', 'critical', 'free', 'irreversible', 'note', 'id', 'json', 'by', 'expires']);
  const file = standingFile();
  const all = (() => { try { const v = JSON.parse(fs.readFileSync(file, 'utf8')); return Array.isArray(v) ? v : []; } catch { return []; } })();
  const log = (entry) => { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.appendFileSync(`${file}.log.jsonl`, `${JSON.stringify({ at: new Date().toISOString(), ...entry })}\n`); };
  if (sub === 'list') {
    const nowMs = Date.now();
    for (const r of all) {
      const bad = standingProblem(r);
      const state = bad ? `ignored (${bad})` : r.disabled ? 'disabled' : nowMs >= Date.parse(r.expires) ? 'expired' : 'on';
      process.stdout.write(`${o.json ? JSON.stringify(r) : `${r.id} | ${state} | /${r.match}/ → ${r.answer}${r.source ? ` | source ${r.source}` : ''}${r.from ? ` | from ${r.from}` : ''}${r.company ? ` | company ${r.company}` : ''}${r.critical ? ' | critical too' : ''}${r.free ? ' | free text' : ''}${r.irreversible ? ' | irreversible' : ''}${r.expires ? ` | until ${r.expires}` : ''} | ${r.note || ''}`}\n`);
    }
    if (!all.length) process.exit(3);
    return;
  }
  if (!['add', 'remove', 'disable'].includes(sub)) die('usage: standing add|list|remove|disable ...');
  if (o.by !== 'desk') die(`standing ${sub} needs --by desk: only the decision desk writes rules, on the owner's words`);
  if (sub === 'add') {
    if (!o.match || !o.answer) die('standing add needs --match <regex> and --answer <label>');
    if (!clean(o.note)) die('standing add needs --note: who set the rule, when, and their words');
    if (o.source && !SOURCES.has(o.source)) die(`--source must be one of ${[...SOURCES].join(', ')}`);
    const nowMs = Date.now();
    const exp = parseExpires(o.expires, nowMs);
    if (exp === null) die(`standing add needs --expires <days>d or an ISO time, at most ${STANDING_MAX_DAYS} days out`);
    if (exp <= nowMs) die('--expires is in the past');
    const at = new Date(nowMs).toISOString();
    const id = `sa_${createHash('sha256').update(`${o.match}\0${o.answer}\0${o.source || ''}\0${o.from || ''}\0${o.company || ''}`).digest('hex').slice(0, 8)}`;
    const rule = { id, at, expires: new Date(exp).toISOString(), match: String(o.match).replace(/[\u0000-\u001f\u007f]+/g, ' ').trim().slice(0, 400), answer: clean(o.answer, 2000), source: o.source || undefined, from: clean(o.from, 80) || undefined, company: clean(o.company, 60) || undefined, critical: !!o.critical || undefined, free: !!o.free || undefined, irreversible: !!o.irreversible || undefined, note: clean(o.note, 200) || undefined };
    const bad = standingProblem(rule);
    if (bad) die(`standing rule refused: ${bad}`);
    if (all.some((r) => r.id === id)) { process.stdout.write(`${id}\n`); process.exit(3); }
    all.push(rule);
    writeStanding(file, all);
    log({ op: 'add', by: 'desk', rule });
    process.stdout.write(`${id}\n`);
    return;
  }
  if (!o.id) die(`standing ${sub} needs --id`);
  const i = all.findIndex((r) => r && r.id === o.id);
  if (i < 0) die(`no standing rule ${o.id}`);
  if (sub === 'remove') all.splice(i, 1); else all[i].disabled = true;
  writeStanding(file, all);
  log({ op: sub, by: 'desk', id: o.id, note: clean(o.note, 200) || undefined });
  process.stdout.write(`${o.id} ${sub === 'remove' ? 'removed' : 'disabled'}\n`);
}

// Open rows waiting longer than `afterMs` at `nowMs`.
export function staleOpen(reqs, afterMs, nowMs = Date.now()) {
  return reqs.filter((r) => r.status === 'open' && nowMs - Date.parse(r.at) >= afterMs)
    .sort((a, b) => Date.parse(a.at) - Date.parse(b.at));
}

function stale(argv) {
  const o = parse(argv, ['file', 'after', 'json', 'now']);
  if (!o.file) die('stale needs --file');
  const rows = staleOpen(fold(readRows(o.file)), Math.max(1, Number(o.after) || 300) * 1000, o.now ? Date.parse(o.now) : Date.now());
  if (!rows.length) process.exit(3);
  for (const r of rows) process.stdout.write(`${o.json ? JSON.stringify(r) : line(r)}\n`);
}

function move(argv, status) {
  const o = parse(argv, ['file', 'id', 'answer', 'note', 'result', 'at', 'by', 'relay-by', 'desk']);
  if (o.by && !['desk', 'conductor'].includes(o.by)) die('--by must be desk or conductor');
  if (o['relay-by'] && o['relay-by'] !== 'desk') die('--relay-by takes desk');
  if (!o.file || !o.id) die(`${status} needs --file and --id`);
  let r;
  try { r = setStatus(o.file, o.id, status, o, o.at || new Date().toISOString()); } catch (e) { die(e.message); }
  process.stdout.write(`${o.id} ${r.from} → ${r.to}\n`);
}

function next(argv) {
  const o = parse(argv, ['file', 'json', 'lane', 'claim', 'now', 'count']);
  if (!o.file) die('next needs --file');
  if (o.lane && !LANES.includes(o.lane)) die(`--lane must be one of ${LANES.join(', ')}`);
  if (o.count !== undefined && !/^[1-9]\d*$/.test(o.count)) die('--count must be a positive integer');
  const rows = claimOpen(o.file, { lane: o.lane, desk: o.claim, now: o.now, count: o.count ? Number(o.count) : 1 });
  if (!rows.length) process.exit(3);
  const out = rows.map((r) => ({ ...r, lane: laneOf(r) }));
  // --count always prints a JSON array with --json, even for one row.
  if (o.json) process.stdout.write(`${JSON.stringify(o.count ? out : out[0])}\n`);
  else for (const r of out) process.stdout.write(`${line(r)}\n`);
}

function claim(argv) {
  const o = parse(argv, ['file', 'id', 'desk']);
  if (!o.file || !o.id || !o.desk) die('claim needs --file, --id and --desk');
  let r;
  try { r = claimId(o.file, o.id, o.desk); } catch (e) { die(e.message); }
  if (!r.claimed) { process.stdout.write(`${o.id} claimed by ${r.by}\n`); process.exit(3); }
  process.stdout.write(`${o.id} claimed by ${clean(o.desk, 40)}\n`);
}

function list(argv) {
  const o = parse(argv, ['file', 'open', 'status', 'json', 'lane']);
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

const stamp = () => new Date().toISOString().replace(/\.\d+Z$/, 'Z');
const clip = (t, n) => { const x = clean(t, n + 1); return x.length > n ? `${x.slice(0, n - 1)}…` : x; };

// One wake line per event, printed once. `seen` (ids already announced) is
// kept next to the queue so a restart does not repeat lines.
// How long the conductor leaves a desk-relayed answer alone before relaying it
// itself (the desk's relay failed or its session is gone).
export const RELAY_GRACE_MS = 120_000;
export const STALE_AFTER_MS = 300_000;

export function wakeLines(reqs, forWhom, seen, opts = {}) {
  const out = [];
  const nowMs = opts.now ? Date.parse(opts.now) : Date.now();
  if (forWhom === 'desk') {
    reqs = reqs.filter((r) => inLane(r, opts.lane) && !claimedByOther(r, opts.desk, nowMs));
    const open = reqs.filter((r) => r.status === 'open' && !seen.has(`open:${r.id}`));
    if (open.length) {
      const first = nextOpen(open);
      for (const r of open) seen.add(`open:${r.id}`);
      out.push(`SUPER-CONDUCTOR DECISION ${stamp()} | ${open.length} open${open.some((r) => r.priority === 'critical' ) ? ', critical first' : ''}: ${clip(first.question, 160)} [${first.options.map((x) => clip(x.label, 30)).join(' / ')}] | id ${first.id} | Send the owner one push notification (PushNotification) with the open count only (never the question text), then run /decision-desk now: up to four rows per picker, answer, repeat until next exits 3.`);
    }
    // A row the owner has not seen for a while: once per row, the desk sends
    // a phone notification so the wait does not depend on the owner looking.
    const late = staleOpen(reqs, opts.staleAfterMs ?? STALE_AFTER_MS, nowMs).filter((r) => !seen.has(`stale:${r.id}`));
    if (late.length) {
      const first = late[0];
      for (const r of late) seen.add(`stale:${r.id}`);
      const mins = Math.max(1, Math.round((nowMs - Date.parse(first.at)) / 60000));
      out.push(`SUPER-CONDUCTOR STALE-DECISION ${stamp()} | ${late.length} waiting over ${mins}m${late.some((r) => r.priority === 'critical') ? ', critical' : ''}: ${clip(first.question, 160)} | id ${first.id} | Send the owner one push notification (PushNotification) with the waiting count only (never the question text), then run Step 3.`);
    }
  } else {
    for (const r of reqs) {
      if (r.status !== 'answered' || seen.has(`answered:${r.id}`)) continue;
      // The desk relays its own answers; the conductor steps in only when the
      // row is still answered after the grace period.
      if (r.relay_by === 'desk' && nowMs - Date.parse(r.updated_at || r.at) < RELAY_GRACE_MS) continue;
      seen.add(`answered:${r.id}`);
      // A child session, or for a ledger row the teammate who asked, on the
      // channel or DM it came from (the ledger row carries source and ref).
      const to = r.relay && (r.relay.child || r.relay.session)
        ? `${r.relay.child || ''}${r.relay.session ? ` (${r.relay.session})` : ''}`.trim()
        : r.reply_to ? `${clip(r.reply_to.from || r.asked_by || 'the sender', 40)} via ${r.reply_to.source}:${clip(r.reply_to.ref, 60)} (reply where it was asked)`
        : r.asked_by ? `${clip(r.asked_by, 40)} via ${r.source}:${clip(r.ref, 60)} (reply where it was asked)` : 'no relay target';
      const who = r.by === 'standing' ? ` | answered by ${clip(r.note || 'standing rule', 60)}, never asked` : '';
      out.push(`SUPER-CONDUCTOR ANSWER ${stamp()} | ${clip(r.question, 120)} → ${clip(r.answer, 160)} | relay to ${to || 'no relay target'}${who} | id ${r.id} | Relay it as a quoted OWNER GO on the link and by direct message in this turn, then decisions.mjs relayed --id ${r.id}.`);
    }
  }
  return out;
}

async function watch(argv) {
  const o = parse(argv, ['file', 'for', 'interval', 'parent-pid', 'once', 'stale-after', 'now', 'lane', 'desk']);
  if (o.lane && !LANES.includes(o.lane)) die(`--lane must be one of ${LANES.join(', ')}`);
  if (!o.file || !['desk', 'conductor'].includes(o.for)) die('watch needs --file and --for desk|conductor');
  const every = Math.max(1, Number(o.interval) || 5) * 1000;
  const wakeOpts = { staleAfterMs: Math.max(1, Number(o['stale-after']) || STALE_AFTER_MS / 1000) * 1000, now: o.now, lane: o.lane, desk: o.desk || (o.lane ? `desk-${o.lane}` : undefined) };
  const seenFile = `${o.file.replace(/\.jsonl$/, '')}-${o.for}${o.for === 'desk' && o.lane ? `-${o.lane}` : ''}-seen.json`;
  const seen = new Set((() => { try { return JSON.parse(fs.readFileSync(seenFile, 'utf8')); } catch { return []; } })());
  const parentAlive = () => {
    if (!o['parent-pid']) return true;
    try { process.kill(Number(o['parent-pid']), 0); return true; } catch (e) { return e.code === 'EPERM'; }
  };
  for (;;) {
    if (!parentAlive()) return;
    const before = seen.size;
    for (const l of wakeLines(fold(readRows(o.file)), o.for, seen, wakeOpts)) process.stdout.write(`${l}\n`);
    if (seen.size !== before) {
      const tmp = `${seenFile}.${process.pid}.tmp`;
      fs.mkdirSync(path.dirname(seenFile), { recursive: true });
      fs.writeFileSync(tmp, JSON.stringify([...seen].slice(-2000)));
      replaceFile(tmp, seenFile);
    }
    if (o.once) return;
    await new Promise((r) => setTimeout(r, every));
  }
}

function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  if (cmd === 'add') add(rest);
  else if (cmd === 'answer') move(rest, 'answered');
  else if (cmd === 'relayed') move(rest, 'relayed');
  else if (cmd === 'drop') move(rest, 'dropped');
  else if (cmd === 'next') next(rest);
  else if (cmd === 'claim') claim(rest);
  else if (cmd === 'list') list(rest);
  else if (cmd === 'count') count(rest);
  else if (cmd === 'stale') stale(rest);
  else if (cmd === 'standing') standing(rest);
  else if (cmd === 'watch') watch(rest);
  else die('usage: add|answer|relayed|drop|next|claim|list|count|stale|watch --file <queue> ... | standing add|list|remove|disable ...');
}

if (isMain(import.meta.url)) main();
