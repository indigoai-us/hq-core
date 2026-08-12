/**
 * doctor-ci-summary — render the advisory PR comment for `hq doctor --json`.
 *
 * US-014 (hq-doctor): the advisory CI job runs `hq doctor --json` twice — once
 * against the PR head, once against the base branch — and this module turns the
 * two documents into a single human-readable Markdown comment.
 *
 * Two properties make the advisory job actually useful, and both live here so
 * they can be unit-tested against fixture JSON documents without a live PR:
 *
 *   1. DIFF-AGAINST-BASE. A comment that repeats the whole standing backlog on
 *      every PR gets ignored within a week. So the *changes this PR introduces*
 *      — new FAIL results and newly-UNTESTED hooks — are computed relative to
 *      the base document and listed FIRST; the standing status is secondary
 *      context below them.
 *
 *   2. ONE COMMENT, UPDATED IN PLACE. The rendered body carries a hidden marker
 *      ({@link ADVISORY_MARKER}); {@link selectExistingComment} finds a prior
 *      advisory comment by that marker so a re-run updates it instead of
 *      appending a new one. The workflow's github-script step imports this
 *      function, so the exact selection logic used in production is the tested
 *      logic.
 *
 * The module never fails the build and never throws on bad input: an
 * unparseable head document renders a note, and an unparseable base document
 * degrades to a standing-status-only summary. All executable logic is here; the
 * workflow only wires I/O and the GitHub API to it.
 */

import fs from "node:fs";
import process from "node:process";

/**
 * Hidden HTML marker embedded in every advisory comment. Present in exactly one
 * comment per PR; the workflow finds it to update in place. Changing this string
 * orphans older comments, so treat it as a stable contract.
 */
export const ADVISORY_MARKER = "<!-- hq-doctor-advisory -->";

/** The coverage meta-result's checkId (mirrors hq-cli fixtures/discover.ts). */
export const COVERAGE_CHECK_ID = "hooks.fixtures.coverage";

/** The status vocabulary, in canonical display order (mirrors hq-cli types.ts). */
export const DOCTOR_STATUSES = [
  "PASS",
  "FAIL",
  "WARN",
  "UNTESTED",
  "NA",
  "UNKNOWN",
  "KNOWN-DEFECT",
];

/** Max items rendered per introduced-changes list before it is truncated. */
const MAX_LISTED = 40;

/**
 * Parse a `hq doctor --json` document from raw text.
 * @param {string|null|undefined} text
 * @returns {{ document: object|null, error: string|null }}
 */
export function parseDoctorJson(text) {
  if (typeof text !== "string" || text.trim() === "") {
    return { document: null, error: "no output" };
  }
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch (err) {
    return { document: null, error: `invalid JSON: ${err.message}` };
  }
  if (parsed === null || typeof parsed !== "object" || !Array.isArray(parsed.results)) {
    return { document: null, error: "not a doctor document (missing results[])" };
  }
  return { document: parsed, error: null };
}

/**
 * The identity of a result for diffing: its check id and target. Two runs that
 * report the same (checkId, target) pair are talking about the same thing.
 * Uses a NUL separator so ids/targets containing other punctuation never
 * collide.
 * @param {{ checkId?: string, target?: string }} result
 * @returns {string}
 */
export function resultKey(result) {
  return `${result.checkId ?? ""}\u0000${result.target ?? ""}`;
}

/**
 * Compute the results this PR introduces relative to the base document.
 *
 * A result is a "new FAIL" when its (checkId, target) is FAIL in head but was
 * not FAIL in base. A result is "newly UNTESTED" when its (checkId, target) is
 * UNTESTED in head but was not UNTESTED in base — which is exactly what a PR
 * adding a hook file without a matching fixture produces.
 *
 * @param {object|null} baseDoc parsed base document, or null when unavailable
 * @param {object} headDoc parsed head document
 * @returns {{ newFails: object[], newlyUntested: object[] }}
 */
export function diffDoctorResults(baseDoc, headDoc) {
  const headResults = Array.isArray(headDoc?.results) ? headDoc.results : [];
  const baseResults = Array.isArray(baseDoc?.results) ? baseDoc.results : [];

  const baseFailKeys = new Set(
    baseResults.filter((r) => r.status === "FAIL").map(resultKey),
  );
  const baseUntestedKeys = new Set(
    baseResults.filter((r) => r.status === "UNTESTED").map(resultKey),
  );

  const newFails = headResults.filter(
    (r) => r.status === "FAIL" && !baseFailKeys.has(resultKey(r)),
  );
  const newlyUntested = headResults.filter(
    (r) => r.status === "UNTESTED" && !baseUntestedKeys.has(resultKey(r)),
  );

  return { newFails, newlyUntested };
}

/**
 * Choose the existing advisory comment to update, or null to create a new one.
 * Returns the FIRST comment whose body carries the marker. Because the workflow
 * always updates when this returns non-null, exactly one advisory comment
 * survives across re-runs.
 * @param {Array<{ id?: number, body?: string }>} comments
 * @param {string} [marker]
 * @returns {object|null}
 */
export function selectExistingComment(comments, marker = ADVISORY_MARKER) {
  if (!Array.isArray(comments)) return null;
  return (
    comments.find(
      (c) => typeof c?.body === "string" && c.body.includes(marker),
    ) ?? null
  );
}

/** Inline-code a value for Markdown (doctor targets are paths / hook ids). */
function code(value) {
  return "`" + String(value).replace(/`/g, "") + "`";
}

/** Render one introduced-change bullet: `checkId` · `target` — message. */
function renderBullet(result, { showCheckId }) {
  const parts = [];
  if (showCheckId && result.checkId) parts.push(code(result.checkId));
  if (result.target) parts.push(code(result.target));
  const head = parts.join(" · ");
  const message = (result.message ?? "").trim();
  return `- ${head}${head && message ? " — " : ""}${message}`;
}

/** Render a possibly-truncated list of bullets. */
function renderList(results, opts) {
  const shown = results.slice(0, MAX_LISTED).map((r) => renderBullet(r, opts));
  if (results.length > MAX_LISTED) {
    shown.push(`- …and ${results.length - MAX_LISTED} more`);
  }
  return shown.join("\n");
}

/** The standing per-status counts table for the whole tree. */
function renderStandingTable(headDoc) {
  const summary = headDoc?.summary ?? {};
  const rows = DOCTOR_STATUSES.filter((s) => (summary[s] ?? 0) > 0).map(
    (s) => `| ${s} | ${summary[s]} |`,
  );
  if (rows.length === 0) return "_No results._";
  return ["| Status | Count |", "| --- | --- |", ...rows].join("\n");
}

/** Extract the `tested/total` coverage ratio, if present. */
function coverageLine(headDoc) {
  const results = Array.isArray(headDoc?.results) ? headDoc.results : [];
  const cov = results.find((r) => r.checkId === COVERAGE_CHECK_ID);
  if (!cov) return null;
  // The coverage result's own message is already self-describing
  // ("Fixture coverage: N/M registered hooks have a fixture.").
  const message = (cov.message ?? "").trim();
  if (message) return message;
  return cov.target ? `Fixture coverage: ${cov.target}` : null;
}

/**
 * Build the full advisory comment body from raw base/head JSON text.
 * Tolerant of missing/invalid input — always returns a marker-carrying body.
 *
 * @param {object} input
 * @param {string|null} [input.baseText] raw base `hq doctor --json` output
 * @param {string|null} [input.headText] raw head `hq doctor --json` output
 * @param {string} [input.workflowPath] workflow path, for the footer
 * @param {string} [input.marker]
 * @returns {string} Markdown comment body
 */
export function buildAdvisorySummary(input = {}) {
  const {
    baseText = null,
    headText = null,
    workflowPath = ".github/workflows/doctor-advisory.yml",
    marker = ADVISORY_MARKER,
  } = input;

  const advisory =
    "> **Advisory only.** This check never fails the build — it reports hook " +
    "health so new drift is visible at review time. Exit code is always 0.";
  const footer = `<sub>Generated by ${workflowPath} · \`hq doctor --json\` (diffed against the base branch)</sub>`;

  const head = parseDoctorJson(headText);
  if (!head.document) {
    return [
      marker,
      "## hq doctor — advisory hook health",
      "",
      advisory,
      "",
      `⚠️ \`hq doctor --json\` did not produce a usable document for this PR (${head.error}). ` +
        "The doctor may be unavailable in the installed CLI; nothing was blocked.",
      "",
      footer,
    ].join("\n");
  }

  const headDoc = head.document;
  const base = parseDoctorJson(baseText);
  const platformId = headDoc.platform?.id ?? "unknown";
  const schema = headDoc.schemaVersion ?? "?";

  const sections = [
    marker,
    "## hq doctor — advisory hook health",
    "",
    advisory,
    "",
    `Platform: \`${platformId}\` · schema v${schema}`,
    "",
  ];

  if (!base.document) {
    // Base comparison unavailable: show standing status only, with a note, so a
    // transient base failure does not flood the comment with false "new" items.
    sections.push(
      `_Base-branch comparison unavailable (${base.error}); showing standing status only._`,
      "",
    );
  } else {
    const { newFails, newlyUntested } = diffDoctorResults(base.document, headDoc);
    sections.push("### Changes introduced by this PR", "");
    if (newFails.length === 0 && newlyUntested.length === 0) {
      sections.push(
        "✅ No new FAIL results or newly-UNTESTED hooks introduced by this PR.",
        "",
      );
    } else {
      if (newFails.length > 0) {
        sections.push(
          `**New FAIL (${newFails.length})** — regressions this PR would introduce:`,
          renderList(newFails, { showCheckId: true }),
          "",
        );
      }
      if (newlyUntested.length > 0) {
        sections.push(
          `**Newly UNTESTED (${newlyUntested.length})** — hooks added without a fixture:`,
          renderList(newlyUntested, { showCheckId: false }),
          "",
        );
      }
    }
  }

  sections.push("### Standing status (whole tree)", "", renderStandingTable(headDoc), "");
  const cov = coverageLine(headDoc);
  if (cov) sections.push(cov, "");
  sections.push(footer);

  return sections.join("\n");
}

/** Read a file as UTF-8, returning null when it does not exist / is unreadable. */
function readTextOrNull(filePath) {
  if (!filePath) return null;
  try {
    return fs.readFileSync(filePath, "utf8");
  } catch {
    return null;
  }
}

/** Minimal `--flag value` argv parser. */
function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg.startsWith("--")) {
      const key = arg.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith("--")) {
        out[key] = true;
      } else {
        out[key] = next;
        i += 1;
      }
    }
  }
  return out;
}

/** CLI entry: node doctor-ci-summary.mjs --base b.json --head h.json [--out s.md]. */
function main(argv) {
  const args = parseArgs(argv);
  if (args.help || !args.head) {
    process.stderr.write(
      "usage: doctor-ci-summary.mjs --head <head.json> [--base <base.json>] " +
        "[--out <summary.md>] [--workflow <path>]\n",
    );
    // Missing --head is a usage error; everything else is advisory and exits 0.
    process.exit(args.help ? 0 : 2);
  }

  const body = buildAdvisorySummary({
    baseText: readTextOrNull(args.base),
    headText: readTextOrNull(args.head),
    workflowPath:
      typeof args.workflow === "string"
        ? args.workflow
        : ".github/workflows/doctor-advisory.yml",
  });

  if (typeof args.out === "string") {
    fs.writeFileSync(args.out, body.endsWith("\n") ? body : body + "\n");
  } else {
    process.stdout.write(body + "\n");
  }
  process.exit(0);
}

// Run as a CLI only when invoked directly, not when imported by tests / the
// workflow's github-script step.
if (
  process.argv[1] &&
  import.meta.url === new URL(`file://${process.argv[1]}`).href
) {
  main(process.argv.slice(2));
}
