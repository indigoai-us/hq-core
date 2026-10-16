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
  signin.refreshViaCli({run: (cmd, args, opts) => { seen = {cmd, args, opts}; return {status: 0}; }});
  assert.equal(seen.cmd, 'runuser');
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
  const r = new CompanyRunner(c, api, {systemctl: () => {}, execute: async (_cmd, args, o) => { launches.push({args, o}); return {code: 0, text: args[0] === '-c' ? 'pre output' : '{"disposition":"reply"}'}; }});
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
    isSignedIn: () => false, start: () => ({alive: () => true, output: () => 'https://claude.ai/oauth/authorize?x=1', sendCode: c => typed.push(c), stop: () => {}})};
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

test('watcher types a repeated code only once', async () => {
  const typed = [];
  const deps = {api: async (_op, body) => body.action === 'login-code' ? {code: 'abcDEF123#s'} : body.action === 'regenerate-pending' ? {pending: false} : {ok: true},
    isSignedIn: () => false, start: () => ({alive: () => true, output: () => 'https://claude.ai/oauth/authorize?x=1', sendCode: c => typed.push(c), stop: () => {}})};
  const state = {};
  await signin.signinTick(state, deps);
  await signin.signinTick(state, deps);
  assert.deepEqual(typed, ['abcDEF123#s']);
});
