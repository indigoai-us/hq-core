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
import { Refusal, apiClient, runuserPath, validateConfig } from './company-jobs.mjs';
import { writeSigninPhase } from './company-service-restart.mjs';

export const AUTH_USER = 'hq-claude-auth';
export const AUTH_HOME = '/var/lib/hq-claude-auth';
export const SAFE_PATH = '/usr/local/bin:/usr/bin:/bin';
export const TOKEN_ENV = 'CLAUDE_CODE_OAUTH_TOKEN';
export const credentialFile = (home = AUTH_HOME) => path.join(home, '.claude', '.credentials.json');
// Margin so a token does not expire between admission and the first model call.
export const TOKEN_MARGIN_MS = 5 * 60 * 1000;
const LOGIN_CODE = /^[A-Za-z0-9][A-Za-z0-9#_.~-]{7,511}$/;
// eslint-disable-next-line no-control-regex
const LOGIN_URL = /https:\/\/(?:[a-z0-9-]+\.)*(?:claude\.ai|claude\.com|anthropic\.com)\/[^\s"'<>\u0000-\u001f\u007f]+/g;
const LOGIN_URL_HOSTS = ['claude.ai', 'claude.com', 'anthropic.com'];

/** Signed-in mode: no broker provider secret and the Claude provider. */
export function usesBoxSignIn(c) {
  return c.providerSecret === undefined && c.provider === 'claude';
}

/**
 * Classify the credential file without throwing. status is one of: ok,
 * missing, not_regular_file (symlink or other type), bad_owner, bad_mode,
 * unreadable, parse_error, invalid_shape. Only the class is returned, never
 * file contents.
 */
export function inspectClaudeCredential(file, {uid} = {}) {
  let fd;
  try { fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW); }
  catch (error) {
    if (error.code === 'ENOENT') return {status: 'missing'};
    if (error.code === 'ELOOP') return {status: 'not_regular_file'};
    return {status: 'unreadable', error};
  }
  let raw;
  try {
    const stat = fs.fstatSync(fd);
    if (!stat.isFile()) return {status: 'not_regular_file'};
    if (Number.isInteger(uid) && stat.uid !== uid) return {status: 'bad_owner'};
    if ((stat.mode & 0o077) !== 0) return {status: 'bad_mode'};
    raw = fs.readFileSync(fd, 'utf8');
  } catch (error) { return {status: 'unreadable', error}; }
  finally { try { fs.closeSync(fd); } catch { /* a failed close does not change the classification */ } }
  let parsed;
  try { parsed = JSON.parse(raw); }
  catch { return {status: 'parse_error'}; }
  const oauth = parsed?.claudeAiOauth;
  if (!oauth || typeof oauth.accessToken !== 'string' || !/^[A-Za-z0-9_.~+/=-]{20,4096}$/.test(oauth.accessToken)) return {status: 'invalid_shape'};
  const expiresAt = Number(oauth.expiresAt);
  return {status: 'ok', access: {accessToken: oauth.accessToken, expiresAt: Number.isFinite(expiresAt) ? expiresAt : 0}};
}

/**
 * Read only the access token and its expiry. The file must be a regular file,
 * not a symlink, owned by the auth account and private to it.
 */
export function readClaudeAccess(file, {uid} = {}) {
  const result = inspectClaudeCredential(file, {uid});
  if (result.status === 'ok') return result.access;
  if (result.status === 'unreadable') throw result.error;
  if (['not_regular_file', 'bad_owner', 'bad_mode'].includes(result.status)) throw new Refusal('provider_credential_unsafe');
  return null;
}

/**
 * Why the box is or is not signed in: ok, expired (token past its expiry and
 * the CLI refresh did not produce a valid one), or one of the
 * inspectClaudeCredential classes.
 */
export function credentialStatus(file, opts = {}) {
  return credentialDetail(file, opts).status;
}

/** Like credentialStatus; for `unreadable` also returns the errno code (never the message or path). */
export function credentialDetail(file, {uid, now = Date.now, refresh = refreshViaCli} = {}) {
  const brief = r => (r.status === 'unreadable' ? {status: r.status, ...(typeof r.error?.code === 'string' ? {errno: r.error.code} : {})} : {status: r.status});
  let result = inspectClaudeCredential(file, {uid});
  if (result.status !== 'ok') return brief(result);
  if (result.access.expiresAt > now()) return {status: 'ok'};
  try { refresh(); } catch { /* the re-read decides */ }
  result = inspectClaudeCredential(file, {uid});
  if (result.status !== 'ok') return brief(result);
  return {status: result.access.expiresAt > now() ? 'ok' : 'expired'};
}

/**
 * Signed-in check for the watcher. Logs credential_not_usable once each time
 * the class changes (and never for ok), so a parked box leaves a trace
 * without a line per tick. The errno code is included for unreadable only.
 */
export function checkSignedIn(state, detail) {
  const {status, errno} = detail();
  const key = errno ? `${status}:${errno}` : status;
  if (key !== state.credentialKey) {
    const previous = state.credentialStatus;
    const before = state.credentialReport;
    state.credentialKey = key;
    state.credentialStatus = status;
    if (status !== 'ok') console.error(JSON.stringify({service: 'company-signin', code: 'credential_not_usable', reason: status, ...(errno ? {errno} : {})}));
    // Queue one report to the cloud on a class change to a non-ok class, and one on
    // recovery. An errno-only change inside the same class is not a new class.
    // A box that starts out signed in has nothing to recover from and reports nothing.
    if (status !== 'ok' && status !== previous) state.credentialReport = {action: 'credential-lost', credentialClass: status};
    else if (status === 'ok' && previous && previous !== 'ok') state.credentialReport = {action: 'credential-ok'};
    // A newer report replaces the queued one, so it must not wait on the older report's backoff.
    if (state.credentialReport && state.credentialReport !== before) state.credentialReportRetryAt = 0;
  }
  return status === 'ok';
}

// Wait before resending a credential report the cloud did not take (network or 5xx).
export const CREDENTIAL_REPORT_RETRY_MS = 60 * 1000;

/**
 * Send the report checkSignedIn queued. Never throws: the cloud alert is
 * additional to the sign-in flow, so a failure cannot stop the watcher. A
 * refusal that retrying cannot fix (4xx other than 401, 403, 408 and 429, such as a
 * server that does not know the action yet) is logged once and dropped. 401 and 403 can
 * be a transient machine-token failure, so they retry like 5xx. A retry
 * happens after CREDENTIAL_REPORT_RETRY_MS. Only the action and the HTTP
 * status are logged.
 */
export async function flushCredentialReport(state, api, {now = Date.now} = {}) {
  const report = state.credentialReport;
  if (!report) return;
  if (state.credentialReportRetryAt && now() < state.credentialReportRetryAt) return;
  try {
    await api('signin', report);
    state.credentialReport = null;
    state.credentialReportRetryAt = 0;
  } catch (error) {
    const status = typeof error?.status === 'number' ? error.status : null;
    const final = status !== null && status >= 400 && status < 500 && ![401, 403, 408, 429].includes(status);
    if (final) { state.credentialReport = null; state.credentialReportRetryAt = 0; }
    else state.credentialReportRetryAt = now() + CREDENTIAL_REPORT_RETRY_MS;
    console.error(JSON.stringify({service: 'company-signin', code: final ? 'credential_report_refused' : 'credential_report_failed', action: report.action, status}));
  }
}

/** Signed in means a token that is still valid, or one the CLI can refresh. */
export function signedIn(file, opts = {}) {
  return credentialStatus(file, opts) === 'ok';
}

/** One minimal CLI call as the auth account; the CLI refreshes and rewrites its own file. */
export function refreshViaCli({user = AUTH_USER, home = AUTH_HOME, run = spawnSync, runuser = runuserPath()} = {}) {
  const result = run(runuser, ['-u', user, '--', 'env', '-i', `HOME=${home}`, `PATH=${SAFE_PATH}`, 'LANG=C.UTF-8',
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

/**
 * Mirrors the server check (hq-pro-agents validLoginUrl): https, an allowed
 * host, no userinfo or port, path ending /oauth/authorize, no controls.
 */
export function validLoginUrl(value) {
  // eslint-disable-next-line no-control-regex
  if (typeof value !== 'string' || value.length > 4096 || /[\u0000-\u0020\u007f]/.test(value)) return false;
  let url;
  try { url = new URL(value); } catch { return false; }
  if (url.protocol !== 'https:' || url.username || url.password || url.port) return false;
  const host = url.hostname.toLowerCase();
  return LOGIN_URL_HOSTS.some(allowed => host === allowed || host.endsWith(`.${allowed}`)) && url.pathname.endsWith('/oauth/authorize');
}

/**
 * Terminal output to plain text. OSC sequences (OSC 8 hyperlinks, titles) end
 * in BEL or ST (ESC \\) and become a space so the hyperlink target and its
 * visible text stay separate. An unterminated OSC at the end of the buffer is
 * an incomplete chunk and is dropped. CSI and other escapes are removed, and
 * any remaining C0/DEL control becomes a space.
 */
export function stripTerminal(text) {
  /* eslint-disable no-control-regex */
  return String(text)
    .replace(/\u001b\][^\u0007\u001b]*(?:\u0007|\u001b\\)/g, ' ')
    .replace(/\u001b\][^\u0007]*$/, ' ')
    .replace(/\u001b\[[0-?]*[ -/]*[@-~]/g, '')
    .replace(/\u001b[ -/]*[0-~]?/g, '')
    .replace(/[\u0000-\u001f\u007f]/g, ' ');
  /* eslint-enable no-control-regex */
}

/**
 * The last complete sign-in URL in the output. An OSC 8 hyperlink target is
 * preferred: it is whole even when the visible text wraps. Otherwise a plain
 * URL is used, but one that runs to the end of the buffer may be cut mid-chunk
 * and is not returned until more output ends it.
 */
export function extractLoginUrl(text) {
  const raw = String(text);
  let found = null;
  // eslint-disable-next-line no-control-regex
  for (const match of raw.matchAll(/\u001b\]8;[^;\u0007\u001b]*;([^\u0007\u001b]*)(?:\u0007|\u001b\\)/g)) {
    if (validLoginUrl(match[1])) found = match[1];
  }
  if (found) return found;
  const clean = stripTerminal(raw);
  for (const match of clean.matchAll(LOGIN_URL)) {
    if (match.index + match[0].length >= clean.length) continue;
    if (validLoginUrl(match[0])) found = match[0];
  }
  return found;
}

export function validLoginCode(code) {
  return typeof code === 'string' && LOGIN_CODE.test(code);
}

/** Login process as the auth account. Output stays in memory; nothing is logged. */
export function startLogin({user = AUTH_USER, home = AUTH_HOME, spawnImpl = spawn, runuser = runuserPath()} = {}) {
  const child = spawnImpl(runuser, ['-u', user, '--', 'env', '-i', `HOME=${home}`, `PATH=${SAFE_PATH}`, 'LANG=C.UTF-8', 'TERM=dumb',
    'script', '-qfec', 'stty cols 1000 rows 50; exec claude auth login --claudeai', '/dev/null'], {cwd: home, stdio: ['pipe', 'pipe', 'pipe']});
  let output = '';
  const collect = chunk => { output = (output + chunk.toString('utf8')).slice(-65536); };
  child.stdout?.on('data', collect);
  child.stderr?.on('data', collect);
  let alive = true;
  let exit = null;
  child.on('exit', (status, signal) => { alive = false; exit ??= {status, signal}; });
  child.on('error', error => { alive = false; exit ??= {status: null, signal: null, error: error?.code ?? 'spawn_error'}; });
  return {
    alive: () => alive,
    exitInfo: () => exit,
    output: () => output,
    sendCode: code => { if (!validLoginCode(code)) throw new Refusal('invalid_login_code'); child.stdin.write(`${code}\r`); },
    stop: () => { if (alive) child.kill('SIGTERM'); alive = false; },
  };
}

function rememberPhase(state, recordPhase, status) {
  recordPhase(status);
  state.phase = status?.phase ?? null;
}

// Poll pacing. While someone is on the sign-in card (the server's `hot` hint),
// a code was just typed, or the login is starting, the watcher polls every
// 5 s. After IDLE_AFTER_MS with no such activity it polls every IDLE_POLL_MS.
export const ACTIVE_POLL_MS = 5000;
export const IDLE_POLL_MS = 30000;
export const IDLE_AFTER_MS = 5 * 60 * 1000;
// A Claude sign-in link stops working about 10 minutes after the CLI prints
// it (same window the server reports as loginUrlExpiresAt).
export const LOGIN_URL_TTL_MS = 10 * 60 * 1000;
// A typed code that neither signs in nor makes the CLI print a new link
// within this window counts as not accepted; the login restarts.
export const CODE_RESULT_TIMEOUT_MS = 2 * 60 * 1000;

/** Stop the login process; the next tick starts a new one, which posts a new link. */
function restartLogin(state, recordPhase) {
  state.login?.stop();
  state.login = null;
  state.posted = null;
  state.sentCode = null;
  rememberPhase(state, recordPhase, null);
}

/** Delay before the next tick. */
export function pollDelayMs(state, now = Date.now(), {activeMs = ACTIVE_POLL_MS, idleMs = IDLE_POLL_MS} = {}) {
  if (!state.posted || state.sentCode) return activeMs;
  const since = Math.max(state.activeAt ?? 0, state.urlSince ?? 0);
  return now - since >= IDLE_AFTER_MS ? Math.max(idleMs, activeMs) : activeMs;
}

/** One watcher step. All side effects are injected for tests. */
export async function signinTick(state, {api, isSignedIn, start, recordPhase = () => {}, now = Date.now}) {
  const signedInNow = isSignedIn();
  await flushCredentialReport(state, api, {now});
  if (signedInNow) {
    state.login?.stop(); state.login = null; state.posted = null; state.lastExit = null;
    if (!state.reported) {
      rememberPhase(state, recordPhase, null);
      state.sentCode = null;
      await api('signin', {action: 'login-complete'});
      state.reported = true;
    }
    return 'signed_in';
  }
  state.reported = false;
  if (state.login && !state.login.alive()) {
    // Once per distinct failure; exit code and signal only, never output.
    const exit = state.login.exitInfo?.() ?? null;
    const key = JSON.stringify(exit);
    if (exit && key !== state.lastExit) {
      console.error(JSON.stringify({service: 'company-signin', code: 'login_exited', status: exit.status, signal: exit.signal, ...(exit.error ? {error: exit.error} : {})}));
    }
    state.lastExit = key;
  } else if (state.login) state.lastExit = null;
  // A new login drops the previous phase. The replacement process posts a new link.
  if (!state.login || !state.login.alive()) {
    rememberPhase(state, recordPhase, null);
    state.sentCode = null;
    state.login = start();
    state.posted = null;
  }
  const url = extractLoginUrl(state.login.output());
  if (url && url !== state.posted) {
    try { await api('signin', {action: 'login-url', url}); }
    catch (error) {
      // No URL or body in the log: only the refusal and the HTTP status.
      console.error(JSON.stringify({service: 'company-signin', code: 'login_url_refused', status: error?.status ?? null}));
      throw error;
    }
    state.posted = url;
    state.urlSince = now();
    state.activeAt = state.urlSince;
  }
  // No code yet: this is idle waiting, not code entry. The phase file stores neither the URL nor a code.
  if (state.posted && !state.sentCode && state.phase !== 'awaiting_person') {
    rememberPhase(state, recordPhase, {phase: 'awaiting_person', since: state.urlSince ?? now()});
  }
  // `hot` (newer servers) says someone is on the sign-in card or a code or
  // regenerate is waiting. Absent means unknown: no auto-restart.
  let hot = false;
  if (state.posted) {
    const reply = await api('signin', {action: 'login-code'});
    const code = reply?.code;
    hot = reply?.hot === true;
    if (hot) state.activeAt = now();
    // A one-time code is typed once; a repeated poll result is ignored.
    if (validLoginCode(code) && code !== state.sentCode) {
      state.login.sendCode(code);
      state.sentCode = code;
      state.codeSince = now();
      state.activeAt = state.codeSince;
    }
  }
  if (state.sentCode && state.phase !== 'code_entry') {
    rememberPhase(state, recordPhase, {phase: 'code_entry', since: state.codeSince ?? now()});
  }
  const {pending} = await api('signin', {action: 'regenerate-pending'});
  if (pending === true) {
    state.activeAt = now();
    restartLogin(state, recordPhase);
    return 'awaiting_sign_in';
  }
  if (state.sentCode && now() - (state.codeSince ?? now()) >= CODE_RESULT_TIMEOUT_MS) {
    // The typed code neither signed in nor made the CLI print a new link. A
    // new login posts a new link, which the server records as a rejected code.
    console.error(JSON.stringify({service: 'company-signin', code: 'login_code_timeout', ...(state.credentialStatus ? {credential: state.credentialStatus} : {})}));
    restartLogin(state, recordPhase);
  } else if (state.posted && !state.sentCode && hot && now() - (state.urlSince ?? now()) >= LOGIN_URL_TTL_MS) {
    // Someone is looking at a link that no longer works: replace it. With no
    // one on the card the old link stays, so an idle box does not churn.
    console.error(JSON.stringify({service: 'company-signin', code: 'login_url_expired_restart'}));
    restartLogin(state, recordPhase);
  }
  return 'awaiting_sign_in';
}

export async function watch(configPath, {intervalMs = ACTIVE_POLL_MS, idleIntervalMs = IDLE_POLL_MS} = {}) {
  const stat = fs.statSync(configPath);
  if (stat.uid !== 0 || (stat.mode & 0o022) !== 0) throw new Refusal('config_must_be_root_owned');
  if (process.getuid() !== 0) throw new Refusal('runner_must_be_root');
  const c = validateConfig({...JSON.parse(fs.readFileSync(configPath, 'utf8')), configPath});
  if (!usesBoxSignIn(c)) return;
  const authUid = Number(spawnSync('/usr/bin/id', ['-u', AUTH_USER], {encoding: 'utf8'}).stdout.trim());
  if (!Number.isInteger(authUid) || authUid <= 0) throw new Refusal('auth_account_required');
  // Refuse at startup, not every tick, when no runuser exists.
  const runuser = runuserPath();
  const api = await apiClient(c);
  const state = {};
  // At most one refresh attempt every 10 minutes when the stored token has expired.
  let lastRefresh = 0;
  const refresh = () => { if (Date.now() - lastRefresh < 600000) return false; lastRefresh = Date.now(); return refreshViaCli({runuser}); };
  // Log the credential class when it changes; the tick also carries it on the code-timeout line.
  const isSignedIn = () => checkSignedIn(state, () => credentialDetail(credentialFile(), {uid: authUid, refresh}));
  const deps = {
    api, isSignedIn, start: () => startLogin({runuser}),
    recordPhase: status => writeSigninPhase(status), now: () => Date.now(),
  };
  for (;;) {
    try { await signinTick(state, deps); }
    catch (error) { console.error(JSON.stringify({service: 'company-signin', code: error instanceof Refusal ? error.code : 'signin_error', status: error?.status ?? null})); }
    await new Promise(resolve => setTimeout(resolve, pollDelayMs(state, Date.now(), {activeMs: intervalMs, idleMs: idleIntervalMs})));
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [action, configPath] = process.argv.slice(2);
  if (action !== 'watch') { console.error('usage: company-signin.mjs watch <config>'); process.exitCode = 2; }
  else watch(configPath).catch(error => { console.error(JSON.stringify({service: 'company-signin', code: error instanceof Refusal ? error.code : 'signin_error'})); process.exitCode = 1; });
}
