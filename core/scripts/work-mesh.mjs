#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const ACTIVE_STATUSES = new Set(["open", "claimed", "in-progress", "blocked", "needs-human"]);
const EVENT_STATUS = new Map([
  ["claim", "claimed"],
  ["progress", "in-progress"],
  ["blocked", "blocked"],
  ["done", "done"],
]);
const REALTIME_V2_RESPONSE_KEYS = [
  "contractVersion", "credentials", "iotEndpoint", "region", "clientId", "topic", "topics", "expiresAt",
];
const REALTIME_CREDENTIAL_KEYS = ["accessKeyId", "secretAccessKey", "sessionToken", "expiration"];
const REALTIME_TOPIC_KEYS = ["dm", "sessions", "work", "notifications"];
const REALTIME_V1_RESPONSE_KEYS = ["credentials", "iotEndpoint", "region", "topic", "topics", "expiresAt"];
const REALTIME_V1_COMPANY_TOPIC_KEYS = ["companyUid", "threadTopicFilter", "presenceTopic"];
const REALTIME_V2_CLIENT_ID_PATTERN = /^rt2-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const REALTIME_PRINCIPAL_PATTERN = /^(?:prs|agt)_[0-9A-HJKMNP-TV-Z]{26}$/;
const REALTIME_COMPANY_PATTERN = /^cmp_[A-Za-z0-9_-]{1,123}$/;
const REALTIME_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;
const REALTIME_EVENT_TYPE_PATTERN = /^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$/;
const REALTIME_ENVELOPE_KEYS = [
  "contractVersion", "eventId", "eventType", "scope", "resourceId", "recipientUid", "createdAt",
];
const WORK_FEED_KEYS = [
  "contractVersion", "snapshot", "reset", "cursor", "cursorExpiresAt", "removedCompanyUids", "open", "changed",
];
const MAX_REALTIME_ENVELOPE_BYTES = 1024;
const MAX_REALTIME_CONFIG_BYTES = 64 * 1024;
const MAX_WORK_FEED_BYTES = 16 * 1024 * 1024;
const MAX_WORK_FEED_THREADS = 20_000;
const MAX_LOCAL_JSON_BYTES = 32 * 1024 * 1024;
const MAX_V1_COMPANY_TOPICS = 100;
const require = createRequire(import.meta.url);

class WorkMeshHttpError extends Error {
  constructor(message, status, retryable = false, code, supportedContractVersions = []) {
    super(message);
    this.name = "WorkMeshHttpError";
    this.status = status;
    this.retryable = retryable;
    this.code = typeof code === "string" ? code : undefined;
    this.supportedContractVersions = Array.isArray(supportedContractVersions)
      ? supportedContractVersions.filter(Number.isSafeInteger)
      : [];
  }
}

class WorkMeshContractError extends Error {
  constructor(message) {
    super(message);
    this.name = "WorkMeshContractError";
  }
}

function usage() {
  return `Usage: core/scripts/work-mesh.sh <command> [options]

Commands:
  check      Show active work-mesh threads for a company/project
  start      Ensure a project thread exists and claim/report start
  progress   Append a progress event to the project thread
  blocked    Append a blocked event to the project thread
  done       Append a done event to the project thread
  note       Append a note event to the project thread
  watch      Subscribe to work-mesh MQTT topics and update local live cache

Options:
  --company <slug|uid>     Company slug or cloud uid
  --project <slug>         HQ project slug / projectId
  --summary <text>         Progress/done/creation summary
  --reason <text>          Blocked reason
  --ask <text>             Repeatable blocked ask
  --thread-id <id>         Explicit work thread id
  --priority <level>       critical|high|normal|low (default: normal)
  --lane <lane>            Routing lane, e.g. engineering
  --tag <tag>              Repeatable routing tag
  --capability <name>      Repeatable routing capability
  --json                   Print machine-readable JSON
  --silent                 Suppress human-readable output
  --dry-run                Resolve inputs without writing
  --once                   For watch: exit after the first MQTT message
  --timeout-ms <ms>        For watch: exit after this many milliseconds
  --cache-file <path>      For watch/check: live cache path

Environment:
  HQ_WORK_MESH_DISABLED=1      Disable and exit 0
  HQ_WORK_MESH_API_URL=<url>   Override hq-pro API base URL
  HQ_VAULT_API_URL=<url>       Fallback hq-pro API base URL
  HQ_API_URL=<url>             Fallback hq-pro API base URL
  HQ_PRO_API_URL=<url>         Fallback hq-pro API base URL
  HQ_WORK_MESH_TOKEN=<jwt>     Use a non-refreshable bearer token instead of HQ auth cache
  HQ_WORK_MESH_STRICT=1        Return non-zero on auth/network/API failures
  HQ_WORK_MESH_MQTT_MODULE=<path|name>  MQTT module override for watch
`;
}

function parseArgs(argv) {
  const opts = {
    command: undefined,
    tags: [],
    capabilities: [],
    skills: [],
    asks: [],
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!opts.command && !arg.startsWith("-")) {
      opts.command = arg;
      continue;
    }

    const eq = arg.match(/^--([^=]+)=(.*)$/);
    if (eq) {
      setOption(opts, eq[1], eq[2]);
      continue;
    }

    if (arg.startsWith("--")) {
      const key = arg.slice(2);
      if (["json", "silent", "dry-run", "help", "once"].includes(key)) {
        setOption(opts, key, true);
      } else {
        i += 1;
        setOption(opts, key, argv[i] ?? "");
      }
      continue;
    }

    if (!opts.project) {
      opts.project = arg;
    }
  }

  opts.command ??= "check";
  return opts;
}

function setOption(opts, key, value) {
  const normalized = key.replace(/-/g, "_");
  if (normalized === "tag") opts.tags.push(String(value));
  else if (normalized === "tags") opts.tags.push(...String(value).split(","));
  else if (normalized === "capability") opts.capabilities.push(String(value));
  else if (normalized === "capabilities") opts.capabilities.push(...String(value).split(","));
  else if (normalized === "skill") opts.skills.push(String(value));
  else if (normalized === "skills") opts.skills.push(...String(value).split(","));
  else if (normalized === "ask") opts.asks.push(String(value));
  else opts[normalized] = value;
}

function compact(value) {
  if (Array.isArray(value)) {
    const arr = value.map(compact).filter((item) => item !== undefined);
    return arr.length > 0 ? arr : undefined;
  }
  if (value && typeof value === "object") {
    const out = {};
    for (const [key, child] of Object.entries(value)) {
      const cleaned = compact(child);
      if (cleaned !== undefined) out[key] = cleaned;
    }
    return Object.keys(out).length > 0 ? out : undefined;
  }
  if (typeof value === "string") {
    const trimmed = value.trim();
    return trimmed.length > 0 ? trimmed : undefined;
  }
  if (value === null || value === undefined) return undefined;
  return value;
}

function clamp(text, max) {
  const value = String(text ?? "").replace(/\s+/g, " ").trim();
  if (value.length <= max) return value;
  return `${value.slice(0, Math.max(0, max - 1)).trim()}...`;
}

function dedupe(values) {
  return [...new Set(values.map((value) => String(value).trim()).filter(Boolean))];
}

function normalizeCommand(command) {
  if (command === "status") return "check";
  if (command === "report") return "progress";
  if (command === "finish" || command === "complete" || command === "completed") return "done";
  return command;
}

function isTruthyEnv(name) {
  return ["1", "true", "yes", "on"].includes(String(process.env[name] ?? "").toLowerCase());
}

function redactedDiagnostic(detail, secrets = []) {
  let output = String(detail ?? "");
  for (const secret of [process.env.HQ_WORK_MESH_TOKEN, ...secrets]) {
    if (typeof secret === "string" && secret.length >= 8) output = output.split(secret).join("[redacted]");
  }
  output = output
    .replace(/wss:\/\/[^\s)"']+/gi, "[redacted signed URL]")
    .replace(/\bBearer\s+[^\s,)"']+/gi, "Bearer [redacted]")
    .replace(/\b(?:AKIA|ASIA)[A-Z0-9]{12,}\b/g, "[redacted access key]")
    .replace(/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/g, "[redacted token]")
    .replace(/([?&](?:X-Amz-(?:Credential|Signature|Security-Token)|token)=)[^&\s]+/gi, "$1[redacted]");
  return clamp(output, 500);
}

function failSoft(opts, reason, detail, secrets = []) {
  const safeDetail = detail ? redactedDiagnostic(detail, secrets) : undefined;
  if (opts.json) {
    console.log(JSON.stringify({ ok: false, skipped: true, reason, detail: safeDetail }));
  } else if (!opts.silent && isTruthyEnv("HQ_WORK_MESH_DEBUG")) {
    console.error(`work-mesh skipped: ${reason}${safeDetail ? ` (${safeDetail})` : ""}`);
  }
  if (isTruthyEnv("HQ_WORK_MESH_STRICT")) process.exitCode = 1;
}

function resolveHqRoot() {
  if (process.env.HQ_ROOT) return path.resolve(process.env.HQ_ROOT);
  let cur = process.cwd();
  while (cur !== path.dirname(cur)) {
    if (
      fs.existsSync(path.join(cur, "companies")) &&
      (fs.existsSync(path.join(cur, "core", "core.yaml")) || fs.existsSync(path.join(cur, "core.yaml")))
    ) {
      return cur;
    }
    cur = path.dirname(cur);
  }
  return process.cwd();
}

function stateFileFor(companyRef, projectId) {
  const root = resolveHqRoot();
  const safeCompany = safeName(companyRef || "unknown-company");
  const safeProject = safeName(projectId || "unknown-project");
  return path.join(root, "workspace", "work-mesh", safeCompany, `${safeProject}.json`);
}

function liveCacheFile(opts = {}) {
  if (opts.cache_file) return path.resolve(String(opts.cache_file));
  return path.join(resolveHqRoot(), "workspace", "work-mesh", "live-cache.json");
}

function safeName(value) {
  return String(value).replace(/[^A-Za-z0-9_.-]+/g, "-").replace(/^-+|-+$/g, "") || "unknown";
}

function readJson(file) {
  let fd;
  try {
    fd = fs.openSync(file, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0));
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || stat.size > MAX_LOCAL_JSON_BYTES) return null;
    return JSON.parse(fs.readFileSync(fd, "utf8"));
  } catch {
    return null;
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

function canonicalDestination(file) {
  const directory = path.dirname(path.resolve(file));
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const destination = path.join(fs.realpathSync(directory), path.basename(file));
  try {
    const stat = fs.lstatSync(destination);
    if (!stat.isFile() || stat.isSymbolicLink()) {
      throw new Error("Work Mesh cache destination must be a regular file");
    }
  } catch (err) {
    if (err?.code !== "ENOENT") throw err;
  }
  return destination;
}

function writeJson(file, value) {
  const destination = canonicalDestination(file);
  const temporary = `${destination}.tmp-${process.pid}-${crypto.randomBytes(6).toString("hex")}`;
  try {
    fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { flag: "wx", mode: 0o600 });
    fs.renameSync(temporary, destination);
  } finally {
    try {
      fs.unlinkSync(temporary);
    } catch (err) {
      if (err?.code !== "ENOENT") throw err;
    }
  }
}

function acquireCacheLock(opts = {}) {
  const destination = `${canonicalDestination(liveCacheFile(opts))}.watch.lock`;
  try {
    fs.mkdirSync(destination, { mode: 0o700 });
  } catch (err) {
    if (err?.code !== "EEXIST") throw err;
    const stat = fs.lstatSync(destination);
    if (!stat.isDirectory() || stat.isSymbolicLink()) {
      throw new Error("Work Mesh cache lock path must be a directory");
    }
  }
  fs.chmodSync(destination, 0o700);

  const nonce = crypto.randomBytes(16).toString("hex");
  const startedOrder = process.hrtime.bigint().toString().padStart(20, "0");
  const ownerName = `${startedOrder}-${String(process.pid).padStart(10, "0")}-${nonce}.json`;
  const ownerFile = path.join(destination, ownerName);
  writeJson(ownerFile, {
    version: 1,
    pid: process.pid,
    nonce,
    startedAt: new Date().toISOString(),
  });

  const cleanupOwner = () => {
    try {
      fs.unlinkSync(ownerFile);
    } catch (err) {
      if (err?.code !== "ENOENT") throw err;
    }
    try {
      fs.rmdirSync(destination);
    } catch (err) {
      if (!["ENOENT", "ENOTEMPTY", "EEXIST"].includes(err?.code)) throw err;
    }
  };

  try {
    const liveOwners = [];
    for (const name of fs.readdirSync(destination).filter((entry) => entry.endsWith(".json")).sort()) {
      const file = path.join(destination, name);
      const held = readJson(file);
      if (
        held?.version !== 1 ||
        !Number.isSafeInteger(held.pid) || held.pid <= 0 ||
        typeof held.nonce !== "string" || held.nonce.length !== 32
      ) throw new Error("Work Mesh cache lock is invalid");
      if (name === ownerName) {
        liveOwners.push({ name, pid: held.pid });
        continue;
      }
      try {
        process.kill(held.pid, 0);
        liveOwners.push({ name, pid: held.pid });
      } catch (probeError) {
        if (probeError?.code === "EPERM") {
          liveOwners.push({ name, pid: held.pid });
          continue;
        }
        if (probeError?.code !== "ESRCH") throw probeError;
        try {
          fs.unlinkSync(file);
        } catch (unlinkError) {
          if (unlinkError?.code !== "ENOENT") throw unlinkError;
        }
      }
    }

    const sameProcessOwner = liveOwners.some((owner) => owner.name !== ownerName && owner.pid === process.pid);
    const electedOwner = liveOwners.map((owner) => owner.name).sort()[0];
    if (sameProcessOwner || electedOwner !== ownerName) {
      throw new Error("another Work Mesh watcher owns this cache");
    }
    return cleanupOwner;
  } catch (err) {
    cleanupOwner();
    throw err;
  }
}

async function readBoundedResponseText(response, maxBytes) {
  const limit = Number.isFinite(maxBytes) ? Math.max(0, Math.floor(maxBytes)) : Infinity;
  const declaredLength = Number(response.headers.get("content-length"));
  if (Number.isFinite(declaredLength) && declaredLength > limit) {
    await response.body?.cancel();
    throw new WorkMeshContractError("Work Mesh API response exceeds its byte bound");
  }
  if (!response.body?.getReader) {
    const text = await response.text();
    if (Buffer.byteLength(text, "utf8") > limit) {
      throw new WorkMeshContractError("Work Mesh API response exceeds its byte bound");
    }
    return text;
  }

  const reader = response.body.getReader();
  const chunks = [];
  let bytes = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > limit) {
        await reader.cancel();
        throw new WorkMeshContractError("Work Mesh API response exceeds its byte bound");
      }
      chunks.push(Buffer.from(value));
    }
  } finally {
    reader.releaseLock();
  }
  return Buffer.concat(chunks, bytes).toString("utf8");
}

function emptyLiveCache() {
  return {
    schemaVersion: 1,
    updatedAt: new Date(0).toISOString(),
    threadsById: {},
    projects: {},
    events: [],
  };
}

function readLiveCache(opts = {}) {
  const cached = readJson(liveCacheFile(opts));
  if (!cached || typeof cached !== "object") return emptyLiveCache();
  return {
    ...emptyLiveCache(),
    ...cached,
    threadsById: cached.threadsById && typeof cached.threadsById === "object" ? cached.threadsById : {},
    projects: cached.projects && typeof cached.projects === "object" ? cached.projects : {},
    events: Array.isArray(cached.events) ? cached.events : [],
  };
}

function buildProjectRollups(threadsById) {
  const projects = {};
  const ownerSets = new Map();
  for (const thread of Object.values(threadsById || {})) {
    if (!thread || typeof thread !== "object") continue;
    const companyUid = thread.companyUid || "unknown-company";
    const projectId = thread.projectId || "(unassigned)";
    const key = `${companyUid}/${projectId}`;
    const existing = projects[key] || {
      companyUid,
      projectId,
      threadIds: [],
      statusCounts: {},
      owners: [],
      updatedAt: "",
      latestSummary: "",
      latestStatus: "",
    };
    existing.threadIds.push(thread.threadId);
    const status = thread.threadStatus || "unknown";
    existing.statusCounts[status] = (existing.statusCounts[status] || 0) + 1;
    let owners = ownerSets.get(key);
    if (!owners) {
      owners = new Set(existing.owners);
      ownerSets.set(key, owners);
    }
    if (thread.ownerUid && !owners.has(thread.ownerUid)) {
      owners.add(thread.ownerUid);
      existing.owners.push(thread.ownerUid);
    }
    const updatedAt = thread.lastActivityAt || thread.createdAt || "";
    if (!existing.updatedAt || updatedAt > existing.updatedAt) {
      existing.updatedAt = updatedAt;
      existing.latestStatus = status;
      existing.latestSummary =
        thread.progressSummary ||
        thread.sourceSignalSummary ||
        thread.blockedReason ||
        thread.lastEventKind ||
        "";
    }
    projects[key] = existing;
  }
  return projects;
}

function writeLiveCache(opts, cache) {
  const next = {
    ...cache,
    updatedAt: new Date().toISOString(),
    projects: buildProjectRollups(cache.threadsById),
  };
  writeJson(liveCacheFile(opts), next);
  return next;
}

function cachedActiveThreads(companyUid, projectId, opts = {}) {
  const cache = readLiveCache(opts);
  return activeProjectThreads(
    Object.values(cache.threadsById || {})
      .filter((thread) => thread.companyUid === companyUid)
      .filter((thread) => !projectId || thread.projectId === projectId)
      .sort((a, b) => String(b.lastActivityAt || b.createdAt || "").localeCompare(String(a.lastActivityAt || a.createdAt || ""))),
  );
}

async function importCognitoSession() {
  const candidates = [];

  if (process.env.HQ_COGNITO_SESSION_MODULE) {
    return import(pathToFileURL(path.resolve(process.env.HQ_COGNITO_SESSION_MODULE)).href);
  }

  try {
    return await import("@indigoai-us/hq-cli/dist/utils/cognito-session.js");
  } catch {
    // Fall through to path-based resolution from the installed hq binary.
  }

  const which = spawnSync("bash", ["-lc", "command -v hq"], { encoding: "utf8" });
  const hqBin = which.status === 0 ? which.stdout.trim() : "";
  if (hqBin) {
    try {
      const real = fs.realpathSync(hqBin);
      candidates.push(path.join(path.dirname(real), "utils", "cognito-session.js"));
      candidates.push(path.join(path.dirname(path.dirname(real)), "dist", "utils", "cognito-session.js"));
    } catch {
      // Ignore broken symlinks.
    }
  }

  candidates.push("/opt/homebrew/lib/node_modules/@indigoai-us/hq-cli/dist/utils/cognito-session.js");
  candidates.push("/usr/local/lib/node_modules/@indigoai-us/hq-cli/dist/utils/cognito-session.js");

  for (const candidate of candidates) {
    if (!candidate || !fs.existsSync(candidate)) continue;
    try {
      return await import(pathToFileURL(candidate).href);
    } catch {
      // Try the next candidate.
    }
  }

  throw new Error("HQ CLI auth module is unavailable");
}

async function resolveAuth() {
  if (process.env.HQ_WORK_MESH_TOKEN) {
    return {
      token: process.env.HQ_WORK_MESH_TOKEN,
      apiUrl: resolveApiUrl(),
      staticToken: true,
      refreshToken: async () => process.env.HQ_WORK_MESH_TOKEN,
    };
  }

  const auth = await importCognitoSession();
  const refreshToken = async () => auth.ensureCognitoIdToken
    ? auth.ensureCognitoIdToken({ interactive: false })
    : auth.ensureCognitoToken({ interactive: false });
  const token = await refreshToken();
  const apiUrl = resolveApiUrl(auth);
  return { token, apiUrl, staticToken: false, refreshToken };
}

async function refreshAuthToken(auth) {
  const token = await auth.refreshToken();
  if (typeof token !== "string" || token.length === 0) {
    throw new Error("HQ auth refresh returned no token");
  }
  auth.token = token;
  return token;
}

function resolveApiUrl(auth = {}) {
  const rawApiUrl =
    process.env.HQ_WORK_MESH_API_URL ||
    process.env.HQ_VAULT_API_URL ||
    process.env.HQ_API_URL ||
    process.env.HQ_PRO_API_URL ||
    auth.DEFAULT_VAULT_API_URL;
  if (!rawApiUrl) {
    throw new Error("HQ Work Mesh API URL unavailable; set HQ_WORK_MESH_API_URL");
  }
  let parsed;
  try {
    parsed = new URL(rawApiUrl);
  } catch {
    throw new Error("HQ Work Mesh API URL is invalid");
  }
  const loopback = parsed.hostname === "localhost" || parsed.hostname === "[::1]" || /^127(?:\.\d{1,3}){3}$/.test(parsed.hostname);
  if (
    (parsed.protocol !== "https:" && !(parsed.protocol === "http:" && loopback)) ||
    parsed.username || parsed.password || parsed.search || parsed.hash
  ) {
    throw new Error("HQ Work Mesh API URL must use HTTPS without credentials, query, or fragment");
  }
  return parsed.toString().replace(/\/+$/, "");
}

function authHeaders(token, json = false) {
  return {
    Authorization: `Bearer ${token}`,
    ...(json ? { "Content-Type": "application/json" } : {}),
  };
}

async function fetchJson(url, token, init = {}) {
  const {
    timeoutMs: requestedTimeoutMs,
    maxResponseBytes,
    rejectDuplicateTopLevelKeys = false,
    signal: externalSignal,
    ...fetchInit
  } = init;
  const timeoutMs = boundedNumber(
    requestedTimeoutMs ?? process.env.HQ_WORK_MESH_TIMEOUT_MS,
    2_000,
    1,
    600_000,
  );
  const controller = new AbortController();
  const abortFromExternal = () => controller.abort();
  if (externalSignal?.aborted) abortFromExternal();
  else externalSignal?.addEventListener("abort", abortFromExternal, { once: true });
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, { ...fetchInit, redirect: "error", signal: controller.signal });
    const text = await readBoundedResponseText(response, maxResponseBytes);
    if (rejectDuplicateTopLevelKeys && duplicateTopLevelJsonKeys(text).size > 0) {
      throw new WorkMeshContractError("Work Mesh API returned ambiguous JSON");
    }
    let body = {};
    try {
      body = text ? JSON.parse(text) : {};
    } catch {
      throw new WorkMeshContractError("Work Mesh API returned invalid JSON");
    }
    if (!response.ok) {
      throw new WorkMeshHttpError(
        `Work Mesh API request failed with ${response.status}`,
        response.status,
        body?.retryable === true || response.status === 429 || response.status >= 500,
        body?.code,
        body?.supportedContractVersions,
      );
    }
    return body;
  } finally {
    clearTimeout(timer);
    externalSignal?.removeEventListener("abort", abortFromExternal);
  }
}

async function getJson(apiUrl, token, pathname) {
  return fetchJson(`${apiUrl}${pathname}`, token, { headers: authHeaders(token) });
}

async function postJson(apiUrl, token, pathname, body, signal, maxResponseBytes, rejectDuplicateTopLevelKeys = false) {
  return fetchJson(`${apiUrl}${pathname}`, token, {
    method: "POST",
    headers: authHeaders(token, true),
    body: JSON.stringify(compact(body) ?? {}),
    signal,
    maxResponseBytes,
    rejectDuplicateTopLevelKeys,
  });
}

async function fetchWorkFeed(apiUrl, token, cursor, signal) {
  const suffix = cursor ? `?cursor=${encodeURIComponent(cursor)}` : "";
  const data = await fetchJson(`${apiUrl}/v1/work-mesh/work${suffix}`, token, {
    headers: authHeaders(token),
    timeoutMs: Number(process.env.HQ_WORK_MESH_RECONCILE_TIMEOUT_MS || "15000"),
    maxResponseBytes: MAX_WORK_FEED_BYTES,
    rejectDuplicateTopLevelKeys: true,
    signal,
  });
  return parseWorkFeed(data);
}

function awsEncode(value) {
  return encodeURIComponent(value).replace(/[!*'()]/g, (char) => `%${char.charCodeAt(0).toString(16).toUpperCase()}`);
}

function sha256hex(value) {
  return crypto.createHash("sha256").update(value, "utf8").digest("hex");
}

function hmac(key, value) {
  return crypto.createHmac("sha256", key).update(value, "utf8").digest();
}

function presignIotWss(credentials, endpoint, region) {
  const service = "iotdevicegateway";
  const method = "GET";
  const canonicalUri = "/mqtt";
  const now = new Date();
  const amzdate = now.toISOString().replace(/[:-]|\.\d{3}/g, "").replace(/Z?$/, "Z");
  const datestamp = amzdate.slice(0, 8);
  const algorithm = "AWS4-HMAC-SHA256";
  const scope = `${datestamp}/${region}/${service}/aws4_request`;
  const canonicalQuery =
    `X-Amz-Algorithm=${awsEncode(algorithm)}` +
    `&X-Amz-Credential=${awsEncode(`${credentials.accessKeyId}/${scope}`)}` +
    `&X-Amz-Date=${awsEncode(amzdate)}` +
    "&X-Amz-SignedHeaders=host";
  const canonicalHeaders = `host:${endpoint}\n`;
  const canonicalRequest = [
    method,
    canonicalUri,
    canonicalQuery,
    canonicalHeaders,
    "host",
    sha256hex(""),
  ].join("\n");
  const stringToSign = [
    algorithm,
    amzdate,
    scope,
    sha256hex(canonicalRequest),
  ].join("\n");
  const kDate = hmac(`AWS4${credentials.secretAccessKey}`, datestamp);
  const kRegion = hmac(kDate, region);
  const kService = hmac(kRegion, service);
  const kSigning = hmac(kService, "aws4_request");
  const signature = crypto.createHmac("sha256", kSigning).update(stringToSign, "utf8").digest("hex");
  let url = `wss://${endpoint}${canonicalUri}?${canonicalQuery}&X-Amz-Signature=${signature}`;
  if (credentials.sessionToken) url += `&X-Amz-Security-Token=${awsEncode(credentials.sessionToken)}`;
  return url;
}

function requireMqttModule() {
  const requested = process.env.HQ_WORK_MESH_MQTT_MODULE;
  if (requested) {
    return require(requested);
  }

  const anchors = [
    import.meta.url,
    path.join(process.cwd(), "package.json"),
    path.join(resolveHqRoot(), "package.json"),
    path.join(resolveHqRoot(), "repos", "private", "hq-pro", "package.json"),
    path.join(resolveHqRoot(), "..", "hq-pro", "package.json"),
  ];

  for (const anchor of anchors) {
    try {
      if (anchor !== import.meta.url && !fs.existsSync(anchor)) continue;
      return createRequire(anchor)("mqtt");
    } catch {
      // Try the next likely runtime location.
    }
  }

  throw new Error("mqtt module unavailable; install mqtt or set HQ_WORK_MESH_MQTT_MODULE");
}

async function resolveCompanyUid(apiUrl, token, company) {
  const explicit = process.env.HQ_WORK_MESH_COMPANY_UID || process.env.HQ_COMPANY_UID;
  if (explicit) return { companyUid: explicit, companySlug: company || explicit };
  if (company && /^(cmp|co)_/.test(company)) return { companyUid: company, companySlug: company };

  const data = await getJson(apiUrl, token, "/membership/me");
  const memberships = Array.isArray(data.memberships) ? data.memberships : [];
  const wanted = String(company || "").toLowerCase();
  const match = memberships.find((membership) => {
    const values = [
      membership.companyUid,
      membership.companySlug,
      membership.slug,
      membership.companyName,
      membership.name,
    ].filter(Boolean);
    return values.some((value) => String(value).toLowerCase() === wanted);
  });

  if (!match && !company && memberships.length === 1) {
    const only = memberships[0];
    return {
      companyUid: String(only.companyUid),
      companySlug: String(only.companySlug || only.slug || only.companyUid),
    };
  }

  if (!match) {
    throw new Error(company ? `No cloud membership found for company '${company}'` : "Company is required");
  }

  return {
    companyUid: String(match.companyUid),
    companySlug: String(match.companySlug || match.slug || company || match.companyUid),
  };
}

async function listThreads(apiUrl, token, companyUid, projectId) {
  const data = await getJson(apiUrl, token, `/v1/work-mesh/threads?companyUid=${encodeURIComponent(companyUid)}&limit=100`);
  const threads = Array.isArray(data.threads) ? data.threads : Array.isArray(data.items) ? data.items : [];
  return threads
    .filter((thread) => !projectId || thread.projectId === projectId)
    .sort((a, b) => String(b.lastActivityAt || b.createdAt || "").localeCompare(String(a.lastActivityAt || a.createdAt || "")));
}

function activeProjectThreads(threads) {
  return threads.filter((thread) => ACTIVE_STATUSES.has(thread.threadStatus));
}

async function createThread(apiUrl, token, companyUid, projectId, opts) {
  const routing = compact({
    priority: opts.priority || "normal",
    lane: opts.lane,
    skills: dedupe(opts.skills),
    capabilities: dedupe(opts.capabilities),
    tags: dedupe(["hq-project", `project:${projectId}`, ...opts.tags]),
  });
  return postJson(apiUrl, token, "/v1/work-mesh/threads", {
    companyUid,
    projectId,
    sourceSignalSummary: clamp(opts.summary || `HQ project ${projectId}`, 280),
    routing,
  });
}

async function appendEvent(apiUrl, token, companyUid, threadId, eventKind, payload) {
  return postJson(apiUrl, token, `/v1/work-mesh/threads/${encodeURIComponent(threadId)}/events`, {
    companyUid,
    eventKind,
    payload,
  });
}

async function fetchRealtimeConfig(apiUrl, token, signal) {
  try {
    const data = await postJson(
      apiUrl,
      token,
      "/v1/realtime/credentials",
      { contractVersion: 2 },
      signal,
      MAX_REALTIME_CONFIG_BYTES,
      true,
    );
    return parseRealtimeV2Config(data);
  } catch (err) {
    if (
      !(err instanceof WorkMeshHttpError) ||
      err.status !== 409 ||
      err.code !== "REALTIME_CONTRACT_UNSUPPORTED" ||
      !err.supportedContractVersions.includes(1) ||
      err.supportedContractVersions.includes(2)
    ) throw err;
  }
  const data = await postJson(
    apiUrl,
    token,
    "/v1/realtime/credentials",
    {},
    signal,
    MAX_REALTIME_CONFIG_BYTES,
    true,
  );
  return parseRealtimeV1Config(data);
}

function mqttTopicsForConfig(config, companyUid) {
  if (config.contractVersion === 2) return [config.topics.work];
  const companyTopics = config.companyTopics
    .filter((entry) => !companyUid || entry.companyUid === companyUid)
    .map((entry) => entry.threadTopicFilter)
    .filter(Boolean);
  return dedupe([
    ...companyTopics,
    config.topics?.work,
  ]);
}

function redactedRealtimeConfig(config, companyUid) {
  const common = {
    contractVersion: config.contractVersion,
    iotEndpoint: config.iotEndpoint,
    region: config.region,
    topics: config.topics,
    expiresAt: config.expiresAt,
  };
  if (config.contractVersion === 2) {
    return common;
  }
  return {
    ...common,
    companyTopics: config.companyTopics
      .filter((entry) => !companyUid || entry.companyUid === companyUid)
      .map((entry) => ({
        companyUid: entry.companyUid,
        threadTopicFilter: entry.threadTopicFilter,
        presenceTopic: entry.presenceTopic,
      })),
  };
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function hasExactKeys(record, expected) {
  if (!isRecord(record)) return false;
  const keys = Object.keys(record);
  return keys.length === expected.length && expected.every((key) => Object.hasOwn(record, key));
}

function hasAllowedKeys(record, required, optional) {
  if (!isRecord(record)) return false;
  const allowed = new Set([...required, ...optional]);
  return required.every((key) => Object.hasOwn(record, key)) && Object.keys(record).every((key) => allowed.has(key));
}

function requiredString(value, maxLength, label) {
  if (typeof value !== "string" || value.length === 0 || value.length > maxLength) {
    throw new WorkMeshContractError(`${label} is invalid`);
  }
  return value;
}

function requiredUtcDate(value, label) {
  const date = requiredString(value, 35, label);
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$/.test(date) || !Number.isFinite(Date.parse(date))) {
    throw new WorkMeshContractError(`${label} is invalid`);
  }
  return date;
}

function assertRealtimeEndpoint(endpoint, region) {
  const labels = endpoint.split(".");
  const escapedRegion = region.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const awsIotEndpoint = new RegExp(
    `^[a-z0-9][a-z0-9-]{0,62}-ats\\.iot\\.${escapedRegion}\\.amazonaws\\.com(?:\\.cn)?$`,
  );
  if (
    endpoint.length > 253 ||
    !/^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/.test(endpoint) ||
    labels.length < 3 ||
    !/^[a-z]{2,63}$/.test(labels.at(-1) || "") ||
    labels.some((label) => label.length === 0 || label.length > 63) ||
    !awsIotEndpoint.test(endpoint)
  ) {
    throw new WorkMeshContractError("realtime IoT endpoint is invalid");
  }
}

function personUidFromDmTopic(topic) {
  const match = /^hq\/((?:prs|agt)_[0-9A-HJKMNP-TV-Z]{26})\/dm$/.exec(topic || "");
  return match?.[1];
}

function parseCredentials(value, version) {
  if (!hasExactKeys(value, REALTIME_CREDENTIAL_KEYS)) {
    throw new WorkMeshContractError(`realtime v${version} credentials are invalid`);
  }
  const parsed = {
    accessKeyId: requiredString(value.accessKeyId, 128, "realtime access key"),
    secretAccessKey: requiredString(value.secretAccessKey, 256, "realtime secret key"),
    sessionToken: requiredString(value.sessionToken, 4096, "realtime session token"),
    expiration: requiredUtcDate(value.expiration, "realtime credential expiration"),
  };
  if (
    !/^(?:AKIA|ASIA)[A-Z0-9]{16}$/.test(parsed.accessKeyId) ||
    !/^[\x21-\x7e]+$/.test(parsed.secretAccessKey) ||
    !/^[\x21-\x7e]+$/.test(parsed.sessionToken)
  ) {
    throw new WorkMeshContractError(`realtime v${version} credentials are invalid`);
  }
  return parsed;
}

function parseTopics(value, version) {
  if (!hasExactKeys(value, REALTIME_TOPIC_KEYS)) {
    throw new WorkMeshContractError(`realtime v${version} topics are invalid`);
  }
  return Object.fromEntries(REALTIME_TOPIC_KEYS.map((key) => [key, requiredString(value[key], 256, `realtime ${key} topic`)]));
}

function validateRealtimeCommon(config, version) {
  if (!/^[a-z0-9]+(?:-[a-z0-9]+){1,4}$/.test(config.region)) {
    throw new WorkMeshContractError(`realtime v${version} region is invalid`);
  }
  assertRealtimeEndpoint(config.iotEndpoint, config.region);
  const principalUid = personUidFromDmTopic(config.topics.dm);
  if (
    !principalUid ||
    config.topic !== config.topics.dm ||
    config.topics.sessions !== `hq/${principalUid}/sessions` ||
    config.topics.work !== `hq/${principalUid}/work` ||
    config.topics.notifications !== `hq/${principalUid}/notifications` ||
    config.credentials.expiration !== config.expiresAt ||
    Date.parse(config.expiresAt) <= Date.now()
  ) {
    throw new WorkMeshContractError(`realtime v${version} topics or expiration are inconsistent`);
  }
  return principalUid;
}

function parseRealtimeV2Config(value) {
  if (!hasExactKeys(value, REALTIME_V2_RESPONSE_KEYS) || value.contractVersion !== 2) {
    throw new WorkMeshContractError("realtime v2 credential response is invalid");
  }
  const config = {
    contractVersion: 2,
    credentials: parseCredentials(value.credentials, 2),
    iotEndpoint: requiredString(value.iotEndpoint, 253, "realtime IoT endpoint"),
    region: requiredString(value.region, 32, "realtime region"),
    clientId: requiredString(value.clientId, 64, "realtime client id"),
    topic: requiredString(value.topic, 256, "realtime topic"),
    topics: parseTopics(value.topics, 2),
    expiresAt: requiredUtcDate(value.expiresAt, "realtime expiration"),
  };
  if (!REALTIME_V2_CLIENT_ID_PATTERN.test(config.clientId)) {
    throw new WorkMeshContractError("realtime v2 client id is invalid");
  }
  config.principalUid = validateRealtimeCommon(config, 2);
  return config;
}

function parseRealtimeV1Config(value) {
  if (!hasAllowedKeys(value, REALTIME_V1_RESPONSE_KEYS, ["contractVersion", "companyTopics"])) {
    throw new WorkMeshContractError("realtime v1 credential response is invalid");
  }
  if (value.contractVersion !== undefined && value.contractVersion !== 1) {
    throw new WorkMeshContractError("realtime v1 contract version is invalid");
  }
  const companyTopics = value.companyTopics ?? [];
  if (!Array.isArray(companyTopics) || companyTopics.length > MAX_V1_COMPANY_TOPICS) {
    throw new WorkMeshContractError("realtime v1 company topics are invalid");
  }
  const config = {
    contractVersion: 1,
    credentials: parseCredentials(value.credentials, 1),
    iotEndpoint: requiredString(value.iotEndpoint, 253, "realtime IoT endpoint"),
    region: requiredString(value.region, 32, "realtime region"),
    topic: requiredString(value.topic, 256, "realtime topic"),
    topics: parseTopics(value.topics, 1),
    expiresAt: requiredUtcDate(value.expiresAt, "realtime expiration"),
    companyTopics: companyTopics.map((entry) => {
      if (!hasExactKeys(entry, REALTIME_V1_COMPANY_TOPIC_KEYS)) {
        throw new WorkMeshContractError("realtime v1 company topics are invalid");
      }
      const companyUid = requiredString(entry.companyUid, 128, "realtime company uid");
      const parsed = {
        companyUid,
        threadTopicFilter: requiredString(entry.threadTopicFilter, 256, "realtime thread topic"),
        presenceTopic: requiredString(entry.presenceTopic, 256, "realtime presence topic"),
      };
      if (
        !REALTIME_COMPANY_PATTERN.test(companyUid) ||
        parsed.threadTopicFilter !== `hq/${companyUid}/thread/#` ||
        parsed.presenceTopic !== `hq/${companyUid}/presence`
      ) {
        throw new WorkMeshContractError("realtime v1 company topics are invalid");
      }
      return parsed;
    }),
  };
  config.principalUid = validateRealtimeCommon(config, 1);
  return config;
}

async function hydrateLiveCache(apiUrl, token, config, opts, companyUid) {
  let cache = readLiveCache(opts);
  cache.realtime = redactedRealtimeConfig(config, companyUid);
  for (const entry of config.companyTopics) {
    if (companyUid && entry.companyUid !== companyUid) continue;
    try {
      const threads = await listThreads(apiUrl, token, entry.companyUid);
      for (const thread of threads) {
        if (!thread?.threadId) continue;
        cache.threadsById[thread.threadId] = {
          ...(cache.threadsById[thread.threadId] || {}),
          ...thread,
          cacheSource: "rest-hydrate",
        };
      }
    } catch (err) {
      cache.events.unshift({
        type: "hydrate_error",
        companyUid: entry.companyUid,
        message: err instanceof Error ? err.message : String(err),
        createdAt: new Date().toISOString(),
      });
    }
  }
  cache.events = cache.events.slice(0, 100);
  cache = writeLiveCache(opts, cache);
  return cache;
}

function parseFeedThread(value, expectedOpen) {
  if (!isRecord(value)) throw new WorkMeshContractError("Work Mesh feed thread is invalid");
  const threadId = requiredString(value.threadId, 128, "Work Mesh feed thread id");
  const companyUid = requiredString(value.companyUid, 128, "Work Mesh feed company uid");
  const threadStatus = requiredString(value.threadStatus, 32, "Work Mesh feed status");
  if (
    !REALTIME_ID_PATTERN.test(threadId) ||
    !REALTIME_COMPANY_PATTERN.test(companyUid) ||
    ![...ACTIVE_STATUSES, "done"].includes(threadStatus) ||
    (expectedOpen && !ACTIVE_STATUSES.has(threadStatus))
  ) {
    throw new WorkMeshContractError("Work Mesh feed thread is invalid");
  }
  return { ...value, threadId, companyUid, threadStatus };
}

function parseWorkFeed(value) {
  if (!hasExactKeys(value, WORK_FEED_KEYS) || value.contractVersion !== 2) {
    throw new WorkMeshContractError("Work Mesh feed response is invalid");
  }
  const serializedBytes = Buffer.byteLength(JSON.stringify(value), "utf8");
  if (serializedBytes > MAX_WORK_FEED_BYTES) throw new WorkMeshContractError("Work Mesh feed exceeds its byte bound");
  if (
    typeof value.snapshot !== "boolean" ||
    typeof value.reset !== "boolean" ||
    (value.reset && !value.snapshot) ||
    !Array.isArray(value.removedCompanyUids) ||
    !Array.isArray(value.open) ||
    !Array.isArray(value.changed) ||
    value.open.length + value.changed.length > MAX_WORK_FEED_THREADS
  ) {
    throw new WorkMeshContractError("Work Mesh feed response is invalid");
  }
  const cursor = requiredString(value.cursor, 128, "Work Mesh cursor");
  const cursorExpiresAt = requiredUtcDate(value.cursorExpiresAt, "Work Mesh cursor expiration");
  if (!/^[A-Za-z0-9_-]{32,128}$/.test(cursor) || Date.parse(cursorExpiresAt) <= Date.now()) {
    throw new WorkMeshContractError("Work Mesh cursor is invalid or expired");
  }
  const removedCompanyUids = value.removedCompanyUids.map((uid) =>
    requiredString(uid, 128, "removed Work Mesh company uid"));
  if (
    removedCompanyUids.some((uid) => !REALTIME_COMPANY_PATTERN.test(uid)) ||
    new Set(removedCompanyUids).size !== removedCompanyUids.length
  ) {
    throw new WorkMeshContractError("Work Mesh removed companies are invalid");
  }
  const open = value.open.map((thread) => parseFeedThread(thread, true));
  const changed = value.changed.map((thread) => parseFeedThread(thread, false));
  if (new Set(open.map((thread) => thread.threadId)).size !== open.length) {
    throw new WorkMeshContractError("Work Mesh feed contains duplicate open threads");
  }
  if (new Set(changed.map((thread) => thread.threadId)).size !== changed.length) {
    throw new WorkMeshContractError("Work Mesh feed contains duplicate changed threads");
  }
  return {
    contractVersion: 2,
    snapshot: value.snapshot,
    reset: value.reset,
    cursor,
    cursorExpiresAt,
    removedCompanyUids,
    open,
    changed,
  };
}

function cursorFileFor(opts = {}) {
  return `${liveCacheFile(opts)}.cursor-v2.json`;
}

function cursorBinding(apiUrl, config) {
  return sha256hex(`${apiUrl}\n${config.principalUid}\n${config.topics.work}`);
}

function loadBoundCursor(apiUrl, config, opts = {}) {
  const stored = readJson(cursorFileFor(opts));
  if (
    stored?.version !== 1 ||
    stored.binding !== cursorBinding(apiUrl, config) ||
    typeof stored.cursor !== "string" ||
    !/^[A-Za-z0-9_-]{32,128}$/.test(stored.cursor) ||
    typeof stored.expiresAt !== "string" ||
    Date.parse(stored.expiresAt) <= Date.now()
  ) return undefined;
  return stored.cursor;
}

function saveBoundCursor(apiUrl, config, opts, cursor, expiresAt) {
  writeJson(cursorFileFor(opts), {
    version: 1,
    binding: cursorBinding(apiUrl, config),
    cursor,
    expiresAt,
  });
}

function applyWorkFeedToCache(cache, feed, config, companyUid, reason) {
  const open = companyUid
    ? feed.open.filter((thread) => thread.companyUid === companyUid)
    : feed.open;
  const nextThreads = {};
  for (const thread of open) {
    nextThreads[thread.threadId] = {
      ...thread,
      cacheSource: "rest-reconcile-v2",
    };
  }
  return {
    ...cache,
    realtime: redactedRealtimeConfig(config, companyUid),
    threadsById: nextThreads,
    events: [
      {
        type: "reconcile",
        reason,
        snapshot: feed.snapshot,
        reset: feed.reset,
        openCount: open.length,
        changedCount: feed.changed.length,
        removedCompanyCount: feed.removedCompanyUids.length,
        createdAt: new Date().toISOString(),
      },
      ...(Array.isArray(cache.events) ? cache.events : []),
    ].slice(0, 100),
  };
}

async function reconcileV2(auth, config, opts, companyUid, cursor, reason, signal) {
  const token = await refreshAuthToken(auth);
  const feed = await fetchWorkFeed(auth.apiUrl, token, cursor, signal);
  const cache = applyWorkFeedToCache(readLiveCache(opts), feed, config, companyUid, reason);
  const written = writeLiveCache(opts, cache);
  saveBoundCursor(auth.apiUrl, config, opts, feed.cursor, feed.cursorExpiresAt);
  return { feed, cache: written };
}

function threadPartsFromTopic(topic) {
  const match = String(topic).match(/^hq\/([^/]+)\/thread\/([^/]+)$/);
  return match ? { companyUid: match[1], threadId: match[2] } : null;
}

function applyMqttMessageToCache(cache, topic, payload) {
  const raw = Buffer.isBuffer(payload) ? payload.toString("utf8") : String(payload ?? "");
  const topicThread = threadPartsFromTopic(topic);
  const receivedAt = new Date().toISOString();

  if (raw.length === 0) {
    if (topicThread?.threadId) delete cache.threadsById[topicThread.threadId];
    cache.events.unshift({
      type: "retained_clear",
      topic,
      ...topicThread,
      receivedAt,
    });
    cache.events = cache.events.slice(0, 100);
    return cache;
  }

  let message;
  try {
    message = JSON.parse(raw);
  } catch {
    cache.events.unshift({ type: "unparsed", topic, receivedAt });
    cache.events = cache.events.slice(0, 100);
    return cache;
  }

  if (message?.threadId && message?.threadStatus && message?.companyUid) {
    cache.threadsById[message.threadId] = {
      ...(cache.threadsById[message.threadId] || {}),
      ...message,
      cacheSource: "mqtt-snapshot",
      receivedAt,
    };
    cache.events.unshift({
      type: "snapshot",
      topic,
      companyUid: message.companyUid,
      threadId: message.threadId,
      threadStatus: message.threadStatus,
      projectId: message.projectId,
      receivedAt,
    });
    cache.events = cache.events.slice(0, 100);
    return cache;
  }

  if (message?.type === "thread_event" && message?.threadId) {
    const threadId = message.threadId;
    const nextStatus = EVENT_STATUS.get(message.eventKind);
    const existing = cache.threadsById[threadId] || {};
    cache.threadsById[threadId] = compact({
      ...existing,
      threadId,
      companyUid: message.companyUid || existing.companyUid || topicThread?.companyUid,
      threadStatus: nextStatus || existing.threadStatus,
      lastActivityAt: message.createdAt || receivedAt,
      lastEventId: message.eventId,
      lastEventKind: message.eventKind,
      authorUid: message.authorUid || existing.authorUid,
      cacheSource: "mqtt-event",
      receivedAt,
      ...(message.eventKind === "done" ? { completedAt: message.createdAt || receivedAt } : {}),
    });
    cache.events.unshift({
      type: "thread_event",
      topic,
      eventId: message.eventId,
      eventKind: message.eventKind,
      companyUid: message.companyUid,
      threadId,
      directedTo: message.directedTo,
      createdAt: message.createdAt,
      receivedAt,
    });
    cache.events = cache.events.slice(0, 100);
    return cache;
  }

  cache.events.unshift({
    type: message?.type || "message",
    topic,
    receivedAt,
  });
  cache.events = cache.events.slice(0, 100);
  return cache;
}

function duplicateTopLevelJsonKeys(serialized) {
  const seen = new Set();
  const duplicates = new Set();
  let depth = 0;
  let inString = false;
  let escaped = false;
  let stringStart = -1;
  let expectingTopLevelKey = false;
  for (let index = 0; index < serialized.length; index += 1) {
    const character = serialized[index];
    if (inString) {
      if (escaped) escaped = false;
      else if (character === "\\") escaped = true;
      else if (character === '"') {
        inString = false;
        if (depth === 1 && expectingTopLevelKey) {
          const key = JSON.parse(serialized.slice(stringStart, index + 1));
          if (seen.has(key)) duplicates.add(key);
          seen.add(key);
          expectingTopLevelKey = false;
        }
      }
      continue;
    }
    if (character === '"') {
      inString = true;
      stringStart = index;
    } else if (character === "{" || character === "[") {
      depth += 1;
      if (character === "{" && depth === 1) expectingTopLevelKey = true;
    } else if (character === "}" || character === "]") {
      depth -= 1;
    } else if (character === "," && depth === 1) {
      expectingTopLevelKey = true;
    }
  }
  return duplicates;
}

function parseRealtimeV2Wake(payload) {
  const raw = Buffer.isBuffer(payload) ? payload.toString("utf8") : String(payload ?? "");
  if (Buffer.byteLength(raw, "utf8") > MAX_REALTIME_ENVELOPE_BYTES) return null;
  let value;
  try {
    value = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!isRecord(value)) return null;
  if (Object.hasOwn(value, "contractVersion")) {
    const duplicates = duplicateTopLevelJsonKeys(raw);
    if (duplicates.size > 0) return null;
    if (Number.isSafeInteger(value.contractVersion) && value.contractVersion > 2) return null;
  }
  if (!hasExactKeys(value, REALTIME_ENVELOPE_KEYS)) return null;
  if (
    value.contractVersion !== 2 ||
    typeof value.eventId !== "string" || value.eventId.length > 64 || !REALTIME_ID_PATTERN.test(value.eventId) ||
    typeof value.eventType !== "string" || value.eventType.length > 64 || !REALTIME_EVENT_TYPE_PATTERN.test(value.eventType) ||
    !["dm", "channel", "work"].includes(value.scope) ||
    typeof value.resourceId !== "string" || !REALTIME_ID_PATTERN.test(value.resourceId) ||
    typeof value.recipientUid !== "string" || !REALTIME_PRINCIPAL_PATTERN.test(value.recipientUid) ||
    typeof value.createdAt !== "string" || value.createdAt.length > 35 ||
      !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:\d{2})$/.test(value.createdAt) ||
      !Number.isFinite(Date.parse(value.createdAt))
  ) return null;
  return value;
}

function deterministicBackoffMs(attempt, baseMs, maxMs, seed) {
  const boundedAttempt = Math.max(1, Math.min(Number(attempt) || 1, 30));
  const ceiling = Math.max(0, Number(maxMs) || 0);
  const exponential = Math.min(ceiling, Math.max(0, Number(baseMs) || 0) * 2 ** (boundedAttempt - 1));
  const mixed = Math.imul((Number(seed) || 0) ^ boundedAttempt, 1_664_525) + 1_013_904_223;
  const fraction = (mixed >>> 0) / 0xffffffff;
  return Math.min(ceiling, Math.max(0, Math.round(exponential * (0.8 + fraction * 0.4))));
}

function deterministicJitterMs(seed, label, maxMs) {
  if (maxMs <= 0) return 0;
  const digest = crypto.createHash("sha256").update(`${seed}:${label}`).digest();
  return digest.readUInt32BE(0) % (Math.floor(maxMs) + 1);
}

function renewalDelayMs(expiresAt, nowMs, renewalSkewMs, jitterSeed, generation) {
  const remaining = Date.parse(expiresAt) - nowMs;
  const skew = Math.min(Math.max(1, renewalSkewMs), Math.max(1, Math.floor(remaining / 2)));
  const jitter = deterministicJitterMs(
    jitterSeed,
    `renewal-${generation}`,
    Math.min(15_000, Math.floor(skew / 4)),
  );
  return Math.min(Math.max(1, remaining - skew - jitter), 2_147_483_647);
}

function boundedNumber(value, fallback, min, max) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(max, Math.max(min, Math.floor(parsed)));
}

function createBoundedLruSet(maxSize = 256) {
  const limit = boundedNumber(maxSize, 256, 1, 65_536);
  const entries = new Map();
  return {
    remember(value) {
      if (entries.has(value)) {
        entries.delete(value);
        entries.set(value, true);
        return false;
      }
      entries.set(value, true);
      if (entries.size > limit) entries.delete(entries.keys().next().value);
      return true;
    },
    has: (value) => entries.has(value),
    get size() { return entries.size; },
  };
}

function createReconcileCoordinator(operation, { debounceMs = 50 } = {}) {
  let cursor;
  let running = null;
  let scheduled = null;
  let scheduledTimer = null;
  let scheduledReject = null;
  let trailing = false;
  const reasons = new Set();

  async function run(reason) {
    reasons.add(reason);
    if (running) {
      trailing = true;
      return running;
    }
    running = (async () => {
      let result;
      do {
        trailing = false;
        const selectedReason = [...reasons].sort().join("+") || reason;
        reasons.clear();
        result = await operation(cursor, selectedReason);
        cursor = result?.feed?.cursor ?? cursor;
      } while (trailing);
      return result;
    })().finally(() => {
      running = null;
    });
    return running;
  }

  function request(reason) {
    reasons.add(reason);
    if (running) {
      trailing = true;
      return running;
    }
    if (scheduled) return scheduled;
    scheduled = new Promise((resolve, reject) => {
      scheduledReject = reject;
      scheduledTimer = setTimeout(() => {
        scheduledTimer = null;
        scheduledReject = null;
        const pending = run(reason);
        scheduled = null;
        pending.then(resolve, reject);
      }, Math.max(0, debounceMs));
    });
    return scheduled;
  }

  return {
    run,
    request,
    setCursor: (value) => { cursor = value; },
    getCursor: () => cursor,
    stop: () => {
      if (scheduledTimer) clearTimeout(scheduledTimer);
      const reject = scheduledReject;
      scheduledTimer = null;
      scheduledReject = null;
      scheduled = null;
      trailing = false;
      reject?.(new Error("Work Mesh reconciliation stopped"));
    },
  };
}

async function ensureThread(apiUrl, token, company, projectId, opts) {
  if (opts.thread_id) {
    return {
      threadId: opts.thread_id,
      created: false,
      thread: { threadId: opts.thread_id, projectId, companyUid: company.companyUid },
    };
  }

  const statePath = stateFileFor(company.companySlug || company.companyUid, projectId);
  const existing = activeProjectThreads(await listThreads(apiUrl, token, company.companyUid, projectId))[0];
  if (existing?.threadId) {
    writeJson(statePath, {
      companyUid: company.companyUid,
      companySlug: company.companySlug,
      projectId,
      threadId: existing.threadId,
      updatedAt: new Date().toISOString(),
    });
    return { threadId: existing.threadId, created: false, thread: existing };
  }

  const cached = readJson(statePath);
  if (cached?.threadId && !opts.force_new) {
    return {
      threadId: cached.threadId,
      created: false,
      thread: { threadId: cached.threadId, projectId, companyUid: company.companyUid },
    };
  }

  const created = opts.dry_run
    ? { threadId: "dry-run-thread", createdAt: new Date().toISOString() }
    : await createThread(apiUrl, token, company.companyUid, projectId, opts);

  writeJson(statePath, {
    companyUid: company.companyUid,
    companySlug: company.companySlug,
    projectId,
    threadId: created.threadId,
    createdAt: created.createdAt,
    updatedAt: new Date().toISOString(),
  });

  return {
    threadId: created.threadId,
    created: true,
    thread: { threadId: created.threadId, projectId, companyUid: company.companyUid },
  };
}

function callerLabel(token) {
  const claims = decodeJwtPayload(token);
  return (
    claims?.["custom:entityUid"] ||
    claims?.email ||
    claims?.sub ||
    process.env.HQ_AGENT_UID ||
    process.env.USER ||
    os.userInfo().username ||
    "hq-agent"
  );
}

function decodeJwtPayload(token) {
  try {
    const payload = token.split(".")[1];
    if (!payload) return null;
    const normalized = payload.replace(/-/g, "+").replace(/_/g, "/");
    const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=");
    return JSON.parse(Buffer.from(padded, "base64").toString("utf8"));
  } catch {
    return null;
  }
}

function eventPayload(command, opts, token) {
  if (command === "claim") {
    const minutes = Number(opts.lease_minutes || "120");
    return {
      claimedBy: clamp(opts.claimed_by || callerLabel(token), 120),
      leaseTtlIso: new Date(Date.now() + minutes * 60 * 1000).toISOString(),
      note: clamp(opts.summary || "Starting HQ project work.", 280),
    };
  }

  if (command === "progress") {
    const completion = opts.completion === undefined ? undefined : Number(opts.completion);
    return {
      summary: clamp(opts.summary || "Project work is in progress.", 280),
      completionEstimate: Number.isFinite(completion) ? Math.min(1, Math.max(0, completion)) : undefined,
    };
  }

  if (command === "blocked") {
    return {
      reason: clamp(opts.reason || opts.summary || "Project work is blocked.", 500),
      asks: dedupe(opts.asks).slice(0, 5),
    };
  }

  if (command === "done") {
    return {
      summary: clamp(opts.summary || "Project work completed.", 280),
    };
  }

  return {
    text: clamp(opts.summary || "HQ project note.", 500),
    noteKind: opts.note_kind || "audit",
  };
}

function printCheck(threads, company, projectId, opts) {
  if (opts.json) {
    console.log(JSON.stringify({ ok: true, action: "check", company, projectId, threads }, null, 2));
    return;
  }
  if (opts.silent) return;
  if (threads.length === 0) {
    console.log("Work mesh: no active project threads found.");
    return;
  }
  const scope = projectId ? `${company.companySlug || company.companyUid}/${projectId}` : company.companySlug || company.companyUid;
  console.log(`Work mesh: ${threads.length} active thread(s) for ${scope}`);
  for (const thread of threads.slice(0, Number(opts.limit || 5))) {
    const owner = thread.ownerUid ? ` owner=${thread.ownerUid}` : "";
    const summary = thread.progressSummary || thread.sourceSignalSummary || thread.blockedReason || "";
    console.log(`- ${thread.threadStatus} ${thread.threadId}${owner}${summary ? `: ${summary}` : ""}`);
  }
}

function printResult(result, opts) {
  if (opts.json) {
    console.log(JSON.stringify(result, null, 2));
    return;
  }
  if (opts.silent) return;
  const created = result.created ? "created" : "using";
  const event = result.eventKind ? `; ${result.eventKind} event ${result.eventId || "recorded"}` : "";
  console.log(`Work mesh: ${created} ${result.threadId}${event}`);
}

function printWatchReady(result, opts) {
  if (opts.json) {
    console.log(JSON.stringify(result, null, 2));
    return;
  }
  if (opts.silent) return;
  console.log(`Work mesh MQTT: ${result.dryRun ? "ready" : "subscribed"} (${result.topics.length} topic(s)); cache=${result.cacheFile}`);
}

async function watchWorkMesh(auth, opts, company) {
  const companyUid = company?.companyUid;
  const initialToken = await refreshAuthToken(auth);
  const initialConfig = await fetchRealtimeConfig(auth.apiUrl, initialToken);
  const lifecycleController = new AbortController();
  const initialTopics = mqttTopicsForConfig(initialConfig, companyUid);
  let initialCache;
  let coordinator;
  let reconcileConfig = initialConfig;
  if (initialConfig.contractVersion === 2) {
    coordinator = createReconcileCoordinator(
      (cursor, reason) => reconcileV2(
        auth,
        reconcileConfig,
        opts,
        companyUid,
        cursor,
        reason,
        lifecycleController.signal,
      ),
      { debounceMs: boundedNumber(process.env.HQ_WORK_MESH_RECONCILE_DEBOUNCE_MS, 50, 0, 60_000) },
    );
    coordinator.setCursor(loadBoundCursor(auth.apiUrl, initialConfig, opts));
    if (opts.dry_run) {
      const reconciled = await coordinator.run("initial");
      initialCache = reconciled.cache;
    } else {
      initialCache = readLiveCache(opts);
    }
  } else {
    initialCache = await hydrateLiveCache(auth.apiUrl, initialToken, initialConfig, opts, companyUid);
  }
  const ready = {
    ok: true,
    action: "watch",
    dryRun: Boolean(opts.dry_run),
    cacheFile: liveCacheFile(opts),
    topics: initialTopics,
    threadCount: Object.keys(initialCache.threadsById || {}).length,
    projectCount: Object.keys(initialCache.projects || {}).length,
    realtime: redactedRealtimeConfig(initialConfig, companyUid),
  };

  if (opts.dry_run) {
    coordinator?.stop();
    printWatchReady(ready, opts);
    return;
  }

  const mqtt = requireMqttModule();
  const timeoutMs = boundedNumber(
    opts.timeout_ms || process.env.HQ_WORK_MESH_WATCH_TIMEOUT_MS || (opts.once ? "10000" : "0"),
    opts.once ? 10_000 : 0,
    0,
    2_147_483_647,
  );
  const renewalSkewMs = boundedNumber(process.env.HQ_WORK_MESH_RENEWAL_SKEW_MS, 60_000, 1, 86_400_000);
  const retryBaseMs = boundedNumber(process.env.HQ_WORK_MESH_RETRY_BASE_MS, 500, 1, 60_000);
  const retryMaxMs = Math.max(
    retryBaseMs,
    boundedNumber(process.env.HQ_WORK_MESH_RETRY_MAX_MS, 30_000, 1, 600_000),
  );
  const periodicMs = boundedNumber(process.env.HQ_WORK_MESH_PERIODIC_RECONCILE_MS, 300_000, 0, 2_147_483_647);
  const jitterSeed = boundedNumber(process.env.HQ_WORK_MESH_JITTER_SEED, 11_011, -2_147_483_648, 2_147_483_647);
  const connectTimeoutMs = boundedNumber(process.env.HQ_WORK_MESH_MQTT_CONNECT_TIMEOUT_MS, 8_000, 1, 120_000);
  const seenWakeIds = createBoundedLruSet(256);
  const clients = new Set();
  const candidateCancels = new Map();
  let active;
  let latestConfig = initialConfig;
  let generation = 0;
  let lifecycleEpoch = 0;
  let connectInFlight = null;
  let retryAttempt = 0;
  let renewalTimer = null;
  let retryTimer = null;
  let reconcileRetryTimer = null;
  let reconcileRetryAttempt = 0;
  let periodicTimer = null;
  let authBlocked = false;
  let settled = false;
  let messageCount = 0;
  let finishWatch;

  const closeClient = (client) => {
    clients.delete(client);
    try {
      client?.end(true);
    } catch {
      // Shutdown is best-effort; generation guards already fence callbacks.
    }
  };

  const blockStaticAuth = (error) => {
    authBlocked = true;
    if (renewalTimer) clearTimeout(renewalTimer);
    if (retryTimer) clearTimeout(retryTimer);
    if (reconcileRetryTimer) clearTimeout(reconcileRetryTimer);
    if (periodicTimer) clearTimeout(periodicTimer);
    renewalTimer = null;
    retryTimer = null;
    reconcileRetryTimer = null;
    periodicTimer = null;
    active = null;
    for (const client of [...clients]) closeClient(client);
    finishWatch?.(error, true);
  };

  const rememberWake = (eventId) => {
    return seenWakeIds.remember(eventId);
  };

  const schedulePeriodic = () => {
    if (settled || authBlocked || latestConfig.contractVersion !== 2 || periodicMs <= 0) return;
    if (periodicTimer) clearTimeout(periodicTimer);
    const jitter = deterministicJitterMs(jitterSeed, `periodic-${generation}`, Math.floor(periodicMs / 10));
    periodicTimer = setTimeout(() => {
      periodicTimer = null;
      requestReconcile("periodic")
        .catch(() => {})
        .finally(schedulePeriodic);
    }, Math.max(1, periodicMs - jitter));
  };

  const scheduleReconcileRetry = (error) => {
    if (settled || reconcileRetryTimer) return;
    if (auth.staticToken && error instanceof WorkMeshHttpError && [401, 403].includes(error.status)) {
      blockStaticAuth(error);
      return;
    }
    reconcileRetryAttempt += 1;
    const delay = deterministicBackoffMs(reconcileRetryAttempt, retryBaseMs, retryMaxMs, jitterSeed ^ 0x5a5a);
    reconcileRetryTimer = setTimeout(() => {
      reconcileRetryTimer = null;
      requestReconcile("retry").catch(() => {});
    }, delay);
  };

  const requestReconcile = async (reason) => {
    if (settled || authBlocked) throw new Error("Work Mesh reconciliation is unavailable");
    try {
      const result = await coordinator.request(reason);
      reconcileRetryAttempt = 0;
      if (reconcileRetryTimer) clearTimeout(reconcileRetryTimer);
      reconcileRetryTimer = null;
      return result;
    } catch (err) {
      scheduleReconcileRetry(err);
      throw err;
    }
  };

  const scheduleRetry = (reason, error) => {
    if (settled || retryTimer) return;
    if (auth.staticToken && error instanceof WorkMeshHttpError && [401, 403].includes(error.status)) {
      blockStaticAuth(error);
      return;
    }
    retryAttempt += 1;
    const delay = deterministicBackoffMs(retryAttempt, retryBaseMs, retryMaxMs, jitterSeed);
    retryTimer = setTimeout(() => {
      retryTimer = null;
      void connectGeneration(reason).catch((err) => scheduleRetry(reason, err));
    }, delay);
  };

  const scheduleRenewal = (config, activeGeneration) => {
    if (renewalTimer) clearTimeout(renewalTimer);
    const delay = renewalDelayMs(config.expiresAt, Date.now(), renewalSkewMs, jitterSeed, activeGeneration);
    renewalTimer = setTimeout(() => {
      renewalTimer = null;
      void connectGeneration("renewal").catch((err) => scheduleRetry("renewal", err));
    }, delay);
  };

  const subscribeCandidate = (client, topics) => new Promise((resolve, reject) => {
    let connected = false;
    let done = false;
    let timer;
    const cleanup = () => {
      if (timer) clearTimeout(timer);
      client.removeListener("error", fail);
      client.removeListener("close", closed);
      candidateCancels.delete(client);
    };
    const fail = (err) => {
      if (done) return;
      done = true;
      cleanup();
      reject(err instanceof Error ? err : new Error(String(err)));
    };
    const closed = () => {
      if (!connected) fail(new Error("MQTT connection closed before subscription"));
    };
    timer = setTimeout(() => fail(new Error("MQTT connection timed out")), connectTimeoutMs);
    candidateCancels.set(client, () => fail(new Error("MQTT subscription cancelled")));
    client.once("error", fail);
    client.once("close", closed);
    client.once("connect", () => {
      if (done) return;
      connected = true;
      client.subscribe(topics, { qos: 1 }, (err, granted) => {
        if (done) return;
        if (err) return fail(err);
        const accepted = Array.isArray(granted) ? granted : [];
        const acceptedTopics = accepted.filter((grant) => grant.qos === 1).map((grant) => grant.topic);
        if (
          acceptedTopics.length !== topics.length ||
          topics.some((topic) => !acceptedTopics.includes(topic)) ||
          accepted.some((grant) => grant.qos !== 1)
        ) return fail(new Error("MQTT QoS1 subscription was not granted exactly"));
        done = true;
        cleanup();
        resolve(acceptedTopics);
      });
    });
  });

  async function connectGeneration(reason, suppliedConfig) {
    if (settled || authBlocked) return;
    if (connectInFlight) return connectInFlight;
    const epoch = lifecycleEpoch;
    const candidateGeneration = ++generation;
    connectInFlight = (async () => {
      const config = suppliedConfig ?? await fetchRealtimeConfig(
        auth.apiUrl,
        await refreshAuthToken(auth),
        lifecycleController.signal,
      );
      if (
        config.contractVersion !== initialConfig.contractVersion ||
        (config.contractVersion === 2 && (
          config.principalUid !== initialConfig.principalUid ||
          config.topics.work !== initialConfig.topics.work
        ))
      ) {
        throw new WorkMeshContractError("renewed realtime contract, identity, or work topic changed");
      }
      const topics = mqttTopicsForConfig(config, companyUid);
      if (topics.length === 0) throw new WorkMeshContractError("no MQTT topics returned by realtime credentials");
      if (config.contractVersion === 2 && topics.length !== 1) {
        throw new WorkMeshContractError("realtime v2 must subscribe only to the personal work topic");
      }
      const clientId = config.contractVersion === 2
        ? config.clientId
        : `hq-work-mesh-${safeName(os.hostname()).slice(0, 30)}-${crypto.randomBytes(4).toString("hex")}`;
      const client = mqtt.connect(presignIotWss(config.credentials, config.iotEndpoint, config.region), {
        clientId,
        protocolVersion: 4,
        reconnectPeriod: 0,
        connectTimeout: connectTimeoutMs,
      });
      clients.add(client);
      let promoted = false;
      client.on("error", (err) => {
        if (!settled && promoted && active?.generation === candidateGeneration) {
          active = null;
          closeClient(client);
          scheduleRetry("reconnect", err);
        }
      });
      client.on("message", (topic, payload) => {
        if (settled || authBlocked || !promoted || active?.generation !== candidateGeneration || lifecycleEpoch !== epoch) return;
        if (config.contractVersion === 2) {
          if (topic !== config.topics.work) return;
          const wake = parseRealtimeV2Wake(payload);
          if (
            !wake || wake.scope !== "work" || wake.eventType !== "work.changed" ||
            wake.recipientUid !== config.principalUid || !rememberWake(wake.eventId)
          ) return;
          requestReconcile("wake").then(() => {
            if (settled || active?.generation !== candidateGeneration) return;
            messageCount += 1;
            if (!opts.silent && !opts.json) console.log(`Work mesh MQTT: message ${messageCount} on ${topic}`);
            if (opts.once) finishWatch({ ...ready, dryRun: false, messageCount, once: true });
          }).catch(() => {});
          return;
        }
        const next = applyMqttMessageToCache(readLiveCache(opts), topic, payload);
        writeLiveCache(opts, next);
        messageCount += 1;
        if (!opts.silent && !opts.json) console.log(`Work mesh MQTT: message ${messageCount} on ${topic}`);
        if (opts.once) finishWatch({ ...ready, dryRun: false, messageCount, once: true });
      });
      client.on("close", () => {
        clients.delete(client);
        if (!settled && promoted && active?.generation === candidateGeneration) {
          active = null;
          scheduleRetry("reconnect", new Error("MQTT connection closed"));
        }
      });
      let previous;
      try {
        await subscribeCandidate(client, topics);
        if (settled || lifecycleEpoch !== epoch || candidateGeneration !== generation) {
          closeClient(client);
          return;
        }
        previous = active;
        active = { client, config, generation: candidateGeneration };
        promoted = true;
        latestConfig = config;
        reconcileConfig = config;
        retryAttempt = 0;
        if (retryTimer) clearTimeout(retryTimer);
        retryTimer = null;
        if (config.contractVersion === 2) {
          if (!coordinator) throw new WorkMeshContractError("realtime v2 reconciler is unavailable");
          const reconciled = await coordinator.run(reason === "initial" ? "initial" : reason);
          reconcileRetryAttempt = 0;
          if (reconcileRetryTimer) clearTimeout(reconcileRetryTimer);
          reconcileRetryTimer = null;
          ready.threadCount = Object.keys(reconciled.cache.threadsById || {}).length;
          ready.projectCount = Object.keys(reconciled.cache.projects || {}).length;
        } else if (reason !== "initial") {
          const hydrated = await hydrateLiveCache(auth.apiUrl, await refreshAuthToken(auth), config, opts, companyUid);
          ready.threadCount = Object.keys(hydrated.threadsById || {}).length;
          ready.projectCount = Object.keys(hydrated.projects || {}).length;
        }
        ready.realtime = redactedRealtimeConfig(config, companyUid);
        closeClient(previous?.client);
        scheduleRenewal(config, candidateGeneration);
        schedulePeriodic();
        return topics;
      } catch (err) {
        if (!promoted) closeClient(client);
        else closeClient(previous?.client);
        throw err;
      }
    })().finally(() => {
      connectInFlight = null;
    });
    return connectInFlight;
  }

  const result = await new Promise((resolve, reject) => {
    const timeoutTimer = timeoutMs > 0
      ? setTimeout(() => finishWatch({ ...ready, dryRun: false, timedOut: true, messageCount }), timeoutMs)
      : null;
    const stop = () => finishWatch({ ...ready, dryRun: false, stopped: true, messageCount });
    finishWatch = (value, isError = false) => {
      if (settled) return;
      settled = true;
      lifecycleEpoch += 1;
      if (timeoutTimer) clearTimeout(timeoutTimer);
      if (renewalTimer) clearTimeout(renewalTimer);
      if (retryTimer) clearTimeout(retryTimer);
      if (reconcileRetryTimer) clearTimeout(reconcileRetryTimer);
      if (periodicTimer) clearTimeout(periodicTimer);
      lifecycleController.abort();
      coordinator?.stop();
      for (const cancel of [...candidateCancels.values()]) cancel();
      candidateCancels.clear();
      for (const client of [...clients]) closeClient(client);
      clients.clear();
      process.removeListener("SIGINT", stop);
      process.removeListener("SIGTERM", stop);
      if (isError) reject(value);
      else resolve(value);
    };
    process.once("SIGINT", stop);
    process.once("SIGTERM", stop);
    connectGeneration("initial", initialConfig).then((acceptedTopics) => {
      if (!settled && !opts.json) printWatchReady({ ...ready, dryRun: false, topics: acceptedTopics }, opts);
    }).catch((err) => finishWatch(err, true));
  });

  if (opts.json && result) console.log(JSON.stringify(result, null, 2));
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const command = normalizeCommand(opts.command);

  if (opts.help || command === "help" || command === "-h") {
    console.log(usage());
    return;
  }

  if (isTruthyEnv("HQ_WORK_MESH_DISABLED")) {
    if (opts.json) console.log(JSON.stringify({ ok: true, skipped: true, reason: "disabled" }));
    return;
  }

  if (!["check", "start", "progress", "blocked", "done", "note", "watch"].includes(command)) {
    console.error(usage());
    process.exitCode = 2;
    return;
  }

  if (!["check", "watch"].includes(command) && !opts.project) {
    failSoft(opts, "project is required");
    return;
  }

  let auth;
  try {
    auth = await resolveAuth();
  } catch (err) {
    failSoft(opts, "auth unavailable", err instanceof Error ? err.message : err);
    return;
  }

  if (command === "watch") {
    let company;
    if (opts.company) {
      try {
        company = await resolveCompanyUid(auth.apiUrl, auth.token, opts.company);
      } catch (err) {
        failSoft(opts, "company unavailable", err instanceof Error ? err.message : err, [auth.token]);
        return;
      }
    }
    let releaseCacheLock;
    try {
      opts.cache_file = canonicalDestination(liveCacheFile(opts));
      releaseCacheLock = acquireCacheLock(opts);
      await watchWorkMesh(auth, opts, company);
    } catch (err) {
      failSoft(opts, "watch failed", err instanceof Error ? err.message : err, [auth.token]);
    } finally {
      releaseCacheLock?.();
    }
    return;
  }

  let company;
  try {
    company = await resolveCompanyUid(auth.apiUrl, auth.token, opts.company);
  } catch (err) {
    failSoft(opts, "company unavailable", err instanceof Error ? err.message : err, [auth.token]);
    return;
  }

  if (command === "check") {
    try {
      const threads = activeProjectThreads(await listThreads(auth.apiUrl, auth.token, company.companyUid, opts.project));
      printCheck(threads, company, opts.project, opts);
    } catch (err) {
      const cached = cachedActiveThreads(company.companyUid, opts.project, opts);
      if (cached.length > 0) {
        printCheck(cached, company, opts.project, opts);
      } else {
        failSoft(opts, "check failed", err instanceof Error ? err.message : err, [auth.token]);
      }
    }
    return;
  }

  try {
    const ensured = await ensureThread(auth.apiUrl, auth.token, company, opts.project, opts);
    const eventKind = command === "start" ? "claim" : command;
    const payload = eventPayload(eventKind, opts, auth.token);
    const event = opts.dry_run
      ? { eventId: "dry-run-event", createdAt: new Date().toISOString() }
      : await appendEvent(auth.apiUrl, auth.token, company.companyUid, ensured.threadId, eventKind, payload);

    printResult(
      {
        ok: true,
        action: command,
        eventKind,
        company,
        projectId: opts.project,
        threadId: ensured.threadId,
        created: ensured.created,
        eventId: event.eventId,
        createdAt: event.createdAt,
      },
      opts,
    );
  } catch (err) {
    failSoft(opts, `${command} failed`, err instanceof Error ? err.message : err, [auth.token]);
  }
}

export {
  acquireCacheLock,
  applyWorkFeedToCache,
  buildProjectRollups,
  createBoundedLruSet,
  createReconcileCoordinator,
  cursorBinding,
  cursorFileFor,
  deterministicBackoffMs,
  deterministicJitterMs,
  fetchRealtimeConfig,
  loadBoundCursor,
  mqttTopicsForConfig,
  parseRealtimeV1Config,
  parseRealtimeV2Config,
  parseRealtimeV2Wake,
  parseWorkFeed,
  readBoundedResponseText,
  reconcileV2,
  redactedDiagnostic,
  redactedRealtimeConfig,
  resolveApiUrl,
  renewalDelayMs,
  saveBoundCursor,
  writeJson,
  writeLiveCache,
};

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  await main();
}
