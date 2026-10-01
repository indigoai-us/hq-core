#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { pathToFileURL } = require("node:url");

const FLAG_KEY = "hooks.company-skill-slug-fallback";
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
      const rootExport = typeof packageJson.exports === "string" ? packageJson.exports : packageJson.exports?.["."];
      const entry = typeof rootExport === "string" ? rootExport : rootExport?.import ?? rootExport?.default ?? packageJson.module ?? packageJson.main;
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
  const doFetch = dependencies.fetch ?? globalThis.fetch;
  let client;
  let flagEnabled = DEFAULT_VALUE;
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
    const slug = env.HQ_COMPANY_SLUG?.trim() || "";
    client = createClient({
      endpoint,
      companyUid,
      ...(slug && /^[A-Za-z0-9][A-Za-z0-9-]{0,63}$/.test(slug) ? { companyIdentifiers: [slug] } : {}),
      env: {},
      getToken: () => loadCachedTokens()?.idToken ?? "",
      fetch: (input, init) => doFetch(input, {
        ...init,
        signal: init?.signal ? AbortSignal.any([init.signal, deadline]) : deadline,
      }),
      refreshIntervalMs: 0,
      requestTimeoutMs: REQUEST_TIMEOUT_MS,
    });
    await client.ready();
    const flags = client.snapshot()?.flags;
    flagEnabled = !deadline.aborted && flags && typeof flags === "object" && flags[FLAG_KEY] === true;
  } catch (error) {
    const name = error instanceof Error && /^[A-Za-z][A-Za-z0-9]{0,63}$/.test(error.name) ? error.name : "UnknownError";
    process.stderr.write(`auto-mirror: hq-flags lookup failed (${name}); slug fallback remains off\n`);
    flagEnabled = DEFAULT_VALUE;
  } finally {
    try {
      client?.close();
    } catch (error) {
      const name = error instanceof Error && /^[A-Za-z][A-Za-z0-9]{0,63}$/.test(error.name) ? error.name : "UnknownError";
      process.stderr.write(`auto-mirror: hq-flags client close failed (${name}); slug fallback remains off\n`);
      flagEnabled = DEFAULT_VALUE;
    }
  }
  return flagEnabled;
}

module.exports = { FLAG_KEY, DEFAULT_VALUE, REQUEST_TIMEOUT_MS, findCliPackageRoot, packageImportPath, enabled };

if (require.main === module) {
  enabled().then((value) => process.stdout.write(value ? "true\n" : "false\n"))
    .catch(() => process.stdout.write(`${DEFAULT_VALUE}\n`));
}
