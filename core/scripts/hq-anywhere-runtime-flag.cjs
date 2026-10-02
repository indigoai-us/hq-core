#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { pathToFileURL } = require("node:url");

const FLAG_KEY = "hq-anywhere-runtime";
const DEFAULT_VALUE = false;
const REQUEST_TIMEOUT_MS = 150;

function findCliPackageRoot(cliBin) {
  if (!cliBin) {
    for (const dir of (process.env.PATH || "").split(path.delimiter)) {
      const candidate = path.join(dir || ".", "hq");
      try { fs.accessSync(candidate, fs.constants.X_OK); cliBin = candidate; break; } catch {}
    }
  }
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
  const parts = packageName.split("/");
  for (let depth = 0; depth < 16; depth += 1) {
    const packageDir = path.join(current, "node_modules", ...parts);
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

function reportFailure(error) {
  const name = error instanceof Error ? error.name : "UnknownError";
  const safeName = /^[A-Za-z][A-Za-z0-9]{0,63}$/.test(name) ? name : "UnknownError";
  process.stderr.write(`hq-anywhere-runtime flag lookup failed (${safeName}); using default-off behavior.\n`);
}

async function anywhereRuntimeEnabled(dependencies = {}) {
  const env = dependencies.env ?? process.env;
  const endpoint = env.HQ_FLAGS_API_URL?.trim() || "";
  const companyUid = env.HQ_COMPANY_UID?.trim() || "";
  if (!endpoint || !/^cmp_[A-Za-z0-9]{3,128}$/.test(companyUid)) return DEFAULT_VALUE;

  const deadline = AbortSignal.timeout(REQUEST_TIMEOUT_MS);
  const doFetch = dependencies.fetch ?? globalThis.fetch;
  const createClient = dependencies.createClient;
  const loadCachedTokens = dependencies.loadCachedTokens;
  let client;
  let enabled = DEFAULT_VALUE;
  let failed = false;
  const reportOnce = (error) => {
    if (failed) return;
    failed = true;
    (dependencies.reportError ?? reportFailure)(error);
  };

  try {
    let makeClient = createClient;
    let loadTokens = loadCachedTokens;
    if (!makeClient || !loadTokens) {
      const cliRoot = dependencies.cliRoot ?? findCliPackageRoot(env.HQ_FLAG_CLI_BIN || env.HQ_CLI_BIN);
      if (!makeClient) {
        const flagsPath = packageImportPath(cliRoot, "@indigoai-us/hq-flags-client");
        ({ createFlagClient: makeClient } = await import(pathToFileURL(flagsPath).href));
      }
      if (!loadTokens) {
        const cloudPath = packageImportPath(cliRoot, "@indigoai-us/hq-cloud");
        ({ loadCachedTokens: loadTokens } = await import(pathToFileURL(cloudPath).href));
      }
    }
    client = makeClient({
      endpoint,
      companyUid,
      ...(env.HQ_COMPANY_SLUG?.trim() ? { companyIdentifiers: [env.HQ_COMPANY_SLUG.trim()] } : {}),
      env: {},
      getToken: () => loadTokens()?.idToken ?? "",
      fetch: (input, init) => doFetch(input, {
        ...init,
        signal: init?.signal ? AbortSignal.any([init.signal, deadline]) : deadline,
      }),
      refreshIntervalMs: 0,
      requestTimeoutMs: REQUEST_TIMEOUT_MS,
      onError: reportOnce,
    });
    await client.ready();
    const flags = client.snapshot()?.flags;
    if (!deadline.aborted && !failed && flags && typeof flags === "object") {
      enabled = flags[FLAG_KEY] === true;
    } else if (deadline.aborted) {
      reportOnce(deadline.reason ?? new Error("flag lookup timed out"));
    }
  } catch (error) {
    reportOnce(error);
  } finally {
    try {
      client?.close();
    } catch (error) {
      reportOnce(error);
    }
  }
  return !failed && !deadline.aborted && enabled === true;
}

module.exports = { FLAG_KEY, DEFAULT_VALUE, REQUEST_TIMEOUT_MS, anywhereRuntimeEnabled };

if (require.main === module) {
  anywhereRuntimeEnabled()
    .then((enabled) => process.stdout.write(enabled ? "true" : "false"))
    .catch((error) => {
      reportFailure(error);
      process.stdout.write("false");
    });
}
