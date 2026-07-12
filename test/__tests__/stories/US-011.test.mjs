import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const HELPER = path.join(ROOT, "core/scripts/work-mesh.mjs");
const PERSON = "prs_01ARZ3NDEKTSV4RRFFQ69G5FAV";
const WORK_TOPIC = `hq/${PERSON}/work`;

function thread(index, status = "open") {
  return {
    threadId: `thr_${String(index).padStart(3, "0")}`,
    companyUid: `cmp_${String(index).padStart(3, "0")}`,
    threadStatus: status,
    projectId: `project_${index}`,
    lastActivityAt: "2026-07-11T12:00:00.000Z",
    createdAt: "2026-07-11T11:00:00.000Z",
    routing: { priority: "normal" },
    participantRefs: [],
  };
}

function writeFakeMqttModule(dir) {
  const file = path.join(dir, "fake-mqtt.cjs");
  fs.writeFileSync(file, `
const { EventEmitter } = require("node:events");
const fs = require("node:fs");
let connectionCount = 0;
const PERSON = ${JSON.stringify(PERSON)};
const TOPIC = ${JSON.stringify(WORK_TOPIC)};
function log(value) { fs.appendFileSync(process.env.FAKE_MQTT_LOG, JSON.stringify(value) + "\\n"); }
exports.connect = (_url, options) => {
  connectionCount += 1;
  const number = connectionCount;
  if (process.env.FAKE_MQTT_SCENARIO === "throw-url") {
    throw new Error("connect failed " + _url + " Bearer " + process.env.HQ_WORK_MESH_TOKEN);
  }
  const client = new EventEmitter();
  let ended = false;
  log({ type: "connect", number, clientId: options.clientId, reconnectPeriod: options.reconnectPeriod });
  client.subscribe = (topics, options, callback) => {
    log({ type: "subscribe", number, topics, qos: options.qos });
    setImmediate(() => callback(null, topics.map((topic) => ({ topic, qos: 1 }))));
    if (!process.env.FAKE_MQTT_SCENARIO && number === 1) {
      const wake = {
        contractVersion: 2,
        eventId: "evt_wake_1",
        eventType: "work.changed",
        scope: "work",
        resourceId: "thr_001",
        recipientUid: PERSON,
        createdAt: "2026-07-11T12:00:01.000Z"
      };
      setTimeout(() => client.emit("message", TOPIC, Buffer.from(JSON.stringify({ ...wake, details: "reject" }))), 10);
      setTimeout(() => client.emit("message", TOPIC, Buffer.from(JSON.stringify(wake))), 15);
      setTimeout(() => client.emit("message", TOPIC, Buffer.from(JSON.stringify(wake))), 16);
    }
    if (!process.env.FAKE_MQTT_SCENARIO && number === 2) {
      setTimeout(() => { if (!ended) client.emit("close"); }, 35);
    }
  };
  client.end = () => {
    ended = true;
    log({ type: "end", number });
    if (process.env.FAKE_MQTT_SCENARIO === "stale-generation" && number === 1) {
      const staleWake = {
        contractVersion: 2,
        eventId: "evt_stale_generation",
        eventType: "work.changed",
        scope: "work",
        resourceId: "thr_001",
        recipientUid: PERSON,
        createdAt: "2026-07-11T12:00:02.000Z"
      };
      log({ type: "stale-message", number });
      client.emit("message", TOPIC, Buffer.from(JSON.stringify(staleWake)));
    }
    client.emit("close");
  };
  if (process.env.FAKE_MQTT_SCENARIO === "hang") return client;
  setImmediate(() => client.emit("connect"));
  return client;
};
`, { mode: 0o600 });
  return file;
}

function writeRefreshingAuthModule(dir) {
  const file = path.join(dir, "refreshing-auth.mjs");
  fs.writeFileSync(file, `
import fs from "node:fs";
let count = 0;
export async function ensureCognitoIdToken() {
  count += 1;
  fs.appendFileSync(process.env.FAKE_AUTH_LOG, String(count) + "\\n");
  return "refresh-token-" + count;
}
`, { mode: 0o600 });
  return file;
}

async function startFixtureServer({
  failCredentialsAfter = Infinity,
  expiryMs = 300,
  renewedExpiryMs = expiryMs,
  feedDelayAfter = Infinity,
  feedDelayMs = 0,
} = {}) {
  const requests = [];
  let credentialCount = 0;
  let feedCount = 0;
  const server = http.createServer((req, res) => {
    let raw = "";
    req.on("data", (chunk) => { raw += chunk; });
    req.on("end", () => {
      const url = new URL(req.url, "http://fixture.test");
      const body = raw ? JSON.parse(raw) : null;
      requests.push({
        method: req.method,
        pathname: url.pathname,
        cursor: url.searchParams.get("cursor"),
        authorization: req.headers.authorization,
        body,
      });
      const send = (status, value) => {
        res.writeHead(status, { "Content-Type": "application/json" });
        res.end(JSON.stringify(value));
      };
      if (req.method === "POST" && url.pathname === "/v1/realtime/credentials") {
        credentialCount += 1;
        if (credentialCount > failCredentialsAfter) {
          send(401, { error: "expired" });
          return;
        }
        const credentialExpiryMs = credentialCount === 1 ? expiryMs : renewedExpiryMs;
        const expiresAt = new Date(Date.now() + credentialExpiryMs).toISOString();
        const suffix = String(credentialCount).padStart(12, "0");
        send(200, {
          contractVersion: 2,
          credentials: {
            accessKeyId: `ASIA${String(credentialCount).padStart(16, "0")}`,
            secretAccessKey: "secret",
            sessionToken: "session-token",
            expiration: expiresAt,
          },
          iotEndpoint: "abc123-ats.iot.us-east-1.amazonaws.com",
          region: "us-east-1",
          clientId: `rt2-${String(credentialCount).padStart(8, "0")}-0000-4000-8000-${suffix}`,
          topic: `hq/${PERSON}/dm`,
          topics: {
            dm: `hq/${PERSON}/dm`,
            sessions: `hq/${PERSON}/sessions`,
            work: WORK_TOPIC,
            notifications: `hq/${PERSON}/notifications`,
          },
          expiresAt,
        });
        return;
      }
      if (req.method === "GET" && url.pathname === "/v1/work-mesh/work") {
        feedCount += 1;
        const revoked = feedCount >= 3;
        const open = Array.from({ length: 150 }, (_, index) => thread(index))
          .filter((item) => !revoked || item.companyUid !== "cmp_000");
        if (feedCount >= 2) open.find((item) => item.threadId === "thr_001").threadStatus = "blocked";
        const response = {
          contractVersion: 2,
          snapshot: feedCount === 1,
          reset: false,
          cursor: String(feedCount).padStart(43, "0"),
          cursorExpiresAt: new Date(Date.now() + 5_000).toISOString(),
          removedCompanyUids: revoked ? ["cmp_000"] : [],
          open,
          changed: feedCount === 1 ? [] : [thread(1, "blocked")],
        };
        if (feedCount >= feedDelayAfter) setTimeout(() => send(200, response), feedDelayMs);
        else send(200, response);
        return;
      }
      send(404, { error: "not found" });
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return {
    apiUrl: `http://127.0.0.1:${server.address().port}`,
    requests,
    counts: () => ({ credentialCount, feedCount }),
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}

function runWatcher(env, timeoutMs) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [HELPER, "watch", "--json", "--timeout-ms", String(timeoutMs), "--cache-file", env.CACHE_FILE], {
      cwd: ROOT,
      env: { ...process.env, ...env },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code !== 0) reject(new Error(`watcher exited ${code}: ${stderr || stdout}`));
      else resolve(JSON.parse(stdout));
    });
  });
}

test("US-011 accelerated expiry, offline reconnect, wake, revocation, and high-company flow", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "us-011-e2e-"));
  const server = await startFixtureServer({ expiryMs: 260 });
  try {
    const mqttLog = path.join(dir, "mqtt.jsonl");
    const result = await runWatcher({
      CACHE_FILE: path.join(dir, "cache.json"),
      FAKE_MQTT_LOG: mqttLog,
      HQ_ROOT: dir,
      HQ_WORK_MESH_TOKEN: "static-test-token",
      HQ_WORK_MESH_API_URL: server.apiUrl,
      HQ_WORK_MESH_MQTT_MODULE: writeFakeMqttModule(dir),
      HQ_WORK_MESH_RENEWAL_SKEW_MS: "120",
      HQ_WORK_MESH_RETRY_BASE_MS: "5",
      HQ_WORK_MESH_RETRY_MAX_MS: "20",
      HQ_WORK_MESH_RECONCILE_DEBOUNCE_MS: "2",
      HQ_WORK_MESH_PERIODIC_RECONCILE_MS: "1000",
      HQ_WORK_MESH_JITTER_SEED: "11",
    }, 520);
    assert.equal(result.timedOut, true);
    assert.equal(result.topics.length, 1);
    assert.equal(result.topics[0], WORK_TOPIC);
    assert.equal(result.threadCount, 149);
    assert.equal(result.messageCount, 1, "duplicate and invalid wakes do not trigger extra visible work");

    const mqtt = fs.readFileSync(mqttLog, "utf8").trim().split("\n").map(JSON.parse);
    const connects = mqtt.filter((row) => row.type === "connect");
    const subscriptions = mqtt.filter((row) => row.type === "subscribe");
    assert.ok(connects.length >= 3, "credential renewal and offline reconnect create fresh generations");
    assert.ok(connects.every((row) => /^rt2-/.test(row.clientId) && row.reconnectPeriod === 0));
    assert.ok(subscriptions.every((row) => row.qos === 1 && JSON.stringify(row.topics) === JSON.stringify([WORK_TOPIC])));
    assert.ok(
      mqtt.findIndex((row) => row.type === "connect" && row.number === 2) <
        mqtt.findIndex((row) => row.type === "end" && row.number === 1),
      "renewal connects and subscribes the candidate before ending the prior generation",
    );

    const credentialRequests = server.requests.filter((row) => row.pathname === "/v1/realtime/credentials");
    assert.ok(credentialRequests.length >= 3);
    assert.ok(credentialRequests.every((row) => JSON.stringify(row.body) === '{"contractVersion":2}'));
    const feedRequests = server.requests.filter((row) => row.pathname === "/v1/work-mesh/work");
    assert.ok(feedRequests.length >= 4);
    assert.equal(feedRequests[0].cursor, null);
    assert.ok(feedRequests.slice(1).every((row) => typeof row.cursor === "string" && row.cursor.length === 43));

    const cache = JSON.parse(fs.readFileSync(path.join(dir, "cache.json"), "utf8"));
    assert.equal(JSON.stringify(cache).includes("must-not-cross"), false);
    assert.equal(JSON.stringify(cache).includes('"details":"reject"'), false);
    assert.equal(cache.schemaVersion, 1);
    assert.equal(Object.keys(cache.threadsById).length, 149);
    assert.equal(cache.threadsById.thr_000, undefined);
    assert.equal(cache.threadsById.thr_001.threadStatus, "blocked");
    assert.equal(fs.statSync(path.join(dir, "cache.json")).mode & 0o777, 0o600);
    assert.equal(fs.statSync(path.join(dir, "cache.json.cursor-v2.json")).mode & 0o777, 0o600);
  } finally {
    await server.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("US-011 static token shuts down promptly after renewal rejection", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "us-011-static-"));
  const server = await startFixtureServer({ failCredentialsAfter: 1, expiryMs: 180 });
  try {
    const started = Date.now();
    const result = await runWatcher({
      CACHE_FILE: path.join(dir, "cache.json"),
      FAKE_MQTT_LOG: path.join(dir, "mqtt.jsonl"),
      FAKE_MQTT_SCENARIO: "quiet",
      HQ_ROOT: dir,
      HQ_WORK_MESH_TOKEN: "non-refreshable-static-token",
      HQ_WORK_MESH_API_URL: server.apiUrl,
      HQ_WORK_MESH_MQTT_MODULE: writeFakeMqttModule(dir),
      HQ_WORK_MESH_RENEWAL_SKEW_MS: "100",
      HQ_WORK_MESH_RETRY_BASE_MS: "5",
      HQ_WORK_MESH_RETRY_MAX_MS: "10",
      HQ_WORK_MESH_PERIODIC_RECONCILE_MS: "1000",
    }, 5_000);
    assert.equal(result.reason, "watch failed");
    assert.match(result.detail, /401/);
    assert.ok(Date.now() - started < 1_000, "static auth rejection must not leave an idle watcher");
    assert.equal(server.counts().credentialCount, 2);
    const mqtt = fs.readFileSync(path.join(dir, "mqtt.jsonl"), "utf8").trim().split("\n").map(JSON.parse);
    assert.ok(mqtt.some((row) => row.type === "end" && row.number === 1));
  } finally {
    await server.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("US-011 restart resumes its bound cursor and reconciles offline changes", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "us-011-restart-"));
  const server = await startFixtureServer({ expiryMs: 10_000 });
  const cacheFile = path.join(dir, "cache.json");
  const env = {
    CACHE_FILE: cacheFile,
    FAKE_MQTT_LOG: path.join(dir, "mqtt.jsonl"),
    FAKE_MQTT_SCENARIO: "quiet",
    HQ_ROOT: dir,
    HQ_WORK_MESH_TOKEN: "static-test-token",
    HQ_WORK_MESH_API_URL: server.apiUrl,
    HQ_WORK_MESH_MQTT_MODULE: writeFakeMqttModule(dir),
    HQ_WORK_MESH_PERIODIC_RECONCILE_MS: "1000",
  };
  try {
    await runWatcher(env, 90);
    const firstCursor = JSON.parse(fs.readFileSync(`${cacheFile}.cursor-v2.json`, "utf8")).cursor;
    assert.equal(firstCursor, "1".padStart(43, "0"));

    await runWatcher(env, 90);
    const feedRequests = server.requests.filter((row) => row.pathname === "/v1/work-mesh/work");
    assert.equal(feedRequests.length, 2);
    assert.equal(feedRequests[0].cursor, null);
    assert.equal(feedRequests[1].cursor, firstCursor);
    const cache = JSON.parse(fs.readFileSync(cacheFile, "utf8"));
    assert.equal(cache.threadsById.thr_001.threadStatus, "blocked");
    assert.equal(JSON.parse(fs.readFileSync(`${cacheFile}.cursor-v2.json`, "utf8")).cursor, "2".padStart(43, "0"));
  } finally {
    await server.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("US-011 stale generation callbacks cannot trigger reconciliation", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "us-011-generation-guard-"));
  const server = await startFixtureServer({ expiryMs: 400, renewedExpiryMs: 10_000 });
  try {
    const mqttLog = path.join(dir, "mqtt.jsonl");
    const result = await runWatcher({
      CACHE_FILE: path.join(dir, "cache.json"),
      FAKE_MQTT_LOG: mqttLog,
      FAKE_MQTT_SCENARIO: "stale-generation",
      HQ_ROOT: dir,
      HQ_WORK_MESH_TOKEN: "static-test-token",
      HQ_WORK_MESH_API_URL: server.apiUrl,
      HQ_WORK_MESH_MQTT_MODULE: writeFakeMqttModule(dir),
      HQ_WORK_MESH_RENEWAL_SKEW_MS: "250",
      HQ_WORK_MESH_PERIODIC_RECONCILE_MS: "1000",
      HQ_WORK_MESH_JITTER_SEED: "11",
    }, 1_000);
    assert.equal(result.messageCount, 0);
    const counts = server.counts();
    assert.ok(counts.credentialCount >= 2, "the old generation must be replaced before its delayed callback");
    assert.equal(counts.feedCount, counts.credentialCount, "stale callbacks must not add reconciliation passes");
    const mqtt = fs.readFileSync(mqttLog, "utf8").trim().split("\n").map(JSON.parse);
    assert.ok(mqtt.some((row) => row.type === "end" && row.number === 1));
    assert.ok(mqtt.some((row) => row.type === "stale-message" && row.number === 1));
  } finally {
    await server.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("US-011 fail-soft JSON redacts signed MQTT URLs and bearer tokens", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "us-011-redaction-"));
  const server = await startFixtureServer({ expiryMs: 10_000 });
  try {
    const result = await runWatcher({
      CACHE_FILE: path.join(dir, "cache.json"),
      FAKE_MQTT_LOG: path.join(dir, "mqtt.jsonl"),
      FAKE_MQTT_SCENARIO: "throw-url",
      HQ_ROOT: dir,
      HQ_WORK_MESH_TOKEN: "non-refreshable-private-token",
      HQ_WORK_MESH_API_URL: server.apiUrl,
      HQ_WORK_MESH_MQTT_MODULE: writeFakeMqttModule(dir),
    }, 200);
    const serialized = JSON.stringify(result);
    assert.equal(result.reason, "watch failed");
    assert.equal(serialized.includes("non-refreshable-private-token"), false);
    assert.equal(serialized.includes("X-Amz-"), false);
    assert.equal(serialized.includes("session-token"), false);
    assert.match(result.detail, /redacted signed URL/);
  } finally {
    await server.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("US-011 renewable auth refreshes the bearer token for credentials and reconciliation", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "us-011-refresh-"));
  const server = await startFixtureServer({ expiryMs: 180 });
  try {
    const authLog = path.join(dir, "auth.log");
    await runWatcher({
      CACHE_FILE: path.join(dir, "cache.json"),
      FAKE_AUTH_LOG: authLog,
      FAKE_MQTT_LOG: path.join(dir, "mqtt.jsonl"),
      FAKE_MQTT_SCENARIO: "quiet",
      HQ_ROOT: dir,
      HQ_WORK_MESH_TOKEN: "",
      HQ_COGNITO_SESSION_MODULE: writeRefreshingAuthModule(dir),
      HQ_WORK_MESH_API_URL: server.apiUrl,
      HQ_WORK_MESH_MQTT_MODULE: writeFakeMqttModule(dir),
      HQ_WORK_MESH_RENEWAL_SKEW_MS: "100",
      HQ_WORK_MESH_RETRY_BASE_MS: "5",
      HQ_WORK_MESH_RETRY_MAX_MS: "10",
      HQ_WORK_MESH_PERIODIC_RECONCILE_MS: "1000",
    }, 300);
    const credentialRequests = server.requests.filter((row) => row.pathname === "/v1/realtime/credentials");
    const feedRequests = server.requests.filter((row) => row.pathname === "/v1/work-mesh/work");
    assert.ok(credentialRequests.length >= 2);
    assert.ok(new Set(credentialRequests.map((row) => row.authorization)).size >= 2);
    assert.ok(new Set(feedRequests.map((row) => row.authorization)).size >= 2);
    assert.ok(fs.readFileSync(authLog, "utf8").trim().split("\n").length >= 5);
  } finally {
    await server.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("US-011 shutdown cancels an unconnected candidate without waiting for connect timeout", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "us-011-shutdown-"));
  const server = await startFixtureServer({ expiryMs: 10_000 });
  try {
    const started = Date.now();
    const result = await runWatcher({
      CACHE_FILE: path.join(dir, "cache.json"),
      FAKE_AUTH_LOG: path.join(dir, "auth.log"),
      FAKE_MQTT_LOG: path.join(dir, "mqtt.jsonl"),
      FAKE_MQTT_SCENARIO: "hang",
      HQ_ROOT: dir,
      HQ_WORK_MESH_TOKEN: "static-test-token",
      HQ_WORK_MESH_API_URL: server.apiUrl,
      HQ_WORK_MESH_MQTT_MODULE: writeFakeMqttModule(dir),
      HQ_WORK_MESH_MQTT_CONNECT_TIMEOUT_MS: "5000",
    }, 40);
    const elapsedMs = Date.now() - started;
    assert.equal(result.timedOut, true);
    assert.ok(elapsedMs < 1_000, `shutdown took ${elapsedMs}ms`);
    const mqtt = fs.readFileSync(path.join(dir, "mqtt.jsonl"), "utf8").trim().split("\n").map(JSON.parse);
    assert.ok(mqtt.some((row) => row.type === "end" && row.number === 1));
  } finally {
    await server.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("US-011 shutdown aborts reconciliation and closes both overlap generations", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "us-011-overlap-shutdown-"));
  const server = await startFixtureServer({
    expiryMs: 240,
    feedDelayAfter: 2,
    feedDelayMs: 1_500,
  });
  try {
    const mqttLog = path.join(dir, "mqtt.jsonl");
    const started = Date.now();
    const result = await runWatcher({
      CACHE_FILE: path.join(dir, "cache.json"),
      FAKE_MQTT_LOG: mqttLog,
      FAKE_MQTT_SCENARIO: "quiet",
      HQ_ROOT: dir,
      HQ_WORK_MESH_TOKEN: "static-test-token",
      HQ_WORK_MESH_API_URL: server.apiUrl,
      HQ_WORK_MESH_MQTT_MODULE: writeFakeMqttModule(dir),
      HQ_WORK_MESH_RENEWAL_SKEW_MS: "120",
    }, 260);
    const elapsedMs = Date.now() - started;
    assert.equal(result.timedOut, true);
    assert.ok(elapsedMs < 1_000, `shutdown took ${elapsedMs}ms`);
    const mqtt = fs.readFileSync(mqttLog, "utf8").trim().split("\n").map(JSON.parse);
    const ended = new Set(mqtt.filter((row) => row.type === "end").map((row) => row.number));
    assert.ok(ended.has(1) && ended.has(2), "both sides of make-before-break overlap must close");
  } finally {
    await server.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
