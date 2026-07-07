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
const require = createRequire(import.meta.url);

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
  HQ_WORK_MESH_TOKEN=<jwt>     Use this bearer token instead of HQ auth cache
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

function failSoft(opts, reason, detail) {
  if (opts.json) {
    console.log(JSON.stringify({ ok: false, skipped: true, reason, detail: detail ? String(detail) : undefined }));
  } else if (!opts.silent && isTruthyEnv("HQ_WORK_MESH_DEBUG")) {
    console.error(`work-mesh skipped: ${reason}${detail ? ` (${detail})` : ""}`);
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
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
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
    if (thread.ownerUid && !existing.owners.includes(thread.ownerUid)) {
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
    candidates.push(path.resolve(process.env.HQ_COGNITO_SESSION_MODULE));
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
    };
  }

  const auth = await importCognitoSession();
  const token = auth.ensureCognitoIdToken
    ? await auth.ensureCognitoIdToken({ interactive: false })
    : await auth.ensureCognitoToken({ interactive: false });
  const apiUrl = resolveApiUrl(auth);
  return { token, apiUrl };
}

function resolveApiUrl(auth = {}) {
  const apiUrl =
    process.env.HQ_WORK_MESH_API_URL ||
    process.env.HQ_VAULT_API_URL ||
    process.env.HQ_API_URL ||
    process.env.HQ_PRO_API_URL ||
    auth.DEFAULT_VAULT_API_URL;
  if (!apiUrl) {
    throw new Error("HQ Work Mesh API URL unavailable; set HQ_WORK_MESH_API_URL");
  }
  return apiUrl.replace(/\/+$/, "");
}

function authHeaders(token, json = false) {
  return {
    Authorization: `Bearer ${token}`,
    ...(json ? { "Content-Type": "application/json" } : {}),
  };
}

async function fetchJson(url, token, init = {}) {
  const timeoutMs = Number(process.env.HQ_WORK_MESH_TIMEOUT_MS || "2000");
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, { ...init, signal: controller.signal });
    const text = await response.text();
    const body = text ? JSON.parse(text) : {};
    if (!response.ok) {
      const message = typeof body.error === "string" ? body.error : `HTTP ${response.status}`;
      throw new Error(message);
    }
    return body;
  } finally {
    clearTimeout(timer);
  }
}

async function getJson(apiUrl, token, pathname) {
  return fetchJson(`${apiUrl}${pathname}`, token, { headers: authHeaders(token) });
}

async function postJson(apiUrl, token, pathname, body) {
  return fetchJson(`${apiUrl}${pathname}`, token, {
    method: "POST",
    headers: authHeaders(token, true),
    body: JSON.stringify(compact(body) ?? {}),
  });
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

async function fetchRealtimeConfig(apiUrl, token) {
  const data = await postJson(apiUrl, token, "/v1/realtime/credentials", {});
  const dmTopic = data.topics?.dm || data.topic;
  const personUid = typeof dmTopic === "string" ? dmTopic.split("/")[1] : undefined;
  const workTopic = data.topics?.work || (personUid ? `hq/${personUid}/work` : undefined);
  return {
    ...data,
    topics: {
      ...(data.topics || {}),
      ...(dmTopic ? { dm: dmTopic } : {}),
      ...(workTopic ? { work: workTopic } : {}),
    },
    companyTopics: Array.isArray(data.companyTopics) ? data.companyTopics : [],
  };
}

function mqttTopicsForConfig(config, companyUid) {
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
  return {
    iotEndpoint: config.iotEndpoint,
    region: config.region,
    topics: config.topics,
    companyTopics: config.companyTopics
      .filter((entry) => !companyUid || entry.companyUid === companyUid)
      .map((entry) => ({
        companyUid: entry.companyUid,
        threadTopicFilter: entry.threadTopicFilter,
        presenceTopic: entry.presenceTopic,
      })),
    expiresAt: config.expiresAt || config.credentials?.expiration,
  };
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
  const config = await fetchRealtimeConfig(auth.apiUrl, auth.token);
  const companyUid = company?.companyUid;
  const topics = mqttTopicsForConfig(config, companyUid);
  if (topics.length === 0) {
    throw new Error("no MQTT topics returned by realtime credentials");
  }

  const cache = await hydrateLiveCache(auth.apiUrl, auth.token, config, opts, companyUid);
  const ready = {
    ok: true,
    action: "watch",
    dryRun: Boolean(opts.dry_run),
    cacheFile: liveCacheFile(opts),
    topics,
    threadCount: Object.keys(cache.threadsById || {}).length,
    projectCount: Object.keys(cache.projects || {}).length,
    realtime: redactedRealtimeConfig(config, companyUid),
  };

  if (opts.dry_run) {
    printWatchReady(ready, opts);
    return;
  }

  const mqtt = requireMqttModule();
  const clientId = `hq-work-mesh-${safeName(os.hostname()).slice(0, 30)}-${crypto.randomBytes(4).toString("hex")}`;
  const url = presignIotWss(config.credentials, config.iotEndpoint, config.region);
  const client = mqtt.connect(url, {
    clientId,
    protocolVersion: 4,
    reconnectPeriod: 0,
    connectTimeout: Number(process.env.HQ_WORK_MESH_MQTT_CONNECT_TIMEOUT_MS || "8000"),
  });

  let settled = false;
  let messageCount = 0;
  const timeoutMs = Number(opts.timeout_ms || process.env.HQ_WORK_MESH_WATCH_TIMEOUT_MS || (opts.once ? "10000" : "0"));

  const result = await new Promise((resolve, reject) => {
    const finish = (value, isError = false) => {
      if (settled) return;
      settled = true;
      try {
        client.end(true);
      } catch {
        // Ignore shutdown errors.
      }
      if (timer) clearTimeout(timer);
      if (isError) reject(value);
      else resolve(value);
    };

    const timer = timeoutMs > 0
      ? setTimeout(() => finish({ ...ready, dryRun: false, timedOut: true, messageCount }), timeoutMs)
      : null;

    const stop = () => finish({ ...ready, dryRun: false, stopped: true, messageCount });
    process.once("SIGINT", stop);
    process.once("SIGTERM", stop);

    client.once("connect", () => {
      client.subscribe(topics, { qos: 1 }, (err, granted) => {
        if (err) {
          finish(err, true);
          return;
        }
        const accepted = (granted || []).filter((grant) => grant.qos !== 128);
        if (accepted.length === 0) {
          finish(new Error("MQTT subscribe denied for all topics"), true);
          return;
        }
        if (!opts.json) {
          printWatchReady({ ...ready, dryRun: false, topics: accepted.map((grant) => grant.topic) }, opts);
        }
      });
    });

    client.on("message", (topic, payload) => {
      const current = readLiveCache(opts);
      const next = applyMqttMessageToCache(current, topic, payload);
      writeLiveCache(opts, next);
      messageCount += 1;
      if (!opts.silent && !opts.json) {
        console.log(`Work mesh MQTT: message ${messageCount} on ${topic}`);
      }
      if (opts.once) {
        finish({ ...ready, dryRun: false, messageCount, once: true });
      }
    });

    client.once("error", (err) => finish(err, true));
    client.once("close", () => {
      if (!settled && timeoutMs === 0) finish(new Error("MQTT connection closed"), true);
    });
  });

  if (opts.json && result) {
    console.log(JSON.stringify(result, null, 2));
  }
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
        failSoft(opts, "company unavailable", err instanceof Error ? err.message : err);
        return;
      }
    }
    try {
      await watchWorkMesh(auth, opts, company);
    } catch (err) {
      failSoft(opts, "watch failed", err instanceof Error ? err.message : err);
    }
    return;
  }

  let company;
  try {
    company = await resolveCompanyUid(auth.apiUrl, auth.token, opts.company);
  } catch (err) {
    failSoft(opts, "company unavailable", err instanceof Error ? err.message : err);
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
        failSoft(opts, "check failed", err instanceof Error ? err.message : err);
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
    failSoft(opts, `${command} failed`, err instanceof Error ? err.message : err);
  }
}

await main();
