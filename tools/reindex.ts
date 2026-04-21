#!/usr/bin/env npx tsx
/**
 * reindex.ts — Scan knowledge/ and generate INDEX.md files.
 *
 * Usage:  npx tsx tools/reindex.ts [-c <company-slug>]
 *
 * No external dependencies beyond Node built-ins.
 */

import { readdir, readFile, writeFile, stat } from "node:fs/promises";
import { join, relative, basename, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execSync } from "node:child_process";

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = execSync("git rev-parse --show-toplevel", { encoding: "utf-8" }).trim();

function getCompanySlug(): string {
  const idx = process.argv.indexOf("-c");
  return idx !== -1 && process.argv[idx + 1] ? process.argv[idx + 1] : "personal";
}

const COMPANY = getCompanySlug();
const KNOWLEDGE_DIR = join(repoRoot, "companies", COMPANY, "knowledge");

// ── Frontmatter parsing (hand-rolled, no yaml library) ──────────────────────

interface Frontmatter {
  title: string;
  category: string;
  tags: string[];
  source: string;
  confidence: number;
  created_at: string;
  updated_at: string;
}

function parseFrontmatter(raw: string): Frontmatter | null {
  const match = raw.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  if (!match) return null;
  const block = match[1];

  const str = (key: string): string => {
    const m = block.match(new RegExp(`^${key}:\\s*["']?(.+?)["']?\\s*$`, "m"));
    return m ? m[1] : "";
  };

  const num = (key: string): number => {
    const v = str(key);
    return v ? parseFloat(v) : 0;
  };

  const arr = (key: string): string[] => {
    const m = block.match(new RegExp(`^${key}:\\s*\\[(.*)\\]\\s*$`, "m"));
    if (!m) return [];
    return m[1]
      .split(",")
      .map((s) => s.trim().replace(/^["']|["']$/g, ""))
      .filter(Boolean);
  };

  const title = str("title");
  const category = str("category");
  if (!title || !category) return null;

  return {
    title,
    category,
    tags: arr("tags"),
    source: str("source"),
    confidence: num("confidence"),
    created_at: str("created_at"),
    updated_at: str("updated_at"),
  };
}

// ── Summary extraction ──────────────────────────────────────────────────────

function extractSummary(raw: string): string {
  // Strip frontmatter
  const body = raw.replace(/^---[\s\S]*?---\s*/, "");
  const lines = body.split("\n");
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    if (trimmed.startsWith("#")) continue;
    const summary = trimmed.length > 100 ? trimmed.slice(0, 97) + "..." : trimmed;
    return summary;
  }
  return "";
}

// ── File discovery ──────────────────────────────────────────────────────────

interface Entry {
  relPath: string; // relative to knowledge/
  frontmatter: Frontmatter;
  summary: string;
}

async function discoverEntries(): Promise<Entry[]> {
  const entries: Entry[] = [];

  async function walk(dir: string) {
    const items = await readdir(dir, { withFileTypes: true });
    for (const item of items) {
      if (item.name.startsWith(".")) continue;
      const full = join(dir, item.name);
      if (item.isDirectory()) {
        await walk(full);
      } else if (
        item.name.endsWith(".md") &&
        item.name !== "INDEX.md"
      ) {
        const raw = await readFile(full, "utf-8");
        const fm = parseFrontmatter(raw);
        if (!fm) {
          console.warn(`  skip (no valid frontmatter): ${relative(KNOWLEDGE_DIR, full)}`);
          continue;
        }
        entries.push({
          relPath: relative(KNOWLEDGE_DIR, full),
          frontmatter: fm,
          summary: extractSummary(raw),
        });
      }
    }
  }

  await walk(KNOWLEDGE_DIR);
  return entries;
}

// ── Index generation ────────────────────────────────────────────────────────

function formatDate(iso: string): string {
  if (!iso) return "—";
  return iso.replace(/T.*$/, "");
}

async function generateCategoryIndex(
  category: string,
  entries: Entry[],
): Promise<void> {
  // Sort by updated_at DESC
  entries.sort((a, b) =>
    (b.frontmatter.updated_at || "").localeCompare(a.frontmatter.updated_at || ""),
  );

  const lines: string[] = [
    `# ${category}`,
    "",
    "| File | Title | Summary | Confidence | Updated |",
    "|------|-------|---------|------------|---------|",
  ];

  for (const e of entries) {
    const file = `[${basename(e.relPath)}](${basename(e.relPath)})`;
    const conf = e.frontmatter.confidence.toFixed(1);
    const updated = formatDate(e.frontmatter.updated_at);
    lines.push(`| ${file} | ${e.frontmatter.title} | ${e.summary} | ${conf} | ${updated} |`);
  }

  lines.push("");
  const catDir = join(KNOWLEDGE_DIR, category);
  await writeFile(join(catDir, "INDEX.md"), lines.join("\n"), "utf-8");
  console.log(`  wrote ${category}/INDEX.md (${entries.length} entries)`);
}

async function generateRootIndex(
  categoryMap: Map<string, Entry[]>,
): Promise<void> {
  const categories = [...categoryMap.keys()].sort();

  const lines: string[] = [
    "# Knowledge Index",
    "",
    "| Category | Files | Last Updated |",
    "|----------|-------|--------------|",
  ];

  for (const cat of categories) {
    const entries = categoryMap.get(cat)!;
    const latest = entries
      .map((e) => e.frontmatter.updated_at || "")
      .sort()
      .reverse()[0];
    const link = `[${cat}](${cat}/INDEX.md)`;
    lines.push(`| ${link} | ${entries.length} | ${formatDate(latest)} |`);
  }

  lines.push("");
  await writeFile(join(KNOWLEDGE_DIR, "INDEX.md"), lines.join("\n"), "utf-8");
  console.log(`  wrote ${COMPANY}/knowledge/INDEX.md (${categories.length} categories)`);
}

// ── Main ────────────────────────────────────────────────────────────────────

async function main() {
  console.log(`reindex: scanning companies/${COMPANY}/knowledge/...`);
  const entries = await discoverEntries();
  console.log(`reindex: found ${entries.length} entries`);

  // Group by category
  const categoryMap = new Map<string, Entry[]>();
  for (const e of entries) {
    const cat = e.frontmatter.category;
    if (!categoryMap.has(cat)) categoryMap.set(cat, []);
    categoryMap.get(cat)!.push(e);
  }

  // Generate per-category INDEX.md (skip empty)
  for (const [cat, catEntries] of categoryMap) {
    // Verify the category directory exists
    const catDir = join(KNOWLEDGE_DIR, cat);
    try {
      const s = await stat(catDir);
      if (!s.isDirectory()) continue;
    } catch {
      console.warn(`  skip category "${cat}" (no directory)`);
      continue;
    }
    await generateCategoryIndex(cat, catEntries);
  }

  // Generate root INDEX.md
  await generateRootIndex(categoryMap);
  console.log("reindex: done");
}

main().catch((err) => {
  console.error("reindex: fatal:", err);
  process.exit(1);
});
