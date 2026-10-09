#!/usr/bin/env node
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { performance } from "node:perf_hooks";

const root = process.cwd();
let forwarder = path.join(root, "core/scripts/derive-trigger-facts.sh");
const bash = process.platform === "win32" ? "bash" : "/bin/bash";

function resolveCliPackageRoot() {
  if (process.env.HQ_CLI_ROOT) return process.env.HQ_CLI_ROOT;

  const npmRoot = spawnSync(bash, ["-c", "npm root -g"], {
    cwd: root,
    env: process.env,
    stdio: ["ignore", "pipe", "pipe"],
    encoding: "utf8",
    timeout: 10_000,
  });
  assert.equal(npmRoot.error, undefined, `could not locate global hq-cli: ${npmRoot.error?.message ?? "unknown error"}`);
  assert.equal(npmRoot.status, 0, `npm root -g failed: ${npmRoot.stderr}`);
  return path.join(npmRoot.stdout.trim(), "@indigoai-us", "hq-cli");
}

const cliPackageRoot = resolveCliPackageRoot();
const packageMetadata = JSON.parse(fs.readFileSync(path.join(cliPackageRoot, "package.json"), "utf8"));
const resolvedPin = spawnSync(bash, ["core/scripts/ci/install-pinned-hq-cli.sh", "--resolve-only"], {
  cwd: root,
  env: process.env,
  stdio: ["ignore", "pipe", "pipe"],
  encoding: "utf8",
  timeout: 10_000,
});
assert.equal(resolvedPin.error, undefined, `could not resolve pinned hq-cli version: ${resolvedPin.error?.message ?? "unknown error"}`);
assert.equal(resolvedPin.status, 0, `pinned hq-cli resolution failed: ${resolvedPin.stderr}`);
assert.equal(packageMetadata.version, resolvedPin.stdout.trim(), "global hq-cli must match the resolved CI pin");

const bundledScript = toBashPath(path.join(cliPackageRoot, "assets/scaffold/core/scripts/derive-trigger-facts.sh"));
function toBashPath(nativePath) {
  if (process.platform !== "win32") return nativePath;
  const converted = spawnSync(bash, ["-c", 'cygpath -u "$1"', "closed-stdin-test", nativePath], {
    cwd: root,
    env: process.env,
    stdio: ["ignore", "pipe", "pipe"],
    encoding: "utf8",
    timeout: 10_000,
  });
  assert.equal(converted.error, undefined, `could not convert script path: ${converted.error?.message ?? "unknown error"}`);
  assert.equal(converted.status, 0, `cygpath could not convert script path: ${converted.stderr}`);
  return converted.stdout.trim();
}
forwarder = toBashPath(forwarder);

function runClosedStdin(script) {
  const startedAt = performance.now();
  const result = spawnSync(bash, [
    "-c",
    'exec 0<&-; exec bash "$@" UserPromptSubmit',
    "closed-stdin-test",
    script,
  ], {
    cwd: root,
    env: {
      ...process.env,
      HQ_NO_UPDATE_CHECK: "1",
    },
    stdio: ["ignore", "pipe", "pipe"],
    timeout: 10_000,
  });
  const elapsedMs = performance.now() - startedAt;
  assert.equal(result.error, undefined, `closed-stdin ${script} did not finish within 10000 ms: ${result.error?.message ?? "unknown error"}`);
  assert.equal(result.signal, null, `closed-stdin ${script} was terminated by ${result.signal}`);
  assert.ok(elapsedMs < 10_000, `closed-stdin ${script} exceeded 10000 ms: ${elapsedMs.toFixed(1)} ms`);
  return { status: result.status, stdout: result.stdout, stderr: result.stderr, elapsedMs };
}

function runOpenStdin(kind) {
  const startedAt = performance.now();
  const result = kind === "forwarder"
    ? spawnSync(bash, [forwarder, "UserPromptSubmit"], {
      cwd: root,
      env: { ...process.env, HQ_NO_UPDATE_CHECK: "1" },
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 60_000,
    })
    : spawnSync(bash, [
      "-c",
      '(: </dev/stdin) 2>/dev/null; exec hq core derive-trigger-facts "$1"',
      "derive-trigger-facts-open-stdin-benchmark",
      "UserPromptSubmit",
    ], {
      cwd: root,
      env: { ...process.env, HQ_NO_UPDATE_CHECK: "1" },
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 60_000,
    });
  const elapsedMs = performance.now() - startedAt;
  assert.equal(result.error, undefined, `${kind} open-stdin call did not finish within 60000 ms: ${result.error?.message ?? "unknown error"}`);
  assert.equal(result.signal, null, `${kind} open-stdin call was terminated by ${result.signal}`);
  assert.equal(result.status, 0, `${kind} open-stdin call failed: stdout=${JSON.stringify(result.stdout)} stderr=${JSON.stringify(result.stderr)}`);
  return { status: result.status, stdout: result.stdout ?? Buffer.alloc(0), stderr: result.stderr ?? Buffer.alloc(0), elapsedMs };
}

function percentile(samples, fraction) {
  const sorted = [...samples].sort((left, right) => left - right);
  return sorted[Math.ceil(sorted.length * fraction) - 1];
}

const forwarded = runClosedStdin(forwarder);
const released = runClosedStdin(bundledScript);
const closedStdinParity = {
  status: forwarded.status === released.status,
  stdout: forwarded.stdout.equals(released.stdout),
  stderr: forwarded.stderr.equals(released.stderr),
};
console.log(
  `derive-trigger-facts closed-stdin comparison ${process.platform}: hq-cli=${packageMetadata.version} `
  + `status=${closedStdinParity.status}, stdoutBytes=${forwarded.stdout.length}/${released.stdout.length} `
  + `equal=${closedStdinParity.stdout}, stderrBytes=${forwarded.stderr.length}/${released.stderr.length} `
  + `equal=${closedStdinParity.stderr}; forwarder=${forwarded.elapsedMs.toFixed(1)} ms, `
  + `bundled=${released.elapsedMs.toFixed(1)} ms (each under 10000 ms)`,
);
assert.equal(forwarded.status, released.status, "closed-stdin exit code parity");
assert.deepEqual(forwarded.stdout, released.stdout, "closed-stdin stdout byte parity");
assert.deepEqual(forwarded.stderr, released.stderr, "closed-stdin stderr byte parity");
console.log(`derive-trigger-facts closed-stdin parity ${process.platform}: matched exit, stdout bytes, and stderr bytes`);

const openStdinRuns = [];
for (let warmup = 0; warmup < 3; warmup += 1) {
  runOpenStdin("legacy");
  runOpenStdin("forwarder");
}
for (let pair = 0; pair < 20; pair += 1) {
  const legacy = runOpenStdin("legacy");
  const forwardedOpen = runOpenStdin("forwarder");
  assert.equal(forwardedOpen.status, legacy.status, `open-stdin pair ${pair + 1} exit code`);
  assert.deepEqual(forwardedOpen.stdout, legacy.stdout, `open-stdin pair ${pair + 1} stdout bytes`);
  assert.deepEqual(forwardedOpen.stderr, legacy.stderr, `open-stdin pair ${pair + 1} stderr bytes`);
  openStdinRuns.push({ legacyMs: legacy.elapsedMs, forwarderMs: forwardedOpen.elapsedMs });
}
const openStdinDeltas = openStdinRuns.map(({ legacyMs, forwarderMs }) => forwarderMs - legacyMs);
console.log(
  `derive-trigger-facts open-stdin ${process.platform}: paired n=${openStdinRuns.length} `
  + `legacy p50=${percentile(openStdinRuns.map((sample) => sample.legacyMs), 0.5).toFixed(1)} ms `
  + `p90=${percentile(openStdinRuns.map((sample) => sample.legacyMs), 0.9).toFixed(1)} ms; `
  + `forwarder p50=${percentile(openStdinRuns.map((sample) => sample.forwarderMs), 0.5).toFixed(1)} ms `
  + `p90=${percentile(openStdinRuns.map((sample) => sample.forwarderMs), 0.9).toFixed(1)} ms; `
  + `paired delta p50=${percentile(openStdinDeltas, 0.5).toFixed(1)} ms`,
);
