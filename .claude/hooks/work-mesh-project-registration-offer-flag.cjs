#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { pathToFileURL } = require("node:url");

const FLAG_KEY = "workmesh.offer-project-create-on-brainstorm";
const DEFAULT_VALUE = false;
const REQUEST_TIMEOUT_MS = 150;

function findCliPackageRoot(cliBin) {
  if (!cliBin) throw new Error("hq CLI binary was not found on PATH");
  let current = fs.realpathSync(cliBin);
  if (!fs.statSync(current).isDirectory()) current = path.dirname(current);
  for (let depth = 0; depth < 16; depth += 1) {
    const manifest = path.join(current, "package.json");
    if (fs.existsSync(manifest) && JSON.parse(fs.readFileSync(manifest, "utf8")).name === "@indigoai-us/hq-cli") return current;
    const parent = path.dirname(current);
    if (parent === current) break;
    current = parent;
  }
  throw new Error("installed hq CLI package could not be resolved");
}

function packageImportPath(cliRoot, packageName) {
  let current = cliRoot;
  const parts = packageName.split("/");
  for (let depth = 0; depth < 16; depth += 1) {
    const packageDir = path.join(current, "node_modules", ...parts);
    const manifest = path.join(packageDir, "package.json");
    if (fs.existsSync(manifest)) {
      const pkg = JSON.parse(fs.readFileSync(manifest, "utf8"));
      const rootExport = typeof pkg.exports === "string" ? pkg.exports : pkg.exports?.["."];
      const entry = typeof rootExport === "string" ? rootExport : rootExport?.import ?? rootExport?.default ?? pkg.module ?? pkg.main;
      if (typeof entry !== "string") throw new Error(`${packageName} has no import entry`);
      return path.resolve(packageDir, entry);
    }
    const parent = path.dirname(current);
    if (parent === current) break;
    current = parent;
  }
  throw new Error(`${packageName} could not be resolved from the installed hq CLI`);
}

async function enabled(dependencies = {}) {
  const env = dependencies.env ?? process.env;
  const endpoint = env.HQ_FLAGS_API_URL?.trim() || "";
  const companyUid = env.HQ_COMPANY_UID?.trim() || "";
  if (!endpoint || !/^cmp_[A-Za-z0-9]{3,128}$/.test(companyUid)) return DEFAULT_VALUE;

  const deadline = AbortSignal.timeout(REQUEST_TIMEOUT_MS);
  let client;
  let enabledValue = DEFAULT_VALUE;
  let failed = false;
  const reportFailure = (error) => {
    if (failed) return;
    failed = true;
    const name = error instanceof Error && /^[A-Za-z][A-Za-z0-9]{0,63}$/.test(error.name) ? error.name : "UnknownError";
    process.stderr.write(`work-mesh-project-offer: hq-flags lookup failed (${name}); using default-off behavior\n`);
  };
  try {
    let createClient = dependencies.createClient;
    let loadCachedTokens = dependencies.loadCachedTokens;
    if (!createClient || !loadCachedTokens) {
      const cliRoot = dependencies.cliRoot ?? findCliPackageRoot(env.HQ_CLI_BIN);
      if (!createClient) {
        const flagsPath = packageImportPath(cliRoot, "@indigoai-us/hq-flags-client");
        ({ createFlagClient: createClient } = await import(pathToFileURL(flagsPath).href));
      }
      if (!loadCachedTokens) {
        const cloudPath = packageImportPath(cliRoot, "@indigoai-us/hq-cloud");
        ({ loadCachedTokens } = await import(pathToFileURL(cloudPath).href));
      }
    }
    client = createClient({
      endpoint,
      companyUid,
      ...(env.HQ_COMPANY_SLUG?.trim() ? { companyIdentifiers: [env.HQ_COMPANY_SLUG.trim()] } : {}),
      env: {},
      getToken: () => loadCachedTokens()?.idToken ?? "",
      fetch: (input, init) => (dependencies.fetch ?? globalThis.fetch)(input, {
        ...init,
        signal: init?.signal ? AbortSignal.any([init.signal, deadline]) : deadline,
      }),
      refreshIntervalMs: 0,
      requestTimeoutMs: REQUEST_TIMEOUT_MS,
      onError: reportFailure,
    });
    await client.ready();
    const flags = client.snapshot()?.flags;
    enabledValue = !failed && !deadline.aborted && flags && typeof flags === "object" && flags[FLAG_KEY] === true;
  } catch (error) {
    reportFailure(error);
  } finally {
    try {
      client?.close();
    } catch (error) {
      reportFailure(error);
      enabledValue = DEFAULT_VALUE;
    }
  }
  return enabledValue;
}

module.exports = { FLAG_KEY, DEFAULT_VALUE, REQUEST_TIMEOUT_MS, findCliPackageRoot, packageImportPath, enabled };

if (require.main === module) {
  enabled().then((value) => process.stdout.write(value ? "true\n" : "false\n"))
    .catch(() => process.stdout.write(`${DEFAULT_VALUE}\n`));
}
