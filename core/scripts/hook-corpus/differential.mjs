// hq-core: public
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, rmSync, copyFileSync, realpathSync } from 'node:fs';
import { dirname, resolve, join, isAbsolute } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';

const here = dirname(fileURLToPath(import.meta.url));
const source = resolve(here, '../../..');
const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";
export const payloadHash = payload => createHash('sha256').update(JSON.stringify(payload)).digest('hex');
const helpers = ['.claude/hooks/master-hook.sh', '.claude/hooks/hook-gate.sh',
  '.claude/hooks/hook-timeout-probe.sh', 'core/scripts/resolve-hq-root.sh',
  'core/scripts/lib/hook-adapter-core.sh', 'core/scripts/lib/trigger-fact-text.awk'];
function safePath(root, path) {
  if (isAbsolute(path) || path.includes('\\') || path.split('/').includes('..')) throw new Error('unsafe fixture path');
  return join(root, path);
}
function put(root, path, content) {
  const dest = safePath(root, path);
  mkdirSync(dirname(dest), { recursive: true });
  writeFileSync(dest, content);
}
export function runEngine(command, row, root) {
  rmSync(root, { recursive: true, force: true });
  mkdirSync(root, { recursive: true });
  for (const file of helpers) {
    mkdirSync(dirname(join(root, file)), { recursive: true });
    copyFileSync(join(source, file), join(root, file));
  }
  put(root, 'core/core.yaml', 'version: synthetic\n');
  put(root, '.claude/hooks/hook-registry.json', JSON.stringify(row.registry));
  for (const [path, content] of Object.entries(row.files)) put(root, path, content);
  for (const groups of Object.values(row.registry.hooks)) for (const group of groups) for (const hook of group.hooks) {
    // Only dispatcher selection is under test here. Real hook bodies could
    // send messages or mutate a user's state; deterministic sentinels cannot.
    const output = JSON.stringify({hookSpecificOutput: {additionalContext: 'synthetic:' + hook.id}});
    put(root, hook.script, '#!/usr/bin/env bash\ncat >/dev/null\nprintf "%s\\n" ' + quote(output) + '\n');
  }
  mkdirSync(join(root, 'home'), { recursive: true });
  const shellPath = spawnSync('bash', ['-c', 'pwd -P'], {cwd: root, encoding: 'utf8', env: {...process.env, BASH_ENV: '/dev/null'}});
  if (shellPath.status !== 0) throw new Error('Bash unavailable');
  const shellRoot = shellPath.stdout.trim();
  const env = Object.fromEntries(['PATH', 'SystemRoot', 'WINDIR', 'COMSPEC', 'PATHEXT', 'TMP', 'TEMP']
    .filter(key => process.env[key]).map(key => [key, process.env[key]]));
  Object.assign(env, row.env, { HOME: shellRoot + '/home', BASH_ENV: '/dev/null', HQ_ROOT: shellRoot,
    HQ_HOOK_TIMEOUT_SENTRY: '0', HQ_HOOK_DEDUPE: '0', HQ_FLAG_HQ_ANYWHERE_RUNTIME: 'false', HQ_HARNESS: 'claude' });
  const input = JSON.stringify(row.payload).replaceAll('$FIXTURE', shellRoot);
  const result = spawnSync('bash', ['-c', `exec ${command} ${quote(row.event)}`], {
    cwd: root, env, input, encoding: 'utf8', timeout: 30000, maxBuffer: 8 * 1024 * 1024,
  });
  return { exit: result.status, stdout: result.stdout || '', stderr: result.stderr || '',
    error: result.error?.code || result.signal || null };
}
export function compare(a, b) {
  return !a.error && !b.error && a.exit === b.exit && a.stdout === b.stdout && a.stderr === b.stderr;
}
export function selectedCorrectly(row, result) {
  if (result.error || result.exit !== 0) return false;
  if (!row.matching) return result.stdout === '';
  try {
    return JSON.parse(result.stdout).hookSpecificOutput?.additionalContext === 'synthetic:' + row.hook_id;
  } catch { return false; }
}
export function diagnostic(row, kind) {
  // Never include output, errors, input text, command text or environment values.
  return JSON.stringify({hook_id: row.hook_id, rule: row.rule, entry: row.entry,
    runtime: row.runtime, payload_hash: payloadHash(row.payload), mismatch: kind});
}
export function main(args) {
  const options = {};
  for (let i = 0; i < args.length; i += 2) {
    if (!['--engine-a','--engine-b','--corpus'].includes(args[i]) || !args[i + 1]) throw new Error('invalid arguments');
    options[args[i]] = args[i + 1];
  }
  if (!options['--engine-a'] || !options['--engine-b']) throw new Error('both engines required');
  const corpus = JSON.parse(readFileSync(options['--corpus'] || join(here, 'corpus.json'), 'utf8'));
  if (corpus.schema_version !== 'hq-hook-corpus.v1' || !corpus.cases?.length) throw new Error('invalid corpus');
  const tmp = realpathSync(mkdtempSync(join(tmpdir(), 'hq-differential-')));
  let mismatches = 0;
  try {
    for (const row of corpus.cases) {
      let kind = '';
      try {
        const a = runEngine(options['--engine-a'], row, join(tmp, 'hq'));
        const b = runEngine(options['--engine-b'], row, join(tmp, 'hq'));
        if (!compare(a, b)) kind = 'engine';
        else if (!selectedCorrectly(row, a) || !selectedCorrectly(row, b)) kind = 'selection';
      } catch { kind = 'fixture'; }
      if (kind) { console.log(diagnostic(row, kind)); mismatches++; }
    }
  } finally { rmSync(tmp, { recursive: true, force: true }); }
  console.log(JSON.stringify({cases: corpus.cases.length, mismatches}));
  return mismatches ? 1 : 0;
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { process.exitCode = main(process.argv.slice(2)); }
  catch { console.error('Differential runner failed: check arguments, dependencies and corpus schema (details redacted)'); process.exitCode = 2; }
}
