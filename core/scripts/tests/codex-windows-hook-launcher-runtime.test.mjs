// codex-windows-hook-launcher-runtime.test.mjs - runtime regression test for
// feedback_d0c2f082 (Codex hooks on Windows through the Git Bash launcher).
//
// Runs on Windows only (wired into the codex-windows-hook-launcher job in
// .github/workflows/pr-checks.yml). It starts every commandWindows string from
// .codex/config.toml the way Codex does (codex-rs hooks/src/engine/
// command_runner.rs: `%COMSPEC% /C "<command>"` as one raw argument, the hook
// JSON on stdin, the session folder as the working directory), against a fake
// HQ root that holds the real launcher and a stub adapter. The stub writes its
// stdin to a file and exits with HQ_STUB_RC (default 2).
//
// It asserts that the hook JSON reaches bash byte-identical, that exit 2 (a
// PreToolUse deny) comes back as process exit code 2 with HQ_ROOT set and
// unset, that a missing bash or a missing launcher denies PreToolUse with exit
// 2 and is never a silent exit 0 for other events, that the git top-level
// lookup finds HQ from a subfolder, and that a folder name with ")" and a space
// does not break the command. Section 8 invokes each command the way a live
// Codex session did on Beaker (cmd.exe /d /s /c "<command>"), with HQ_ROOT set
// and unset, and requires stdout to be empty or exactly the hook JSON: no
// cmd prompt line and no literal %VAR%.
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

if (process.platform !== 'win32') {
  console.error('FAIL: this test runs the cmd.exe launcher and must run on Windows');
  process.exit(1);
}

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const CONFIG = path.join(ROOT, '.codex', 'config.toml');
const LAUNCHER = path.join(ROOT, '.codex', 'hooks', 'hq-codex-hook.cmd');

let pass = 0;
let fail = 0;
const ok = (name) => { pass += 1; console.log(`ok   [${name}]`); };
const bad = (name, detail) => { fail += 1; console.log(`FAIL [${name}]: ${detail}`); };
const check = (name, cond, detail) => (cond ? ok(name) : bad(name, detail));

// Parse the commandWindows literal of each [[hooks.<Event>.hooks]] entry.
function readCommandWindows(file) {
  const out = [];
  let event = null;
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    const header = line.match(/^\[\[hooks\.([A-Za-z]+)\.hooks\]\]\s*$/);
    if (header) { event = header[1]; continue; }
    if (/^\[/.test(line)) { event = null; continue; }
    const cmd = line.match(/^commandWindows = '(.*)'\s*$/);
    if (cmd && event) out.push({ event, command: cmd[1] });
  }
  return out;
}

const hooks = readCommandWindows(CONFIG);
const byEvent = new Map(hooks.map((h) => [h.event, h.command]));
check('config defines commandWindows for 8 events', hooks.length === 8,
  `found ${hooks.length}: ${hooks.map((h) => h.event).join(',')}`);
const preToolUse = byEvent.get('PreToolUse');
if (!preToolUse) {
  bad('PreToolUse commandWindows', 'missing');
  console.log(`\npassed=${pass} failed=${fail}`);
  process.exit(1);
}

// Fixture layout. Every folder name carries a space and a ")".
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'hq hook (run) '));
const HQ = path.join(TMP, 'Projects (old)', 'hq');
const HQ_SUB = path.join(HQ, 'companies', 'acme (x)');
const ELSEWHERE = path.join(TMP, 'elsewhere (no hq)');
const EMPTY = path.join(TMP, 'no tools (here)');
const OUT = path.join(TMP, 'stub-stdin.bin');
for (const dir of [path.join(HQ, '.codex', 'hooks'), HQ_SUB, ELSEWHERE, EMPTY]) {
  fs.mkdirSync(dir, { recursive: true });
}
fs.copyFileSync(LAUNCHER, path.join(HQ, '.codex', 'hooks', 'hq-codex-hook.cmd'));
fs.writeFileSync(path.join(HQ, '.codex', 'hooks', 'hq-codex-hook-adapter.sh'),
  '#!/usr/bin/env bash\ncat > "$HQ_STUB_OUT"\nif [ -n "${HQ_STUB_STDOUT+x}" ]; then printf \'%s\' "$HQ_STUB_STDOUT"; fi\nexit "${HQ_STUB_RC:-2}"\n');
const git = spawnSync('git', ['init', '-q', HQ], { encoding: 'utf8' });
check('fixture HQ root is a git repo', git.status === 0, git.stderr);

// Hook JSON with bytes that cmd.exe or a codepage conversion would change.
const fixture = Buffer.from(JSON.stringify({
  session_id: 'sess-1',
  hook_event_name: 'PreToolUse',
  cwd: HQ,
  tool_name: 'Bash',
  tool_input: { command: 'git push origin main & echo %CD% ^ ) ( ! "q" \u00e9 \u65e5\u672c \u2713' },
}) + '\n', 'utf8');

const COMSPEC = process.env.ComSpec || process.env.COMSPEC || 'C:\\Windows\\System32\\cmd.exe';
const SYSTEM_ROOT = process.env.SystemRoot || 'C:\\Windows';
const GIT_BASH = path.join(process.env.ProgramFiles || 'C:\\Program Files', 'Git', 'bin', 'bash.exe');

function baseEnv(overrides = {}) {
  const env = { ...process.env, HQ_STUB_OUT: OUT.replace(/\\/g, '/') };
  for (const key of Object.keys(env)) {
    if (/^(HQ_ROOT|HQ_BASH_EXE|HQ_HOOK_RAN)$/i.test(key)) delete env[key];
  }
  for (const [key, value] of Object.entries(overrides)) {
    for (const k of Object.keys(env)) if (k.toLowerCase() === key.toLowerCase()) delete env[k];
    if (value !== undefined) env[key] = value;
  }
  return env;
}

// No Git for Windows anywhere: PATH holds only System32, and every folder the
// launcher searches points at an empty folder.
function noBashEnv(overrides = {}) {
  return baseEnv({
    PATH: path.join(SYSTEM_ROOT, 'System32'),
    ProgramFiles: EMPTY,
    ProgramW6432: EMPTY,
    LOCALAPPDATA: EMPTY,
    ...overrides,
  });
}

function runHook(command, { cwd, env, input = fixture, codex = false }) {
  fs.rmSync(OUT, { force: true });
  // codex=true matches the Beaker failure mode: cmd.exe /d /s /c "<command>".
  const args = codex ? ['/d', '/s', '/c', `"${command}"`] : ['/C', `"${command}"`];
  const r = spawnSync(COMSPEC, args, {
    cwd, env, input, windowsVerbatimArguments: true, timeout: 60000,
  });
  const got = fs.existsSync(OUT) ? fs.readFileSync(OUT) : null;
  return { status: r.status, stderr: String(r.stderr || ''), stdout: String(r.stdout || ''), got, error: r.error };
}

// Codex reads hook stdout as JSON. A cmd prompt line or an unexpanded %VAR%
// corrupts it. Empty stdout (stub wrote nothing) or exactly one JSON value
// are the only legal shapes.
function stdoutIsHookJson(stdout) {
  const trimmed = stdout.trim();
  if (trimmed === '') return true;
  try {
    JSON.parse(trimmed);
    return true;
  } catch {
    return false;
  }
}

function stdoutPolluted(stdout) {
  const prompt = /(?:^|[\r\n])[A-Za-z]:\\[^\r\n]*>/.test(stdout)
    || />\s*(?:if |set |for |echo |call )/i.test(stdout);
  const literal = /%[A-Za-z_][A-Za-z0-9_]*%/.test(stdout);
  return prompt || literal || !stdoutIsHookJson(stdout);
}

function describe(r) {
  return `status=${r.status} error=${r.error ? r.error.message : ''} stdout=${JSON.stringify(r.stdout)} stderr=${JSON.stringify(r.stderr)}`;
}

console.log('== 1. Every event: HQ_ROOT set, bytes reach bash unchanged, exit 2 comes back ==');
for (const { event, command } of hooks) {
  const r = runHook(command, { cwd: ELSEWHERE, env: baseEnv({ HQ_ROOT: HQ }) });
  check(`${event} HQ_ROOT exit 2`, r.status === 2, describe(r));
  check(`${event} HQ_ROOT stdin bytes`, r.got !== null && r.got.equals(fixture),
    r.got === null ? `stub did not run; ${describe(r)}` : `got ${r.got.length} bytes, want ${fixture.length}`);
}

console.log('== 2. PreToolUse exit codes with HQ_ROOT set and unset ==');
for (const rc of ['2', '0', '1']) {
  const set = runHook(preToolUse, { cwd: ELSEWHERE, env: baseEnv({ HQ_ROOT: HQ, HQ_STUB_RC: rc }) });
  check(`HQ_ROOT set, adapter exit ${rc}`, String(set.status) === rc, describe(set));
  const unset = runHook(preToolUse, { cwd: HQ, env: baseEnv({ HQ_STUB_RC: rc }) });
  check(`HQ_ROOT unset (current folder), adapter exit ${rc}`, String(unset.status) === rc, describe(unset));
}
{
  const r = runHook(preToolUse, { cwd: HQ, env: baseEnv() });
  check('current folder with ")" and a space: stdin bytes', r.got !== null && r.got.equals(fixture), describe(r));
}

console.log('== 3. Git top-level lookup from a subfolder, HQ_ROOT unset ==');
{
  const r = runHook(preToolUse, { cwd: HQ_SUB, env: baseEnv() });
  check('subfolder exit 2', r.status === 2, describe(r));
  check('subfolder stdin bytes', r.got !== null && r.got.equals(fixture), describe(r));
}

console.log('== 4. Working folder with ")" and a space while HQ_ROOT points elsewhere ==');
{
  const r = runHook(preToolUse, { cwd: HQ_SUB, env: baseEnv({ HQ_ROOT: HQ }) });
  check('")" folder with HQ_ROOT exit 2', r.status === 2, describe(r));
  check('")" folder with HQ_ROOT stdin bytes', r.got !== null && r.got.equals(fixture), describe(r));
}

console.log('== 5. Missing launcher fails closed ==');
{
  const r = runHook(preToolUse, { cwd: ELSEWHERE, env: baseEnv() });
  check('missing launcher: PreToolUse exit 2', r.status === 2, describe(r));
  check('missing launcher: PreToolUse reason on stderr', /launcher not found/i.test(r.stderr), describe(r));
  const r2 = runHook(preToolUse, { cwd: ELSEWHERE, env: baseEnv({ HQ_ROOT: path.join(TMP, 'gone (x)') }) });
  check('missing launcher, stale HQ_ROOT: PreToolUse exit 2', r2.status === 2, describe(r2));
  for (const event of ['SessionStart', 'PostToolUse', 'Stop']) {
    const o = runHook(byEvent.get(event), { cwd: ELSEWHERE, env: baseEnv() });
    check(`missing launcher: ${event} is not a silent exit 0`,
      o.status !== 0 && o.status !== 2 && /launcher not found/i.test(o.stderr), describe(o));
  }
}

console.log('== 6. Missing bash fails closed ==');
{
  const r = runHook(preToolUse, { cwd: ELSEWHERE, env: noBashEnv({ HQ_ROOT: HQ }) });
  check('missing bash: PreToolUse exit 2', r.status === 2, describe(r));
  check('missing bash: PreToolUse reason on stderr', /Git Bash not found/i.test(r.stderr), describe(r));
  check('missing bash: adapter did not run', r.got === null, describe(r));
  const o = runHook(byEvent.get('PostToolUse'), { cwd: ELSEWHERE, env: noBashEnv({ HQ_ROOT: HQ }) });
  check('missing bash: PostToolUse is not a silent exit 0',
    o.status !== 0 && o.status !== 2 && /Git Bash not found/i.test(o.stderr), describe(o));
}

console.log('== 7. HQ_BASH_EXE override ==');
{
  const r = runHook(preToolUse, { cwd: ELSEWHERE, env: noBashEnv({ HQ_ROOT: HQ, HQ_BASH_EXE: GIT_BASH }) });
  check('HQ_BASH_EXE to Git Bash: exit 2', r.status === 2, describe(r));
  check('HQ_BASH_EXE to Git Bash: stdin bytes', r.got !== null && r.got.equals(fixture), describe(r));
  const wsl = path.join(SYSTEM_ROOT, 'System32', 'cmd.exe');
  const w = runHook(preToolUse, { cwd: ELSEWHERE, env: baseEnv({ HQ_ROOT: HQ, HQ_BASH_EXE: wsl }) });
  check('HQ_BASH_EXE under SystemRoot is ignored: Git Bash still runs the adapter',
    w.status === 2 && w.got !== null && w.got.equals(fixture), describe(w));
  check('HQ_BASH_EXE under SystemRoot: warning on stderr', /HQ_BASH_EXE/.test(w.stderr), describe(w));
  const w2 = runHook(preToolUse, { cwd: ELSEWHERE, env: noBashEnv({ HQ_ROOT: HQ, HQ_BASH_EXE: wsl }) });
  check('HQ_BASH_EXE under SystemRoot and no Git Bash: PreToolUse exit 2', w2.status === 2 && w2.got === null, describe(w2));
}

console.log('== 8. cmd.exe /d /s /c stdout is empty or hook JSON (no prompt, no %VAR%) ==');
{
  const minimal = Buffer.from('{"hook_event_name":"SessionStart","session_id":"s"}\n', 'utf8');
  const jsonOut = '{"ok":true}';
  for (const { event, command } of hooks) {
    const payload = Buffer.from(`{"hook_event_name":"${event}","session_id":"s"}\n`, 'utf8');
    const set = runHook(command, {
      cwd: ELSEWHERE, input: payload, codex: true, env: baseEnv({ HQ_ROOT: HQ, HQ_STUB_RC: '0' }),
    });
    check(`${event} /d /s /c HQ_ROOT set: stdout quiet`,
      set.status === 0 && set.stdout === '' && !stdoutPolluted(set.stdout), describe(set));
    const unset = runHook(command, {
      cwd: HQ, input: payload, codex: true, env: baseEnv({ HQ_STUB_RC: '0' }),
    });
    check(`${event} /d /s /c HQ_ROOT unset: stdout quiet`,
      unset.status === 0 && unset.stdout === '' && !stdoutPolluted(unset.stdout), describe(unset));
    const passed = runHook(command, {
      cwd: HQ, input: minimal, codex: true,
      env: baseEnv({ HQ_STUB_RC: '0', HQ_STUB_STDOUT: jsonOut }),
    });
    check(`${event} /d /s /c JSON stdout is only the hook JSON`,
      passed.status === 0 && passed.stdout === jsonOut && !stdoutPolluted(passed.stdout), describe(passed));
  }
}

fs.rmSync(TMP, { recursive: true, force: true });
console.log(`\npassed=${pass} failed=${fail}`);
process.exit(fail === 0 ? 0 : 1);
