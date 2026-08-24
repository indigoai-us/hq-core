import assert from "node:assert/strict";
import { test } from "node:test";

import { execResolvedFile, resolveBin } from "./command-runner.mjs";

function windowsFixture(paths) {
  const files = new Set(paths.map((path) => path.toLowerCase()));
  return {
    platform: "win32",
    home: "C:\\Users\\Ada",
    existsSync: (path) => files.has(path.toLowerCase()),
  };
}

test("Windows PATH keeps drive-letter entries intact and probes command shims", () => {
  const expected = "D:\\npm\\hq.CMD";
  const resolved = resolveBin("hq", {
    ...windowsFixture([expected]),
    env: {
      PATH: "C:\\Program Files\\HQ;D:\\npm",
      PATHEXT: ".EXE;.CMD",
    },
  });

  assert.equal(resolved, expected);
});

test("Windows PATH probes executable files and ignores unsafe PATHEXT entries", () => {
  const expected = "C:\\Tools\\qmd.EXE";
  const resolved = resolveBin("qmd", {
    ...windowsFixture([expected]),
    env: {
      PATH: "C:\\Tools;D:\\Elsewhere",
      PATHEXT: ".DLL;..\\EVIL;.EXE",
    },
  });

  assert.equal(resolved, expected);
});

test("Windows resolver includes the managed HQ toolchain for both commands", () => {
  const toolchain = "C:\\Users\\Ada\\AppData\\Roaming\\Indigo HQ\\toolchain";
  const hq = `${toolchain}\\npm-global\\hq.CMD`;
  const qmd = `${toolchain}\\npm-global\\qmd.CMD`;
  const fixture = windowsFixture([hq, qmd]);
  const env = { PATH: "", APPDATA: "C:\\Users\\Ada\\AppData\\Roaming" };

  assert.equal(resolveBin("hq", { ...fixture, env }), hq);
  assert.equal(resolveBin("qmd", { ...fixture, env }), qmd);
});

test("Windows resolver includes npm, pnpm, Bun, and Volta per-user locations", () => {
  const npmHq = "C:\\Users\\Ada\\AppData\\Roaming\\npm\\hq.CMD";
  const pnpmQmd = "C:\\Users\\Ada\\AppData\\Local\\pnpm\\qmd.EXE";
  const fixture = windowsFixture([npmHq, pnpmQmd]);
  const env = {
    PATH: "",
    APPDATA: "C:\\Users\\Ada\\AppData\\Roaming",
    LOCALAPPDATA: "C:\\Users\\Ada\\AppData\\Local",
  };

  assert.equal(resolveBin("hq", { ...fixture, env }), npmHq);
  assert.equal(resolveBin("qmd", { ...fixture, env }), pnpmQmd);

  const bunHq = "C:\\Users\\Ada\\.bun\\bin\\hq.CMD";
  const voltaQmd = "C:\\Users\\Ada\\.volta\\bin\\qmd.EXE";
  const otherFixture = windowsFixture([bunHq, voltaQmd]);
  assert.equal(resolveBin("hq", { ...otherFixture, env: { PATH: "" } }), bunHq);
  assert.equal(resolveBin("qmd", { ...otherFixture, env: { PATH: "" } }), voltaQmd);
});

test("both absolute command overrides support Windows drive-letter paths", () => {
  for (const [bin, envKey] of [["hq", "HQ_BIN"], ["qmd", "QMD_BIN"]]) {
    const override = `C:\\HQ Tools\\${bin}.cmd`;
    assert.equal(
      resolveBin(bin, {
        ...windowsFixture([override]),
        env: { [envKey]: override, PATH: "" },
      }),
      override,
    );
  }
});

test("POSIX resolution preserves colon-separated PATH and extensionless commands", () => {
  const expected = "/opt/tools/qmd";
  assert.equal(
    resolveBin("qmd", {
      platform: "linux",
      home: "/home/ada",
      env: { PATH: `/usr/bin:${expected.slice(0, -4)}` },
      existsSync: (path) => path === expected,
    }),
    expected,
  );
});

test("POSIX absolute override behavior is preserved for both commands", () => {
  for (const [bin, envKey] of [["hq", "HQ_BIN"], ["qmd", "QMD_BIN"]]) {
    const override = `/custom/bin/${bin}`;
    assert.equal(
      resolveBin(bin, {
        platform: "darwin",
        home: "/Users/ada",
        env: { [envKey]: override, PATH: "" },
        existsSync: (path) => path === override,
      }),
      override,
    );
  }
});

test("Windows command shims run through the fixed PowerShell adapter with argv intact", () => {
  const calls = [];
  const callback = () => {};
  const untrustedArg = "report & whoami";
  const child = { stdin: null };
  const returned = execResolvedFile(
    "C:\\Users\\Ada\\AppData\\Roaming\\npm\\hq.cmd",
    ["feedback", "bug", "--title", untrustedArg],
    { cwd: "C:\\HQ" },
    callback,
    {
      platform: "win32",
      env: { SystemRoot: "C:\\Windows" },
      execFileImpl: (...args) => {
        calls.push(args);
        return child;
      },
      shimScript: "C:\\plugin\\windows-command-shim.ps1",
    },
  );

  assert.equal(returned, child);
  const encoded = [
    "C:\\Users\\Ada\\AppData\\Roaming\\npm\\hq.cmd",
    "feedback",
    "bug",
    "--title",
    untrustedArg,
  ].map((value) => Buffer.from(value, "utf8").toString("base64"));
  assert.deepEqual(calls, [[
    "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
    [
      "-NoLogo",
      "-NoProfile",
      "-NonInteractive",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      "C:\\plugin\\windows-command-shim.ps1",
      ...encoded,
    ],
    { cwd: "C:\\HQ", shell: false, windowsHide: true },
    callback,
  ]]);
  assert.equal(JSON.stringify(calls).includes(untrustedArg), false);
});

test("native Windows and POSIX executables still execute directly", () => {
  for (const [platform, file] of [
    ["win32", "C:\\Tools\\hq.exe"],
    ["linux", "/usr/local/bin/hq"],
  ]) {
    const calls = [];
    const callback = () => {};
    execResolvedFile(file, ["whoami"], {}, callback, {
      platform,
      execFileImpl: (...args) => {
        calls.push(args);
        return {};
      },
    });
    assert.deepEqual(calls, [[file, ["whoami"], { shell: false }, callback]]);
  }
});
