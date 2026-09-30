#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { pathToFileURL } = require("node:url");

const FLAG_KEY = "hooks.hq-autocommit-failure-context";
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
  const packageParts = packageName.split("/");
  for (let depth = 0; depth < 16; depth += 1) {
    const packageDir = path.join(current, "node_modules", ...packageParts);
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

function safeErrorClass(error) {
  const name = error instanceof Error ? error.name : "UnknownError";
  return /^[A-Za-z][A-Za-z0-9]{0,63}$/.test(name) ? name : "UnknownError";
}

function reportFailure(error) {
  process.stderr.write(
    `HQ autocommit failure-context flag lookup failed (${safeErrorClass(error)}); using default-off behavior.\n`,
  );
}

function combineSignals(first, second) {
  return first ? AbortSignal.any([first, second]) : second;
}

async function failureContextEnabled(dependencies = {}) {
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
  let failureReported = false;
  const reportFailureOnce = (error) => {
    failed = true;
    if (failureReported) return;
    failureReported = true;
    (dependencies.reportError ?? reportFailure)(error);
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
      ...(env.HQ_COMPANY_SLUG?.trim() && /^[A-Za-z0-9][A-Za-z0-9-]{0,63}$/.test(env.HQ_COMPANY_SLUG.trim())
        ? { companyIdentifiers: [env.HQ_COMPANY_SLUG.trim()] }
        : {}),
      env: {},
      getToken: () => loadCachedTokens()?.idToken ?? "",
      fetch: (input, init) => doFetch(input, {
        ...init,
        signal: combineSignals(init?.signal ?? undefined, deadline),
      }),
      refreshIntervalMs: 0,
      requestTimeoutMs: REQUEST_TIMEOUT_MS,
      onError: reportFailureOnce,
    });
    await client.ready();
    const snapshot = client.snapshot();
    const flags = snapshot?.flags && typeof snapshot.flags === "object" ? snapshot.flags : {};
    if (!deadline.aborted && !failed && Object.prototype.hasOwnProperty.call(flags, FLAG_KEY)) {
      enabled = flags[FLAG_KEY] === true;
    } else if (deadline.aborted) {
      reportFailureOnce(deadline.reason ?? new Error("flag lookup timed out"));
    }
  } catch (error) {
    reportFailureOnce(error);
  } finally {
    try {
      client?.close();
    } catch (error) {
      reportFailureOnce(error);
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
  failureContextEnabled,
};

if (require.main === module) {
  failureContextEnabled()
    .then((enabled) => process.stdout.write(enabled ? "true\n" : "false\n"))
    .catch(() => process.stdout.write(`${DEFAULT_VALUE}\n`));
}
