// hq-core: public
// Company Outpost Claude sign-in (design: option B, privileged runner).
//
// The sign-in belongs to a dedicated account (hq-claude-auth) whose credential
// file is mode 600 and never readable by hq-jobs. A company owner or admin
// completes the sign-in once through HQ (console or `hq outposts login-code
// --company`). For each run the root runner reads only the short-lived access
// token and hands it to the claude session as CLAUDE_CODE_OAUTH_TOKEN through
// the existing LoadCredential path. Job code never sees the refresh token, and
// precondition scripts get no provider credential at all.
import fs from 'node:fs';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { Refusal, apiClient, validateConfig } from './company-jobs.mjs';

export const AUTH_USER = 'hq-claude-auth';
export const AUTH_HOME = '/var/lib/hq-claude-auth';
export const SAFE_PATH = '/usr/local/bin:/usr/bin:/bin';
export const TOKEN_ENV = 'CLAUDE_CODE_OAUTH_TOKEN';
export const credentialFile = (home = AUTH_HOME) => path.join(home, '.claude', '.credentials.json');
// Margin so a token does not expire between admission and the first model call.
export const TOKEN_MARGIN_MS = 5 * 60 * 1000;
const LOGIN_CODE = /^[A-Za-z0-9][A-Za-z0-9#_.~-]{7,511}$/;
const LOGIN_URL = /https:\/\/(?:[a-z0-9-]+\.)*(?:claude\.ai|claude\.com|anthropic\.com)\/[^\s"'<>\u001b]+/;

/** Signed-in mode: no broker provider secret and the Claude provider. */
export function usesBoxSignIn(c) {
  return c.providerSecret === undefined && c.provider === 'claude';
}

/**
 * Read only the access token and its expiry. The file must be a regular file,
 * not a symlink, owned by the auth account and private to it.
 */
export function readClaudeAccess(file, {uid} = {}) {
  let fd;
  try { fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW); }
  catch (error) { if (error.code === 'ENOENT') return null; if (error.code === 'ELOOP') throw new Refusal('provider_credential_unsafe'); throw error; }
  let raw;
  try {
    const stat = fs.fstatSync(fd);
    if (!stat.isFile()) throw new Refusal('provider_credential_unsafe');
    if (Number.isInteger(uid) && stat.uid !== uid) throw new Refusal('provider_credential_unsafe');
    if ((stat.mode & 0o077) !== 0) throw new Refusal('provider_credential_unsafe');
    raw = fs.readFileSync(fd, 'utf8');
  } finally { fs.closeSync(fd); }
  let parsed;
  try { parsed = JSON.parse(raw); }
  catch { return null; }
  const oauth = parsed?.claudeAiOauth;
  if (!oauth || typeof oauth.accessToken !== 'string' || !/^[A-Za-z0-9_.~+/=-]{20,4096}$/.test(oauth.accessToken)) return null;
  const expiresAt = Number(oauth.expiresAt);
  return {accessToken: oauth.accessToken, expiresAt: Number.isFinite(expiresAt) ? expiresAt : 0};
}

/** Signed in means a token that is still valid, or one the CLI can refresh. */
export function signedIn(file, {uid, now = Date.now, refresh = refreshViaCli} = {}) {
  try {
    let access = readClaudeAccess(file, {uid});
    if (!access) return false;
    if (access.expiresAt > now()) return true;
    refresh();
    access = readClaudeAccess(file, {uid});
    return access !== null && access.expiresAt > now();
  } catch { return false; }
}

/** One minimal CLI call as the auth account; the CLI refreshes and rewrites its own file. */
export function refreshViaCli({user = AUTH_USER, home = AUTH_HOME, run = spawnSync} = {}) {
  const result = run('runuser', ['-u', user, '--', 'env', '-i', `HOME=${home}`, `PATH=${SAFE_PATH}`, 'LANG=C.UTF-8',
    'claude', '-p', 'Reply with OK.', '--max-turns', '1'], {cwd: home, timeout: 60000, stdio: 'ignore'});
  return result.status === 0;
}

/**
 * Access token valid until `needUntil`. Refresh once through the CLI when it is
 * short. A missing or still-short token blocks the run.
 */
export function claudeAccessToken({file = credentialFile(), uid, needUntil, now = Date.now, refresh = refreshViaCli} = {}) {
  let access = readClaudeAccess(file, {uid});
  if (!access) throw new Refusal('provider_not_signed_in');
  const need = Math.max(needUntil ?? 0, now() + TOKEN_MARGIN_MS);
  if (access.expiresAt < need) {
    refresh();
    access = readClaudeAccess(file, {uid});
    if (!access) throw new Refusal('provider_not_signed_in');
    if (access.expiresAt < need) throw new Refusal('provider_token_expiring');
  }
  return access.accessToken;
}

// ---------------------------------------------------------------------------
// Sign-in watcher (root). Runs `claude auth login --claudeai` as the auth
// account under a pty, reports the URL, types the code an owner or admin
// submits, and reports completion. Same protocol as the personal Outpost
// runner, authenticated by the company machine principal.
// ---------------------------------------------------------------------------

export function extractLoginUrl(text) {
  // eslint-disable-next-line no-control-regex
  const clean = String(text).replace(/\u001b\[[0-9;?]*[ -/]*[@-~]/g, '').replace(/\u001b\][^\u0007]*\u0007/g, '');
  const match = LOGIN_URL.exec(clean);
  return match ? match[0] : null;
}

export function validLoginCode(code) {
  return typeof code === 'string' && LOGIN_CODE.test(code);
}

/** Login process as the auth account. Output stays in memory; nothing is logged. */
export function startLogin({user = AUTH_USER, home = AUTH_HOME, spawnImpl = spawn} = {}) {
  const child = spawnImpl('runuser', ['-u', user, '--', 'env', '-i', `HOME=${home}`, `PATH=${SAFE_PATH}`, 'LANG=C.UTF-8', 'TERM=dumb',
    'script', '-qfec', 'stty cols 1000 rows 50; exec claude auth login --claudeai', '/dev/null'], {cwd: home, stdio: ['pipe', 'pipe', 'pipe']});
  let output = '';
  const collect = chunk => { output = (output + chunk.toString('utf8')).slice(-65536); };
  child.stdout?.on('data', collect);
  child.stderr?.on('data', collect);
  let alive = true;
  child.on('exit', () => { alive = false; });
  child.on('error', () => { alive = false; });
  return {
    alive: () => alive,
    output: () => output,
    sendCode: code => { if (!validLoginCode(code)) throw new Refusal('invalid_login_code'); child.stdin.write(`${code}\r`); },
    stop: () => { if (alive) child.kill('SIGTERM'); alive = false; },
  };
}

/** One watcher step. All side effects are injected for tests. */
export async function signinTick(state, {api, isSignedIn, start}) {
  if (isSignedIn()) {
    state.login?.stop(); state.login = null; state.posted = null;
    if (!state.reported) { await api('signin', {action: 'login-complete'}); state.reported = true; }
    return 'signed_in';
  }
  state.reported = false;
  if (!state.login || !state.login.alive()) { state.login = start(); state.posted = null; }
  const url = extractLoginUrl(state.login.output());
  if (url && url !== state.posted) { await api('signin', {action: 'login-url', url}); state.posted = url; }
  if (state.posted) {
    const {code} = await api('signin', {action: 'login-code'});
    // A one-time code is typed once; a repeated poll result is ignored.
    if (validLoginCode(code) && code !== state.sentCode) { state.login.sendCode(code); state.sentCode = code; }
  }
  const {pending} = await api('signin', {action: 'regenerate-pending'});
  if (pending === true) { state.login.stop(); state.login = null; state.posted = null; }
  return 'awaiting_sign_in';
}

export async function watch(configPath, {intervalMs = 5000} = {}) {
  const stat = fs.statSync(configPath);
  if (stat.uid !== 0 || (stat.mode & 0o022) !== 0) throw new Refusal('config_must_be_root_owned');
  if (process.getuid() !== 0) throw new Refusal('runner_must_be_root');
  const c = validateConfig({...JSON.parse(fs.readFileSync(configPath, 'utf8')), configPath});
  if (!usesBoxSignIn(c)) return;
  const authUid = Number(spawnSync('id', ['-u', AUTH_USER], {encoding: 'utf8'}).stdout.trim());
  if (!Number.isInteger(authUid) || authUid <= 0) throw new Refusal('auth_account_required');
  const api = await apiClient(c);
  const state = {};
  // At most one refresh attempt every 10 minutes when the stored token has expired.
  let lastRefresh = 0;
  const refresh = () => { if (Date.now() - lastRefresh < 600000) return false; lastRefresh = Date.now(); return refreshViaCli(); };
  const deps = {api, isSignedIn: () => signedIn(credentialFile(), {uid: authUid, refresh}), start: () => startLogin()};
  for (;;) {
    try { await signinTick(state, deps); }
    catch (error) { console.error(JSON.stringify({service: 'company-signin', code: error instanceof Refusal ? error.code : 'signin_error'})); }
    await new Promise(resolve => setTimeout(resolve, intervalMs));
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [action, configPath] = process.argv.slice(2);
  if (action !== 'watch') { console.error('usage: company-signin.mjs watch <config>'); process.exitCode = 2; }
  else watch(configPath).catch(error => { console.error(JSON.stringify({service: 'company-signin', code: error instanceof Refusal ? error.code : 'signin_error'})); process.exitCode = 1; });
}
