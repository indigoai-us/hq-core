"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { test } = require("node:test");
const {
  FLAG_KEY,
  REQUEST_TIMEOUT_MS,
  codexExplicitPathGuardEnabled,
  companyUidForSlug,
} = require("../../../.codex/hooks/codex-explicit-path-flag.cjs");

function fakeRuntime(flagValue, fetchImpl = async () => ({ ok: true }), inspectConfig = () => {}) {
  return {
    createClient(config) {
      inspectConfig(config);
      return {
        async ready() {
          await config.fetch("https://flags.invalid/v1/flags", {});
        },
        snapshot() {
          return { flags: { [FLAG_KEY]: flagValue } };
        },
        close() {},
      };
    },
    getClientHealthFlagToken: async () => "test-id-token",
    loadCachedTokens: () => ({ idToken: "cached-test-id-token" }),
    fetch: fetchImpl,
  };
}

function envWithExplicitCompany() {
  return {
    HQ_FLAGS_API_URL: "https://flags.invalid",
    HQ_COMPANY_UID: "cmp_test123",
  };
}

test("slow module loading does not consume the flag request deadline", async () => {
  assert.ok(REQUEST_TIMEOUT_MS > 0);
  let fetched = false;
  const runtime = fakeRuntime(true, async () => {
    fetched = true;
    return { ok: true };
  });
  const enabled = await codexExplicitPathGuardEnabled({
    env: envWithExplicitCompany(),
    cliRoot: "/virtual-cli",
    loadRuntimeModules: async () => {
      await new Promise((resolve) => setTimeout(resolve, 300));
      return runtime;
    },
  });
  assert.equal(fetched, true, "flag request must start after module loading");
  assert.equal(enabled, true);
});

test("resolves endpoint and company from the bound HQ session without explicit env", async (t) => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), "codex-flag-context-"));
  t.after(() => fs.rmSync(temp, { recursive: true, force: true }));
  const hqRoot = path.join(temp, "hq");
  const cliRoot = path.join(temp, "cli");
  fs.mkdirSync(path.join(hqRoot, "core/scripts"), { recursive: true });
  fs.mkdirSync(path.join(hqRoot, "companies/indigo"), { recursive: true });
  fs.writeFileSync(path.join(hqRoot, "core/scripts/hq-session.sh"),
    '#!/usr/bin/env bash\n[ "$1" = get ] && [ "$2" = company_slug ] && printf indigo\n');
  fs.writeFileSync(path.join(hqRoot, "companies/indigo/.company-uid"), "cmp_indigo123\n");
  fs.mkdirSync(path.join(cliRoot, "dist/lib"), { recursive: true });
  fs.writeFileSync(path.join(cliRoot, "package.json"), JSON.stringify({ name: "@indigoai-us/hq-cli", type: "module" }));
  fs.writeFileSync(path.join(cliRoot, "dist/lib/flag-registry-endpoint.js"),
    'export const FLAG_REGISTRY_DEFAULT_ENDPOINT = "https://flags.default.invalid";\n');

  let observed;
  const enabled = await codexExplicitPathGuardEnabled({
    env: {},
    hqRoot,
    cliRoot,
    loadRuntimeModules: async () => fakeRuntime(true, undefined, (config) => { observed = config; }),
  });
  assert.equal(enabled, true);
  assert.equal(observed.endpoint, "https://flags.default.invalid");
  assert.equal(observed.companyUid, "cmp_indigo123");
  assert.deepEqual(observed.companyIdentifiers, ["indigo"]);
});

test("a flag request slower than the network bound fails closed", async () => {
  let requestStarted = false;
  let requestAborted = false;
  const runtime = fakeRuntime(true, (_input, init) => new Promise((resolve, reject) => {
    requestStarted = true;
    if (init.signal.aborted) {
      requestAborted = true;
      reject(init.signal.reason);
      return;
    }
    const timer = setTimeout(() => resolve({ ok: true }), REQUEST_TIMEOUT_MS + 150);
    init.signal.addEventListener("abort", () => {
      clearTimeout(timer);
      requestAborted = true;
      reject(init.signal.reason);
    }, { once: true });
  }));
  const enabled = await codexExplicitPathGuardEnabled({
    env: envWithExplicitCompany(),
    cliRoot: "/virtual-cli",
    loadRuntimeModules: async () => runtime,
  });
  assert.equal(requestStarted, true);
  assert.equal(requestAborted, true);
  assert.equal(enabled, false);
});

test("a false registry value stays false", async () => {
  const enabled = await codexExplicitPathGuardEnabled({
    env: envWithExplicitCompany(),
    cliRoot: "/virtual-cli",
    loadRuntimeModules: async () => fakeRuntime(false),
  });
  assert.equal(enabled, false);
});

test("falls back to the manifest cloud_uid when the company has no .company-uid file", (t) => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), "codex-flag-manifest-"));
  t.after(() => fs.rmSync(temp, { recursive: true, force: true }));
  fs.mkdirSync(path.join(temp, "companies/indigo"), { recursive: true });
  fs.writeFileSync(path.join(temp, "companies/manifest.yaml"), [
    "companies:",
    "  other:",
    "    cloud_uid: cmp_other999",
    "  indigo:",
    "    name: Indigo",
    "    qmd_collections:",
    "      - indigo",
    "    cloud_uid: cmp_indigo456",
    "  local-only:",
    "    name: Local",
    "",
  ].join("\n"));
  assert.equal(companyUidForSlug(temp, "indigo"), "cmp_indigo456");
  assert.equal(companyUidForSlug(temp, "local-only"), undefined);
  assert.equal(companyUidForSlug(temp, "missing"), undefined);
});
