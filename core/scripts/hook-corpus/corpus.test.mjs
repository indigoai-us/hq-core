// hq-core: public
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { generate, hash } from './generate-corpus.mjs';
import { compare, diagnostic, selectedCorrectly } from './differential.mjs';
const here = dirname(fileURLToPath(import.meta.url));
const corpus = JSON.parse(readFileSync(join(here, 'corpus.json'), 'utf8'));

test('committed corpus equals deterministic registry/policy generation', () => {
  assert.deepEqual(corpus, generate());
});

test('policy entries hash only the when/on dispatch fields, never the policy body', () => {
  assert.ok(corpus.policies.length > 0);
  for (const policy of corpus.policies) {
    assert.deepEqual(Object.keys(policy).sort(), ['on', 'path', 'trigger_sha256', 'when']);
    assert.equal(policy.trigger_sha256, hash(`when: ${policy.when}\non: ${policy.on}\n`));
  }
});
test('every registry occurrence and prefilter has both outcomes in both runtime shapes', () => {
  const registry = JSON.parse(readFileSync(join(here, '../../../.claude/hooks/hook-registry.json'), 'utf8'));
  for (const [event, groups] of Object.entries(registry.hooks)) {
    groups.forEach((group, gi) => group.hooks.forEach((hook, hi) => {
      for (const rule of ['entry', ...Object.keys(hook.prefilter || {}).map(key => 'prefilter.' + key)]) {
        for (const runtime of ['claude', 'codex']) for (const matching of [true, false]) {
          const matches = corpus.cases.filter(row => row.entry === `${event}/${gi}/${hi}` &&
            row.rule === rule && row.runtime === runtime && row.matching === matching);
          assert.equal(matches.length, 1, `${event}/${gi}/${hi}/${rule}/${runtime}/${matching}`);
          assert.equal(matches[0].hook_id, hook.id);
        }
      }
    }));
  }
});
test('comparison detects exit, output, stderr and infrastructure failures', () => {
  const ok = {exit: 0, stdout: 'same', stderr: '', error: null};
  assert.equal(compare(ok, {...ok}), true);
  for (const mutant of [{exit: 2}, {stdout: 'different'}, {stderr: 'different'}, {error: 'ETIMEDOUT'}]) {
    assert.equal(compare(ok, {...ok, ...mutant}), false);
  }
  assert.equal(compare({...ok, error: 'ETIMEDOUT'}, {...ok, error: 'ETIMEDOUT'}), false);
  assert.equal(selectedCorrectly({matching: true, hook_id: 'test'}, {...ok, stdout: ''}), false);
});
test('mismatch diagnostics contain identifiers and hashes, never payload text', () => {
  const row = {...corpus.cases[0], payload: {prompt: 'PRIVATE_PAYLOAD_CANARY'}};
  const text = diagnostic(row, 'engine');
  assert.equal(text.includes('PRIVATE_PAYLOAD_CANARY'), false);
  const record = JSON.parse(text);
  assert.match(record.payload_hash, /^[a-f0-9]{64}$/);
  assert.equal(record.hook_id, row.hook_id);
  assert.equal(record.rule, row.rule);
});
test('CLI rejects divergent engines and suppresses their stdout and stderr', () => {
  const temp = mkdtempSync(join(tmpdir(), 'corpus-test-'));
  try {
    const path = join(temp, 'corpus.json');
    const row = {...corpus.cases[0], payload: {prompt: 'PRIVATE_PAYLOAD_CANARY'}};
    writeFileSync(path, JSON.stringify({...corpus, cases: [row]}));
    const result = spawnSync(process.execPath, [join(here, 'differential.mjs'), '--corpus', path,
      '--engine-a', 'bash -c "cat; echo PRIVATE_STDERR_CANARY >&2"', '--engine-b', 'bash -c "cat >/dev/null"'],
    {encoding: 'utf8', timeout: 15000});
    assert.equal(result.status, 1);
    assert.equal((result.stdout + result.stderr).includes('PRIVATE_'), false);
    assert.equal(JSON.parse(result.stdout.split('\n')[0]).mismatch, 'engine');
  } finally { rmSync(temp, {recursive: true, force: true}); }
});
