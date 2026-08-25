import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { posix, win32 } from "node:path";
import { fileURLToPath } from "node:url";

const WINDOWS_EXECUTABLE_EXTENSIONS = [".COM", ".EXE", ".BAT", ".CMD"];

function windowsExecutableExtensions(pathExt = "") {
  const allowed = new Set(WINDOWS_EXECUTABLE_EXTENSIONS);
  const configured = pathExt
    .split(win32.delimiter)
    .map((extension) => extension.trim().toUpperCase())
    .filter((extension) => /^\.[A-Z0-9]+$/.test(extension) && allowed.has(extension));
  return [...new Set([...configured, ...WINDOWS_EXECUTABLE_EXTENSIONS])];
}

function compact(items) {
  return items.filter((item) => typeof item === "string" && item.length > 0);
}

function encodePowerShellArgument(value) {
  return Buffer.from(String(value), "utf8").toString("base64");
}

/**
 * Resolve a host command from an explicit override, PATH, or common install
 * locations.
 */
export function resolveBin(bin, options = {}) {
  const {
    env = process.env,
    existsSync: pathExists = existsSync,
    home = homedir(),
    platform = process.platform,
  } = options;
  const pathApi = platform === "win32" ? win32 : posix;
  const envKey = `${bin.toUpperCase().replace(/[^A-Z0-9]/g, "_")}_BIN`;
  const override = env[envKey];
  // Only absolute, existing overrides are trusted. Relative paths could be
  // redirected through the caller-controlled working directory.
  if (override && pathApi.isAbsolute(override) && pathExists(override)) {
    return override;
  }

  const pathDirectories = (env.PATH || "")
    .split(pathApi.delimiter)
    .filter(Boolean);
  const windows = platform === "win32";
  const localAppData = env.LOCALAPPDATA || (windows ? win32.join(home, "AppData", "Local") : "");
  const appData = env.APPDATA || (windows ? win32.join(home, "AppData", "Roaming") : "");
  const managedToolchains = env.HQ_TOOLCHAIN_DIR
    ? [env.HQ_TOOLCHAIN_DIR]
    : windows
      ? [
          win32.join(appData, "Indigo HQ", "toolchain"),
          win32.join(localAppData, "Indigo HQ", "toolchain"),
        ]
      : [posix.join(home, "Library", "Application Support", "Indigo HQ", "toolchain")];

  const installDirectories = windows
    ? compact([
        ...pathDirectories,
        ...managedToolchains.flatMap((toolchain) => [
          win32.join(toolchain, "npm-global"),
          win32.join(toolchain, "npm-global", "bin"),
          win32.join(toolchain, "node"),
          win32.join(toolchain, "node", "bin"),
          win32.join(toolchain, "git", "cmd"),
          win32.join(toolchain, "git", "bin"),
        ]),
        win32.join(appData, "npm"),
        env.PNPM_HOME,
        win32.join(localAppData, "pnpm"),
        env.BUN_INSTALL && win32.join(env.BUN_INSTALL, "bin"),
        win32.join(home, ".bun", "bin"),
        env.VOLTA_HOME && win32.join(env.VOLTA_HOME, "bin"),
        win32.join(home, ".volta", "bin"),
        win32.join(localAppData, "Yarn", "bin"),
        win32.join(localAppData, "Yarn", "Data", "global", "node_modules", ".bin"),
        win32.join(home, ".cargo", "bin"),
        win32.join(home, ".local", "bin"),
        win32.join(home, "bin"),
      ])
    : compact([
        ...pathDirectories,
        posix.join(managedToolchains[0], "npm-global", "bin"),
        posix.join(managedToolchains[0], "node", "bin"),
        posix.join(managedToolchains[0], "git", "bin"),
        env.PNPM_HOME,
        posix.join(home, ".local", "share", "pnpm"),
        env.BUN_INSTALL && posix.join(env.BUN_INSTALL, "bin"),
        posix.join(home, ".bun", "bin"),
        env.VOLTA_HOME && posix.join(env.VOLTA_HOME, "bin"),
        posix.join(home, ".volta", "bin"),
        posix.join(home, ".npm-global", "bin"),
        posix.join(home, ".cargo", "bin"),
        posix.join(home, ".local", "bin"),
        posix.join(home, "bin"),
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
      ]);

  const suffixes = windows && !win32.extname(bin)
    ? windowsExecutableExtensions(env.PATHEXT)
    : [""];
  const candidates = [
    ...new Set(
      installDirectories.flatMap((directory) =>
        suffixes.map((suffix) => pathApi.join(directory, `${bin}${suffix}`))),
    ),
  ];
  return candidates.find((candidate) => pathExists(candidate)) || bin;
}

/**
 * Execute a resolved host command without interpolating command arguments into
 * a shell program string.
 */
export function execResolvedFile(file, args, options, callback, dependencies = {}) {
  const {
    env = process.env,
    execFileImpl = execFile,
    platform = process.platform,
    shimScript = fileURLToPath(new URL("./windows-command-shim.ps1", import.meta.url)),
  } = dependencies;
  const execOptions = { ...options, shell: false };
  if (platform !== "win32" || !/\.(?:bat|cmd)$/i.test(file)) {
    return execFileImpl(file, args, execOptions, callback);
  }

  const powershell = win32.join(
    env.SystemRoot || "C:\\Windows",
    "System32",
    "WindowsPowerShell",
    "v1.0",
    "powershell.exe",
  );
  return execFileImpl(
    powershell,
    [
      "-NoLogo",
      "-NoProfile",
      "-NonInteractive",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      shimScript,
      ...[file, ...args].map(encodePowerShellArgument),
    ],
    { ...execOptions, windowsHide: true },
    callback,
  );
}
