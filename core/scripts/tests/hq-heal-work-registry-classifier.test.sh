#!/usr/bin/env bash
# Regression for feedback_f03e3ed7-0468-4569-94a2-47f70c7cabaa: a work-mesh
# register refused because the company's work registry was off was reported by
# hq-heal as an unclassified AUTH_DENIED. hq-heal must classify
# WORK_REGISTRY_DISABLED (and a work-mesh register AUTH_DENIED from older CLIs)
# as its own class, before `access`, and tell a company owner how to turn the
# registry on with the real hq-cli command.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILL="$ROOT/.claude/skills/hq-heal/SKILL.md"
WORKFLOW="$ROOT/.github/workflows/pr-checks.yml"
checks=0
failures=()
expect_grep() {
  local pattern="$1" input="$2" message="$3"
  if grep -Fq -- "$pattern" <<<"$input"; then
    checks=$((checks + 1))
  else
    failures+=("$message")
  fi
}

table="$(sed -n '/^| Class | Triggers/,/^| `unknown` |/p' "$SKILL")"
row="$(grep -E '^\| `work-registry` \|' <<<"$table" || true)"
expect_grep 'WORK_REGISTRY_DISABLED' "$row" 'work-registry row must match WORK_REGISTRY_DISABLED'
expect_grep 'AUTH_DENIED' "$row" 'work-registry row must catch a work-mesh register AUTH_DENIED from older CLIs'
reg_line="$(grep -nE '^\| `work-registry` \|' <<<"$table" | cut -d: -f1 || true)"
acc_line="$(grep -nE '^\| `access` \|' <<<"$table" | cut -d: -f1 || true)"
if [[ -n "$reg_line" && -n "$acc_line" && "$reg_line" -lt "$acc_line" ]]; then
  checks=$((checks + 1))
else
  failures+=('work-registry row must come before the access row (first match wins)')
fi

flags="$(grep -E '^- `--class <name>`' "$SKILL")"
expect_grep '`work-registry`' "$flags" '--class must list work-registry'

extract="$(sed -n '/If `--last-session`/,/Store the resulting text/p' "$SKILL")"
expect_grep 'WORK_REGISTRY_DISABLED' "$extract" '--last-session extraction is missing WORK_REGISTRY_DISABLED'

recipe="$(sed -n '/^#### `work-registry`/,/^#### `access`/p' "$SKILL")"
expect_grep "work registry is off" "$recipe" 'recipe must say plainly that the work registry is off'
expect_grep 'hq company --company <slug> settings get' "$recipe" 'recipe must check the switches with the real get command'
expect_grep 'hq company --company <slug> settings set --work-registry-enabled true' "$recipe" 'recipe must give the real owner command to turn the registry on'
expect_grep '--work-mesh-live-enabled true' "$recipe" 'recipe must cover the live tracking switch too'
expect_grep 'hq mesh context requeue' "$recipe" 'recipe must requeue held sessions after the switch'
expect_grep 'owner' "$recipe" 'recipe must say only a company owner can turn it on'

expect_grep 'bash core/scripts/tests/hq-heal-work-registry-classifier.test.sh' \
  "$(cat "$WORKFLOW")" 'pr-checks.yml must execute this regression test'

if ((${#failures[@]})); then
  for failure in "${failures[@]}"; do printf 'FAIL: %s\n' "$failure" >&2; done
  exit 1
fi
printf 'PASS: %s hq-heal work-registry classifier assertions\n' "$checks"
