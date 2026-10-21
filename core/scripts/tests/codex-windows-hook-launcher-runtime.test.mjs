// codex-windows-hook-launcher-runtime.test.mjs - runtime regression test for
// feedback_d0c2f082 (Codex hooks on Windows through the Git Bash launcher).
//
// Runs on Windows only (wired into the codex-windows-hook-launcher job in
// .github/workflows/pr-checks.yml). It starts every commandWindows string from
// .codex/config.toml in each way Codex can start a hook on Windows (codex-rs
// hooks/src/engine/command_runner.rs):
//   - pwsh       `pwsh.exe -NoProfile -Command <command>` (PowerShell 7, the
//                 session shell on a default Windows install)
//   - powershell `powershell.exe -NoProfile -Command <command>` (Windows
//                 PowerShell 5.1)
//   - cmd        `%COMSPEC% /C "<command>"` as one raw argument (cmd session
//                 shell, or no shell)
//   - cmd /d /s /c "<command>" for the stdout checks in section 8
// with the hook JSON on stdin and the session folder as the working directory,
// against a fake HQ root that holds the real launcher and a stub adapter. The
// stub writes its stdin to a file, optionally prints a file or a string, and
// exits with HQ_STUB_RC (default 2).
//
// It asserts, for every shell: the hook JSON reaches bash byte-identical; exit
// 2 (a deny) comes back as process exit code 2 with HQ_ROOT set and unset;
// PreToolUse fails closed (an adapter exit 1 or 3, a missing launcher, a
// missing bash, or a shell that cannot start cmd.exe all deny with 2) while the
// other events report errors as 1 and never as a silent 0; the git top-level
// lookup finds HQ from a subfolder; a folder name with ")" and a space does
// not break the command; and stdout is empty or exactly the adapter's bytes,
// with no cmd prompt line and no literal %VAR%.
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

// Parse the commandWindows value of each [[hooks.<Event>.hooks]] entry. The
// value is a one-line TOML literal string, multiline form ('''...''') or
// plain ('...').
function readCommandWindows(file) {
  const out = [];
  let event = null;
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    const header = line.match(/^\[\[hooks\.([A-Za-z]+)\.hooks\]\]\s*$/);
    if (header) { event = header[1]; continue; }
    if (/^\[/.test(line)) { event = null; continue; }
    const cmd = line.match(/^commandWindows = '''(.*)'''\s*$/) || line.match(/^commandWindows = '([^']*)'\s*$/);
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
const STDOUT_FILE = path.join(TMP, 'stub-stdout.bin');
for (const dir of [path.join(HQ, '.codex', 'hooks'), HQ_SUB, ELSEWHERE, EMPTY]) {
  fs.mkdirSync(dir, { recursive: true });
}
fs.copyFileSync(LAUNCHER, path.join(HQ, '.codex', 'hooks', 'hq-codex-hook.cmd'));
fs.writeFileSync(path.join(HQ, '.codex', 'hooks', 'hq-codex-hook-adapter.sh'), [
  '#!/usr/bin/env bash',
  'cat > "$HQ_STUB_OUT"',
  'if [ -n "${HQ_STUB_STDOUT_FILE:-}" ]; then cat "$HQ_STUB_STDOUT_FILE"; fi',
  'if [ -n "${HQ_STUB_STDOUT+x}" ]; then printf \'%s\' "$HQ_STUB_STDOUT"; fi',
  'exit "${HQ_STUB_RC:-2}"',
  '',
].join('\n'));
const git = spawnSync('git', ['init', '-q', HQ], { encoding: 'utf8' });
check('fixture HQ root is a git repo', git.status === 0, git.stderr);

// Hook JSON with bytes that cmd.exe, PowerShell or a codepage conversion would
// change.
const fixture = Buffer.from(JSON.stringify({
  session_id: 'sess-1',
  hook_event_name: 'PreToolUse',
  cwd: HQ,
  tool_name: 'Bash',
  tool_input: { command: 'git push origin main & echo %CD% ^ ) ( ! "q" \' $x `t \u00e9 \u65e5\u672c \u2713' },
}) + '\n', 'utf8');
// Adapter stdout with non-ASCII text, which PowerShell must not re-encode.
const adapterJson = Buffer.from(JSON.stringify({
  decision: 'block',
  reason: 'blocked: caf\u00e9 \u65e5\u672c \u2713 $HOME %PATH% ^&',
}) + '\n', 'utf8');
fs.writeFileSync(STDOUT_FILE, adapterJson);

const COMSPEC = process.env.ComSpec || process.env.COMSPEC || 'C:\\Windows\\System32\\cmd.exe';
const SYSTEM_ROOT = process.env.SystemRoot || 'C:\\Windows';
const GIT_BASH = path.join(process.env.ProgramFiles || 'C:\\Program Files', 'Git', 'bin', 'bash.exe');

function findOnPath(exe) {
  const r = spawnSync('where.exe', [exe], { encoding: 'utf8' });
  return r.status === 0 ? r.stdout.split(/\r?\n/).find(Boolean) : null;
}
const PWSH = findOnPath('pwsh.exe');
const WINPS = path.join(SYSTEM_ROOT, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
check('pwsh.exe is installed', Boolean(PWSH), 'pwsh.exe not on PATH');
check('powershell.exe is installed', fs.existsSync(WINPS), WINPS);
const SHELLS = ['pwsh', 'powershell', 'cmd'];

function baseEnv(overrides = {}) {
  const env = { ...process.env, HQ_STUB_OUT: OUT.replace(/\\/g, '/') };
  for (const key of Object.keys(env)) {
    if (/^(HQ_ROOT|HQ_BASH_EXE|HQ_HOOK_RAN|HQ_HOOK_DENY|HQ_HOOK_ERR|HQ_STUB_.*)$/i.test(key) && key !== 'HQ_STUB_OUT') delete env[key];
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

// shell: 'pwsh' | 'powershell' | 'cmd' (cmd.exe /C "<command>") |
// 'cmd-dsc' (cmd.exe /d /s /c "<command>").
function runHook(command, { cwd, env, input = fixture, shell = 'cmd' }) {
  fs.rmSync(OUT, { force: true });
  let exe;
  let args;
  let verbatim = false;
  if (shell === 'pwsh' || shell === 'powershell') {
    // Codex passes the command as one argument with the standard Windows
    // quoting, which is what Node uses without windowsVerbatimArguments.
    exe = shell === 'pwsh' ? PWSH : WINPS;
    args = ['-NoProfile', '-Command', command];
  } else {
    exe = COMSPEC;
    args = shell === 'cmd-dsc' ? ['/d', '/s', '/c', `"${command}"`] : ['/C', `"${command}"`];
    verbatim = true;
  }
  const r = spawnSync(exe, args, {
    cwd, env, input, windowsVerbatimArguments: verbatim, timeout: 120000,
  });
  const got = fs.existsSync(OUT) ? fs.readFileSync(OUT) : null;
  const stdoutBytes = r.stdout || Buffer.alloc(0);
  return {
    status: r.status, stderr: String(r.stderr || ''), stdout: stdoutBytes.toString('utf8'), stdoutBytes, got, error: r.error,
  };
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
  return `status=${r.status} error=${r.error ? r.error.message : ''} stdout=${JSON.stringify(r.stdout)} stderr=${JSON.stringify(r.stderr.slice(-1500))}`;
}

const stdinOk = (r) => r.got !== null && r.got.equals(fixture);
const stdinDetail = (r) => (r.got === null ? `stub did not run; ${describe(r)}` : `got ${r.got.length} bytes, want ${fixture.length}; ${describe(r)}`);

for (const shell of SHELLS) {
  if (shell === 'pwsh' && !PWSH) continue;
  const S = `${shell}:`;
  console.log(`\n######## shell: ${shell} ########`);

  console.log('== 1. Every event: HQ_ROOT set, bytes reach bash unchanged, exit 2 comes back ==');
  for (const { event, command } of hooks) {
    const r = runHook(command, { cwd: ELSEWHERE, env: baseEnv({ HQ_ROOT: HQ }), shell });
    check(`${S} ${event} HQ_ROOT exit 2`, r.status === 2, describe(r));
    check(`${S} ${event} HQ_ROOT stdin bytes`, stdinOk(r), stdinDetail(r));
  }

  console.log('== 2. Exit codes with HQ_ROOT set and unset ==');
  // PreToolUse is the guard: only an adapter exit 0 allows. Exit 1 (adapter
  // or launcher error) and exit 3+ deny with 2. Other events are advisory:
  // 0 and 2 pass through, any other error is reported as 1.
  for (const [rc, wantGuard, wantOther] of [['0', 0, 0], ['2', 2, 2], ['1', 2, 1], ['3', 2, 1]]) {
    const set = runHook(preToolUse, { cwd: ELSEWHERE, env: baseEnv({ HQ_ROOT: HQ, HQ_STUB_RC: rc }), shell });
    check(`${S} PreToolUse HQ_ROOT set, adapter exit ${rc} -> ${wantGuard}`, set.status === wantGuard, describe(set));
    const unset = runHook(preToolUse, { cwd: HQ, env: baseEnv({ HQ_STUB_RC: rc }), shell });
    check(`${S} PreToolUse HQ_ROOT unset (current folder), adapter exit ${rc} -> ${wantGuard}`, unset.status === wantGuard, describe(unset));
    const other = runHook(byEvent.get('PostToolUse'), { cwd: HQ, env: baseEnv({ HQ_STUB_RC: rc }), shell });
    check(`${S} PostToolUse adapter exit ${rc} -> ${wantOther}`, other.status === wantOther, describe(other));
  }
  {
    const r = runHook(preToolUse, { cwd: HQ, env: baseEnv(), shell });
    check(`${S} current folder with ")" and a space: stdin bytes`, stdinOk(r), stdinDetail(r));
  }

  console.log('== 3. Git top-level lookup from a subfolder, HQ_ROOT unset ==');
  {
    const r = runHook(preToolUse, { cwd: HQ_SUB, env: baseEnv(), shell });
    check(`${S} subfolder exit 2`, r.status === 2, describe(r));
    check(`${S} subfolder stdin bytes`, stdinOk(r), stdinDetail(r));
  }

  console.log('== 4. Working folder with ")" and a space while HQ_ROOT points elsewhere ==');
  {
    const r = runHook(preToolUse, { cwd: HQ_SUB, env: baseEnv({ HQ_ROOT: HQ }), shell });
    check(`${S} ")" folder with HQ_ROOT exit 2`, r.status === 2, describe(r));
    check(`${S} ")" folder with HQ_ROOT stdin bytes`, stdinOk(r), stdinDetail(r));
  }

  console.log('== 5. Missing launcher fails closed ==');
  {
    const r = runHook(preToolUse, { cwd: ELSEWHERE, env: baseEnv(), shell });
    check(`${S} missing launcher: PreToolUse exit 2`, r.status === 2, describe(r));
    check(`${S} missing launcher: PreToolUse reason on stderr`, /launcher not found/i.test(r.stderr), describe(r));
    const r2 = runHook(preToolUse, { cwd: ELSEWHERE, env: baseEnv({ HQ_ROOT: path.join(TMP, 'gone (x)') }), shell });
    check(`${S} missing launcher, stale HQ_ROOT: PreToolUse exit 2`, r2.status === 2, describe(r2));
    for (const event of ['SessionStart', 'PostToolUse', 'Stop']) {
      const o = runHook(byEvent.get(event), { cwd: ELSEWHERE, env: baseEnv(), shell });
      check(`${S} missing launcher: ${event} exits 1 with a warning`,
        o.status === 1 && /launcher not found/i.test(o.stderr), describe(o));
    }
  }

  console.log('== 6. Missing bash fails closed ==');
  {
    const r = runHook(preToolUse, { cwd: ELSEWHERE, env: noBashEnv({ HQ_ROOT: HQ }), shell });
    check(`${S} missing bash: PreToolUse exit 2`, r.status === 2, describe(r));
    check(`${S} missing bash: PreToolUse reason on stderr`, /Git Bash not found/i.test(r.stderr), describe(r));
    check(`${S} missing bash: adapter did not run`, r.got === null, describe(r));
    const o = runHook(byEvent.get('PostToolUse'), { cwd: ELSEWHERE, env: noBashEnv({ HQ_ROOT: HQ }), shell });
    check(`${S} missing bash: PostToolUse exits 1 with a warning`,
      o.status === 1 && /Git Bash not found/i.test(o.stderr), describe(o));
  }

  console.log('== 7. HQ_BASH_EXE override ==');
  {
    const r = runHook(preToolUse, { cwd: ELSEWHERE, env: noBashEnv({ HQ_ROOT: HQ, HQ_BASH_EXE: GIT_BASH }), shell });
    check(`${S} HQ_BASH_EXE to Git Bash: exit 2`, r.status === 2, describe(r));
    check(`${S} HQ_BASH_EXE to Git Bash: stdin bytes`, stdinOk(r), stdinDetail(r));
    const wsl = path.join(SYSTEM_ROOT, 'System32', 'cmd.exe');
    const w = runHook(preToolUse, { cwd: ELSEWHERE, env: baseEnv({ HQ_ROOT: HQ, HQ_BASH_EXE: wsl }), shell });
    check(`${S} HQ_BASH_EXE under SystemRoot is ignored: Git Bash still runs the adapter`,
      w.status === 2 && stdinOk(w), describe(w));
    check(`${S} HQ_BASH_EXE under SystemRoot: warning on stderr`, /HQ_BASH_EXE/.test(w.stderr), describe(w));
    const w2 = runHook(preToolUse, { cwd: ELSEWHERE, env: noBashEnv({ HQ_ROOT: HQ, HQ_BASH_EXE: wsl }), shell });
    check(`${S} HQ_BASH_EXE under SystemRoot and no Git Bash: PreToolUse exit 2`, w2.status === 2 && w2.got === null, describe(w2));
  }

  console.log('== 8. stdout is empty or exactly the adapter bytes (no prompt, no %VAR%) ==');
  {
    // cmd also runs as /d /s /c, the form a live Codex session used.
    const stdoutShell = shell === 'cmd' ? 'cmd-dsc' : shell;
    const minimal = Buffer.from('{"hook_event_name":"SessionStart","session_id":"s"}\n', 'utf8');
    const jsonOut = '{"ok":true}';
    for (const { event, command } of hooks) {
      const payload = Buffer.from(`{"hook_event_name":"${event}","session_id":"s"}\n`, 'utf8');
      const set = runHook(command, {
        cwd: ELSEWHERE, input: payload, shell: stdoutShell, env: baseEnv({ HQ_ROOT: HQ, HQ_STUB_RC: '0' }),
      });
      check(`${S} ${event} HQ_ROOT set: stdout quiet`,
        set.status === 0 && set.stdout === '' && !stdoutPolluted(set.stdout), describe(set));
      const unset = runHook(command, {
        cwd: HQ, input: payload, shell: stdoutShell, env: baseEnv({ HQ_STUB_RC: '0' }),
      });
      check(`${S} ${event} HQ_ROOT unset: stdout quiet`,
        unset.status === 0 && unset.stdout === '' && !stdoutPolluted(unset.stdout), describe(unset));
      const passed = runHook(command, {
        cwd: HQ, input: minimal, shell: stdoutShell,
        env: baseEnv({ HQ_STUB_RC: '0', HQ_STUB_STDOUT: jsonOut }),
      });
      check(`${S} ${event} JSON stdout is only the hook JSON`,
        passed.status === 0 && passed.stdout === jsonOut && !stdoutPolluted(passed.stdout), describe(passed));
    }
    // A deny reason with non-ASCII text reaches Codex byte for byte.
    const deny = runHook(preToolUse, {
      cwd: HQ, shell: stdoutShell, env: baseEnv({ HQ_STUB_RC: '2', HQ_STUB_STDOUT_FILE: STDOUT_FILE.replace(/\\/g, '/') }),
    });
    check(`${S} PreToolUse deny: exit 2 and stdout bytes unchanged`,
      deny.status === 2 && deny.stdoutBytes.equals(adapterJson),
      `want ${adapterJson.toString('hex')} got ${deny.stdoutBytes.toString('hex')}; ${describe(deny)}`);
  }

  if (shell === 'pwsh' || shell === 'powershell') {
    console.log('== 9. PowerShell cannot start cmd.exe ==');
    // PATH without System32: PowerShell cannot resolve `cmd`, so no batch
    // runs. PreToolUse must deny; other events report an error.
    const env = baseEnv({ HQ_ROOT: HQ, PATH: EMPTY });
    const r = runHook(preToolUse, { cwd: HQ, env, shell });
    check(`${S} cmd.exe not found: PreToolUse exit 2`, r.status === 2 && r.got === null, describe(r));
    const o = runHook(byEvent.get('PostToolUse'), { cwd: HQ, env, shell });
    check(`${S} cmd.exe not found: PostToolUse exit 1`, o.status === 1 && o.got === null, describe(o));
  }
}

fs.rmSync(TMP, { recursive: true, force: true });
console.log(`\npassed=${pass} failed=${fail}`);
process.exit(fail === 0 ? 0 : 1);
