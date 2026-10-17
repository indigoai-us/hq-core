// hq-core: public
import { realpathSync, mkdtempSync, mkdirSync, copyFileSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { isDeepStrictEqual } from 'node:util';

const here = dirname(fileURLToPath(import.meta.url));
const source = resolve(here, '../../../..');
const args = process.argv.slice(2);
if (args.length !== 2 || args[0] !== '--engine') {
  console.error('Usage: run-contract.sh --engine <cmd>');
  process.exit(2);
}
const engine = args[1];
const suite = JSON.parse(readFileSync(join(here, 'cases.json'), 'utf8'));
if (suite.schema_version !== 'hq-hook-contract.v1' || !suite.cases?.length) throw new Error('Invalid or empty contract suite');
const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";
const expand = (value, root) => {
  if (typeof value === 'string') return value.replaceAll('$FIXTURE', root);
  if (Array.isArray(value)) return value.map(item => expand(item, root));
  if (value && typeof value === 'object') {
    if ('$repeat' in value) return value.$repeat.repeat(value.count) + (value.suffix || '');
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, expand(item, root)]));
  }
  return value;
};
let failures = 0;
for (const test of suite.cases) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'hq-contract-')));
  try {
    const put = (path, content) => {
      const dest = join(root, path);
      mkdirSync(dirname(dest), { recursive: true });
      writeFileSync(dest, content);
    };
    for (const path of ['.claude/hooks/master-hook.sh', '.claude/hooks/hook-timeout-probe.sh',
      '.claude/hooks/hook-gate.sh', 'core/scripts/resolve-hq-root.sh', 'core/scripts/lib/hook-adapter-core.sh']) {
      mkdirSync(dirname(join(root, path)), { recursive: true });
      copyFileSync(join(source, path), join(root, path));
    }
    put('core/core.yaml', 'version: fixture\n');
    put('.claude/hooks/hook-registry.json', JSON.stringify({ hooks: {} }));
    mkdirSync(join(root, 'home'), { recursive: true });
    const shellPath = spawnSync('bash', ['-c', 'pwd -P'], {cwd: root, encoding: 'utf8', env: {...process.env, BASH_ENV: '/dev/null'}});
    if (shellPath.status !== 0) throw new Error('Bash unavailable');
    const shellRoot = shellPath.stdout.trim();
    const item = expand(test, shellRoot);
    const env = Object.fromEntries(['PATH', 'SystemRoot', 'WINDIR', 'COMSPEC', 'PATHEXT', 'TMP', 'TEMP']
      .filter(key => process.env[key]).map(key => [key, process.env[key]]));
    // Native jq receives MSYS-converted path arguments on Windows. Probe that
    // transport boundary independently; do not normalize the engine's output.
    const provenancePath = spawnSync('bash', ['-c', 'jq -nr --arg root "$PWD" \'$root\''], {
      cwd: root, encoding: 'utf8', env: {...env, HOME: shellRoot + '/home', BASH_ENV: '/dev/null'},
    });
    if (provenancePath.status !== 0) throw new Error('jq path probe failed');
    item.expected = expand(test.expected, provenancePath.stdout.trim());
    for (const [index, child] of item.children.entries()) {
      const text = typeof child.output === 'object' ? JSON.stringify(child.output) : (child.output || '');
      put(`core/hooks/${item.event}/${String(index).padStart(2, '0')}-child.sh`,
        '#!/usr/bin/env bash\ncat >/dev/null\n' +
        (child.sleep ? `sleep ${Number(child.sleep)}\n` : '') +
        `cat <<'HQ_CONTRACT_OUTPUT'\n${text}\nHQ_CONTRACT_OUTPUT\nexit ${child.exit || 0}\n`);
    }
    // An allowlist prevents local flags, credentials, profiles and state from
    // changing a golden result. The engine command is trusted developer input.
    Object.assign(env, { HOME: shellRoot + '/home', BASH_ENV: '/dev/null', HQ_ROOT: shellRoot,
      HQ_HOOK_TIMEOUT_SENTRY: '0', HQ_HOOK_DEDUPE: '0', HQ_FLAG_HQ_ANYWHERE_RUNTIME: 'false',
      HQ_MASTER_CHILD_TIMEOUT: String(item.childTimeout || 10), HQ_HARNESS: 'claude' });
    const result = spawnSync('bash', ['-c', `exec ${engine} ${quote(item.event)}`], {
      cwd: root, env, input: JSON.stringify({ session_id: 'synthetic-contract', cwd: shellRoot,
        hook_event_name: item.event, tool_name: 'Bash', tool_input: { command: 'true' } }),
      encoding: 'utf8', timeout: 30000, maxBuffer: 8 * 1024 * 1024,
    });
    let error = result.error ? result.error.code : '';
    if (result.status !== item.expected.exit) error ||= `exit ${result.status}; expected ${item.expected.exit}`;
    const prefix = item.expected.text || '';
    if (!result.stdout.startsWith(prefix)) error ||= 'plain-text prefix differs';
    const tail = result.stdout.slice(prefix.length);
    if ('json' in item.expected) {
      try {
        if (!isDeepStrictEqual(JSON.parse(tail), item.expected.json)) error ||= 'JSON differs';
      } catch { error ||= 'output is not one JSON object after plain text'; }
    } else if (tail !== '') error ||= 'unexpected trailing output';
    console.log(`${error ? 'FAIL' : 'PASS'} ${item.id}${error ? ': ' + error : ''}`);
    if (error) failures++;
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}
console.log(`${suite.cases.length} cases; ${failures} failures`);
process.exitCode = failures ? 1 : 0;
