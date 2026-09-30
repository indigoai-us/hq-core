#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { pathToFileURL } = require("node:url");

const FLAG_KEY = "hooks.hq-autocommit-bash-sweep";
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

function findCliBin(env = process.env) {
  if (env.HQ_CLI_BIN?.trim()) return env.HQ_CLI_BIN.trim();
  for (const directory of (env.PATH ?? "").split(path.delimiter)) {
    const candidate = path.join(directory, "hq");
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      return candidate;
    } catch {
      // Continue through PATH; absence is handled by findCliPackageRoot.
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

function readBoundCompanySlug(hqRoot, env, dependencies) {
  if (dependencies.readBoundCompanySlug) {
    return dependencies.readBoundCompanySlug(hqRoot);
  }
  const sessionScript = path.join(hqRoot, "core/scripts/hq-session.sh");
  if (!fs.existsSync(sessionScript)) throw new Error("HQ session reader is unavailable");
  const result = spawnSync("bash", [sessionScript, "get", "company_slug"], {
    cwd: hqRoot,
    encoding: "utf8",
    timeout: 500,
    env: {
      ...process.env,
      ...env,
      HQ_ROOT: hqRoot,
      CLAUDE_PROJECT_DIR: hqRoot,
      HQ_HQ_SESSION_NO_CLI: "1",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error("HQ session company lookup failed");
  const slug = result.stdout.trim();
  return slug || undefined;
}

function companyUidForSlug(hqRoot, slug) {
  if (!slug || !COMPANY_SLUG_RE.test(slug)) return undefined;
  const companyDir = path.join(hqRoot, "companies", slug);
  const uidPath = path.join(companyDir, ".company-uid");
  if (!fs.existsSync(uidPath)) return undefined;
  const uid = fs.readFileSync(uidPath, "utf8").trim();
  return COMPANY_UID_RE.test(uid) ? uid : undefined;
}

function resolveCompanyContext(env, hqRoot, dependencies) {
  const explicitUid = env.HQ_COMPANY_UID?.trim() || "";
  if (COMPANY_UID_RE.test(explicitUid)) {
    const slug = env.HQ_COMPANY_SLUG?.trim() || "";
    return {
      companyUid: explicitUid,
      ...(COMPANY_SLUG_RE.test(slug) ? { companyIdentifiers: [slug] } : {}),
    };
  }
  const slug = readBoundCompanySlug(hqRoot, env, dependencies);
  const companyUid = companyUidForSlug(hqRoot, slug);
  return {
    ...(companyUid ? { companyUid } : {}),
    ...(companyUid && slug ? { companyIdentifiers: [slug] } : {}),
  };
}

function safeErrorClass(error) {
  const name = error instanceof Error ? error.name : "UnknownError";
  return /^[A-Za-z][A-Za-z0-9]{0,63}$/.test(name) ? name : "UnknownError";
}

function reportFailure(error) {
  process.stderr.write(
    `HQ Bash-autocommit flag lookup failed (${safeErrorClass(error)}); using the default-off behavior.\n`,
  );
}

function combineSignals(first, second) {
  return first ? AbortSignal.any([first, second]) : second;
}

async function bashAutosaveSweepEnabled(dependencies = {}) {
  const env = dependencies.env ?? process.env;
  const deadline = AbortSignal.timeout(REQUEST_TIMEOUT_MS);
  const doFetch = dependencies.fetch ?? globalThis.fetch;
  let createClient = dependencies.createClient;
  let loadTokens = dependencies.loadCachedTokens;
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
    const hqRoot = dependencies.hqRoot
      || env.CLAUDE_PROJECT_DIR?.trim()
      || env.HQ_ROOT?.trim()
      || process.cwd();
    const cliRoot = dependencies.cliRoot ?? findCliPackageRoot(findCliBin(env));
    const endpoint = await resolveEndpoint(env, cliRoot);
    const companyContext = resolveCompanyContext(env, hqRoot, dependencies);
    if (!createClient || !loadTokens) {
      if (!createClient) {
        const flagsPath = packageImportPath(cliRoot, "@indigoai-us/hq-flags-client");
        ({ createFlagClient: createClient } = await import(pathToFileURL(flagsPath).href));
      }
      if (!loadTokens) {
        const cloudPath = packageImportPath(cliRoot, "@indigoai-us/hq-cloud");
        ({ loadCachedTokens: loadTokens } = await import(pathToFileURL(cloudPath).href));
      }
    }
    const token = loadTokens()?.idToken;
    if (typeof token !== "string" || !token.trim()) {
      throw new Error("cached ID token is unavailable");
    }
    client = createClient({
      endpoint,
      ...companyContext,
      env: {},
      getToken: () => token,
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
  findCliBin,
  resolveEndpoint,
  readBoundCompanySlug,
  companyUidForSlug,
  resolveCompanyContext,
  bashAutosaveSweepEnabled,
};

if (require.main === module) {
  bashAutosaveSweepEnabled()
    .then((enabled) => process.stdout.write(enabled ? "true\n" : "false\n"))
    .catch(() => process.stdout.write(`${DEFAULT_VALUE}\n`));
}
