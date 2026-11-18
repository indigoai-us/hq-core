#!/usr/bin/env bash
# us041-duplicate-command-callers.test.sh: shipped core files call the owning
# commands, not the duplicates hq-cli keeps for older callers (hq-core-rust
# US-041).
#
# The duplicates and their owning commands:
#   hq auth login | logout | status   -> hq login | hq logout | hq whoami --check / --json
#   hq sync status                    -> hq daemon sync status --local
#   hq sync mode [--show | <mode>]    -> hq daemon sync mode list | set <company> <mode>
#   hq packages install | list | update | remove
#                                     -> hq install | hq packs list | hq packs update --registry | hq remove
#
# Searched: every tracked text file the release ships (core/, .claude/, .codex/,
# .grok/, AGENTS.md), plus the same commands as argument arrays in code
# ('sync', 'status' and the rest). Not searched: changelogs and MIGRATION.md
# (history), test files and fixtures, the generated CLI reference
# (core/knowledge/public/hq-core/hq-cli-reference.md, built from hq-cli's own
# command list, which still has the duplicates) and the manifest
# (core/functions.yaml). One file may name a duplicate on purpose:
#   .claude/skills/hq-logout/SKILL.md tells readers to use hq logout instead.
#
# Tracked files when the tree is a git checkout, every file otherwise.
#
# A second part runs the same scan on a fixture tree with one caller of each
# duplicate, so a scan that finds nothing cannot pass by accident.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
failures=0
fail() { printf 'FAIL: %s\n' "$1"; failures=$((failures + 1)); }
pass() { printf 'PASS: %s\n' "$1"; }

TEXT_RE='hq(\.cmd)? +(auth +(login|logout|status)|sync +(status|mode)|packages +(install|list|update|remove))([^A-Za-z0-9_-]|$)'
ARGV_RE="[\"']auth[\"'] *, *[\"'](login|logout|status)[\"']|[\"']sync[\"'] *, *[\"'](status|mode)[\"']|[\"']packages[\"'] *, *[\"'](install|list|update|remove)[\"']"
ALLOWED='^\.claude/skills/hq-logout/SKILL\.md:'

# scan <tree>: print path:line:text for each duplicate caller in the tree.
scan() {
  local tree=$1
  (
    cd "$tree" || exit 2
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      git ls-files -- core .claude .codex .grok AGENTS.md
    else
      find core .claude .codex .grok AGENTS.md -type f 2>/dev/null
    fi \
      | grep -vE '(^|/)node_modules/' \
      | grep -vE '(^|/)(tests?|__tests__|__fixtures__|fixtures|hook-corpus)/|\.(test|spec)\.[a-z]+$|(^|/)test_[^/]*\.py$' \
      | grep -vE '(^|/)(CHANGELOG[^/]*|MIGRATION\.md)$|(^|/)changelog\.d/' \
      | grep -vxE 'core/knowledge/public/hq-core/hq-cli-reference\.md|core/functions\.yaml' \
      | grep -E '\.(md|sh|bash|mjs|cjs|js|ts|py|json|yaml|yml|toml|txt)$|(^|/)AGENTS\.md$' \
      | while IFS= read -r f; do
          # Blank out the owning spellings first, so a line that names both
          # an owning command and a duplicate is still reported.
          sed -E -e 's/daemon +sync/daemon_sync/g' \
            -e "s/([\"']daemon[\"'] *, *)[\"']sync[\"']/\1'daemon_sync'/g" \
            -e 's/"family" *: *"sync"/"family":"x"/g' "$f" \
            | grep -nE "$TEXT_RE|$ARGV_RE" | sed "s|^|$f:|"
        done
  ) | grep -vE "$ALLOWED"
}

# Part 1: the fixture tree proves the scan finds each kind of caller.
fixture=$(mktemp -d "${TMPDIR:-/tmp}/us041-callers.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/core/scripts" "$fixture/.claude/skills/demo/scripts" "$fixture/.claude/skills/hq-logout" "$fixture/core/scripts/tests"
cat > "$fixture/core/scripts/demo.sh" <<'EOF'
hq auth status >/dev/null || exit 1
hq sync status --json
hq packages install demo-pack
hq daemon sync status --local
hq daemon sync status --local || hq sync status
EOF
cat > "$fixture/.claude/skills/demo/SKILL.md" <<'EOF'
Run `hq sync mode --show` to list memberships.
Run `hq daemon sync mode list` instead.
EOF
printf "run(['hq', 'sync', 'mode', '--show'])\nrun(['hq', 'daemon', 'sync', 'mode', 'list'])\n" > "$fixture/.claude/skills/demo/scripts/sweep.py"
printf 'Use `hq logout`, not `hq auth logout`.\n' > "$fixture/.claude/skills/hq-logout/SKILL.md"
printf 'hq auth login\n' > "$fixture/core/scripts/tests/demo.test.sh"
found=$(scan "$fixture")
for want in 'core/scripts/demo.sh:1:' 'core/scripts/demo.sh:2:' 'core/scripts/demo.sh:3:' 'core/scripts/demo.sh:5:' '.claude/skills/demo/SKILL.md:1:' '.claude/skills/demo/scripts/sweep.py:1:'; do
  if printf '%s\n' "$found" | grep -F -- "$want" >/dev/null; then pass "the scan finds the duplicate caller at $want"; else fail "the scan missed the duplicate caller at $want"; fi
done
for not in 'core/scripts/demo.sh:4:' '.claude/skills/demo/SKILL.md:2:' '.claude/skills/demo/scripts/sweep.py:2:' 'hq-logout/SKILL.md' 'tests/demo.test.sh'; do
  if printf '%s\n' "$found" | grep -F -- "$not" >/dev/null; then fail "the scan reported $not, which is an owning command, the allowed hq-logout note or a test file"; else pass "the scan leaves $not alone"; fi
done

# Part 2: the shipped tree has no duplicate caller.
found=$(scan "$ROOT")
if [ -z "$found" ]; then
  pass "no shipped core file calls a duplicate command"
else
  printf '%s\n' "$found"
  fail "shipped core files still call a duplicate command (listed above); use the owning command"
fi

if [ "$failures" -gt 0 ]; then
  printf 'us041-duplicate-command-callers: %d failure(s)\n' "$failures"
  exit 1
fi
printf 'us041-duplicate-command-callers: all checks passed\n'
