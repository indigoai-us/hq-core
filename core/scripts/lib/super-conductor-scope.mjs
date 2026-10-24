// super-conductor-scope.mjs — the company boundary for /super-conductor's
// message watcher, open-asks checker and HQ channel sweep.
//
// A conductor runs inside one session's locked company set
// (`hq-session.sh get company_slugs`, `personal` when no company is bound). It
// may read and name only what belongs to that set:
//   - a channel row whose `companyUid` is the cloud_uid of a locked company
//     (from companies/manifest.yaml);
//   - a person-to-person conversation (scope or type `personal` or `group`,
//     with no `companyUid`): the owner's own DMs, the same items the hq_dms
//     sweep already reads;
//   - a desktop session whose own company set (workspace/sessions/<id>/meta.yaml)
//     is inside the locked set.
// Everything else is dropped before it is read, printed or stored. A company
// row with no `companyUid`, a locked slug with no cloud_uid, and a session with
// no meta.yaml all fail closed.
//
// --session-companies (in place of --company) reads the set from
// `hq-session.sh get company_slugs` for the calling session, so a skill command
// needs no shell substitution. An empty set fails closed.
//
// CLI:
//   node core/scripts/lib/super-conductor-scope.mjs filter-channels --company <csv>|--session-companies [--exclude <csv>]
//       Reads `hq channels list --json` (an array) or a `hq channels changes`
//       object on stdin and prints it with out-of-scope rows removed. Rows
//       whose slug, name or id is in `hq_channels_exclude` (owner settings,
//       super-conductor-prefs.mjs exclude) or --exclude are removed too, so
//       the hq_channels sweep never reads or counts them.
// Exit: 0 ok, 2 bad arguments or input.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const SLUG = /^[a-z0-9][a-z0-9_-]{0,63}$/;
const PERSON_SCOPES = new Set(['personal', 'group']);

// --company values, repeatable and comma-separated. Returns the slug list, or
// throws on an empty or malformed value.
export function parseCompanies(values) {
  const slugs = [];
  for (const v of values) {
    for (const s of String(v).split(',').map((x) => x.trim()).filter(Boolean)) {
      if (!SLUG.test(s)) throw new Error(`--company: invalid company slug '${s}'`);
      if (!slugs.includes(s)) slugs.push(s);
    }
  }
  if (!slugs.length) throw new Error('--company needs the locked company set (hq-session.sh get company_slugs)');
  return slugs;
}

// The calling session's locked company set, from hq-session.sh. Throws when it
// cannot be read or is empty. HQ_SESSION_SH overrides the script (tests).
export function sessionCompanySlugs(root) {
  const script = process.env.HQ_SESSION_SH || path.join(root, 'core', 'scripts', 'hq-session.sh');
  let out = '';
  try {
    out = execFileSync('bash', [script, 'get', 'company_slugs'], { cwd: root, encoding: 'utf8', timeout: 15000, stdio: ['ignore', 'pipe', 'ignore'] });
  } catch (e) { throw new Error(`--session-companies: hq-session.sh get company_slugs failed (${String(e.message).split('\n')[0]})`); }
  const slugs = out.split(/[\s,]+/).filter(Boolean);
  if (!slugs.length) throw new Error('--session-companies: this session has no locked company set (hq-session.sh get company_slugs printed nothing)');
  return slugs;
}

// slug -> cloud_uid from companies/manifest.yaml (two-space slug keys under
// `companies:`, four-space `cloud_uid:` lines).
export function manifestUids(root) {
  let text = '';
  try { text = fs.readFileSync(path.join(root, 'companies', 'manifest.yaml'), 'utf8'); } catch { return {}; }
  const out = {};
  let inCompanies = false;
  let slug = null;
  for (const line of text.split('\n')) {
    if (/^\S/.test(line)) { inCompanies = /^companies:\s*$/.test(line); slug = null; continue; }
    if (!inCompanies) continue;
    const key = /^ {2}([A-Za-z0-9_-]+):\s*$/.exec(line);
    if (key) { slug = key[1]; continue; }
    const uid = /^ {4}cloud_uid:\s*["']?([A-Za-z0-9_-]+)["']?\s*$/.exec(line);
    if (uid && slug) out[slug] = uid[1];
  }
  return out;
}

// The scope object the scripts share.
export function makeScope(root, slugs) {
  const uids = manifestUids(root);
  return {
    slugs: new Set(slugs),
    uids: new Set(slugs.map((s) => uids[s]).filter(Boolean)),
    unmapped: slugs.filter((s) => s !== 'personal' && !uids[s]),
  };
}

// Is this channel directory row inside the locked set?
export function rowInScope(row, scope) {
  if (!row || typeof row !== 'object') return false;
  if (row.companyUid) return scope.uids.has(row.companyUid);
  return PERSON_SCOPES.has(row.scope || row.type);
}

// The company set a desktop session was locked to, from its meta.yaml, or null
// when there is no readable meta. An unbound session is `personal`.
export function sessionCompanies(root, sid) {
  if (!/^[A-Za-z0-9_-]+$/.test(sid)) return null;
  let text;
  try { text = fs.readFileSync(path.join(root, 'workspace', 'sessions', sid, 'meta.yaml'), 'utf8'); } catch { return null; }
  const read = (key) => {
    const m = new RegExp(`^${key}:[ \\t]*"?([^"\\n]*)"?[ \\t]*$`, 'm').exec(text);
    return m ? m[1].split(',').map((s) => s.trim()).filter(Boolean) : [];
  };
  const set = read('company_slugs');
  if (set.length) return set;
  const one = read('company_slug');
  return one.length ? one : ['personal'];
}

export function sessionInScope(root, sid, scope) {
  const cos = sessionCompanies(root, sid);
  return !!cos && cos.every((c) => scope.slugs.has(c));
}

// Is this channel row on the exclude list (slugs, names or ids, lowercased)?
export function rowExcluded(row, exclude) {
  if (!exclude || !exclude.length || !row || typeof row !== 'object') return false;
  const keys = new Set([row.channelId, row.slug, row.name].filter(Boolean).map((k) => String(k).toLowerCase()));
  return exclude.some((c) => keys.has(String(c).toLowerCase()));
}

// `hq_channels_exclude` from the owner settings (prefs.mjs exclude), or [].
export function prefsExclude(root) {
  try {
    const prefs = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'super-conductor-prefs.mjs');
    const out = execFileSync(process.execPath, [prefs, 'exclude'], { cwd: root, encoding: 'utf8', timeout: 10000, stdio: ['ignore', 'pipe', 'ignore'] });
    return out.split(',').map((s) => s.trim().toLowerCase()).filter(Boolean);
  } catch { return []; }
}

// Filter a `channels list` array or a `channels changes` object.
export function filterChannels(data, scope, exclude = []) {
  const keep = (r) => rowInScope(r, scope) && !rowExcluded(r, exclude);
  if (Array.isArray(data)) return data.filter(keep);
  if (data && typeof data === 'object') {
    const out = { ...data };
    for (const k of ['rows', 'changed', 'channels']) if (Array.isArray(out[k])) out[k] = out[k].filter(keep);
    return out;
  }
  throw new Error('expected a channel list or a channel changes object');
}

// True when this module file is the script node was started with. Compares
// real paths, so a symlinked HQ root still runs main().
export function isMain(metaUrl, argv1 = process.argv[1]) {
  if (!argv1) return false;
  try { return fs.realpathSync(argv1) === fs.realpathSync(fileURLToPath(metaUrl)); } catch { return false; }
}

function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  const fail = (msg) => { process.stderr.write(`super-conductor-scope: ${msg}\n`); process.exit(2); };
  if (cmd !== 'filter-channels') fail('usage: filter-channels --company <csv>|--session-companies [--exclude <csv>]');
  const companies = [];
  const exclude = [];
  let fromSession = false;
  for (let i = 0; i < rest.length; i++) {
    if (rest[i] === '--company' && rest[i + 1] !== undefined) companies.push(rest[++i]);
    else if (rest[i] === '--session-companies') fromSession = true;
    else if (rest[i] === '--exclude' && rest[i + 1] !== undefined) exclude.push(...rest[++i].split(',').map((s) => s.trim().toLowerCase()).filter(Boolean));
    else fail(`unexpected argument ${rest[i]}`);
  }
  let scope;
  try {
    const root = process.env.HQ_ROOT || path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
    if (fromSession) companies.push(...sessionCompanySlugs(root));
    scope = makeScope(root, parseCompanies(companies));
    exclude.push(...prefsExclude(root));
  } catch (e) { fail(e.message); }
  let data;
  try { data = JSON.parse(fs.readFileSync(0, 'utf8')); } catch (e) { fail(`stdin is not JSON: ${e.message}`); }
  try { process.stdout.write(`${JSON.stringify(filterChannels(data, scope, exclude), null, 2)}\n`); } catch (e) { fail(e.message); }
}

if (isMain(import.meta.url)) main();
