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
python3 - "$deny_file" "${present[@]}" <<'PY'
import re, sys

deny_file = sys.argv[1]
files = sys.argv[2:]

tokens = []
for ln in open(deny_file, errors="ignore"):
    ln = ln.split("#", 1)[0].strip()
    if re.fullmatch(r"[a-z][a-z0-9-]*", ln):
        tokens.append(ln)

if not tokens:
    print("OK: install-deps.deny lists no tokens (nothing to check).")
    sys.exit(0)

bad = []
for tok in tokens:
    t = re.escape(tok)
    patterns = [
        # package-manager install of the token (token is the install target,
        # optionally after one or more -flags)
        rf"\b(?:npm|pnpm|yarn|bun)\s+(?:install|i|add|exec)\b(?:\s+-{{1,2}}[a-z][\w-]*)*\s+{t}\b",
        # global install flag pointing at the token
        rf"-g\s+{t}\b",
        rf"--global\b(?:\s+-{{1,2}}[a-z][\w-]*)*\s+{t}\b",
        # homebrew install of the token
        rf"\bbrew\s+install\b(?:\s+-{{1,2}}[a-z][\w-]*)*\s+{t}\b",
        # presence check used as a setup gate
        rf"\bwhich\s+{t}\b",
        rf"\bcommand\s+-v\s+{t}\b",
        # auth-gate invocation during setup
        rf"\b{t}\s+(?:whoami|login)\b",
    ]
    rx = re.compile("|".join(patterns), re.IGNORECASE)
    for f in files:
        for i, line in enumerate(open(f, errors="ignore"), 1):
            if rx.search(line):
                bad.append((f, i, tok, line.strip()))

if bad:
    print("FAIL: HQ's install/setup surface installs or dependency-checks a tool")
    print("listed in core/scripts/install-deps.deny. HQ features never call these;")
    print("they are user-provided — do not gate setup on them.")
    print()
    for f, i, tok, line in bad:
        print(f"  {f}:{i}  [{tok}]  {line}")
    print()
    print("Fix one of:")
    print("  • remove the install/check from the setup surface (the tool is")
    print("    user-provided; document usage in a point-of-use policy instead); or")
    print("  • if HQ genuinely needs the tool at install time, remove it from")
    print("    core/scripts/install-deps.deny (and justify in the PR).")
    sys.exit(1)

print(f"OK: install/setup surface installs no denied dependency "
      f"({len(tokens)} token(s) checked across {len(files)} file(s)).")
PY
rc=$?
set -e
exit "$rc"
