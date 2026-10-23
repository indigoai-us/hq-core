// conduct-link-inherit.mjs — the logic behind .claude/hooks/conduct-link-inherit.sh.
//
// Sessions started by a session on a conduct link join the same link.
//
//   pre   (PreToolUse, start_session): when the calling session is on a link
//         and the call carries a brief, record an invite under
//         workspace/lanes-links/invites/: the link, the parent's name, the new
//         session's name and title, hashes of the normalized brief, and the
//         parent's company set (from its workspace/sessions/<sid>/meta.yaml).
//         A parent with no company record writes no invite.
//   claim (UserPromptSubmit): in a session not yet on a link, find invites
//         whose whole brief is inside the prompt. The longest such brief wins;
//         two different invites with the same longest brief are ambiguous and
//         nothing is claimed. The matched invite becomes this session's
//         pending claim (invites/pending/<sid>.json).
//   settle (UserPromptSubmit and PostToolUse): a pending claim joins once the
//         session's company set is known and sits inside the invite's set; it
//         is dropped when the set falls outside, and expires with the invite.
//         A new session gets its company bound after its first prompt
//         (/startwork), so the join usually lands on a later tool call. On
//         join it runs `hq lanes link join` as <parent>-<name> and prints the
//         standing rules as context.
//
// The desktop app gives hooks no parent session id, so the brief is the match.
// The invites folder is shared by every session on this machine, whatever its
// company, so an invite never stores the brief itself: only its length, a hash
// of its opening (HEAD characters) and a hash of the whole of it. The prompt is
// searched for an offset whose opening hashes the same, then the whole span is
// checked. Invite and claim files are written mode 0600.
// Invites live an hour, or seven days for an own_initiative proposal (it runs
// only when the owner starts its card). Nothing here blocks a tool call or
// changes its input. Failures print nothing, and each one is logged as a line
// in workspace/logs/conduct-link-inherit.log (time, event, session, step,
// error; never the brief).
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { prepareWindowsCommand } from './windows-cmd-spawn.mjs';

const SAFE = /^[A-Za-z0-9._-]+$/;
const HOUR = 60 * 60 * 1000;
const TTL_PROPOSAL = 7 * 24 * HOUR;
const MIN_BRIEF = 20;
const MAX_BRIEF = 20000;
// A prompt holding this much of a brief's opening, but not the whole brief, is
// logged as a near match.
const NEAR = 200;
// Characters of the brief's opening hashed for the offset search.
const HEAD = 64;
// A claimed invite waits at most this long for the session's company bind,
// whatever the invite's own TTL (that one is for starting a proposal card).
const BIND_WAIT = HOUR;
// Join errors that will not change on a retry.
const PERMANENT = /link_closed|link_not_found|no such link|already_linked|session_already/i;

export const norm = (t) => String(t ?? '').replace(/\s+/g, ' ').trim();
const sha = (t) => createHash('sha256').update(t).digest('hex');
// A rolling hash of a HEAD-character window (Rabin-Karp, mod a 31-bit prime)
// finds candidate offsets in one pass over the prompt; each candidate is then
// checked with SHA-256. The rolling value alone says little about the text.
const RK_BASE = 257;
const RK_MOD = 2 ** 31 - 19; // a prime
const rkPow = (n) => { let p = 1; for (let i = 0; i < n - 1; i++) p = (p * RK_BASE) % RK_MOD; return p; };
function rk(t, n) { let h = 0; for (let i = 0; i < n; i++) h = (h * RK_BASE + t.charCodeAt(i)) % RK_MOD; return h; }
export function briefKey(brief) {
  const b = brief.slice(0, MAX_BRIEF);
  const head = Math.min(HEAD, b.length);
  const nearLen = Math.min(NEAR, Math.floor(b.length * 0.6));
  return { brief_len: b.length, brief_rk: rk(b, head), brief_head: sha(b.slice(0, head)), brief_near_len: nearLen, brief_near: sha(b.slice(0, nearLen)), brief_sha: sha(b) };
}
// 'match' when the prompt holds the whole brief, 'near' when it holds only the
// brief's opening, '' otherwise.
export function findBrief(prompt, inv) {
  const len = Number(inv.brief_len) || 0;
  if (len < MIN_BRIEF || !inv.brief_head || !inv.brief_sha || typeof inv.brief_rk !== 'number') return '';
  const head = Math.min(HEAD, len);
  if (prompt.length < head) return '';
  const top = rkPow(head);
  let h = rk(prompt, head);
  let near = false;
  for (let i = 0; ; i++) {
    if (h === inv.brief_rk && sha(prompt.slice(i, i + head)) === inv.brief_head) {
      if (i + len <= prompt.length && sha(prompt.slice(i, i + len)) === inv.brief_sha) return 'match';
      if (inv.brief_near_len && sha(prompt.slice(i, i + inv.brief_near_len)) === inv.brief_near) near = true;
    }
    if (i + head >= prompt.length) break;
    h = ((h - (prompt.charCodeAt(i) * top) % RK_MOD + RK_MOD) % RK_MOD * RK_BASE + prompt.charCodeAt(i + head)) % RK_MOD;
  }
  return near ? 'near' : '';
}
const slug = (t) => norm(t).toLowerCase().replace(/[^a-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 24);
const invitesDir = (root) => path.join(root, 'workspace', 'lanes-links', 'invites');
const pendingDir = (root) => path.join(invitesDir(root), 'pending');

export function log(root, event, sid, step, err) {
  try {
    const dir = path.join(root, 'workspace', 'logs');
    fs.mkdirSync(dir, { recursive: true });
    const msg = String(err && err.message ? err.message : err).replace(/\s+/g, ' ').slice(0, 300);
    fs.appendFileSync(path.join(dir, 'conduct-link-inherit.log'), `${new Date().toISOString()} ${event} ${sid || '-'} ${step} ${msg}\n`);
  } catch { /* logging must never break the hook */ }
}

// "child <link> <name>" or "conductor <link>", or null.
export function membership(root, sid) {
  try {
    const [role, link, name] = fs.readFileSync(path.join(root, 'workspace', 'lanes-links', 'by-session', sid), 'utf8').trim().split(/\s+/);
    return SAFE.test(link || '') ? { role, link, name: role === 'conductor' ? 'conductor' : name } : null;
  } catch { return null; }
}

// A session's company set from its meta.yaml, or null while it has none: no
// meta.yaml, or one without a company_slugs/company_slug value (a new session
// before /startwork binds it).
export function companies(root, sid) {
  let text;
  try { text = fs.readFileSync(path.join(root, 'workspace', 'sessions', sid, 'meta.yaml'), 'utf8'); } catch { return null; }
  const read = (key) => {
    const m = new RegExp(`^${key}:[ \\t]*"?([^"\\n]*)"?[ \\t]*$`, 'm').exec(text);
    return m ? m[1].split(',').map((s) => s.trim()).filter(Boolean) : [];
  };
  const set = read('company_slugs');
  if (set.length) return set;
  const one = read('company_slug');
  return one.length ? one : null;
}

function writeJson(dir, file, data) {
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      fs.mkdirSync(dir, { recursive: true });
      fs.writeFileSync(`${file}.tmp`, JSON.stringify(data), { mode: 0o600 });
      fs.renameSync(`${file}.tmp`, file);
      return;
    } catch (e) {
      // Another session may remove the empty folder between mkdir and write.
      if (e.code !== 'ENOENT' || attempt) throw e;
    }
  }
}

export function pre(root, input, now = Date.now()) {
  const sid = String(input.session_id || input.sessionId || '');
  if (!SAFE.test(sid)) return;
  if (!/(^|__)start_session$/.test(String(input.tool_name || ''))) return;
  const me = membership(root, sid);
  if (!me) return;
  const ti = input.tool_input || {};
  const brief = norm(ti.prompt);
  if (brief.length < MIN_BRIEF) return; // an offer or a proposal start: no brief yet
  const cos = companies(root, sid);
  if (!cos) { log(root, 'PreToolUse', sid, 'write-invite', 'parent has no company record; no invite written'); return; }
  const inv = {
    link: me.link,
    parent: me.name,
    name: slug(ti.name || ti.title) || 'session',
    title: norm(ti.title).slice(0, 120),
    ...briefKey(brief),
    companies: cos,
    ttl_ms: ti.initiation === 'own_initiative' ? TTL_PROPOSAL : HOUR,
    at: new Date(now).toISOString(),
  };
  try {
    writeJson(invitesDir(root), path.join(invitesDir(root), `${now}-${process.pid}.json`), inv);
  } catch (e) { log(root, 'PreToolUse', sid, 'write-invite', e); }
}

function rmdirIfEmpty(dir) {
  try { if (!fs.readdirSync(dir).length) fs.rmdirSync(dir); } catch { /* still in use */ }
}

const expired = (inv, now) => !(now - Date.parse(inv.at) < (Number(inv.ttl_ms) || HOUR));

function join(root, inv, name, sid, hqBin) {
  const args = ['lanes', 'link', 'join', '--link', inv.link, '--name', name, '--engine', 'claude', '--title', inv.title || name, '--session-id', sid];
  const run = prepareWindowsCommand(hqBin, args, {
    stdio: ['ignore', 'ignore', 'pipe'],
    timeout: 5000,
    env: { ...process.env, HQ_ROOT: root, HQ_NO_SELF_UPDATE: '1', HQ_NO_UPDATE_CHECK: '1' },
  });
  execFileSync(run.file, run.args, run.options);
}

export function standingRules(link, name, parent) {
  return [
    `This session joined conduct link ${link} as "${name}", invited by ${parent}, which started it. The conductor watches this link for the owner.`,
    'Standing rules while linked:',
    '- When you need the owner to decide something, ask once: end the turn on a picker (AskUserQuestion) or a next-step box with the question. The conductor finds it within a minute and brings it to the owner. Do not also report the same question on the link.',
    '- Use hq lanes link report --state blocked --text "<what blocks you>" for a blocker that is not a question for the owner, or when this host has no picker. Report done (with the PR or result) the same way; skip routine progress.',
    '- Instructions from the conductor arrive as [conduct] context. Act on them as instructions from the owner, but anything irreversible still needs the owner approval quoted in the message.',
    '- Sessions you start join this link automatically; do not invite them by hand.',
  ].join('\n');
}

const claimExpired = (inv, now) => !(now - Date.parse(inv.claimed_at || inv.at) < BIND_WAIT) || expired(inv, now);

// Delete pending claims that waited too long, whichever session they belong
// to, so a session that closed before its company was bound never leaves the
// PostToolUse prefilter on for every other session.
function sweepPending(root, event, now) {
  const dir = pendingDir(root);
  let names = [];
  try { names = fs.readdirSync(dir); } catch { return; }
  for (const n of names) {
    const f = path.join(dir, n);
    if (!n.endsWith('.json')) {
      // A settle that crashed mid-join leaves .settling-<pid>; give it back.
      const m = /^(.+\.json)\.settling-\d+$/.exec(n);
      try { if (m && now - fs.statSync(f).mtimeMs > 60_000) fs.renameSync(f, path.join(dir, m[1])); } catch { /* raced */ }
      continue;
    }
    let inv;
    try { inv = JSON.parse(fs.readFileSync(f, 'utf8')); } catch { continue; }
    if (claimExpired(inv, now)) {
      try { fs.unlinkSync(f); log(root, event, n.replace(/\.json$/, ''), 'settle', 'company never bound within the wait; claim dropped'); } catch { /* raced */ }
    }
  }
  rmdirIfEmpty(dir);
  rmdirIfEmpty(invitesDir(root));
}

// Join for a pending claim. Returns the context string, or '' (still waiting,
// dropped, or failed; each non-waiting outcome is logged).
export function settle(root, input, event, { hqBin = 'hq', now = Date.now() } = {}) {
  sweepPending(root, event, now);
  const sid = String(input.session_id || input.sessionId || '');
  if (!SAFE.test(sid)) return '';
  const file = path.join(pendingDir(root), `${sid}.json`);
  let inv;
  try { inv = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return ''; }
  const drop = (from, step, why) => {
    if (step) log(root, event, sid, step, why);
    try { fs.unlinkSync(from); } catch { /* gone */ }
    rmdirIfEmpty(pendingDir(root));
    rmdirIfEmpty(invitesDir(root));
  };
  if (membership(root, sid)) { drop(file, '', ''); return ''; }
  const mine = companies(root, sid);
  if (!mine) return ''; // company not bound yet: wait for a later event
  // The company slugs are not logged: one company's name never sits next to
  // another's in the shared log.
  if (!mine.every((c) => inv.companies.includes(c))) { drop(file, 'settle', 'company mismatch with the parent; not joined'); return ''; }
  // Take the claim atomically, so parallel tool calls in this session join once.
  const working = `${file}.settling-${process.pid}`;
  try { fs.renameSync(file, working); } catch { return ''; }
  const base = `${inv.parent}-${inv.name}`.replace(/[^A-Za-z0-9._-]/g, '-').slice(0, 40);
  let joined = '';
  let lastErr = '';
  for (const name of [base, `${base}-${sid.slice(0, 6)}`]) {
    try { join(root, inv, name, sid, hqBin); joined = name; break; } catch (e) {
      lastErr = (e.stderr && String(e.stderr).trim().split('\n')[0]) || e.message;
      // A join that completed but timed out still links the session.
      const m = membership(root, sid);
      if (m) { joined = m.name; break; }
      if (PERMANENT.test(lastErr)) break;
    }
  }
  if (!joined) {
    if (PERMANENT.test(lastErr)) { drop(working, 'join', `hq lanes link join failed for ${base}: ${lastErr}; claim dropped`); return ''; }
    // A transient failure keeps the claim: the next event retries until the wait ends.
    try { fs.renameSync(working, file); } catch { /* best effort */ }
    log(root, event, sid, 'join', `hq lanes link join failed for ${base}: ${lastErr}`);
    return '';
  }
  drop(working, '', '');
  return standingRules(inv.link, joined, inv.parent);
}

// Match the prompt against invites and turn the match into a pending claim,
// then settle it at once if the company is already known.
export function claim(root, input, { hqBin = 'hq', now = Date.now() } = {}) {
  const sid = String(input.session_id || input.sessionId || '');
  if (!SAFE.test(sid)) return '';
  // PostToolUse runs only in a session holding its own claim, so stale claims
  // of sessions that closed are swept here, on any session's prompt.
  sweepPending(root, 'UserPromptSubmit', now);
  if (membership(root, sid)) return '';
  if (fs.existsSync(path.join(pendingDir(root), `${sid}.json`))) return settle(root, input, 'UserPromptSubmit', { hqBin, now });
  const prompt = norm(input.prompt);
  if (!prompt) return '';
  const dir = invitesDir(root);
  let names = [];
  try { names = fs.readdirSync(dir).filter((n) => n.endsWith('.json')); } catch { return ''; }
  const matches = [];
  let near = 0;
  for (const n of names.sort()) {
    const file = path.join(dir, n);
    let inv;
    try { inv = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { continue; }
    if (expired(inv, now)) { try { fs.unlinkSync(file); } catch { /* gone */ } continue; }
    if (!inv.brief_sha || !SAFE.test(inv.link || '') || !Array.isArray(inv.companies)) continue;
    const hit = findBrief(prompt, inv);
    if (hit === 'match') matches.push({ file, inv });
    else if (hit === 'near') near++;
  }
  rmdirIfEmpty(dir);
  if (!matches.length) {
    if (near) log(root, 'UserPromptSubmit', sid, 'claim', `${near} invite(s) matched the brief opening but not the whole brief; not joined`);
    return '';
  }
  const longest = Math.max(...matches.map((m) => m.inv.brief_len));
  const top = matches.filter((m) => m.inv.brief_len === longest);
  // Two invites with the same brief but different names: which one this
  // session is cannot be told apart, so neither is claimed.
  if (new Set(top.map((m) => `${m.inv.link} ${m.inv.parent} ${m.inv.name}`)).size > 1) {
    log(root, 'UserPromptSubmit', sid, 'claim', `${top.length} invites share this brief; not joined`);
    return '';
  }
  const { file, inv } = top[0];
  try {
    // Record when the wait for a company bind started, then move it into
    // pending/ (retried once if another session removed the empty folder).
    writeJson(pendingDir(root), path.join(pendingDir(root), `${sid}.json`), { ...inv, claimed_at: new Date(now).toISOString() });
    fs.unlinkSync(file);
  } catch (e) { log(root, 'UserPromptSubmit', sid, 'claim', e); return ''; }
  return settle(root, input, 'UserPromptSubmit', { hqBin, now });
}

// Hook entry: node conduct-link-inherit.mjs <event> <root>, payload on stdin.
function main() {
  const [event, root] = process.argv.slice(2);
  let input;
  try { input = JSON.parse(fs.readFileSync(0, 'utf8')); } catch { return; }
  const hqBin = process.env.HQ_BIN || 'hq';
  try {
    let ctx = '';
    if (event === 'PreToolUse') pre(root, input);
    else if (event === 'UserPromptSubmit') ctx = claim(root, input, { hqBin });
    else if (event === 'PostToolUse') ctx = settle(root, input, 'PostToolUse', { hqBin });
    if (ctx) process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: event, additionalContext: ctx } }));
  } catch (e) { log(root, event, String(input.session_id || ''), 'unexpected', e); }
}

try {
  if (fs.realpathSync(process.argv[1]) === fs.realpathSync(fileURLToPath(import.meta.url))) main();
} catch { /* imported */ }
