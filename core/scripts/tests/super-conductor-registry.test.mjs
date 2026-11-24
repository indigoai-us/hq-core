// Tests for core/scripts/super-conductor-registry.mjs.
// Run: bash core/scripts/tests/super-conductor-registry.test.sh
// Every test uses throwaway registry and conduct directories under the OS
// temp dir; nothing touches the real profiles or live conductor state.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SCRIPT = path.join(HERE, '..', 'super-conductor-registry.mjs');
const PREFS = path.join(HERE, '..', 'super-conductor-prefs.mjs');

function sandbox() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sc-registry-'));
  const env = {
    ...process.env,
    SC_REGISTRY_DIR: path.join(dir, 'reg'),
    SC_CONDUCT_DIR: path.join(dir, 'conduct'),
    SC_BASE_PREFS: path.join(dir, 'base.yaml'),
  };
  fs.writeFileSync(env.SC_BASE_PREFS, 'channels:\n  - hq_dms\nemail_accounts:\n  - shared@example.com\nteam:\n  - "Pat"\nwatch_interval:\n  present: 60\n  away: 1500\n');
  const run = (...args) => spawnSync('node', [SCRIPT, ...args], { env, encoding: 'utf8' });
  const ok = (...args) => {
    const r = run(...args);
    assert.equal(r.status, 0, `${args.join(' ')} failed: ${r.stderr}`);
    return r.stdout.trim().startsWith('{') || r.stdout.trim().startsWith('[') ? JSON.parse(r.stdout) : r.stdout.trim();
  };
  const answers = (obj) => { const f = path.join(dir, `answers-${obj.name}.json`); fs.writeFileSync(f, JSON.stringify(obj)); return f; };
  return { dir, env, run, ok, answers };
}

const ALPHA = {
  name: 'alpha', company: 'acme', companies: ['acme'], primary_for_companies: ['acme'],
  session: { desktop: 'local_alpha' },
  scope: { manages: ['Acme owner work'], session_groups: ['Acme'], not_watching_groups: ['Beta lanes'], not_watching_sessions: ['local_beta_child'] },
  spawn: { mode: 'ask' }, adopt: { mode: 'listed', sessions: ['local_a1'] },
  cadence: { present: 300, away: 'present' },
  sweep: { channels: ['hq_dms', 'email'], email_accounts: ['alpha@example.com'] },
  stats: { calendar: { accounts: ['alpha@example.com'], always_join: ['Standup'] } },
  decisions: { mode: 'own_queue' },
};
const BETA = {
  name: 'beta', company: 'acme', companies: ['acme'],
  session: { desktop: 'local_beta' },
  scope: { manages: ['Beta project lanes'], session_groups: ['Beta lanes'], route_keywords: ['release hold'] },
  spawn: { mode: 'auto_within_scope' }, adopt: { mode: 'all_in_scope', sessions: ['local_beta_child'] },
  cadence: { present: 10, away: 99999 },
  sweep: { channels: [] },
  decisions: { mode: 'desk_session', desk_session: 'local_beta_desk' },
};

test('questions cover every questionnaire topic and end with the name', () => {
  const { ok } = sandbox();
  const q = ok('questions');
  const keys = q.map((x) => x.key);
  for (const k of ['scope.manages', 'spawn.mode', 'adopt.mode', 'cadence.present', 'cadence.away', 'sweep.channels', 'stats', 'decisions.mode', 'scope.not_watching']) assert.ok(keys.includes(k), k);
  assert.equal(keys[keys.length - 1], 'name');
});

test('create writes a profile with its own runtime files; dry run writes nothing', () => {
  const { ok, env, answers } = sandbox();
  const dry = ok('create', '--answers', answers(ALPHA), '--dry-run');
  assert.equal(dry.dry_run, true);
  assert.equal(fs.existsSync(path.join(env.SC_REGISTRY_DIR, 'alpha.yaml')), false);
  const made = ok('create', '--answers', answers(ALPHA));
  assert.equal(made.profile.cadence.away, 300, 'away "present" copies the present cadence');
  assert.deepEqual(made.profile.sweep.channels, ['sessions', 'hq_dms', 'email']);
  assert.equal(made.profile.cadence.message_wake, true);
  const shown = ok('show', 'alpha');
  assert.deepEqual(shown.stats.calendar.always_join, ['Standup']);
  assert.equal(shown.files.state, 'workspace/reports/conduct/sc-alpha-state.json');
});

test('names must be unique and well formed', () => {
  const { ok, run, answers } = sandbox();
  ok('create', '--answers', answers(ALPHA));
  assert.equal(run('create', '--answers', answers(ALPHA)).status, 4);
  assert.notEqual(run('create', '--answers', answers({ ...ALPHA, name: 'Bad Name' })).status, 0);
  assert.notEqual(run('create', '--answers', answers({ ...ALPHA, name: 'base' })).status, 0);
});

test('cadence is clamped to 30-3600 seconds', () => {
  const { ok, answers } = sandbox();
  const p = ok('create', '--answers', answers(BETA)).profile;
  assert.equal(p.cadence.present, 30);
  assert.equal(p.cadence.away, 3600);
});

test('a session adopted by one conductor cannot be listed by another', () => {
  const { ok, run, answers } = sandbox();
  ok('create', '--answers', answers(ALPHA));
  const r = run('create', '--answers', answers({ ...BETA, adopt: { mode: 'listed', sessions: ['local_a1'] } }));
  assert.equal(r.status, 4);
  assert.match(r.stderr, /adopted session 'local_a1'/);
});

test('bind keys runtime files on the link and refuses a link another conductor uses', () => {
  const { ok, run, answers } = sandbox();
  ok('create', '--answers', answers(ALPHA));
  ok('create', '--answers', answers(BETA));
  const b = ok('bind', 'alpha', '--link', 'cl-test-1');
  assert.equal(b.files.decisions, 'workspace/reports/conduct/cl-test-1-decisions.jsonl');
  assert.equal(run('bind', 'beta', '--link', 'cl-test-1').status, 4);
  ok('bind', 'beta', '--link', 'cl-test-2');
  const v = ok('validate');
  assert.equal(v.ok, true);
});

test('claims give each session one owner', () => {
  const { ok, run, answers } = sandbox();
  ok('create', '--answers', answers(ALPHA));
  ok('create', '--answers', answers(BETA));
  ok('claim', 'alpha', '--session', 'local_x');
  const r = run('claim', 'beta', '--session', 'local_x');
  assert.equal(r.status, 4);
  assert.equal(JSON.parse(r.stdout).held_by, 'alpha');
  assert.equal(run('claim', 'alpha', '--session', 'local_beta').status, 4, 'cannot adopt another conductor');
  assert.equal(run('claim', 'alpha', '--session', 'local_beta_desk').status, 4, 'cannot adopt another desk');
  assert.equal(run('claim', 'alpha', '--session', 'local_beta_child').status, 4, 'not_watching_sessions is refused');
  assert.equal(run('release', 'beta', '--session', 'local_x').status, 4, 'only the holder releases');
  ok('release', 'alpha', '--session', 'local_x');
  ok('claim', 'beta', '--session', 'local_x');
});

test('route sends items to the conductor whose scope matches', () => {
  const { ok, run, answers } = sandbox();
  ok('create', '--answers', answers(ALPHA));
  ok('create', '--answers', answers(BETA));
  assert.equal(ok('route', '--session', 'local_beta_child').owner, 'beta');
  assert.equal(ok('route', '--session', 'local_beta_desk').owner, 'beta');
  assert.equal(ok('route', '--group', 'Beta lanes').owner, 'beta');
  assert.equal(ok('route', '--company', 'acme', '--text', 'Can we lift the release hold?').owner, 'beta');
  assert.equal(ok('route', '--company', 'acme', '--text', 'Need brand folder access').owner, 'alpha', 'primary wins a tie');
  assert.equal(ok('route', '--channel', 'email:alpha@example.com').owner, 'alpha');
  ok('claim', 'alpha', '--session', 'local_y');
  assert.equal(ok('route', '--session', 'local_y').owner, 'alpha');
  const none = run('route', '--company', 'other-co');
  assert.equal(none.status, 5);
  assert.equal(JSON.parse(none.stdout).owner, null);
});

test('resolve: one profile asks to confirm, several ask to pick, session matches resume', () => {
  const { ok, answers } = sandbox();
  assert.equal(ok('resolve').mode, 'new');
  ok('create', '--answers', answers(ALPHA));
  const one = ok('resolve');
  assert.equal(one.mode, 'only');
  assert.equal(one.confirm, true);
  ok('create', '--answers', answers(BETA));
  assert.equal(ok('resolve').mode, 'pick');
  assert.equal(ok('resolve', '--session', 'local_beta').profile.name, 'beta');
  assert.equal(ok('resolve', 'alpha').mode, 'named');
});

test('render-prefs layers the profile on the base file and drops other mailboxes', () => {
  const { ok, env, answers } = sandbox();
  ok('create', '--answers', answers(ALPHA));
  ok('create', '--answers', answers(BETA));
  const fa = ok('render-prefs', 'alpha');
  const fb = ok('render-prefs', 'beta');
  const get = (f) => JSON.parse(execFileSync('node', [PREFS, 'get'], { env: { ...env, SC_PREFS_FILE: f }, encoding: 'utf8' }));
  const a = get(fa);
  assert.deepEqual(a.email_accounts, ['alpha@example.com']);
  assert.deepEqual(a.team, ['Pat'], 'base keys carry through');
  assert.deepEqual(a.watch_interval, { present: 300, away: 300 });
  assert.equal(a.conductor_name, 'alpha');
  const b = get(fb);
  assert.ok(!(b.email_accounts || []).includes('shared@example.com'), 'base mailbox is not swept by every conductor');
  assert.deepEqual(b.channels, ['sessions']);
});

test('set/add/remove edit one key and keep the profile valid; delete removes profile and claims only', () => {
  const { ok, run, env, answers } = sandbox();
  ok('create', '--answers', answers(ALPHA));
  ok('add', 'alpha', 'sweep.email_accounts', 'second@example.com');
  ok('remove', 'alpha', 'sweep.email_accounts', 'alpha@example.com');
  assert.deepEqual(ok('show', 'alpha').sweep.email_accounts, ['second@example.com']);
  ok('set', 'alpha', 'cadence.present', '120');
  assert.equal(ok('show', 'alpha').cadence.present, 120);
  assert.notEqual(run('set', 'alpha', 'name', 'zeta').status, 0, 'name is registry-managed');
  ok('claim', 'alpha', '--session', 'local_z');
  fs.mkdirSync(env.SC_CONDUCT_DIR, { recursive: true });
  const state = path.join(env.SC_CONDUCT_DIR, 'sc-alpha-state.json');
  fs.writeFileSync(state, '{}');
  assert.notEqual(run('delete', 'alpha').status, 0, 'delete needs --yes');
  ok('delete', 'alpha', '--yes');
  assert.equal(fs.existsSync(path.join(env.SC_REGISTRY_DIR, 'alpha.yaml')), false);
  assert.equal(fs.existsSync(state), true, 'state files are never deleted');
  assert.deepEqual(ok('claims').claims, {});
});

test('no_forward_to: the asker leaves a peer item alone instead of forwarding it', () => {
  const { ok, answers } = sandbox();
  ok('create', '--answers', answers({ ...ALPHA, scope: { ...ALPHA.scope, no_forward_to: ['beta'] } }));
  ok('create', '--answers', answers(BETA));
  const r = ok('route', '--company', 'acme', '--text', 'release hold on 236?', '--from', 'alpha');
  assert.equal(r.owner, 'beta');
  assert.equal(r.forward, false);
  assert.match(r.reason, /does not forward to beta/);
  const back = ok('route', '--company', 'acme', '--text', 'brand folder access', '--from', 'beta');
  assert.equal(back.owner, 'alpha');
  assert.equal(back.forward, true);
  const own = ok('route', '--company', 'acme', '--text', 'brand folder access', '--from', 'alpha');
  assert.equal(own.forward, false, 'an item the asker owns is handled, not forwarded');
});

test('decision defaults: desk session and queued child asks; stay_in_window renders the escalation time', () => {
  const { ok, env, answers } = sandbox();
  const plain = ok('create', '--answers', answers({ ...ALPHA, decisions: undefined })).profile;
  assert.equal(plain.decisions.mode, 'desk_session');
  assert.equal(plain.decisions.child_asks, 'queue');
  ok('create', '--answers', answers({ ...BETA, decisions: { mode: 'own_queue', child_asks: 'stay_in_window', child_ask_escalate_minutes: 90 } }));
  const f = ok('render-prefs', 'beta');
  const prefs = JSON.parse(execFileSync('node', [PREFS, 'get'], { env: { ...env, SC_PREFS_FILE: f }, encoding: 'utf8' }));
  assert.equal(prefs.child_ask_escalate_minutes, 90);
  assert.equal(prefs.conductor_decisions, 'own_queue');
  assert.equal(prefs.conductor_child_asks, 'stay_in_window');
  const fa = ok('render-prefs', 'alpha');
  const pa = JSON.parse(execFileSync('node', [PREFS, 'get'], { env: { ...env, SC_PREFS_FILE: fa }, encoding: 'utf8' }));
  assert.equal(pa.child_ask_escalate_minutes, undefined, 'queued child asks carry no escalation time');
});

test('questions ask where child asks go, right after the decisions question', () => {
  const { ok } = sandbox();
  const keys = ok('questions').map((x) => x.key);
  assert.equal(keys.indexOf('decisions.child_asks'), keys.indexOf('decisions.mode') + 1);
});
