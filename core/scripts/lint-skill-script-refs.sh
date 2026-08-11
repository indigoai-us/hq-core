#!/usr/bin/env bash
# lint-skill-script-refs.sh — fail if a selected release skill refers to a
# local shell script that is absent from the same HQ scaffold.
#
# Skills are executable guidance. A script path in a skill must resolve in a
# fresh install, just as lint-skill-command-refs.sh guarantees slash commands
# resolve. The selected skill keeps this validation focused on its documented
# workflow and catches stale paths left behind when a script is retired.
#
# Allowlist: core/scripts/lint-skill-script-refs.allow (one normalized script
# ref per line, `#` comments allowed). A ref listed there is a KNOWN pending
# backbone — a skill absorbed ahead of its script — and is exempted so the gate
# stays green while the gap remains visible in the allow file, not silent.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

if [[ $# -ne 1 || ! "$1" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo "usage: $0 <skill-name>" >&2
  exit 2
fi

node - "$repo_root" "$1" <<'JS'
const fs = require("fs");
const path = require("path");

const root = path.resolve(process.argv[2]);
const skillName = process.argv[3];
const skillFile = path.join(root, ".claude", "skills", skillName, "SKILL.md");
const scriptRef = /(?<![A-Za-z0-9_./-])((?:\.\/)?(?:core|\.claude)\/[A-Za-z0-9_./-]+\.sh)(?![A-Za-z0-9_./-])/g;

// Normalized (leading ./ stripped) refs that are known-pending and exempt.
const allowFile = path.join(root, "core", "scripts", "lint-skill-script-refs.allow");
const allow = new Set();
if (fs.existsSync(allowFile)) {
  for (let entry of fs.readFileSync(allowFile, "utf8").split(/\r?\n/)) {
    entry = entry.replace(/#.*$/, "").trim();
    if (entry) allow.add(entry.replace(/^\.\//, ""));
  }
}

if (!fs.existsSync(skillFile)) {
  console.error(`ERROR: skill not found: ${path.relative(root, skillFile)}`);
  process.exit(2);
}

const missing = [];
const source = fs.readFileSync(skillFile, "utf8");
for (const match of source.matchAll(scriptRef)) {
  const reference = match[1];
  if (allow.has(reference.replace(/^\.\//, ""))) continue;
  const target = path.resolve(root, reference);
  const relativeTarget = path.relative(root, target);
  const line = source.slice(0, match.index).split(/\r?\n/).length;

  if (relativeTarget.startsWith("..") || path.isAbsolute(relativeTarget) || !fs.existsSync(target)) {
    missing.push({
      file: path.relative(root, skillFile).split(path.sep).join("/"),
      line,
      reference,
    });
  }
}

if (missing.length > 0) {
  console.error("FAIL: release skill guidance references missing local shell script(s):");
  for (const { file, line, reference } of missing) {
    console.error(`  ${file}:${line} -> ${reference}`);
  }
  process.exit(1);
}

console.log(`OK: every local shell script referenced by ${skillName} exists.`);
JS
