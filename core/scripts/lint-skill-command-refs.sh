#!/usr/bin/env bash
# lint-skill-command-refs.sh — fail if release-shipped guidance instructs a
# slash-command that is not resolvable on the install it is shown to.
#
# WHY (DEV-1716): hq-core ships a lean scaffold. The engineering commands
# (/run-project, /execute-task, /prd, /diagnose, ...) were extracted into the
# separately-installed hq-pack-engineering in 15.0.0 (core/docs/hq/CHANGELOG.md).
# They are auto-installed for upgraders but deliberately NOT for greenfield
# installs. A core skill that prints "run /run-project" as a next step therefore
# strands any pack-less user — the documented dead-end the reporter hit after
# /plan. This lint asserts every command a core skill presents as runnable is
# either (a) a shipped core skill or (b) explicitly allowlisted in
# core/scripts/skill-command-refs.allow. It catches FUTURE dangling references,
# not just the originally-reported skills.
#
# Detection is deliberately low-false-positive: a "command reference" is the
# FIRST token of a fenced-code-block line or of a `backtick span`, matching
# ^/[a-z][a-z0-9-]*. In release policies, namespaced targets and `/invite`
# receive the same validation; hook-injected text is checked for commands named
# after a routing verb.
# Path/URL/route fragments (/api/.., /tmp/.., /sts/vend, /share-session/<t>)
# are excluded. Namespaced targets are resolved against the shipped target skill
# (for example, /indigo:signals resolves to the shipped signals skill).
#
# Exit codes: 0 = clean, 1 = dangling reference(s) found, 2 = script error.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

skills_dir=".claude/skills"
allow_file="core/scripts/skill-command-refs.allow"

if [[ ! -d "$skills_dir" ]]; then
  echo "lint-skill-command-refs: no $skills_dir (nothing to check)"
  exit 0
fi

resolvable_file="$(mktemp)"
trap 'rm -f "$resolvable_file"' EXIT

# Resolvable set = shipped core skills (bare dir names, skipping _shared etc.)
# ∪ allowlisted tokens.
{
  for d in "$skills_dir"/*/; do
    bn="$(basename "$d")"
    [[ "$bn" == _* ]] && continue
    echo "$bn"
  done
  if [[ -f "$allow_file" ]]; then
    sed -E 's/#.*$//' "$allow_file" | tr -d '[:blank:]' | grep -E '^[a-z][a-z0-9-]*$' || true
  fi
} | sort -u > "$resolvable_file"

set +e
node - "$skills_dir" "core/policies" ".claude/hooks" "$resolvable_file" <<'JS'
const fs = require("fs");
const path = require("path");

const [skillsDir, policiesDir, hooksDir, resolvableFile] = process.argv.slice(2);
const resolvable = new Set(fs.readFileSync(resolvableFile, "utf8").split(/\s+/).filter(Boolean));

// First token of a line/span: a slash-command, not a path/route fragment.
const cmd = /^\/([a-z][a-z0-9-]*(?::[a-z][a-z0-9-]*)?)(?![a-z0-9/:-])/;
const hookCmd = /\b(?:run|running|invoke|execute)\s+`?\/([a-z][a-z0-9-]*(?::[a-z][a-z0-9-]*)?)(?![a-z0-9/:-])/g;
const backtick = /`([^`]+)`/g;
const hqInvite = /(?<![a-z0-9_-])hq\s+invite(?:\s|$)/;

// These commands are supplied by their named integrations rather than hq-core.
// Other namespaced targets must resolve to a shipped skill.
const externalNamespaced = new Set(["indigo:action-items", "personal:worktree"]);

const walkMd = (dir) => {
  const out = [];
  const walk = (d) => {
    let entries;
    try { entries = fs.readdirSync(d, { withFileTypes: true }); } catch (e) { return; }
    for (const e of entries) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.isFile() && e.name.endsWith(".md")) out.push(p);
    }
  };
  walk(dir);
  return out.sort();
};

const files = [];
try {
  for (const d of fs.readdirSync(skillsDir).sort()) {
    const f = path.join(skillsDir, d, "SKILL.md");
    if (fs.existsSync(f)) files.push({ f: f, kind: "skill" });
  }
} catch (e) {}
for (const f of walkMd(policiesDir)) files.push({ f: f, kind: "policy" });
try {
  for (const name of fs.readdirSync(hooksDir).sort()) {
    if (name.endsWith(".sh")) files.push({ f: path.join(hooksDir, name), kind: "hook" });
  }
} catch (e) {}

const norm = (p) => p.split(path.sep).join("/");
const slackNativeInvite = (f, line, command) =>
  command === "invite" &&
  norm(f) === "core/policies/hq-slack.md" &&
  /\/invite\s+@[a-z0-9_-]+/i.test(line);

const resolvableCommand = (command) => {
  if (externalNamespaced.has(command)) return true;
  const parts = command.split(":");
  return resolvable.has(parts[parts.length - 1]);
};

const bad = [];
for (const { f, kind } of files) {
  const isHook = kind === "hook";
  const isPolicy = kind === "policy";
  let inFence = false;
  const lines = fs.readFileSync(f, "utf8").split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const s = lines[i];
    if (hqInvite.test(s)) bad.push([f, i + 1, "hq invite"]);

    if (isHook) {
      if (s.includes("additionalContext")) {
        let m;
        hookCmd.lastIndex = 0;
        while ((m = hookCmd.exec(s)) !== null) {
          if (!resolvableCommand(m[1])) bad.push([f, i + 1, m[1]]);
        }
      }
      continue;
    }

    if (s.trimStart().startsWith("```")) { inFence = !inFence; continue; }
    const cands = [];
    if (inFence) {
      const m = s.trim().match(cmd);
      if (m) cands.push(m[1]);
    }
    let bm;
    backtick.lastIndex = 0;
    while ((bm = backtick.exec(s)) !== null) {
      const m = bm[1].trim().match(cmd);
      if (m) cands.push(m[1]);
    }
    for (const c of cands) {
      if (isPolicy && !c.includes(":") && c !== "invite" && !s.includes("⚠")) continue;
      if (slackNativeInvite(f, s, c)) continue;
      if (!resolvableCommand(c)) bad.push([f, i + 1, c]);
    }
  }
}

if (bad.length) {
  console.log("FAIL: dangling release-guidance command reference(s) — these commands are neither");
  console.log("a shipped core skill nor allowlisted in core/scripts/skill-command-refs.allow:");
  console.log("");
  for (const [f, i, c] of bad) console.log("  " + f + ":" + i + "  ->  " + (c === "hq invite" ? c : "/" + c));
  console.log("");
  console.log("Fix one of:");
  console.log("  • change the skill to instruct a command that ships in core; or");
  console.log("  • if /<cmd> comes from an installable pack, reference it WITH the");
  console.log("    pack's install line and add /<cmd> to skill-command-refs.allow; or");
  console.log("  • if it is a genuine non-command (API route/placeholder), add it to");
  console.log("    the 'Not commands' section of skill-command-refs.allow.");
  process.exit(1);
}

console.log("OK: every command referenced by release guidance resolves (" + resolvable.size + " resolvable names).");
JS
rc=$?
set -e
exit "$rc"
