"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "../../..");
const flag = require(path.join(root, ".claude/hooks/worker-codex-model-overrides-flag.cjs"));
const skill = fs.readFileSync(path.join(root, ".claude/skills/execute-task/SKILL.md"), "utf8");

const validEnv = {
  HQ_FLAGS_API_URL: "https://flags.invalid",
  HQ_COMPANY_UID: "cmp_abc123",
  HQ_COMPANY_SLUG: "acme",
};

function clientWith(flags) {
  return {
    ready: async () => {},
    snapshot: () => ({ flags }),
    close: () => {},
  };
}

async function main() {
  assert.equal(flag.FLAG_KEY, "workers.codex-model-overrides");
  assert.equal(flag.DEFAULT_VALUE, false);
  assert.equal(await flag.codexModelOverridesEnabled({
    env: {},
    createClient: () => { throw new Error("must not construct without flag context"); },
  }), false, "missing flag context stays off");

  const read = async (value) => flag.codexModelOverridesEnabled({
    env: validEnv,
    createClient: () => clientWith({ [flag.FLAG_KEY]: value }),
    loadCachedTokens: () => ({ idToken: "synthetic" }),
    fetch: async () => { throw new Error("injected client should not fetch"); },
    reportError: (error) => { throw error; },
  });
  assert.equal(await read(false), false, "explicit off stays off");
  assert.equal(await read(true), true, "explicit on enables model overlays");

  assert.equal(await flag.codexModelOverridesEnabled({
    env: validEnv,
    createClient: () => { throw new Error("synthetic lookup failure"); },
    loadCachedTokens: () => ({ idToken: "synthetic" }),
    reportError: () => {},
  }), false, "lookup failure fails closed");

  assert.match(skill, /workers\.codex-model-overrides/);
  assert.match(skill, /Resolve the core worker profile independently of the registry path/);
  assert.match(skill, /set the registry variable worker_path to the core directory before step 2/i);
  assert.match(skill, /companies\/\{active-company\}\/\.company-uid/);
  assert.match(skill, /Do not rely on inherited `HQ_COMPANY_UID` or `HQ_COMPANY_SLUG`/);
  assert.match(skill, /HQ_COMPANY_UID="\$active_company_uid"/);
  assert.match(skill, /HQ_COMPANY_SLUG="\{active-company\}"/);
  assert.match(skill, /personal\/workers\/\{worker-id\}\/worker\.yaml/);
  assert.match(skill, /companies\/\{active-company\}\/workers\/\{worker-id\}\/worker\.yaml/);
  assert.match(skill, /execution\.codex_model/);
  const workflow = fs.readFileSync(path.join(root, ".github/workflows/pr-checks.yml"), "utf8");
  assert.match(workflow, /node core\/scripts\/tests\/worker-codex-model-overrides\.test\.cjs/);
  assert.match(skill, /codex_flags/);
  assert.match(skill, /Do not read or merge overlay `execution\.codex_flags`/);
  process.stdout.write("worker Codex model overlay flag and scope: ok\n");
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});
