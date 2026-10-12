// Unit tests for core/scripts/lib/windows-cmd-spawn.mjs — Windows npm shims
// (.cmd/.bat) cannot be spawn()'d on Node 20+ without a shell (EINVAL), and a
// bare `claude` is ENOENT because CreateProcess does not apply PATHEXT.
//
// Run: node --test core/scripts/__tests__/windows-cmd-spawn.test.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { win32 } from 'node:path';
import {
  prepareWindowsCommand,
  resolveWindowsCommand,
  spawnCommand,
  spawnSyncCommand,
} from '../lib/windows-cmd-spawn.mjs';

const RUNNER = fileURLToPath(new URL('../workflow-runner.mjs', import.meta.url));
const SHIM = fileURLToPath(new URL('../lib/windows-command-shim.ps1', import.meta.url));

function windowsFixture(paths) {
  const files = new Set(paths.map((p) => p.toLowerCase()));
  return {
    platform: 'win32',
    pathApi: win32,
    existsSync: (p) => files.has(String(p).toLowerCase()),
  };
}

test('bare claude on PATH resolves to the npm .cmd shim', () => {
  const expected = 'C:\\Program Files (x86)\\nodejs\\claude.CMD';
  const resolved = resolveWindowsCommand('claude', {
    ...windowsFixture([expected]),
    env: {
      PATH: 'C:\\Windows\\system32;C:\\Program Files (x86)\\nodejs',
      PATHEXT: '.COM;.EXE;.BAT;.CMD',
    },
  });
  assert.equal(resolved, expected);
});

test('an absolute path without an extension picks the neighboring .cmd', () => {
  const base = 'C:\\Program Files (x86)\\nodejs\\claude';
  const expected = `${base}.CMD`;
  const resolved = resolveWindowsCommand(base, {
    ...windowsFixture([expected]),
    env: { PATH: '', PATHEXT: '.EXE;.CMD' },
  });
  assert.equal(resolved, expected);
});

test('a path that already has an extension is not rewritten', () => {
  const file = 'C:\\Program Files (x86)\\nodejs\\claude.cmd';
  assert.equal(
    resolveWindowsCommand(file, {
      ...windowsFixture([]),
      env: { PATH: 'C:\\nowhere', PATHEXT: '.CMD' },
    }),
    file,
  );
});

test('POSIX names stay extensionless and skip PATH probing', () => {
  assert.equal(
    resolveWindowsCommand('claude', {
      platform: 'linux',
      env: { PATH: '/usr/bin' },
      existsSync: () => true,
    }),
    'claude',
  );
});

test('Windows .cmd spawn goes through PowerShell with argv base64-encoded', () => {
  const untrusted = 'say hi & calc.exe';
  const file = 'C:\\Program Files (x86)\\nodejs\\claude.cmd';
  const prepared = prepareWindowsCommand(
    file,
    ['-p', untrusted, '--output-format', 'json'],
    { detached: true, cwd: 'C:\\hq', stdio: ['ignore', 3, 4] },
    {
      platform: 'win32',
      env: { SystemRoot: 'C:\\Windows' },
      shimScript: 'C:\\hq\\core\\scripts\\lib\\windows-command-shim.ps1',
    },
  );

  assert.equal(prepared.file, 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe');
  assert.equal(prepared.options.shell, false);
  assert.equal(prepared.options.windowsHide, true);
  assert.equal(prepared.options.detached, true);
  assert.equal(prepared.options.cwd, 'C:\\hq');
  assert.deepEqual(prepared.options.stdio, ['ignore', 3, 4]);
  assert.deepEqual(prepared.args.slice(0, 7), [
    '-NoLogo',
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    'C:\\hq\\core\\scripts\\lib\\windows-command-shim.ps1',
  ]);
  const encoded = [file, '-p', untrusted, '--output-format', 'json']
    .map((value) => Buffer.from(value, 'utf8').toString('base64'));
  assert.deepEqual(prepared.args.slice(7), encoded);
  assert.equal(JSON.stringify(prepared.args).includes(untrusted), false);
});

test('native Windows .exe and POSIX binaries still spawn directly', () => {
  for (const [platform, file] of [
    ['win32', 'C:\\Tools\\claude.exe'],
    ['linux', '/usr/local/bin/claude'],
  ]) {
    const prepared = prepareWindowsCommand(file, ['-p', 'hi'], { cwd: '/hq' }, { platform });
    assert.equal(prepared.file, file);
    assert.deepEqual(prepared.args, ['-p', 'hi']);
    assert.equal(prepared.options.cwd, '/hq');
    if (platform === 'win32') {
      assert.equal(prepared.options.shell, false);
      assert.equal(prepared.options.windowsHide, true);
    } else {
      assert.equal(prepared.options.shell, undefined);
      assert.equal(prepared.options.windowsHide, undefined);
    }
  }
});

test('spawnCommand and spawnSyncCommand pass the prepared argv to the impl', () => {
  const calls = [];
  const child = { pid: 42 };
  const returned = spawnCommand(
    'C:\\npm\\claude.cmd',
    ['-p', 'hi'],
    { detached: true },
    {
      platform: 'win32',
      env: { SystemRoot: 'C:\\Windows' },
      shimScript: 'C:\\shim.ps1',
      spawnImpl: (...args) => {
        calls.push(args);
        return child;
      },
    },
  );
  assert.equal(returned, child);
  assert.equal(calls.length, 1);
  assert.equal(calls[0][0].toLowerCase().endsWith('powershell.exe'), true);
  assert.equal(calls[0][2].shell, false);
  assert.equal(calls[0][2].detached, true);

  const syncCalls = [];
  spawnSyncCommand('C:\\npm\\claude.cmd', ['--version'], { timeout: 1500 }, {
    platform: 'win32',
    env: { SystemRoot: 'C:\\Windows' },
    shimScript: 'C:\\shim.ps1',
    spawnSyncImpl: (...args) => {
      syncCalls.push(args);
      return { status: 0, stdout: '1.0.0', stderr: '' };
    },
  });
  assert.equal(syncCalls.length, 1);
  assert.equal(syncCalls[0][2].timeout, 1500);
  assert.equal(syncCalls[0][2].shell, false);
});

test('workflow-runner uses spawnCommand for the engine child', () => {
  const src = fs.readFileSync(RUNNER, 'utf8');
  assert.match(src, /import \{ spawnCommand, spawnSyncCommand \} from '\.\/lib\/windows-cmd-spawn\.mjs'/);
  assert.match(src, /spawnCommand\(engine\.bin, argv,/);
  assert.doesNotMatch(src, /spawn\(engine\.bin,/);
  assert.equal(fs.existsSync(SHIM), true);
});
