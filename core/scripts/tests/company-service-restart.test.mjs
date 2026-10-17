// hq-core: public
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {applyRestart, releaseDigest, processChildren, readSigninPhase, writeSigninPhase, processStartAgeMs, IDLE_SIGNIN_BOUND_MS} from '../lib/company-service-restart.mjs';

function fixture(overrides = {}) {
  const calls = [];
  return {calls, deps: {
    digest: 'new-version', previous: 'old-version',
    mainPid: () => 42,
    pause: pid => calls.push(['pause', pid]),
    children: () => [],
    resume: pid => calls.push(['resume', pid]),
    restart: () => calls.push(['try-restart']),
    save: digest => calls.push(['save', digest]),
    ...overrides,
  }};
}

test('version change restarts before advancing the installed marker', async () => {
  const f = fixture();
  assert.equal(await applyRestart(f.deps), 'restarted');
  assert.deepEqual(f.calls, [['pause', 42], ['try-restart'], ['save', 'new-version'], ['resume', 42]]);
});

test('unchanged version makes no service calls', async () => {
  const f = fixture({previous: 'new-version', mainPid: () => { throw Error('must not inspect'); }});
  assert.equal(await applyRestart(f.deps), 'unchanged');
  assert.deepEqual(f.calls, []);
});

test('live code-entry child defers without advancing marker; completion retries', async () => {
  let active = true;
  const f = fixture({
    children: () => active ? [43] : [],
    // A received code, not merely a live login child. The child can be old.
    phase: () => ({phase: 'code_entry', since: 0}),
    childAgeMs: () => 60 * 60 * 1000,
  });
  assert.equal(await applyRestart(f.deps), 'deferred');
  assert.deepEqual(f.calls, [['pause', 42], ['resume', 42]]);
  active = false; // login completed or CLI exited/timed out
  assert.equal(await applyRestart(f.deps), 'restarted');
  assert.deepEqual(f.calls.slice(2), [['pause', 42], ['try-restart'], ['save', 'new-version'], ['resume', 42]]);
});

test('idle sign-in with no code entered restarts after the bound', async () => {
  const now = 1_700_000_000_000;
  const bound = IDLE_SIGNIN_BOUND_MS;
  const f = fixture({
    children: () => [43],
    phase: () => ({phase: 'awaiting_person', since: now - bound - 1}),
    now: () => now,
    idleBoundMs: bound,
    childAgeMs: () => 1000,
  });
  assert.equal(await applyRestart(f.deps), 'restarted');
  assert.deepEqual(f.calls, [['pause', 42], ['try-restart'], ['save', 'new-version'], ['resume', 42]]);
});

test('legacy idle login with no phase file restarts after the bound', async () => {
  const bound = IDLE_SIGNIN_BOUND_MS;
  const f = fixture({
    children: () => [43],
    phase: () => null,
    childAgeMs: () => bound + 1,
    idleBoundMs: bound,
  });
  assert.equal(await applyRestart(f.deps), 'restarted');
  assert.equal(f.calls.some(([name]) => name === 'try-restart'), true);
  assert.equal(f.calls.some(([name]) => name === 'save'), true);
});

test('fresh sign-in link inside the bound is not restarted', async () => {
  const now = 1_700_000_000_000;
  const bound = IDLE_SIGNIN_BOUND_MS;
  const f = fixture({
    children: () => [43],
    phase: () => ({phase: 'awaiting_person', since: now - 60_000}),
    now: () => now,
    idleBoundMs: bound,
    childAgeMs: () => bound + 1,
  });
  assert.equal(await applyRestart(f.deps), 'deferred');
  assert.equal(f.calls.some(([name]) => name === 'try-restart'), false);
});

test('code entry does not read child age and is not restarted', async () => {
  const f = fixture({
    children: () => [43],
    phase: () => ({phase: 'code_entry', since: 1}),
    childAgeMs: () => { throw Error('must not read age'); },
  });
  assert.equal(await applyRestart(f.deps), 'deferred');
  assert.equal(f.calls.some(([name]) => name === 'try-restart'), false);
});

test('corrupt sign-in phase fails closed and resumes the parent', async () => {
  const f = fixture({children: () => [43], phase: () => { throw Error('invalid_signin_phase'); }});
  await assert.rejects(applyRestart(f.deps), /invalid_signin_phase/);
  assert.deepEqual(f.calls.at(-1), ['resume', 42]);
  assert.equal(f.calls.some(([name]) => name === 'save'), false);
});

test('phase file stores only the phase and a timestamp', t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'signin-phase-'));
  t.after(() => fs.rmSync(dir, {recursive: true, force: true}));
  const file = path.join(dir, 'signin-phase');
  writeSigninPhase({phase: 'awaiting_person', since: 10}, file);
  assert.equal(fs.readFileSync(file, 'utf8'), 'awaiting_person 10\n');
  assert.equal(fs.statSync(file).mode & 0o077, 0);
  assert.deepEqual(readSigninPhase(file), {phase: 'awaiting_person', since: 10});
  fs.writeFileSync(file, 'awaiting_person 10 https://claude.example/oauth/authorize\n');
  assert.throws(() => readSigninPhase(file), /invalid_signin_phase/);
  assert.throws(() => writeSigninPhase({phase: 'awaiting_person', since: 1.5}, file), /invalid_signin_phase/);
  writeSigninPhase(null, file);
  assert.equal(readSigninPhase(file), null);
});

test('process start age uses starttime and ignores the command name', t => {
  const proc = fs.mkdtempSync(path.join(os.tmpdir(), 'restart-stat-'));
  t.after(() => fs.rmSync(proc, {recursive: true, force: true}));
  fs.mkdirSync(`${proc}/7`);
  fs.writeFileSync(`${proc}/7/stat`, '7 (claude auth login) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 500 0 0\n');
  assert.equal(processStartAgeMs(7, {procRoot: proc, clockTicks: 100, uptimeSeconds: 15.5}), 10500);
  fs.writeFileSync(`${proc}/7/stat`, '7 (sleep) S 1\n');
  assert.throws(() => processStartAgeMs(7, {procRoot: proc, clockTicks: 100, uptimeSeconds: 15.5}), /invalid_process_status/);
});

test('legacy watcher without a marker is checked rather than assumed current', async () => {
  const f = fixture({previous: null, children: () => [43]});
  assert.equal(await applyRestart(f.deps), 'deferred');
  assert.deepEqual(f.calls, [['pause', 42], ['resume', 42]]);
});

test('inactive watcher records release without starting a disabled service', async () => {
  const f = fixture({mainPid: () => 0});
  assert.equal(await applyRestart(f.deps), 'inactive');
  assert.deepEqual(f.calls, [['save', 'new-version']]);
});

for (const phase of ['pause', 'children', 'restart']) {
  test(`${phase} failure resumes parent and leaves update pending`, async () => {
    const f = fixture({[phase]: () => { throw Error('unavailable'); }});
    await assert.rejects(applyRestart(f.deps), /unavailable/);
    assert.deepEqual(f.calls.at(-1), ['resume', 42]);
    assert.equal(f.calls.some(([name]) => name === 'save'), false);
  });
}

test('service PID change during inspection defers', async () => {
  let reads = 0;
  const f = fixture({mainPid: () => ++reads === 1 ? 42 : 44});
  assert.equal(await applyRestart(f.deps), 'deferred');
  assert.deepEqual(f.calls, [['pause', 42], ['resume', 42]]);
});

test('digest includes version, watcher, transitive modules and unit', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'restart-digest-'));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  fs.mkdirSync(path.join(root, 'core/scripts/lib/nested'), {recursive: true});
  const files = ['core/core.yaml', 'core/scripts/lib/company-signin.mjs', 'core/scripts/lib/nested/import.mjs', 'hq-company-signin.service'];
  for (const file of files) fs.writeFileSync(path.join(root, file), 'original');
  let digest = releaseDigest(root, root);
  assert.equal(releaseDigest(root, root), digest);
  for (const file of files) {
    fs.writeFileSync(path.join(root, file), 'changed');
    const next = releaseDigest(root, root);
    assert.notEqual(next, digest, file);
    digest = next;
  }
});

test('process status includes children from every thread and fails closed', t => {
  const proc = fs.mkdtempSync(path.join(os.tmpdir(), 'restart-proc-'));
  t.after(() => fs.rmSync(proc, {recursive: true, force: true}));
  for (const tid of ['42', '44']) fs.mkdirSync(`${proc}/42/task/${tid}`, {recursive: true});
  fs.writeFileSync(`${proc}/42/task/42/children`, '');
  fs.writeFileSync(`${proc}/42/task/44/children`, '45 46 ');
  assert.deepEqual(processChildren(42, proc), [45, 46]);
  fs.writeFileSync(`${proc}/42/task/44/children`, 'invalid');
  assert.throws(() => processChildren(42, proc), /invalid_process_status/);
  fs.unlinkSync(`${proc}/42/task/44/children`);
  assert.throws(() => processChildren(42, proc), {code: 'ENOENT'});
});
