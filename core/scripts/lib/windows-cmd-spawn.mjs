/** # hq-core: public */
/**
 * Spawn Windows npm `.cmd`/`.bat` shims without Node 20+'s EINVAL and without
 * `shell: true`. Node's CreateProcess refuses batch files unless a shell is
 * involved; interpolating agent prompts into `cmd.exe /c` is unsafe. The same
 * PowerShell adapter the Cowork pack uses keeps argv intact via base64.
 */
import { spawn, spawnSync } from 'node:child_process';
import { existsSync as fsExistsSync } from 'node:fs';
import { posix, win32 } from 'node:path';
import { fileURLToPath } from 'node:url';

const WINDOWS_EXECUTABLE_EXTENSIONS = ['.COM', '.EXE', '.BAT', '.CMD'];
const WINDOWS_BATCH_EXT = /\.(?:bat|cmd)$/i;

export function windowsExecutableExtensions(pathExt = '') {
  const allowed = new Set(WINDOWS_EXECUTABLE_EXTENSIONS);
  const configured = String(pathExt)
    .split(win32.delimiter)
    .map((extension) => extension.trim().toUpperCase())
    .filter((extension) => /^\.[A-Z0-9]+$/.test(extension) && allowed.has(extension));
  return [...new Set([...configured, ...WINDOWS_EXECUTABLE_EXTENSIONS])];
}

function encodePowerShellArgument(value) {
  return Buffer.from(String(value), 'utf8').toString('base64');
}

function hasWindowsDirectory(file, pathApi) {
  return pathApi.isAbsolute(file) || file.includes('/') || file.includes('\\');
}

/**
 * On Windows, apply PATHEXT so a bare `claude` becomes `claude.cmd` when that
 * shim exists on PATH. Paths that already have an extension are left alone.
 */
export function resolveWindowsCommand(file, options = {}) {
  const {
    platform = process.platform,
    env = process.env,
    existsSync: pathExists = fsExistsSync,
    pathApi = platform === 'win32' ? win32 : posix,
  } = options;
  const trimmed = String(file || '');
  if (platform !== 'win32' || !trimmed || pathApi.extname(trimmed)) return trimmed;

  const suffixes = windowsExecutableExtensions(env.PATHEXT);
  if (hasWindowsDirectory(trimmed, pathApi)) {
    for (const suffix of suffixes) {
      const candidate = `${trimmed}${suffix}`;
      if (pathExists(candidate)) return candidate;
    }
    return trimmed;
  }

  const directories = String(env.PATH || '').split(pathApi.delimiter).filter(Boolean);
  for (const directory of directories) {
    for (const suffix of suffixes) {
      const candidate = pathApi.join(directory, `${trimmed}${suffix}`);
      if (pathExists(candidate)) return candidate;
    }
  }
  return trimmed;
}

function powershellPath(env, pathApi) {
  return pathApi.join(
    env.SystemRoot || env.SYSTEMROOT || 'C:\\Windows',
    'System32',
    'WindowsPowerShell',
    'v1.0',
    'powershell.exe',
  );
}

/**
 * Return the `{ file, args, options }` that spawn/spawnSync should receive.
 * Non-Windows and native `.exe` files are unchanged aside from `shell: false`
 * and `windowsHide: true` on win32.
 */
export function prepareWindowsCommand(file, args, options = {}, deps = {}) {
  const platform = deps.platform ?? process.platform;
  const env = deps.env ?? process.env;
  const pathApi = deps.pathApi ?? (platform === 'win32' ? win32 : posix);
  const resolved = resolveWindowsCommand(file, {
    platform,
    env,
    existsSync: deps.existsSync,
    pathApi,
  });
  const spawnOptions = { ...options };
  if (platform === 'win32') {
    spawnOptions.shell = false;
    if (spawnOptions.windowsHide == null) spawnOptions.windowsHide = true;
  }
  if (platform !== 'win32' || !WINDOWS_BATCH_EXT.test(resolved)) {
    return { file: resolved, args, options: spawnOptions };
  }

  const shimScript = deps.shimScript
    || fileURLToPath(new URL('./windows-command-shim.ps1', import.meta.url));
  return {
    file: powershellPath(env, pathApi),
    args: [
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      shimScript,
      ...[resolved, ...args].map(encodePowerShellArgument),
    ],
    options: spawnOptions,
  };
}

export function spawnCommand(file, args, options, deps = {}) {
  const prepared = prepareWindowsCommand(file, args, options, deps);
  return (deps.spawnImpl || spawn)(prepared.file, prepared.args, prepared.options);
}

export function spawnSyncCommand(file, args, options, deps = {}) {
  const prepared = prepareWindowsCommand(file, args, options, deps);
  return (deps.spawnSyncImpl || spawnSync)(prepared.file, prepared.args, prepared.options);
}
