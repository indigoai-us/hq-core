#!/usr/bin/env node
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

function argument(name) {
  const index = process.argv.indexOf(name);
  if (index < 0 || index + 1 >= process.argv.length) {
    throw new Error(`missing ${name} argument`);
  }
  return process.argv[index + 1];
}

function shellWords(source) {
  const words = [];
  let word = "";
  let quote = "";
  let escaped = false;
  for (const character of source) {
    if (escaped) {
      word += character;
      escaped = false;
      continue;
    }
    if (quote === "'") {
      if (character === "'") quote = "";
      else word += character;
      continue;
    }
    if (quote === '"') {
      if (character === '"') quote = "";
      else if (character === "\\") escaped = true;
      else word += character;
      continue;
    }
    if (character === "'" || character === '"') {
      quote = character;
      continue;
    }
    if (character === "\\") {
      escaped = true;
      continue;
    }
    if (/[;&|()<>]/.test(character)) break;
    if (/\s/.test(character)) {
      if (word !== "") words.push(word);
      word = "";
      continue;
    }
    word += character;
  }
  if (word !== "") words.push(word);
  return words;
}

function executableCoreCalls(line) {
  const calls = [];
  // The executable-line scanner has already removed comments and here-doc bodies.
  // Require a command boundary so quoted diagnostics such as "run hq core ..."
  // are not mistaken for an invocation.
  const pattern = /(?:^|[;&|(`])\s*(?:(?:if|then|elif|while|until|do|exec|command|!)\s+)*hq\s+core(?:\s+|$)/g;
  let match;
  while ((match = pattern.exec(line)) !== null) {
    let words = shellWords(line.slice(pattern.lastIndex));
    if (words[0] === "--hq-root") words = words.slice(2);
    else if (words[0]?.startsWith("--hq-root=")) words = words.slice(1);
    if (words.length === 0) {
      calls.push({ error: "has no literal command name" });
      continue;
    }
    calls.push({ words });
  }
  return calls;
}

function readTsv(path) {
  return readFileSync(path, "utf8")
    .split(/\r?\n/)
    .filter(Boolean)
    .map((line) => {
      const [pathValue, command, kind, root, interpreter, minCli, state] = line.split("\t");
      return { path: pathValue, command, kind, root, interpreter, minCli, state };
    });
}

const root = argument("--root");
const rows = readTsv(argument("--rows"));
const scanner = argument("--scanner");
const catalog = JSON.parse(readFileSync(argument("--catalog"), "utf8"));
if (!Array.isArray(catalog)) throw new Error("hq core commands --json must return an array");

const byName = new Map();
for (const entry of catalog) {
  if (!entry || typeof entry.name !== "string" || typeof entry.root !== "string") {
    throw new Error("hq core commands --json returned a row without name and root");
  }
  if (!byName.has(entry.name)) byName.set(entry.name, entry);
}

const mismatches = [];
for (const row of rows) {
  if (row.state !== "forwarded" || !["generated", "hybrid"].includes(row.kind)) continue;
  const entry = byName.get(row.command);
  if (!entry) {
    mismatches.push(`${row.path}: hq core ${row.command} is missing from hq core commands`);
  } else {
    // `live-project` is a wrapper root-selection policy; the native command
    // still declares its root capability as `live` in the published catalog.
    const expectedCatalogRoot = row.root === "live-project" ? "live" : row.root;
    if (entry.root !== expectedCatalogRoot) {
      mismatches.push(`${row.path}: hq core ${row.command} root is ${entry.root}, expected ${expectedCatalogRoot}`);
    }
  }
}

const allowedSources = [
  "core/scripts/handoff-finalize.sh",
  "core/scripts/handoff-post.sh",
  "core/scripts/generate-forwarders.sh",
  "core/scripts/check-cli-hosted.sh",
  "core/scripts/ci/install-pinned-hq-cli.sh",
];
for (const relativePath of allowedSources) {
  const sourcePath = join(root, relativePath);
  if (!existsSync(sourcePath)) continue;
  const language = /\.(?:mjs|js)$/.test(sourcePath) ? "javascript" : "shell";
  const scanned = spawnSync("awk", ["-v", `language=${language}`, "-f", scanner, sourcePath], {
    encoding: "utf8",
  });
  if (scanned.error || scanned.status !== 0) {
    mismatches.push(`${relativePath}: executable-line scan failed`);
    continue;
  }
  for (const line of scanned.stdout.split(/\r?\n/).filter(Boolean)) {
    for (const call of executableCoreCalls(line)) {
      if (call.error) {
        mismatches.push(`${relativePath}: hq core call ${call.error}`);
        continue;
      }
      const { words } = call;
      if (words.length === 1 && words[0] === "--help") continue;
      if (/[$*?{}]/.test(words[0])) {
        mismatches.push(`${relativePath}: hq core command name is not static (${words[0]})`);
        continue;
      }
      const oneWord = words[0];
      const twoWords = words.length > 1 ? `${words[0]} ${words[1]}` : "";
      const command = byName.has(twoWords) ? twoWords : oneWord;
      if (command === twoWords && /[$*?{}]/.test(words[1])) {
        mismatches.push(`${relativePath}: hq core command name is not static (${twoWords})`);
        continue;
      }
      if (!byName.has(command)) {
        mismatches.push(`${relativePath}: hq core ${command} is missing from hq core commands`);
      }
    }
  }
}

if (mismatches.length > 0) {
  for (const mismatch of mismatches) process.stderr.write(`${mismatch}\n`);
  process.exitCode = 1;
}
