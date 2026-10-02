const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");
const { readHqFlag } = require("../setup-path-flag.cjs");

function createCliFixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "hq-flag-timeout-"));
  const cliRoot = path.join(root, "cli");
  const cliBin = path.join(cliRoot, "bin", "hq");
  fs.mkdirSync(path.dirname(cliBin), { recursive: true });
  fs.writeFileSync(cliBin, "#!/usr/bin/env node\n");
  fs.writeFileSync(path.join(cliRoot, "package.json"), JSON.stringify({ name: "@indigoai-us/hq-cli" }));

  const flagsPackage = path.join(cliRoot, "node_modules", "@indigoai-us", "hq-flags-client");
  fs.mkdirSync(flagsPackage, { recursive: true });
  fs.writeFileSync(path.join(flagsPackage, "package.json"), JSON.stringify({ exports: "./index.mjs" }));
  fs.writeFileSync(path.join(flagsPackage, "index.mjs"), `
    export function createFlagClient(options) {
      return {
        ready: async () => { await options.fetch("https://flags.invalid/resolve"); },
        snapshot: () => ({ flags: { "test.slow-fetch": true } }),
        close: () => {},
      };
    }
  `);

  const cloudPackage = path.join(cliRoot, "node_modules", "@indigoai-us", "hq-cloud");
  fs.mkdirSync(cloudPackage, { recursive: true });
  fs.writeFileSync(path.join(cloudPackage, "package.json"), JSON.stringify({ exports: "./index.mjs" }));
  fs.writeFileSync(path.join(cloudPackage, "index.mjs"), `
    export function loadCachedTokens() { return { idToken: "fixture-token" }; }
  `);

  return { root, cliBin };
}

test("readHqFlag honors a longer total budget for a slow flag fetch", async (t) => {
  const fixture = createCliFixture();
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (_input, init = {}) => new Promise((resolve, reject) => {
    const signal = init.signal;
    const finish = () => {
      signal?.removeEventListener("abort", abort);
      resolve({ ok: true });
    };
    const timer = setTimeout(finish, 400);
    const abort = () => {
      clearTimeout(timer);
      signal?.removeEventListener("abort", abort);
      reject(signal.reason ?? new Error("fetch aborted"));
    };
    if (signal?.aborted) abort();
    else signal?.addEventListener("abort", abort, { once: true });
  });

  try {
    const env = {
      HQ_CLI_BIN: fixture.cliBin,
      HQ_FLAGS_API_URL: "https://flags.invalid",
      HQ_COMPANY_UID: "cmp_fixture123",
    };
    assert.equal(
      await readHqFlag("test.slow-fetch", env, "timeout test", { timeoutMs: 5000 }),
      true,
      "the extended budget should allow the delayed flag response",
    );
    assert.equal(
      await readHqFlag("test.slow-fetch", env, "timeout test"),
      false,
      "the default budget should retain default-off behavior when the response is slow",
    );
  } finally {
    globalThis.fetch = originalFetch;
  }
});
