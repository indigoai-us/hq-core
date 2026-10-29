// hq-core: public
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { CompanyRunner, contentDigest } from '../lib/company-jobs.mjs';
import * as signin from '../lib/company-signin.mjs';

const FAKE_ACCESS = 'fake-access-token-for-tests-a';
const FAKE_REFRESH = 'fake-refresh-token-for-tests-b';

function credDir(t) {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'company-signin-')));
  t.after(() => fs.rmSync(dir, {recursive: true, force: true}));
  const file = path.join(dir, '.credentials.json');
  const write = (expiresAt, mode = 0o600) => {
    fs.writeFileSync(file, JSON.stringify({claudeAiOauth: {accessToken: FAKE_ACCESS, refreshToken: FAKE_REFRESH, expiresAt}}), {mode});
    fs.chmodSync(file, mode);
  };
  return {dir, file, write};
}

test('reads only the access token and expiry from a private regular file', t => {
  const c = credDir(t);
  assert.equal(signin.readClaudeAccess(c.file), null);
  c.write(Date.now() + 3600000);
  const access = signin.readClaudeAccess(c.file, {uid: process.getuid()});
  assert.deepEqual(Object.keys(access).sort(), ['accessToken', 'expiresAt']);
  assert.equal(access.accessToken, FAKE_ACCESS);
  assert.throws(() => signin.readClaudeAccess(c.file, {uid: process.getuid() + 1}), {code: 'provider_credential_unsafe'});
  c.write(Date.now() + 3600000, 0o644);
  assert.throws(() => signin.readClaudeAccess(c.file), {code: 'provider_credential_unsafe'});
  const link = path.join(c.dir, 'link.json');
  fs.symlinkSync(c.file, link);
  assert.throws(() => signin.readClaudeAccess(link), {code: 'provider_credential_unsafe'});
});

test('a short token is refreshed once through the CLI; still short or missing blocks', t => {
  const c = credDir(t);
  const now = () => 1_000_000;
  assert.throws(() => signin.claudeAccessToken({file: c.file, now, needUntil: 2_000_000, refresh: () => true}), {code: 'provider_not_signed_in'});
  c.write(1_500_000);
  let refreshed = 0;
  const token = signin.claudeAccessToken({file: c.file, now, needUntil: 2_000_000, refresh: () => { refreshed++; c.write(99_000_000); return true; }});
  assert.equal(token, FAKE_ACCESS);
  assert.equal(refreshed, 1);
  c.write(1_500_000);
  assert.throws(() => signin.claudeAccessToken({file: c.file, now, needUntil: 2_000_000, refresh: () => true}), {code: 'provider_token_expiring'});
  // The margin applies even for very short jobs.
  c.write(now() + 60_000);
  assert.throws(() => signin.claudeAccessToken({file: c.file, now, needUntil: now() + 1000, refresh: () => true}), {code: 'provider_token_expiring'});
});

test('the CLI refresh runs as the auth account with a clean environment', () => {
  let seen;
  signin.refreshViaCli({runuser: '/usr/sbin/runuser', run: (cmd, args, opts) => { seen = {cmd, args, opts}; return {status: 0}; }});
  assert.equal(seen.cmd, '/usr/sbin/runuser');
  assert.deepEqual(seen.args.slice(0, 5), ['-u', 'hq-claude-auth', '--', 'env', '-i']);
  assert(seen.args.includes('HOME=/var/lib/hq-claude-auth'));
  assert(!seen.args.some(a => /TOKEN|KEY/.test(a)));
});

function runnerFixture(t, {provider = 'claude', providerSecret} = {}) {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'company-signin-run-')));
  t.after(() => fs.rmSync(dir, {recursive: true, force: true}));
  const cred = path.join(dir, 'auth.json');
  const c = {companyUid: 'cmp_test', companySlug: 'test', machineUid: 'out_test', outpostId: 'outpost_cmp_test', instanceId: 'i-test', attemptId: 'attempt1', hqRoot: dir, stateDir: path.join(dir, 'state'), unitDir: path.join(dir, 'units'), configPath: path.join(dir, 'config.json'), machineCredsFile: '/not-read', provider, providerAuthFile: cred, ...(providerSecret ? {providerSecret} : {})};
  const j = {ownerKind: 'company-outpost', companyUid: c.companyUid, agentUid: c.outpostId, jobId: 'job_abc', acceptedRevision: 'revision1', status: 'active', prompt: 'do work', script: 'echo pre', target: {machineUid: c.machineUid, outpostId: c.outpostId, instanceId: c.instanceId, attemptId: c.attemptId}, acceptedAt: '2026-01-01T00:00:00Z', schedule: {kind: 'recurring', cron: 'cron(0 9,17 * * ? *)', timezone: 'America/Los_Angeles'}};
  j.contentDigest = contentDigest(j);
  const delivery = (runId = 'run1') => ({companyUid: c.companyUid, agentUid: c.machineUid, jobId: j.jobId, acceptedRevision: j.acceptedRevision, contentDigest: j.contentDigest, prompt: j.prompt, context: j.context, script: j.script, target: j.target, runId, firedAt: '2026-01-02T01:00:00Z'});
  const calls = [];
  const api = async (op, body) => { calls.push({op, ...body}); if (op === 'secret') return {value: 'SENTINEL_SECRET'}; return delivery(); };
  const launches = [];
  const r = new CompanyRunner(c, api, {systemctl: () => {}, execute: async (_cmd, args, o) => { launches.push({args, o}); return {code: 0, text: args[0] === '-c' ? 'pre output' : '{"disposition":"reply","outcome":"complete"}'}; }});
  r.signin = {...signin, claudeAccessToken: opts => signin.claudeAccessToken({...opts, refresh: () => false})};
  t.after(() => r.close());
  const writeCred = expiresAt => fs.writeFileSync(cred, JSON.stringify({claudeAiOauth: {accessToken: FAKE_ACCESS, refreshToken: FAKE_REFRESH, expiresAt}}), {mode: 0o600});
  return {c, j, r, delivery, calls, launches, writeCred};
}

test('signed-in box: only the claude session unit gets the access token; the precondition script gets none', async t => {
  const f = runnerFixture(t);
  f.writeCred(Date.now() + 8 * 3600000);
  const receipt = await f.r.runDelivery(f.j, f.delivery());
  assert.equal(receipt.outcome, 'succeeded');
  assert.equal(f.calls.filter(c => c.op === 'secret').length, 0);
  const [pre, session] = f.launches;
  assert.equal(pre.args[0], '-c');
  assert.equal(pre.o.env[signin.TOKEN_ENV], undefined);
  assert(!pre.o.secretNames.includes(signin.TOKEN_ENV));
  assert(!JSON.stringify(pre.o.env).includes(FAKE_ACCESS));
  assert.equal(session.o.env[signin.TOKEN_ENV], FAKE_ACCESS);
  assert(session.o.secretNames.includes(signin.TOKEN_ENV));
  assert(session.o.redactions.includes(FAKE_ACCESS));
  for (const launch of f.launches) assert(!JSON.stringify(launch.o.env).includes(FAKE_REFRESH));
  assert.equal(session.o.env.ANTHROPIC_API_KEY, undefined);
});

test('box not signed in: the run is blocked before any job code runs', async t => {
  const f = runnerFixture(t);
  const receipt = await f.r.runDelivery(f.j, f.delivery());
  assert.equal(receipt.outcome, 'blocked');
  assert.equal(receipt.errorCode, 'provider_not_signed_in');
  assert.equal(f.launches.length, 0);
});

test('next tick after sign-in runs a previously blocked delivery exactly once', async t => {
  const f = runnerFixture(t);
  const before = await f.r.scheduled(f.j);
  assert.equal(before.errorCode, 'provider_not_signed_in');
  assert.equal(f.launches.length, 0);
  f.writeCred(Date.now() + 8 * 3600000);
  assert.equal((await f.r.scheduled(f.j)).outcome, 'succeeded');
  assert.equal(f.launches.length, 2); // precondition and session
  assert.equal((await f.r.scheduled(f.j)).outcome, 'duplicate');
  assert.equal(f.launches.length, 2);
  const reports = f.calls.filter(call => call.action === 'report');
  assert.deepEqual(reports.map(report => report.outcome), ['blocked', 'succeeded']);
});

test('a broker provider secret keeps the previous path and never reads the sign-in', async t => {
  const f = runnerFixture(t, {providerSecret: 'ANTHROPIC_API_KEY'});
  const receipt = await f.r.runDelivery(f.j, f.delivery());
  assert.equal(receipt.outcome, 'succeeded');
  assert(f.calls.some(c => c.op === 'secret' && c.secretName === 'ANTHROPIC_API_KEY'));
  assert(f.launches.every(l => l.o.env[signin.TOKEN_ENV] === undefined));
});

test('extracts the login URL from pty output with escapes and validates codes', () => {
  assert.equal(signin.extractLoginUrl('\u001b[1mVisit:\u001b[0m https://claude.ai/oauth/authorize?code=true&state=abc\r\nPaste code'), 'https://claude.ai/oauth/authorize?code=true&state=abc');
  assert.equal(signin.extractLoginUrl('https://evil.example/claude.ai'), null);
  assert.equal(signin.validLoginCode('abcDEF123#state'), true);
  assert.equal(signin.validLoginCode('-tabcdefgh'), false);
  assert.equal(signin.validLoginCode('abc def\nrm'), false);
});

// Byte shape printed by `claude auth login --claudeai` (Claude Code 2.1.299):
// an OSC 8 hyperlink terminated with BEL, URL as target and as visible text.
const REAL_URL = 'https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=user%3Ainference&code_challenge=abc_DEF-123&code_challenge_method=S256&state=xyz-789';

test('login URL: OSC 8 hyperlink terminated with BEL', () => {
  const out = `Browser didn't open? Use the url below to sign in (c to copy)\r\n\r\nvisit: \u001b]8;;${REAL_URL}\u0007${REAL_URL}\u001b]8;;\u0007\r\n\r\nPaste code here if prompted > `;
  assert.equal(out.split('').filter(ch => ch.charCodeAt(0) < 0x20 && ch !== '\r' && ch !== '\n').map(ch => ch.charCodeAt(0)).join(','), '27,7,27,7');
  const url = signin.extractLoginUrl(out);
  assert.equal(url, REAL_URL);
  assert.equal(signin.validLoginUrl(url), true);
});

test('login URL: OSC 8 hyperlink terminated with ST', () => {
  const out = `visit: \u001b]8;;${REAL_URL}\u001b\\${REAL_URL}\u001b]8;;\u001b\\\r\nPaste code here if prompted > `;
  assert.equal(signin.extractLoginUrl(out), REAL_URL);
});

test('login URL: plain URL, and no control character ever reaches the value', () => {
  assert.equal(signin.extractLoginUrl(`visit: ${REAL_URL}\r\n`), REAL_URL);
  assert.equal(signin.extractLoginUrl(`visit: ${REAL_URL}\u0007junk https://claude.com/x\r\n`), REAL_URL);
  for (const out of [`\u001b]8;;${REAL_URL}\u0007${REAL_URL}\u001b]8;;\u0007\n`, `\u001b]8;;${REAL_URL}\u001b\\${REAL_URL}\n`]) {
    // eslint-disable-next-line no-control-regex
    assert.doesNotMatch(signin.extractLoginUrl(out), /[\u0000-\u001f\u007f]/);
  }
  assert.equal(signin.extractLoginUrl('visit: https://claude.com/cai/not-oauth?x=1\n'), null);
  assert.equal(signin.extractLoginUrl('visit: https://claude.com:8443/oauth/authorize?x=1\n'), null);
  assert.equal(signin.validLoginUrl(`${REAL_URL}\u0007https://claude.com/x`), false);
});

test('login URL: the OSC 8 target wins over wrapped visible text, and a regenerated link replaces the old one', () => {
  const wrapped = `visit: \u001b]8;;${REAL_URL}\u0007${REAL_URL.slice(0, 40)}\r\n${REAL_URL.slice(40)}\u001b]8;;\u0007\r\n> `;
  assert.equal(signin.extractLoginUrl(wrapped), REAL_URL);
  const next = REAL_URL.replace('state=xyz-789', 'state=new-456');
  assert.equal(signin.extractLoginUrl(`visit: \u001b]8;;${REAL_URL}\u0007${REAL_URL}\u001b]8;;\u0007\r\nvisit: \u001b]8;;${next}\u0007${next}\u001b]8;;\u0007\r\n`), next);
  assert.equal(signin.extractLoginUrl(`visit: ${REAL_URL}\r\nvisit: ${next}\r\n`), next);
});

test('login URL: output split across chunks never yields a partial URL', () => {
  const full = `visit: \u001b]8;;${REAL_URL}\u0007${REAL_URL}\u001b]8;;\u0007\r\nPaste code here if prompted > `;
  for (let cut = 1; cut < full.length; cut++) {
    const got = signin.extractLoginUrl(full.slice(0, cut));
    assert(got === null || got === REAL_URL, `cut ${cut}: ${JSON.stringify(got)}`);
  }
  assert.equal(signin.extractLoginUrl(full), REAL_URL);
});

test('watcher: a refused login-url post is logged with its status and no URL', async t => {
  const lines = [];
  t.mock.method(console, 'error', line => lines.push(String(line)));
  const api = async (op, body) => {
    if (body.action === 'login-url') { const e = new Error('company_api_400'); e.status = 400; throw e; }
    return {};
  };
  const state = {};
  const login = () => ({alive: () => true, output: () => `visit: ${REAL_URL}\r\n`, sendCode() {}, stop() {}});
  await assert.rejects(signin.signinTick(state, {api, isSignedIn: () => false, start: login}));
  assert.equal(state.posted, null);
  assert.equal(lines.length, 1);
  assert.deepEqual(JSON.parse(lines[0]), {service: 'company-signin', code: 'login_url_refused', status: 400});
  assert(!lines[0].includes('claude.com'));
});

test('runuser is resolved to an absolute sbin path (Amazon Linux 2023 has it only in /usr/sbin)', async () => {
  const jobs = await import('../lib/company-jobs.mjs');
  assert.equal(jobs.runuserPath({exists: p => p === '/usr/sbin/runuser'}), '/usr/sbin/runuser');
  assert.equal(jobs.runuserPath({exists: p => p === '/sbin/runuser'}), '/sbin/runuser');
  assert.throws(() => jobs.runuserPath({exists: () => false}), {code: 'runuser_missing'});
});

test('watcher: a login child that exits 127 is logged once per distinct failure, with no output text', async t => {
  const lines = [];
  t.mock.method(console, 'error', line => lines.push(String(line)));
  const spawned = [];
  const fakeSpawn = (cmd, args) => {
    spawned.push(cmd);
    const handlers = {};
    const child = {stdout: {on() {}}, stderr: {on(ev, fn) { fn(Buffer.from('runuser: command not found\n')); }},
      stdin: {write() {}}, kill() {}, on(ev, fn) { handlers[ev] = fn; }};
    queueMicrotask(() => handlers.exit?.(127, null));
    return child;
  };
  const start = () => signin.startLogin({runuser: '/usr/sbin/runuser', spawnImpl: fakeSpawn});
  const api = async (_op, body) => body.action === 'regenerate-pending' ? {pending: false} : {ok: true};
  const state = {};
  const deps = {api, isSignedIn: () => false, start};
  for (let i = 0; i < 3; i++) { await signin.signinTick(state, deps); await new Promise(r => setImmediate(r)); }
  assert.equal(spawned.length, 3);
  assert(spawned.every(cmd => cmd === '/usr/sbin/runuser'));
  const exited = lines.filter(l => l.includes('login_exited'));
  assert.equal(exited.length, 1);
  assert.deepEqual(JSON.parse(exited[0]), {service: 'company-signin', code: 'login_exited', status: 127, signal: null});
  assert(lines.every(l => !l.includes('not found')));
});

test('watcher: the same login failure is logged again after a sign-in recovers', async t => {
  const lines = [];
  t.mock.method(console, 'error', line => lines.push(String(line)));
  const dead = () => ({alive: () => false, exitInfo: () => ({status: 127, signal: null}), output: () => '', sendCode() {}, stop() {}});
  const api = async (_op, body) => body.action === 'regenerate-pending' ? {pending: false} : {ok: true};
  let signedIn = false;
  const state = {};
  const deps = {api, isSignedIn: () => signedIn, start: dead};
  await signin.signinTick(state, deps);
  await signin.signinTick(state, deps);
  await signin.signinTick(state, deps);
  signedIn = true; await signin.signinTick(state, deps);
  signedIn = false; await signin.signinTick(state, deps);
  await signin.signinTick(state, deps);
  assert.equal(lines.filter(l => l.includes('login_exited')).length, 2);
});

test('watcher: posts the URL once, types a valid code, reports completion once, honours regenerate', async () => {
  const calls = [];
  let codeQueue = ['abcDEF123#state', null];
  let pending = false;
  const api = async (op, body) => {
    calls.push(body.action);
    if (body.action === 'login-code') return {code: codeQueue.shift() ?? null};
    if (body.action === 'regenerate-pending') return {pending};
    return {ok: true};
  };
  const typed = [];
  let starts = 0;
  const login = () => { starts++; let alive = true; return {alive: () => alive, output: () => 'Open https://claude.ai/oauth/authorize?x=1 now', sendCode: c => typed.push(c), stop: () => { alive = false; }}; };
  let signedIn = false;
  const deps = {api, isSignedIn: () => signedIn, start: login};
  const state = {};
  await signin.signinTick(state, deps);
  await signin.signinTick(state, deps);
  assert.equal(calls.filter(a => a === 'login-url').length, 1);
  assert.deepEqual(typed, ['abcDEF123#state']);
  pending = true;
  await signin.signinTick(state, deps);
  pending = false;
  await signin.signinTick(state, deps);
  assert.equal(starts, 2);
  assert.equal(calls.filter(a => a === 'login-url').length, 2);
  signedIn = true;
  assert.equal(await signin.signinTick(state, deps), 'signed_in');
  await signin.signinTick(state, deps);
  assert.equal(calls.filter(a => a === 'login-complete').length, 1);
});

test('watcher refuses to type an unsafe code', async () => {
  const typed = [];
  const state = {};
  const deps = {api: async (_op, body) => body.action === 'login-code' ? {code: 'abc\nrm -rf /'} : body.action === 'regenerate-pending' ? {pending: false} : {ok: true},
    isSignedIn: () => false, start: () => ({alive: () => true, output: () => 'https://claude.ai/oauth/authorize?x=1\r\n', sendCode: c => typed.push(c), stop: () => {}})};
  await signin.signinTick(state, deps);
  assert.deepEqual(typed, []);
});

test('installer: sign-in mode creates a separate account hq-jobs cannot reach and a watcher unit', () => {
  const install = fs.readFileSync(new URL('../company-jobs-install.sh', import.meta.url), 'utf8');
  assert.match(install, /ensure_system_account hq-claude-auth \/var\/lib\/hq-claude-auth/);
  assert.match(install, /install -d -m 700 -o hq-claude-auth -g hq-claude-auth \/var\/lib\/hq-claude-auth /);
  assert.match(install, /hq-jobs can reach the Claude sign-in/);
  assert.match(install, /company-signin\.mjs" watch/);
  assert.doesNotMatch(install, /!c\.providerSecret\)throw/);
});

test('an expired token that the CLI cannot refresh is not signed in, so the watcher starts a new login', t => {
  const c = credDir(t);
  c.write(1000);
  assert.equal(signin.signedIn(c.file, {now: () => 5000, refresh: () => false}), false);
  assert.equal(signin.signedIn(c.file, {now: () => 5000, refresh: () => { c.write(99999); return true; }}), true);
});

test('restarted watcher posts a new link and still honours regenerate', async () => {
  const calls = [];
  const phases = [];
  let pending = false;
  let starts = 0;
  const api = async (_op, body) => {
    calls.push(body.action);
    if (body.action === 'login-code') return {code: null};
    if (body.action === 'regenerate-pending') return {pending};
    return {ok: true};
  };
  const login = () => {
    starts += 1;
    let alive = true;
    return {
      alive: () => alive,
      output: () => 'Open https://claude.ai/oauth/authorize?x=9 now',
      sendCode() {},
      stop: () => { alive = false; },
    };
  };
  const deps = {api, isSignedIn: () => false, start: login, recordPhase: status => phases.push(status), now: () => 1_700_000_000_000};
  // A restarted process has empty memory. It posts the new login's link.
  const restarted = {};
  await signin.signinTick(restarted, deps);
  assert.equal(calls.filter(action => action === 'login-url').length, 1);
  assert.deepEqual(phases.at(-1), {phase: 'awaiting_person', since: 1_700_000_000_000});
  assert.equal(JSON.stringify(phases).includes('claude'), false);
  pending = true;
  await signin.signinTick(restarted, deps);
  pending = false;
  await signin.signinTick(restarted, deps);
  assert.equal(starts, 2);
  assert.equal(calls.filter(action => action === 'login-url').length, 2);
  assert.deepEqual(phases.at(-1), {phase: 'awaiting_person', since: 1_700_000_000_000});
});

test('watcher records code entry without storing the code or the URL', async () => {
  const phases = [];
  const deps = {
    api: async (_op, body) => body.action === 'login-code' ? {code: 'abcDEF123#s'} : body.action === 'regenerate-pending' ? {pending: false} : {ok: true},
    isSignedIn: () => false,
    start: () => ({alive: () => true, output: () => 'https://claude.ai/oauth/authorize?x=1\r\n', sendCode() {}, stop() {}}),
    recordPhase: status => phases.push(status),
    now: () => 50,
  };
  await signin.signinTick({}, deps);
  assert.deepEqual(phases.at(-1), {phase: 'code_entry', since: 50});
  const encoded = JSON.stringify(phases);
  assert.equal(encoded.includes('abcDEF'), false);
  assert.equal(encoded.includes('claude'), false);
});

test('watcher types a repeated code only once', async () => {
  const typed = [];
  const deps = {api: async (_op, body) => body.action === 'login-code' ? {code: 'abcDEF123#s'} : body.action === 'regenerate-pending' ? {pending: false} : {ok: true},
    isSignedIn: () => false, start: () => ({alive: () => true, output: () => 'https://claude.ai/oauth/authorize?x=1\r\n', sendCode: c => typed.push(c), stop: () => {}})};
  const state = {};
  await signin.signinTick(state, deps);
  await signin.signinTick(state, deps);
  assert.deepEqual(typed, ['abcDEF123#s']);
});

// Feedback 34753dc8: a box that was never signed in polled every ~5.6 s for
// days, kept a two-day-old link, and never surfaced a code Claude refused.
function pacedBox({hot = () => false, code = () => null, pending = () => false} = {}) {
  const calls = [];
  const api = async (_op, body) => {
    calls.push(body.action);
    if (body.action === 'login-code') return {code: code(), hot: hot()};
    if (body.action === 'regenerate-pending') return {pending: pending()};
    return {ok: true};
  };
  let starts = 0;
  const typed = [];
  const start = () => {
    starts += 1;
    const link = 'https://claude.ai/oauth/authorize?attempt=' + starts;
    let alive = true;
    return {alive: () => alive, output: () => 'visit: ' + link + '\r\n', sendCode: c => typed.push(c), stop: () => { alive = false; }};
  };
  let clock = 1_700_000_000_000;
  const deps = {api, isSignedIn: () => false, start, now: () => clock};
  return {calls, typed, deps, state: {}, starts: () => starts, advance: ms => { clock += ms; }, now: () => clock,
    urls: () => calls.filter(a => a === 'login-url').length};
}

test('pacing: polls every 5 s while the link is fresh, every 30 s after 5 idle minutes, back to 5 s when someone is on the card', async () => {
  let hot = false;
  const b = pacedBox({hot: () => hot});
  await signin.signinTick(b.state, b.deps);
  assert.equal(signin.pollDelayMs(b.state, b.now()), 5000);
  b.advance(signin.IDLE_AFTER_MS - 1);
  await signin.signinTick(b.state, b.deps);
  assert.equal(signin.pollDelayMs(b.state, b.now()), 5000);
  b.advance(1);
  await signin.signinTick(b.state, b.deps);
  assert.equal(signin.pollDelayMs(b.state, b.now()), 30000);
  assert(signin.IDLE_POLL_MS >= 30000 && signin.IDLE_POLL_MS <= 60000);
  hot = true;
  await signin.signinTick(b.state, b.deps);
  assert.equal(signin.pollDelayMs(b.state, b.now()), 5000);
  hot = false;
  b.advance(signin.IDLE_AFTER_MS);
  await signin.signinTick(b.state, b.deps);
  assert.equal(signin.pollDelayMs(b.state, b.now()), 30000);
});

test('pacing: a typed code, a regenerate, or a login still starting keeps the 5 s poll', async () => {
  let code = null;
  let pending = false;
  const b = pacedBox({code: () => code});
  assert.equal(signin.pollDelayMs({}, b.now()), 5000);
  await signin.signinTick(b.state, b.deps);
  b.advance(signin.IDLE_AFTER_MS);
  await signin.signinTick(b.state, b.deps);
  assert.equal(signin.pollDelayMs(b.state, b.now()), 30000);
  code = 'abcDEF123#state';
  await signin.signinTick(b.state, b.deps);
  assert.deepEqual(b.typed, ['abcDEF123#state']);
  assert.equal(signin.pollDelayMs(b.state, b.now()), 5000);
  const c = pacedBox({pending: () => pending});
  await signin.signinTick(c.state, c.deps);
  c.advance(signin.IDLE_AFTER_MS);
  pending = true;
  await signin.signinTick(c.state, c.deps);
  pending = false;
  assert.equal(signin.pollDelayMs(c.state, c.now()), 5000);
});

test('an expired link is replaced once someone is on the card, and kept while no one is', async t => {
  const lines = [];
  t.mock.method(console, 'error', line => lines.push(String(line)));
  let hot = false;
  const b = pacedBox({hot: () => hot});
  await signin.signinTick(b.state, b.deps);
  assert.equal(b.urls(), 1);
  // Two days with no one on the card: same login, same link, no churn.
  b.advance(2 * 24 * 3600 * 1000);
  await signin.signinTick(b.state, b.deps);
  assert.equal(b.starts(), 1);
  assert.equal(b.urls(), 1);
  // An admin opens the card: the stale link is replaced with a new one.
  hot = true;
  await signin.signinTick(b.state, b.deps);
  await signin.signinTick(b.state, b.deps);
  assert.equal(b.starts(), 2);
  assert.equal(b.urls(), 2);
  assert.equal(b.state.posted, 'https://claude.ai/oauth/authorize?attempt=2');
  // The fresh link is not replaced again while it is still inside its window.
  b.advance(signin.LOGIN_URL_TTL_MS - 1);
  await signin.signinTick(b.state, b.deps);
  assert.equal(b.starts(), 2);
  assert.deepEqual(lines.map(l => JSON.parse(l)), [{service: 'company-signin', code: 'login_url_expired_restart'}]);
  assert(!lines.join('\n').includes('claude.ai'));
});

test('an old server with no hot hint never triggers an auto-restart', async () => {
  const calls = [];
  let starts = 0;
  let t = 0;
  const deps = {
    api: async (_op, body) => { calls.push(body.action); return body.action === 'login-code' ? {code: null} : body.action === 'regenerate-pending' ? {pending: false} : {ok: true}; },
    isSignedIn: () => false,
    start: () => { starts++; return {alive: () => true, output: () => 'https://claude.ai/oauth/authorize?x=1\r\n', sendCode() {}, stop() {}}; },
    now: () => (t += signin.LOGIN_URL_TTL_MS),
  };
  const state = {};
  for (let i = 0; i < 4; i++) await signin.signinTick(state, deps);
  assert.equal(starts, 1);
  assert.equal(calls.filter(a => a === 'login-url').length, 1);
});

test('a typed code that neither signs in nor brings a new link restarts the login, so the server records it as rejected', async t => {
  const lines = [];
  t.mock.method(console, 'error', line => lines.push(String(line)));
  let code = null;
  const b = pacedBox({code: () => code});
  await signin.signinTick(b.state, b.deps);
  code = 'abcDEF123#state';
  await signin.signinTick(b.state, b.deps);
  code = null;
  b.advance(signin.CODE_RESULT_TIMEOUT_MS - 1);
  await signin.signinTick(b.state, b.deps);
  assert.equal(b.starts(), 1);
  b.advance(1);
  await signin.signinTick(b.state, b.deps);
  await signin.signinTick(b.state, b.deps);
  assert.equal(b.starts(), 2);
  assert.equal(b.urls(), 2);
  assert.equal(b.state.sentCode, null);
  assert.deepEqual(lines.map(l => JSON.parse(l)), [{service: 'company-signin', code: 'login_code_timeout'}]);
  assert(!lines.join('\n').includes('abcDEF'));
});
