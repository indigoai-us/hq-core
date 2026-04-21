#!/usr/bin/env npx tsx
/**
 * queue-curiosity.ts
 * Appends a curiosity item to companies/{slug}/knowledge/.queue.jsonl
 *
 * Usage:
 *   npx tsx tools/queue-curiosity.ts \
 *     -c personal \
 *     --question "How does X work?" \
 *     --context "Encountered during Y task" \
 *     --source knowledge_gap \
 *     --priority 5
 */

import fs from "node:fs";
import path from "node:path";
import { execSync } from "node:child_process";

const repoRoot = execSync("git rev-parse --show-toplevel", { encoding: "utf-8" }).trim();

const VALID_SOURCES = [
  "user_interaction",
  "outcome_gap",
  "knowledge_gap",
  "conversation_insight",
  "research_followup",
  "trend_detection",
] as const;
type Source = (typeof VALID_SOURCES)[number];

function getCompanySlug(argv: string[]): string {
  const idx = argv.indexOf("-c");
  return idx !== -1 && argv[idx + 1] ? argv[idx + 1] : "personal";
}

const COMPANY = getCompanySlug(process.argv);
const QUEUE_PATH = path.join(repoRoot, "companies", COMPANY, "knowledge", ".queue.jsonl");

// ── Arg parsing ──────────────────────────────────────────────────────
function parseArgs(argv: string[]): Record<string, string> {
  const args: Record<string, string> = {};
  for (let i = 2; i < argv.length; i++) {
    const arg = argv[i];
    if (arg.startsWith("--") && i + 1 < argv.length) {
      const key = arg.slice(2);
      args[key] = argv[++i];
    }
  }
  return args;
}

function fail(msg: string): never {
  process.stderr.write(`Error: ${msg}\n`);
  process.exit(1);
}

// ── Main ─────────────────────────────────────────────────────────────
const args = parseArgs(process.argv);

const question = args.question;
if (!question) fail("--question is required");

const context = args.context ?? "";

const source = (args.source ?? "knowledge_gap") as Source;
if (!VALID_SOURCES.includes(source)) {
  fail(
    `Invalid source "${source}". Must be one of: ${VALID_SOURCES.join(", ")}`,
  );
}

const priorityRaw = args.priority ?? "5";
const priority = Number(priorityRaw);
if (!Number.isInteger(priority) || priority < 1 || priority > 10) {
  fail(`Invalid priority "${priorityRaw}". Must be an integer 1-10.`);
}

const now = new Date().toISOString();
const item = {
  id: `c-${Date.now()}`,
  question,
  context,
  source,
  priority,
  status: "pending",
  created_at: now,
  updated_at: now,
};

// Ensure parent dir exists
fs.mkdirSync(path.dirname(QUEUE_PATH), { recursive: true });

// Atomic append on POSIX
fs.appendFileSync(QUEUE_PATH, JSON.stringify(item) + "\n");

process.stdout.write(item.id + "\n");
