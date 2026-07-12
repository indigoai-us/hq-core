import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { performance } from "node:perf_hooks";
import test from "node:test";

import {
  acquireCacheLock,
  applyWorkFeedToCache,
  buildProjectRollups,
  createBoundedLruSet,
  createReconcileCoordinator,
  cursorBinding,
  deterministicBackoffMs,
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
  renewalDelayMs,
  resolveApiUrl,
  saveBoundCursor,
  writeLiveCache,
} from "../work-mesh.mjs";

const PERSON = "prs_01ARZ3NDEKTSV4RRFFQ69G5FAV";
const CLIENT_ID = "rt2-12345678-1234-4123-8123-123456789abc";
const EXPIRES = "2099-07-11T12:00:00.000Z";

function credentials() {
  return {
    accessKeyId: "ASIA0000000000000000",
    secretAccessKey: "secret",
    sessionToken: "session-token",
    expiration: EXPIRES,
  };
}

function topics() {
  return {
    dm: `hq/${PERSON}/dm`,
    sessions: `hq/${PERSON}/sessions`,
    work: `hq/${PERSON}/work`,
    notifications: `hq/${PERSON}/notifications`,
  };
}

function v2(overrides = {}) {
  return {
    contractVersion: 2,
    credentials: credentials(),
    iotEndpoint: "abc123-ats.iot.us-east-1.amazonaws.com",
    region: "us-east-1",
    clientId: CLIENT_ID,
    topic: topics().dm,
    topics: topics(),
    expiresAt: EXPIRES,
    ...overrides,
  };
}

function v1(overrides = {}) {
  return {
    credentials: credentials(),
    iotEndpoint: "abc123-ats.iot.us-east-1.amazonaws.com",
    region: "us-east-1",
    topic: topics().dm,
    topics: topics(),
    expiresAt: EXPIRES,
    companyTopics: [{
      companyUid: "cmp_legacy",
      threadTopicFilter: "hq/cmp_legacy/thread/#",
      presenceTopic: "hq/cmp_legacy/presence",
    }],
    ...overrides,
  };
}

function feed(overrides = {}) {
  return {
    contractVersion: 2,
    snapshot: true,
    reset: false,
    cursor: "a".repeat(43),
    cursorExpiresAt: EXPIRES,
    removedCompanyUids: [],
    open: [],
    changed: [],
    ...overrides,
  };
}

test("v2 credentials are exact and use only the fixed personal work subscription", () => {
  const parsed = parseRealtimeV2Config(v2());
  assert.equal(parsed.clientId, CLIENT_ID);
  assert.equal(parsed.principalUid, PERSON);
  assert.deepEqual(mqttTopicsForConfig(parsed), [`hq/${PERSON}/work`]);
  assert.equal(Object.hasOwn(redactedRealtimeConfig(parsed), "clientId"), false);
  assert.equal(JSON.stringify(redactedRealtimeConfig(parsed)).includes("secret"), false);
  assert.throws(() => parseRealtimeV2Config(v2({ companyTopics: [] })), /invalid/);
  assert.throws(() => parseRealtimeV2Config(v2({ clientId: "client-chosen" })), /client id/);
  assert.throws(() => parseRealtimeV2Config(v2({ topics: { ...topics(), work: "hq/other/work" } })), /inconsistent/);
  assert.throws(
    () => parseRealtimeV2Config(v2({ iotEndpoint: "abc123-ats.iot.eu-west-1.amazonaws.com" })),
    /endpoint/,
  );
  assert.throws(
    () => parseRealtimeV2Config(v2({ credentials: { ...credentials(), sessionToken: "bad\ntoken" } })),
    /credentials/,
  );
});

test("legacy v1 response remains compatible and validates retained company fixtures", () => {
  const legacy = parseRealtimeV1Config(v1());
  assert.equal(legacy.contractVersion, 1);
  assert.deepEqual(mqttTopicsForConfig(legacy), ["hq/cmp_legacy/thread/#", `hq/${PERSON}/work`]);
});

test("credential negotiation rejects silent downgrade and uses v1 only after explicit 409", async () => {
  const previousFetch = globalThis.fetch;
  const requestBodies = [];
  try {
    globalThis.fetch = async (_url, init) => {
      requestBodies.push(JSON.parse(init.body));
      return new Response(JSON.stringify(v1()), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    };
    await assert.rejects(
      fetchRealtimeConfig("https://api.example.test", "token"),
      /v2 credential response is invalid/,
    );
    assert.deepEqual(requestBodies, [{ contractVersion: 2 }]);

    requestBodies.length = 0;
    globalThis.fetch = async (_url, init) => {
      requestBodies.push(JSON.parse(init.body));
      return new Response(JSON.stringify({ code: "UNRELATED_CONFLICT" }), {
        status: 409,
        headers: { "Content-Type": "application/json" },
      });
    };
    await assert.rejects(
      fetchRealtimeConfig("https://api.example.test", "token"),
      (err) => err?.status === 409 && err?.code === "UNRELATED_CONFLICT",
    );
    assert.deepEqual(requestBodies, [{ contractVersion: 2 }]);

    requestBodies.length = 0;
    globalThis.fetch = async (_url, init) => {
      requestBodies.push(JSON.parse(init.body));
      return new Response(JSON.stringify({
        code: "REALTIME_CONTRACT_UNSUPPORTED",
        supportedContractVersions: [1, 2],
      }), { status: 409, headers: { "Content-Type": "application/json" } });
    };
    await assert.rejects(
      fetchRealtimeConfig("https://api.example.test", "token"),
      (err) => err?.status === 409 && err?.code === "REALTIME_CONTRACT_UNSUPPORTED",
    );
    assert.deepEqual(requestBodies, [{ contractVersion: 2 }]);

    requestBodies.length = 0;
    let requestCount = 0;
    globalThis.fetch = async (_url, init) => {
      requestBodies.push(JSON.parse(init.body));
      requestCount += 1;
      return requestCount === 1
        ? new Response(JSON.stringify({
            code: "REALTIME_CONTRACT_UNSUPPORTED",
            supportedContractVersions: [1],
          }), { status: 409, headers: { "Content-Type": "application/json" } })
        : new Response(JSON.stringify(v1()), {
            status: 200,
            headers: { "Content-Type": "application/json" },
          });
    };
    const legacy = await fetchRealtimeConfig("https://api.example.test", "token");
    assert.equal(legacy.contractVersion, 1);
    assert.deepEqual(requestBodies, [{ contractVersion: 2 }, {}]);
  } finally {
    globalThis.fetch = previousFetch;
  }
});

test("v2 wake parser accepts only the ids-only exact envelope", () => {
  const wake = {
    contractVersion: 2,
    eventId: "evt_1",
    eventType: "work.changed",
    scope: "work",
    resourceId: "thr_1",
    recipientUid: PERSON,
    createdAt: "2026-07-11T12:00:00.000Z",
  };
  assert.deepEqual(parseRealtimeV2Wake(JSON.stringify(wake)), wake);
  assert.equal(parseRealtimeV2Wake(JSON.stringify({ ...wake, details: "must-not-cross" })), null);
  assert.equal(parseRealtimeV2Wake(`{"contractVersion":2,"contractVersion":2,"eventId":"evt_1"}`), null);
  assert.equal(parseRealtimeV2Wake(Buffer.alloc(1025, "x")), null);
});

test("feed validation and application rebuild authoritative state and purge revocations", () => {
  const parsed = parseWorkFeed(feed({
    snapshot: false,
    removedCompanyUids: ["cmp_removed"],
    open: [{
      threadId: "thr_live",
      companyUid: "cmp_live",
      threadStatus: "blocked",
      projectId: "mesh",
      lastActivityAt: "2026-07-11T12:00:00.000Z",
    }],
    changed: [{
      threadId: "thr_done",
      companyUid: "cmp_removed",
      threadStatus: "done",
      lastActivityAt: "2026-07-11T12:00:00.000Z",
    }],
  }));
  const next = applyWorkFeedToCache({
    schemaVersion: 1,
    threadsById: {
      thr_stale: { threadId: "thr_stale", companyUid: "cmp_removed", threadStatus: "open" },
    },
    projects: {},
    events: [],
  }, parsed, parseRealtimeV2Config(v2()), undefined, "wake");
  assert.deepEqual(Object.keys(next.threadsById), ["thr_live"]);
  assert.equal(next.threadsById.thr_live.cacheSource, "rest-reconcile-v2");
  assert.deepEqual(Object.keys(next.events[0]).sort(), [
    "changedCount", "createdAt", "openCount", "reason", "removedCompanyCount", "reset", "snapshot", "type",
  ]);
  assert.throws(() => parseWorkFeed(feed({ reset: true, snapshot: false })), /invalid/);
  assert.throws(() => parseWorkFeed({ ...feed(), extra: true }), /invalid/);
  assert.throws(() => parseWorkFeed(feed({ removedCompanyUids: ["other_tenant"] })), /removed companies/);
  assert.throws(() => parseWorkFeed(feed({
    changed: [
      { threadId: "thr_same", companyUid: "cmp_live", threadStatus: "done" },
      { threadId: "thr_same", companyUid: "cmp_live", threadStatus: "done" },
    ],
  })), /duplicate changed/);
});

test("cursor sidecar is API, account, and topic bound and persisted mode 0600", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "work-mesh-cursor-"));
  const opts = { cache_file: path.join(dir, "cache.json") };
  const config = parseRealtimeV2Config(v2());
  saveBoundCursor("https://api.example.test", config, opts, "z".repeat(43), EXPIRES);
  const file = `${opts.cache_file}.cursor-v2.json`;
  assert.equal(fs.statSync(file).mode & 0o777, 0o600);
  assert.equal(loadBoundCursor("https://api.example.test", config, opts), "z".repeat(43));
  assert.equal(loadBoundCursor("https://other.example.test", config, opts), undefined);
  assert.notEqual(
    cursorBinding("https://api.example.test", config),
    cursorBinding("https://other.example.test", config),
  );
  const copied = path.join(dir, "copied-cursor.json");
  fs.renameSync(file, copied);
  fs.symlinkSync(copied, file);
  assert.equal(loadBoundCursor("https://api.example.test", config, opts), undefined);
  fs.rmSync(dir, { recursive: true, force: true });
});

test("a failed cache write never advances the durable cursor", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "work-mesh-cache-before-cursor-"));
  const opts = { cache_file: path.join(dir, "cache.json") };
  fs.mkdirSync(opts.cache_file);
  const previousFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response(JSON.stringify(feed({ cursor: "b".repeat(43) })), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
  try {
    await assert.rejects(
      reconcileV2({
        apiUrl: "https://api.example.test",
        refreshToken: async () => "test-token",
      }, parseRealtimeV2Config(v2()), opts, undefined, undefined, "test", undefined),
      /regular file/,
    );
    assert.equal(fs.existsSync(`${opts.cache_file}.cursor-v2.json`), false);
  } finally {
    globalThis.fetch = previousFetch;
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("cache writes reject symlink destinations and watcher locks exclude shared writers", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "work-mesh-cache-security-"));
  const target = path.join(dir, "target.json");
  const cache = path.join(dir, "cache.json");
  fs.writeFileSync(target, '{"protected":true}\n', { mode: 0o600 });
  fs.symlinkSync(target, cache);
  assert.throws(() => writeLiveCache({ cache_file: cache }, {
    schemaVersion: 1,
    threadsById: {},
    projects: {},
    events: [],
  }), /regular file/);
  assert.equal(fs.readFileSync(target, "utf8"), '{"protected":true}\n');
  fs.unlinkSync(cache);

  const opts = { cache_file: cache };
  const release = acquireCacheLock(opts);
  assert.throws(() => acquireCacheLock(opts), /another Work Mesh watcher/);
  assert.equal(fs.statSync(`${cache}.watch.lock`).mode & 0o777, 0o700);
  const owners = fs.readdirSync(`${cache}.watch.lock`);
  assert.equal(owners.length, 1);
  assert.equal(fs.statSync(path.join(`${cache}.watch.lock`, owners[0])).mode & 0o777, 0o600);
  release();
  assert.equal(fs.existsSync(`${cache}.watch.lock`), false);

  fs.mkdirSync(`${cache}.watch.lock`, { mode: 0o700 });
  fs.writeFileSync(path.join(`${cache}.watch.lock`, "0000000000000-2147483647-stale.json"), JSON.stringify({
    version: 1,
    pid: 2_147_483_647,
    nonce: "0".repeat(32),
  }), { mode: 0o600 });
  const releaseAfterCrash = acquireCacheLock(opts);
  assert.equal(fs.readdirSync(`${cache}.watch.lock`).length, 1);
  releaseAfterCrash();
  fs.rmSync(dir, { recursive: true, force: true });
});

test("API URL and diagnostics do not permit bearer or signed URL leakage", () => {
  const previous = process.env.HQ_WORK_MESH_API_URL;
  try {
    process.env.HQ_WORK_MESH_API_URL = "http://127.0.0.1:1234";
    assert.equal(resolveApiUrl(), "http://127.0.0.1:1234");
    process.env.HQ_WORK_MESH_API_URL = "http://api.example.test";
    assert.throws(() => resolveApiUrl(), /HTTPS/);
    process.env.HQ_WORK_MESH_API_URL = "https://user:pass@api.example.test";
    assert.throws(() => resolveApiUrl(), /HTTPS/);
  } finally {
    if (previous === undefined) delete process.env.HQ_WORK_MESH_API_URL;
    else process.env.HQ_WORK_MESH_API_URL = previous;
  }
  const diagnostic = redactedDiagnostic(
    "failed Bearer private-bearer at wss://abc.iot.test/mqtt?X-Amz-Security-Token=private-session",
    ["private-bearer"],
  );
  assert.equal(diagnostic.includes("private-bearer"), false);
  assert.equal(diagnostic.includes("private-session"), false);
  assert.match(diagnostic, /redacted/);
});

test("reconciliation coalesces bursts and performs one mandatory trailing pass", async () => {
  let calls = 0;
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const coordinator = createReconcileCoordinator(async () => {
    calls += 1;
    if (calls === 1) await gate;
    return { feed: { cursor: String(calls) } };
  }, { debounceMs: 1 });
  const initial = coordinator.run("initial");
  await new Promise((resolve) => setImmediate(resolve));
  const wakeA = coordinator.request("wake");
  const wakeB = coordinator.request("wake");
  release();
  await Promise.all([initial, wakeA, wakeB]);
  assert.equal(calls, 2);
  assert.equal(coordinator.getCursor(), "2");
  coordinator.stop();
});

test("stopping reconciliation rejects a pending debounced caller", async () => {
  const coordinator = createReconcileCoordinator(async () => ({ feed: { cursor: "unused" } }), { debounceMs: 10_000 });
  const pending = coordinator.request("wake");
  coordinator.stop();
  await assert.rejects(pending, /stopped/);
});

test("retry backoff is deterministic and bounded", () => {
  assert.equal(deterministicBackoffMs(3, 100, 1000, 11), deterministicBackoffMs(3, 100, 1000, 11));
  assert.ok(deterministicBackoffMs(30, 100, 1000, 11) <= 1000);
  assert.ok(deterministicBackoffMs(1, 100, 1000, 11) >= 80);
});

test("renewal scheduling uses a deterministic fake clock and stays before expiry", () => {
  const now = Date.parse("2026-07-11T12:00:00.000Z");
  const expiresAt = "2026-07-11T12:15:00.000Z";
  const first = renewalDelayMs(expiresAt, now, 60_000, 11, 7);
  assert.equal(first, renewalDelayMs(expiresAt, now, 60_000, 11, 7));
  assert.ok(first >= 825_000 && first < 840_000);
  assert.equal(renewalDelayMs("2026-07-11T11:59:00.000Z", now, 60_000, 11, 7), 1);
});

test("wake event ids use a bounded true LRU", () => {
  const ids = createBoundedLruSet(3);
  assert.equal(ids.remember("a"), true);
  assert.equal(ids.remember("b"), true);
  assert.equal(ids.remember("c"), true);
  assert.equal(ids.remember("a"), false, "duplicate access refreshes recency");
  assert.equal(ids.remember("d"), true);
  assert.equal(ids.has("a"), true);
  assert.equal(ids.has("b"), false);
  assert.equal(ids.size, 3);
});

test("high-cardinality feed parse, authoritative apply, rollup, and atomic write stay bounded", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "work-mesh-benchmark-"));
  const opts = { cache_file: path.join(dir, "cache.json") };
  const open = Array.from({ length: 5_000 }, (_, index) => ({
    threadId: `thr_${index}`,
    companyUid: `cmp_${index % 500}`,
    threadStatus: index % 7 === 0 ? "blocked" : "open",
    projectId: `project_${index % 100}`,
    ownerUid: `owner_${index}`,
    lastActivityAt: "2026-07-11T12:00:00.000Z",
  }));
  const changed = open.map((thread) => ({ ...thread, threadStatus: "done" }));
  const started = performance.now();
  const parsed = parseWorkFeed(feed({ snapshot: false, open, changed }));
  const parsedAt = performance.now();
  const cache = applyWorkFeedToCache({
    schemaVersion: 1,
    threadsById: {},
    projects: {},
    events: [],
  }, parsed, parseRealtimeV2Config(v2()), undefined, "benchmark");
  const written = writeLiveCache(opts, cache);
  const finished = performance.now();

  assert.equal(Object.keys(written.threadsById).length, 5_000);
  assert.equal(Object.keys(written.projects).length, 500);
  assert.equal(written.projects["cmp_0/project_0"].owners.length, 10);
  assert.equal(fs.statSync(opts.cache_file).mode & 0o777, 0o600);
  assert.ok(finished - started < 5_000, "bounded 10,000-row fixture must not regress catastrophically");
  assert.deepEqual(fs.readdirSync(dir), ["cache.json"]);
  console.log(JSON.stringify({
    benchmark: "work-mesh-high-cardinality",
    companies: 500,
    open: open.length,
    changed: changed.length,
    bytes: Buffer.byteLength(JSON.stringify(feed({ snapshot: false, open, changed }))),
    parseMs: Number((parsedAt - started).toFixed(2)),
    applyRollupWriteMs: Number((finished - parsedAt).toFixed(2)),
  }));
  fs.rmSync(dir, { recursive: true, force: true });
});

test("reconciliation collapses a 10,000-wake in-flight burst to one trailing pass", async () => {
  let calls = 0;
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const coordinator = createReconcileCoordinator(async () => {
    calls += 1;
    if (calls === 1) await gate;
    return { feed: { cursor: `cursor-${calls}` } };
  }, { debounceMs: 0 });
  const initial = coordinator.run("initial");
  await new Promise((resolve) => setImmediate(resolve));
  const wakes = Array.from({ length: 10_000 }, () => coordinator.request("wake"));
  release();
  await Promise.all([initial, ...wakes]);
  assert.equal(calls, 2);
  coordinator.stop();
});

test("feed cardinality overflow fails closed instead of truncating", () => {
  const open = Array.from({ length: 20_001 }, (_, index) => ({
    threadId: `thr_${index}`,
    companyUid: "cmp_bound",
    threadStatus: "open",
  }));
  assert.throws(() => parseWorkFeed(feed({ open })), /invalid/);
});

test("response streaming enforces the feed byte bound before JSON parsing", async () => {
  await assert.rejects(
    readBoundedResponseText(new Response("123456", { headers: { "Content-Length": "6" } }), 5),
    /byte bound/,
  );
  assert.equal(await readBoundedResponseText(new Response("12345"), 5), "12345");
});

test("project rollups remain linear with 10,000 distinct owners on one project", () => {
  const threads = Object.fromEntries(Array.from({ length: 10_000 }, (_, index) => [
    `thr_${index}`,
    {
      threadId: `thr_${index}`,
      companyUid: "cmp_large",
      projectId: "project_large",
      threadStatus: "open",
      ownerUid: `owner_${index}`,
      lastActivityAt: "2026-07-11T12:00:00.000Z",
    },
  ]));
  const started = performance.now();
  const projects = buildProjectRollups(threads);
  const elapsedMs = performance.now() - started;
  assert.equal(projects["cmp_large/project_large"].owners.length, 10_000);
  assert.ok(elapsedMs < 2_000, "owner deduplication must not regress to quadratic work");
  console.log(JSON.stringify({
    benchmark: "work-mesh-project-rollup",
    threads: 10_000,
    distinctOwners: 10_000,
    elapsedMs: Number(elapsedMs.toFixed(2)),
  }));
});
