const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");
const { readHqFlag, setupPathFlagEnabled } = require("../setup-path-flag.cjs");

function createCliFixture({ userToken = null, machineToken = null, flagStatus = 200 } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "hq-flag-machine-token-"));
  const cliRoot = path.join(root, "cli");
  const cliBin = path.join(cliRoot, "bin", "hq");
  fs.mkdirSync(path.dirname(cliBin), { recursive: true });
  fs.writeFileSync(cliBin, "#!/usr/bin/env node\n");
  fs.writeFileSync(path.join(cliRoot, "package.json"), JSON.stringify({ name: "@indigoai-us/hq-cli", type: "module" }));

  const flagsPackage = path.join(cliRoot, "node_modules", "@indigoai-us", "hq-flags-client");
  fs.mkdirSync(flagsPackage, { recursive: true });
  fs.writeFileSync(path.join(flagsPackage, "package.json"), JSON.stringify({ exports: "./index.mjs" }));
  fs.writeFileSync(path.join(flagsPackage, "index.mjs"), `
    export function createFlagClient(options) {
      return {
        ready: async () => {
          const token = options.getToken();
          const response = await options.fetch("https://flags.invalid/resolve", {
            headers: token ? { Authorization: "Bearer " + token } : {},
          });
          if (response.status !== 200) {
            const error = new Error("flag request failed");
            options.onError?.(error);
            throw error;
          }
        },
        snapshot: () => ({ flags: {
          "test.machine-token": true,
          "core.setup-path-settings-local": true,
        } }),
        close: () => {},
      };
    }
  `);

  const cloudPackage = path.join(cliRoot, "node_modules", "@indigoai-us", "hq-cloud");
  fs.mkdirSync(cloudPackage, { recursive: true });
  fs.writeFileSync(path.join(cloudPackage, "package.json"), JSON.stringify({ exports: "./index.mjs" }));
  fs.writeFileSync(path.join(cloudPackage, "index.mjs"), `
    export function loadCachedTokens() {
      return ${JSON.stringify(userToken)} ? { idToken: ${JSON.stringify(userToken)} } : null;
    }
  `);

  const cliSession = path.join(cliRoot, "dist", "utils");
  fs.mkdirSync(cliSession, { recursive: true });
  fs.writeFileSync(path.join(cliSession, "cognito-session.js"), `
    export function loadMachineCachedTokens() {
      return ${JSON.stringify(machineToken)} ? { idToken: ${JSON.stringify(machineToken)} } : null;
    }
  `);

  return { root, cliBin, userToken, machineToken, flagStatus };
}

async function runReader(t, fixture) {
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
  let authorizationMatched = false;
  let reported = "";
  const originalFetch = globalThis.fetch;
  const originalWrite = process.stderr.write;
  globalThis.fetch = async (_input, init = {}) => {
    authorizationMatched = init.headers?.Authorization === `Bearer ${fixture.userToken || fixture.machineToken}`;
    const status = authorizationMatched ? fixture.flagStatus : 401;
    return { status, ok: status === 200 };
  };
  process.stderr.write = function (chunk, ...args) {
    reported += String(chunk);
    return originalWrite.call(this, "", ...args);
  };
  try {
    const result = await readHqFlag("test.machine-token", {
      HQ_CLI_BIN: fixture.cliBin,
      HQ_FLAGS_API_URL: "https://flags.invalid",
      HQ_COMPANY_UID: "cmp_fixture123",
    }, "machine token test");
    return { result, authorizationMatched, reportCount: (reported.match(/flag lookup failed/g) ?? []).length };
  } finally {
    globalThis.fetch = originalFetch;
    process.stderr.write = originalWrite;
  }
}

test("machine token only is sent to flag evaluation and returns the flag", async (t) => {
  const fixture = createCliFixture({ machineToken: "machine-test-token" });
  const outcome = await runReader(t, fixture);
  assert.equal(outcome.authorizationMatched, true, "the machine ID token should authenticate the flag request");
  assert.equal(outcome.result, true, "the machine principal should receive the evaluated flag value");
});

test("cached user ID token is preferred over the machine token loader", async (t) => {
  const fixture = createCliFixture({ userToken: "user-test-token", machineToken: "machine-test-token" });
  const outcome = await runReader(t, fixture);
  assert.equal(outcome.authorizationMatched, true, "the cached user ID token should authenticate the flag request");
  assert.equal(outcome.result, true, "the user principal should receive the evaluated flag value");
});

test("no user or machine token returns false without calling the endpoint", async (t) => {
  const fixture = createCliFixture();
  const outcome = await runReader(t, fixture);
  assert.equal(outcome.result, false, "missing credentials retain default-off behavior");
  assert.equal(outcome.authorizationMatched, false, "the flag endpoint is not called without a token");
});

test("flag endpoint failure is still reported once", async (t) => {
  const fixture = createCliFixture({ machineToken: "machine-test-token", flagStatus: 403 });
  const outcome = await runReader(t, fixture);
  assert.equal(outcome.result, false, "a rejected flag request retains default-off behavior");
  assert.equal(outcome.reportCount, 1, "the flag request failure is reported once");
});

test("setup PATH allows the real network evaluation budget", async (t) => {
  const fixture = createCliFixture({ machineToken: "machine-test-token" });
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => {
    await new Promise((resolve) => setTimeout(resolve, 400));
    return { status: 200, ok: true };
  };
  try {
    assert.equal(await setupPathFlagEnabled({
      HQ_CLI_BIN: fixture.cliBin,
      HQ_FLAGS_API_URL: "https://flags.invalid",
      HQ_COMPANY_UID: "cmp_fixture123",
    }), true, "setup PATH evaluation should tolerate ordinary network latency");
  } finally {
    globalThis.fetch = originalFetch;
  }
});
