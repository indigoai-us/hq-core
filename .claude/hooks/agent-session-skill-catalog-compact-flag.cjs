#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { pathToFileURL } = require("node:url");

const FLAG_KEY = "core.agent-session-skill-catalog-compact";
const DEFAULT_VALUE = false;
const REQUEST_TIMEOUT_MS = 150;
const COMPANY_UID_RE = /^cmp_[A-Za-z0-9]{3,128}$/;
const COMPANY_SLUG_RE = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;

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

function findCliBin(env = process.env) {
  if (env.HQ_CLI_BIN?.trim()) return env.HQ_CLI_BIN.trim();
  for (const directory of (env.PATH ?? "").split(path.delimiter)) {
    const candidate = path.join(directory, "hq");
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      return candidate;
    } catch {
      // Keep searching; the caller reports a bounded, safe failure.
    }
  }
  return "";
}

async function resolveEndpoint(env, cliRoot) {
  const configured = env.HQ_FLAGS_API_URL?.trim() || "";
  if (configured) return configured;
  const endpointModule = path.join(cliRoot, "dist/lib/flag-registry-endpoint.js");
  const imported = await import(pathToFileURL(endpointModule).href);
  const endpoint = imported.FLAG_REGISTRY_DEFAULT_ENDPOINT;
  if (typeof endpoint !== "string" || !endpoint.trim()) {
    throw new Error("hq CLI flag registry default endpoint is missing");
  }
  return endpoint.trim();
}

function companyUid(root, slug) {
  if (!COMPANY_SLUG_RE.test(slug)) return "";
  const uidFile = path.join(root, "companies", slug, ".company-uid");
  if (!fs.existsSync(uidFile)) return "";
  const value = fs.readFileSync(uidFile, "utf8").trim();
  return COMPANY_UID_RE.test(value) ? value : "";
}

function reportFailure(error) {
  const name = error instanceof Error ? error.name : "UnknownError";
  const safeName = /^[A-Za-z][A-Za-z0-9]{0,63}$/.test(name) ? name : "UnknownError";
  process.stderr.write(`hq-agent-session: skill catalog flag lookup failed (${safeName}); using default-off behavior.\n`);
}

async function compactSkillCatalogEnabled(dependencies = {}) {
  const env = dependencies.env ?? process.env;
  const root = dependencies.root ?? env.HQ_ROOT ?? "";
  const slug = dependencies.companySlug ?? env.HQ_COMPANY_SLUG ?? "";
  const uid = companyUid(root, slug);
  if (!root || !uid) return DEFAULT_VALUE;

  const deadline = AbortSignal.timeout(REQUEST_TIMEOUT_MS);
  const doFetch = dependencies.fetch ?? globalThis.fetch;
  let createClient = dependencies.createClient;
  let loadCachedTokens = dependencies.loadCachedTokens;
  let client;
  let enabled = DEFAULT_VALUE;
  let failed = false;
  const reportOnce = (error) => {
    if (failed) return;
    failed = true;
    (dependencies.reportError ?? reportFailure)(error);
  };

  try {
    const cliRoot = dependencies.cliRoot ?? findCliPackageRoot(findCliBin(env));
    if (!createClient) {
      const flagsPath = packageImportPath(cliRoot, "@indigoai-us/hq-flags-client");
      ({ createFlagClient: createClient } = await import(pathToFileURL(flagsPath).href));
    }
    if (!loadCachedTokens) {
      const cloudPath = packageImportPath(cliRoot, "@indigoai-us/hq-cloud");
      ({ loadCachedTokens } = await import(pathToFileURL(cloudPath).href));
    }
    client = createClient({
      endpoint: await resolveEndpoint(env, cliRoot),
      companyUid: uid,
      companyIdentifiers: [slug],
      env: {},
      getToken: () => loadCachedTokens()?.idToken ?? "",
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

module.exports = {
  FLAG_KEY,
  DEFAULT_VALUE,
  REQUEST_TIMEOUT_MS,
  compactSkillCatalogEnabled,
};

if (require.main === module) {
  compactSkillCatalogEnabled()
    .then((enabled) => process.stdout.write(enabled ? "true\n" : "false\n"))
    .catch((error) => {
      reportFailure(error);
      process.stdout.write(`${DEFAULT_VALUE}\n`);
    });
}
