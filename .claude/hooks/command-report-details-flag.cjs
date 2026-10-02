#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { pathToFileURL } = require("node:url");

// The flag stays off in code until the lead enables it through hq-flags.
const FLAG_KEY = "output.command-report-details-expandable";
const DEFAULT_VALUE = false;
const REQUEST_TIMEOUT_MS = 150;

function findCliPackageRoot(cliBin) {
  if (!cliBin) throw new Error("hq CLI binary was not found on PATH");
  let current = fs.realpathSync(cliBin);
  if (!fs.statSync(current).isDirectory()) current = path.dirname(current);
  for (let depth = 0; depth < 16; depth += 1) {
    const manifest = path.join(current, "package.json");
    if (fs.existsSync(manifest)) {
      const packageJson = JSON.parse(fs.readFileSync(manifest, "utf8"));
      if (packageJson.name === "@indigoai-us/hq-cli") return current;
    }
    const parent = path.dirname(current);
    if (parent === current) break;
    current = parent;
  }
  throw new Error("installed hq CLI package could not be resolved");
}

function packageImportPath(cliRoot, packageName) {
  let current = cliRoot;
  for (let depth = 0; depth < 16; depth += 1) {
    const packageDir = path.join(current, "node_modules", ...packageName.split("/"));
    const manifest = path.join(packageDir, "package.json");
    if (fs.existsSync(manifest)) {
      const packageJson = JSON.parse(fs.readFileSync(manifest, "utf8"));
      const rootExport = typeof packageJson.exports === "string"
        ? packageJson.exports
        : packageJson.exports?.["."];
      const entry = typeof rootExport === "string"
        ? rootExport
        : rootExport?.import ?? rootExport?.default ?? packageJson.module ?? packageJson.main;
      if (typeof entry !== "string") throw new Error(`${packageName} has no import entry`);
      return path.resolve(packageDir, entry);
    }
    const parent = path.dirname(current);
    if (parent === current) break;
    current = parent;
  }
  throw new Error(`${packageName} could not be resolved from the installed hq CLI`);
}

async function commandReportDetailsEnabled(dependencies = {}) {
  const env = dependencies.env ?? process.env;
  const endpoint = env.HQ_FLAGS_API_URL?.trim() || "";
  const companyUid = env.HQ_COMPANY_UID?.trim() || "";
  if (!endpoint || !/^cmp_[A-Za-z0-9]{3,128}$/.test(companyUid)) return DEFAULT_VALUE;

  const deadline = AbortSignal.timeout(REQUEST_TIMEOUT_MS);
  const doFetch = dependencies.fetch ?? globalThis.fetch;
  let createClient = dependencies.createClient;
  let loadCachedTokens = dependencies.loadCachedTokens;
  let client;
  let enabled = DEFAULT_VALUE;
  let failed = false;
  const reportFailure = (error) => {
    if (failed) return;
    failed = true;
    const name = error instanceof Error && /^[A-Za-z][A-Za-z0-9]{0,63}$/.test(error.name)
      ? error.name
      : "UnknownError";
    (dependencies.reportError ?? ((safeName) => {
      process.stderr.write(`command-report details flag lookup failed (${safeName}); using the default-off behavior.\n`);
    }))(name);
  };

  try {
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
      fetch: (input, init) => doFetch(input, {
        ...init,
        signal: init?.signal ? AbortSignal.any([init.signal, deadline]) : deadline,
      }),
      refreshIntervalMs: 0,
      requestTimeoutMs: REQUEST_TIMEOUT_MS,
      onError: reportFailure,
    });
    await client.ready();
    const flags = client.snapshot()?.flags;
    if (!deadline.aborted && !failed && flags && typeof flags === "object") {
      enabled = flags[FLAG_KEY] === true;
    }
  } catch (error) {
    reportFailure(error);
  } finally {
    try {
      client?.close();
    } catch (error) {
      reportFailure(error);
    }
  }
  return !failed && !deadline.aborted && enabled === true;
}

module.exports = {
  FLAG_KEY,
  DEFAULT_VALUE,
  REQUEST_TIMEOUT_MS,
  findCliPackageRoot,
  packageImportPath,
  commandReportDetailsEnabled,
};

if (require.main === module) {
  commandReportDetailsEnabled()
    .then((enabled) => process.stdout.write(enabled ? "true\n" : "false\n"))
    .catch(() => process.stdout.write(`${DEFAULT_VALUE}\n`));
}
