#!/usr/bin/env bash
# lint-install-deps.sh — fail if HQ's install/setup surface installs or
# dependency-checks a third-party CLI that HQ itself never uses.
#
# WHY (DEV-1727 / feedback_f4f48522): the /setup wizard used to `which vercel`
# and offer `npm install -g vercel` during base setup. But HQ's own features
# never shell out to the Vercel CLI — `/deploy` targets hq-deploy infrastructure
# and silently no-ops on Vercel-managed projects. Gating setup on a tool nobody
# in HQ calls strands every install behind an irrelevant dependency. Vercel (and
# any other third-party deploy CLI) is a user-provided integration, installed
# on-demand by the user only when they drive their own pipeline.
#
# This lint asserts the install-surface files (the installer script, the install
# manifest, and the setup/onboard wizards) contain NO install / presence-check /
# auth-gate invocation of any token listed in core/scripts/install-deps.deny. It
# catches FUTURE re-introductions, not just the originally-reported one.
#
# Detection is deliberately low-false-positive. A bare mention of the tool name
# (including prose that says "do NOT install it") is allowed — only a
# dependency-bearing construct is flagged:
#   • package-manager install:  npm|pnpm|yarn|bun (install|i|add|exec) [flags] <tok>
#   • global install flag:       -g <tok>   /   --global ... <tok>
#   • homebrew install:          brew install [flags] <tok>
#   • presence check / gate:     which <tok>   /   command -v <tok>
#   • auth-gate invocation:      <tok> whoami   /   <tok> login
#
# Exit codes: 0 = clean, 1 = forbidden dependency invocation found, 2 = error.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

deny_file="core/scripts/install-deps.deny"

# The install/setup surface: only files a user runs (or an agent follows) to
# install or onboard HQ. NOT policies/knowledge (those legitimately discuss
# tool usage at point of use).
surface_files=(
  "core/scripts/setup.sh"
  "core/core.yaml"
  ".claude/skills/setup/SKILL.md"
  ".claude/skills/onboard/SKILL.md"
)

if [[ ! -f "$deny_file" ]]; then
  echo "lint-install-deps: no $deny_file (nothing to check)"
  exit 0
fi

# Existing surface files only (a lean scaffold may not ship every wizard).
present=()
for f in "${surface_files[@]}"; do
  [[ -f "$f" ]] && present+=("$f")
done
if [[ ${#present[@]} -eq 0 ]]; then
  echo "lint-install-deps: no install-surface files present (nothing to check)"
  exit 0
fi

set +e
node - "$deny_file" "${present[@]}" <<'JS'
const fs = require("fs");

const denyFile = process.argv[2];
const files = process.argv.slice(3);

const tokens = [];
for (let ln of fs.readFileSync(denyFile, "utf8").split(/\r?\n/)) {
  ln = ln.split("#", 1)[0].trim();
  if (/^[a-z][a-z0-9-]*$/.test(ln)) tokens.push(ln);
}

if (!tokens.length) {
  console.log("OK: install-deps.deny lists no tokens (nothing to check).");
  process.exit(0);
}

const bad = [];
for (const tok of tokens) {
  const t = tok.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const patterns = [
    // package-manager install of the token (token is the install target,
    // optionally after one or more -flags)
    "\\b(?:npm|pnpm|yarn|bun)\\s+(?:install|i|add|exec)\\b(?:\\s+-{1,2}[a-z][\\w-]*)*\\s+" + t + "\\b",
    // global install flag pointing at the token
    "-g\\s+" + t + "\\b",
    "--global\\b(?:\\s+-{1,2}[a-z][\\w-]*)*\\s+" + t + "\\b",
    // homebrew install of the token
    "\\bbrew\\s+install\\b(?:\\s+-{1,2}[a-z][\\w-]*)*\\s+" + t + "\\b",
    // presence check used as a setup gate
    "\\bwhich\\s+" + t + "\\b",
    "\\bcommand\\s+-v\\s+" + t + "\\b",
    // auth-gate invocation during setup
    "\\b" + t + "\\s+(?:whoami|login)\\b",
  ];
  const rx = new RegExp(patterns.join("|"), "i");
  for (const f of files) {
    const lines = fs.readFileSync(f, "utf8").split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      if (rx.test(lines[i])) bad.push([f, i + 1, tok, lines[i].trim()]);
    }
  }
}

if (bad.length) {
  console.log("FAIL: HQ's install/setup surface installs or dependency-checks a tool");
  console.log("listed in core/scripts/install-deps.deny. HQ features never call these;");
  console.log("they are user-provided — do not gate setup on them.");
  console.log("");
  for (const [f, i, tok, line] of bad) console.log("  " + f + ":" + i + "  [" + tok + "]  " + line);
  console.log("");
  console.log("Fix one of:");
  console.log("  • remove the install/check from the setup surface (the tool is");
  console.log("    user-provided; document usage in a point-of-use policy instead); or");
  console.log("  • if HQ genuinely needs the tool at install time, remove it from");
  console.log("    core/scripts/install-deps.deny (and justify in the PR).");
  process.exit(1);
}

console.log("OK: install/setup surface installs no denied dependency (" +
  tokens.length + " token(s) checked across " + files.length + " file(s)).");
JS
rc=$?
set -e
exit "$rc"
