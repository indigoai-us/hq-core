// hq-core: public
// US-043: the caller rewrite moves runnable helper calls to `hq core` and
// leaves prose, comments, data and held hook files alone.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { TWINS, compareVersions, installFloor, rewriteLine, scanFile } from '../ci/rewrite-core-callers.mjs';
import * as rewriter from '../ci/rewrite-core-callers.mjs';

const SCRIPT = fileURLToPath(new URL('../ci/rewrite-core-callers.mjs', import.meta.url));

test('relative bash calls become hq core calls', () => {
  assert.equal(rewriteLine('bash core/scripts/rebuild-threads-index.sh').line, 'hq core rebuild-index threads');
  assert.equal(rewriteLine('  bash core/scripts/jobs-validate.sh personal/jobs/x.yaml').line, '  hq core jobs validate personal/jobs/x.yaml');
  assert.equal(rewriteLine('x="$(bash core/scripts/knowledge-prefs.sh get "$co" a)"').line, 'x="$(hq core knowledge-prefs get "$co" a)"');
  assert.equal(rewriteLine('run `sh ./core/scripts/hq-pin.sh check` first').line, 'run `hq core pin check` first');
  assert.equal(rewriteLine('exec core/scripts/hq-dm-bind.sh post').line, 'exec hq core dm-bind post');
});

test('a bare helper path as the first word of a line is a call', () => {
  assert.equal(rewriteLine('core/scripts/audit-log.sh append \\').line, 'hq core audit-log append \\');
  assert.equal(rewriteLine('  ./core/scripts/session-journal.sh list').line, '  hq core session-journal list');
  assert.equal(rewriteLine('Bash(core/scripts/hq-pin.sh:*), Read').line, 'Bash(hq core pin:*), Read');
  // Mid-line prose and case patterns are not calls.
  assert.equal(rewriteLine('see core/scripts/audit-log.sh for the format').line, 'see core/scripts/audit-log.sh for the format');
  assert.equal(rewriteLine('core/scripts/repo-run-registry.sh|exec').line, 'core/scripts/repo-run-registry.sh|exec');
});

test('allowed-tools permission patterns follow the command', () => {
  assert.equal(
    rewriteLine('allowed-tools: Bash(hq:*), Bash(bash core/scripts/jobs-validate.sh:*)').line,
    'allowed-tools: Bash(hq:*), Bash(hq core jobs validate:*)',
  );
});

test('a root variable becomes --hq-root for live commands only', () => {
  assert.equal(
    rewriteLine('bash "$ROOT/core/scripts/work-mesh-live-bind-trusted.sh" "${pin[@]}"').line,
    'hq core --hq-root "$ROOT" work-mesh-bind-trusted "${pin[@]}"',
  );
  assert.equal(
    rewriteLine('bash "$HQ_ROOT"/core/scripts/session-journal.sh due').line,
    'hq core --hq-root "$HQ_ROOT" session-journal due',
  );
  assert.equal(
    rewriteLine('nohup bash "$ROOT/core/scripts/refresh-vault-access.sh" --root "$ROOT"').line,
    'nohup hq core refresh-vault-access --root "$ROOT"',
  );
  assert.equal(TWINS['refresh-vault-access.sh'].root, 'cwd');
});

test('unbalanced quotes, prose, comments and data are left alone', () => {
  for (const line of [
    'bash "$ROOT/core/scripts/hq-pin.sh',
    'See `core/scripts/hq-pin.sh` for the format.',
    'core/scripts/repo-run-registry.sh|exec',
    'json_sources+=("$REPO_ROOT/core/scripts/resolve-company.sh")',
    'bash core/scripts/hq-session.sh add company indigo',
    'bash core/scripts/hq-pin.sh.bak',
  ]) {
    assert.equal(rewriteLine(line).line, line, line);
  }
  assert.equal(rewriteLine('# bash core/scripts/hq-pin.sh check', { shell: true }).line, '# bash core/scripts/hq-pin.sh check');
  assert.equal(rewriteLine('# bash core/scripts/hq-pin.sh check').line, '# hq core pin check');
});

test('hooks and the handoff-finalize helper are listed as held, not rewritten', () => {
  const hook = rewriteLine('  bash core/scripts/worktree.sh --name x', { file: '.claude/hooks/block-on-active-run.sh', shell: true });
  assert.equal(hook.line, '  bash core/scripts/worktree.sh --name x');
  assert.equal(hook.hits[0].action, 'held');
  const handoff = rewriteLine('bash core/scripts/handoff-finalize.sh --summary x', { file: '.claude/skills/handoff/SKILL.md' });
  assert.equal(handoff.line, 'bash core/scripts/handoff-finalize.sh --summary x');
  assert.equal(handoff.hits[0].action, 'held');
});

test('helper paths kept in a variable are reported for a hand fix', () => {
  const { rows, text } = scanFile('REG="$HQ_ROOT/core/scripts/repo-run-registry.sh"\n', 'core/scripts/example.sh');
  assert.equal(text, 'REG="$HQ_ROOT/core/scripts/repo-run-registry.sh"\n');
  assert.deepEqual(rows.map((row) => [row.helper, row.action]), [['repo-run-registry.sh', 'manual']]);
});

test('every command a caller now runs directly is covered by the install floor', () => {
  const floor = installFloor(fileURLToPath(new URL('../../..', import.meta.url)));
  assert.match(floor, /^\d+\.\d+\.\d+$/);
  for (const name of ['jobs-validate.sh', 'work-mesh-live-bind-trusted.sh', 'read-policy-frontmatter.sh', 'pipeline-conductor.sh', 'hq-dm-bind.sh', 'generate-workers-registry.sh']) {
    assert.ok(TWINS[name].minCli, name);
    assert.ok(compareVersions(TWINS[name].minCli, floor) <= 0, `${name} ${TWINS[name].minCli} > ${floor}`);
  }
  // hq-cli 5.309.1 and 5.78.0 had no hq core dm-bind / generate-workers-registry.
  assert.equal(TWINS['hq-dm-bind.sh'].minCli, '5.310.0');
  assert.equal(TWINS['generate-workers-registry.sh'].minCli, '5.89.0');
  assert.equal(compareVersions('5.345.63', '5.345.217'), -1);
  assert.equal(compareVersions('5.345.217', '5.345.63'), 1);
});

test('--check fails when a direct call needs more than the install floor', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'rewrite-core-callers-floor-'));
  try {
    fs.mkdirSync(path.join(root, 'core'), { recursive: true });
    fs.writeFileSync(path.join(root, 'core/core.yaml'), 'requiresHqCli: ">=5.300.0"\n');
    execFileSync('git', ['-C', root, 'init', '-q']);
    execFileSync('git', ['-C', root, 'add', '.']);
    const result = spawnSync(process.execPath, [SCRIPT, '--check', '--root', root], { encoding: 'utf8' });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /hq core pipeline conductor needs hq-cli 5\.345\.119, above requiresHqCli 5\.300\.0/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

// US-043 c3: the journal and schedule skills run `hq core session-journal` and
// `hq core job probe`; both commands need a floor so --check covers them.
// First releases (hq-cli tags, matched to npm gitHead): job probe 5.296.0
// (absent in 5.295.0), session-journal 5.317.0 (absent in 5.316.0).
test('commands the shipped skills run directly carry a minCli', () => {
  assert.equal(TWINS['hq-job-probe.sh'].minCli, '5.296.0');
  assert.equal(TWINS['session-journal.sh'].minCli, '5.317.0');
});

test('a direct hq core call of a twin with no minCli is found', () => {
  assert.equal(typeof rewriter.callsWithoutFloor, 'function');
  const { callsWithoutFloor } = rewriter;
  assert.deepEqual(callsWithoutFloor('hq core session-title list\n', 'x.md'), [{ line: 1, command: 'session-title' }]);
  // --hq-root before the command, repeated spaces, the longer command wins.
  assert.deepEqual(callsWithoutFloor('x="$(hq core --hq-root "$R" session-title-config get)"', 'x.sh'), [{ line: 1, command: 'session-title-config' }]);
  assert.deepEqual(callsWithoutFloor('run `hq core  job   remediate` now', 'x.md'), [{ line: 1, command: 'job remediate' }]);
  assert.deepEqual(callsWithoutFloor('then run hq core worktree-gc.', 'x.md'), [{ line: 1, command: 'worktree-gc' }]);
  // Floored commands, shell comments and longer words are not reported.
  assert.deepEqual(callsWithoutFloor('hq core session-journal list\nhq core job probe x\n', 'x.md'), []);
  assert.deepEqual(callsWithoutFloor('# hq core worktree-gc\n', 'x.sh'), []);
  assert.deepEqual(callsWithoutFloor('uhq core worktree-gc\n', 'x.md'), []);
});

test('--check fails when a caller runs a twin command that has no minCli', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'rewrite-core-callers-unfloored-'));
  try {
    const put = (file, text) => {
      fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
      fs.writeFileSync(path.join(root, file), text);
    };
    put('core/core.yaml', 'requiresHqCli: ">=5.345.221"\n');
    put('core/scripts/tests/demo.test.sh', 'hq core worktree-gc\n');
    execFileSync('git', ['-C', root, 'init', '-q']);
    execFileSync('git', ['-C', root, 'add', '.']);
    const check = () => spawnSync(process.execPath, [SCRIPT, '--check', '--root', root], { encoding: 'utf8' });
    // A test file is out of scope.
    assert.equal(check().status, 0);
    put('.claude/skills/demo/SKILL.md', 'Run:\n\n```bash\nhq core --hq-root "$HQ_ROOT" worktree-gc --dry-run\n```\n');
    execFileSync('git', ['-C', root, 'add', '.']);
    const result = check();
    assert.equal(result.status, 1);
    assert.match(result.stderr, /\.claude\/skills\/demo\/SKILL\.md:4 runs hq core worktree-gc, which has no minCli in TWINS/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('--apply rewrites tracked callers, --check passes after it, out-of-scope files stay', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'rewrite-core-callers-'));
  try {
    const put = (file, text) => {
      fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
      fs.writeFileSync(path.join(root, file), text);
    };
    put('.claude/skills/demo/SKILL.md', 'Run:\n\n```bash\nbash core/scripts/rebuild-threads-index.sh\n```\n');
    put('core/scripts/tests/demo.test.sh', 'bash core/scripts/rebuild-threads-index.sh\n');
    put('core/knowledge/public/demo.md', 'bash core/scripts/rebuild-threads-index.sh\n');
    put('.claude/hooks/demo.sh', 'bash core/scripts/rebuild-threads-index.sh\n');
    execFileSync('git', ['-C', root, 'init', '-q']);
    execFileSync('git', ['-C', root, 'add', '.']);
    const check = (mode) => spawnSync(process.execPath, [SCRIPT, mode, '--root', root], { encoding: 'utf8' });
    assert.equal(check('--check').status, 1);
    assert.equal(check('--apply').status, 0);
    assert.equal(check('--check').status, 0);
    assert.equal(fs.readFileSync(path.join(root, '.claude/skills/demo/SKILL.md'), 'utf8'), 'Run:\n\n```bash\nhq core rebuild-index threads\n```\n');
    for (const file of ['core/scripts/tests/demo.test.sh', 'core/knowledge/public/demo.md', '.claude/hooks/demo.sh']) {
      assert.equal(fs.readFileSync(path.join(root, file), 'utf8'), 'bash core/scripts/rebuild-threads-index.sh\n', file);
    }
    const listed = check('--list').stdout.trim().split('\n').map((row) => row.split('\t'));
    assert.deepEqual(listed.map((row) => [row[0], row[5]]), [['.claude/hooks/demo.sh', 'held']]);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

// Review of #2012: hq-cli main's twins reject these helper modes (hq 5.345.223:
// `hq core register-project --board a b` prints its usage and exits 1;
// `hq core delegate send --reconcile x` exits 1 with "unknown argument").
// Calls that use them stay on the helper; other calls of the same helper move.
test('helper modes the twin lacks stay on the helper', () => {
  for (const [line, helper] of [
    ['  bash core/scripts/register-project.sh --board {co} {board-project-id}', 'register-project.sh'],
    ['bash core/scripts/hq-delegate-send.sh --manifest <manifest> --reconcile <eventId>', 'hq-delegate-send.sh'],
  ]) {
    const result = rewriteLine(line, { file: '.claude/skills/demo/SKILL.md' });
    assert.equal(result.line, line);
    assert.deepEqual(result.hits.map((hit) => [hit.helper, hit.action]), [[helper, 'held']]);
  }
  assert.equal(
    rewriteLine('bash core/scripts/register-project.sh {co} {project}').line,
    'hq core register-project {co} {project}',
  );
  assert.equal(
    rewriteLine('bash core/scripts/hq-delegate-send.sh --manifest <manifest> --send').line,
    'hq core delegate send --manifest <manifest> --send',
  );
  // A word that only starts with the flag does not hold the call.
  assert.equal(
    rewriteLine('bash core/scripts/register-project.sh acme --boardroom').line,
    'hq core register-project acme --boardroom',
  );
});

test('a skill call with a variable operand stays on the helper', () => {
  const file = '.claude/skills/demo/SKILL.md';
  for (const line of [
    'lock_json="$(bash core/scripts/resume-thread-lock.sh inspect "$thread_id")"',
    '    if bash core/scripts/resume-thread-lock.sh acquire "$thread_id" --session-id "$session_id"; then',
    'bash core/scripts/jobs-schedule-parse.sh --tz "$TZ_IANA" "$SCHEDULE_TEXT"',
  ]) {
    const result = rewriteLine(line, { file });
    assert.equal(result.line, line);
    assert.equal(result.hits[0].action, 'held');
  }
  // Placeholders are not variables, and scripts do not pass the Bash tool guard.
  assert.equal(
    rewriteLine('bash core/scripts/resume-thread-lock.sh inspect "{thread_id}"', { file }).line,
    'hq core resume-thread-lock inspect "{thread_id}"',
  );
  assert.equal(
    rewriteLine('out="$(bash "$ROOT/core/scripts/knowledge-prefs.sh" get "$co" x)"', { file: 'core/scripts/demo.sh', shell: true }).line,
    'out="$(hq core --hq-root "$ROOT" knowledge-prefs get "$co" x)"',
  );
  // The allowed-tools entries of a helper held this way stay too.
  const { text } = scanFile([
    'allowed-tools: Bash(bash core/scripts/resume-thread-lock.sh:*), Bash(lock_json="$(bash core/scripts/resume-thread-lock.sh:*), Bash(if bash core/scripts/resume-thread-lock.sh:*)',
    'lock_json="$(bash core/scripts/resume-thread-lock.sh inspect "$thread_id")"',
  ].join('\n'), file);
  assert.equal(
    text.split('\n')[0],
    'allowed-tools: Bash(bash core/scripts/resume-thread-lock.sh:*), Bash(lock_json="$(bash core/scripts/resume-thread-lock.sh:*), Bash(if bash core/scripts/resume-thread-lock.sh:*)',
  );
});

test('a marked shell fallback stays on the helper', () => {
  const file = 'core/scripts/demo.sh';
  const fallback = '    bash "$ROOT/core/scripts/work-mesh-live-bind-trusted.sh" "$@"  # hq-core-fallback';
  const held = rewriteLine(fallback, { file, shell: true });
  assert.equal(held.line, fallback);
  assert.equal(held.hits[0].action, 'held');
  // Without the mark the same call moves.
  assert.equal(
    rewriteLine('    bash "$ROOT/core/scripts/work-mesh-live-bind-trusted.sh" "$@"', { file, shell: true }).line,
    '    hq core --hq-root "$ROOT" work-mesh-bind-trusted "$@"',
  );
});

test('a file with a held helper-mode call keeps the helper permission', () => {
  const file = '.claude/skills/demo/SKILL.md';
  const text = [
    'allowed-tools: Bash(hq core register-project:*), Bash(bash core/scripts/register-project.sh:*), Bash(bash core/scripts/hq-delegate-send.sh:*)',
    '  bash core/scripts/register-project.sh --board {co} {id}',
    'bash core/scripts/register-project.sh {co} {name}',
    'bash core/scripts/hq-delegate-send.sh --manifest <m> --send',
  ].join('\n');
  const { text: out, rows } = scanFile(text, file);
  const lines = out.split('\n');
  // register-project has a held --board call here, so its permission stays;
  // hq-delegate-send has no held call, so its permission moves.
  assert.equal(
    lines[0],
    'allowed-tools: Bash(hq core register-project:*), Bash(bash core/scripts/register-project.sh:*), Bash(hq core delegate send:*)',
  );
  assert.equal(lines[1], '  bash core/scripts/register-project.sh --board {co} {id}');
  assert.equal(lines[2], 'hq core register-project {co} {name}');
  assert.equal(lines[3], 'hq core delegate send --manifest <m> --send');
  assert.deepEqual(
    rows.filter((row) => row.action === 'held').map((row) => [row.line, row.helper]),
    [[1, 'register-project.sh'], [2, 'register-project.sh']],
  );
  // Outside a file with a held call the permission still moves.
  assert.equal(
    rewriteLine('allowed-tools: Bash(bash core/scripts/register-project.sh:*)', { file }).line,
    'allowed-tools: Bash(hq core register-project:*)',
  );
});
