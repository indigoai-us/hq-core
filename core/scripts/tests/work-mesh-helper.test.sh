#!/usr/bin/env bash
# Smoke tests for the work-mesh helper's fail-soft and API-call behavior.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HELPER="$ROOT/core/scripts/work-mesh.sh"
TMP="$(mktemp -d)"

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}

trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$label: missing '$needle' in $haystack"
}

disabled_out="$(HQ_WORK_MESH_DISABLED=1 "$HELPER" check --company indigo --project demo --json)"
assert_contains "$disabled_out" '"skipped":true' "disabled helper reports skipped"

cat > "$TMP/server.mjs" <<'JS'
import fs from "node:fs";
import http from "node:http";

const logPath = process.argv[2];
const portPath = process.argv[3];
const threads = [];
let eventCount = 0;
const projectViews = {};

function projectIdFromUrl(url) {
  const match = String(url || "").match(/\/v1\/work-mesh\/projects\/([^/?]+)/);
  return match ? decodeURIComponent(match[1]) : "";
}

function send(res, status, body) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
}

const server = http.createServer((req, res) => {
  let raw = "";
  req.on("data", (chunk) => {
    raw += chunk;
  });
  req.on("end", () => {
    const entry = {
      method: req.method,
      url: req.url,
      authorization: req.headers.authorization,
      body: raw ? JSON.parse(raw) : null,
    };
    fs.appendFileSync(logPath, `${JSON.stringify(entry)}\n`);

    if (req.method === "GET" && req.url === "/membership/me") {
      send(res, 200, {
        memberships: [{ companyUid: "cmp_indigo", companySlug: "indigo", companyName: "Indigo" }],
      });
      return;
    }

    if (req.method === "GET" && req.url.startsWith("/v1/work-mesh/threads?")) {
      send(res, 200, { threads });
      return;
    }

    if (req.method === "POST" && req.url === "/v1/realtime/credentials") {
      const request = raw ? JSON.parse(raw) : {};
      if (request.contractVersion === 2) {
        send(res, 409, {
          code: "REALTIME_CONTRACT_UNSUPPORTED",
          supportedContractVersions: [1],
        });
        return;
      }
      const expiresAt = new Date(Date.now() + 60_000).toISOString();
      send(res, 200, {
        credentials: {
          accessKeyId: "ASIA0000000000000000",
          secretAccessKey: "secret",
          sessionToken: "token",
          expiration: expiresAt,
        },
        iotEndpoint: "abc123-ats.iot.us-east-1.amazonaws.com",
        region: "us-east-1",
        topic: "hq/prs_01ARZ3NDEKTSV4RRFFQ69G5FAV/dm",
        topics: {
          dm: "hq/prs_01ARZ3NDEKTSV4RRFFQ69G5FAV/dm",
          sessions: "hq/prs_01ARZ3NDEKTSV4RRFFQ69G5FAV/sessions",
          work: "hq/prs_01ARZ3NDEKTSV4RRFFQ69G5FAV/work",
          notifications: "hq/prs_01ARZ3NDEKTSV4RRFFQ69G5FAV/notifications",
        },
        companyTopics: [{
          companyUid: "cmp_indigo",
          threadTopicFilter: "hq/cmp_indigo/thread/#",
          presenceTopic: "hq/cmp_indigo/presence",
        }],
        expiresAt,
      });
      return;
    }

    if (req.method === "POST" && req.url === "/v1/work-mesh/threads") {
      const body = JSON.parse(raw || "{}");
      const thread = {
        threadId: `thr_${threads.length + 1}`,
        threadStatus: "claimed",
        companyUid: body.companyUid,
        projectId: body.projectId,
        routing: body.routing,
        participantRefs: [],
        createdAt: "2026-07-05T00:00:00.000Z",
        lastActivityAt: "2026-07-05T00:00:00.000Z",
      };
      threads.push(thread);
      send(res, 200, { threadId: thread.threadId, createdAt: thread.createdAt });
      return;
    }

    if (req.method === "POST" && /\/v1\/work-mesh\/threads\/[^/]+\/events/.test(req.url)) {
      eventCount += 1;
      send(res, 200, { eventId: `evt_${eventCount}`, createdAt: "2026-07-05T00:00:01.000Z" });
      return;
    }

    if (req.method === "GET" && req.url.startsWith("/v1/work-mesh/projects/")) {
      const projectId = projectIdFromUrl(req.url);
      const projectView = projectViews[projectId];
      if (!projectView) {
        send(res, 404, { error: "not found" });
        return;
      }
      send(res, 200, projectView);
      return;
    }

    if (req.method === "PUT" && req.url.startsWith("/v1/work-mesh/projects/")) {
      const body = JSON.parse(raw || "{}");
      const projectId = projectIdFromUrl(req.url);
      projectViews[projectId] = {
        companyUid: body.companyUid,
        projectId,
        version: 1,
        stories: Array.isArray(body.stories) ? body.stories : [],
        repos: Array.isArray(body.repos) ? body.repos : [],
      };
      send(res, 200, projectViews[projectId]);
      return;
    }

    if (req.method === "POST" && /\/v1\/work-mesh\/projects\/[^/?]+\/stories(?:\?|$)/.test(req.url)) {
      const body = JSON.parse(raw || "{}");
      const projectId = projectIdFromUrl(req.url);
      const projectView = projectViews[projectId] || {
        companyUid: body.companyUid,
        projectId,
        version: 0,
        stories: [],
        repos: [],
      };
      const stories = [...(projectView.stories || [])];
      if (stories.some((row) => row.id === body.id)) {
        send(res, 400, { error: "duplicate id" });
        return;
      }
      stories.push({
        id: body.id,
        title: body.title,
        description: body.description || "",
        status: "queued",
      });
      projectViews[projectId] = { ...projectView, version: (projectView.version || 0) + 1, stories };
      send(res, 200, projectViews[projectId]);
      return;
    }

    if (req.method === "PATCH" && req.url.includes("/v1/work-mesh/projects/") && req.url.includes("/stories/")) {
      const projectId = projectIdFromUrl(req.url);
      const projectView = projectViews[projectId];
      if (!projectView) {
        send(res, 404, { error: "not found" });
        return;
      }
      const body = JSON.parse(raw || "{}");
      const storyId = req.url.split("/stories/")[1]?.split("?")[0] || "US-000";
      const stories = (projectView.stories || []).map((row) => (
        row.id === storyId ? { ...row, status: body.status, passes: body.status === "done" } : row
      ));
      if (!stories.some((row) => row.id === storyId)) {
        stories.push({ id: storyId, status: body.status, passes: body.status === "done" });
      }
      projectViews[projectId] = { ...projectView, version: (projectView.version || 1) + 1, stories };
      send(res, 200, projectViews[projectId]);
      return;
    }

    send(res, 404, { error: "not found" });
  });
});

server.listen(0, "127.0.0.1", () => {
  fs.writeFileSync(portPath, String(server.address().port));
});
JS

node "$TMP/server.mjs" "$TMP/requests.jsonl" "$TMP/port" &
SERVER_PID=$!

for _ in {1..50}; do
  [[ -f "$TMP/port" ]] && break
  sleep 0.1
done
[[ -f "$TMP/port" ]] || fail "fake API server did not start"

API_URL="http://127.0.0.1:$(cat "$TMP/port")"
mkdir -p "$TMP/companies/indigo/projects/mesh-adoption"
cat > "$TMP/companies/indigo/projects/mesh-adoption/prd.json" <<'PRD'
{"name":"mesh-adoption","description":"Seed Board from start","userStories":[{"id":"US-000","title":"First","passes":false}]}
PRD
start_out="$(HOME="$TMP" HQ_ROOT="$TMP" HQ_WORK_MESH_TOKEN=test-token HQ_WORK_MESH_API_URL="$API_URL" "$HELPER" start --company indigo --project mesh-adoption --summary "Starting adoption" --json)"
assert_contains "$start_out" '"threadId": "thr_1"' "start reports thread id"
assert_contains "$start_out" '"eventKind": "claim"' "start appends claim"
assert_contains "$start_out" '"viewCreated": true' "start seeds missing Board view from prd.json"

progress_out="$(HOME="$TMP" HQ_ROOT="$TMP" HQ_WORK_MESH_TOKEN=test-token HQ_WORK_MESH_API_URL="$API_URL" "$HELPER" progress --company indigo --project mesh-adoption --summary "Working" --json)"
assert_contains "$progress_out" '"eventKind": "progress"' "progress appends event"

reuse_out="$(HOME="$TMP" HQ_ROOT="$TMP" HQ_WORK_MESH_TOKEN=test-token HQ_WORK_MESH_API_URL="$API_URL" "$HELPER" start --company indigo --project mesh-adoption --summary "Again" --json)"
assert_contains "$reuse_out" '"threadId": "thr_1"' "second start reuses thread"
assert_contains "$reuse_out" '"created": false' "second start does not create"
assert_contains "$reuse_out" '"viewCreated": false' "second start does not overwrite existing Board view"

check_out="$(HOME="$TMP" HQ_ROOT="$TMP" HQ_WORK_MESH_TOKEN=test-token HQ_WORK_MESH_API_URL="$API_URL" "$HELPER" check --company indigo --project mesh-adoption --json)"
assert_contains "$check_out" '"threadId": "thr_1"' "check finds the active project thread"
assert_contains "$check_out" '"stories"' "check JSON includes Board stories[]"
assert_contains "$check_out" '"id": "US-000"' "check Board includes the seeded story"

ground_out="$(HOME="$TMP" HQ_ROOT="$TMP" HQ_WORK_MESH_TOKEN=test-token HQ_WORK_MESH_API_URL="$API_URL" "$HELPER" ground --company indigo --project mesh-adoption --json)"
assert_contains "$ground_out" '"bound": true' "ground binds the named project"
assert_contains "$ground_out" '"id": "US-000"' "ground --json returns Board stories[]"

story_out="$(HOME="$TMP" HQ_ROOT="$TMP" HQ_WORK_MESH_TOKEN=test-token HQ_WORK_MESH_API_URL="$API_URL" "$HELPER" story --company indigo --project mesh-adoption --story US-000 --status review --json)"
assert_contains "$story_out" '"status": "review"' "story reports review"
[[ -f "$TMP/.hq/work-mesh/cache/projects/cmp_indigo/mesh-adoption.json" ]] || fail "story writes machine cache"

mkdir -p "$TMP/companies/indigo/projects/mesh-one-call"
cat > "$TMP/companies/indigo/projects/mesh-one-call/prd.json" <<'PRD'
{"name":"mesh-one-call","description":"One report call","userStories":[{"id":"US-001","title":"Only","passes":false}]}
PRD
report_out="$(HOME="$TMP" HQ_ROOT="$TMP" HQ_WORK_MESH_TOKEN=test-token HQ_WORK_MESH_API_URL="$API_URL" "$HELPER" report --company indigo --project mesh-one-call --task US-001 --status doing --summary "Working US-001" --json)"
assert_contains "$report_out" '"viewCreated": true' "report seeds Board in the same call"
assert_contains "$report_out" '"status": "in_progress"' "report maps doing → in_progress on the wire"
assert_contains "$report_out" '"eventKind": "progress"' "report writes the work thread in the same call"

confirm_out="$(HOME="$TMP" HQ_ROOT="$TMP" HQ_WORK_MESH_TOKEN=test-token HQ_WORK_MESH_API_URL="$API_URL" "$HELPER" ground --company indigo --create wm-auto-nope --json)"
assert_contains "$confirm_out" 'create requires --confirm' "ground --create without --confirm does not write"

create_out="$(HOME="$TMP" HQ_ROOT="$TMP" HQ_WORK_MESH_TOKEN=test-token HQ_WORK_MESH_API_URL="$API_URL" "$HELPER" report --company indigo --project mesh-adoption --task-title "Probe add task" --status doing --json)"
assert_contains "$create_out" '"created": true' "unrelated --task-title POSTs a new Board task"
assert_contains "$create_out" '"taskId": "T-001"' "new live tasks use T-NNN ids"

attach_out="$(HOME="$TMP" HQ_ROOT="$TMP" HQ_WORK_MESH_TOKEN=test-token HQ_WORK_MESH_API_URL="$API_URL" "$HELPER" report --company indigo --project mesh-adoption --task-title "Probe add task" --status doing --json)"
assert_contains "$attach_out" '"attached": true' "matching open title attaches instead of duplicating"
assert_contains "$attach_out" '"created": false' "matching open title does not POST again"

watch_out="$(HQ_ROOT="$TMP" HQ_WORK_MESH_TOKEN=test-token HQ_WORK_MESH_API_URL="$API_URL" "$HELPER" watch --dry-run --json --cache-file "$TMP/live-cache.json")"
assert_contains "$watch_out" '"action": "watch"' "watch dry-run reports action"
assert_contains "$watch_out" '"hq/prs_01ARZ3NDEKTSV4RRFFQ69G5FAV/work"' "watch uses authoritative work topic"
assert_contains "$watch_out" '"hq/cmp_indigo/thread/#"' "watch subscribes to company thread filter"

python3 - "$TMP/requests.jsonl" <<'PY' || fail "request log validation failed"
import json
import sys

rows = [json.loads(line) for line in open(sys.argv[1])]
assert any(row["url"] == "/membership/me" for row in rows)
assert any(row["method"] == "POST" and row["url"] == "/v1/work-mesh/threads" for row in rows)
assert any(row["method"] == "PUT" and row["url"].startswith("/v1/work-mesh/projects/") for row in rows)
assert any(row["method"] == "POST" and "/stories" in row["url"] and row["url"].rstrip("/").endswith("/stories") for row in rows)
assert any(row["body"] and row["body"].get("eventKind") == "claim" for row in rows)
assert any(row["body"] and row["body"].get("eventKind") == "progress" for row in rows)
assert any(row["method"] == "POST" and row["url"] == "/v1/realtime/credentials" for row in rows)
credential_rows = [row for row in rows if row["method"] == "POST" and row["url"] == "/v1/realtime/credentials"]
assert [row["body"] for row in credential_rows] == [{"contractVersion": 2}, {}]
assert all(row["authorization"] == "Bearer test-token" for row in rows)
PY

python3 - "$TMP/live-cache.json" <<'PY' || fail "live cache validation failed"
import json
import sys

cache = json.load(open(sys.argv[1]))
assert cache["realtime"]["topics"]["work"] == "hq/prs_01ARZ3NDEKTSV4RRFFQ69G5FAV/work"
assert "thr_1" in cache["threadsById"]
assert "cmp_indigo/mesh-adoption" in cache["projects"]
PY

[ ! -d "$TMP/companies/wm-auto-nope" ] || fail "helper must not mkdir a company folder"
[ ! -d "$TMP/companies/ok" ] || fail "helper must not mkdir companies/ok"

echo "work-mesh helper smoke: ok"
