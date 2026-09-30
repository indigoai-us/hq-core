"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

async function main() {
  const [readerPath, fixtureRoot] = process.argv.slice(2);
  assert.ok(readerPath, "reader path is required");
  assert.ok(fixtureRoot, "fixture root is required");
  const { bashAutosaveSweepEnabled } = require(readerPath);
  fs.mkdirSync(fixtureRoot, { recursive: true });

  function createHqRoot(name, companySlug) {
    const root = path.join(fixtureRoot, name);
    const sessionScript = path.join(root, "core/scripts/hq-session.sh");
    fs.mkdirSync(path.dirname(sessionScript), { recursive: true });
    fs.mkdirSync(path.join(root, "companies"), { recursive: true });
    fs.writeFileSync(sessionScript, `#!/usr/bin/env bash\nif [[ "$1:$2" == "get:company_slug" ]]; then printf '%s\\n' '${companySlug}'; fi\n`);
    fs.chmodSync(sessionScript, 0o755);
    if (companySlug) {
      const companyDir = path.join(root, "companies", companySlug);
      fs.mkdirSync(companyDir, { recursive: true });
      fs.writeFileSync(path.join(companyDir, ".company-uid"), "cmp_synthetic123\n");
    }
    return root;
  }

  function createCliRoot() {
    const cliRoot = path.join(fixtureRoot, "fake-hq-cli");
    const endpointFile = path.join(cliRoot, "dist/lib/flag-registry-endpoint.js");
    fs.mkdirSync(path.dirname(endpointFile), { recursive: true });
    fs.writeFileSync(path.join(cliRoot, "package.json"), JSON.stringify({ name: "@indigoai-us/hq-cli", type: "module" }));
    fs.writeFileSync(endpointFile, 'export const FLAG_REGISTRY_DEFAULT_ENDPOINT = "https://flags.synthetic.test";\n');
    return cliRoot;
  }

  const cliRoot = createCliRoot();
  function fakeClient(flagValue, seen) {
    return (options) => {
      seen.options = options;
      return {
        ready: async () => {},
        snapshot: () => ({ flags: { ["hooks.hq-autocommit-bash-sweep"]: flagValue } }),
        close: () => {},
      };
    };
  }

  const boundRoot = createHqRoot("bound-company", "synthetic-co");
  const enabledSeen = {};
  const enabled = await bashAutosaveSweepEnabled({
    env: { HQ_ROOT: boundRoot },
    hqRoot: boundRoot,
    cliRoot,
    createClient: fakeClient(true, enabledSeen),
    loadCachedTokens: () => ({ idToken: "synthetic-id-token" }),
    fetch: async () => { throw new Error("network must not be used by fake client"); },
    reportError: (error) => { throw error; },
  });
  assert.equal(enabled, true, "bound company flag true must enable the sweep without endpoint env");
  assert.equal(enabledSeen.options.endpoint, "https://flags.synthetic.test");
  assert.equal(enabledSeen.options.companyUid, "cmp_synthetic123");

  const disabledSeen = {};
  const disabled = await bashAutosaveSweepEnabled({
    env: { HQ_ROOT: boundRoot },
    hqRoot: boundRoot,
    cliRoot,
    createClient: fakeClient(false, disabledSeen),
    loadCachedTokens: () => ({ idToken: "synthetic-id-token" }),
    reportError: (error) => { throw error; },
  });
  assert.equal(disabled, false, "bound company flag false must keep the sweep disabled");
  assert.equal(disabledSeen.options.companyUid, "cmp_synthetic123");

  const unboundRoot = createHqRoot("unbound", "");
  const unboundSeen = {};
  const unbound = await bashAutosaveSweepEnabled({
    env: { HQ_ROOT: unboundRoot },
    hqRoot: unboundRoot,
    cliRoot,
    createClient: fakeClient(true, unboundSeen),
    loadCachedTokens: () => ({ idToken: "synthetic-id-token" }),
    reportError: (error) => { throw error; },
  });
  assert.equal(unbound, true, "client supports resolving defaults/person overrides without a company UID");
  assert.equal(unboundSeen.options.companyUid, undefined);
  assert.equal(unboundSeen.options.endpoint, "https://flags.synthetic.test");

  const missingTokenSeen = {};
  const missingTokenErrors = [];
  const missingToken = await bashAutosaveSweepEnabled({
    env: { HQ_ROOT: boundRoot },
    hqRoot: boundRoot,
    cliRoot,
    createClient: fakeClient(true, missingTokenSeen),
    loadCachedTokens: () => null,
    reportError: (error) => missingTokenErrors.push(error),
  });
  assert.equal(missingToken, false, "missing token must stay default-off");
  assert.equal(missingTokenSeen.options, undefined, "missing token must prevent a client request");
  assert.equal(missingTokenErrors.length, 1, "missing token reports one failure and stays quiet otherwise");

  fs.rmSync(fixtureRoot, { recursive: true, force: true });
  process.stdout.write("hq-autocommit-bash-flag-reach: all checks passed\n");
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});
