/**
 * Unit + contract tests for the US-014 advisory CI integration.
 *
 * These exercise the helper (`core/scripts/doctor-ci-summary.mjs`) against
 * fixture `hq doctor --json` documents, plus a structural contract over the
 * workflow file. Together they cover all four US-014 e2eTests without a live
 * PR — the mapping is asserted explicitly below:
 *
 *   e2e1  PR adds a hook with no fixture  → newly UNTESTED   → "diff: surfaces a newly-UNTESTED hook"
 *   e2e2  PR introduces a drifted mirror  → new FAIL, exit 0 → "diff: surfaces a new FAIL" + "CLI: exits 0 …"
 *   e2e3  two runs → exactly one comment  → update-in-place  → "selectExistingComment …"
 *   e2e4  docs-only PR → job skipped      → paths filter     → "workflow: paths filter gates …"
 */

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  ADVISORY_MARKER,
  buildAdvisorySummary,
  diffDoctorResults,
  parseDoctorJson,
  resultKey,
  selectExistingComment,
} from "../doctor-ci-summary.mjs";

const HELPER = fileURLToPath(new URL("../doctor-ci-summary.mjs", import.meta.url));
const WORKFLOW = fileURLToPath(
  new URL("../../../.github/workflows/doctor-advisory.yml", import.meta.url),
);

function fixturePath(name) {
  return fileURLToPath(new URL(`./fixtures/doctor/${name}`, import.meta.url));
}
function fixtureText(name) {
  return fs.readFileSync(fixturePath(name), "utf8");
}
function fixtureDoc(name) {
  return JSON.parse(fixtureText(name));
}

// ── parsing ───────────────────────────────────────────────────────────────

test("parseDoctorJson: accepts a valid document", () => {
  const { document, error } = parseDoctorJson(fixtureText("base.json"));
  assert.equal(error, null);
  assert.equal(document.schemaVersion, 2);
  assert.ok(Array.isArray(document.results));
});

test("parseDoctorJson: rejects empty and malformed input without throwing", () => {
  assert.equal(parseDoctorJson("").document, null);
  assert.equal(parseDoctorJson(null).document, null);
  assert.equal(parseDoctorJson("{not json").document, null);
  assert.equal(parseDoctorJson('{"no":"results"}').document, null);
});

test("resultKey: distinguishes by checkId and target", () => {
  const a = { checkId: "hooks.fixtures.untested", target: "reindex" };
  const b = { checkId: "hooks.fixtures.untested", target: "session-title" };
  assert.notEqual(resultKey(a), resultKey(b));
  assert.equal(resultKey(a), resultKey({ ...a }));
});

// ── diff (e2e1 + e2e2) ──────────────────────────────────────────────────────

test("diff: surfaces a newly-UNTESTED hook a PR adds without a fixture (e2e1)", () => {
  const base = fixtureDoc("base.json");
  const head = fixtureDoc("head-adds-untested.json");
  const { newFails, newlyUntested } = diffDoctorResults(base, head);

  assert.equal(newFails.length, 0, "no new FAIL introduced");
  assert.equal(newlyUntested.length, 1, "exactly one newly-UNTESTED hook");
  assert.equal(newlyUntested[0].target, "block-new-thing");
  // Standing UNTESTED hooks from base are NOT re-listed as introduced.
  const targets = newlyUntested.map((r) => r.target);
  assert.ok(!targets.includes("reindex") && !targets.includes("session-title"));
});

test("diff: surfaces a new FAIL from a drifted Codex mirror (e2e2)", () => {
  const base = fixtureDoc("base.json");
  const head = fixtureDoc("head-adds-fail.json");
  const { newFails, newlyUntested } = diffDoctorResults(base, head);

  assert.equal(newlyUntested.length, 0);
  assert.equal(newFails.length, 1, "exactly one new FAIL");
  assert.equal(newFails[0].target, "detect-secrets.sh");
  // The pre-existing (standing) FAIL is not counted as introduced.
  assert.ok(!newFails.some((r) => r.target === "block-core-writes.sh"));
});

test("diff: no changes when head equals base", () => {
  const base = fixtureDoc("base.json");
  const { newFails, newlyUntested } = diffDoctorResults(base, fixtureDoc("base.json"));
  assert.equal(newFails.length, 0);
  assert.equal(newlyUntested.length, 0);
});

test("diff: tolerates a null base (base run unavailable)", () => {
  const head = fixtureDoc("head-adds-fail.json");
  const { newFails } = diffDoctorResults(null, head);
  // With no base, every FAIL reads as new — the summary guards this separately.
  assert.equal(newFails.length, 2);
});

// ── summary rendering ───────────────────────────────────────────────────────

test("summary: lists introduced changes FIRST and carries the marker + advisory", () => {
  const body = buildAdvisorySummary({
    baseText: fixtureText("base.json"),
    headText: fixtureText("head-adds-fail.json"),
  });

  assert.ok(body.startsWith(ADVISORY_MARKER), "marker leads the body");
  assert.match(body, /Advisory only/i, "advisory intent stated");
  assert.match(body, /never fails the build/i);

  const introducedIdx = body.indexOf("Changes introduced by this PR");
  const standingIdx = body.indexOf("Standing status");
  const newFailIdx = body.indexOf("New FAIL");
  assert.ok(introducedIdx !== -1 && standingIdx !== -1);
  assert.ok(introducedIdx < standingIdx, "introduced section precedes standing");
  assert.ok(
    newFailIdx !== -1 && newFailIdx < standingIdx,
    "new FAIL listed before the standing backlog",
  );
  assert.match(body, /detect-secrets\.sh/, "names the drifted mirror");
});

test("summary: newly-UNTESTED hook is named in the introduced section (e2e1)", () => {
  const body = buildAdvisorySummary({
    baseText: fixtureText("base.json"),
    headText: fixtureText("head-adds-untested.json"),
  });
  assert.match(body, /Newly UNTESTED \(1\)/);
  assert.match(body, /block-new-thing/);
});

test("summary: clean PR reports no introduced changes but still shows standing status", () => {
  const body = buildAdvisorySummary({
    baseText: fixtureText("base.json"),
    headText: fixtureText("base.json"),
  });
  assert.match(body, /No new FAIL results or newly-UNTESTED hooks/i);
  assert.match(body, /Standing status/);
});

test("summary: unparseable head renders a note, never throws", () => {
  const body = buildAdvisorySummary({ baseText: fixtureText("base.json"), headText: "" });
  assert.ok(body.startsWith(ADVISORY_MARKER));
  assert.match(body, /did not produce a usable document/i);
});

test("summary: unavailable base degrades to standing-only with a note", () => {
  const body = buildAdvisorySummary({ baseText: "", headText: fixtureText("base.json") });
  assert.match(body, /Base-branch comparison unavailable/i);
  assert.match(body, /Standing status/);
});

// ── comment selection (e2e3) ────────────────────────────────────────────────

test("selectExistingComment: finds a prior advisory comment to update (e2e3)", () => {
  const comments = [
    { id: 1, body: "unrelated review comment" },
    { id: 2, body: `${ADVISORY_MARKER}\n## hq doctor — advisory hook health\n…` },
    { id: 3, body: "another comment" },
  ];
  const found = selectExistingComment(comments);
  assert.ok(found);
  assert.equal(found.id, 2, "updates the existing marker comment (one comment survives)");
});

test("selectExistingComment: returns null when no advisory comment exists yet", () => {
  assert.equal(selectExistingComment([{ id: 1, body: "hi" }]), null);
  assert.equal(selectExistingComment([]), null);
  assert.equal(selectExistingComment(undefined), null);
});

// ── CLI (advisory exit-0 contract, e2e2) ─────────────────────────────────────

test("CLI: writes a summary and exits 0 even when the doctor verdict is FAIL (e2e2)", () => {
  const stdout = execFileSync(
    process.execPath,
    [HELPER, "--base", fixturePath("base.json"), "--head", fixturePath("head-adds-fail.json")],
    { encoding: "utf8" },
  );
  assert.ok(stdout.startsWith(ADVISORY_MARKER));
  assert.match(stdout, /New FAIL/);
  assert.match(stdout, /detect-secrets\.sh/);
});

test("CLI: missing --head is a usage error (exit 2)", () => {
  assert.throws(
    () => execFileSync(process.execPath, [HELPER], { encoding: "utf8", stdio: "pipe" }),
    (err) => err.status === 2,
  );
});

// ── workflow structural contract (e2e4 + advisory wiring) ────────────────────

test("workflow: paths filter gates the job off unrelated (docs-only) PRs (e2e4)", () => {
  const yaml = fs.readFileSync(WORKFLOW, "utf8");
  assert.match(yaml, /pull_request:/, "triggers on pull_request");
  assert.match(yaml, /paths:/, "declares a paths filter");
  // The hook, settings, and fixture surfaces that must trigger the job.
  assert.match(yaml, /\.claude\/hooks\//, "hook files");
  assert.match(yaml, /\.codex\/hooks/, "codex hook files");
  assert.match(yaml, /\.grok\/hooks/, "grok hook files");
  assert.match(yaml, /core\/hooks\//, "event-directory hooks");
  assert.match(yaml, /core\/hook-tests\//, "fixture files");
  assert.match(yaml, /\.claude\/settings/, "settings files");
});

test("workflow: runs hq doctor --json and is explicitly advisory (never fails build)", () => {
  const yaml = fs.readFileSync(WORKFLOW, "utf8");
  assert.match(yaml, /hq doctor --json/, "invokes the JSON doctor");
  assert.match(yaml, /npm install -g @indigoai-us\/hq-cli/, "installs the hq CLI");
  assert.match(yaml, /doctor-ci-summary\.mjs/, "renders the summary via the helper");
  assert.match(yaml, /github-script/, "posts/updates the PR comment via github-script");
  assert.match(yaml, /selectExistingComment/, "update-in-place uses the tested selection logic");
  // Advisory intent must be explicit in a workflow comment, and the job must
  // not fail the build regardless of verdict.
  assert.match(yaml, /[Aa]dvisory/, "advisory intent stated in the workflow");
  assert.match(yaml, /exit 0/, "explicit exit 0 keeps the job green");
});
