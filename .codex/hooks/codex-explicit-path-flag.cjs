#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { pathToFileURL } = require("node:url");

const FLAG_KEY = process.env.HQ_FLAG_KEY?.trim() || "hooks.codex-explicit-path-guard";
const DEFAULT_VALUE = false;
const REQUEST_TIMEOUT_MS = 1_000;
const TOTAL_TIMEOUT_MS = 2_000;
const TOKEN_TIMEOUT_MS = 750;
const COMPANY_UID_RE = /^cmp_[A-Za-z0-9]{3,128}$/;
const COMPANY_SLUG_RE = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;

function findCliBin(env) {
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
  if (dependencies.readBoundCompanySlug) return dependencies.readBoundCompanySlug(hqRoot);
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
  return result.stdout.trim() || undefined;
}

function readBoundCompanySlugs(hqRoot, env, dependencies) {
  if (dependencies.readBoundCompanySlugs) return dependencies.readBoundCompanySlugs(hqRoot);
  const sessionScript = path.join(hqRoot, "core/scripts/hq-session.sh");
  if (!fs.existsSync(sessionScript)) throw new Error("HQ session reader is unavailable");
  const result = spawnSync("bash", [sessionScript, "get", "company_slugs"], {
    cwd: hqRoot,
    encoding: "utf8",
    timeout: 500,
    env: { ...process.env, ...env, HQ_ROOT: hqRoot, CLAUDE_PROJECT_DIR: hqRoot, HQ_HQ_SESSION_NO_CLI: "1" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    // Older hq-session readers do not expose company_slugs. Falling back to
    // the primary is compatibility-safe: it cannot widen the company lock.
    const primary = readBoundCompanySlug(hqRoot, env, dependencies);
    return primary ? [primary] : [];
  }
  const slugs = result.stdout.trim().split(",").filter((slug) => COMPANY_SLUG_RE.test(slug));
  return [...new Set(slugs)];
}

function manifestCloudUid(hqRoot, slug) {
  const manifestPath = path.join(hqRoot, "companies", "manifest.yaml");
  if (!fs.existsSync(manifestPath)) return undefined;
  let inCompany = false;
  for (const line of fs.readFileSync(manifestPath, "utf8").split(/\r?\n/)) {
    const company = /^  ([^ #][^:]*):\s*$/.exec(line);
    if (company) {
      inCompany = company[1].trim() === slug;
      continue;
    }
    if (/^\S/.test(line)) inCompany = false;
    const uid = inCompany && /^    cloud_uid:\s*["']?([^"'\s#]+)/.exec(line);
    if (uid) return uid[1];
  }
  return undefined;
}

function companyUidForSlug(hqRoot, slug) {
  if (!slug || !COMPANY_SLUG_RE.test(slug)) return undefined;
  const uidPath = path.join(hqRoot, "companies", slug, ".company-uid");
  const uid = fs.existsSync(uidPath)
    ? fs.readFileSync(uidPath, "utf8").trim()
    : manifestCloudUid(hqRoot, slug);
  return uid && COMPANY_UID_RE.test(uid) ? uid : undefined;
}

function resolveCompanyContext(hqRoot, env, dependencies) {
  const explicitUid = env.HQ_COMPANY_UID?.trim() || "";
  if (COMPANY_UID_RE.test(explicitUid)) {
    const slug = env.HQ_COMPANY_SLUG?.trim() || "";
    const slugs = String(env.HQ_COMPANY_SLUGS || "").split(",").filter((item) => COMPANY_SLUG_RE.test(item));
    return {
      companyUid: explicitUid,
      ...(slugs.length ? { companyIdentifiers: [...new Set(slugs)] } : COMPANY_SLUG_RE.test(slug) ? { companyIdentifiers: [slug] } : {}),
    };
  }
  const slugs = readBoundCompanySlugs(hqRoot, env, dependencies);
  const slug = slugs[0] ?? readBoundCompanySlug(hqRoot, env, dependencies);
  const companyUid = companyUidForSlug(hqRoot, slug);
  return {
    ...(companyUid ? { companyUid } : {}),
    ...(companyUid && slugs.length ? { companyIdentifiers: slugs } : companyUid && slug ? { companyIdentifiers: [slug] } : {}),
  };
}

async function loadRuntimeModules(cliRoot) {
  const flagsPath = packageImportPath(cliRoot, "@indigoai-us/hq-flags-client");
  const cloudPath = packageImportPath(cliRoot, "@indigoai-us/hq-cloud");
  const tokenPath = path.join(cliRoot, "dist/lib/doctor/client-health-flag-token.js");
  const [flags, cloud] = await Promise.all([
    import(pathToFileURL(flagsPath).href),
    import(pathToFileURL(cloudPath).href),
  ]);
  let getClientHealthFlagToken;
  if (fs.existsSync(tokenPath)) {
    try {
      ({ getClientHealthFlagToken } = await import(pathToFileURL(tokenPath).href));
    } catch {
      // Older CLI packages may not ship this helper; use their cached token below.
    }
  }
  return { createClient: flags.createFlagClient, ...cloud, getClientHealthFlagToken };
}

function safeErrorClass(error) {
  const name = error instanceof Error ? error.name : "UnknownError";
  return /^[A-Za-z][A-Za-z0-9]{0,63}$/.test(name) ? name : "UnknownError";
}

function reportFailure(error) {
  process.stderr.write(
    `Codex explicit-path flag lookup failed (${safeErrorClass(error)}); using the default-off behavior.\n`,
  );
}

function combineSignals(...signals) {
  const present = signals.filter(Boolean);
  if (present.length === 1) return present[0];
  return AbortSignal.any(present);
}

function timeoutPromise(signal) {
  return new Promise((_resolve, reject) => {
    const rejectTimeout = () => reject(signal.reason ?? new Error("flag lookup timed out"));
    if (signal.aborted) rejectTimeout();
    else signal.addEventListener("abort", rejectTimeout, { once: true });
  });
}

async function codexExplicitPathGuardEnabled(dependencies = {}) {
  const env = dependencies.env ?? process.env;
  const overallDeadline = AbortSignal.timeout(TOTAL_TIMEOUT_MS);
  const timeout = timeoutPromise(overallDeadline);
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

  const readFlag = async () => {
    const cliBin = findCliBin(env);
    const cliRoot = dependencies.cliRoot ?? findCliPackageRoot(cliBin);
    const hqRoot = dependencies.hqRoot
      || env.HQ_ROOT?.trim()
      || env.CLAUDE_PROJECT_DIR?.trim()
      || process.cwd();
    const endpoint = await (dependencies.resolveEndpoint ?? resolveEndpoint)(env, cliRoot);
    const companyContext = resolveCompanyContext(hqRoot, env, dependencies);
    const runtime = await (dependencies.loadRuntimeModules ?? loadRuntimeModules)(cliRoot);
    if (overallDeadline.aborted) throw overallDeadline.reason;

    const createClient = dependencies.createClient ?? runtime.createClient;
    const loadTokens = dependencies.loadCachedTokens ?? runtime.loadCachedTokens;
    if (typeof createClient !== "function") throw new Error("hq-flags client is unavailable");

    let token;
    const getClientHealthFlagToken = dependencies.getClientHealthFlagToken ?? runtime.getClientHealthFlagToken;
    if (typeof getClientHealthFlagToken === "function") {
      try {
        token = await getClientHealthFlagToken(undefined, TOKEN_TIMEOUT_MS, overallDeadline);
      } catch {
        // Fall back to the cached CLI token for older clients or transient refresh failures.
      }
    }
    if (typeof token !== "string" || !token.trim()) token = loadTokens?.()?.idToken;
    if (typeof token !== "string" || !token.trim()) throw new Error("HQ identity token is unavailable");
    if (overallDeadline.aborted) throw overallDeadline.reason;

    let requestDeadline;
    const doFetch = dependencies.fetch ?? runtime.fetch ?? globalThis.fetch;
    client = createClient({
      endpoint,
      ...companyContext,
      env: {},
      getToken: () => token,
      fetch: (input, init) => doFetch(input, {
        ...init,
        signal: combineSignals(init?.signal, requestDeadline, overallDeadline),
      }),
      refreshIntervalMs: 0,
      requestTimeoutMs: REQUEST_TIMEOUT_MS,
      onError: reportFailureOnce,
    });
    requestDeadline = AbortSignal.timeout(REQUEST_TIMEOUT_MS);
    await client.ready();
    if (overallDeadline.aborted) throw overallDeadline.reason;
    if (requestDeadline.aborted) throw requestDeadline.reason;

    const snapshot = client.snapshot();
    const flags = snapshot?.flags && typeof snapshot.flags === "object" ? snapshot.flags : {};
    if (!failed && Object.prototype.hasOwnProperty.call(flags, FLAG_KEY)) {
      enabled = flags[FLAG_KEY] === true;
    }
  };

  try {
    await Promise.race([readFlag(), timeout]);
  } catch (error) {
    reportFailureOnce(error);
  } finally {
    try {
      client?.close();
    } catch (error) {
      reportFailureOnce(error);
    }
  }
  return !failed && !overallDeadline.aborted && enabled === true;
}

module.exports = {
  FLAG_KEY,
  DEFAULT_VALUE,
  REQUEST_TIMEOUT_MS,
  TOTAL_TIMEOUT_MS,
  findCliBin,
  findCliPackageRoot,
  packageImportPath,
  resolveEndpoint,
  readBoundCompanySlug,
  readBoundCompanySlugs,
  manifestCloudUid,
  companyUidForSlug,
  resolveCompanyContext,
  loadRuntimeModules,
  codexExplicitPathGuardEnabled,
};

if (require.main === module) {
  codexExplicitPathGuardEnabled()
    .then((enabled) => process.stdout.write(enabled ? "true\n" : "false\n"))
    .catch(() => process.stdout.write(`${DEFAULT_VALUE}\n`));
}
