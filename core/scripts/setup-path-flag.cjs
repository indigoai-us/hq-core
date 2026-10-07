#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { pathToFileURL } = require("node:url");

const FLAG_KEY = "core.setup-path-settings-local";
const DEFAULT_VALUE = false;
const REQUEST_TIMEOUT_MS = 150;
const SETUP_PATH_TIMEOUT_MS = 5000;

function safeErrorClass(error) {
  const name = error instanceof Error ? error.name : "UnknownError";
  return /^[A-Za-z][A-Za-z0-9]{0,63}$/.test(name) ? name : "UnknownError";
}

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

function reportFailure(error, context = "HQ setup PATH") {
  process.stderr.write(
    `${context} flag lookup failed (${safeErrorClass(error)}); using the default-off behavior.\n`,
  );
}

function getHqRoot(env) {
  return path.resolve(env.HQ_ROOT || path.join(__dirname, "..", ".."));
}

function resolveCompanyContext(env, hqRoot, timeoutMs) {
  const explicitUid = env.HQ_COMPANY_UID?.trim() || "";
  if (/^cmp_[A-Za-z0-9]{3,128}$/.test(explicitUid)) {
    return { companyUid: explicitUid };
  }

  const sessionScript = path.join(hqRoot, "core", "scripts", "hq-session.sh");
  if (!fs.existsSync(sessionScript)) return {};
  const result = spawnSync("bash", [sessionScript, "get", "company_slug"], {
    cwd: hqRoot,
    env: { ...env, HQ_ROOT: hqRoot, HQ_HQ_SESSION_NO_CLI: "1" },
    encoding: "utf8",
    timeout: timeoutMs,
    maxBuffer: 4096,
  });
  if (result.error || result.status !== 0) {
    throw result.error || new Error("bound company lookup failed");
  }
  const companySlug = result.stdout.trim();
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(companySlug)) return {};

  const uidFile = path.join(hqRoot, "companies", companySlug, ".company-uid");
  if (!fs.existsSync(uidFile)) return {};
  const companyUid = fs.readFileSync(uidFile, "utf8").trim();
  if (!/^cmp_[A-Za-z0-9]{3,128}$/.test(companyUid)) return {};
  return { companyUid, companySlug };
}

async function resolveEndpoint(cliRoot, env) {
  const configured = env.HQ_FLAGS_API_URL?.trim();
  if (configured) return configured;
  const endpointPath = path.join(cliRoot, "dist", "lib", "flag-registry-endpoint.js");
  const { FLAG_REGISTRY_DEFAULT_ENDPOINT } = await import(pathToFileURL(endpointPath).href);
  if (typeof FLAG_REGISTRY_DEFAULT_ENDPOINT !== "string" || !FLAG_REGISTRY_DEFAULT_ENDPOINT) {
    throw new Error("installed hq CLI default flag endpoint is unavailable");
  }
  return FLAG_REGISTRY_DEFAULT_ENDPOINT;
}

async function readHqFlag(
  flagKey,
  env = process.env,
  context = "HQ feature",
  { timeoutMs = REQUEST_TIMEOUT_MS } = {},
) {
  const deadline = AbortSignal.timeout(timeoutMs);
  let client;
  let failed = false;
  let failureReported = false;
  const reportOnce = (error) => {
    if (failureReported) return;
    failureReported = true;
    reportFailure(error, context);
  };
  try {
    const cliRoot = findCliPackageRoot(env.HQ_CLI_BIN || "");
    const endpoint = await resolveEndpoint(cliRoot, env);
    const hqRoot = getHqRoot(env);
    const company = resolveCompanyContext(env, hqRoot, timeoutMs);
    const flagsPath = packageImportPath(cliRoot, "@indigoai-us/hq-flags-client");
    const cloudPath = packageImportPath(cliRoot, "@indigoai-us/hq-cloud");
    const [{ createFlagClient }, { loadCachedTokens }] = await Promise.all([
      import(pathToFileURL(flagsPath).href),
      import(pathToFileURL(cloudPath).href),
    ]);
    let token = loadCachedTokens()?.idToken ?? "";
    if (!token) {
      // `hq whoami` uses this CLI loader for the machine identity. Keep token
      // acquisition cached and noninteractive on this short setup path.
      const sessionPath = path.join(cliRoot, "dist", "utils", "cognito-session.js");
      const { loadMachineCachedTokens } = await import(pathToFileURL(sessionPath).href);
      token = loadMachineCachedTokens()?.idToken ?? "";
    }
    if (typeof token !== "string" || token.length === 0) return DEFAULT_VALUE;
    client = createFlagClient({
      endpoint,
      ...(company.companyUid ? { companyUid: company.companyUid } : {}),
      ...(company.companySlug ? { companyIdentifiers: [company.companySlug] } : {}),
      env: {},
      getToken: () => token,
      fetch: (input, init) => globalThis.fetch(input, {
        ...init,
        signal: AbortSignal.any([init?.signal, deadline].filter(Boolean)),
      }),
      refreshIntervalMs: 0,
      requestTimeoutMs: timeoutMs,
      onError: (error) => {
        failed = true;
        reportOnce(error);
      },
    });
    await client.ready();
    const flags = client.snapshot()?.flags;
    if (deadline.aborted || failed || !flags || typeof flags !== "object") return DEFAULT_VALUE;
    return flags[flagKey] === true;
  } catch (error) {
    reportOnce(error);
    return DEFAULT_VALUE;
  } finally {
    try {
      client?.close();
    } catch (error) {
      reportOnce(error);
    }
  }
}

async function setupPathFlagEnabled(env = process.env) {
  return readHqFlag(FLAG_KEY, env, "HQ setup PATH", { timeoutMs: SETUP_PATH_TIMEOUT_MS });
}

if (require.main === module) {
  setupPathFlagEnabled()
    .then((enabled) => process.stdout.write(enabled ? "true\n" : "false\n"))
    .catch((error) => {
      reportFailure(error);
      process.stdout.write(`${DEFAULT_VALUE}\n`);
    });
}

module.exports = { FLAG_KEY, DEFAULT_VALUE, REQUEST_TIMEOUT_MS, readHqFlag, setupPathFlagEnabled };
